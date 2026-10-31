#region Disk space and path checks
# Returns the free space (GB, rounded to two decimals) on the drive that holds the given path, or $null.
function Get-DriveFreeGB {
    param([string]$Path)
    try {
        $Qualifier = (Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue)
        # A UNC path has no qualifier, and guessing the system drive would report a number for the wrong
        # volume, so say nothing rather than something false.
        if (-not $Qualifier) { return $null }
        $Drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Qualifier'" -ErrorAction Stop
        if ($Drive -and $Drive.FreeSpace) {
            return [math]::Round($Drive.FreeSpace / 1GB, 2)
        }
    }
    catch { }
    return $null
}

# True when a path is not on a local disk: a UNC share, a mapped network drive, or a drive letter that does
# not exist in this session. Mappings are per-logon-session, so a mapped drive that works interactively is
# simply absent when the scheduled task runs.
function Test-RemotePath {
    param([Parameter(Mandatory)][string]$Path)
    if ("$Path" -match '^\\\\') { return $true }
    $Qualifier = try { Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue } catch { $null }
    if (-not $Qualifier) { return $false }
    try {
        $Drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Qualifier'" -ErrorAction Stop
        if (-not $Drive) { return $true }
        return ([int]$Drive.DriveType -eq 4)
    }
    catch { return $false }   # WMI is not answering, so assume local and carry on as before
}

# Proves the finished ISO can actually be written before the build starts, by creating the destination
# folder and writing a probe file into it. Returns a sentence describing the problem, or $null when the
# location is usable. oscdimg runs at the very end of a build measured in hours, so an unwritable output
# folder that is only discovered there throws away all of that work.
function Get-OutputPathProblem {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$FilePath
    )
    if ($FilePath) {
        # Character checks come first: Test-Path itself throws on a path containing something like a pipe.
        $BadPathChar = @($FilePath.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidPathChars() -contains $_ })
        if ($BadPathChar.Count -gt 0) {
            return "'$FilePath' contains a character Windows does not allow in a path."
        }
        $Leaf = Split-Path -Path $FilePath -Leaf
        if (-not $Leaf) { return "'$FilePath' does not name a file. Pass -OutputIsoPath a full file name, such as D:\ISOs\Windows11.iso." }
        $BadNameChar = @($Leaf.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidFileNameChars() -contains $_ })
        if ($BadNameChar.Count -gt 0) {
            return "The file name '$Leaf' contains a character Windows does not allow in a file name."
        }
    }
    if (-not $Directory) { return "'$FilePath' has no folder part, so there is nowhere to write the ISO." }
    # -ErrorAction Stop inside a try is the only reliable way to quieten Test-Path here: an unreachable share
    # raises an IOException that SilentlyContinue does not suppress.
    $DirectoryExists = try { Test-Path -LiteralPath $Directory -ErrorAction Stop } catch { $false }
    if (-not $DirectoryExists) {
        try { New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null }
        catch { return "The output folder '$Directory' does not exist and could not be created: $($_.Exception.Message)" }
    }
    # An ISO left at the target path by a previous run is deleted before oscdimg writes, so a copy that is
    # mounted in Explorer or being read by something else blocks the build just as surely as a bad folder.
    $TargetExists = if ($FilePath) { try { Test-Path -LiteralPath $FilePath -PathType Leaf -ErrorAction Stop } catch { $false } } else { $false }
    if ($TargetExists) {
        try {
            $Handle = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
            $Handle.Close()
        }
        catch {
            return "An ISO already exists at '$FilePath' and something else has it open, so it cannot be replaced. Dismount it or close whatever is using it: $($_.Exception.Message)"
        }
    }
    $Probe = Join-Path -Path $Directory -ChildPath ('wiso-write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($Probe, 'Windows-ISO-Updater write test')
    }
    catch {
        return "The output folder '$Directory' cannot be written to: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
    }
    return $null
}

# An export stages a second copy of the image beside the original, so both must fit at the same time.
# Returns $false (and explains why) when the working drive no longer has room, so the caller can skip
# the shrink instead of failing a build that is otherwise finished.
function Test-RoomForExport {
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [string]$Label = 'image'
    )
    $Free = Get-DriveFreeGB -Path $WorkRoot
    if ($null -eq $Free) { return $true }
    $SourceGB = try { (Get-Item -LiteralPath $SourceImage -ErrorAction Stop).Length / 1GB } catch { return $true }
    $NeedGB = [math]::Round($SourceGB * 1.1, 2)
    if ($Free -lt $NeedGB) {
        Write-HostTimestamp "  Skipping the $Label re-export: staging a copy needs about $NeedGB GB, but only $Free GB is free on the working drive." -ForegroundColor Yellow
        return $false
    }
    return $true
}

# Detects the currently-installed Windows version/architecture so the Fido download request can reuse it.
function Get-InstalledWindowsInfo {
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'x86'   { 'x86' }
        default { 'x64' }
    }
    [PSCustomObject]@{ Architecture = $Arch }
}
#endregion

