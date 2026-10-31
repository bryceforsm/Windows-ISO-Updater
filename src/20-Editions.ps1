#region Editions and output naming
# Returns the 8.3 short path for a file, avoiding spaces in paths passed to oscdimg's -bootdata argument.
function Get-ShortPath {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $Fso = New-Object -ComObject Scripting.FileSystemObject
        $Short = $Fso.GetFile($Path).ShortPath
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Fso) | Out-Null
        if ($Short) { return $Short }
    }
    catch { }
    return $Path
}

# oscdimg's -bootdata value for a media folder. etfsboot.com boots it on legacy BIOS PCs and efisys.bin on
# UEFI ones, so both go in when both exist. Short paths because -bootdata breaks on a space. Returns $null
# when the folder has neither, which still builds an ISO but not a bootable one.
function Get-OscdimgBootData {
    param([Parameter(Mandatory)][string]$MediaRoot)

    $EtfsBoot = Join-Path -Path $MediaRoot -ChildPath 'boot\etfsboot.com'
    $EfiSys   = Join-Path -Path $MediaRoot -ChildPath 'efi\microsoft\boot\efisys.bin'
    if ((Test-Path -LiteralPath $EtfsBoot) -and (Test-Path -LiteralPath $EfiSys)) {
        return "2#p0,e,b$(Get-ShortPath -Path $EtfsBoot)#pEF,e,b$(Get-ShortPath -Path $EfiSys)"
    }
    if (Test-Path -LiteralPath $EfiSys) { return "1#pEF,e,b$(Get-ShortPath -Path $EfiSys)" }
    return $null
}

# Resolves a list of edition tokens (edition names, partial names, or index numbers) to the matching
# install.wim image indexes. Returns the distinct, sorted indexes that matched. Unmatched tokens are
# reported via the [ref]$Unmatched list so the caller can decide whether to fail.
function Resolve-EditionIndexes {
    param(
        [Parameter(Mandatory)][object[]]$Images,
        [Parameter(Mandatory)][string[]]$Tokens,
        [ref]$Unmatched
    )
    $Matched = New-Object System.Collections.Generic.List[int]
    $NoMatch = New-Object System.Collections.Generic.List[string]
    foreach ($Token in $Tokens) {
        # Batch launchers pass "-KeepEditions 1,3" as one string, so split each token on commas here too.
        foreach ($T in ("$Token".Trim() -split '\s*,\s*' | Where-Object { $_ -ne '' })) {
            $Found = $null
            if ($T -match '^\d+$') {
                $Found = $Images | Where-Object { $_.ImageIndex -eq [int]$T }
            }
            else {
                $Found = $Images | Where-Object { $_.ImageName -eq $T }
                if (-not $Found) { $Found = $Images | Where-Object { $_.ImageName -like "*$T*" } }
            }
            if ($Found) { $Found | ForEach-Object { [void]$Matched.Add([int]$_.ImageIndex) } }
            else { [void]$NoMatch.Add($T) }
        }
    }
    if ($Unmatched) { $Unmatched.Value = $NoMatch }
    return ($Matched | Sort-Object -Unique)
}

# Scores a Windows edition name so the "highest" edition can be picked automatically. Only Enterprise,
# Pro, and Home are considered (Enterprise > Pro > Home). Education and Workstation editions (including
# "Pro Education" and "Pro for Workstations") are deliberately excluded and scored lowest so they are
# never chosen when a plain Enterprise/Pro/Home edition is present. Within a tier, base editions are
# preferred over the "N" and "Single Language" variants.
# Windows Server is ranked the other way up, Standard over Datacenter: an installed Standard server can be
# upgraded to Datacenter in place with DISM /Set-Edition, but Datacenter can never be taken back down. The
# Desktop Experience still wins over the bare (Server Core) name, because that choice cannot be changed
# after installation in either direction.
function Get-EditionRank {
    param([string]$Name)
    $n = "$Name".ToLower()
    if ($n -match 'standard') { $Rank = 70 }
    elseif ($n -match 'datacenter') { $Rank = 50 }
    elseif ($n -match 'education|workstation') { $Rank = 5 }  # excluded tiers - lowest priority
    elseif ($n -match 'enterprise') { $Rank = 60 }
    elseif ($n -match 'pro') { $Rank = 40 }
    elseif ($n -match 'home|core|famille') { $Rank = 20 } # Famille is the French localized name for Home
    else { $Rank = 10 }
    if ($n -match 'desktop experience') { $Rank += 1 } # prefer the full server install over Server Core
    if ($n -match '(^|\s)n(\s|$)') { $Rank -= 2 }   # prefer base over "N" variants
    if ($n -match 'single language') { $Rank -= 1 } # prefer base over Single Language
    return $Rank
}

