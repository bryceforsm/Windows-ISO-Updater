#region Mount recovery
# Last resort for a mount that nothing in this session can release. At boot the WIM filter driver has not
# re-attached anything yet, so a task running as SYSTEM (which outranks the TrustedInstaller ACLs DISM
# leaves on the files) can clear the folder before anything claims it. The task deletes itself afterwards
# so a machine is never left with a stray task from a failed build.
function Register-MountCleanupTask {
    param([Parameter(Mandatory)][string[]]$Path)

    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) { return $false }

    $CleanupTaskName = 'Windows-ISO-Updater Mount Cleanup'
    $ToolsDir = Join-Path -Path $WorkRoot -ChildPath 'Tools'
    $CleanupScript = Join-Path -Path $ToolsDir -ChildPath 'Clear-StaleMount.ps1'
    $CleanupLog = Join-Path -Path $LogDir -ChildPath 'mount-cleanup.log'

    # Every mount folder goes in the list, not just the one that failed. By the time this runs the build is
    # long dead, so the siblings are stale too, and clearing them all is what makes the next run start clean.
    $Targets = New-Object System.Collections.Generic.List[string]
    foreach ($Item in @($Path) + @('Mount', 'WinREMount', 'BuildCheck' | ForEach-Object { Join-Path -Path $WorkRoot -ChildPath $_ })) {
        if ($Item -and -not ($Targets | Where-Object { $_ -ieq $Item })) { $Targets.Add($Item) }
    }
    $PathList = ($Targets | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '

    # Runs unattended at boot, so it leaves a log rather than failing silently. Everything here is the
    # teardown DISM should have done itself: strip the reparse point and attributes the WIM filter leaves
    # on a half-released mount, drop the registry entry that /Cleanup-Mountpoints skips when the mount is
    # too broken for DISM to recognise, and only then take ownership and delete.
    $EscCleanupLog    = $CleanupLog    -replace "'", "''"
    $EscCleanupScript = $CleanupScript -replace "'", "''"
    $EscCleanupTaskName = $CleanupTaskName -replace "'", "''"
    $Body = @"
`$ErrorActionPreference = 'SilentlyContinue'
Start-Transcript -Path '$EscCleanupLog' -Append | Out-Null
`$Targets = @($PathList)

foreach (`$Target in `$Targets) {
    if (-not (Test-Path -LiteralPath `$Target)) { continue }
    "Stripping reparse point and attributes from `$Target"
    & fsutil.exe reparsepoint delete "`$Target"
    & attrib.exe -R -S -H "`$Target" /S /D
}

# DISM's own list of mounts. An entry here that no longer matches reality is what makes every later mount
# fail, and it outlives both a reboot and /Cleanup-Mountpoints. Matched on any value holding the path
# rather than one named value, so a layout change cannot make this delete the wrong key.
`$MountedKey = 'HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images'
foreach (`$Entry in (Get-ChildItem -LiteralPath `$MountedKey)) {
    `$Values = Get-ItemProperty -LiteralPath `$Entry.PSPath
    foreach (`$Prop in `$Values.PSObject.Properties) {
        if (`$Prop.Value -isnot [string]) { continue }
        foreach (`$Target in `$Targets) {
            if (`$Prop.Value.TrimEnd('\') -ieq `$Target.TrimEnd('\')) {
                "Removing orphaned WIMMount registration `$(`$Entry.PSChildName) for `$Target"
                Remove-Item -LiteralPath `$Entry.PSPath -Recurse -Force
            }
        }
    }
}

& dism.exe /English /Cleanup-Mountpoints

`$EmptyDir = Join-Path -Path `$env:TEMP -ChildPath 'wiso-empty'
New-Item -ItemType Directory -Path `$EmptyDir -Force | Out-Null
foreach (`$Target in `$Targets) {
    if (-not (Test-Path -LiteralPath `$Target)) { continue }
    "Taking ownership of `$Target and deleting it"
    & takeown.exe /F "`$Target" /A /R /D Y | Out-Null
    & icacls.exe "`$Target" /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null
    # Nothing else here reaches the WinSxS paths past 260 characters, and /B uses backup privileges.
    & robocopy.exe `$EmptyDir `$Target /MIR /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
    `$DeleteError = `$null
    Remove-Item -LiteralPath `$Target -Recurse -Force -ErrorVariable DeleteError
    if (Test-Path -LiteralPath `$Target) {
        `$Remaining = @(Get-ChildItem -LiteralPath `$Target -Recurse -Force).Count
        "STILL PRESENT: `$Target (`$Remaining items left) `$(if (`$DeleteError) { `$DeleteError[0].Exception.Message })"
    }
    else { "Removed `$Target" }
}
Remove-Item -LiteralPath `$EmptyDir -Recurse -Force

Stop-Transcript | Out-Null
Unregister-ScheduledTask -TaskName '$EscCleanupTaskName' -Confirm:`$false
Remove-Item -LiteralPath '$EscCleanupScript' -Force
"@

    try {
        New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null
        # Always Windows PowerShell runs it, and that reads a file without a byte-order mark as ANSI, so the mark
        # is written explicitly. PowerShell 7's -Encoding UTF8 leaves it out, which would garble non-ASCII paths.
        [System.IO.File]::WriteAllText($CleanupScript, $Body, (New-Object System.Text.UTF8Encoding $true))
        # SYSTEM runs this file, so nobody below Administrator may be able to rewrite it first.
        & icacls.exe "$CleanupScript" /inheritance:r /grant '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' /Q 2>&1 | Out-Null

        # The inbox Windows PowerShell, not $PSHOME, so the task does not depend on whichever host started this run.
        $Exe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $Action = New-ScheduledTaskAction -Execute $Exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$CleanupScript`""
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $CleanupTaskName -Trigger $Trigger -Action $Action -Principal $Principal `
            -Settings $Settings -Description 'One-shot cleanup of a stale DISM mount folder left behind by Windows-ISO-Updater. Removes itself after it runs.' `
            -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-HostTimestamp "    Could not register the boot-time cleanup task: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }

    Write-HostTimestamp "    Registered the scheduled task '$CleanupTaskName' to clear it as SYSTEM at the next boot." -ForegroundColor Green
    Write-HostTimestamp "      It strips the reparse point, deletes the orphaned WIMMount registry entry, then takes ownership and deletes the folder, logging to $CleanupLog." -ForegroundColor DarkGray
    return $true
}

# Finds broken mounts that belong to someone else. Neither /Cleanup-Mountpoints nor
# Clear-WindowsCorruptMountPoint can be scoped to a folder, and both release every corrupt mount on the
# machine, so checking first is the only way to keep a recovery here from wrecking another run under a
# different -WorkPath, or somebody's MDT or ADK session. A mount reporting Ok is left out because the
# global cleanups do not touch healthy mounts, and a status that cannot be read counts as at risk.
function Get-ForeignBrokenMount {
    $Root = $WorkRoot.TrimEnd('\')
    try {
        return @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and
                -not (($_.Path.TrimEnd('\') -ieq $Root) -or ($_.Path -ilike "$Root\*")) -and
                ("$($_.MountStatus)" -ne 'Ok')
            })
    }
    catch { return @() }
}

# Throws away a mount without letting DISM's errors escape. Dismount-WindowsImage raises a terminating
# COMException that -ErrorAction cannot suppress, so every discard has to be wrapped or it fills the
# transcript with stack traces from cleanup paths that already know the mount may be gone. -Escalate then
# walks dism.exe up from a plain discard, to re-attaching a mount abandoned by a dead process (which
# answers the managed call with "The request is not supported"), to dropping the registration outright for
# one that survived a reboot and can no longer be re-attached at all.
function Dismount-ImageDiscard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Escalate
    )

    try {
        Dismount-WindowsImage -Path $Path -Discard -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        if (-not $Escalate) { return $false }
        Write-HostTimestamp "      Discard failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # dism.exe reaches mounts the managed API will not touch, so ask it to discard before re-attaching
    # anything. Re-attaching a mount that did not need it is what turns a dormant mount back into a live one.
    Write-HostTimestamp '      Asking dism.exe to discard it...' -ForegroundColor Yellow
    & dism.exe /English /Unmount-Image "/MountDir:$Path" /Discard 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-HostTimestamp '      Released it.' -ForegroundColor Green
        return $true
    }
    $DiscardCode = $LASTEXITCODE

    Write-HostTimestamp ('      dism.exe could not discard it either (exit code 0x{0:X8}), re-attaching the mount first...' -f $DiscardCode) -ForegroundColor Yellow
    & dism.exe /English /Remount-Image "/MountDir:$Path" 2>&1 | Out-Null
    $RemountCode = $LASTEXITCODE
    if ($RemountCode -eq 0) {
        & dism.exe /English /Unmount-Image "/MountDir:$Path" /Discard 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-HostTimestamp '      Released it.' -ForegroundColor Green
            return $true
        }
        Write-HostTimestamp ('      It re-attached but still would not release (exit code 0x{0:X8}).' -f $LASTEXITCODE) -ForegroundColor Yellow
    }
    else {
        Write-HostTimestamp ('      It cannot be re-attached (exit code 0x{0:X8}), which is what a mount that outlived a reboot looks like.' -f $RemountCode) -ForegroundColor Yellow
    }

    # Nothing can revive this mount, so the registration itself is what has to go.
    $Foreign = @(Get-ForeignBrokenMount)
    if ($Foreign.Count -gt 0) {
        Write-HostTimestamp "      Not running /Cleanup-Mountpoints: it would also release $($Foreign.Count) broken mount(s) outside $WorkRoot." -ForegroundColor Yellow
        foreach ($Other in $Foreign) { Write-HostTimestamp "        $($Other.Path)" -ForegroundColor DarkGray }
        Write-HostTimestamp '        Clear those yourself, or run this build with a -WorkPath nothing else is using.' -ForegroundColor Yellow
        return $false
    }

    Write-HostTimestamp '      Dropping the mount point registration instead...' -ForegroundColor Yellow
    & dism.exe /English /Cleanup-Mountpoints 2>&1 | Out-Null
    $StillMounted = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $Path.TrimEnd('\') })
    if ($StillMounted.Count -eq 0) {
        Write-HostTimestamp '      Released it.' -ForegroundColor Green
        return $true
    }

    Write-HostTimestamp '      The mount is still registered with DISM.' -ForegroundColor Yellow
    return $false
}

# Deletes a directory that Administrator rights alone cannot touch. What DISM leaves behind when a mount
# is interrupted is owned by TrustedInstaller and carries the image's own ACLs, so Remove-Item fails with
# "You need permission from TrustedInstaller", and the WinSxS tree inside nests past 260 characters, which
# Windows PowerShell 5.1 cannot address at all. Well-known SIDs are used rather than account names so this
# still works on a non-English Windows.
function Remove-DirectoryForce {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $TryRemove = {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        return (-not (Test-Path -LiteralPath $Path))
    }

    if (& $TryRemove) { return $true }

    Write-HostTimestamp "    Leftover files at $Path are locked down by TrustedInstaller, taking ownership of them..." -ForegroundColor Yellow
    & takeown.exe /F "$Path" /A /R /D Y 2>&1 | Out-Null
    & icacls.exe "$Path" /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
    & attrib.exe -R -S -H "$Path\*" /S /D 2>&1 | Out-Null
    if (& $TryRemove) {
        Write-HostTimestamp '    Removed them.' -ForegroundColor Green
        return $true
    }

    # Mirroring an empty folder over the target is the only thing here that walks paths longer than 260
    # characters, and /B uses backup privileges so whatever ACLs survived takeown stop mattering.
    Write-HostTimestamp '    Paths inside are too long for Remove-Item, emptying the folder with robocopy...' -ForegroundColor Yellow
    $EmptyDir = Join-Path -Path $env:TEMP -ChildPath ('wiso-empty-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $EmptyDir -Force -ErrorAction SilentlyContinue | Out-Null
    & robocopy.exe $EmptyDir $Path /MIR /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
    Remove-Item -LiteralPath $EmptyDir -Recurse -Force -ErrorAction SilentlyContinue
    if (& $TryRemove) {
        Write-HostTimestamp '    Removed them.' -ForegroundColor Green
        return $true
    }

    # A handle held by the servicing stack usually goes away on its own a moment later.
    Start-Sleep -Seconds 3
    $DeleteError = $null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable DeleteError
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-HostTimestamp '    Removed them.' -ForegroundColor Green
        return $true
    }
    if ($DeleteError) {
        Write-HostTimestamp "    It still will not delete: $($DeleteError[0].Exception.Message)" -ForegroundColor Yellow
    }
    return $false
}

# Ensures a mount directory is clean and ready to receive a fresh WIM mount. A previous run that crashed
# or was killed can leave an image still mounted (or a corrupt mount point) there, which makes the next
# Mount-WindowsImage fail. DISM tracks a mount by WIM file + index as well as by directory, so a mount
# left over at some other path still blocks the same index with "the specified image in the specified wim
# is already mounted for read/write access". Pass -ImagePath so both are released.
function Reset-MountDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ImagePath
    )

    $Normalized = $Path.TrimEnd('\')
    $TargetWim = if ($ImagePath) {
        try { (Get-Item -LiteralPath $ImagePath -ErrorAction Stop).FullName } catch { $ImagePath }
    }
    else { $null }

    $FindStale = {
        try {
            @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
                    ($_.Path -and $_.Path.TrimEnd('\') -ieq $Normalized) -or
                    ($TargetWim -and $_.ImagePath -and $_.ImagePath -ieq $TargetWim)
                })
        }
        catch { @() }
    }

    foreach ($M in (& $FindStale)) {
        $Leaf = if ($M.ImagePath) { Split-Path $M.ImagePath -Leaf } else { 'image' }
        Write-HostTimestamp "    A previous run left $Leaf index $($M.ImageIndex) mounted at $($M.Path) - discarding it..." -ForegroundColor Yellow
        if ($M.Path) { Dismount-ImageDiscard -Path $M.Path -Escalate | Out-Null }
    }

    # Releases mounts whose directory was deleted from under DISM, the only way back from an orphaned mount.
    $ForeignBroken = @(Get-ForeignBrokenMount)
    if ($ForeignBroken.Count -gt 0) {
        Write-HostTimestamp "    Skipping the corrupt mount point cleanup: $($ForeignBroken.Count) broken mount(s) outside $WorkRoot would be released too." -ForegroundColor Yellow
        foreach ($Other in $ForeignBroken) { Write-HostTimestamp "      $($Other.Path)" -ForegroundColor DarkGray }
    }
    else {
        try { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    # Clearing a corrupt mount point can make a mount that refused to discard discardable, so try once more.
    foreach ($M in (& $FindStale)) {
        if ($M.Path) { Dismount-ImageDiscard -Path $M.Path -Escalate | Out-Null }
    }

    $Stale = & $FindStale
    if ($Stale) {
        $Detail = ($Stale | ForEach-Object { "$(if ($_.ImagePath) { Split-Path $_.ImagePath -Leaf } else { 'image' }) index $($_.ImageIndex)" }) -join ', '
        if (Register-MountCleanupTask -Path $Path) {
            throw "An image is still mounted ($Detail) and nothing this script can do from a running session will release it. Reboot and start the build again - the cleanup task clears it on the way up."
        }
        throw "An image is still mounted ($Detail) and DISM will reject the next mount. Every automatic recovery has already been tried, including 'dism /Cleanup-Mountpoints'. Reboot, then run 'dism /Cleanup-Mountpoints' from an elevated prompt before starting the build again."
    }

    # Only safe once nothing is mounted here - deleting a tracked mount directory is what orphans it.
    if (-not (Remove-DirectoryForce -Path $Path)) {
        if (Register-MountCleanupTask -Path $Path) {
            throw "The mount folder $Path could not be deleted, even after taking ownership. Reboot and start the build again - the cleanup task clears it on the way up."
        }
        throw "The mount folder $Path still holds files from a failed run and could not be deleted, even after taking ownership. Reboot to release the handles, then start the build again."
    }
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
}
#endregion

