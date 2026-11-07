#region Functions

#region Output and timing helpers
function Get-TimeStamp {
    return (Get-Date -Format '[MM/dd/yyyy|HH:mm:ss]')
}

function Get-FriendlyDate {
    param([datetime]$Date = (Get-Date))
    # Ordinal suffixes are English-only, so the month name is forced to invariant culture rather than
    # the thread culture the Locale line above already reports.
    $Day = $Date.Day
    $Suffix = if ($Day -in 11, 12, 13) { 'th' }
    else {
        switch ($Day % 10) {
            1 { 'st' }
            2 { 'nd' }
            3 { 'rd' }
            default { 'th' }
        }
    }
    return '{0} {1}{2} {3}' -f $Date.ToString('MMMM', [System.Globalization.CultureInfo]::InvariantCulture), $Day, $Suffix, $Date.Year
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds) }
    if ($Duration.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f $Duration.Minutes, $Duration.Seconds) }
    return ('{0:N1}s' -f $Duration.TotalSeconds)
}

function Write-CMTraceLog {
    param(
        [string]$Message,
        [ValidateRange(1, 3)][int]$Type = 1,
        [string]$Component = $script:LogComponent,
        [int]$Line = 0
    )

    if (-not $script:CMTraceLog) { return }
    try {
        $Now = Get-Date
        # CMTrace reads the offset as minutes behind UTC, so a machine at UTC-5 writes +300.
        $Bias = [int](-[System.TimeZoneInfo]::Local.GetUtcOffset($Now).TotalMinutes)
        $Entry = '<![LOG[{0}]LOG]!><time="{1}{2}{3:000}" date="{4}" component="{5}" context="" type="{6}" thread="{7}" file="{8}:{9}">' -f
            # Indents and column padding only line things up on the console, so CMTrace gets single spaces.
            ("$Message".Trim() -replace '[ \t]{2,}', ' ').Replace(']LOG]!>', ']LOG] !>'),
            $Now.ToString('HH:mm:ss.fff'),
            $(if ($Bias -ge 0) { '+' } else { '-' }),
            [math]::Abs($Bias),
            $Now.ToString('MM-dd-yyyy'),
            "$Component".Replace('"', "'"),
            $Type,
            $PID,
            $script:LogScriptName,
            $Line
        [System.IO.File]::AppendAllText($script:CMTraceLog, $Entry + "`r`n", [System.Text.Encoding]::UTF8)
    }
    catch { }   # a log that cannot be written must never be the reason a build stops
}

# The width to wrap console output at, or 0 when it should not be wrapped. Output that is redirected has no
# edge to wrap at, and a host without a console buffer cannot report one.
function Get-ConsoleWidth {
    try {
        if ([Console]::IsOutputRedirected) { return 0 }
        return [int]$Host.UI.RawUI.BufferSize.Width
    }
    catch { return 0 }
}

# The console cuts a long line at its edge, mid-word, and carries on at column 0. This breaks it between
# words instead, and starts each continuation $Indent columns in, so it lines up under the message rather
# than under the timestamp. A path has no spaces, so it breaks after a separator, and a word is only cut
# when it is wider than the console on its own.
function Format-WrappedText {
    param(
        [string]$Text,
        [int]$Width,
        [int]$Indent = 0
    )

    if ($Width -le 0 -or $Text.Length -le $Width) { return $Text }
    # On a narrow console a timestamp-wide indent would leave too little room for the message.
    if ($Indent -gt [math]::Floor($Width / 2)) { $Indent = 0 }
    $Pad = ' ' * $Indent
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Rest = $Text
    while ($Rest.Length -gt $Width) {
        # The search starts past the indent, so a continuation cannot break inside its own padding.
        $Floor = $Indent + 1
        $Cut = $Rest.Substring(0, $Width + 1).LastIndexOf(' ')
        if ($Cut -ge $Floor) {
            $Head = $Rest.Substring(0, $Cut).TrimEnd()
            $Tail = $Rest.Substring($Cut + 1).TrimStart()
        }
        else {
            $Cut = $Rest.Substring(0, $Width).LastIndexOfAny([char[]]'\/_-')
            if ($Cut -lt $Floor) { $Cut = $Width - 1 }
            $Head = $Rest.Substring(0, $Cut + 1)
            $Tail = $Rest.Substring($Cut + 1)
        }
        $Lines.Add($Head)
        $Rest = $Pad + $Tail
    }
    $Lines.Add($Rest)
    return $Lines.ToArray()
}

# A progress line: one console line, such as "      [############--------]  47%  2m 13s", that is redrawn
# in place while a long operation runs and cleared when it ends. It is written straight to the console rather
# than through Write-Host, so it never reaches the transcript or the CMTrace log, and nothing is drawn when
# output is redirected. New-ProgressLine starts one, Update-ProgressLine redraws it, Clear-ProgressLine
# blanks it so the next message starts on a clean line, as it would have without it.
function Format-ProgressLine {
    param(
        [int]$Percent,
        [string]$Detail,
        [int]$Width,
        [int]$Indent = 0
    )
    $Tail = ' {0,3}%  {1}' -f $Percent, $Detail
    # One column is kept free, because writing into the last column makes some consoles wrap, and a wrapped
    # line is one that \r cannot get back to.
    $BarWidth = [math]::Min(40, $Width - 1 - $Indent - $Tail.Length - 2)
    if ($BarWidth -lt 10) {
        $Indent = 0
        $BarWidth = [math]::Max(0, $Width - 1 - $Tail.Length - 2)
    }
    $Filled = [int][math]::Floor($BarWidth * $Percent / 100)
    $Line = (' ' * $Indent) + '[' + ('#' * $Filled) + ('-' * ($BarWidth - $Filled)) + ']' + $Tail
    # A detail too long for a narrow console is cut rather than allowed to wrap.
    if ($Line.Length -gt $Width - 1) { $Line = $Line.Substring(0, [math]::Max(0, $Width - 1)) }
    return $Line
}

