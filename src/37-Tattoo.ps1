#region Tattoo the build details onto the media (-SkipTattoo)
# Written into the extracted folder now, while oscdimg has not packaged it yet, so the finished ISO can
# answer "where did this come from and what is in it" without the build machine being around.
if (-not $SkipTattoo) {
    Invoke-Task -Description 'Writing the build record onto the media...' -ScriptBlock {
        $SourceItem = Get-Item -LiteralPath $ResolvedIso -ErrorAction SilentlyContinue
        # Source indexes, because these are the editions as the ISO shipped them. Re-exporting renumbers
        # whatever survives, which is why the kept list is by name. An install.esd was already trimmed
        # during its conversion, so its pre-trim lists are the only record of what the media carried.
        # Wrapped outside the if, which would otherwise unroll a one-edition list into a bare entry.
        $SourceEditions = @(if ($script:SourceMediaEditions.Count -gt 0) { $script:SourceMediaEditions } else { $InstallImages | ForEach-Object { [ordered]@{ Index = [int]$_.ImageIndex; Name = "$($_.ImageName)" } } })
        $KeptNames      = @($InstallImages | Where-Object { $KeepIndexes -contains [int]$_.ImageIndex } | ForEach-Object { "$($_.ImageName)" })
        $RemovedNames   = @($script:SourceMediaDropped) + @($InstallImages | Where-Object { $KeepIndexes -notcontains [int]$_.ImageIndex } | ForEach-Object { "$($_.ImageName)" })
        $UnpatchedNames = @($InstallImages | Where-Object { ($KeepIndexes -contains [int]$_.ImageIndex) -and ($ServiceIndexes -notcontains [int]$_.ImageIndex) } | ForEach-Object { "$($_.ImageName)" })
        $Failed         = @($script:TattooServicing | Where-Object { $_.Result -eq 'Failed' })
        $WinReResults   = @($script:TattooServicing | Where-Object { "$($_.Image)" -like 'winre.wim*' })
        $WinReApplied   = @($WinReResults | Where-Object { $_.Result -eq 'Applied' }).Count
        $WinReFailed    = @($WinReResults | Where-Object { $_.Result -eq 'Failed' }).Count
        $WinReSkipped   = @($WinReResults | Where-Object { $_.Result -eq 'Skipped' }).Count
        $WinRe =
            if ($SkipWinRE) { @{ Status = 'NotServiced'; Reason = '-SkipWinRE was used' } }
            elseif ($SkipUpdates -or $SkipServicing) { @{ Status = 'NotServiced'; Reason = 'No updates were integrated' } }
            elseif ($UpdatePath) { @{ Status = 'NotServiced'; Reason = '-UpdatePath packages are applied to install.wim and boot.wim only' } }
            elseif ($script:LcuUpToDate) { @{ Status = 'NotServiced'; Reason = 'The media already carries the latest cumulative update' } }
            elseif (-not $SafeOsGroup) { @{ Status = 'NotServiced'; Reason = 'No Safe OS Dynamic Update was available' } }
            elseif ($WinReApplied -gt 0 -and $WinReFailed -gt 0) { @{ Status = 'PartiallyServiced'; Reason = "Failed for $WinReFailed edition(s), which keep the recovery image they shipped with" } }
            elseif ($WinReApplied -gt 0) { @{ Status = 'Serviced'; Reason = $null } }
            elseif ($WinReSkipped -gt 0 -and $WinReFailed -eq 0) { @{ Status = 'AlreadyCurrent'; Reason = 'Already at the build the Safe OS Dynamic Update delivers' } }
            elseif ($WinReFailed -gt 0) { @{ Status = 'Failed'; Reason = 'The Safe OS Dynamic Update failed to apply' } }
            else { @{ Status = 'NotServiced'; Reason = $null } }

        $Invariant  = [System.Globalization.CultureInfo]::InvariantCulture
        $TimeFormat = "yyyy-MM-dd'T'HH:mm:sszzz"

        # The stamp keeps these as Role=KB@date tokens for comparison, which nobody reading the media should have to parse.
        $CatalogSelection = @(foreach ($Token in @($script:ExpectedUpdateSet | Where-Object { "$_" -match '=' })) {
            $Role, $Value = "$Token" -split '=', 2
            if ($Value -match '^KB(\d+)@([\d-]*)$') {
                [ordered]@{
                    Role     = $Role
                    Kb       = "KB$($Matches[1])"
                    Released = if ($Matches[2]) { $Matches[2] } else { $null }
                    Title    = $script:CatalogTitles[$Role]
                }
            }
            else {
                [ordered]@{ Role = $Role; Kb = $null; Released = $null; Title = $null; Note = $(if ($Value -eq 'none') { 'Not found in the catalog' } else { $Value }) }
            }
        })

        # Anything not claimed by one of the catalog roles came from -UpdatePath.
        $PackageRoles = @{}
        $LcuFiles = @($script:Lcu | Where-Object { $_ })
        for ($n = 0; $n -lt $LcuFiles.Count; $n++) {
            $PackageRoles[(Split-Path -Leaf "$($LcuFiles[$n])")] = if ($n -eq $LcuFiles.Count - 1) { 'LCU' } else { 'Checkpoint' }
        }
        $OtherRoles = [ordered]@{ DotNet = $script:DotNet; SetupDU = $script:SetupDu; SafeOS = $script:SafeOs }
        foreach ($Role in @($OtherRoles.Keys)) {
            foreach ($File in @($OtherRoles[$Role] | Where-Object { $_ })) { $PackageRoles[(Split-Path -Leaf "$File")] = $Role }
        }
        # FromDownloadFolder is left behind on purpose. Only -AutoClean reads it, and only from the stamp.
        $Packages = @(foreach ($Record in @($script:UpdateFileRecords)) {
            $FileName = "$($Record.FileName)"
            [ordered]@{
                Kb       = if ($Record.Kb) { $Record.Kb } else { $null }
                Role     = if ($PackageRoles.ContainsKey($FileName)) { $PackageRoles[$FileName] } else { 'Supplied' }
                FileName = $FileName
                SizeMB   = $Record.SizeMB
                Sha256   = $Record.Sha256
            }
        })

        # Typed, unlike the strings the stamp hashes, so a script reading this gets real booleans and nulls.
        $BuildParameters = [ordered]@{}
        foreach ($ParamName in $script:BuildAffectingParameters) {
            $ParamValue = Get-Variable -Name $ParamName -ValueOnly -ErrorAction SilentlyContinue
            $BuildParameters[$ParamName] =
                if ($ParamValue -is [switch]) { $ParamValue.IsPresent }
                elseif ($null -eq $ParamValue -or "$ParamValue" -eq '') { $null }
                elseif ($AnonymousTattoo -and $ParamName -like '*Path') { Split-Path -Leaf "$ParamValue" }
                elseif ($ParamValue -is [array]) { , @($ParamValue | ForEach-Object { "$_" }) }
                else { $ParamValue }
        }

        $TattooInfo = [ordered]@{
            # Bumped whenever a field changes shape. Records written before this field existed are version 1.
            SchemaVersion = 2
            Build       = [ordered]@{
                # The tattoo goes on before oscdimg runs, so this is when the record was written, not when the ISO was.
                Started       = $script:ScriptStartTime.ToString($TimeFormat, $Invariant)
                Recorded      = (Get-Date).ToString($TimeFormat, $Invariant)
                Outcome       = if ($Failed.Count -gt 0 -or [int]$script:ServicingFailures -gt 0) { 'Completed with servicing warnings' } else { 'Completed' }
                ScriptVersion = $ScriptVersion
                IsoFileName   = Split-Path -Leaf $OutputIsoPath
                VolumeLabel   = $IsoVolumeLabel
                LogFile       = $LogFile
            }
            BuiltBy     = [ordered]@{
                Computer        = $env:COMPUTERNAME
                User            = "$env:USERDOMAIN\$env:USERNAME"
                OperatingSystem = "$($OsInfo.Caption) ($($OsInfo.Version))"
                PowerShell      = "$($PSVersionTable.PSVersion)"
                # Reuses the run header's read rather than asking Get-WinSystemLocale a second time.
                Locale          = [ordered]@{
                    ThreadCulture = "$($script:CurrentCulture.Name)"
                    UICulture     = "$($script:CurrentUICulture.Name)"
                    SystemLocale  = "$($script:SystemLocale)"
                }
                ScriptPath      = $script:ScriptPath
                CommandLine     = Get-ScriptCommandLine
            }
            SourceMedia = [ordered]@{
                FileName      = if ($SourceItem) { $SourceItem.Name } else { Split-Path -Leaf $ResolvedIso }
                SizeGB        = if ($SourceItem) { [math]::Round($SourceItem.Length / 1GB, 2) } else { 0 }
                Sha256        = $script:StampSourceHash
                Version       = $ImageVersionText
                FeatureUpdate = $FeatureName
                Architecture  = $ImageArch
                Language      = if ($script:MediaLanguage) { "$script:MediaLanguage" } else { $null }
                ImageCreated  = if ($ImageInfo.CreatedTime) { ([datetime]$ImageInfo.CreatedTime).ToString('yyyy-MM-dd', $Invariant) } else { $null }
                Editions      = $SourceEditions
            }
            Contents    = [ordered]@{
                FinalBuild         = if ($script:FinalBuildString) { $script:FinalBuildString } else { $ImageVersionText }
                EditionBuilds      = $script:EditionBuilds.ToArray()
                # Read from the offline hive while an edition was mounted to service it, since the media's
                # own language (SourceMedia.Language, above) is only what Setup offers, not what was captured.
                ImageLocale        = if ($script:FinalImageLocale) { "$script:FinalImageLocale" } else { $null }
                InstallImage       = Split-Path -Leaf $FinalInstallImage
                EditionsKept       = $KeptNames
                EditionsRemoved    = $RemovedNames
                EditionsNotUpdated = $UnpatchedNames
                AnswerFile         = if ($ResolvedUnattend) { [ordered]@{ FileName = 'autounattend.xml'; Source = Split-Path -Leaf $ResolvedUnattend; Sha256 = $script:UnattendHash } } else { $null }
                RecoveryImage      = [ordered]@{
                    Status   = $WinRe.Status
                    Reason   = $WinRe.Reason
                    SafeOsKb = if ($script:SafeOsKb) { "KB$($script:SafeOsKb)" } else { $null }
                    # Read from each edition's winre.wim header while it was mounted. Nothing else on the
                    # media says which recovery environment it will actually install.
                    Editions = @($script:WinReVersions | ForEach-Object {
                        $EntryIndex = if ($_.Label -match '^\[(\d+)\]') { [int]$Matches[1] } else { $null }
                        [ordered]@{ Index = $EntryIndex; Edition = ($_.Label -replace '^\[\d+\]\s*', ''); Before = $_.Before; After = $_.After }
                    })
                }
                ImageSizes         = @($script:WimSizes | ForEach-Object {
                    [ordered]@{ Image = $_.Label; ShippedAs = $_.AfterName; BeforeMB = [math]::Round($_.Before / 1MB); AfterMB = [math]::Round($_.After / 1MB) }
                })
            }
            Drivers     = if ($ResolvedDriverPath) {
                [ordered]@{
                    Source        = if ($AnonymousTattoo) { Split-Path -Leaf $ResolvedDriverPath } else { $ResolvedDriverPath }
                    Sha256        = $script:DriverHash
                    AllowUnsigned = [bool]$AllowUnsignedDrivers
                    Targets       = @('install.wim, every serviced edition', 'boot.wim index 2 (Windows Setup)')
                    Packages      = @($script:DriverInfFiles | ForEach-Object { $_.Name })
                }
            }
            else { $null }
            ExtraFiles  = if ($ResolvedExtraFiles) {
                [ordered]@{
                    Source        = if ($AnonymousTattoo) { Split-Path -Leaf $ResolvedExtraFiles } else { $ResolvedExtraFiles }
                    Sha256        = $script:ExtraFilesHash
                    FileCount     = $script:ExtraFilesCopied
                    ReplacedCount = $script:ExtraFileOverwrites.Count
                    # Paths are relative to the root of the ISO, so this is exactly what a stock Microsoft
                    # ISO would have had instead.
                    Replaced      = $script:ExtraFileOverwrites.ToArray()
                    # Every file that went on, hashed, so what is on the media can be told apart from what
                    # the folder holds today.
                    Files         = $script:ExtraFileRecords
                }
            }
            else { $null }
            Stripped    = [ordered]@{
                # /StartComponentCleanup /ResetBase, after which the images cannot be rolled back to their original patch level.
                ResetBase        = ($UpdateGroups.Count -gt 0)
                ResidueStripped  = [bool]$StripImageResidue
                ResidueMB        = [math]::Round($script:TattooResidueMB, 0)
                # Only ever populated when the source ISO was captured from an installed machine rather
                # than downloaded from Microsoft, which is worth knowing about the media you are holding.
                # .ToArray() rather than @(), which throws "Argument types do not match" on 5.1.
                CaptureLeftovers = $script:TattooResidueFound.ToArray()
            }
            Updates     = [ordered]@{
                CatalogSelection = $CatalogSelection
                Packages         = $Packages
                Servicing        = $script:TattooServicing.ToArray()
                FailedCount      = $Failed.Count
            }
            BuildParameters = $BuildParameters
        }
        if ($AnonymousTattoo) {
            foreach ($Key in 'Computer', 'User', 'ScriptPath', 'CommandLine') { $TattooInfo.BuiltBy.Remove($Key) }
            $TattooInfo.Build.Remove('LogFile')
            # Says the gap is deliberate, so nobody reads it as a record that failed to write.
            $TattooInfo.BuiltBy['IdentityOmitted'] = $true
        }

        Write-BuildTattoo -MediaRoot $ExtractDir -Info $TattooInfo -ScriptSource $script:ScriptPath | Out-Null
    }
}

#endregion

