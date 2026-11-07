#region Recompile the ISO with oscdimg
Invoke-Task -Description "Recompiling the bootable ISO to $BuildIsoPath ..." -ScriptBlock {
    # Remove any leftover ISO at the target path from a previous run so oscdimg starts clean.
    if (Test-Path -LiteralPath $BuildIsoPath) { Remove-Item -LiteralPath $BuildIsoPath -Force -ErrorAction SilentlyContinue }

    $BootArg = Get-OscdimgBootData -MediaRoot $ExtractDir
    if (-not $BootArg) {
        # Neither boot sector was found, so oscdimg will still build the ISO, but it may not be bootable.
        Write-HostTimestamp '  No boot sectors were found in the extracted media, so the resulting ISO may not be bootable.' -ForegroundColor Yellow
    }

    # oscdimg switches: -m (ignore the 4 GB image size limit), -o (de-duplicate identical files to save
    # space), -u2 (write a pure UDF file system, required for the large install.wim), -udfver102 (UDF
    # revision 1.02 for broad compatibility), -l (volume label). -bootdata makes the ISO bootable, and the
    # last two arguments are the source folder to package and the output ISO path.
    $OscdimgArgs = @('-m', '-o', '-u2', '-udfver102', "-l$IsoVolumeLabel")
    if ($BootArg) { $OscdimgArgs += "-bootdata:$BootArg" }
    $OscdimgArgs += @($ExtractDir, $BuildIsoPath)
    Write-HostTimestamp "  Volume label: $IsoVolumeLabel" -ForegroundColor DarkGray

    # Run oscdimg and wait for it to finish, then verify it actually produced the ISO.
    Write-HostTimestamp "  Running: `"$Oscdimg`" $($OscdimgArgs -join ' ')"
    $Proc = Start-Process -FilePath $Oscdimg -ArgumentList $OscdimgArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
    if ($Proc.ExitCode -ne 0) {
        # A non-zero exit code means oscdimg failed to build the image.
        throw "oscdimg returned exit code $($Proc.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $BuildIsoPath)) {
        # Guard against the rare case where oscdimg exits 0 but no file was written.
        throw 'oscdimg reported success but the output ISO was not created.'
    }
    $SizeGB = [math]::Round((Get-Item -LiteralPath $BuildIsoPath).Length / 1GB, 2)
    Write-HostTimestamp "  New ISO created ($SizeGB GB)." -ForegroundColor Green
}

# One sequential copy at the end, rather than oscdimg writing across the wire for the length of the build.
if ($BuildIsoPath -ne $OutputIsoPath) {
    Invoke-Task -Description "Copying the finished ISO to $OutputIsoPath ..." -ScriptBlock {
        # Hashed while the file is still local, because the stamp wants this hash and reading 8 GB back off
        # a share to get it would cost about as much as the copy itself.
        if (-not $NoStamp) {
            Write-HostTimestamp '  Hashing the finished ISO before it leaves the local disk...'
            $script:OutputIsoSha256 = Get-Sha256 -Path $BuildIsoPath -ShowProgress
        }
        try {
            if (Test-Path -LiteralPath $OutputIsoPath) { Remove-Item -LiteralPath $OutputIsoPath -Force -ErrorAction SilentlyContinue }
            Copy-LargeFile -Path $BuildIsoPath -Destination $OutputIsoPath
        }
        catch {
            # The staged ISO is deliberately left behind, it is a finished build and only the copy failed.
            throw "The ISO was built but could not be copied to '$OutputIsoPath': $($_.Exception.Message). It is still at $BuildIsoPath, so you can move it there by hand."
        }
        Write-HostTimestamp "  The finished ISO is at $OutputIsoPath." -ForegroundColor Green
        Remove-Item -LiteralPath $BuildIsoPath -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Build the recovery ISO (-RecoveryIsoPath)
$script:RecoveryIsoOutput = $null
if ($RecoveryIsoPath) {
    Invoke-Task -Description 'Building the recovery ISO...' -ScriptBlock {
        try {
            if (-not $script:RecoveryWinRe) {
                Write-HostTimestamp '  No recovery image was copied out of install.wim, so there is no recovery ISO to build.' -ForegroundColor Yellow
                return
            }
            # The boot managers in $ExtractDir were already matched to the serviced boot.wim.
            $script:RecoveryIsoOutput = New-RecoveryIso -WinReWim $script:RecoveryWinRe -BootSource $ExtractDir -Build $ImageBuild -Architecture $ImageArch
        }
        catch {
            # The installation ISO is already finished, so a recovery ISO that fails must not cost the run.
            Write-HostTimestamp "  The recovery ISO could not be built: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally {
            Remove-Item -LiteralPath $RecoveryMediaDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region Report the final image contents (editions + build) before the working files are removed
Invoke-Task -Description 'Reading the final image details...' -ScriptBlock {
    $FallbackBuild = if ($FeatureName) { "$ImageVersionText ($FeatureName)" } else { $ImageVersionText }
    Show-FinalImageInfo -WimPath $FinalInstallImage -FallbackBuildString $FallbackBuild
}
Show-WinReVersions
Show-WimSizeComparison

#endregion

#region Cleanup the working extraction folder
Invoke-Task -Description 'Cleaning up the working extraction folder...' -ScriptBlock {
    try {
        Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction Stop
        Remove-Item -LiteralPath (Join-Path -Path $WorkRoot -ChildPath 'ServicingStack') -Recurse -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Removed the extracted media.' -ForegroundColor Green
    }
    catch {
        Write-HostTimestamp "  Could not fully remove $ExtractDir : $($_.Exception.Message). You can delete it manually." -ForegroundColor Yellow
    }
}

#endregion

#region Write the build stamp
# The record the next run compares itself against: what went in, what came out, and under which settings.
if (-not $NoStamp) {
    Invoke-Task -Description 'Writing the build stamp...' -ScriptBlock {
        $SourceItem = Get-Item -LiteralPath $ResolvedIso -ErrorAction SilentlyContinue
        $OutputItem = Get-Item -LiteralPath $OutputIsoPath -ErrorAction SilentlyContinue

        $UpdateRecords = @($script:UpdateFileRecords)

        $ParameterSet = Get-BuildParameterSet
        $OutputHash = $null
        if ($script:OutputIsoSha256) {
            $OutputHash = $script:OutputIsoSha256
        }
        elseif ($OutputItem) {
            Write-HostTimestamp "  Hashing the finished ISO ($([math]::Round($OutputItem.Length / 1GB, 2)) GB)..."
            $OutputHash = Get-Sha256 -Path $OutputItem.FullName -ShowProgress
        }
        # Taken from the image list read before the working folder was removed.
        $KeptEditionNames = @($InstallImages | Where-Object { $KeepIndexes -contains [int]$_.ImageIndex } | ForEach-Object { "$($_.ImageName)" })
        $Stamp = [ordered]@{
            SchemaVersion   = 1
            ScriptVersion   = $ScriptVersion
            CreatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
            Computer        = $env:COMPUTERNAME
            Result          = if ($script:ServicingFailures -gt 0) { 'SuccessWithWarnings' } else { 'Success' }
            DurationMinutes = [math]::Round(((Get-Date) - $script:ScriptStartTime).TotalMinutes, 1)
            Source          = [ordered]@{
                Path             = if ($SourceItem) { $SourceItem.FullName } else { $ResolvedIso }
                FileName         = if ($SourceItem) { $SourceItem.Name } else { Split-Path -Leaf $ResolvedIso }
                Length           = if ($SourceItem) { $SourceItem.Length } else { 0 }
                LastWriteTimeUtc = if ($SourceItem) { $SourceItem.LastWriteTimeUtc.ToString('o') } else { '' }
                Sha256           = $script:StampSourceHash
                # Non-empty only when this run copied -IsoPath into $DlDir from a remote/cloud path, so
                # -AutoClean can tell a script-managed cached copy apart from the user's own ISO.
                RemoteOrigin     = if ($script:SourceLocalCopy) { "$script:SourceLocalCopy" } else { '' }
            }
            Image           = [ordered]@{
                Version       = $ImageVersionText
                Build         = $ImageBuild
                Ubr           = $ImageUbr
                FeatureUpdate = $FeatureName
                Architecture  = $ImageArch
                CatalogArch   = $CatalogArch
                # The next run reads this back before extracting anything, since the catalog product name
                # differs between Server and client and there is no image to ask yet at that point.
                Server        = [bool]$script:EffectiveServer
                FinalBuild    = $script:FinalBuildString
            }
            Updates         = [ordered]@{
                # What the catalog was offering at build time - this is what a later run compares against.
                Catalog = @($script:ExpectedUpdateSet | Where-Object { $_ })
                Files   = $UpdateRecords
            }
            Output          = [ordered]@{
                Path     = $OutputIsoPath
                FileName = if ($OutputItem) { $OutputItem.Name } else { Split-Path -Leaf $OutputIsoPath }
                SizeGB   = if ($OutputItem) { [math]::Round($OutputItem.Length / 1GB, 2) } else { 0 }
                Sha256   = $OutputHash
                Editions = $KeptEditionNames
            }
            Parameters      = $ParameterSet
            ParametersHash  = Get-BuildParameterHash -Set $ParameterSet
        }
        Write-BuildStamp -Stamp $Stamp
    }
}

#endregion

#region Housekeeping (-AutoClean)
if ($AutoClean) {
    Invoke-Task -Description 'Cleaning up old downloads and ISOs (-AutoClean)...' -ScriptBlock {
        Invoke-AutoClean -CurrentStamp (Read-BuildStamp) -History (Get-BuildStampHistory) -KeepIsoCount $KeepIsoCount -Protected @($ResolvedIso, $OutputIsoPath, $script:RecoveryIsoOutput)
    }
}

#endregion

#region Timing summary
$TotalElapsed = (Get-Date) - $script:ScriptStartTime
if ($script:StepTimings.Count -gt 0) {
    Write-HostTimestamp 'Time spent on each step:' -ForegroundColor Cyan
    $NameWidth = ($script:StepTimings | ForEach-Object { $_.Description.Length } | Measure-Object -Maximum).Maximum
    if ($NameWidth -gt 70) { $NameWidth = 70 }
    foreach ($Step in $script:StepTimings) {
        $Label = if ($Step.Description.Length -gt $NameWidth) { $Step.Description.Substring(0, $NameWidth - 3) + '...' } else { $Step.Description }
        Write-HostLog ("  {0,-$NameWidth}  {1,10}" -f $Label, (Format-Duration $Step.Duration))
    }
    $Slowest = $script:StepTimings | Sort-Object -Property Duration -Descending | Select-Object -First 1
    Write-Host ''
    Write-HostTimestamp "Longest step: $($Slowest.Description) ($(Format-Duration $Slowest.Duration))" -ForegroundColor DarkGray
}
Write-HostTimestamp "Total run time: $(Format-Duration $TotalElapsed) (started $($script:ScriptStartTime.ToString('HH:mm:ss')), finished $((Get-Date).ToString('HH:mm:ss')))" -ForegroundColor Cyan
Write-Host $LineBreak

Write-HostTimestamp 'Done. Your updated Windows installation ISO is ready:' -ForegroundColor Green
Write-HostTimestamp "  $OutputIsoPath" -ForegroundColor Green
if ($script:RecoveryIsoOutput) {
    Write-HostTimestamp 'Recovery ISO:' -ForegroundColor Green
    Write-HostTimestamp "  $script:RecoveryIsoOutput" -ForegroundColor Green
}
if (-not $SkipTattoo) {
    Write-HostTimestamp '  Open \WISO-Build on the ISO for the record of how it was built.' -ForegroundColor DarkGray
}
Write-Host ''
# Every package that failed on any image, boot.wim and the recovery image included, so the warnings that scrolled
# past during servicing are not the only place a failure shows.
$FailedServicing = @($script:TattooServicing | Where-Object { $_.Result -eq 'Failed' })
if ($FailedServicing.Count -gt 0 -or $script:ServicingFailures -gt 0) {
    Write-HostTimestamp "Some updates didn't apply. The ISO is still valid and bootable, but these images are missing them:" -ForegroundColor Yellow
    foreach ($Failure in $FailedServicing) {
        Write-HostLog "  - $($Failure.Package) on $($Failure.Image)$(if ($Failure.Detail) { ": $($Failure.Detail)" })" -ForegroundColor Yellow
    }
    $DismLogFolder = Join-Path -Path $LogDir -ChildPath "Windows-ISO-Updater_${LogStamp}_DISM"
    if (Test-Path -LiteralPath $DismLogFolder) { Write-HostTimestamp "  DISM's log for each one is in $DismLogFolder" -ForegroundColor DarkYellow }
    else { Write-HostTimestamp '  Details are in C:\Windows\Logs\DISM\dism.log.' -ForegroundColor DarkYellow }
    Write-Host ''
}
Write-HostLog 'You can write it to a USB drive (e.g. with Rufus) or use it for a clean install or in-place upgrade.'
Write-Host $LineBreak

Remove-WorkPathDefenderExclusion
Write-HostTimestamp 'Windows ISO Updater script finished.' -ForegroundColor Green
if (-not $Unattended -and -not $SkipInteractive) {
    Read-Host -Prompt 'Press enter to exit'
}

#endregion

#region End Logging
# Stop logging
Stop-Transcript
#endregion
