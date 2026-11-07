#region Re-export install.wim (shrink after servicing and/or drop editions with -KeepEditions)
# Exporting only the kept indexes both reclaims the space freed by the component cleanup AND physically
# removes any editions the user chose not to keep. Runs when updates were applied or when trimming.
# Tracks what Setup will actually read, since -CompressEsd replaces install.wim with install.esd.
$FinalInstallImage = $InstallWimExtracted
if (($UpdateGroups.Count -gt 0) -or $TrimNeeded -or $CompressEsd) {
    $ExportDesc = if ($CompressEsd) { 'Exporting the image as install.esd (recovery compression - this is slow)...' }
                  elseif ($TrimNeeded) { 'Rebuilding install.wim with only the kept edition(s) and shrinking it...' }
                  else { 'Re-exporting install.wim to shrink it...' }
    Invoke-Task -Description $ExportDesc -ScriptBlock {
        if (-not (Test-RoomForExport -SourceImage $InstallWimExtracted -Label 'install image')) { return }
        $TempName    = if ($CompressEsd) { 'install_new.esd' } else { 'install_new.wim' }
        $FinalName   = if ($CompressEsd) { 'install.esd' } else { 'install.wim' }
        $Compression = if ($CompressEsd) { 'Recovery' } else { $WimCompression }
        $Temp = Join-Path $ExtractDir "sources\$TempName"
        $Dest = Join-Path $ExtractDir "sources\$FinalName"
        try {
            if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
            $BeforeMB = (Get-Item -LiteralPath $InstallWimExtracted).Length / 1MB
            # Export in the order the indexes were chosen, which is ascending for -KeepEditions and
            # highest-edition-first for the default.
            foreach ($Index in $KeepIndexes) {
                $Name = ($InstallImages | Where-Object { $_.ImageIndex -eq $Index }).ImageName
                Write-HostTimestamp "  Exporting [$Index] $Name ..."
                Export-WimImage -SourceImagePath $InstallWimExtracted -DestinationImagePath $Temp -CompressionType $Compression -SourceIndex $Index
            }
            Remove-Item -LiteralPath $InstallWimExtracted -Force -ErrorAction Stop
            Move-Item -LiteralPath $Temp -Destination $Dest -Force -ErrorAction Stop
            $script:FinalInstallImage = $Dest
            $AfterMB = (Get-Item -LiteralPath $Dest).Length / 1MB
            Write-HostTimestamp ('  {0}: {1:N0} MB -> {2:N0} MB (saved {3:N0} MB).' -f $FinalName, $BeforeMB, $AfterMB, ($BeforeMB - $AfterMB)) -ForegroundColor Green
            if ($CompressEsd -and $AfterMB -ge 4096) {
                Write-HostTimestamp '  Still over 4 GB, so a FAT32 USB stick will need the image split. Consider -KeepEditions to drop more editions.' -ForegroundColor DarkYellow
            }
        }
        catch {
            Write-HostTimestamp "  Export failed: $($_.Exception.Message). The original serviced install.wim will be used as-is." -ForegroundColor Yellow
            Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        }
    }
}

# Reads $FinalInstallImage rather than install.wim, so -CompressEsd is measured against what ships.
Add-WimSizeSample -Label 'install.wim' -Path $FinalInstallImage

#endregion

