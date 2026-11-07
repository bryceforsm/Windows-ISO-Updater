#region List editions and exit (-ListEditions)
# Mount the ISO (no full extraction needed) just to read the editions inside install.wim/esd, print them,
# then dismount and exit. Handy for picking -Edition / -KeepEditions values before a full build.
if ($ListEditions) {
    $ListMount = $null
    try {
        $ListMount = Mount-DiskImage -ImagePath $ResolvedIso -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        $ListDrive = ($ListMount | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
        if (-not $ListDrive) { $ListDrive = (Get-DiskImage -ImagePath $ResolvedIso | Get-Volume -ErrorAction SilentlyContinue).DriveLetter }
        if (-not $ListDrive) { throw 'Could not determine the drive letter of the mounted ISO.' }

        $ListImg = "$($ListDrive):\sources\install.wim"
        if (-not (Test-Path -LiteralPath $ListImg)) { $ListImg = "$($ListDrive):\sources\install.esd" }
        if (-not (Test-Path -LiteralPath $ListImg)) { throw 'No install.wim or install.esd was found on the ISO.' }

        Write-HostTimestamp "Editions inside $(Split-Path -Leaf $ListImg):" -ForegroundColor Cyan
        Get-WindowsImage -ImagePath $ListImg -ErrorAction Stop | ForEach-Object {
            Write-HostLog ("    [{0}] {1}" -f $_.ImageIndex, $_.ImageName)
        }
        Write-Host ''
        Write-HostLog 'Use these with -Edition (which to service) or -KeepEditions (which to keep in the final ISO).'
        Write-HostLog 'Example: -KeepEditions "Windows 11 Pro","Windows 11 Home"   or   -KeepEditions 6,1'
    }
    catch {
        Write-HostTimestamp "Could not list the editions: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($ListMount) { Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null }
    }
    Write-Host $LineBreak
    Stop-Transcript | Out-Null
    exit 0
}

#endregion

#region Build only the recovery ISO and exit (-RecoveryIsoOnly)
# A recovery ISO needs only the recovery image and the media's boot files, so the ISO is read in place
# rather than extracted, install.wim is never serviced, and the run ends here.
if ($RecoveryIsoOnly) {
    $RecoveryExit = 1
    $RecoveryMountedIso = $false
    $RecoveryBootManagers = Join-Path -Path $RecoveryMediaDir -ChildPath 'BootManagers'
    $script:RecoveryWinRe = $null
    $script:RecoveryIsoOutput = $null
    try {
        $Attached = Get-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue
        if (-not ($Attached -and $Attached.Attached)) {
            Mount-DiskImage -ImagePath $ResolvedIso -ErrorAction Stop | Out-Null
            $RecoveryMountedIso = $true
            Start-Sleep -Seconds 2
        }
        $IsoDrive = (Get-DiskImage -ImagePath $ResolvedIso | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
        if (-not $IsoDrive) { throw 'Could not determine the drive letter of the mounted ISO.' }
        $MediaRoot = "$($IsoDrive):\"
        $SourceImage = Join-Path -Path $MediaRoot -ChildPath 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $SourceImage)) { $SourceImage = Join-Path -Path $MediaRoot -ChildPath 'sources\install.esd' }
        if (-not (Test-Path -LiteralPath $SourceImage)) { throw 'The ISO has no sources\install.wim or install.esd, so it is not Windows installation media.' }

        $ImageInfo = Get-WindowsImage -ImagePath $SourceImage -Index 1 -ErrorAction Stop
        $ImageBuild = if ("$($ImageInfo.Version)" -match '^\d+\.\d+\.(\d+)') { [int]$Matches[1] } else { 0 }
        $script:EffectiveServer = "$($ImageInfo.ImageName) $($ImageInfo.EditionId)" -match '(?i)server'
        if (-not $script:EffectiveServer -and $ImageBuild -gt 0) {
            $script:EffectiveWindowsVersion = if ($ImageBuild -ge 22000) { '11' } else { '10' }
        }
        $ImageArch = switch ($ImageInfo.Architecture) { 0 { 'x86' } 9 { 'x64' } 12 { 'arm64' } default { $WinInfo.Architecture } }
        $CatalogArch = switch ($ImageArch) { 'arm64' { 'ARM64' } 'x86' { 'x86' } default { 'x64' } }
        $RecoverySkipUpdate = $SkipUpdates -or $SkipServicing -or $SkipWinRE -or $ImageBuild -lt 10240
        Write-HostTimestamp "Image          : $($ImageInfo.ImageName), $($ImageInfo.Version), $ImageArch"
        Write-Host $LineBreak
        New-Item -ItemType Directory -Path $RecoveryMediaDir -Force -ErrorAction Stop | Out-Null

        Invoke-Task -Description 'Copying the recovery image out of the ISO...' -ScriptBlock {
            $MountSource = $SourceImage
            # DISM cannot mount an .esd. Every edition carries the same recovery image, so converting one is enough.
            if ($SourceImage -like '*.esd') {
                $MountSource = Join-Path -Path $RecoveryMediaDir -ChildPath 'install.wim'
                Write-HostTimestamp '  The media uses install.esd, so one edition is converted to a WIM first...'
                Export-WimImage -SourceImagePath $SourceImage -SourceIndex 1 -DestinationImagePath $MountSource -CompressionType Fast
            }
            $script:RecoveryFeatureName = if ($RecoverySkipUpdate) { $null } else { Resolve-FeatureUpdateName -Build $ImageBuild -WimPath $MountSource }
            $Staged = Join-Path -Path $RecoveryMediaDir -ChildPath 'winre.wim'
            try {
                Reset-MountDirectory -Path $MountDir -ImagePath $MountSource
                Mount-WindowsImage -ImagePath $MountSource -Index 1 -Path $MountDir -ReadOnly -ErrorAction Stop | Out-Null
                $Source = Join-Path -Path $MountDir -ChildPath 'Windows\System32\Recovery\winre.wim'
                if (-not (Test-Path -LiteralPath $Source)) { throw 'the image carries no Windows\System32\Recovery\winre.wim' }
                Copy-Item -LiteralPath $Source -Destination $Staged -Force -ErrorAction Stop
                # It is mounted read-write further down, so it cannot keep a read-only attribute from the media.
                Set-ItemProperty -LiteralPath $Staged -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                $script:RecoveryWinRe = $Staged
            }
            finally {
                Dismount-ImageDiscard -Path $MountDir | Out-Null
                if (-not (Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $MountDir.TrimEnd('\') })) {
                    Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                if ($MountSource -ne $SourceImage) { Remove-Item -LiteralPath $MountSource -Force -ErrorAction SilentlyContinue }
            }
            $Re = Get-WinReVersion -WinReWim $Staged
            Write-HostTimestamp "  Copied the recovery image$(if ($Re) { " ($($Re.Version))" })." -ForegroundColor Green
        }

        if ($RecoverySkipUpdate) {
            Write-HostTimestamp 'The recovery image is used as the media shipped it, without the Safe OS Dynamic Update.' -ForegroundColor Yellow
            Write-Host $LineBreak
        }
        elseif ($script:EffectiveServer -and -not $script:RecoveryFeatureName) {
            # Without the release name the Server query matches every Server release, the same trap a full build stops on.
            Write-HostTimestamp "No release name is known for Server build $ImageBuild, so no catalog query can find its Safe OS Dynamic Update. The recovery image is used as the media shipped it." -ForegroundColor Yellow
            Write-Host $LineBreak
        }
        else {
            Invoke-Task -Description 'Looking for a Safe OS Dynamic Update for the recovery image...' -ScriptBlock {
                $Product = Get-CatalogProductQuery -FeatureUpdate $script:RecoveryFeatureName
                # Bounded by the cumulative update's date as in a full build, offline cap included, so both modes pick the same package.
                $Cap = @{}
                $Cutoff = Get-OfflineLcuCutoff -Build $ImageBuild
                if ($Cutoff) { $Cap.NotAfter = $Cutoff }
                $Lcu = Get-CatalogLatestEntry -Query "Cumulative Update for $Product for $CatalogArch-based Systems" -TitleInclude '(?i)cumulative update (preview )?for (windows|microsoft server operating system)' -TitleExclude (Get-LcuTitleExclude) -AllowPreview:$IncludePreview @Cap
                $SafeOsArgs = Get-DynamicUpdateSearch -Product $Product -CatalogArch $CatalogArch
                $SafeOsArgs.DownloadDir = $DlDir
                $SafeOsArgs.DynamicUpdateKind = 'SafeOS'
                $SafeOsArgs.AllowPreview = $IncludePreview
                if ($Lcu -and $Lcu.LastUpdated) { $SafeOsArgs.NotAfter = $Lcu.LastUpdated }
                $script:SafeOs = Get-LatestCatalogPackage @SafeOsArgs
                if (-not $script:SafeOs) {
                    Write-HostTimestamp '  No Safe OS Dynamic Update was found, so the recovery image is used as the media shipped it.' -ForegroundColor Yellow
                }
            }

            if ($script:SafeOs) {
                Invoke-Task -Description 'Applying the Safe OS Dynamic Update to the recovery image...' -ScriptBlock {
                    $SafeOsKb = if ((Split-Path -Leaf "$(@($script:SafeOs)[-1])") -match '(?i)kb(\d{6,})') { $Matches[1] } else { $null }
                    if (-not $ReapplyUpdates -and (Test-WinReAlreadyCurrent -WinReWim $script:RecoveryWinRe -KbNumber $SafeOsKb)) { return }
                    $WinReMount = Join-Path -Path $WorkRoot -ChildPath 'WinREMount'
                    Reset-MountDirectory -Path $WinReMount -ImagePath $script:RecoveryWinRe
                    try {
                        Mount-WindowsImage -ImagePath $script:RecoveryWinRe -Index 1 -Path $WinReMount -ErrorAction Stop | Out-Null
                        $script:ImageUnserviceable = $false
                        Add-UpdateGroup -MountDir $WinReMount -Group @($script:SafeOs) -Label 'Safe OS Dynamic Update' | Out-Null
                        if ($script:ImageUnserviceable) { throw 'DISM reports the recovery image can no longer be serviced, so it was discarded' }
                        Write-HostTimestamp '      Cleaning up the recovery image component store (/StartComponentCleanup /ResetBase)...'
                        Invoke-Dism -ArgumentList "/Image:$WinReMount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase' | Out-Null
                        New-Item -ItemType Directory -Path $RecoveryBootManagers -Force -ErrorAction Stop | Out-Null
                        foreach ($Name in 'bootmgfw.efi', 'bootmgr.efi') {
                            $From = Join-Path -Path $WinReMount -ChildPath "Windows\Boot\EFI\$Name"
                            if (Test-Path -LiteralPath $From) { Copy-Item -LiteralPath $From -Destination $RecoveryBootManagers -Force -ErrorAction Stop }
                        }
                        Save-MountedImage -Path $WinReMount -Indent 28
                        $Re = Get-WinReVersion -WinReWim $script:RecoveryWinRe
                        if ($Re) { Write-HostTimestamp "  The recovery image is now at $($Re.Version)." -ForegroundColor Green }
                    }
                    catch {
                        # Not fatal, the recovery image the media shipped still makes a working recovery ISO.
                        Write-HostTimestamp "  The recovery image could not be serviced: $($_.Exception.Message). It is used as the media shipped it." -ForegroundColor Yellow
                        Dismount-ImageDiscard -Path $WinReMount | Out-Null
                        Remove-Item -LiteralPath $RecoveryBootManagers -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    finally {
                        if (-not (Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $WinReMount.TrimEnd('\') })) {
                            Remove-Item -LiteralPath $WinReMount -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        }

        Invoke-Task -Description 'Building the recovery ISO...' -ScriptBlock {
            $BootManagers = if (Test-Path -LiteralPath $RecoveryBootManagers) { $RecoveryBootManagers } else { $null }
            $script:RecoveryIsoOutput = New-RecoveryIso -WinReWim $script:RecoveryWinRe -BootSource $MediaRoot -BootManagerDir $BootManagers -Build $ImageBuild -Architecture $ImageArch
        }
        if ($AutoClean) {
            Invoke-Task -Description 'Cleaning up old recovery ISOs (-AutoClean)...' -ScriptBlock {
                Remove-StaleRecoveryIso -Directory $RecoveryIsoDir -KeepCount $KeepIsoCount -Protected @($script:RecoveryIsoOutput) | Out-Null
            }
        }
        $RecoveryExit = 0
    }
    catch {
        Write-HostTimestamp "The recovery ISO could not be built: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($RecoveryMountedIso) { Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null }
        Remove-Item -LiteralPath $RecoveryMediaDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-HostTimestamp "Total run time: $(Format-Duration ((Get-Date) - $script:ScriptStartTime))" -ForegroundColor Cyan
    if ($RecoveryExit -eq 0) {
        Write-HostTimestamp 'Done. Your recovery ISO is ready:' -ForegroundColor Green
        Write-HostTimestamp "  $script:RecoveryIsoOutput" -ForegroundColor Green
        Write-HostLog 'Boot it, or a USB stick written from it, and it opens straight to the Windows Recovery Environment.'
    }
    Write-Host $LineBreak
    if (-not $Unattended -and -not $SkipInteractive) {
        Read-Host -Prompt 'Press enter to exit'
    }
    Stop-Transcript | Out-Null
    exit $RecoveryExit
}

#endregion

#region Has anything actually changed? (build stamp check)
# A full build is an hour or more of disk and CPU, so before any of it starts this run is compared with
# the stamp the last successful build left behind: the source ISO's hash, the build-affecting parameters,
# and the newest packages the Microsoft Update Catalog is offering. If all of those still match and last
# run's ISO is still on disk, there is nothing to gain from doing it again.
$script:StampSourceHash    = $null
$script:ExpectedUpdateSet  = $null
$script:ExpectedUpdateFor  = $null
$script:StampUpdateFiles   = @()
if (-not $NoStamp) {
    Invoke-Task -Description 'Checking the build stamp to see whether anything has changed...' -ScriptBlock {
        $script:PreviousStamp = Get-PreviousBuildStamp
        $script:StampSourceHash = Get-SourceIsoHash -Path $ResolvedIso -Stamp $script:PreviousStamp

        # The catalog queries need the feature update and architecture of the image, and reading those
        # means extracting the ISO - the very thing we are trying to avoid. The last stamp already knows
        # them, and they cannot change while the source ISO's hash stays the same.
        if ($script:PreviousStamp -and $script:PreviousStamp.Image) {
            $StampFeature = "$($script:PreviousStamp.Image.FeatureUpdate)"
            $StampArch    = "$($script:PreviousStamp.Image.CatalogArch)"
            # Same correction as below, taken from the last stamp's recorded build instead of a mount,
            # since that is the whole point of this pre-extraction check.
            $StampBuild = if ($script:PreviousStamp.Image.Build) { [int]$script:PreviousStamp.Image.Build } else { 0 }
            if (-not $script:EffectiveServer) {
                $script:EffectiveWindowsVersion = if ($StampBuild -ge 22000) { '11' } elseif ($StampBuild -gt 0) { '10' } else { $WindowsVersion }
            }
            $script:ExpectedUpdateSet = Get-ExpectedUpdateSet -FeatureName $StampFeature -CatalogArch $StampArch -Build $StampBuild
            $script:ExpectedUpdateFor = "$StampFeature|$StampArch"

            # Says out loud that the catalog really was queried - a run that finishes in a second
            # otherwise looks like it only compared local files and never asked Microsoft anything.
            if ($script:ExpectedUpdateSet -and -not $SkipUpdates -and -not $SkipServicing -and -not $UpdatePath) {
                $Listed = @($script:ExpectedUpdateSet | ForEach-Object { $_ -replace '^(\w+)=(.+)@(.+)$', '$1 $2 (published $3)' })
                Write-HostTimestamp "  The Microsoft Update Catalog was checked for $(Get-CatalogProductQuery -FeatureUpdate $StampFeature) $StampArch, newest available:" -ForegroundColor DarkGray
                foreach ($Item in $Listed) { Write-HostTimestamp "    $Item" -ForegroundColor DarkGray }
            }
        }

        $script:StampDecision = Test-RebuildNeeded -Stamp $script:PreviousStamp -SourceHash $script:StampSourceHash `
            -ParameterSet (Get-BuildParameterSet) -ExpectedUpdates $script:ExpectedUpdateSet
        foreach ($Reason in $script:StampDecision.Reasons) { Write-HostTimestamp "  - $Reason" }
        if (-not $script:StampDecision.Rebuild) { Write-HostTimestamp '  Everything matches the last build.' -ForegroundColor Green }
    }

    if ($CheckOnly) {
        if ($script:StampDecision.Rebuild) {
            Write-HostTimestamp 'A rebuild is needed (exit code 10).' -ForegroundColor Yellow
            Stop-Transcript | Out-Null
            exit 10
        }
        Write-HostTimestamp 'Nothing has changed, so no rebuild is needed (exit code 0).' -ForegroundColor Green
        Stop-Transcript | Out-Null
        exit 0
    }

    if (-not $script:StampDecision.Rebuild) {
        if ($Force) {
            Write-HostTimestamp 'Nothing has changed since the last build, but -Force was specified - building anyway.' -ForegroundColor Yellow
        }
        else {
            Write-HostTimestamp 'Nothing has changed since the last build, so this run has nothing to do.' -ForegroundColor Green
            if ($script:PreviousStamp -and $script:PreviousStamp.Output) {
                Write-HostTimestamp "The ISO from that build is still current: $($script:PreviousStamp.Output.Path)" -ForegroundColor Green
            }
            Write-HostTimestamp 'Use -Force to build anyway.' -ForegroundColor DarkGray
            if ($AutoClean) {
                Invoke-Task -Description 'Cleaning up old downloads and ISOs (-AutoClean)...' -ScriptBlock {
                    Invoke-AutoClean -CurrentStamp $script:PreviousStamp -History (Get-BuildStampHistory) -KeepIsoCount $KeepIsoCount -Protected @($ResolvedIso)
                }
            }
            else { Write-Host $LineBreak }
            Stop-Transcript | Out-Null
            exit 0
        }
    }
    Write-Host $LineBreak
}
elseif ($CheckOnly) {
    Write-HostTimestamp '-CheckOnly needs the build stamps to compare against, but -NoStamp turned them off. Assuming a rebuild is needed (exit code 10).' -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    exit 10
}

#endregion
