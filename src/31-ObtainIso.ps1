#region Interactive confirmation
if ($RecoveryIsoOnly -and -not $Unattended -and -not $SkipInteractive -and -not $ListEditions) {
    Write-HostLog 'This tool builds a recovery ISO that boots straight into the Windows Recovery Environment. It will:'
    if ($IsoPath) { Write-HostLog "  - Use the ISO you provided: $IsoPath" }
    else { Write-HostLog "  - Use the ISO it finds in the download folder: $DlDir" }
    Write-HostLog '  - Read the recovery image out of that ISO without extracting or servicing anything else'
    if (-not ($SkipUpdates -or $SkipServicing -or $SkipWinRE)) {
        Write-HostLog '  - Download the latest Safe OS Dynamic Update from the Microsoft Update Catalog and apply it to the recovery image'
    }
    Write-HostLog "  - Write the recovery ISO to $(if ($RecoveryIsoFile) { $RecoveryIsoFile } else { $RecoveryIsoDir })"
    if ($AutoClean) {
        Write-HostLog "  - DELETE all but the newest $KeepIsoCount generated recovery ISOs in that folder (-AutoClean)" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-HostLog 'This usually takes minutes rather than hours. Nothing on this PC is changed.' -ForegroundColor Yellow
    Write-Host ''
    $Confirm = Read-Host "Type 'Y' to continue, or anything else to cancel"
    if ($Confirm -notin @('Y', 'y', 'Yes', 'yes')) {
        Write-HostTimestamp 'Operation cancelled by user.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 0
    }
    Write-Host $LineBreak
}
if (-not $Unattended -and -not $SkipInteractive -and -not $ListEditions -and -not $CheckOnly -and -not $RecoveryIsoOnly) {
    Write-HostLog "This tool builds an updated Windows installation ISO. It will:"
    if ($IsoPath) {
        Write-HostLog "  - Use the ISO you provided: $IsoPath"
    }
    elseif ($script:EffectiveServer) {
        Write-HostLog "  - Use the Windows Server ISO it finds in the download folder: $DlDir"
        Write-HostLog "      NOTE: Server media cannot be downloaded automatically, so drop the ISO in that folder" -ForegroundColor Yellow
        Write-HostLog "            or re-run with -IsoPath." -ForegroundColor Yellow
    }
    elseif ($UseFido) {
        Write-HostLog "  - Download the matching official Windows $WindowsVersion ISO from Microsoft (~8 GB)"
        Write-HostLog "      TIP: Microsoft can rate-limit/block repeated ISO downloads. The script retries, and can" -ForegroundColor Yellow
        Write-HostLog "           then offer Microsoft's Media Creation Tool instead. To skip all that, download the" -ForegroundColor Yellow
        Write-HostLog "           ISO yourself and re-run with -IsoPath." -ForegroundColor Yellow
    }
    elseif ($UseMct) {
        Write-HostLog "  - Open Microsoft's Media Creation Tool so you can download the ISO with it (~8 GB)"
        Write-HostLog "      NOTE: MCT has no headless mode, so you click through its last few pages and save the" -ForegroundColor Yellow
        Write-HostLog "            ISO into the download folder. The script waits, then picks it up." -ForegroundColor Yellow
    }
    else {
        Write-HostLog "  - Use the ISO it finds in the download folder: $DlDir"
        Write-HostLog "      NOTE: no ISO is downloaded automatically. Drop one into that folder or re-run with" -ForegroundColor Yellow
        Write-HostLog "            -IsoPath, or add -UseFido to have the script fetch one from Microsoft." -ForegroundColor Yellow
    }
    Write-HostLog "  - Extract it to $ExtractDir"
    if ($KeepEditions -and $KeepEditions.Count -gt 0) {
        Write-HostLog "  - Keep ONLY these editions in the final ISO (remove the rest): $($KeepEditions -join ', ')" -ForegroundColor Yellow
    }
    elseif ($KeepAllEditions) {
        Write-HostLog "  - Keep ALL editions in the final ISO (-KeepAllEditions)"
    }
    else {
        $EditionRule = if ($script:EffectiveServer) { 'the most upgradeable edition (Standard over Datacenter, and the Desktop Experience over Server Core)' } else { 'Enterprise, Pro and Home, whichever of them this media carries' }
        Write-HostLog "  - Keep ONLY $EditionRule to speed up the build. Use -KeepAllEditions to keep them all" -ForegroundColor Yellow
    }
    if (-not $SkipUpdates) {
        if ($UpdatePath) {
            Write-HostLog "  - Integrate the update packages found in: $UpdatePath"
        }
        else {
            Write-HostLog "  - Download the latest cumulative update(s)$(if (-not $SkipDotNet) { ' and the latest .NET cumulative update' }) from the Microsoft Update Catalog"
            Write-HostLog "      (the cumulative update is skipped entirely if the image already has that build)" -ForegroundColor DarkGray
            if ($ReapplyUpdates) {
                Write-HostLog "  - Integrate every update even if the image already has it (-ReapplyUpdates)" -ForegroundColor Yellow
                Write-HostLog "      WARNING: this may leave the media's Setup binaries mismatched with boot.wim, which can stop Windows 11 Setup Dynamic Update from completing" -ForegroundColor Yellow
            }
            else {
                Write-HostLog "      (and if it does, the .NET update, Dynamic Updates and boot.wim are left untouched too)" -ForegroundColor DarkGray
            }
            if ($VerifyPatchLevel) {
                Write-HostLog "  - Mount the image read-only to confirm its real patch level before deciding (-VerifyPatchLevel)"
            }
            if ($IncludePreview) {
                Write-HostLog "  - Allow preview updates to be selected (-IncludePreview): the media can end up on a build Windows Update will not offer until next month" -ForegroundColor Yellow
            }
            if (-not $SkipSetupDU) { Write-HostLog "  - Download the latest Setup Dynamic Update and apply it to the media's sources folder" }
        }
        Write-HostLog "  - Integrate the update(s) into install.wim ($Edition), boot.wim$(if (-not $SkipWinRE) { ', and winre.wim' })"
        Write-HostLog "  - Clean up and re-export the images to shrink them"
    }
    else {
        Write-HostLog "  - Skip update integration (-SkipUpdates) and just recompile the ISO"
    }
    if ($CompressEsd) {
        Write-HostLog "  - Export the image as install.esd with recovery compression (-CompressEsd): a much smaller ISO, but a slow export and the media cannot be serviced again afterwards" -ForegroundColor Yellow
    }
    if ($ExcludeWorkPathFromDefender) {
        Write-HostLog "  - Exclude the folders DISM works in from Defender real-time scanning while the build runs (-ExcludeWorkPathFromDefender), and remove the exclusions when it ends" -ForegroundColor Yellow
    }
    if ($StripImageResidue) {
        Write-HostLog "  - Strip the servicing residue out of each image (-StripImageResidue): not everything that looks like leftover state is, so install from this ISO once before you deploy from it" -ForegroundColor Yellow
    }
    if ($ResolvedDriverPath) {
        Write-HostLog "  - Inject $($script:DriverInfFiles.Count) driver package(s) from $ResolvedDriverPath into every serviced edition and into boot.wim index 2 (Windows Setup)" -ForegroundColor Yellow
    }
    if ($ResolvedUnattend) {
        Write-HostLog "  - Place your answer file on the media as autounattend.xml, so Setup runs unattended: $ResolvedUnattend" -ForegroundColor Yellow
    }
    if ($ResolvedExtraFiles) {
        Write-HostLog "  - Copy the contents of $ResolvedExtraFiles onto the root of the ISO, replacing anything the media already had at the same path" -ForegroundColor Yellow
    }
    if ($RecoveryIsoPath) {
        Write-HostLog "  - Also build a recovery ISO that boots straight into the Windows Recovery Environment, written to $(if ($RecoveryIsoFile) { $RecoveryIsoFile } else { $RecoveryIsoDir })"
    }
    Write-HostLog "  - Recompile a new bootable ISO with oscdimg"
    if (-not $NoStamp) {
        Write-HostLog "  - Record a stamp of the finished build in $StampRoot, so a later run can tell that nothing has changed" -ForegroundColor DarkGray
    }
    if ($AutoClean) {
        Write-HostLog "  - DELETE the update packages earlier builds downloaded, and every generated ISO except the newest $KeepIsoCount (-AutoClean)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-HostLog "With the default settings this normally takes an hour or two from start to finish." -ForegroundColor Yellow
    Write-HostLog "This is disk- and time-intensive and needs a lot of free space. Nothing on this PC is changed." -ForegroundColor Yellow
    Write-Host ""
    $Confirm = Read-Host "Type 'Y' to continue, or anything else to cancel"
    if ($Confirm -notin @('Y', 'y', 'Yes', 'yes')) {
        Write-HostTimestamp 'Operation cancelled by user.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 0
    }
    Write-Host $LineBreak
}

#endregion

#region Locate oscdimg early so we fail fast if the ISO cannot be recompiled (not needed for -ListEditions)
$Oscdimg = $null
if (-not $ListEditions -and -not $CheckOnly) {
    Invoke-Task -Description 'Locating oscdimg.exe (Windows ADK Deployment Tools)...' -ScriptBlock {
        $script:Oscdimg = Find-Oscdimg
        if ($script:Oscdimg) {
            Write-HostTimestamp "  Found oscdimg: $($script:Oscdimg)" -ForegroundColor Green
        }
        else {
            # Grab the single ~150 KB executable straight from Microsoft's symbol server first, and only
            # fall back to the full ADK install (which is hundreds of MB) if that fails.
            if (-not $SkipOscdimgDownload) {
                Write-HostTimestamp '  oscdimg was not found. Downloading a standalone copy from Microsoft...' -ForegroundColor Yellow
                $script:Oscdimg = Get-OscdimgDownload
                if ($script:Oscdimg) { Write-HostTimestamp "  Downloaded oscdimg: $($script:Oscdimg)" -ForegroundColor Green }
            }
            if (-not $script:Oscdimg -and $InstallAdk) {
                Write-HostTimestamp '  Installing the Windows ADK Deployment Tools...' -ForegroundColor Yellow
                $script:Oscdimg = Install-AdkDeploymentTools
                if ($script:Oscdimg) { Write-HostTimestamp "  Installed. Found oscdimg: $($script:Oscdimg)" -ForegroundColor Green }
            }
        }
    }
    $Oscdimg = $script:Oscdimg
    if (-not $Oscdimg) {
        Write-HostTimestamp 'oscdimg.exe was not found and could not be downloaded. It is part of the Windows ADK "Deployment Tools" feature and is required to recompile the ISO.' -ForegroundColor Red
        Write-HostTimestamp 'Re-run with -InstallAdk to have this script download and install the ADK automatically, or install the Windows ADK (Deployment Tools) manually from Microsoft and re-run.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 1
    }
}

#endregion

#region Obtain the ISO
$ResolvedIso = $null
if ($IsoPath) {
    if (Test-Path -LiteralPath $IsoPath -PathType Container) {
        $FolderIso = Find-SourceIso -Directory $IsoPath -Largest:$UseLargestIso
        if (-not $FolderIso) {
            Write-HostTimestamp "-IsoPath '$IsoPath' is a folder, but it holds no .iso larger than 3 GB. The search is not recursive, so an ISO in a subfolder is not found. Cannot continue." -ForegroundColor Red
            Stop-Transcript | Out-Null
            exit 1
        }
        $ResolvedIso = $FolderIso.FullName
        $PickedBy = if ($UseLargestIso) { 'largest' } else { 'most recently modified' }
        Write-HostTimestamp "Using the $PickedBy ISO in '$IsoPath': $ResolvedIso ($([math]::Round($FolderIso.Length / 1GB, 2)) GB)" -ForegroundColor Green
    }
    elseif (Test-Path -LiteralPath $IsoPath -PathType Leaf) {
        $ResolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path
        Write-HostTimestamp "Using the provided ISO: $ResolvedIso" -ForegroundColor Green
    }
    else {
        Write-HostTimestamp "The ISO path '$IsoPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }

    # If the ISO sits on a cloud-synced or network path, copy it to the local download folder first.
    # Mounting and reading a placeholder or an SMB share during the long extraction is slow and unreliable,
    # while a local copy is not, and Mount-DiskImage wants a local file anyway. -CheckOnly only ever reads
    # the file to hash it, so it is not worth moving gigabytes for.
    $IsoIsCloud = ($ResolvedIso -match $CloudPattern -or $ResolvedIso -match '(?i)OneDrive')
    $IsoIsRemote = Test-RemotePath -Path $ResolvedIso
    $DlDirIsCloud = ($DlDir -match $CloudPattern -or $DlDir -match '(?i)OneDrive')
    if (($IsoIsCloud -or $IsoIsRemote) -and -not $DlDirIsCloud -and -not (Test-RemotePath -Path $DlDir) -and -not $CheckOnly) {
        $RemoteKind = if ($IsoIsRemote) { 'a network path' } else { 'a cloud-synced path' }
        $RemoteOrigin = $ResolvedIso
        $LocalIso = Join-Path -Path $DlDir -ChildPath (Split-Path -Leaf $ResolvedIso)
        $SourceLen = (Get-Item -LiteralPath $ResolvedIso).Length
        if ((Test-Path -LiteralPath $LocalIso) -and ((Get-Item -LiteralPath $LocalIso).Length -eq $SourceLen)) {
            Write-HostTimestamp "  A local copy already exists - using it: $LocalIso" -ForegroundColor Green
            $ResolvedIso = $LocalIso
            $script:SourceLocalCopy = $RemoteOrigin
        }
        else {
            try {
                Invoke-Task -Description "The ISO is on $RemoteKind, so it is copied to a local disk first ($([math]::Round($SourceLen / 1GB, 2)) GB): $LocalIso ..." -ScriptBlock {
                    Copy-LargeFile -Path $ResolvedIso -Destination $LocalIso
                    Write-HostTimestamp '  Copy complete.' -ForegroundColor Green
                }
                $ResolvedIso = $LocalIso
                $script:SourceLocalCopy = $RemoteOrigin
            }
            catch {
                Write-HostTimestamp "  Could not copy the ISO locally ($($_.Exception.Message)). Proceeding from $RemoteKind - this may be slow or fail." -ForegroundColor Yellow
            }
        }
    }
}
else {
    # Reuse an already-downloaded ISO in the download folder if present, otherwise resolve + download one.
    $ExistingIso = Find-SourceIso -Directory $DlDir -Largest:$UseLargestIso
    if ($ExistingIso) {
        $ResolvedIso = $ExistingIso.FullName
        Write-HostTimestamp "An ISO is already downloaded - reusing it: $ResolvedIso ($([math]::Round($ExistingIso.Length / 1GB, 2)) GB)" -ForegroundColor Green
    }
    else {
        # Neither Fido nor the Media Creation Tool offers Windows Server media, so a run that is expecting
        # it has nowhere to download from and cannot go any further without an ISO from the user.
        if ($script:EffectiveServer) {
            Write-HostTimestamp 'No Windows Server ISO was found, and Server media cannot be downloaded automatically (neither Fido nor the Media Creation Tool serves it).' -ForegroundColor Red
            Write-HostTimestamp '  Get the ISO from the Microsoft Evaluation Center, your Volume Licensing Service Center, or a Visual Studio subscription, then re-run with -IsoPath "C:\path\to\Server.iso"' -ForegroundColor Yellow
            Write-HostTimestamp "  or drop the .iso into the download folder and re-run - it is picked up automatically: $DlDir" -ForegroundColor Yellow
            Stop-Transcript | Out-Null
            exit 1
        }
        # -CheckOnly answers a question, so it never spends 8 GB of bandwidth to do it.
        if ($CheckOnly) {
            Write-HostTimestamp 'No ISO is available locally, so there is nothing to compare against - a build is needed.' -ForegroundColor Yellow
            Stop-Transcript | Out-Null
            exit 10
        }
        # Fido is opt-in, so without -UseFido this lands on the same fallbacks a blocked link request
        # would: the Media Creation Tool, or instructions for supplying the ISO by hand.
        if ($UseMct) {
            $ResolvedIso = Get-IsoViaMct -Version $WindowsVersion -Language $Language -Architecture $WinInfo.Architecture -DownloadDir $DlDir
            if (-not $ResolvedIso) {
                Write-HostTimestamp 'No ISO was produced with the Media Creation Tool. Cannot continue.' -ForegroundColor Red
                Stop-Transcript | Out-Null
                exit 1
            }
        }
        else {
            if ($UseFido) {
                Invoke-Task -Description 'Obtaining the Windows ISO download link from Microsoft...' -ScriptBlock {
                    $script:IsoUrl = Get-WindowsIsoUrl -Version $WindowsVersion -Release $Release -Language $Language -Architecture $WinInfo.Architecture
                }
            }
            else {
                Write-HostTimestamp 'No ISO was supplied or found in the download folder, and nothing is downloaded automatically unless you ask for it.' -ForegroundColor Yellow
                Write-HostTimestamp '  Add -UseFido to have the script fetch the ISO from Microsoft, or -UseMct to get it with the Media Creation Tool.' -ForegroundColor Yellow
            }
            if (-not $script:IsoUrl) {
                if ($UseFido) {
                    Write-HostTimestamp 'Could not obtain a download link. Microsoft may be rate-limiting/blocking your IP for repeated ISO requests.' -ForegroundColor Yellow
                }

                # The Media Creation Tool uses different Microsoft endpoints, so it usually still works when
                # the download-link API is blocked - but it needs someone to click through its wizard.
                $CanPrompt = -not ($Unattended -or $SkipInteractive)
                if ($CanPrompt) {
                    Write-Host ''
                    $Answer = Read-Host "Microsoft's Media Creation Tool uses different servers and can fetch the ISO instead. Open it now? (Y/N)"
                    if ($Answer -match '(?i)^\s*(y|yes)\s*$') {
                        $ResolvedIso = Get-IsoViaMct -Version $WindowsVersion -Language $Language -Architecture $WinInfo.Architecture -DownloadDir $DlDir
                    }
                }
                else {
                    Write-HostTimestamp 'Re-run interactively (without -Unattended/-SkipInteractive) and this script can open the Media Creation Tool for you, or pass -UseMct.' -ForegroundColor Yellow
                }

                if (-not $ResolvedIso) {
                    Write-HostTimestamp 'Download the ISO yourself from https://www.microsoft.com/software-download, then either re-run with -IsoPath "C:\path\to\Windows.iso"' -ForegroundColor Yellow
                    Write-HostTimestamp "or simply drop the .iso into the download folder and re-run - it is picked up automatically: $DlDir" -ForegroundColor Yellow
                    Stop-Transcript | Out-Null
                    exit 1
                }
            }
        }

        if (-not $ResolvedIso) {
            $FileName = $null
            try { $FileName = [System.IO.Path]::GetFileName(([Uri]$script:IsoUrl).AbsolutePath) } catch { }
            if (-not $FileName -or $FileName -notmatch '\.iso$') {
                $FileName = "Windows$WindowsVersion`_$Language`_$($WinInfo.Architecture).iso"
            }
            $ResolvedIso = Join-Path -Path $DlDir -ChildPath $FileName

            Invoke-Task -Description "Downloading the Windows $WindowsVersion ISO to $ResolvedIso ..." -ScriptBlock {
                if (-not (Get-FileDownload -Url $script:IsoUrl -Destination $ResolvedIso)) {
                    Write-HostTimestamp 'ISO download failed. Microsoft may be rate-limiting/blocking your IP for repeated ISO requests.' -ForegroundColor Red
                    Write-HostTimestamp 'Download the ISO yourself from https://www.microsoft.com/software-download and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
                    Stop-Transcript | Out-Null
                    exit 1
                }
                $SizeGB = [math]::Round((Get-Item -LiteralPath $ResolvedIso).Length / 1GB, 2)
                if ($SizeGB -lt 3) {
                    Write-HostTimestamp "The downloaded file is only $SizeGB GB - that is too small to be a Windows ISO. The download likely failed." -ForegroundColor Red
                    Stop-Transcript | Out-Null
                    exit 1
                }
                Write-HostTimestamp "  Download complete ($SizeGB GB)." -ForegroundColor Green
            }
        }
    }
}
Write-Host $LineBreak

#endregion

