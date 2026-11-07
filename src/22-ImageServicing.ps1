#region Image servicing
# The percentage on one of DISM's progress-bar lines, such as "[=====      10.0%      ]", or $null for any
# other line. A comma is allowed as the decimal mark, because DISM formats it in the system's own locale.
function Get-DismPercent {
    param([string]$Line)
    if ($Line -notmatch '^\s*\[[=\s]*(\d{1,3})(?:[.,]\d+)?%[=\s]*\]\s*$') { return $null }
    return [math]::Min(100, [int]$Matches[1])
}

# The text beside DISM's progress bar. DISM's percentage can sit still for many minutes and then jump, so the
# time keeps counting to show the work is alive, and a long stretch at one percentage is called out before it
# can be mistaken for a hang.
function Format-DismProgressDetail {
    param(
        [int]$Percent,
        [TimeSpan]$Elapsed,
        [TimeSpan]$Unchanged
    )
    $Taken = Format-Duration ([TimeSpan]::FromSeconds([math]::Floor($Elapsed.TotalSeconds)))
    if ($Percent -lt 0) { return "Working ($Taken)" }
    if ($Unchanged.TotalSeconds -ge 60) {
        return "$Taken, still working (no change for $(Format-Duration ([TimeSpan]::FromSeconds([math]::Floor($Unchanged.TotalSeconds)))))"
    }
    return $Taken
}

