#region Image inspection and final report
# Unloads a hive `reg.exe load`-ed by Get-MountedImageBuild/Get-MountedImageLocale, retrying once because
# the handle release can be delayed rather than permanent. Warns loudly instead of failing silently,
# because a hive left loaded under the host's HKLM at commit time ships an orphaned GUID key in the ISO.
function Dismount-RegistryHive {
    param([Parameter(Mandatory)][string]$Hive)

    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    & reg.exe unload $Hive *> $null
    if ($LASTEXITCODE -eq 0) { return }

    Write-HostTimestamp "    $Hive did not unload on the first try. Waiting for the handle to clear before retrying..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    & reg.exe unload $Hive *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-HostTimestamp "    $Hive is still loaded under the host's HKLM and could not be released. Do not commit the mount until this hive is confirmed unloaded, or the ISO ships an orphaned hive-mount key." -ForegroundColor Red
    }
}

# Reads the exact build (with UBR) out of an ALREADY-MOUNTED image's offline SOFTWARE hive.
# Returns a version string, or $null if the hive could not be read.
function Get-MountedImageBuild {
    param([Parameter(Mandatory)][string]$MountPath)

    $Hive = 'HKLM\WISO_BUILD'
    $SoftwareHive = Join-Path $MountPath 'Windows\System32\config\SOFTWARE'
    if (-not (Test-Path -LiteralPath $SoftwareHive)) { return $null }
    try {
        & reg.exe load $Hive $SoftwareHive *> $null
        if ($LASTEXITCODE -ne 0) { return $null }
        try {
            $Cv = Get-ItemProperty -Path "Registry::$Hive\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            return "10.0.$($Cv.CurrentBuildNumber).$($Cv.UBR)$(if ($Cv.DisplayVersion) { " ($($Cv.DisplayVersion))" })"
        }
        finally {
            Dismount-RegistryHive -Hive $Hive
        }
    }
    catch { return $null }
}

# Reads the shipped display language out of an ALREADY-MOUNTED image's offline DEFAULT user hive
# (Control Panel\International\LocaleName), the same source HKEY_USERS\.DEFAULT exposes live.
# Returns a culture name such as "en-US", or $null if the hive could not be read.
function Get-MountedImageLocale {
    param([Parameter(Mandatory)][string]$MountPath)

    $Hive = 'HKLM\WISO_LOCALE'
    $DefaultHive = Join-Path $MountPath 'Windows\System32\config\default'
    if (-not (Test-Path -LiteralPath $DefaultHive)) { return $null }
    try {
        & reg.exe load $Hive $DefaultHive *> $null
        if ($LASTEXITCODE -ne 0) { return $null }
        try {
            $Intl = Get-ItemProperty -Path "Registry::$Hive\Control Panel\International" -ErrorAction Stop
            if (-not $Intl.LocaleName) { return $null }
            return $Intl.LocaleName
        }
        finally {
            Dismount-RegistryHive -Hive $Hive
        }
    }
    catch { return $null }
}

# Mounts a WIM read-only just long enough to read its true build/UBR, because the WIM header's SPBuild is
# stale on some Microsoft media and the SOFTWARE hive is the only trustworthy source. Costs a few minutes.
# Returns a version string, or $null if it could not be read.
function Get-WimBuildViaMount {
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [int]$Index = 1
    )

    # Every caller runs before servicing, so the answer cannot change within a run and one mount covers them all.
    $CacheKey = "$WimPath|$Index"
    if ($script:WimBuildCache.ContainsKey($CacheKey)) { return $script:WimBuildCache[$CacheKey] }

    $Mnt = Join-Path -Path $WorkRoot -ChildPath 'BuildCheck'
    $Build = $null
    try {
        Reset-MountDirectory -Path $Mnt -ImagePath $WimPath
        Mount-WindowsImage -ImagePath $WimPath -Index $Index -Path $Mnt -ReadOnly -ErrorAction Stop | Out-Null
        $Build = Get-MountedImageBuild -MountPath $Mnt
    }
    catch { }
    finally {
        Dismount-ImageDiscard -Path $Mnt | Out-Null
        # Removing a directory DISM still tracks as mounted is what orphans a mount point, so leave it
        # alone if the discard above did not take.
        if (-not (Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $Mnt.TrimEnd('\') })) {
            Remove-Item -LiteralPath $Mnt -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:WimBuildCache[$CacheKey] = $Build
    return $Build
}

# Reports the editions (indexes) inside the finished install.wim and the exact OS build. The build number
# (including the revision/UBR set by the cumulative update) isn't stored in the WIM header, so it comes from
# the image's offline SOFTWARE hive - reusing the value captured during servicing, or mounting read-only if
# there is none (mounting a finished image, especially a recovery-compressed .esd, costs several minutes).
function Show-FinalImageInfo {
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [string]$FallbackBuildString = ''
    )

    $Images = $null
    try { $Images = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop) } catch { }
    if (-not $Images -or $Images.Count -eq 0) {
        Write-HostTimestamp '  Could not read the final image information.' -ForegroundColor DarkGray
        return
    }

    Write-HostTimestamp 'Editions (indexes) in the final ISO:' -ForegroundColor Cyan
    foreach ($Img in $Images) { Write-HostLog ("    [{0}] {1}" -f $Img.ImageIndex, $Img.ImageName) }

    # Read the exact build (with UBR) from the first index's SOFTWARE hive.
    $BuildStr = if ($script:FinalBuildString) { $script:FinalBuildString }
                elseif ($FallbackBuildString) { $FallbackBuildString }
                else { $null }

    if ($BuildStr) { Write-HostTimestamp "Final OS build: $BuildStr" -ForegroundColor Cyan }
    else { Write-HostTimestamp "Final OS build: $($Images[0].Version) (revision unavailable)" -ForegroundColor Cyan }

    # Same offline-read-else-media-language fallback already used for the ISO name and tattoo.
    $LocaleStr = if ($script:FinalImageLocale) { $script:FinalImageLocale }
                 elseif ($script:MediaLanguage) { "$script:MediaLanguage (media language, offline read unavailable)" }
                 else { 'unknown' }
    Write-HostTimestamp "Image locale  : $LocaleStr" -ForegroundColor Cyan
}

# Records how big an image is at this moment. The first sample under a label is kept as the starting size
# and every later one replaces the finishing size, so a caller never has to know which stage it is in.
function Add-WimSizeSample {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )

    $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $Item) { return }
    $Entry = $script:WimSizes | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
    if ($Entry) {
        $Entry.After     = $Item.Length
        $Entry.AfterName = $Item.Name
        return
    }
    $script:WimSizes.Add([pscustomobject]@{
        Label      = $Label
        BeforeName = $Item.Name
        AfterName  = $Item.Name
        Before     = $Item.Length
        After      = $Item.Length
    })
}

