#region Resolve which editions to keep and which to service
$InstallImages = @(Get-WindowsImage -ImagePath $InstallWimExtracted -ErrorAction Stop)

# Which editions to KEEP in the final ISO.
#   * -KeepEditions <list>  : keep exactly what the user named (highest precedence).
#   * -KeepAllEditions      : keep every edition in the media.
#   * default               : keep Enterprise, Pro and Home on client media (whichever of them it carries),
#                             or the most upgradeable single edition on Server, to speed up servicing and
#                             shrink the ISO.
$KeepIndexes = @($InstallImages.ImageIndex)
if ($script:EsdPreTrimmed) {
    # The ESD conversion already exported only the editions to keep, and dropping editions renumbers the
    # indexes, so re-resolving the same tokens against this WIM would not line up.
    Write-HostTimestamp "Keeping the $($InstallImages.Count) edition(s) exported from install.esd: $(($InstallImages.ImageName) -join ', ')" -ForegroundColor Cyan
    Write-Host $LineBreak
}
elseif ($KeepEditions -and $KeepEditions.Count -gt 0) {
    $KeepUnmatched = $null
    $KeepIndexes = @(Resolve-EditionIndexes -Images $InstallImages -Tokens $KeepEditions -Unmatched ([ref]$KeepUnmatched))
    if ($KeepIndexes.Count -eq 0) {
        # None of several values matching nothing is almost always a typo in the whole list, not a
        # deliberate "keep nothing", so fall back to every edition rather than a hard exit.
        Write-HostTimestamp "None of these -KeepEditions values matched any edition: $($KeepEditions -join ', '). Keeping all $($InstallImages.Count) editions instead." -ForegroundColor Yellow
        Write-HostTimestamp 'Available editions:' -ForegroundColor Yellow
        $InstallImages | ForEach-Object { Write-HostLog "    [$($_.ImageIndex)] $($_.ImageName)" }
        $KeepIndexes = @($InstallImages.ImageIndex)
        Write-Host $LineBreak
    }
    elseif ($KeepUnmatched -and $KeepUnmatched.Count -gt 0) {
        Write-HostTimestamp "These -KeepEditions values did not match any edition: $($KeepUnmatched -join ', ')" -ForegroundColor Red
        Write-HostTimestamp 'Available editions:' -ForegroundColor Yellow
        $InstallImages | ForEach-Object { Write-HostLog "    [$($_.ImageIndex)] $($_.ImageName)" }
        Stop-Transcript | Out-Null
        exit 1
    }
    else {
        $KeptNames = $InstallImages | Where-Object { $KeepIndexes -contains $_.ImageIndex } | ForEach-Object { $_.ImageName }
        $DroppedNames = $InstallImages | Where-Object { $KeepIndexes -notcontains $_.ImageIndex } | ForEach-Object { $_.ImageName }
        Write-HostTimestamp "Keeping $($KeepIndexes.Count) of $($InstallImages.Count) editions: $($KeptNames -join ', ')" -ForegroundColor Cyan
        if ($DroppedNames) { Write-HostTimestamp "Removing from the ISO: $($DroppedNames -join ', ')" -ForegroundColor Yellow }
        Write-Host $LineBreak
    }
}
elseif ($KeepAllEditions) {
    Write-HostTimestamp "Keeping all $($InstallImages.Count) editions (-KeepAllEditions):" -ForegroundColor Cyan
    $InstallImages | ForEach-Object { Write-HostLog "    [$($_.ImageIndex)] $($_.ImageName)" }
    Write-Host $LineBreak
}
elseif ($InstallImages.Count -gt 1) {
    $KeepIndexes = @(Select-DefaultEditions -Images $InstallImages -ServerMedia:$script:EffectiveServer)
    $KeptNames = $InstallImages | Where-Object { $KeepIndexes -contains [int]$_.ImageIndex } | ForEach-Object { $_.ImageName }
    $DroppedNames = $InstallImages | Where-Object { $KeepIndexes -notcontains [int]$_.ImageIndex } | ForEach-Object { $_.ImageName }
    $EditionRule = if ($script:EffectiveServer) { 'the most upgradeable edition' } elseif ($KeepIndexes.Count -gt 1) { 'the Enterprise, Pro and Home editions the media carries' } else { 'one edition' }
    Write-HostTimestamp "Keeping only $EditionRule to speed up the build: $($KeptNames -join ', '). Use -KeepAllEditions to keep them all, or -KeepEditions to choose." -ForegroundColor Cyan
    if ($script:EffectiveServer) { Write-HostTimestamp '  Standard can be upgraded to Datacenter in place with DISM /Set-Edition, but Datacenter can never be downgraded, so Standard is the safer edition to ship.' -ForegroundColor DarkGray }
    if ($DroppedNames) { Write-HostTimestamp "Removing from the ISO: $($DroppedNames -join ', ')" -ForegroundColor Yellow }
    Write-Host $LineBreak
}
$TrimNeeded = ($KeepIndexes.Count -lt $InstallImages.Count)