# Runs dism.exe and returns everything it printed, leaving $LASTEXITCODE as DISM set it. DISM redraws its
# progress bar with carriage returns, which ReadLine hands over as lines of their own, so the percentage is read
# off as it goes and shown on a progress line (see New-ProgressLine). The output is read asynchronously so the
# line is redrawn every second even while DISM prints nothing, which it can do for minutes at a time.
#
# With -FailureMessage it stands in for a DISM cmdlet called with -ErrorAction Stop: any exit code other than
# success or "restart needed" throws, with that message followed by DISM's error code and its own words.
function Invoke-Dism {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$Indent = 28,
        [string]$FailureMessage
    )

    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName = 'dism.exe'
    # Quoted the way the call operator quotes, so a path with spaces still reaches DISM as one argument.
    $Info.Arguments = (@($ArgumentList | ForEach-Object { if ("$_" -match '\s' -and "$_" -notmatch '^".*"$') { "`"$_`"" } else { "$_" } })) -join ' '
    $Info.UseShellExecute = $false
    # Left sharing this console, so Ctrl+C stops DISM along with the script instead of leaving it running.
    $Info.CreateNoWindow = $false
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    # What PowerShell decodes a native command's output with, so DISM's words read as they did through a pipe.
    $Info.StandardOutputEncoding = [Console]::OutputEncoding
    $Info.StandardErrorEncoding = [Console]::OutputEncoding

    $Output = New-Object System.Collections.Generic.List[string]
    $Progress = New-ProgressLine -Indent $Indent
    $Percent = -1
    $ChangedAt = Get-Date
    $Proc = $null
    try {
        $Proc = [System.Diagnostics.Process]::Start($Info)
        # Drained alongside, because a full stderr pipe would stall DISM.
        $ErrorText = $Proc.StandardError.ReadToEndAsync()
        $NextLine = $Proc.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($NextLine.Wait(1000)) {
                $Line = $NextLine.Result
                if ($null -eq $Line) { break }
                $Output.Add($Line)
                $Found = Get-DismPercent -Line $Line
                if ($null -ne $Found -and $Found -ne $Percent) { $Percent = $Found; $ChangedAt = Get-Date }
                $NextLine = $Proc.StandardOutput.ReadLineAsync()
            }
            $Now = Get-Date
            Update-ProgressLine -State $Progress -Percent $Percent -Detail (Format-DismProgressDetail -Percent $Percent -Elapsed ($Now - $Progress.Start) -Unchanged ($Now - $ChangedAt))
        }
        $Proc.WaitForExit()
        foreach ($Line in ($ErrorText.Result -split '\r?\n')) { if ($Line) { $Output.Add($Line) } }
        $global:LASTEXITCODE = $Proc.ExitCode
    }
    finally {
        Clear-ProgressLine -State $Progress
        if ($Proc) { $Proc.Dispose() }
    }

    if ($FailureMessage) { Assert-DismSuccess -Output $Output.ToArray() -ExitCode $LASTEXITCODE -FailureMessage $FailureMessage }
    return $Output.ToArray()
}

# Throws unless DISM ended in success or "restart needed", with the message followed by DISM's error code
# and its own account of what went wrong.
function Assert-DismSuccess {
    param(
        [object[]]$Output,
        [int]$ExitCode,
        [Parameter(Mandatory)][string]$FailureMessage
    )
    if ($ExitCode -eq 0 -or $ExitCode -eq 3010) { return }
    $Code = Get-DismErrorCode -Output $Output -ExitCode $ExitCode
    $Said = (@(Get-DismMessage -Output $Output) | Where-Object { $_ -notmatch '^Error:\s*0x' }) -join ' '
    throw "$FailureMessage (DISM error $Code)$(if ($Said) { ": $Said" })"
}

# Runs a program in the background and, while it works, shows how far it has got. For work that can go quiet
# for minutes at a time, so a line read from its output alone would sit still: a DISM commit says nothing
# while it scans the mounted image, and only reports a percentage once it starts writing.
#
# Two things are watched once a second. -WatchFile is a file the work writes into, and how much it has grown
# is shown. -GetPercent is handed each line the program has printed so far, and returns a percentage or
# $null. Once one turns up the line becomes a bar. Until then it shows -Waiting before the file starts to
# grow, and -Writing followed by the amount once it does. -GetStage is handed the same lines and returns a
# name for a line that starts a new stage of the work, or $null. The name then labels the line, and the bar
# starts again for that stage. Returns the exit code and everything the program printed. Anything that
# cannot be read just leaves the line showing the time taken.
function Invoke-WatchedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$WatchFile,
        [scriptblock]$GetPercent,
        [scriptblock]$GetStage,
        [string]$Waiting = 'Working',
        [string]$Writing = 'Writing',
        [int]$Indent = 0
    )

    $StartSize = $null
    if ($WatchFile -and (Test-Path -LiteralPath $WatchFile -PathType Leaf)) { $StartSize = (Get-Item -LiteralPath $WatchFile).Length }
    $OutFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wiso_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.out')
    $ErrFile = "$OutFile.err"
    $Progress = New-ProgressLine -Indent $Indent
    $ReadFrom = [long]0
    $Pending = ''
    $Percent = $null
    $Stage = $null
    $StageFrom = [long]0
    $Shown = $null
    $ShownAt = Get-Date
    try {
        $Proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -ErrorAction Stop
        # Read once now, because without the handle the exit code can come back empty once the process is gone.
        $null = $Proc.Handle
        while (-not $Proc.WaitForExit(1000)) {
            $Written = [long]0
            if ($null -ne $StartSize) {
                try { $Written = [long](Get-Item -LiteralPath $WatchFile -ErrorAction Stop).Length - $StartSize } catch { }
            }
            # Whatever the program has printed since the last look. The last piece may be a line still being
            # written, so it is held back until the next look completes it.
            if ($GetPercent -or $GetStage) {
                try {
                    $Stream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        [void]$Stream.Seek($ReadFrom, [System.IO.SeekOrigin]::Begin)
                        $Bytes = New-Object byte[] ([int][math]::Min(1MB, $Stream.Length - $ReadFrom))
                        $Count = $Stream.Read($Bytes, 0, $Bytes.Length)
                        $ReadFrom += $Count
                    }
                    finally { $Stream.Dispose() }
                    # A program writing UTF-16 leaves a NUL after every character, which would hide the digits.
                    $Pieces = ($Pending + [System.Text.Encoding]::ASCII.GetString($Bytes, 0, $Count).Replace([string][char]0, '')) -split '[\r\n]'
                    $Pending = $Pieces[-1]
                    for ($i = 0; $i -lt $Pieces.Count - 1; $i++) {
                        # A new stage starts its own bar from 0%, so the last stage's percentage is dropped, and
                        # from the second stage on, only what that stage itself writes is counted.
                        $NewStage = if ($GetStage) { & $GetStage $Pieces[$i] } else { $null }
                        if ($NewStage -and $NewStage -ne $Stage) {
                            if ($Stage) { $StageFrom = $Written }
                            $Stage = $NewStage
                            $Percent = $null
                            continue
                        }
                        $Found = if ($GetPercent) { & $GetPercent $Pieces[$i] } else { $null }
                        if ($null -ne $Found) { $Percent = $Found }
                    }
                }
                catch { }
            }
            $Elapsed = Format-Duration ((Get-Date) - $Progress.Start)
            $Grown = $Written - $StageFrom
            $Amount = if ($Grown -ge 1GB) { '{0:N2} GB' -f ($Grown / 1GB) } elseif ($Grown -ge 1MB) { '{0:N0} MB' -f ($Grown / 1MB) } else { $null }
            if ("$Percent|$Stage" -ne $Shown) { $Shown = "$Percent|$Stage"; $ShownAt = Get-Date }
            if ($null -ne $Percent) {
                # Called out once it has sat long enough to look like a hang, as Format-DismProgressDetail does.
                $Unchanged = (Get-Date) - $ShownAt
                if ($Unchanged.TotalSeconds -ge 60) { $Elapsed = "$Elapsed, still working (no change for $(Format-Duration ([TimeSpan]::FromSeconds([math]::Floor($Unchanged.TotalSeconds)))))" }
                $Detail = if ($Stage -and $Amount) { "${Stage}: $Amount written, $Elapsed" }
                          elseif ($Stage) { "$Stage, $Elapsed" }
                          elseif ($Amount) { "$Amount written, $Elapsed" }
                          else { $Elapsed }
                Update-ProgressLine -State $Progress -Percent $Percent -Detail $Detail
            }
            else {
                $Label = if ($Stage) { $Stage } else { $null }
                $Detail = if ($Amount) { "$(if ($Label) { $Label } else { $Writing }): $Amount so far ($Elapsed)" }
                          else { "$(if ($Label) { $Label } else { $Waiting }) ($Elapsed)" }
                Update-ProgressLine -State $Progress -Percent -1 -Detail $Detail
            }
        }
        $Proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $Proc.ExitCode
            Output   = @(Get-Content -LiteralPath $OutFile, $ErrFile -ErrorAction SilentlyContinue)
        }
    }
    finally {
        Clear-ProgressLine -State $Progress
        Remove-Item -LiteralPath $OutFile, $ErrFile -Force -ErrorAction SilentlyContinue
    }
}

# Export-WindowsImage, run through dism.exe so its progress can be shown. Throws if DISM fails.
function Export-WimImage {
    param(
        [Parameter(Mandatory)][string]$SourceImagePath,
        [Parameter(Mandatory)][int]$SourceIndex,
        [Parameter(Mandatory)][string]$DestinationImagePath,
        [ValidateSet('None', 'Fast', 'Max', 'Recovery')][string]$CompressionType = 'Max',
        [switch]$Setbootable,
        [int]$Indent = 24
    )
    $Arguments = @('/Export-Image', "/SourceImageFile:$SourceImagePath", "/SourceIndex:$SourceIndex",
        "/DestinationImageFile:$DestinationImagePath", "/Compress:$($CompressionType.ToLowerInvariant())")
    if ($Setbootable) { $Arguments += '/Bootable' }
    Invoke-Dism -ArgumentList $Arguments -Indent $Indent -FailureMessage "Could not export index $SourceIndex of $(Split-Path -Leaf $SourceImagePath)" | Out-Null
}

# Dismount-WindowsImage -Save, through dism.exe. Throws if DISM fails, leaving the image mounted for the
# caller's own discard-and-recover handling, as the cmdlet did.
#
# DISM says nothing for the first part of a commit, often minutes, while it scans the mounted image. Then it
# runs two stages, each with its own bar from 0 to 100%: "Saving image", which writes the changes into the
# .wim, and "Unmounting image". So it runs in the background with the image file it commits to watched as
# well, since the .wim grows as the changes are written back into it. The line shows "Preparing" during the
# scan, how much has been written once the file grows, and DISM's own bar, named for its stage, as soon as
# it reports one. /English keeps the stage names recognisable on a Windows in another language.
function Save-MountedImage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Indent = 26
    )
    $ImagePath = $null
    try {
        $Mounted = Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { "$($_.Path)".TrimEnd('\') -eq $Path.TrimEnd('\') } | Select-Object -First 1
        if ($Mounted) { $ImagePath = $Mounted.ImagePath }
    }
    catch { }   # without it the line still shows the time taken
    $Result = Invoke-WatchedProcess -FilePath 'dism.exe' -Arguments "/English /Unmount-Image /MountDir:`"$($Path.TrimEnd('\'))`" /Commit" -WatchFile $ImagePath -GetPercent { param($Line) Get-DismPercent -Line $Line } -GetStage {
        param($Line)
        switch -Regex ($Line) {
            '^\s*Saving image' { 'Saving the image' }
            '^\s*Unmounting image' { 'Unmounting' }
        }
    } -Waiting 'Preparing the commit' -Writing 'Writing the image' -Indent $Indent
    Assert-DismSuccess -Output $Result.Output -ExitCode $Result.ExitCode -FailureMessage "Could not commit and unmount the image at $Path"
}

# The names of the files inside a cabinet. An .msu is one too.
function Get-CabFileList {
    param([Parameter(Mandatory)][string]$Path)
    return @(& expand.exe -D "$Path" 2>$null | ForEach-Object {
            if ("$_" -match '(?i)\.(?:msu|cab):\s+(.+?)\s*$') { $Matches[1] }
        })
}

# Copies the servicing stack update packed inside a combined update out to $Destination and returns the .cab, or
# $null when the package carries none. Listed first rather than extracted with a wildcard, because pulling every
# cab out would unpack the multi-GB cumulative update as well.
function Expand-ServicingStack {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$Destination
    )
    $Name = @(Get-CabFileList -Path $PackagePath | Where-Object { $_ -match '(?i)^ssu-.*\.cab$|servicingstack.*\.cab$' }) | Select-Object -First 1
    if (-not $Name) { return $null }
    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    & expand.exe -R "$PackagePath" "-F:$Name" "$Destination" | Out-Null
    return Get-Item -LiteralPath (Join-Path -Path $Destination -ChildPath $Name) -ErrorAction SilentlyContinue
}

# Whether a package is a servicing stack update on its own. Its file name does not say, so the root manifest is
# read, where a servicing stack's identity is Package_for_ServicingStack_<n>. A combined update is not one, since
# its stack is pulled out with Expand-ServicingStack instead.
function Test-StandaloneServicingStack {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkDir
    )
    # No servicing stack update comes near this, and reading a manifest out of a cumulative update means
    # decompressing gigabytes to reach it.
    if ((Get-Item -LiteralPath $Path).Length -gt 300MB) { return $false }
    $Temp = Join-Path -Path $WorkDir -ChildPath ('ssucheck_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $Temp -Force -ErrorAction Stop | Out-Null
        $Cab = $Path
        if ($Path -match '(?i)\.msu$') {
            $Names = @(Get-CabFileList -Path $Path)
            if ($Names | Where-Object { $_ -match '(?i)^ssu-' }) { return $false }
            $Inner = $Names | Where-Object { $_ -match '(?i)\.cab$' -and $_ -notmatch '(?i)^wsusscan\.cab$' } | Select-Object -First 1
            if (-not $Inner) { return $false }
            & expand.exe -R "$Path" "-F:$Inner" "$Temp" | Out-Null
            $Cab = Join-Path -Path $Temp -ChildPath $Inner
            if (-not (Test-Path -LiteralPath $Cab)) { return $false }
        }
        $MumDir = Join-Path -Path $Temp -ChildPath 'mum'
        New-Item -ItemType Directory -Path $MumDir -Force -ErrorAction Stop | Out-Null
        & expand.exe -R "$Cab" '-F:update.mum' "$MumDir" | Out-Null
        $Mum = Join-Path -Path $MumDir -ChildPath 'update.mum'
        if (-not (Test-Path -LiteralPath $Mum)) { return $false }
        return [bool](Select-String -LiteralPath $Mum -Pattern 'Package_for_ServicingStack' -SimpleMatch -Quiet)
    }
    catch { return $false }
    finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Pulls the servicing stack update out of a combined SSU+LCU .msu and applies it on its own. Windows rejects
# a cumulative update with 0x800F0823 when the image's stack is older than the update needs, and DISM does
# not always take the stack out of the combined package by itself when servicing offline.
function Add-ServicingStack {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$StageDir,
        [string]$LogPath
    )

    $SsuDir = Join-Path -Path $StageDir -ChildPath 'ssu'
    $LogArgs = @(if ($LogPath) { "/LogPath:$LogPath" })
    try {
        $Ssu = Expand-ServicingStack -PackagePath $PackagePath -Destination $SsuDir
        if (-not $Ssu) {
            Write-HostTimestamp '      No servicing stack package is bundled inside this update, so it cannot be applied on its own.' -ForegroundColor DarkYellow
            return $false
        }

        Write-HostTimestamp "      Applying the bundled servicing stack update first: $($Ssu.Name)" -ForegroundColor DarkYellow
        Invoke-Dism -ArgumentList (@("/Image:$MountDir", '/Add-Package', "/PackagePath:$($Ssu.FullName)") + $LogArgs) | Out-Null
        $SsuExit = $LASTEXITCODE
        if ($SsuExit -eq 0 -or $SsuExit -eq 3010) {
            Write-HostTimestamp '      Servicing stack updated.' -ForegroundColor Green
            return $true
        }
        # DISM often installs the bundled stack itself on the failed first pass, so finding it already there is
        # the stack being current, not a failure.
        if ($SsuExit -eq -2146498530) {
            Write-HostTimestamp '      The image already has this servicing stack.' -ForegroundColor DarkGray
            return $true
        }
        Write-HostTimestamp "      The servicing stack update did not apply either (exit code $(Format-ExitCode $SsuExit))." -ForegroundColor DarkYellow
        return $false
    }
    catch {
        Write-HostTimestamp "      Could not extract the servicing stack from the update: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
    finally {
        Remove-Item -LiteralPath $SsuDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Applies ONE update "group" to a mounted image using Microsoft's documented checkpoint-cumulative-update
# method. A group is an ordered set of related packages with the TARGET package LAST (e.g. [checkpoint, LCU]
# or just [.NET CU]).
#
# Per Microsoft (learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates), the
# correct procedure is: place the target .msu AND all its prior checkpoint .msu files in a clean folder with
# no other .msu present, then run "DISM /Add-Package" with ONLY the latest (target) .msu as the sole target.
# DISM pulls the differentials it needs from the checkpoint files automatically. Adding a checkpoint as its
# own /PackagePath target is NOT supported and corrupts the image (STATUS_SXS_FILE_HASH_MISMATCH / 0x80070228).
#
# Returns $true if DISM reported success (or the package was already present), $false on a real failure.
# One line of the servicing story: which package was tried against which image and how it ended.
function Add-ServicingResult {
    param(
        [string]$Image,
        [string]$Package,
        [string]$Result,
        [string]$Detail,
        [string[]]$Checkpoints
    )
    if (-not $Image) { return }
    # Updates.Packages already lists each file, so a record names the KB and the two join on it.
    if ($Package -match '(?i)kb(\d{6,}).*\.(msu|cab)$') { $Package = "KB$($Matches[1])" }
    $Record = [ordered]@{ Image = $Image; Package = $Package; Result = $Result }
    if ($Checkpoints) { $Record['Checkpoints'] = @($Checkpoints) }
    if ($Detail) { $Record['Detail'] = $Detail }
    $script:TattooServicing.Add($Record)
}

# A discarded mount takes every package already applied to it along, so those records must stop saying Applied.
function Set-ServicingResultDiscarded {
    param([string[]]$Image)
    foreach ($Record in $script:TattooServicing) {
        if ($Image -contains "$($Record['Image'])" -and $Record['Result'] -eq 'Applied') {
            $Record['Result'] = 'Failed'
            $Record['Detail'] = 'Applied, then thrown away with the rest of the image after a later package left it unserviceable'
        }
    }
}

# The code DISM reported, as 0x followed by eight hex digits. Its own "Error: 0x..." line is preferred, because
# the exit code is sometimes a generic one, and the exit code is the fallback.
function Get-DismErrorCode {
    param(
        [object[]]$Output,
        [int]$ExitCode
    )
    $Found = @([regex]::Matches((@($Output) -join "`n"), '(?i)\bError:\s*0x([0-9a-f]{8})'))
    if ($Found.Count -gt 0) { return '0x' + $Found[$Found.Count - 1].Groups[1].Value.ToUpperInvariant() }
    if ($ExitCode) { return '0x{0:X8}' -f $ExitCode }
    return $null
}

# Plain words for the codes that turn up most when adding updates to an offline image. Anything else gets
# DISM's own message and log lines, which are printed either way.
function Get-DismErrorMeaning {
    param([string]$Code)
    switch ("$Code".ToUpperInvariant()) {
        '0X800F081E' { 'the package does not apply to this image, usually because it is for a different release, edition or architecture'; break }
        '0X800F0823' { 'the image needs a newer servicing stack before it can take this update'; break }
        '0X800F0922' { 'the package failed partway through installing, most often because the servicing stack is too old or the package is for a different release'; break }
        '0X800F0984' { 'a file this update patches is missing from the image, usually because the media was repacked or an earlier checkpoint update is missing'; break }
        '0X800F0831' { 'the image is missing an earlier update this one builds on'; break }
        '0X80070228' { "the image's files do not match their manifests, which usually means a repacked or UUP-built ISO rather than an official one"; break }
        '0X80073712' { "the image's component store is damaged"; break }
        '0X80073713' { 'one of the setup steps the update runs inside the image failed, so the image can no longer be serviced and has to be discarded'; break }
        '0X80070070' { 'there is not enough free disk space on the working drive'; break }
        '0X80070005' { 'access was denied, often because antivirus or another program is holding files in the mounted image'; break }
        '0X80070020' { 'another program has a file in the mounted image open, often antivirus, Explorer or the search indexer'; break }
        '0X8007000D' { 'the package file is damaged, so delete it from the download folder and run again to fetch a fresh copy'; break }
        '0X80070002' { 'DISM could not find a file it needed, such as the package itself or a checkpoint update staged with it'; break }
        default { $null }
    }
}

# DISM exit codes are HRESULTs, which print as a meaningless negative number in decimal.
function Format-ExitCode {
    param([int]$Code)
    if ($Code -lt 0) { return '0x{0:X8}' -f $Code }
    return "$Code"
}

# DISM says an image is past saving in words rather than with one code, and the code differs by failure. Once it
# has, nothing more may be applied to that mount and it must never be committed.
function Test-DismImageUnserviceable {
    param(
        [object[]]$Output,
        [string]$LogPath
    )
    $Pattern = '(?i)no longer serviceable|Discard (the modified|this Windows) image'
    if ((@($Output) -join "`n") -match $Pattern) { return $true }
    return [bool](@(Get-DismLogError -Path $LogPath -Last 50) | Where-Object { $_ -match $Pattern })
}

# Windows 10 updates carry an Extended Security Updates step that will not run in an offline image. It logs this
# as an Info line long before DISM gives up, so the errors at the end of the log never mention it. Only called
# after a failure, so reading the whole log costs nothing on a run that works.
function Test-DismEsuOfflineRefusal {
    param([string]$LogPath)
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $false }
    return [bool](Select-String -LiteralPath $LogPath -Pattern 'ESU: Offline is not supported' -SimpleMatch -List -ErrorAction SilentlyContinue)
}

# DISM's console output without its banner, progress bars and blank lines, which leaves its own account of what
# went wrong. The line that explains the failure often carries neither "error" nor a code, so nothing else is cut.
function Get-DismMessage {
    param([object[]]$Output)
    return @(@($Output) | ForEach-Object { "$_".Trim() } | Where-Object {
            $_ -and $_ -notmatch '^\[' -and
            $_ -notmatch '^(Deployment Image Servicing and Management tool|Version:|Image Version:|The DISM log file can be found)'
        } | Select-Object -Unique | Select-Object -Last 15)
}

# The Error lines from a DISM log, without the timestamp and padding that make them too wide to read on screen.
function Get-DismLogError {
    param(
        [string]$Path,
        [int]$Last = 10
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $Lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\S+ \S+, Error\s' })
    return @($Lines | ForEach-Object {
            $Text = ($_ -replace '^\S+ \S+, Error\s+', '') -replace '\s{2,}', ' '
            if ($Text.Length -gt 240) { $Text.Substring(0, 237) + '...' } else { $Text }
        } | Select-Object -Unique | Select-Object -Last $Last)
}

# Keeps the DISM log of a package that failed beside this run's own logs, named for the package and the image, so
# one Logs folder holds everything a bug report needs. Logs of packages that applied are not kept, because a
# cumulative update's can run to tens of megabytes. Returns the saved path, or $null.
function Save-DismLog {
    param(
        [string]$Path,
        [string]$Package,
        [string]$ImageLabel
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $Folder = Join-Path -Path $LogDir -ChildPath "Windows-ISO-Updater_${LogStamp}_DISM"
        New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null
        # The KB alone, because the full file name carries a 40-character hash that would push the image off the end.
        if ($Package -match '(?i)kb(\d{6,})') { $Package = "KB$($Matches[1])" }
        $Name = (("$Package $ImageLabel".Trim() -replace '[^A-Za-z0-9.()-]+', '_') -replace '_+', '_').Trim('_')
        if (-not $Name) { $Name = 'package' }
        if ($Name.Length -gt 100) { $Name = $Name.Substring(0, 100) }
        $Destination = Join-Path -Path $Folder -ChildPath "$Name.log"
        $Count = 1
        while (Test-Path -LiteralPath $Destination) { $Count++; $Destination = Join-Path -Path $Folder -ChildPath "${Name}_$Count.log" }
        Copy-Item -LiteralPath $Path -Destination $Destination -ErrorAction Stop
        return $Destination
    }
    catch { return $null }
}

function Add-UpdateGroup {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][object[]]$Group,
        [string]$Label = 'update package',
        [string]$ImageLabel
    )

    if (-not $Group -or $Group.Count -eq 0) { return $true }

    # The default label says nothing the package name does not, so it stays out of the build record.
    $RecordDetail = if ($Label -eq 'update package') { '' } else { $Label }
    # DISM reads these from the staging folder without being told, so the record has to say they were there.
    $Checkpoints = @()
    if ($Group.Count -gt 1) {
        $Checkpoints = @($Group[0..($Group.Count - 2)] | ForEach-Object {
            $Leaf = Split-Path -Leaf "$_"
            if ($Leaf -match '(?i)kb(\d{6,})') { "KB$($Matches[1])" } else { $Leaf }
        })
    }

    # Stage the whole group in a clean, isolated folder so DISM sees ONLY these files (no unrelated .msu).
    $Stage = Join-Path -Path $WorkRoot -ChildPath ('pkgstage_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $Stage -Force -ErrorAction Stop | Out-Null

        $Target = $null
        foreach ($Pkg in $Group) {
            $Dest = Join-Path -Path $Stage -ChildPath (Split-Path -Leaf $Pkg)
            Copy-Item -LiteralPath $Pkg -Destination $Dest -Force -ErrorAction Stop
            $Target = $Dest  # the group is ordered target-last, so the final file copied is the target
        }

        # A log of just this package, rather than the shared C:\Windows\Logs\DISM\dism.log every DISM call on the
        # machine appends to. Kept with the run's logs only if the package fails.
        $DismLog = Join-Path -Path $Stage -ChildPath 'dism.log'

        $Extra = if ($Group.Count -gt 1) { " (+$($Group.Count - 1) prior checkpoint file(s) staged alongside)" } else { '' }
        Write-HostTimestamp "      Applying ${Label}: $(Split-Path -Leaf $Target)$Extra"
        Write-HostTimestamp '      Running DISM /Add-Package with the target as the sole package (this can take several minutes)...'
        # Once a run, and only where the bar is drawn, since a log reader never sees it.
        if (-not $script:DismProgressNoteShown -and (Get-ConsoleWidth) -gt 0) {
            $script:DismProgressNoteShown = $true
            Write-HostTimestamp "      Note: DISM's percentage is only a rough guide. Depending on the update it can sit at one figure for many minutes and then jump, so the time beside it keeps counting while DISM works." -ForegroundColor DarkGray
        }

        # One retry, because transient problems (a locked file, a busy servicing stack) often clear on a second
        # attempt. 0x800F0823 means the image needs a newer servicing stack, so the one bundled in the update goes
        # in before the retry. An image DISM calls unserviceable is never retried, because it cannot recover.
        $MaxAttempts = 2
        $StackBroughtForward = $false
        $Unserviceable = $false
        for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
            $Output = Invoke-Dism -ArgumentList "/Image:$MountDir", '/Add-Package', "/PackagePath:$Target", "/LogPath:$DismLog"
            $ExitCode = $LASTEXITCODE

            if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
                Write-HostTimestamp '      Applied.' -ForegroundColor Green
                $AppliedDetail = if ($StackBroughtForward) { 'Applied after the servicing stack was brought forward (0x800F0823)' } else { $RecordDetail }
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Applied' -Detail $AppliedDetail -Checkpoints $Checkpoints
                return $true
            }
            if ($Output -match '0x800f081e') {
                Write-HostTimestamp '      Already present / not applicable - skipping.' -ForegroundColor DarkGray
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Skipped' -Detail 'Already present or not applicable (0x800F081E)' -Checkpoints $Checkpoints
                return $true
            }
            if (Test-DismImageUnserviceable -Output $Output -LogPath $DismLog) {
                $Unserviceable = $true
                break
            }

            if ($Attempt -lt $MaxAttempts) {
                if ($Output -match '0x800f0823') {
                    Write-HostTimestamp '      DISM /Add-Package failed with 0x800F0823: the image needs a newer servicing stack first.' -ForegroundColor DarkYellow
                    $StackBroughtForward = Add-ServicingStack -MountDir $MountDir -PackagePath $Target -StageDir $Stage -LogPath $DismLog
                    Write-HostTimestamp '      Retrying the update...' -ForegroundColor DarkYellow
                }
                else {
                    Write-HostTimestamp "      DISM /Add-Package failed (exit code $(Format-ExitCode $ExitCode)). Retrying once..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 5
                }
            }
        }
        if ($Unserviceable) { $script:ImageUnserviceable = $true }

        $PackageName = Split-Path -Leaf $Target
        $Code = Get-DismErrorCode -Output $Output -ExitCode $ExitCode
        $Meaning = Get-DismErrorMeaning -Code $Code
        Write-HostTimestamp "      This package didn't apply: DISM error $Code$(if ($Meaning) { " - $Meaning" })." -ForegroundColor Yellow
        $Message = @(Get-DismMessage -Output $Output)
        if ($Message.Count -gt 0) {
            Write-HostTimestamp '      DISM said:' -ForegroundColor DarkYellow
            foreach ($Line in $Message) { Write-HostLog "        $Line" -ForegroundColor DarkYellow }
        }
        $LogErrors = @(Get-DismLogError -Path $DismLog)
        if ($LogErrors.Count -gt 0) {
            Write-HostTimestamp "      The errors DISM logged, last $($LogErrors.Count):" -ForegroundColor DarkYellow
            foreach ($Line in $LogErrors) { Write-HostLog "        $Line" -ForegroundColor DarkGray }
        }
        $SavedLog = Save-DismLog -Path $DismLog -Package $PackageName -ImageLabel $ImageLabel
        if ($SavedLog) { Write-HostTimestamp "      DISM's full log for this package: $SavedLog" -ForegroundColor DarkYellow }
        else { Write-HostTimestamp '      Details are in C:\Windows\Logs\DISM\dism.log.' -ForegroundColor DarkYellow }
        $Detail = "DISM error $Code$(if ($Meaning) { ": $Meaning" })"
        Add-ServicingResult -Image $ImageLabel -Package $PackageName -Result 'Failed' -Detail $Detail -Checkpoints $Checkpoints
        # Most failures mention "Unattend.xml", which is a red herring, so the error code decides the advice.
        # One message each, so Write-HostTimestamp wraps them to the console instead of a fixed width.
        if ($Unserviceable) {
            $Discarded = 'Tip: DISM reports this image can no longer be serviced, so it will be discarded rather than saved, and this edition keeps exactly what the source media had.'
            if (Test-DismEsuOfflineRefusal -LogPath $DismLog) {
                Write-HostTimestamp "      $Discarded The update's Extended Security Updates step refuses to run on an offline image (it logged 'ESU: Offline is not supported'), so no ISO can carry this update and other media will not help. Windows installs it once setup finishes, through Windows Update or the after-setup answer file." -ForegroundColor DarkGray
            }
            else {
                # 0x80073713 is ERROR_ADVANCED_INSTALLER_FAILED: one of the update's install-time steps failed.
                $Cause = if ($Code -eq '0x80073713') { "One of the setup steps the update runs inside the image failed. The DISM log names it on the line with 'Failed execution of queue item Installer'." }
                         else { 'Base media much older than the update, or media that was repacked, is the usual cause.' }
                Write-HostTimestamp "      $Discarded $Cause An untouched official Microsoft ISO resolves it when the media is at fault." -ForegroundColor DarkGray
            }
        }
        elseif ($Output -match '0x800f0823') {
            Write-HostTimestamp '      Tip: 0x800F0823 means the image needs a newer servicing stack than it has, and the one bundled in this update did not take. Base media several years older than the update is the usual cause. Try newer media, or apply the standalone SSU for this release to the mounted image by hand before re-running.' -ForegroundColor DarkGray
        }
        elseif ($Output -match '0x80070228') {
            Write-HostTimestamp "      Tip: this is typically the base image, not the update. The install.wim files did not match their manifests, which is common with repacked or UUP-built ISOs. A clean official Microsoft ISO usually resolves it." -ForegroundColor DarkGray
        }
        return $false
    }
    catch {
        Write-HostTimestamp "      This package couldn't be staged/applied: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Group[$Group.Count - 1]) -Result 'Failed' -Detail $_.Exception.Message -Checkpoints $Checkpoints
        return $false
    }
    finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Injects the -DriverPath packages into a mounted image. Each .inf is added on its own rather than letting