# Shows what servicing did to the size of each image. Growth is the normal outcome and not a problem: a
# cumulative update adds more than /StartComponentCleanup /ResetBase and the re-export can take back.
function Show-WimSizeComparison {
    if ($script:WimSizes.Count -eq 0) { return }

    $Rows = @(foreach ($Wim in $script:WimSizes) {
        # -CompressEsd renames install.wim on the way out, so show both names rather than a misleading one.
        $Name = if ($Wim.AfterName -ne $Wim.BeforeName) { "$($Wim.Label) -> $($Wim.AfterName)" } else { $Wim.Label }
        [pscustomobject]@{
            Name   = $Name
            Before = $Wim.Before / 1MB
            After  = $Wim.After / 1MB
            Delta  = ($Wim.After - $Wim.Before) / 1MB
        }
    })
    $Rows += [pscustomobject]@{
        Name   = 'Total'
        Before = ($Rows | Measure-Object -Property Before -Sum).Sum
        After  = ($Rows | Measure-Object -Property After -Sum).Sum
        Delta  = ($Rows | Measure-Object -Property Delta -Sum).Sum
    }

    $NameWidth = ($Rows | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    Write-Host ''
    Write-HostTimestamp 'Image sizes, as extracted and as shipped:' -ForegroundColor Cyan
    foreach ($Row in $Rows) {
        if ($Row.Name -eq 'Total') { Write-HostLog ('  ' + ('-' * ($NameWidth + 42))) }
        $Change = '{0}{1:N0} MB' -f $(if ($Row.Delta -ge 0) { '+' } else { '-' }), [math]::Abs($Row.Delta)
        Write-HostLog ("  {0,-$NameWidth}  {1,9:N0} MB -> {2,9:N0} MB  {3,10}" -f $Row.Name, $Row.Before, $Row.After, $Change)
    }
}

# Records the build of an edition's recovery image. As with the sizes, the first call under a label is
# what it started at and every later one is where it ended up.
function Add-WinReVersionSample {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Version
    )

    if (-not $Version) { return }
    $Entry = $script:WinReVersions | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
    if ($Entry) {
        $Entry.After = $Version
        return
    }
    $script:WinReVersions.Add([pscustomobject]@{ Label = $Label; Before = $Version; After = $Version })
}

# What recovery environment the finished media ships, per edition. Worth stating outright: it is the one
# part of a Windows image that stock media leaves years behind, and nothing else on the ISO records it.
function Show-WinReVersions {
    if ($script:WinReVersions.Count -eq 0) { return }

    $NameWidth = ($script:WinReVersions | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    Write-Host ''
    Write-HostTimestamp 'Recovery image (WinRE) build, per edition:' -ForegroundColor Cyan
    foreach ($Entry in $script:WinReVersions) {
        $Change = if ($Entry.After -ne $Entry.Before) { "$($Entry.Before) -> $($Entry.After)" } else { "$($Entry.After) (unchanged)" }
        Write-HostLog ("  {0,-$NameWidth}  {1}" -f $Entry.Label, $Change)
    }
}

#endregion