#region Add the unattended answer file to the media
# Windows Setup implicitly reads \autounattend.xml from the root of read-only boot media during the
# windowsPE pass, so no Setup switches are needed when the ISO is booted.
if ($ResolvedUnattend) {
    Invoke-Task -Description 'Adding the unattended answer file to the media...' -ScriptBlock {
        $UnattendDest = Join-Path $ExtractDir 'autounattend.xml'
        if (Test-Path -LiteralPath $UnattendDest) { Set-ItemProperty -LiteralPath $UnattendDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $ResolvedUnattend -Destination $UnattendDest -Force -ErrorAction Stop
        Write-HostTimestamp '  Added autounattend.xml to the root of the media.' -ForegroundColor Green
        if (($TrimNeeded -or $script:EsdPreTrimmed) -and $UnattendText -match '(?i)/IMAGE/INDEX') {
            Write-HostTimestamp '  Warning: the answer file selects the edition by /IMAGE/INDEX, but install.wim was renumbered when the other editions were removed. Switch it to /IMAGE/NAME, or use -KeepAllEditions, if Setup cannot find the edition.' -ForegroundColor Yellow
        }
    }
}

#endregion

#region Copy the extra files onto the media (-ExtraFilesPath)
# Last of the content steps, so anything here deliberately wins over the media's own copy and over the
# answer file -UnattendPath just placed.
if ($ResolvedExtraFiles) {
    Invoke-Task -Description 'Copying your extra files onto the media...' -ScriptBlock {
        $Root = $ResolvedExtraFiles.TrimEnd('\')
        # Validation already hashed every file, so the copy only has to find its record and flag it.
        $ByPath = @{}
        foreach ($Record in $script:ExtraFileRecords) { $ByPath[$Record.Path.ToLowerInvariant()] = $Record }

        foreach ($Item in (Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)) {
            $Relative = $Item.FullName.Substring($Root.Length).TrimStart('\')
            $Dest = Join-Path -Path $ExtractDir -ChildPath $Relative
            if ($Item.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force -ErrorAction Stop | Out-Null }
                continue
            }
            $Replaced = Test-Path -LiteralPath $Dest -PathType Leaf
            if ($Replaced) {
                [void]$script:ExtraFileOverwrites.Add($Relative)
                # Files copied off the source ISO are read-only, so Copy-Item -Force alone is not enough.
                Set-ItemProperty -LiteralPath $Dest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            }
            Copy-Item -LiteralPath $Item.FullName -Destination $Dest -Force -ErrorAction Stop
            $script:ExtraFilesCopied++

            $Record = $ByPath["\$($Relative.ToLowerInvariant())"]
            if ($Record) { $Record['Replaced'] = $Replaced }
            $SizeKB = if ($Record) { $Record.SizeKB } else { [math]::Round($Item.Length / 1KB, 2) }
            if ($Replaced) {
                Write-HostTimestamp "    \$Relative ($SizeKB KB) REPLACED" -ForegroundColor Yellow
            }
            else {
                Write-HostTimestamp "    \$Relative ($SizeKB KB)" -ForegroundColor DarkGray
            }
        }
        Write-HostTimestamp "  Copied $($script:ExtraFilesCopied) file(s) to the root of the media." -ForegroundColor Green

        if ($script:ExtraFileOverwrites.Count -eq 0) {
            Write-HostTimestamp '  Nothing the media already had was replaced.' -ForegroundColor DarkGray
            return
        }

        Write-HostTimestamp "  $($script:ExtraFileOverwrites.Count) of them REPLACED a file the media already had, marked above and listed in the build record." -ForegroundColor Yellow

        # Replacing one of these throws away everything this run just spent an hour producing.
        $Serviced = @($script:ExtraFileOverwrites | Where-Object { $_ -match '(?i)^sources\\(install|boot)\.(wim|esd)$' })
        if ($Serviced.Count -gt 0) {
            Write-HostTimestamp "  WARNING: $($Serviced -join ', ') came from your folder, so the ISO ships YOUR image, not the one this run serviced. The updates and drivers applied above are not in the finished ISO." -ForegroundColor Red
        }
        $SetupFiles = @($script:ExtraFileOverwrites | Where-Object { $_ -match '(?i)^(sources\\setup(host)?\.exe|boot\\|efi\\|bootmgr)' })
        if ($SetupFiles.Count -gt 0) {
            Write-HostTimestamp '  Warning: boot or Setup files were replaced. Windows Setup fails if those do not match the version inside boot.wim, and the wrong boot sector makes the ISO unbootable.' -ForegroundColor Yellow
        }
        if ($script:ExtraFileOverwrites -contains 'autounattend.xml') {
            Write-HostTimestamp '  Note: autounattend.xml was replaced, so your folder''s copy is on the ISO rather than the one -UnattendPath supplied.' -ForegroundColor Yellow
        }
    }
    if (-not $SkipTattoo -and @($script:ExtraFileOverwrites | Where-Object { $_ -match '(?i)^WISO-Build\\' }).Count -gt 0) {
        Write-HostTimestamp '  Note: files under \WISO-Build are about to be replaced by the build record. Pass -SkipTattoo to keep yours.' -ForegroundColor Yellow
        Write-Host $LineBreak
    }
}

#endregion

#region Decide the output ISO name and volume label
# The name describes what the ISO actually contains: Win11_Pro_x64_enGB_26100.4061_20260815-1332.iso. It is
# built even when -OutputIsoPath overrides the path, because the volume label is derived from it.
$IsoLocale = if ($script:FinalImageLocale) { $script:FinalImageLocale } else { "$script:MediaLanguage" }
$DefaultIsoName = Get-DefaultIsoName -Images $InstallImages -Indexes $KeepIndexes -BuildString $script:FinalBuildString -FallbackVersion $ImageInfo.Version -Architecture $ImageArch -Locale $IsoLocale
if ($IsoNamePrefix -or $IsoNameSuffix) {
    $DefaultIsoName = "$IsoNamePrefix$([System.IO.Path]::GetFileNameWithoutExtension($DefaultIsoName))$IsoNameSuffix.iso"
}
if (-not $OutputIsoPath) {
    $OutputIsoPath = Join-Path -Path $FinishedIsoDir -ChildPath $DefaultIsoName
}
$IsoVolumeLabel = if ($VolumeLabel) { $VolumeLabel } else { Get-IsoVolumeLabel -IsoFileName $DefaultIsoName -Locale $IsoLocale }
# Make sure the destination folder exists before oscdimg writes the ISO into it.
try {
    $OutDir = Split-Path -Path $OutputIsoPath -Parent
    if ($OutDir -and -not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null }
}
catch { }
# Where oscdimg actually writes. Everything else (the stamp, the tattoo, -AutoClean, the closing summary)
# keeps quoting the real destination, so only the build and the copy know a staging file existed.
$BuildIsoPath = $OutputIsoPath
if ($OutputIsRemote) {
    $BuildIsoPath = Join-Path -Path $IsoStageDir -ChildPath (Split-Path -Leaf $OutputIsoPath)
    New-Item -ItemType Directory -Path $IsoStageDir -Force -ErrorAction SilentlyContinue | Out-Null
}

#endregion