# DISM recurse the folder, so one driver the image rejects cannot take the whole set down with it.
# Returns $true when every package went in.
function Add-ImageDrivers {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [AllowEmptyCollection()][object[]]$InfFiles,
        [string]$ImageLabel
    )

    if (-not $InfFiles -or $InfFiles.Count -eq 0) { return $true }

    Write-HostTimestamp "    Injecting $($InfFiles.Count) driver package(s)..."
    $Added  = 0
    $Failed = New-Object System.Collections.Generic.List[string]
    foreach ($Inf in $InfFiles) {
        try {
            Add-WindowsDriver -Path $MountDir -Driver $Inf.FullName -ForceUnsigned:$AllowUnsignedDrivers -ErrorAction Stop | Out-Null
            $Added++
        }
        catch {
            [void]$Failed.Add($Inf.Name)
            Write-HostTimestamp "      $($Inf.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($Failed.Count -eq 0) {
        Write-HostTimestamp "      $Added driver package(s) added." -ForegroundColor Green
        Add-ServicingResult -Image $ImageLabel -Package "$Added driver package(s)" -Result 'Applied' -Detail 'Injected from -DriverPath'
        return $true
    }

    Write-HostTimestamp "      $Added added, $($Failed.Count) rejected. A rejected driver is usually unsigned, built for another architecture, or not a real driver package." -ForegroundColor Yellow
    if (-not $AllowUnsignedDrivers) {
        Write-HostTimestamp '      Pass -AllowUnsignedDrivers if the rejected ones are unsigned and you accept that risk.' -ForegroundColor DarkGray
    }
    $Result = if ($Added -gt 0) { 'Partial' } else { 'Failed' }
    Add-ServicingResult -Image $ImageLabel -Package "$($InfFiles.Count) driver package(s)" -Result $Result -Detail "$Added added, rejected: $(($Failed | Select-Object -First 10) -join ', ')"
    return $false
}

