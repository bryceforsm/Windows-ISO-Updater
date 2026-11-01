
$WimCompression = if ($FastCompression) { 'Fast' } else { 'Max' }

#region Extract the ISO to the working folder
$MountedImage = $null
try {
    Invoke-Task -Description "Mounting the ISO to copy its contents: $ResolvedIso ..." -ScriptBlock {
        # If a previous attempt left this ISO mounted, dismount it before mounting again. If that
        # dismount fails (or the image will not release), do NOT proceed on a stale/duplicate mount -
        # throw so the outer catch aborts the whole run.
        $Existing = Get-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue
        if ($Existing -and $Existing.Attached) {
            Write-HostTimestamp '  This ISO is still mounted from a previous attempt - dismounting it first...' -ForegroundColor Yellow
            try {
                Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction Stop | Out-Null
                Start-Sleep -Seconds 2
            }
            catch {
                throw "The ISO is still mounted from a previous attempt and could not be dismounted: $($_.Exception.Message). Aborting."
            }
            if ((Get-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue).Attached) {
                throw 'The ISO is still mounted from a previous attempt and could not be dismounted. Aborting.'
            }
        }
        $script:MountedImage = Mount-DiskImage -ImagePath $ResolvedIso -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
    }
    $MountedImage = $script:MountedImage

    $DriveLetter = ($MountedImage | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    if (-not $DriveLetter) {
        $DriveLetter = (Get-DiskImage -ImagePath $ResolvedIso | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    }
    if (-not $DriveLetter) { throw 'Could not determine the drive letter of the mounted ISO.' }
    Write-HostTimestamp "  ISO mounted at $($DriveLetter):\" -ForegroundColor Green

    if (-not (Test-Path -LiteralPath "$($DriveLetter):\sources\install.wim") -and
        -not (Test-Path -LiteralPath "$($DriveLetter):\sources\install.esd")) {
        throw 'The mounted image has no sources\install.wim or install.esd - this is not a Windows installation ISO.'
    }

    Invoke-Task -Description "Extracting the ISO contents to $ExtractDir ..." -ScriptBlock {
        if (Test-Path $ExtractDir) { Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $ExtractDir -Force -ErrorAction Stop | Out-Null
        # robocopy mirrors the whole media reliably (long paths, retries). /NP keeps the log readable.
        $RoboArgs = @("$($DriveLetter):\", $ExtractDir, '/E', '/COPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
        & robocopy.exe @RoboArgs | Out-Null
        # robocopy exit codes 0-7 indicate success, while 8+ indicates a real failure.
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed to copy the ISO contents (exit code $LASTEXITCODE)." }
        Write-HostTimestamp '  Extraction complete.' -ForegroundColor Green
    }
}
catch {
    Write-HostTimestamp "Could not extract the ISO: $($_.Exception.Message)" -ForegroundColor Red
    if ($MountedImage) { Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null }
    Stop-Transcript | Out-Null
    exit 1
}
finally {
    if ($MountedImage) {
        Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null
        Write-HostTimestamp '  Dismounted the source ISO.' -ForegroundColor DarkGray
    }
}
Write-Host $LineBreak

# The copied wim files inherit the read-only attribute from the optical media, so clear it to let DISM
# mount and commit changes.
Get-ChildItem -Path (Join-Path $ExtractDir 'sources') -Filter '*.wim' -File -ErrorAction SilentlyContinue |
    ForEach-Object { try { Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { } }

$InstallWimExtracted = Join-Path $ExtractDir 'sources\install.wim'
$InstallEsdExtracted = Join-Path $ExtractDir 'sources\install.esd'
$BootWim = Join-Path $ExtractDir 'sources\boot.wim'

# If the media ships install.esd (compressed), convert it to an editable install.wim so DISM can service
# it. Servicing is done against a WIM, and the ESD is a delivery-only format. Only the editions that will
# survive into the final ISO are exported - each one costs several minutes, so exporting the rest just to
# delete them later is wasted time.
$script:EsdPreTrimmed = $false
# The install.wim that gets built here holds only the kept editions, so the ones the source media shipped
# are recorded before the export or nothing downstream can report them.
$script:SourceMediaEditions = @()
$script:SourceMediaDropped = @()
if (-not (Test-Path -LiteralPath $InstallWimExtracted) -and (Test-Path -LiteralPath $InstallEsdExtracted)) {
    Invoke-Task -Description 'The media uses install.esd - converting it to an editable install.wim...' -ScriptBlock {
        $Images = @(Get-WindowsImage -ImagePath $InstallEsdExtracted -ErrorAction Stop)
        $script:SourceMediaEditions = @($Images | ForEach-Object { [ordered]@{ Index = [int]$_.ImageIndex; Name = "$($_.ImageName)" } })
        $Wanted = @($Images.ImageIndex)
        if ($KeepEditions -and $KeepEditions.Count -gt 0) {
            $EsdUnmatched = $null
            $Resolved = @(Resolve-EditionIndexes -Images $Images -Tokens $KeepEditions -Unmatched ([ref]$EsdUnmatched))
            # Anything unmatched is reported (and aborts the run) by the edition resolution further down.
            if ($Resolved.Count -gt 0 -and -not $EsdUnmatched) { $Wanted = $Resolved }
        }
        elseif (-not $KeepAllEditions -and $Images.Count -gt 1) {
            # The edition list is already in hand, so ask it rather than trusting the pre-extraction guess.
            $EsdIsServer = [bool](@($Images | Where-Object { "$($_.ImageName)" -match '(?i)server' }).Count)
            $Wanted = @(Select-DefaultEditions -Images $Images -ServerMedia:$EsdIsServer)
        }

        $Skipped = @($Images | Where-Object { $Wanted -notcontains [int]$_.ImageIndex })
        if ($Skipped.Count -gt 0) {
            Write-HostTimestamp "  Not exporting $($Skipped.Count) edition(s) that would only be removed again: $(($Skipped.ImageName) -join ', ')" -ForegroundColor Yellow
            $script:EsdPreTrimmed = $true
            $script:SourceMediaDropped = @($Skipped | ForEach-Object { "$($_.ImageName)" })
        }
        foreach ($Want in $Wanted) {
            $Img = $Images | Where-Object { [int]$_.ImageIndex -eq [int]$Want } | Select-Object -First 1
            if (-not $Img) { continue }
            Write-HostTimestamp "  Exporting index $($Img.ImageIndex): $($Img.ImageName) ..."
            Export-WindowsImage -SourceImagePath $InstallEsdExtracted -SourceIndex $Img.ImageIndex -DestinationImagePath $InstallWimExtracted -CompressionType $WimCompression -ErrorAction Stop | Out-Null
        }
        Remove-Item -LiteralPath $InstallEsdExtracted -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Conversion complete.' -ForegroundColor Green
    }
}

if (-not (Test-Path -LiteralPath $InstallWimExtracted)) {
    Write-HostTimestamp 'No editable install.wim is present after extraction. Cannot continue.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# The starting sizes for the comparison at the end. Taken after any install.esd conversion, because that
# WIM is the one servicing actually works on.
Add-WimSizeSample -Label 'install.wim' -Path $InstallWimExtracted
Add-WimSizeSample -Label 'boot.wim' -Path $BootWim

#endregion

#region Determine the feature update / architecture from the image (for catalog searches)
$ImageInfo = $null
try { $ImageInfo = Get-WindowsImage -ImagePath $InstallWimExtracted -Index 1 -ErrorAction Stop } catch { }
$script:MediaLanguage = Get-MediaLanguage -ImageInfo $ImageInfo -MediaRoot $ExtractDir
$ImageBuild = 0
if ($ImageInfo -and $ImageInfo.Version -match '^\d+\.\d+\.(\d+)') { $ImageBuild = [int]$Matches[1] }
# The image is the source of truth for Server versus client, the same way catalog queries follow the
# image's own build rather than -WindowsVersion. EditionId is not localised, so this holds on non-English
# media too. Resolved before anything below reads it, because the catalog product name depends on it.
$WasGuessedServer = $script:EffectiveServer
$script:EffectiveServer = "$($ImageInfo.ImageName) $($ImageInfo.EditionId)" -match '(?i)server'
if ($ImageInfo -and $script:EffectiveServer -ne $WasGuessedServer) {
    $Actual = if ($script:EffectiveServer) { 'Windows Server' } else { 'client' }
    Write-HostTimestamp "This is $Actual media: $($ImageInfo.ImageName) (edition '$($ImageInfo.EditionId)'). Continuing as $Actual, since that is what the image actually is." -ForegroundColor Yellow
}
# Catalog searches for client media go by the image's own build, not -WindowsVersion, so an ISO supplied
# with -IsoPath is queried correctly even when -WindowsVersion names the other family or was left default.
if (-not $script:EffectiveServer) {
    $script:EffectiveWindowsVersion = if ($ImageBuild -ge 22000) { '11' } elseif ($ImageBuild -gt 0) { '10' } else { $WindowsVersion }
}
# The WIM header carries the UBR as the "service pack build", so the image's exact patch level is known
# without mounting anything.
$ImageUbr = if ($ImageInfo -and $null -ne $ImageInfo.SPBuild) { [int]$ImageInfo.SPBuild } else { 0 }
# Only the catalog queries need the release name, so a run that is not going to make any is not charged the
# mount it would take to work one out for an unrecognised build.
$FeatureName =
    if (-not $ImageBuild) { $null }
    elseif ($SkipUpdates -or $SkipServicing -or $UpdatePath) { Get-FeatureUpdateName -Build $ImageBuild }
    else { Resolve-FeatureUpdateName -Build $ImageBuild -WimPath $InstallWimExtracted }
$ImageArch = switch ($ImageInfo.Architecture) { 0 { 'x86' } 9 { 'x64' } 12 { 'arm64' } default { $WinInfo.Architecture } }
$CatalogArch = switch ($ImageArch) { 'x64' { 'x64' } 'arm64' { 'ARM64' } 'x86' { 'x86' } default { 'x64' } }

# Version is usually already 4-part (10.0.26200.9168), but is 3-part on some media, so only add the UBR
# when it is missing.
$ImageVersionText = "$($ImageInfo.Version)"
if ($ImageUbr -and $ImageVersionText -match '^\d+\.\d+\.\d+$') { $ImageVersionText = "$ImageVersionText.$ImageUbr" }

Write-HostTimestamp "Image build    : $ImageVersionText$(if ($FeatureName) { " ($FeatureName)" })"
Write-HostTimestamp "Image arch     : $ImageArch"

# DISM on a Windows 10 or later host cannot service a Vista, 7 or 8 era image, and Microsoft never
# published cumulative updates for those releases either, so all that is possible on media that old is a
# straight repack.
if ($ImageBuild -gt 0 -and $ImageBuild -lt 10240) {
    $WillService = ((-not $SkipUpdates) -and (-not $SkipServicing)) -or $DriverPath
    Write-HostTimestamp "This image is build $ImageBuild, older than Windows 10 and Windows Server 2016 (build 10240)." -ForegroundColor $(if ($WillService) { 'Red' } else { 'Yellow' })
    if ($WillService) {
        Write-HostTimestamp '  DISM on this host cannot service an image that old, and the Microsoft Update Catalog has no cumulative update for it, so this run stops here.' -ForegroundColor Red
        Write-HostTimestamp '  Re-run with -SkipUpdates and without -DriverPath to repack the media unchanged, which still applies -UnattendPath, -ExtraFilesPath and the new volume label.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-HostTimestamp '  Nothing will be serviced, so no image is mounted and the media is only repacked.' -ForegroundColor Yellow
}
Write-Host $LineBreak

# The stamp check ran against the feature update/architecture recorded last time (or nothing at all on a
# first run). Now that the image itself has been read, the list of updates recorded in the new stamp is
# refreshed so the next run compares against the right thing.
if (-not $NoStamp -and $script:ExpectedUpdateFor -ne "$FeatureName|$CatalogArch") {
    Invoke-Task -Description 'Checking which updates the Microsoft Update Catalog is offering for this image...' -ScriptBlock {
        $script:ExpectedUpdateSet = Get-ExpectedUpdateSet -FeatureName $FeatureName -CatalogArch $CatalogArch
        $script:ExpectedUpdateFor = "$FeatureName|$CatalogArch"
        if ($script:ExpectedUpdateSet) { Write-HostTimestamp "  $($script:ExpectedUpdateSet -join ', ')" -ForegroundColor DarkGray }
    }
}

#endregion

