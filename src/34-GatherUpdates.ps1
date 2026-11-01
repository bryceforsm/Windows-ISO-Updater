#region Gather the update packages to integrate
# Each entry in $UpdateGroups is an ordered array of related packages with the TARGET last (e.g. the LCU
# group is [checkpoint..., LCU]). Groups are applied independently with the documented sole-target method.
$UpdateGroups = New-Object System.Collections.Generic.List[object]
$SafeOsGroup = $null
$script:SetupDu = $null
# The Safe OS KB and the builds it delivers, shared so the per-edition WinRE check asks the support page once.
$script:SafeOsKb = $null
$script:SafeOsTargets = $null

if ($SkipUpdates -or $SkipServicing) {
    Write-HostTimestamp 'Skipping update integration (-SkipUpdates was specified).' -ForegroundColor Yellow
    Write-Host $LineBreak
}
elseif ($UpdatePath) {
    $script:UpdateFiles = @()
    Invoke-Task -Description "Collecting update packages from $UpdatePath ..." -ScriptBlock {
        if (-not (Test-Path -LiteralPath $UpdatePath)) { throw "The update folder '$UpdatePath' does not exist." }
        $Found = Get-ChildItem -Path $UpdatePath -Include '*.msu', '*.cab' -File -Recurse -ErrorAction SilentlyContinue
        $script:UpdateFiles = @($Found | ForEach-Object { $_.FullName })
        if (-not $script:UpdateFiles -or $script:UpdateFiles.Count -eq 0) {
            throw "No .msu or .cab packages were found in '$UpdatePath'."
        }
        Write-HostTimestamp "  Found $($script:UpdateFiles.Count) package(s)." -ForegroundColor Green
    }
    # Treat the supplied files as one group ordered by KB ascending, so the latest (target) is applied last
    # and any prior checkpoints are staged alongside it.
    $OrderedUserFiles = @($script:UpdateFiles | Sort-Object { if ((Split-Path -Leaf $_) -match '(?i)kb(\d{6,})') { [int]$Matches[1] } else { 0 } })
    $UpdateGroups.Add($OrderedUserFiles)
    Write-Host $LineBreak
}
else {
    # Dropping the version token narrows a client query to the right product family, but the server one
    # becomes "Microsoft server operating system", which matches every release and would hand back the
    # newest Server LCU no matter how old this media is.
    if ($script:EffectiveServer -and -not $FeatureName) {
        Write-HostTimestamp "Neither this script nor the image itself could name the release build $ImageBuild belongs to, so there is no catalog query that can identify this media." -ForegroundColor Red
        Write-HostTimestamp '  Searching on the product name alone would return an update for a different Server release, which DISM would refuse to apply, so this run stops here.' -ForegroundColor Red
        Write-HostTimestamp '  Supply the packages yourself with -UpdatePath, or use -SkipUpdates to repack the media unchanged.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 1
    }
    if (-not $FeatureName) {
        Write-HostTimestamp 'Could not determine the feature-update name from the image, so the catalog search may be less precise.' -ForegroundColor Yellow
    }

    Invoke-Task -Description 'Downloading the latest cumulative update from the Microsoft Update Catalog...' -ScriptBlock {
        # The monthly LCU is titled e.g. "2026-07 Cumulative Update for Windows 11 Version 25H2 for
        # x64-based Systems (KB...)" and classified as a Security Update. Restrict the match to real
        # cumulative updates and exclude the .NET / Dynamic Update entries the same query returns. The
        # optional "Preview" word has to be allowed through here, because whether a preview is acceptable
        # is -IncludePreview's decision to make, not this pattern's.
        $Query = "Cumulative Update for $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) for $CatalogArch-based Systems"
        $Include = '(?i)cumulative update (preview )?for (windows|microsoft server operating system)'
        $Exclude = '(?i)\.net|dynamic update'
        $script:LcuUpToDate = $null
        $script:LcuSkippedBaselineOnly = $false
        $script:LcuReapplied = $false
        $script:LcuReleaseDate = $null
        $script:Lcu = Get-LatestCatalogPackage -Query $Query -DownloadDir $DlDir -TitleInclude $Include -TitleExclude $Exclude -AllowPreview:$IncludePreview -CurrentBuild $ImageBuild -CurrentUbr $ImageUbr -VerifyWimPath $InstallWimExtracted -VerifyPatchLevel:$VerifyPatchLevel -Reapply:$ReapplyUpdates -AlreadyCurrent ([ref]$script:LcuUpToDate) -BaselineOnly:$BaselineOnly -SelectedDate ([ref]$script:LcuReleaseDate)
        if (-not $script:Lcu -and -not $script:LcuUpToDate -and -not $script:EffectiveServer) {
            # Retry with a looser query (some releases omit the "Version xxHx" token in the title). Server
            # media is excluded because its product name without the version matches every Server release.
            $Query2 = "Cumulative Update for $(Get-CatalogProductQuery) for $CatalogArch-based Systems"
            Write-HostTimestamp "  Retrying with a broader query: $Query2" -ForegroundColor Yellow
            $script:Lcu = Get-LatestCatalogPackage -Query $Query2 -DownloadDir $DlDir -TitleInclude $Include -TitleExclude $Exclude -AllowPreview:$IncludePreview -CurrentBuild $ImageBuild -CurrentUbr $ImageUbr -VerifyWimPath $InstallWimExtracted -VerifyPatchLevel:$VerifyPatchLevel -Reapply:$ReapplyUpdates -AlreadyCurrent ([ref]$script:LcuUpToDate) -BaselineOnly:$BaselineOnly -SelectedDate ([ref]$script:LcuReleaseDate)
        }
    }
    if ($script:Lcu) {
        $UpdateGroups.Add(@($script:Lcu))
        if ($script:LcuReapplied) {
            Write-HostTimestamp 'WARNING: -ReapplyUpdates is integrating updates into media that already carries them. This may leave the Setup binaries on the media mismatched with the ones inside boot.wim, which can stop Windows 11 Setup Dynamic Update from completing when imaging a computer with Windows 11.' -ForegroundColor Yellow
            Write-Host $LineBreak
        }
    }
    elseif ($script:LcuUpToDate) {
        # Nothing will change the OS build now, so reuse the build already confirmed by the check.
        if (-not $script:FinalBuildString) { $script:FinalBuildString = $script:LcuUpToDate }
        Write-HostTimestamp "The image is already fully patched ($script:LcuUpToDate), so no cumulative update is needed." -ForegroundColor Green
        Add-ServicingResult -Image 'install.wim, boot.wim, winre.wim and the media sources folder' -Package 'Cumulative, .NET, Setup and Safe OS Dynamic Updates' -Result 'Skipped' -Detail "The media is already at $script:LcuUpToDate, so it is left as it shipped"
        Write-HostTimestamp '  The .NET update, both Dynamic Updates and boot.wim are left exactly as the media shipped them, so its Setup files stay matched to its images. Use -ReapplyUpdates to integrate everything anyway.' -ForegroundColor DarkGray
        Write-Host $LineBreak
    }
    elseif ($script:LcuSkippedBaselineOnly) {
        Write-HostTimestamp '  WARNING: no baseline cumulative update was found, so the image keeps the patch level of the source ISO. Supply the baseline package with -UpdatePath if that level is too old.' -ForegroundColor Yellow
        Write-Host $LineBreak
    }
    else {
        Write-HostTimestamp 'Could not obtain a cumulative update from the catalog. You can supply one with -UpdatePath, or use -SkipUpdates to just recompile the ISO.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }

    if (-not $SkipDotNet -and -not $script:LcuUpToDate) {
        Invoke-Task -Description 'Downloading the latest .NET cumulative update from the Microsoft Update Catalog...' -ScriptBlock {
            $Query = "Cumulative Update for .NET Framework $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) for $CatalogArch"
            $script:DotNet = Get-LatestCatalogPackage -Query $Query -DownloadDir $DlDir -TitleInclude '(?i)\.net framework' -TitleExclude '(?i)dynamic update' -AllowPreview:$IncludePreview
        }
        if ($script:DotNet) { $UpdateGroups.Add(@($script:DotNet)) }
        else {
            Write-HostTimestamp '  No .NET cumulative update was integrated (none found).' -ForegroundColor Yellow
            Write-Host $LineBreak
        }
    }

    # The Setup Dynamic Update is NOT applied to an image - it is expanded over the media's sources
    # folder, which is what keeps the loose Setup binaries, compatibility database and component
    # manifests in step with the serviced boot.wim. It is therefore kept out of $UpdateGroups.
    if (-not $SkipSetupDU -and -not $script:LcuUpToDate) {
        Invoke-Task -Description 'Downloading the latest Setup Dynamic Update from the Microsoft Update Catalog...' -ScriptBlock {
            # Bounded by the LCU's own release date, since a DU published after it can carry Setup logic
            # the LCU's servicing stack does not yet expect.
            $SetupDuArgs = @{
                Query        = "Setup Dynamic Update $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) $CatalogArch"
                DownloadDir  = $DlDir
                TitleInclude = '(?i)setup dynamic update'
                AllowPreview = $IncludePreview
            }
            if ($script:LcuReleaseDate) { $SetupDuArgs.NotAfter = $script:LcuReleaseDate }
            $script:SetupDu = Get-LatestCatalogPackage @SetupDuArgs
        }
        if (-not $script:SetupDu) {
            Write-HostTimestamp '  No Setup Dynamic Update was found. The media Setup files will only be refreshed from boot.wim, which can make Windows Setup fail on the finished ISO.' -ForegroundColor Yellow
            if ($script:EffectiveServer) {
                Write-HostTimestamp '  Microsoft only publishes one for Server 2025 and newer, so this is expected on older Server media.' -ForegroundColor DarkGray
            }
            Write-Host $LineBreak
        }
    }

    if (-not $SkipWinRE -and -not $script:LcuUpToDate) {
        Invoke-Task -Description 'Looking for a Safe OS Dynamic Update for the recovery image (WinRE)...' -ScriptBlock {
            # Server media labels the Safe OS package plain "Dynamic Update", so the Setup one is excluded
            # by name instead of the Safe OS one being required by name.
            $SafeInclude = if ($script:EffectiveServer) { '(?i)dynamic update' } else { '(?i)safe os dynamic update' }
            # Bounded by the LCU's release date for the same reason the Setup DU is: a Safe OS package
            # published later targets a servicing stack this month's LCU has not put in the image yet.
            $SafeOsArgs = @{
                Query        = "Safe OS Dynamic Update $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) $CatalogArch"
                DownloadDir  = $DlDir
                TitleInclude = $SafeInclude
                TitleExclude = '(?i)setup dynamic update'
                AllowPreview = $IncludePreview
            }
            if ($script:LcuReleaseDate) { $SafeOsArgs.NotAfter = $script:LcuReleaseDate }
            $script:SafeOs = Get-LatestCatalogPackage @SafeOsArgs
        }
        if ($script:SafeOs) {
            $SafeOsGroup = @($script:SafeOs)
            # Read off the package name so the per-edition check can ask the support page what build it delivers.
            foreach ($File in $SafeOsGroup) {
                if ((Split-Path -Leaf "$File") -match '(?i)kb(\d{6,})') { $script:SafeOsKb = $Matches[1]; break }
            }
        }
        else {
            Write-HostTimestamp '  No Safe OS Dynamic Update was found, so WinRE update integration will be skipped (per Microsoft, the LCU does not apply to WinRE).' -ForegroundColor Yellow
            Write-Host $LineBreak
        }
    }
}

# Everything that will be integrated, flattened for the build stamp (and so -AutoClean later knows which
# downloads belong to which build).
$script:StampUpdateFiles = @()
foreach ($Group in $UpdateGroups) { $script:StampUpdateFiles += @($Group) }
if ($script:SetupDu) { $script:StampUpdateFiles += @($script:SetupDu) }
if ($SafeOsGroup) { $script:StampUpdateFiles += @($SafeOsGroup) }
# Hashed here, once, because both the media tattoo and the build stamp describe the same packages.
$script:UpdateFileRecords = @(Get-UpdateFileRecords -Paths $script:StampUpdateFiles -DownloadDir $DlDir)

#endregion

