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

function Write-HostTimestamp {
    param (
        [string]$Message,
        [consolecolor]$ForegroundColor = $(try { ((Get-Host).ui.rawui.ForegroundColor) } catch { 'White' })
    )

    # Get the current timestamp and combine it with the user's message.
    # The output is then sent to the console using Write-Host with the specified color.
    Write-Host "$(Get-TimeStamp) $Message" -ForegroundColor $ForegroundColor
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

    Write-Host $Message -ForegroundColor $ForegroundColor
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