# Deletes servicing residue from a mounted image before it is committed. Windows recreates all of it on
# first boot, and its size varies with how chatty DISM was, which is the main reason two builds from the
# same source ISO and the same update come out different sizes.
function Remove-ImageResidue {
    param([Parameter(Mandatory)][string]$MountDir)

    if (-not $StripImageResidue) {
        Write-HostTimestamp '    Leaving the servicing residue in place (pass -StripImageResidue to remove it).' -ForegroundColor DarkGray
        return
    }

    # Folder contents to clear, keeping the folder itself so nothing has to recreate it.
    $ClearFolders = @(
        'Windows\Logs\CBS'
        'Windows\Logs\DISM'
        'Windows\Logs\DPX'
        'Windows\Logs\MoSetup'
        'Windows\Logs\WindowsUpdate'
        'Windows\Temp'
        'Windows\SoftwareDistribution\Download'
    )
    # Whole items to remove.
    $DeleteItems = @('$WinREAgent')
    # None of these belong in clean Microsoft media, so finding one says the source ISO was built from a
    # captured image rather than downloaded from Microsoft. They are removed either way.
    $Suspect = @(
        'Windows.old'
        '$WINDOWS.~BT'
        '$WINDOWS.~WS'
        '$Recycle.Bin'
        'System Volume Information'
        'pagefile.sys'
        'hiberfil.sys'
        'swapfile.sys'
    )

    $FreedMB = 0
    $Found = New-Object System.Collections.Generic.List[string]
    $Stuck = New-Object System.Collections.Generic.List[string]

    # Get-ChildItem on a file path returns that file, so one expression sizes folders and files alike.
    $Measure = {
        param($Path)
        $Sum = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($Sum) { return ($Sum / 1MB) }
        return 0
    }

    foreach ($Relative in $ClearFolders) {
        $Full = Join-Path -Path $MountDir -ChildPath $Relative
        if (-not (Test-Path -LiteralPath $Full -PathType Container)) { continue }
        foreach ($Child in @(Get-ChildItem -LiteralPath $Full -Force -ErrorAction SilentlyContinue)) {
            # The image's TrustedInstaller permissions can defeat Remove-Item, so only count what really went.
            $ChildMB = & $Measure $Child.FullName
            Remove-Item -LiteralPath $Child.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Child.FullName)) { $FreedMB += $ChildMB }
        }
    }

    # Only the logs in Panther, because a captured image can keep the answer file that built it there.
    $Panther = Join-Path -Path $MountDir -ChildPath 'Windows\Panther'
    if (Test-Path -LiteralPath $Panther -PathType Container) {
        foreach ($Log in @(Get-ChildItem -LiteralPath $Panther -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.log', '.etl', '.evtx' })) {
            Remove-Item -LiteralPath $Log.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Log.FullName)) { $FreedMB += ($Log.Length / 1MB) }
        }
    }

    foreach ($Relative in ($DeleteItems + $Suspect)) {
        $Full = Join-Path -Path $MountDir -ChildPath $Relative
        if (-not (Test-Path -LiteralPath $Full)) { continue }
        $Before = & $Measure $Full
        Remove-Item -LiteralPath $Full -Recurse -Force -ErrorAction SilentlyContinue
        # Windows.old is a full Windows tree, so parts of it can refuse to go and would otherwise be counted.
        $Survived = Test-Path -LiteralPath $Full
        $FreedMB += if ($Survived) { $Before - (& $Measure $Full) } else { $Before }
        if ($Suspect -contains $Relative) {
            $Found.Add($Relative)
            if ($Survived) { $Stuck.Add($Relative) }
        }
    }

    if ($Found.Count -gt 0) {
        Write-HostTimestamp "    Found leftovers that clean Microsoft media never contains: $($Found -join ', ')" -ForegroundColor Yellow
        Write-HostTimestamp '      These come from the source image, not from this build, so it was captured from an installed machine. Exclude them at capture time, or use official Microsoft media.' -ForegroundColor Yellow
    }
    if ($Stuck.Count -gt 0) {
        Write-HostTimestamp "      Could not fully remove $($Stuck -join ', '). The image's permissions denied it, so what is left will ship in the ISO." -ForegroundColor Yellow
    }
    if ($FreedMB -ge 1) {
        Write-HostTimestamp ('    Stripped {0:N0} MB of servicing residue (logs and temp files Windows recreates on first boot).' -f $FreedMB) -ForegroundColor DarkGray
    }

    # Totalled across every image so the tattoo can state what this build removed.
    $script:TattooResidueMB += $FreedMB
    foreach ($Item in $Found) {
        if (-not $script:TattooResidueFound.Contains($Item)) { $script:TattooResidueFound.Add($Item) }
    }
}