# Chooses the editions to keep when the user has not named any: Enterprise, Pro and Home on client media,
# whichever of them the media actually carries, so one ISO covers the business and consumer tiers. Server
# media keeps one, because its tiers are a licence choice rather than something the person at the keyboard
# picks during Setup.
function Select-DefaultEditions {
    param(
        [Parameter(Mandatory)][object[]]$Images,
        [switch]$ServerMedia
    )

    # Shorter names sort first, so a base edition beats its "N" and "Single Language" variants.
    $Ranked = @($Images |
            Sort-Object @{ Expression = { Get-EditionRank $_.ImageName }; Descending = $true },
            @{ Expression = { "$($_.ImageName)".Length } },
            @{ Expression = { [int]$_.ImageIndex } })
    if ($Ranked.Count -eq 0) { return @() }

    $Keep = New-Object System.Collections.Generic.List[object]
    if ($ServerMedia) {
        [void]$Keep.Add($Ranked[0])
    }
    else {
        # Highest tier first, so the top edition lands at index 1 after the re-export renumbers the image
        # and an answer file selecting by /IMAGE/INDEX still gets the edition it used to.
        foreach ($Tier in '(?i)enterprise', '(?i)pro', '(?i)home|core|famille') {
            $Best = $Ranked |
                Where-Object { "$($_.ImageName)" -match $Tier -and "$($_.ImageName)" -notmatch '(?i)education|workstation' } |
                Where-Object { $Keep.ImageIndex -notcontains [int]$_.ImageIndex } |
                Select-Object -First 1
            if ($Best) { [void]$Keep.Add($Best) }
        }
        # Media carrying none of the three (an Education- or LTSC-only build under another name) still
        # needs something to service.
        if ($Keep.Count -eq 0) { [void]$Keep.Add($Ranked[0]) }
    }
    return @($Keep | ForEach-Object { [int]$_.ImageIndex })
}

# Shortens a WIM edition name ("Windows 11 Pro") to the tag used in the output ISO file name.
function Get-EditionShortName {
    param([string]$Name)
    $n = "$Name".ToLower()
    # Server names carry no "Server Core" marker: the bare name IS Server Core, the other is the GUI.
    if ($n -match 'datacenter|standard') {
        # Not "DC", which reads as domain controller on a file called WinSrv2025_DC_x64.
        if ($n -match 'datacenter') { return 'Dtc' } else { return 'Std' }
    }
    # LTSC names all contain "enterprise" too, so this has to run before the plain Enterprise match below.
    if ($n -match 'ltsc') {
        if ($n -match 'iot') { return 'IoTLTSC' } else { return 'LTSC' }
    }
    if ($n -match 'enterprise') { return 'Ent' }
    if ($n -match 'education') { return 'Edu' }
    if ($n -match 'pro') { return 'Pro' }
    if ($n -match 'home|core|famille') { return 'Home' } # Famille is the French localized name for Home
    $Short = ($Name -replace '(?i)^\s*windows\s*\d+\s*', '') -replace '[^A-Za-z0-9]', ''
    if ($Short) { return $Short } else { return 'Windows' }
}