# How far a transfer has got, such as "1.23 of 6.84 GB, 45 MB/s".
function Format-ByteProgress {
    param(
        [long]$Done,
        [long]$Total,
        [TimeSpan]$Elapsed
    )
    $Speed = if ($Elapsed.TotalSeconds -ge 1) { ', {0:N0} MB/s' -f ($Done / 1MB / $Elapsed.TotalSeconds) } else { '' }
    if ($Total -ge 1GB) { return ('{0:N2} of {1:N2} GB{2}' -f ($Done / 1GB), ($Total / 1GB), $Speed) }
    return ('{0:N0} of {1:N0} MB{2}' -f ($Done / 1MB), ($Total / 1MB), $Speed)
}

function New-ProgressLine {
    param([int]$Indent = 0)
    return @{ Width = (Get-ConsoleWidth); Indent = $Indent; Start = (Get-Date); Percent = -1; Detail = $null; Drawn = $false }
}

# Redraws only when the percentage or the detail has changed. Without a -Detail, the time taken so far is shown.
function Update-ProgressLine {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [int]$Percent,
        [string]$Detail
    )
    $Percent = [math]::Max(0, [math]::Min(100, $Percent))
    if ($Percent -eq $State.Percent -and $Detail -eq $State.Detail) { return }
    $State.Percent = $Percent
    $State.Detail = $Detail
    if ($State.Width -le 0) { return }
    if (-not $Detail) { $Detail = Format-Duration ((Get-Date) - $State.Start) }
    try {
        [Console]::Write("`r" + (Format-ProgressLine -Percent $Percent -Detail $Detail -Width $State.Width -Indent $State.Indent))
        $State.Drawn = $true
    }
    catch { $State.Width = 0 }   # a host without a real console, so stop trying
}

function Clear-ProgressLine {
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.Drawn) { return }
    try { [Console]::Write("`r" + (' ' * ($State.Width - 1)) + "`r") } catch { }
    $State.Drawn = $false
}

function Write-HostTimestamp {
    param (
        [string]$Message,
        [consolecolor]$ForegroundColor = $(try { ((Get-Host).ui.rawui.ForegroundColor) } catch { 'White' })
    )

    # The console copy is wrapped to fit the window. The CMTrace log gets the message whole, on one line.
    $Stamp = Get-TimeStamp
    $Indent = $Stamp.Length + 1 + ($Message.Length - $Message.TrimStart().Length)
    foreach ($Part in (Format-WrappedText -Text "$Stamp $Message" -Width (Get-ConsoleWidth) -Indent $Indent)) {
        Write-Host $Part -ForegroundColor $ForegroundColor
    }
    Write-CMTraceLog -Message $Message -Type (Get-LogSeverity -Color "$ForegroundColor") -Line $MyInvocation.ScriptLineNumber
}

# Red and Yellow already mean fatal and warning throughout this script, so CMTrace's severity comes free.
function Get-LogSeverity {
    param([string]$Color)
    switch -Regex ($Color) {
        '^(Dark)?Red$'    { return 3 }
        '^(Dark)?Yellow$' { return 2 }
        default           { return 1 }
    }
}

# For tables and lists, where a timestamp on every row would break the columns but the .log still needs the rows.
function Write-HostLog {
    param (
        [string]$Message,
        [consolecolor]$ForegroundColor = $(try { ((Get-Host).ui.rawui.ForegroundColor) } catch { 'White' })
    )

    $Indent = $Message.Length - $Message.TrimStart().Length
    foreach ($Part in (Format-WrappedText -Text $Message -Width (Get-ConsoleWidth) -Indent $Indent)) {
        Write-Host $Part -ForegroundColor $ForegroundColor
    }
    if ("$Message".Trim()) {
        Write-CMTraceLog -Message $Message -Type (Get-LogSeverity -Color "$ForegroundColor") -Line $MyInvocation.ScriptLineNumber
    }
}

function Invoke-Task {
    param(
        [string]$Description,
        [scriptblock]$ScriptBlock
    )

    # Naming the component after the step is what makes CMTrace's filter useful on a log this long.
    $PreviousComponent = $script:LogComponent
    $script:LogComponent = $Description
    Write-HostTimestamp $Description
    $StepStart = Get-Date
    try {
        & $ScriptBlock
    }
    catch {
        # PowerShell prints an uncaught error to the console only, so without this the .log just stops.
        Write-CMTraceLog -Message "$Description failed: $($_.Exception.Message)" -Type 3 -Line $_.InvocationInfo.ScriptLineNumber
        throw
    }
    finally {
        # Recorded in a finally block so a step that throws still contributes to the timing summary.
        $Elapsed = (Get-Date) - $StepStart
        $script:StepTimings.Add([pscustomobject]@{ Description = $Description; Duration = $Elapsed })
        Write-HostTimestamp "  Step finished in $(Format-Duration $Elapsed)." -ForegroundColor DarkGray
        $script:LogComponent = $PreviousComponent
    }
    Write-Host $LineBreak
}
#endregion

