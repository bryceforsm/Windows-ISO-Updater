#region Defender exclusion (-ExcludeWorkPathFromDefender)
# Real-time scanning inspects every file DISM writes into a mounted image, and an image holds hundreds of
# thousands of them, so it slows applying updates, the component store cleanup and the commit alike.
# Microsoft's guidance for servicing images is to exclude the mount folder, and -ExcludeWorkPathFromDefender
# does that, for the length of one run, for the folders under the working folder where DISM does that work.
# Downloads, Output and OutputStaging stay scanned: they hold files from the internet and the finished ISO,
# and each of those is read only once, so scanning them costs little.
#
# The exclusions are a change to the host, so they have to come off again however the run ends. PowerShell's
# own exit event does not fire for a script run with -File, so a hidden watcher process waits for this one to
# end, whether by exit, error, Ctrl+C or a closed window, and removes them then. A marker file in the working
# folder records which run added which ones, so a run cut short by a restart is cleaned up by the next run
# instead. An exclusion that was already there before the run is never touched.

function Get-DefenderExclusionMarker {
    return (Join-Path -Path $WorkRoot -ChildPath 'DefenderExclusion.json')
}

# The folders DISM mounts into and writes the media to. docs\reference.md lists them with what each is for.
function Get-DefenderExclusionFolders {
    param([Parameter(Mandatory)][string]$WorkRoot)
    return @('ISO', 'Mount', 'WinREMount', 'BuildCheck', 'WinRECache' | ForEach-Object { Join-Path -Path $WorkRoot.TrimEnd('\') -ChildPath $_ })
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
# Read from the WMI class Get-MpComputerStatus wraps, because loading the Defender module costs a second and
# the environment report in every run's log header asks too.
function Get-DefenderState {
    try { $Status = Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName MSFT_MpComputerStatus -ErrorAction Stop }
    catch { return 'Unavailable' }
    if (-not $Status) { return 'Unavailable' }
    # Older Windows 10 builds do not report a running mode at all, and are always the active antivirus.
    if ($Status.AMRunningMode -and "$($Status.AMRunningMode)" -ne 'Normal') { return 'Passive' }
    if (-not $Status.RealTimeProtectionEnabled) { return 'Off' }
    return 'Active'
}

function Add-WorkPathDefenderExclusion {
    param([Parameter(Mandatory)][string]$WorkRoot)

    switch (Get-DefenderState) {
        'Unavailable' {
            Write-HostTimestamp '-ExcludeWorkPathFromDefender: Microsoft Defender is not available on this machine, so there is nothing to exclude the working folders from.' -ForegroundColor Yellow
            return
        }
        'Passive' {
            Write-HostTimestamp '-ExcludeWorkPathFromDefender: another antivirus is doing the scanning on this machine, so a Defender exclusion would change nothing. Exclude the working folders in that antivirus instead.' -ForegroundColor Yellow
            return
        }
        'Off' {
            Write-HostTimestamp '-ExcludeWorkPathFromDefender: Defender real-time protection is already off, so there is nothing to exclude.' -ForegroundColor DarkGray
            return
        }
    }

    $Folders = Get-DefenderExclusionFolders -WorkRoot $WorkRoot
    $Names = ($Folders | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
    try {
        $Existing = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
        # Only the folders not already on the list are added, and only those are recorded for removal.
        $ToAdd = @($Folders | Where-Object { -not (Test-PathInList -List $Existing -Path $_) })
        if ($ToAdd.Count -eq 0) {
            Write-HostTimestamp "The working folders ($Names) are already excluded from Defender scanning, so those exclusions are left as they are." -ForegroundColor DarkGray
            return
        }
        # Written before the exclusions are added, so no moment exists where Defender has them and nothing
        # records that they have to come off again.
        $Marker = Get-DefenderExclusionMarker
        [ordered]@{ Paths = $ToAdd; Pid = $PID; Added = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $Marker -Encoding UTF8 -ErrorAction Stop
        Add-MpPreference -ExclusionPath $ToAdd -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath (Get-DefenderExclusionMarker) -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp "Could not exclude the working folders from Defender scanning: $($_.Exception.Message). The build carries on with scanning as usual." -ForegroundColor Yellow
        return
    }

    # Exclusions managed by Group Policy or Intune can make a local one silently not apply. Where the list
    # itself is hidden from administrators it reads back as "N/A: ...", and there is no way to check.
    $After = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath)
    $Missing = @($ToAdd | Where-Object { -not (Test-PathInList -List $After -Path $_) })
    if ($Missing.Count -eq $ToAdd.Count -and -not ($After | Where-Object { "$_" -like 'N/A*' })) {
        Remove-Item -LiteralPath (Get-DefenderExclusionMarker) -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp 'Defender did not take the exclusions, most likely because its exclusions are managed by policy on this machine. The build carries on with scanning as usual.' -ForegroundColor Yellow
        return
    }

    $script:DefenderExclusionPaths = $ToAdd
    Start-DefenderExclusionWatcher
    Write-HostTimestamp "Excluded the folders DISM works in from Defender real-time scanning for this run: $Names (in $($WorkRoot.TrimEnd('\')))" -ForegroundColor Yellow
    Write-HostTimestamp '  The exclusions come off again when the run ends, however it ends. Downloads and the finished ISO are still scanned.' -ForegroundColor DarkGray
}

# A hidden process that outlives this one by a moment: it waits for this process to end, then removes the
# exclusions if the marker still says this run added them. A later run that has since taken the working folder
# over rewrites the marker with its own process ID, so its exclusions are never removed from under it.
function Start-DefenderExclusionWatcher {
    $Marker = (Get-DefenderExclusionMarker) -replace "'", "''"
    $Code = @"
`$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id $PID
`$Record = Get-Content -LiteralPath '$Marker' -Raw | ConvertFrom-Json
if (`$Record -and [int]`$Record.Pid -eq $PID) {
    # The marker goes only once the exclusions have, so a removal that failed is retried by the next run.
    try {
        Remove-MpPreference -ExclusionPath @(`$Record.Paths) -ErrorAction Stop
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
        # Not fatal: the normal end of the run removes them, and the next run clears a marker left behind.
        Write-HostTimestamp "  Could not start the process that removes the exclusions if this run is cut short: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# Called as the run finishes, so the exclusions are gone before the window waits for Enter.
function Remove-WorkPathDefenderExclusion {
    if (-not $script:DefenderExclusionPaths) { return }
    try {
        Remove-MpPreference -ExclusionPath $script:DefenderExclusionPaths -ErrorAction Stop
        Remove-Item -LiteralPath (Get-DefenderExclusionMarker) -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp "Removed the Defender exclusions for the working folders: $(($script:DefenderExclusionPaths | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')" -ForegroundColor DarkGray
        $script:DefenderExclusionPaths = $null
    }
    catch {
        # The watcher tries again once the process ends, and the next run after that.
        Write-HostTimestamp "Could not remove the Defender exclusions yet ($($_.Exception.Message)). They are removed when this window closes." -ForegroundColor Yellow
    }
}

# A marker found at startup belongs to a run that never got to remove its exclusions, because a restart or
# power cut took the watcher down with it. This run holds the working folder's lock, so that run is over.
function Clear-StaleDefenderExclusion {
    $Marker = Get-DefenderExclusionMarker
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return }
    try {
        $Record = Get-Content -LiteralPath $Marker -Raw -ErrorAction Stop | ConvertFrom-Json
        $Paths = @($Record.Paths | Where-Object { $_ })
        if ($Paths.Count -gt 0 -and (Get-Command -Name Remove-MpPreference -ErrorAction SilentlyContinue)) {
            Remove-MpPreference -ExclusionPath $Paths -ErrorAction Stop
            Write-HostTimestamp "Removed the Defender exclusions an interrupted run left behind: $($Paths -join ', ')" -ForegroundColor DarkGray
            Write-Host $LineBreak
        }
        Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-HostTimestamp "Could not remove the Defender exclusions an interrupted run left behind: $($_.Exception.Message). Remove them in Windows Security if they are still listed." -ForegroundColor Yellow
    }
}
#endregion

