#region Defender exclusion (-ExcludeWorkPathFromDefender)
# Real-time scanning inspects every file DISM writes into a mounted image, and an image holds hundreds of
# thousands of them, so it slows applying updates, the component store cleanup and the commit alike.
# Microsoft's guidance for servicing images is to exclude the mount folder, and -ExcludeWorkPathFromDefender
# does that for the working folder, for the length of one run.
#
# The exclusion is a change to the host, so it has to come off again however the run ends. PowerShell's own
# exit event does not fire for a script run with -File, so a hidden watcher process waits for this one to
# end, whether by exit, error, Ctrl+C or a closed window, and removes it then. A marker file in the working
# folder records which run added it, so a run cut short by a restart is cleaned up by the next run instead.
# An exclusion that was already there before the run is never touched.

function Get-DefenderExclusionMarker {
    return (Join-Path -Path $WorkRoot -ChildPath 'DefenderExclusion.json')
}

# Whether a path is on Defender's exclusion list, ignoring case and a trailing backslash.
function Test-PathInList {
    param(
        [string[]]$List,
        [Parameter(Mandatory)][string]$Path
    )
    $Want = $Path.TrimEnd('\')
    foreach ($Item in @($List)) {
        if ("$Item".TrimEnd('\') -eq $Want) { return $true }
    }
    return $false
}

# What Defender is doing on this machine: Active, Off (real-time protection is turned off), Passive (another
# antivirus is the active one, so Defender's exclusions change nothing), or Unavailable.
function Get-DefenderState {
    if (-not (Get-Command -Name Add-MpPreference -ErrorAction SilentlyContinue)) { return 'Unavailable' }
    try { $Status = Get-MpComputerStatus -ErrorAction Stop }
    catch { return 'Unavailable' }
    # Older Windows 10 builds do not report a running mode at all, and are always the active antivirus.
    if ($Status.AMRunningMode -and "$($Status.AMRunningMode)" -ne 'Normal') { return 'Passive' }
    if (-not $Status.RealTimeProtectionEnabled) { return 'Off' }
    return 'Active'
}

function Add-WorkPathDefenderExclusion {
    param([Parameter(Mandatory)][string]$Path)

    $Path = $Path.TrimEnd('\')
    switch (Get-DefenderState) {
        'Unavailable' {
            Write-HostTimestamp '-ExcludeWorkPathFromDefender: Microsoft Defender is not available on this machine, so there is nothing to exclude the working folder from.' -ForegroundColor Yellow
            return
        }
        'Passive' {
            Write-HostTimestamp '-ExcludeWorkPathFromDefender: another antivirus is doing the scanning on this machine, so a Defender exclusion would change nothing. Exclude the working folder in that antivirus instead.' -ForegroundColor Yellow
            return
        }
        'Off' {
            Write-HostTimestamp '-ExcludeWorkPathFromDefender: Defender real-time protection is already off, so there is nothing to exclude.' -ForegroundColor DarkGray
            return
        }
    }

    try {
        if (Test-PathInList -List (Get-MpPreference -ErrorAction Stop).ExclusionPath -Path $Path) {
            Write-HostTimestamp "The working folder is already excluded from Defender scanning, so that exclusion is left as it is: $Path" -ForegroundColor DarkGray
            return
        }
        # Written before the exclusion is added, so no moment exists where Defender has it and nothing
        # records that it has to come off again.
        $Marker = Get-DefenderExclusionMarker
        [ordered]@{ Path = $Path; Pid = $PID; Added = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $Marker -Encoding UTF8 -ErrorAction Stop
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath (Get-DefenderExclusionMarker) -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp "Could not exclude the working folder from Defender scanning: $($_.Exception.Message). The build carries on with scanning as usual." -ForegroundColor Yellow
        return
    }

    # Exclusions managed by Group Policy or Intune can make a local one silently not apply. Where the list
    # itself is hidden from administrators it reads back as "N/A: ...", and there is no way to check.
    $After = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath)
    if (-not (Test-PathInList -List $After -Path $Path) -and -not ($After | Where-Object { "$_" -like 'N/A*' })) {
        Remove-Item -LiteralPath (Get-DefenderExclusionMarker) -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp 'Defender did not take the exclusion, most likely because its exclusions are managed by policy on this machine. The build carries on with scanning as usual.' -ForegroundColor Yellow
        return
    }

    $script:DefenderExclusionPath = $Path
    Start-DefenderExclusionWatcher -Path $Path
    Write-HostTimestamp "Excluded the working folder from Defender real-time scanning for this run: $Path" -ForegroundColor Yellow
    Write-HostTimestamp '  The exclusion comes off again when the run ends, however it ends. Nothing in that folder is scanned until then.' -ForegroundColor DarkGray
}

# A hidden process that outlives this one by a moment: it waits for this process to end, then removes the
# exclusion if the marker still says this run added it. A later run that has since taken the working folder
# over rewrites the marker with its own process ID, so its exclusion is never removed from under it.
function Start-DefenderExclusionWatcher {
    param([Parameter(Mandatory)][string]$Path)
    $Marker = (Get-DefenderExclusionMarker) -replace "'", "''"
    $Code = @"
`$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id $PID
`$Record = Get-Content -LiteralPath '$Marker' -Raw | ConvertFrom-Json
if (`$Record -and [int]`$Record.Pid -eq $PID) {
    # The marker goes only once the exclusion has, so a removal that failed is retried by the next run.
    try {
        Remove-MpPreference -ExclusionPath `$Record.Path -ErrorAction Stop
        Remove-Item -LiteralPath '$Marker' -Force
    }
    catch { }
}
"@
    try {
        $Shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $Encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Code))
        Start-Process -FilePath $Shell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $Encoded" -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }
    catch {
        # Not fatal: the normal end of the run removes it, and the next run clears a marker left behind.
        Write-HostTimestamp "  Could not start the process that removes the exclusion if this run is cut short: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# Called as the run finishes, so the exclusion is gone before the window waits for Enter.
function Remove-WorkPathDefenderExclusion {
    if (-not $script:DefenderExclusionPath) { return }
    try {
        Remove-MpPreference -ExclusionPath $script:DefenderExclusionPath -ErrorAction Stop
        Remove-Item -LiteralPath (Get-DefenderExclusionMarker) -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp "Removed the Defender exclusion for the working folder: $script:DefenderExclusionPath" -ForegroundColor DarkGray
        $script:DefenderExclusionPath = $null
    }
    catch {
        # The watcher tries again once the process ends, and the next run after that.
        Write-HostTimestamp "Could not remove the Defender exclusion yet ($($_.Exception.Message)). It is removed when this window closes." -ForegroundColor Yellow
    }
}

# A marker found at startup belongs to a run that never got to remove its exclusion, because a restart or
# power cut took the watcher down with it. This run holds the working folder's lock, so that run is over.
function Clear-StaleDefenderExclusion {
    $Marker = Get-DefenderExclusionMarker
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return }
    try {
        $Record = Get-Content -LiteralPath $Marker -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($Record.Path -and (Get-Command -Name Remove-MpPreference -ErrorAction SilentlyContinue)) {
            Remove-MpPreference -ExclusionPath $Record.Path -ErrorAction Stop
            Write-HostTimestamp "Removed a Defender exclusion an interrupted run left behind: $($Record.Path)" -ForegroundColor DarkGray
            Write-Host $LineBreak
        }
        Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-HostTimestamp "Could not remove the Defender exclusion an interrupted run left behind: $($_.Exception.Message). Remove it in Windows Security if it is still listed." -ForegroundColor Yellow
    }
}
#endregion
#endregion

