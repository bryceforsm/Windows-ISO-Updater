#region Functions

#region Output and timing helpers
# The console shows only the time, because the run header gives the date and the .log records both on every line.
function Get-TimeStamp {
    param([datetime]$Date = (Get-Date))
    return $Date.ToString('[HH:mm:ss]', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Where a top-level message's text starts: after the timestamp, a space, the symbol and another space. Lists,
# tables and boxes start here too, so everything on the console shares one left edge.
function Get-MessageColumn {
    return (Get-TimeStamp).Length + 3
}

# The indent a line is drawn with. Messages and rows go in steps of two spaces: the top level for headings and
# anything outside a step, then one level for a step's own lines, and deeper levels for detail under those.
# Inside a step, a line written at the top level is moved in a level, so every line of a step starts at least
# in the same column as its "Step finished" line. -InStep is for the tests; it defaults to whether a step is running.
function Get-ConsoleIndent {
    param(
        [int]$Lead,
        [bool]$InStep = [bool]$script:CurrentStep
    )
    if ($InStep -and $Lead -lt 2) { return 2 }
    return $Lead
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
    # Floored, because [int] rounds and would show 1h 36m as 2h 36m.
    if ($Duration.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds) }
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

# The characters the console output is drawn with, chosen once per run. Write-Host reaches the console through
# its Unicode API, so any character arrives intact, but the font of a classic console window may not carry it,
# and [Console]::Write (the progress line) goes through the console's code page, which turns anything outside it
# into '?'. So there are three sets:
# - Unicode: Windows Terminal, the VS Code terminal, or a UTF-8 console, whose fonts carry check marks and
#   rounded corners.
# - Oem: a classic console on code page 437, 850 or 858, which all have box drawing, blocks and a square root sign.
# - Ascii: every other code page, and always when output is redirected or the run is scheduled, so a file or a
#   transcript read somewhere else never holds a character it cannot show.
# The .log never gets any of them, and the transcript only ever holds what the console showed. The characters are
# written as [char] codes because the script itself stays ASCII, which Windows PowerShell 5.1 reads correctly
# whatever its encoding.
function Get-ConsoleStyleSet {
    param(
        [bool]$Redirected,
        [int]$CodePage,
        [bool]$WindowsTerminal,
        [bool]$VsCode,
        [bool]$Scheduled,
        [bool]$VirtualTerminal
    )
    $Kind =
        if ($Redirected -or $Scheduled) { 'Ascii' }
        elseif ($WindowsTerminal -or $VsCode -or $CodePage -eq 65001) { 'Unicode' }
        elseif ($CodePage -in 437, 850, 858) { 'Oem' }
        else { 'Ascii' }
    $Style = switch ($Kind) {
        'Unicode' {
            @{ Ok = [string][char]0x2713; Warn = '!'; Error = [string][char]0x2717; Rule = [string][char]0x2500; Side = [string][char]0x2502
                TopLeft = [string][char]0x256D; TopRight = [string][char]0x256E; BottomLeft = [string][char]0x2570; BottomRight = [string][char]0x256F }
        }
        'Oem' {
            @{ Ok = [string][char]0x221A; Warn = '!'; Error = 'x'; Rule = [string][char]0x2500; Side = [string][char]0x2502
                TopLeft = [string][char]0x250C; TopRight = [string][char]0x2510; BottomLeft = [string][char]0x2514; BottomRight = [string][char]0x2518 }
        }
        default {
            @{ Ok = '+'; Warn = '!'; Error = 'x'; Rule = '-'; Side = '|'; TopLeft = '+'; TopRight = '+'; BottomLeft = '+'; BottomRight = '+' }
        }
    }
    $Style.Kind = $Kind
    # The bar goes through the code page, so its blocks have to exist in the code page itself, even in Windows Terminal.
    $Blocks = $Kind -ne 'Ascii' -and $CodePage -in 437, 850, 858, 65001
    $Style.BarFill = if ($Blocks) { [string][char]0x2588 } else { '#' }
    $Style.BarEmpty = if ($Blocks) { [string][char]0x2591 } else { '-' }
    # Windows Terminal fills the tab and the taskbar button from an escape sequence. Anywhere else it would print.
    $Style.TaskbarProgress = (-not $Redirected) -and (-not $Scheduled) -and $WindowsTerminal -and $VirtualTerminal
    return $Style
}

function Get-ConsoleStyle {
    if (-not $script:ConsoleStyle) {
        $Redirected = $true
        $CodePage = 0
        try {
            $Redirected = [Console]::IsOutputRedirected
            $CodePage = [Console]::OutputEncoding.CodePage
        }
        catch { }
        $Vt = try { [bool]$Host.UI.SupportsVirtualTerminal } catch { $false }
        $script:ConsoleStyle = Get-ConsoleStyleSet -Redirected $Redirected -CodePage $CodePage -WindowsTerminal ([bool]$env:WT_SESSION) -VsCode ($env:TERM_PROGRAM -eq 'vscode') -Scheduled ([bool]$Scheduled) -VirtualTerminal $Vt
    }
    return $script:ConsoleStyle
}

# The window title names the step and its percentage, so a build can be followed from the taskbar.
function Set-ConsoleTitle {
    param(
        [string]$Step,
        [int]$Percent = -1
    )
    if (-not $script:BaseWindowTitle) { return }
    $Parts = @()
    if ($Percent -ge 0) { $Parts += "$Percent%" }
    if ($Step) { $Parts += $Step.TrimEnd('.') }
    $Parts += $script:BaseWindowTitle
    try { $Host.UI.RawUI.WindowTitle = $Parts -join ' - ' } catch { }
}

# Windows Terminal's tab and taskbar progress (OSC 9;4): a percentage, a busy state for -1, or nothing with -Clear.
# Written straight to the console, so the sequence never reaches the transcript, and ended with ST rather than
# BEL, which a terminal that does not know the sequence could ring.
function Set-TaskbarProgress {
    param(
        [int]$Percent = -1,
        [switch]$Clear
    )
    if (-not (Get-ConsoleStyle).TaskbarProgress) { return }
    $Esc = [char]27
    $Code =
        if ($Clear) { '0;0' }
        elseif ($Percent -lt 0) { '3;0' }
        else { "1;$([math]::Min(100, $Percent))" }
    try { [Console]::Write("$Esc]9;4;$Code$Esc\") } catch { }
}

# A step's heading: the description followed by a rule out to the console's edge, less the column a console wraps
# on (see Format-ProgressLine). $PrefixLength is what goes in front of it on the line, the timestamp and symbol.
function Format-StepHeader {
    param(
        [string]$Text,
        [int]$Width,
        [string]$Rule = '-',
        [int]$PrefixLength = 0
    )
    $Fill = if ($Width -gt 0) { $Width - 1 - $PrefixLength - $Text.Length - 1 } else { 3 }
    if ($Fill -lt 3) { return $Text }
    return "$Text " + ($Rule * $Fill)
}

# The finished run's summary in a box, as lines. A box wider than the console would wrap and fall apart, so then
# the rows are listed without one.
function Format-SummaryBox {
    param(
        [string]$Title,
        [System.Collections.Specialized.OrderedDictionary]$Rows,
        [int]$Width,
        [hashtable]$Style
    )
    $LabelWidth = (@($Rows.Keys) | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
    $Body = @(foreach ($Key in $Rows.Keys) { "{0,-$LabelWidth}   {1}" -f $Key, $Rows[$Key] })
    $Inner = [math]::Max((($Body | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum), $Title.Length + 2)
    if ($Width -gt 0 -and $Inner + 4 -gt $Width - 1) {
        return @($Title) + @($Body | ForEach-Object { "  $_" })
    }
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add($Style.TopLeft + $Style.Rule + " $Title " + ($Style.Rule * ($Inner - $Title.Length - 1)) + $Style.TopRight)
    foreach ($Line in $Body) { $Lines.Add($Style.Side + ' ' + $Line.PadRight($Inner) + ' ' + $Style.Side) }
    $Lines.Add($Style.BottomLeft + ($Style.Rule * ($Inner + 2)) + $Style.BottomRight)
    return $Lines.ToArray()
}

# The box goes to the console, and the .log gets the same rows as plain lines.
function Write-SummaryBox {
    param(
        [string]$Title,
        [System.Collections.Specialized.OrderedDictionary]$Rows,
        [consolecolor]$ForegroundColor = 'Green'
    )
    # In the message column, like every other block of output.
    $Column = Get-MessageColumn
    $Width = Get-ConsoleWidth
    if ($Width -gt 0) { $Width -= $Column }
    foreach ($Line in (Format-SummaryBox -Title $Title -Rows $Rows -Width $Width -Style (Get-ConsoleStyle))) {
        Write-Host ((' ' * $Column) + $Line) -ForegroundColor $ForegroundColor
    }
    Write-CMTraceLog -Message $Title
    foreach ($Key in $Rows.Keys) { Write-CMTraceLog -Message "  ${Key}: $($Rows[$Key])" }
}

# Flashes the console window's taskbar button until the window is next in front. Compiled only when a run needs it.
function Invoke-ConsoleFlash {
    try {
        if (-not ('WisoConsoleFlash' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WisoConsoleFlash {
    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FLASHWINFO info);
    public static void Flash() {
        IntPtr Window = GetConsoleWindow();
        if (Window == IntPtr.Zero) { return; }
        FLASHWINFO Info = new FLASHWINFO();
        Info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        Info.hwnd = Window;
        Info.dwFlags = 2 | 12;   // FLASHW_TRAY | FLASHW_TIMERNOFG: the taskbar button, until the window is in front
        FlashWindowEx(ref Info);
    }
}
'@
        }
        [WisoConsoleFlash]::Flash()
    }
    catch { }   # a missing compiler or an unusual host is no reason for the end of a build to fail
}

# Run once as the run ends, however it ends: clears the taskbar progress, says in the title how it went, and for a
# run someone started by hand that took a minute or more, sounds the console bell and flashes the taskbar button,
# because they have probably switched to another window. A scheduled or unattended run has nobody to hear it.
function Complete-ConsoleRun {
    param([switch]$Failed)
    if ($script:ConsoleRunCompleted) { return }
    $script:ConsoleRunCompleted = $true
    Set-TaskbarProgress -Clear
    Set-ConsoleTitle -Step $(if ($Failed) { 'Stopped' } else { 'Finished' })
    if ($Unattended -or $Scheduled) { return }
    if (-not $script:ScriptStartTime -or ((Get-Date) - $script:ScriptStartTime).TotalSeconds -lt 60) { return }
    try {
        if ([Console]::IsOutputRedirected) { return }
        [Console]::Write([string][char]7)
    }
    catch { return }
    Invoke-ConsoleFlash
}

# Every exit goes through here, so the console is finished with before the transcript stops.
function Stop-RunLogging {
    Complete-ConsoleRun -Failed:([bool]$script:ConsoleSawError)
    Stop-Transcript
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
# blanks it so the next message starts on a clean line, as it would have without it. A -Percent below 0 means
# the work has no percentage to show, and the line is the detail alone.
function Format-ProgressLine {
    param(
        [int]$Percent,
        [string]$Detail,
        [int]$Width,
        [int]$Indent = 0,
        [string]$Fill = '#',
        [string]$Empty = '-'
    )
    if ($Percent -lt 0) {
        if ($Indent + $Detail.Length -gt $Width - 1) { $Indent = 0 }
        $Line = (' ' * $Indent) + $Detail
        if ($Line.Length -gt $Width - 1) { $Line = $Line.Substring(0, [math]::Max(0, $Width - 1)) }
        return $Line
    }
    $Tail = ' {0,3}%  {1}' -f $Percent, $Detail
    # One column is kept free, because writing into the last column makes some consoles wrap, and a wrapped
    # line is one that \r cannot get back to.
    $BarWidth = [math]::Min(40, $Width - 1 - $Indent - $Tail.Length - 2)
    if ($BarWidth -lt 10) {
        $Indent = 0
        $BarWidth = [math]::Max(0, $Width - 1 - $Tail.Length - 2)
    }
    $Filled = [int][math]::Floor($BarWidth * $Percent / 100)
    $Line = (' ' * $Indent) + '[' + ($Fill * $Filled) + ($Empty * ($BarWidth - $Filled)) + ']' + $Tail
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

# Without an -Indent, the line goes one level under the text of the last timestamped message, which is the
# one it reports on, so no caller has to know how wide the timestamp is.
function New-ProgressLine {
    param([int]$Indent = -1)
    if ($Indent -lt 0) {
        $Indent = if ($script:LastTextColumn) { $script:LastTextColumn + 2 } else { (Get-MessageColumn) + 2 }
    }
    return @{ Width = (Get-ConsoleWidth); Indent = $Indent; Start = (Get-Date); Percent = -2; Detail = $null; Drawn = $false; Length = 0 }
}

# Redraws only when the percentage or the detail has changed. Without a -Detail, the time taken so far is shown.
function Update-ProgressLine {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [int]$Percent,
        [string]$Detail
    )
    if ($Percent -lt 0) { $Percent = -1 } else { $Percent = [math]::Min(100, $Percent) }
    if ($Percent -eq $State.Percent -and $Detail -eq $State.Detail) { return }
    $State.Percent = $Percent
    $State.Detail = $Detail
    if ($State.Width -le 0) { return }
    if (-not $Detail) { $Detail = Format-Duration ((Get-Date) - $State.Start) }
    try {
        $Style = Get-ConsoleStyle
        $Line = Format-ProgressLine -Percent $Percent -Detail $Detail -Width $State.Width -Indent $State.Indent -Fill $Style.BarFill -Empty $Style.BarEmpty
        # Padded out to the last line drawn, so a shorter redraw does not leave the end of the old one behind.
        [Console]::Write("`r" + $Line.PadRight([int]$State.Length))
        $State.Length = $Line.Length
        $State.Drawn = $true
    }
    catch { $State.Width = 0; return }   # a host without a real console, so stop trying
    # The title and the taskbar change only with the percentage, not with every redraw of the detail.
    if ($Percent -ne $State.Shown) {
        $State.Shown = $Percent
        Set-TaskbarProgress -Percent $Percent
        Set-ConsoleTitle -Step $script:CurrentStep -Percent $Percent
    }
}

function Clear-ProgressLine {
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.Drawn) { return }
    try { [Console]::Write("`r" + (' ' * ($State.Width - 1)) + "`r") } catch { }
    $State.Drawn = $false
    $State.Shown = $null
    Set-TaskbarProgress -Clear
    Set-ConsoleTitle -Step $script:CurrentStep
}

# The symbol in front of a message, from the line's color: green succeeded, yellow is a warning and red an error.
# Every other line gets a blank in its place, so messages at the same depth start in the same column.
function Get-ConsoleSymbol {
    param(
        [string]$Color,
        [hashtable]$Style
    )
    switch -Regex ($Color) {
        '^(Dark)?Green$'  { return $Style.Ok }
        '^(Dark)?Yellow$' { return $Style.Warn }
        '^(Dark)?Red$'    { return $Style.Error }
        default           { return ' ' }
    }
}

function Write-HostTimestamp {
    param (
        [string]$Message,
        [consolecolor]$ForegroundColor = $(try { ((Get-Host).ui.rawui.ForegroundColor) } catch { 'White' }),
        # Replaces the symbol the color would pick. A step heading uses it for its rule.
        [string]$Symbol,
        # What the .log gets, when it should not be the console text.
        [string]$LogMessage
    )

    $Style = Get-ConsoleStyle
    # The stamp has no date, so a run that goes past midnight says once that the day has changed.
    $Now = Get-Date
    if ($script:ConsoleDate -and $script:ConsoleDate -ne $Now.Date) {
        Write-Host "$(Get-TimeStamp -Date $Now)   The date is now $(Get-FriendlyDate -Date $Now)."
    }
    $script:ConsoleDate = $Now.Date
    if ("$ForegroundColor" -match '^(Dark)?Red$') { $script:ConsoleSawError = $true }

    # The console copy is wrapped to fit the window. The CMTrace log gets the message whole, on one line.
    if (-not $PSBoundParameters.ContainsKey('Symbol')) { $Symbol = Get-ConsoleSymbol -Color "$ForegroundColor" -Style $Style }
    # The symbol goes just before the text, after the message's own indent, so it stays beside what it marks.
    $Lead = $Message.Length - $Message.TrimStart().Length
    # A step's heading stays at the top level. Everything else follows the indent rules (see Get-ConsoleIndent).
    if (-not $PSBoundParameters.ContainsKey('Symbol')) { $Lead = Get-ConsoleIndent -Lead $Lead }
    $Line = "$(Get-TimeStamp -Date $Now) " + (' ' * $Lead) + "$Symbol " + $Message.TrimStart()
    $Indent = (Get-MessageColumn) + $Lead
    # Where this message's text starts, so a progress line that follows can sit one level under it.
    $script:LastTextColumn = $Indent
    foreach ($Part in (Format-WrappedText -Text $Line -Width (Get-ConsoleWidth) -Indent $Indent)) {
        Write-Host $Part -ForegroundColor $ForegroundColor
    }
    if (-not $PSBoundParameters.ContainsKey('LogMessage')) { $LogMessage = $Message }
    Write-CMTraceLog -Message $LogMessage -Type (Get-LogSeverity -Color "$ForegroundColor") -Line $MyInvocation.ScriptLineNumber
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

    if (-not "$Message".Trim()) { Write-Host ''; return }
    # Rows start in the message column, so a list or table lines up with the timestamped lines around it, and
    # inside a step they move in a level like the step's own lines (see Get-ConsoleIndent).
    $Lead = Get-ConsoleIndent -Lead ($Message.Length - $Message.TrimStart().Length)
    $Line = (' ' * ((Get-MessageColumn) + $Lead)) + $Message.TrimStart()
    foreach ($Part in (Format-WrappedText -Text $Line -Width (Get-ConsoleWidth) -Indent ((Get-MessageColumn) + $Lead))) {
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
    $PreviousStep = $script:CurrentStep
    $script:LogComponent = $Description
    $script:CurrentStep = $Description
    # A heading in cyan with a rule out to the edge, so each step stands out from the long stretches of DISM output.
    $Style = Get-ConsoleStyle
    $Heading = Format-StepHeader -Text $Description -Width (Get-ConsoleWidth) -Rule $Style.Rule -PrefixLength ((Get-TimeStamp).Length + 3)
    Write-HostTimestamp $Heading -ForegroundColor Cyan -Symbol $Style.Rule -LogMessage $Description
    Set-ConsoleTitle -Step $Description
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
        Write-HostTimestamp "  Step finished in $(Format-Duration $Elapsed)."
        $script:LogComponent = $PreviousComponent
        $script:CurrentStep = $PreviousStep
        Set-ConsoleTitle -Step $PreviousStep
    }
    Write-Host $LineBreak
}
#endregion