# Builds the default output ISO name, e.g. Win11_Pro_x64_enGB_26100.4061_20260815-1332.iso. The build/UBR
# comes from the serviced image when available (that is the only place the post-update revision is known),
# otherwise from the source image's version. Multiple kept editions are joined into a compound tag such as EntPro or StdDtc.
function Get-DefaultIsoName {
    param(
        [object[]]$Images,
        [int[]]$Indexes,
        [string]$BuildString,
        [string]$FallbackVersion,
        [string]$Architecture,
        [string]$Locale
    )

    $Kept = @($Images | Where-Object { $Indexes -contains [int]$_.ImageIndex })
    $Tags = @($Kept | ForEach-Object { Get-EditionShortName $_.ImageName } | Select-Object -Unique)
    $EditionTag = if ($Tags.Count -eq 1) { $Tags[0] } elseif ($Tags.Count -gt 1) { $Tags -join '' } else { 'Windows' }

    $BuildUbr = $null
    foreach ($Candidate in @($BuildString, $FallbackVersion)) {
        if ("$Candidate" -match '\b\d+\.\d+\.(\d+)\.(\d+)') { $BuildUbr = "$($Matches[1]).$($Matches[2])"; break }
    }
    $BuildNumber = if ("$BuildUbr" -match '^(\d+)') { [int]$Matches[1] } else { 0 }
    $WindowsTag =
        if ($script:EffectiveServer) { Get-ServerReleaseName -Build $BuildNumber }
        elseif ($BuildNumber -ge 22000) { 'Win11' }
        elseif ($BuildNumber -gt 0) { 'Win10' }
        else { 'Windows' }

    $Parts = @($WindowsTag, $EditionTag)
    if ($Architecture) { $Parts += ($Architecture -replace '[^A-Za-z0-9]', '') }
    if ($Locale) { $Parts += ($Locale -replace '[^A-Za-z0-9]', '') }
    if ($BuildUbr) { $Parts += $BuildUbr }
    $Parts += (Get-Date -Format 'yyyyMMdd-HHmm')
    return (($Parts -join '_') + '.iso')
}

# Builds the ISO's volume label from the generated file name, so the media describes itself the same way
# the file does. oscdimg writes no label unless -l is passed, and unlabelled media turns up as a generic
# "DVD_ROM" in File Explorer and in the Rufus volume label box.
function Get-IsoVolumeLabel {
    param(
        [Parameter(Mandatory)][string]$IsoFileName,
        [string]$Locale
    )

    # Windows shows 32 characters, and only A-Z, 0-9 and underscore survive every reader, so the build
    # timestamp is dropped (the label describes contents, not when it was made) and the rest is folded.
    $MaxLength = 32
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($IsoFileName) -replace '_\d{8}-\d{4}$', ''
    $Label = ($Base.ToUpperInvariant() -replace '[^A-Z0-9]', '_') -replace '_+', '_'
    # A free-form locale tag (unlike the fixed architecture set) can't be matched by pattern, so the exact
    # value that went into the file name is passed in here to find and drop it.
    $LocaleTag = if ($Locale) { ($Locale -replace '[^A-Za-z0-9]', '').ToUpperInvariant() } else { $null }

    # Too long drops the architecture tag, then the locale tag (neither changes the release or the build,
    # the two things worth reading off a USB stick), then shortens the edition, so those two always survive.
    if ($Label.Length -gt $MaxLength) { $Label = $Label -replace '_(X64|X86|ARM64|AMD64)_', '_' }
    if ($Label.Length -gt $MaxLength -and $LocaleTag) { $Label = $Label -replace "_$([regex]::Escape($LocaleTag))_", '_' }
    if ($Label.Length -gt $MaxLength -and $Label -match '^([A-Z0-9]+)_([A-Z0-9]+)_(.+)$') {
        $Room = $MaxLength - ($Matches[1].Length + $Matches[3].Length + 2)
        if ($Room -ge 3) {
            $Label = '{0}_{1}_{2}' -f $Matches[1], $Matches[2].Substring(0, [Math]::Min($Matches[2].Length, $Room)), $Matches[3]
        }
    }
    if ($Label.Length -gt $MaxLength) { $Label = $Label.Substring(0, $MaxLength) }
    return $Label.Trim('_')
}
#endregion

