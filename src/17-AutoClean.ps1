#region Housekeeping (-AutoClean)
# Only files this script recorded in a stamp are ever deleted, so anything else living in the same folders
# (a hand-placed ISO, someone else's .msu) is left completely alone.
function Invoke-AutoClean {
    param(
        $CurrentStamp,
        [object[]]$History,
        [int]$KeepIsoCount,
        [string[]]$Protected
    )

    $ProtectedPaths = @(@($Protected) | Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\').ToLowerInvariant() })

    # 1. Update packages: everything a stamp says was downloaded into the download folder, except the ones
    #    the newest build still uses.
    $Keep = @()
    if ($CurrentStamp -and $CurrentStamp.Updates -and $CurrentStamp.Updates.Files) {
        $Keep = @($CurrentStamp.Updates.Files | ForEach-Object { "$($_.FileName)" })
    }
    $Known = New-Object System.Collections.Generic.List[string]
    foreach ($Stamp in @($History)) {
        if (-not $Stamp -or -not $Stamp.Updates -or -not $Stamp.Updates.Files) { continue }
        foreach ($Entry in @($Stamp.Updates.Files)) {
            # Packages the user pointed at with -UpdatePath are not ours to delete.
            if ($Entry.FileName -and $Entry.FromDownloadFolder) { $Known.Add("$($Entry.FileName)") }
        }
    }

    $RemovedUpdates = 0
    $FreedMB = 0
    foreach ($Name in @($Known | Sort-Object -Unique)) {
        if ($Keep -contains $Name) { continue }
        # A stamp is written by this script, but it is still a file on disk: never let a name out of one
        # escape the download folder.
        if ($Name -match '[\\/:]' -or $Name -notmatch '(?i)\.(msu|cab)$') { continue }
        $Path = Join-Path -Path $DlDir -ChildPath $Name
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
        if ($ProtectedPaths -contains $Path.ToLowerInvariant()) { continue }
        try {
            $SizeMB = (Get-Item -LiteralPath $Path).Length / 1MB
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            $RemovedUpdates++
            $FreedMB += $SizeMB
            Write-HostTimestamp ('  Deleted superseded update: {0} ({1:N0} MB)' -f $Name, $SizeMB) -ForegroundColor DarkGray
        }
        catch { Write-HostTimestamp "  Could not delete '$Name': $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($RemovedUpdates -eq 0) { Write-HostTimestamp '  No superseded update packages to remove.' -ForegroundColor DarkGray }

    # 2. Generated ISOs: keep the newest -KeepIsoCount, delete the rest. Candidates are the ISOs named in
    #    the stamps plus any still sitting in the output folder under this script's generated name pattern
    #    (their stamp may have aged out of the history).
    $Candidates = @{}
    foreach ($Stamp in (@($CurrentStamp) + @($History))) {
        if (-not $Stamp -or -not $Stamp.Output -or -not $Stamp.Output.Path) { continue }
        $Item = Get-Item -LiteralPath "$($Stamp.Output.Path)" -ErrorAction SilentlyContinue
        if ($Item -and -not $Item.PSIsContainer) { $Candidates[$Item.FullName.ToLowerInvariant()] = $Item }
    }
    # Must track every tag Get-DefaultIsoName can emit, including the Server release names and the
    # optional locale tag between architecture and build. The old Server* tags stay listed so ISOs from
    # before the rename are still recognised as this script's own work.
    $GeneratedName = '(Win10|Win11|Windows|WinSrv[A-Za-z0-9]*|Server[A-Za-z0-9]*)_[A-Za-z0-9]+_[A-Za-z0-9]+(_[A-Za-z0-9]+)?(_[\d.]+)?_\d{8}-\d{4}.*\.iso$'
    # When the output is a remote file path, $FinishedIsoDir is still the default local folder and any ISOs
    # there are orphans from earlier runs, not candidates for this remote-output run.
    if (-not $OutputIsRemote) {
        foreach ($Item in @(Get-ChildItem -LiteralPath $FinishedIsoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
            # A -RecoveryIsoPath ISO follows the same naming but must not use up a -KeepIsoCount slot.
            if ($Item.Name -match $GeneratedName -and $Item.Name -notmatch '_Recovery_') { $Candidates[$Item.FullName.ToLowerInvariant()] = $Item }
        }
    }

    if ($Candidates.Count -gt 0) {
        Write-HostTimestamp "AutoClean candidates ($($Candidates.Count)):" -ForegroundColor DarkGray
        foreach ($Candidate in $Candidates.Values) {
            Write-HostTimestamp "  $($Candidate.FullName)" -ForegroundColor DarkGray
        }
    }

    $Ordered = @($Candidates.Values | Sort-Object -Property LastWriteTime -Descending)
    $Stale = @($Ordered | Select-Object -Skip $KeepIsoCount | Where-Object { $ProtectedPaths -notcontains $_.FullName.ToLowerInvariant() })
    if ($Ordered.Count -gt 0) {
        Write-HostTimestamp "  Found $($Ordered.Count) generated ISO(s), keeping the newest $KeepIsoCount." -ForegroundColor DarkGray
    }
    $RemovedIsos = 0
    foreach ($Item in $Stale) {
        try {
            $SizeMB = $Item.Length / 1MB
            Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
            $RemovedIsos++
            $FreedMB += $SizeMB
            Write-HostTimestamp ('  Deleted old ISO: {0} ({1:N0} MB)' -f $Item.Name, $SizeMB) -ForegroundColor DarkGray
        }
        catch { Write-HostTimestamp "  Could not delete '$($Item.FullName)': $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($RemovedIsos -eq 0) { Write-HostTimestamp '  No old ISOs to remove.' -ForegroundColor DarkGray }

    # 3. Locally cached source ISOs: a copy this script made of a remote/cloud -IsoPath under $DlDir, using
    #    the source's own file name. A stamp only records a RemoteOrigin when that happened, so an ISO the
    #    user dropped into $DlDir themselves, or one this script downloaded directly, is never a candidate.
    $KeepSourceIso = @()
    if ($CurrentStamp -and $CurrentStamp.Source -and "$($CurrentStamp.Source.RemoteOrigin)") {
        $KeepSourceIso = @("$($CurrentStamp.Source.FileName)")
    }
    $KnownSourceIso = @{}
    foreach ($Stamp in @($History)) {
        if (-not $Stamp -or -not $Stamp.Source -or -not "$($Stamp.Source.RemoteOrigin)") { continue }
        $FileName = "$($Stamp.Source.FileName)"
        # History is newest first, so the first record seen for a name is the one whose size is trusted.
        if ($FileName -and -not $KnownSourceIso.ContainsKey($FileName)) { $KnownSourceIso[$FileName] = [int64]$Stamp.Source.Length }
    }

    $RemovedSourceIsos = 0
    foreach ($FileName in @($KnownSourceIso.Keys | Sort-Object)) {
        if ($KeepSourceIso -contains $FileName) { continue }
        # A stamp is written by this script, but it is still a file on disk: never let a name out of one
        # escape the download folder.
        if ($FileName -match '[\\/:]' -or $FileName -notmatch '(?i)\.iso$') { continue }
        $Path = Join-Path -Path $DlDir -ChildPath $FileName
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
        if ($ProtectedPaths -contains $Path.ToLowerInvariant()) { continue }
        $OnDisk = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        # A same-named file whose size no longer matches what was stamped is not the file this script
        # cached, so it is left alone rather than risk deleting something the user swapped in by hand.
        if (-not $OnDisk -or ($KnownSourceIso[$FileName] -gt 0 -and $OnDisk.Length -ne $KnownSourceIso[$FileName])) { continue }
        try {
            $SizeMB = $OnDisk.Length / 1MB
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            $RemovedSourceIsos++
            $FreedMB += $SizeMB
            Write-HostTimestamp ('  Deleted stale cached source ISO: {0} ({1:N0} MB)' -f $FileName, $SizeMB) -ForegroundColor DarkGray
        }
        catch { Write-HostTimestamp "  Could not delete '$FileName': $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($RemovedSourceIsos -eq 0) { Write-HostTimestamp '  No stale cached source ISOs to remove.' -ForegroundColor DarkGray }

    # 4. Recovery ISOs, counted on their own so they never take an installation ISO's -KeepIsoCount slot.
    $RemovedRecoveryIsos = 0
    if ($RecoveryIsoDir) {
        $RecoveryCleanup = Remove-StaleRecoveryIso -Directory $RecoveryIsoDir -KeepCount $KeepIsoCount -Protected $ProtectedPaths
        $RemovedRecoveryIsos = $RecoveryCleanup.Removed
        $FreedMB += $RecoveryCleanup.FreedMB
    }

    Write-HostTimestamp ('  Cleanup removed {0} update package(s), {1} ISO(s), {2} recovery ISO(s) and {3} cached source ISO(s), freeing {4:N1} GB.' -f $RemovedUpdates, $RemovedIsos, $RemovedRecoveryIsos, $RemovedSourceIsos, ($FreedMB / 1024)) -ForegroundColor Green
}

#endregion