# Which of the kept editions to actually service (apply updates to). -Edition narrows this further.
# Index numbers cannot be honoured after an ESD pre-trim renumbered them, so everything kept is serviced.
if ($Edition -eq 'All' -or ($script:EsdPreTrimmed -and $Edition -match '^\d+$')) {
    $ServiceIndexes = $KeepIndexes
}
else {
    $EdUnmatched = $null
    $EdIndexes = @(Resolve-EditionIndexes -Images $InstallImages -Tokens @($Edition) -Unmatched ([ref]$EdUnmatched))
    if ($EdIndexes.Count -eq 0) {
        Write-HostTimestamp "Edition '$Edition' was not found in the image. Available editions:" -ForegroundColor Red
        $InstallImages | ForEach-Object { Write-HostLog "    [$($_.ImageIndex)] $($_.ImageName)" }
        Stop-Transcript | Out-Null
        exit 1
    }
    # Only service editions we are keeping in the final ISO.
    $ServiceIndexes = @($EdIndexes | Where-Object { $KeepIndexes -contains $_ })
}

# Any edition that ships in the ISO but is not serviced installs at the ORIGINAL patch level, so warn.
$UnservicedKept = @($KeepIndexes | Where-Object { $ServiceIndexes -notcontains $_ })
if ($UnservicedKept.Count -gt 0 -and -not $SkipUpdates) {
    $UnservicedNames = $InstallImages | Where-Object { $UnservicedKept -contains [int]$_.ImageIndex } | ForEach-Object { $_.ImageName }
    Write-HostTimestamp "Warning: these editions stay in the ISO but will NOT be updated, so installing them gives an unpatched Windows: $($UnservicedNames -join ', ')" -ForegroundColor Yellow
    Write-HostTimestamp '  Drop -Edition (or add them to -KeepEditions) so every edition left in the ISO is serviced.' -ForegroundColor Yellow
    Write-Host $LineBreak
}

#endregion