# Committing a serviced winre.wim APPENDS the Safe OS delta instead of rebasing it, so the recovery image
# grows by far more than the update is worth and can outgrow the recovery partition Setup sizes at install
# time. Re-exporting rebuilds it from a single index, which is the only thing that reclaims that space.
function Optimize-WinReImage {
    param(
        [Parameter(Mandatory)][string]$WinReWim,
        [string]$ImageLabel = 'winre.wim'
    )
    if (-not (Test-RoomForExport -SourceImage $WinReWim -Label 'winre.wim')) { return }
    # Staged outside the mounted install.wim so a failed export can never be committed into the edition.
    $Temp = Join-Path -Path $WorkRoot -ChildPath 'winre_new.wim'
    try {
        if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
        $BeforeMB = (Get-Item -LiteralPath $WinReWim).Length / 1MB
        Write-HostTimestamp '      Re-exporting the recovery image to shrink it...'
        # Always Max, never -FastCompression: this image has to fit a fixed recovery partition, and at a few
        # hundred MB the compression time is irrelevant next to install.wim.
        Export-WimImage -SourceImagePath $WinReWim -SourceIndex 1 -DestinationImagePath $Temp -CompressionType Max -Indent 28
        Set-ItemProperty -LiteralPath $WinReWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        # Copied rather than moved, because the destination lives inside a DISM projection of install.wim.
        Copy-Item -LiteralPath $Temp -Destination $WinReWim -Force -ErrorAction Stop
        $AfterMB = (Get-Item -LiteralPath $WinReWim).Length / 1MB
        Write-HostTimestamp ('      winre.wim: {0:N0} MB -> {1:N0} MB (saved {2:N0} MB).' -f $BeforeMB, $AfterMB, ($BeforeMB - $AfterMB)) -ForegroundColor Green
        Add-ServicingResult -Image $ImageLabel -Package 'Re-export' -Result 'Applied' -Detail ('{0:N0} MB -> {1:N0} MB' -f $BeforeMB, $AfterMB)
    }
    catch {
        Write-HostTimestamp "      The winre.wim re-export failed: $($_.Exception.Message). The serviced recovery image is used as it is." -ForegroundColor Yellow
        Add-ServicingResult -Image $ImageLabel -Package 'Re-export' -Result 'Failed' -Detail $_.Exception.Message
    }
    finally {
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}

# Every edition on one medium normally ships the same recovery image (winre.wim is WinPE, nothing in it is
# edition-specific), so the mount, the Safe OS DU, the /ResetBase and the re-export only have to happen for
# the first one. Keyed on the source hash rather than assumed, because media that really does carry a
# different recovery image per edition has to keep being serviced properly.
function Copy-CachedWinReImage {
    param(
        [Parameter(Mandatory)][string]$WinReWim,
        [string]$SourceHash
    )
    if (-not $SourceHash -or $SourceHash -ne $script:WinReCacheHash) { return $false }
    if (-not $script:WinReCachePath -or -not (Test-Path -LiteralPath $script:WinReCachePath)) { return $false }
    try {
        Set-ItemProperty -LiteralPath $WinReWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $script:WinReCachePath -Destination $WinReWim -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-HostTimestamp "    The serviced recovery image could not be reused here: $($_.Exception.Message). This edition's own copy will be serviced instead." -ForegroundColor Yellow
        return $false
    }
}

# Keeps the serviced recovery image where the next edition can pick it up. Staged outside the mount,
# because the source lives inside a DISM projection that is about to be committed and torn down.
function Save-ServicedWinReImage {
    param(
        [Parameter(Mandatory)][string]$WinReWim,
        [string]$SourceHash
    )
    if (-not $SourceHash) { return }
    $Cache = Join-Path -Path $WinReCacheDir -ChildPath 'winre_serviced.wim'
    try {
        New-Item -ItemType Directory -Path $WinReCacheDir -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $WinReWim -Destination $Cache -Force -ErrorAction Stop
        $script:WinReCachePath = $Cache
        $script:WinReCacheHash = $SourceHash
    }
    catch {
        # Not fatal, the remaining editions just each do the work themselves.
        Write-HostTimestamp "      The serviced recovery image could not be kept for the other editions: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# The build a recovery image is at, read straight from the WIM header so nothing has to be mounted.
# Trustworthy here in a way it is not for install.wim: winre.wim is rebuilt and re-stamped by the Safe OS
# Dynamic Update rather than patched in place, so its header follows what is actually inside it.
function Get-WinReVersion {
    param([Parameter(Mandatory)][string]$WinReWim)

    $Info = try { Get-WindowsImage -ImagePath $WinReWim -Index 1 -ErrorAction Stop } catch { $null }
    if (-not $Info) { return $null }
    $Build = [int]$Info.Build
    $Ubr   = [int]$Info.SPBuild
    # Some media leaves Build and SPBuild empty and fills only the combined version string.
    if ($Build -le 0 -and "$($Info.Version)" -match '^\d+\.\d+\.(\d+)\.(\d+)$') {
        $Build = [int]$Matches[1]
        $Ubr   = [int]$Matches[2]
    }
    if ($Build -le 0) { return $null }
    return [pscustomobject]@{ Build = $Build; Ubr = $Ubr; Version = "10.0.$Build.$Ubr" }
}

# Answers "is servicing this recovery image going to change anything" WITHOUT mounting it, which is the
# whole point: the mount, the /ResetBase and the re-export are the expensive part, not the update itself.
# Returns $true only when it can positively prove the image is already there, because wrongly skipping
# would silently ship a stale recovery environment.
function Test-WinReAlreadyCurrent {
    param(
        [Parameter(Mandatory)][string]$WinReWim,
        [string]$KbNumber,
        [psobject]$Version
    )
    if (-not $KbNumber) { return $false }
    # Cached because this runs once per serviced edition and the answer cannot change mid-build. An empty
    # table is the "asked and the page did not say" marker, so the lookup is not retried.
    if ($null -eq $script:SafeOsTargets) {
        $script:SafeOsTargets = Get-KbTargetBuilds -KbNumber $KbNumber
        if (-not $script:SafeOsTargets) { $script:SafeOsTargets = @{} }
    }
    if ($script:SafeOsTargets.Count -eq 0) { return $false }

    if (-not $Version) { $Version = Get-WinReVersion -WinReWim $WinReWim }
    if (-not $Version -or $Version.Ubr -le 0 -or -not $script:SafeOsTargets.ContainsKey($Version.Build)) { return $false }

    $TargetUbr = [int]$script:SafeOsTargets[$Version.Build]
    if ($TargetUbr -le 0 -or $Version.Ubr -lt $TargetUbr) { return $false }
    Write-HostTimestamp "    The recovery image is already at $($Version.Version) and KB$KbNumber delivers 10.0.$($Version.Build).$TargetUbr, so it is left as it is." -ForegroundColor Green
    return $true
}
#endregion