#region Service the images
# Drivers alone are reason enough to mount everything, so this runs with no updates to apply too.
if ($UpdateGroups.Count -gt 0 -or $script:DriverInfFiles.Count -gt 0) {
    # Tracks editions whose update set failed to apply, so we can warn loudly at the end.
    $script:ServicingFailures = 0
    # Start from a clean mount directory, discarding any stale mount a previous crashed run left behind.
    Reset-MountDirectory -Path $MountDir -ImagePath $InstallWimExtracted

    # 1) Service install.wim (each targeted edition).
    foreach ($Index in $ServiceIndexes) {
        $EditionName = ($InstallImages | Where-Object { $_.ImageIndex -eq $Index }).ImageName
        Invoke-Task -Description "Servicing install.wim index $Index ($EditionName)..." -ScriptBlock {
            try {
                Reset-MountDirectory -Path $MountDir -ImagePath $InstallWimExtracted
                Write-HostTimestamp '    Mounting the image...'
                Mount-WindowsImage -ImagePath $InstallWimExtracted -Index $Index -Path $MountDir -ErrorAction Stop | Out-Null

                # Per Microsoft, the recovery image inside this edition is patched with the Safe OS Dynamic
                # Update and never with the LCU, so with no Safe OS package there is nothing to mount for.
                $WinReWim = Join-Path $MountDir 'Windows\System32\Recovery\winre.wim'
                $WinReLabel = "winre.wim (inside index $Index, $EditionName)"
                $WinReSizeLabel = "winre.wim (index $Index)"
                $WinReVersionLabel = "[$Index] $EditionName"
                # Read from the WIM header, so which recovery environment this edition carries is on record
                # even when -SkipWinRE means nothing is going to be done about it.
                $WinReBefore = Get-WinReVersion -WinReWim $WinReWim
                if ($WinReBefore) {
                    Add-WinReVersionSample -Label $WinReVersionLabel -Version $WinReBefore.Version
                    Write-HostTimestamp "    The recovery image is at $($WinReBefore.Version)." -ForegroundColor DarkGray
                }

                if (-not $SkipWinRE -and $SafeOsGroup) {
                    if (-not (Test-Path -LiteralPath $WinReWim)) {
                        Write-HostTimestamp '    This edition carries no winre.wim, so there is no recovery image to service.' -ForegroundColor DarkGray
                    }
                    elseif (-not $ReapplyUpdates -and (Test-WinReAlreadyCurrent -WinReWim $WinReWim -KbNumber $script:SafeOsKb -Version $WinReBefore)) {
                        Add-ServicingResult -Image $WinReLabel -Package "KB$($script:SafeOsKb)" -Result 'Skipped' -Detail 'Already at the build this Safe OS Dynamic Update delivers'
                    }
                    else {
                        Add-WimSizeSample -Label $WinReSizeLabel -Path $WinReWim
                        # Seconds spent here buy skipping a whole mount, /ResetBase and re-export below.
                        $WinReSourceHash = Get-Sha256 -Path $WinReWim
                        if (Copy-CachedWinReImage -WinReWim $WinReWim -SourceHash $WinReSourceHash) {
                            Write-HostTimestamp '    This edition ships the recovery image an earlier one was serviced from, so the serviced copy goes straight in.' -ForegroundColor Green
                            Add-ServicingResult -Image $WinReLabel -Package "KB$($script:SafeOsKb)" -Result 'Applied' -Detail 'Reused the recovery image serviced for an earlier edition'
                            Add-WimSizeSample -Label $WinReSizeLabel -Path $WinReWim
                            $WinReAfter = Get-WinReVersion -WinReWim $WinReWim
                            if ($WinReAfter) { Add-WinReVersionSample -Label $WinReVersionLabel -Version $WinReAfter.Version }
                        }
                        else {
                            $WinReMount = Join-Path $WorkRoot 'WinREMount'
                            Reset-MountDirectory -Path $WinReMount -ImagePath $WinReWim
                            try {
                                Set-ItemProperty -LiteralPath $WinReWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                                Write-HostTimestamp '    Servicing the recovery image (winre.wim)...'
                                Mount-WindowsImage -ImagePath $WinReWim -Index 1 -Path $WinReMount -ErrorAction Stop | Out-Null
                                Add-UpdateGroup -MountDir $WinReMount -Group $SafeOsGroup -Label 'Safe OS Dynamic Update' -ImageLabel $WinReLabel | Out-Null
                                Write-HostTimestamp '      Cleaning up the recovery image component store (/StartComponentCleanup /ResetBase)...'
                                Invoke-Dism -ArgumentList "/Image:$WinReMount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase' | Out-Null
                                Remove-ImageResidue -MountDir $WinReMount
                                Save-MountedImage -Path $WinReMount -Indent 28
                                Optimize-WinReImage -WinReWim $WinReWim -ImageLabel $WinReLabel
                                # Read before the edition is committed, since this file only exists while it is mounted.
                                Add-WimSizeSample -Label $WinReSizeLabel -Path $WinReWim
                                $WinReAfter = Get-WinReVersion -WinReWim $WinReWim
                                if ($WinReAfter) {
                                    Add-WinReVersionSample -Label $WinReVersionLabel -Version $WinReAfter.Version
                                    Write-HostTimestamp "      The recovery image is now at $($WinReAfter.Version)." -ForegroundColor Green
                                }
                                Save-ServicedWinReImage -WinReWim $WinReWim -SourceHash $WinReSourceHash
                            }
                            catch {
                                # Deliberately not fatal. A recovery image that will not service must never cost
                                # the user the ISO, so the edition keeps the winre.wim it shipped with.
                                Write-HostTimestamp "      WinRE servicing failed: $($_.Exception.Message). This edition keeps the recovery image it shipped with." -ForegroundColor Yellow
                                Add-ServicingResult -Image $WinReLabel -Package 'Safe OS Dynamic Update' -Result 'Failed' -Detail $_.Exception.Message
                                Dismount-ImageDiscard -Path $WinReMount | Out-Null
                            }
                        }
                    }
                }

                Write-HostTimestamp '    Applying updates to install.wim...'
                $script:InstallApplyOk = $true
                foreach ($Group in $UpdateGroups) {
                    if (-not (Add-UpdateGroup -MountDir $MountDir -Group $Group -ImageLabel "install.wim index $Index ($EditionName)")) { $script:InstallApplyOk = $false }
                }
                if (-not $script:InstallApplyOk) {
                    $script:ServicingFailures++
                    Write-HostTimestamp "    Note: the cumulative update didn't apply to index $Index ($EditionName), so this edition kept its original patch level. The ISO will still build." -ForegroundColor DarkYellow
                }

                # After the updates, so a driver is never superseded by an inbox one the cumulative update brings in.
                Add-ImageDrivers -MountDir $MountDir -InfFiles $script:DriverInfFiles -ImageLabel "install.wim index $Index ($EditionName)" | Out-Null

                if ($UpdateGroups.Count -gt 0) {
                    Write-HostTimestamp '    Cleaning up the component store (/StartComponentCleanup /ResetBase)...'
                    # ResetBase permanently removes superseded components, shrinking the image. This is slow.
                    Invoke-Dism -ArgumentList "/Image:$MountDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase' -Indent 26 | Out-Null
                }

                Remove-ImageResidue -MountDir $MountDir

                # Grabbed here because the image is already mounted, since mounting the finished image later
                # just to read this one value costs several minutes.
                $EditionBuild = Get-MountedImageBuild -MountPath $MountDir
                if ($EditionBuild) { $script:EditionBuilds.Add([ordered]@{ Index = [int]$Index; Edition = "$EditionName"; Build = $EditionBuild }) }
                if (-not $script:FinalBuildString) { $script:FinalBuildString = $EditionBuild }
                if (-not $script:FinalImageLocale) { $script:FinalImageLocale = Get-MountedImageLocale -MountPath $MountDir }

                Write-HostTimestamp '    Committing and unmounting...'
                Save-MountedImage -Path $MountDir -Indent 26
                Write-HostTimestamp "    Index $Index done." -ForegroundColor Green
            }
            catch {
                Write-HostTimestamp "    Servicing index $Index failed: $($_.Exception.Message)" -ForegroundColor Red
                Dismount-ImageDiscard -Path $MountDir | Out-Null
            }
        }
    }

    # 2) Apply the Setup Dynamic Update to the media's sources folder. This refreshes the loose Windows
    # Setup binaries, the compatibility database and replacement component manifests. Step 3 then
    # overwrites setup.exe/setuphost.exe from the serviced boot.wim, matching Microsoft's documented order.
    if ($script:SetupDu) {
        Invoke-Task -Description 'Applying the Setup Dynamic Update to the media sources folder...' -ScriptBlock {
            $MediaSources = Join-Path $ExtractDir 'sources'
            Get-ChildItem -LiteralPath $MediaSources -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.IsReadOnly } |
                ForEach-Object { $_.IsReadOnly = $false }
            foreach ($Cab in $script:SetupDu) {
                & "$env:SystemRoot\System32\expand.exe" $Cab '-F:*' $MediaSources | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-HostTimestamp "  expand.exe returned $LASTEXITCODE for $(Split-Path -Leaf $Cab), so the media Setup files were not fully refreshed." -ForegroundColor Yellow
                    Add-ServicingResult -Image 'media sources folder' -Package (Split-Path -Leaf $Cab) -Result 'Failed' -Detail "expand.exe returned $LASTEXITCODE"
                }
                else {
                    Write-HostTimestamp "  Applied $(Split-Path -Leaf $Cab) to sources\." -ForegroundColor Green
                    Add-ServicingResult -Image 'media sources folder' -Package (Split-Path -Leaf $Cab) -Result 'Applied' -Detail 'Setup Dynamic Update'
                }
            }
        }
    }

    # 3) Service boot.wim (Windows Setup / WinPE). Index 2 is the Setup environment, index 1 is WinPE.
    if (Test-Path -LiteralPath $BootWim) {
        Set-ItemProperty -LiteralPath $BootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        # Staging folder for the serviced Setup/boot-manager binaries pulled out of boot.wim index 2.
        $SetupStage = Join-Path -Path $WorkRoot -ChildPath 'SetupFiles'
        if (Test-Path -LiteralPath $SetupStage) { Remove-Item -LiteralPath $SetupStage -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $SetupStage -Force -ErrorAction SilentlyContinue | Out-Null
        $BootImages = Get-WindowsImage -ImagePath $BootWim -ErrorAction SilentlyContinue
        foreach ($BootImg in $BootImages) {
            Invoke-Task -Description "Servicing boot.wim index $($BootImg.ImageIndex) ($($BootImg.ImageName))..." -ScriptBlock {
                try {
                    Reset-MountDirectory -Path $MountDir -ImagePath $BootWim
                    Mount-WindowsImage -ImagePath $BootWim -Index $BootImg.ImageIndex -Path $MountDir -ErrorAction Stop | Out-Null
                    foreach ($Group in $UpdateGroups) { Add-UpdateGroup -MountDir $MountDir -Group $Group -ImageLabel "boot.wim index $($BootImg.ImageIndex) ($($BootImg.ImageName))" | Out-Null }
                    # Only index 2 needs the drivers: that is the image Setup boots into, and it has to see
                    # the disk and the network card. Index 1 is loaded into a RAM disk and never installs.
                    if ([int]$BootImg.ImageIndex -eq 2) {
                        Add-ImageDrivers -MountDir $MountDir -InfFiles $script:DriverInfFiles -ImageLabel "boot.wim index 2 ($($BootImg.ImageName))" | Out-Null
                    }
                    if ($UpdateGroups.Count -gt 0) { Invoke-Dism -ArgumentList "/Image:$MountDir", '/Cleanup-Image', '/StartComponentCleanup' -Indent 26 | Out-Null }
                    Remove-ImageResidue -MountDir $MountDir

                    # Index 2 is the Windows Setup image. The cumulative update raises the version of the
                    # Setup and boot-manager binaries INSIDE this image, so the copies sitting loose on the
                    # media must be replaced with them. If they don't match, Windows Setup fails when it is
                    # launched from the media (e.g. "A media driver your computer needs is missing").
                    if ([int]$BootImg.ImageIndex -eq 2) {
                        Write-HostTimestamp '    Saving the serviced Setup and boot manager files for the media...'
                        $Grab = @(
                            @{ From = 'sources\setup.exe';                To = 'setup.exe';     Required = $true }
                            @{ From = 'sources\setuphost.exe';            To = 'setuphost.exe'; Required = $false } # Windows 11 24H2+
                            @{ From = 'Windows\boot\efi\bootmgfw.efi';    To = 'bootmgfw.efi';  Required = $false }
                            @{ From = 'Windows\boot\efi\bootmgr.efi';     To = 'bootmgr.efi';   Required = $false }
                            @{ From = 'Windows\boot\efi\boot.stl';        To = 'boot.stl';      Required = $false }
                        )
                        foreach ($Item in $Grab) {
                            $Src = Join-Path $MountDir $Item.From
                            if (Test-Path -LiteralPath $Src) {
                                Copy-Item -LiteralPath $Src -Destination (Join-Path $SetupStage $Item.To) -Force -ErrorAction SilentlyContinue
                            }
                            elseif ($Item.Required) {
                                Write-HostTimestamp "      $($Item.From) was not found in boot.wim index 2." -ForegroundColor Yellow
                            }
                        }
                    }

                    Save-MountedImage -Path $MountDir -Indent 26
                    Write-HostTimestamp "    boot.wim index $($BootImg.ImageIndex) done." -ForegroundColor Green
                }
                catch {
                    Write-HostTimestamp "    Servicing boot.wim index $($BootImg.ImageIndex) failed: $($_.Exception.Message)" -ForegroundColor Yellow
                    Dismount-ImageDiscard -Path $MountDir | Out-Null
                }
            }
        }

        # Servicing inflates boot.wim and nothing else reclaims that space, so re-export it.
        if ($BootImages) {
            Invoke-Task -Description 'Re-exporting boot.wim to shrink it...' -ScriptBlock {
                if (-not (Test-RoomForExport -SourceImage $BootWim -Label 'boot.wim')) { return }
                # Staged outside the media folder so a failed export can never be baked into the ISO.
                $TempBoot = Join-Path -Path $WorkRoot -ChildPath 'boot_new.wim'
                try {
                    if (Test-Path -LiteralPath $TempBoot) { Remove-Item -LiteralPath $TempBoot -Force -ErrorAction SilentlyContinue }
                    $BeforeMB = (Get-Item -LiteralPath $BootWim).Length / 1MB
                    foreach ($Img in ($BootImages | Sort-Object ImageIndex)) {
                        # Index 2 (Windows Setup) carries the WIM's bootable flag, and without -Setbootable the ISO will not boot.
                        $Boot = ([int]$Img.ImageIndex -eq 2)
                        Write-HostTimestamp "  Exporting index $($Img.ImageIndex) ($($Img.ImageName))$(if ($Boot) { ' [bootable]' }) ..."
                        Export-WimImage -SourceImagePath $BootWim -SourceIndex $Img.ImageIndex -DestinationImagePath $TempBoot -CompressionType $WimCompression -Setbootable:$Boot
                    }
                    Set-ItemProperty -LiteralPath $BootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $BootWim -Force -ErrorAction Stop
                    Move-Item -LiteralPath $TempBoot -Destination $BootWim -Force -ErrorAction Stop
                    $AfterMB = (Get-Item -LiteralPath $BootWim).Length / 1MB
                    Write-HostTimestamp ('  boot.wim: {0:N0} MB -> {1:N0} MB (saved {2:N0} MB).' -f $BeforeMB, $AfterMB, ($BeforeMB - $AfterMB)) -ForegroundColor Green
                }
                catch {
                    Write-HostTimestamp "  Re-export failed: $($_.Exception.Message). The serviced boot.wim is used as-is." -ForegroundColor Yellow
                    Remove-Item -LiteralPath $TempBoot -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Sampled here rather than inside the re-export, so a boot.wim that was serviced but could not be
        # re-exported still reports the size it is actually shipping at.
        Add-WimSizeSample -Label 'boot.wim' -Path $BootWim

        # Push the serviced binaries onto the media so their versions match the serviced boot.wim.
        Invoke-Task -Description 'Updating the media Setup and boot manager files to match the serviced boot.wim...' -ScriptBlock {
            $StagedSetup = Join-Path $SetupStage 'setup.exe'
            if (-not (Test-Path -LiteralPath $StagedSetup)) {
                Write-HostTimestamp '  No serviced Setup files were captured, so the media files are left as they are.' -ForegroundColor Yellow
                return
            }
            $MediaSources = Join-Path $ExtractDir 'sources'
            foreach ($Name in @('setup.exe', 'setuphost.exe')) {
                $Staged = Join-Path $SetupStage $Name
                if (Test-Path -LiteralPath $Staged) {
                    $Dest = Join-Path $MediaSources $Name
                    if (Test-Path -LiteralPath $Dest) { Set-ItemProperty -LiteralPath $Dest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
                    Copy-Item -LiteralPath $Staged -Destination $Dest -Force -ErrorAction SilentlyContinue
                    Write-HostTimestamp "  Replaced sources\$Name." -ForegroundColor Green
                }
            }

            # The media's boot managers live under several names (bootmgfw.efi, bootx64.efi, ...), each of
            # them the same binary, so every copy is refreshed from the serviced one.
            $StagedMgfw = Join-Path $SetupStage 'bootmgfw.efi'
            $StagedMgr  = Join-Path $SetupStage 'bootmgr.efi'
            foreach ($File in (Get-ChildItem -LiteralPath $ExtractDir -Force -Recurse -Filter 'b*.efi' -ErrorAction SilentlyContinue)) {
                $Source = switch -Regex ($File.Name) {
                    '^(bootmgfw|bootx64|bootia32|bootaa64)\.efi$' { $StagedMgfw }
                    '^bootmgr\.efi$' { $StagedMgr }
                    default { $null }
                }
                if ($Source -and (Test-Path -LiteralPath $Source)) {
                    Set-ItemProperty -LiteralPath $File.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    Copy-Item -LiteralPath $Source -Destination $File.FullName -Force -ErrorAction SilentlyContinue
                    Write-HostTimestamp "  Replaced $($File.FullName.Substring($ExtractDir.Length).TrimStart('\'))." -ForegroundColor Green
                }
            }

            $StagedStl = Join-Path $SetupStage 'boot.stl'
            if (Test-Path -LiteralPath $StagedStl) {
                $StlDest = Join-Path $ExtractDir 'efi\microsoft\boot\boot.stl'
                if (Test-Path -LiteralPath $StlDest) { Set-ItemProperty -LiteralPath $StlDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $StagedStl -Destination $StlDest -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $SetupStage -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4) Re-export install.wim below (outside this block) to reclaim the space freed by the cleanup.
    Remove-Item -LiteralPath $WinReCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-DirectoryForce -Path $MountDir | Out-Null
}

#endregion

#region Capture the recovery image (-RecoveryIsoPath)
# Read back out of install.wim rather than caught mid-servicing, so a run that serviced nothing still has
# one. Done before the re-export, because -CompressEsd turns install.wim into an .esd DISM cannot mount.
$script:RecoveryWinRe = $null
if ($RecoveryIsoPath) {
    Invoke-Task -Description 'Copying the recovery image out of install.wim for the recovery ISO...' -ScriptBlock {
        # A serviced edition carries the serviced recovery image, so one of those is preferred.
        $RecoveryIndex = [int](@($ServiceIndexes) + @($KeepIndexes))[0]
        $Staged = Join-Path -Path $RecoveryMediaDir -ChildPath 'winre.wim'
        try {
            New-Item -ItemType Directory -Path $RecoveryMediaDir -Force -ErrorAction Stop | Out-Null
            Reset-MountDirectory -Path $MountDir -ImagePath $InstallWimExtracted
            Mount-WindowsImage -ImagePath $InstallWimExtracted -Index $RecoveryIndex -Path $MountDir -ReadOnly -ErrorAction Stop | Out-Null
            $Source = Join-Path -Path $MountDir -ChildPath 'Windows\System32\Recovery\winre.wim'
            if (-not (Test-Path -LiteralPath $Source)) {
                Write-HostTimestamp "  Index $RecoveryIndex carries no winre.wim, so there is no recovery image to build an ISO from." -ForegroundColor Yellow
                return
            }
            Copy-Item -LiteralPath $Source -Destination $Staged -Force -ErrorAction Stop
            $script:RecoveryWinRe = $Staged
            $Re = Get-WinReVersion -WinReWim $Staged
            Write-HostTimestamp "  Took the recovery image$(if ($Re) { " ($($Re.Version))" }) from index $RecoveryIndex." -ForegroundColor Green
        }
        catch {
            Write-HostTimestamp "  The recovery image could not be copied out: $($_.Exception.Message). The recovery ISO will be skipped." -ForegroundColor Yellow
        }
        finally {
            Dismount-ImageDiscard -Path $MountDir | Out-Null
            # Removing a folder DISM still tracks as mounted is what orphans a mount, so only an empty one goes.
            if (-not (Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $MountDir.TrimEnd('\') })) {
                Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

#endregion

