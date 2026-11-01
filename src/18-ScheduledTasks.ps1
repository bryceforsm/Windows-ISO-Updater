#region Scheduled task registration
# Rebuilds this run's command line for the task, dropping the parameters that only make sense when a human
# typed them and adding -Scheduled so the task never waits at a prompt.
function Get-ScheduledTaskArgumentString {
    $Excluded = @(
        'RegisterScheduledTask', 'UnregisterScheduledTask', 'Schedule', 'ScheduleTime', 'ScheduleDay',
        'TaskName', 'TaskUsername', 'TaskPassword', 'PromptTaskPassword', 'CheckOnly', 'Force', 'ListEditions', 'Unattended', 'SkipInteractive', 'Scheduled',
        'ServiceWinRE', 'Server'
    )
    # -Command keeps single-quoted string literals intact; -File strips quotes and misreads
    # hyphen-prefixed values (e.g. '-unattended') as switch names.
    $EscapedPath = $script:ScriptPath -replace "'", "''"
    $Parts = New-Object System.Collections.Generic.List[string]
    $Parts.Add("& '$EscapedPath'")
    $Parts.Add('-Scheduled')

    foreach ($Name in @($script:ScriptBoundParameters.Keys)) {
        if ($Excluded -contains $Name) { continue }
        $Value = $script:ScriptBoundParameters[$Name]
        if ($Value -is [switch]) {
            if ($Value.IsPresent) { $Parts.Add("-$Name") }
            continue
        }
        $Parts.Add("-$Name")
        foreach ($Item in @($Value)) {
            $EscapedItem = "$Item" -replace "'", "''"
            $Parts.Add("'$EscapedItem'")
        }
    }
    return "-NoProfile -ExecutionPolicy Bypass -Command `"$($Parts -join ' ')`""
}

# Microsoft publishes Patch Tuesday updates around 10:00 Pacific, so -Schedule PatchTuesday aims for 10:30
# Pacific translated into this machine's time zone. Pacific and local DST rules drift apart during the
# year, so the latest local equivalent across the next twelve Patch Tuesdays is used: running late is
# harmless (the stamp check exits in a minute or two), running early misses that month's updates for a
# whole month. Returns $null when the Pacific zone cannot be resolved.
function Get-PatchTuesdayStart {
    $Pacific = $null
    foreach ($Id in @('Pacific Standard Time', 'America/Los_Angeles')) {
        try { $Pacific = [System.TimeZoneInfo]::FindSystemTimeZoneById($Id); break } catch { }
    }
    if (-not $Pacific) { return $null }

    $LatestSameDay = [timespan]::Zero
    $LatestNextDay = $null
    $FirstOfThisMonth = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    for ($Index = 0; $Index -lt 12; $Index++) {
        $FirstOfMonth = $FirstOfThisMonth.AddMonths($Index)
        $ToTuesday = ([int][System.DayOfWeek]::Tuesday - [int]$FirstOfMonth.DayOfWeek + 7) % 7
        $SecondTuesday = $FirstOfMonth.AddDays($ToTuesday + 7)
        $PacificStart = [datetime]::new($SecondTuesday.Year, $SecondTuesday.Month, $SecondTuesday.Day, 10, 30, 0, [System.DateTimeKind]::Unspecified)
        $LocalStart = [System.TimeZoneInfo]::ConvertTime($PacificStart, $Pacific, [System.TimeZoneInfo]::Local)
        if ($LocalStart.Date -ne $SecondTuesday.Date) {
            if ($null -eq $LatestNextDay -or $LocalStart.TimeOfDay -gt $LatestNextDay) { $LatestNextDay = $LocalStart.TimeOfDay }
        }
        elseif ($LocalStart.TimeOfDay -gt $LatestSameDay) {
            $LatestSameDay = $LocalStart.TimeOfDay
        }
    }

    # Where any month spills over midnight the whole schedule moves to the following local day, and only
    # those months set the time - any month that did land on the Tuesday is then at most a few hours late.
    $CrossesMidnight = ($null -ne $LatestNextDay)
    $StartTime = if ($CrossesMidnight) { $LatestNextDay } else { $LatestSameDay }
    $ZoneName = if ($Pacific.IsDaylightSavingTime((Get-Date))) { $Pacific.DaylightName } else { $Pacific.StandardName }

    return [pscustomobject]@{
        TimeOfDay       = $StartTime
        CrossesMidnight = $CrossesMidnight
        ZoneName        = $ZoneName
    }
}

function Register-UpdaterScheduledTask {
    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'The ScheduledTasks PowerShell module is not available on this machine.'
    }
    if (-not $script:ScriptPath -or -not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw 'The path of this script could not be determined, so a scheduled task cannot point at it.'
    }

    if ($TaskPassword -and -not $TaskUsername) {
        throw '-TaskPassword requires -TaskUsername. Omit both to run the task as SYSTEM.'
    }

    # NT SERVICE\ virtual accounts are synthetic and will not resolve through NTAccount.Translate
    if ($TaskUsername -and $TaskUsername -notlike 'NT SERVICE\*') {
        try {
            ([System.Security.Principal.NTAccount]$TaskUsername).Translate(
                [System.Security.Principal.SecurityIdentifier]) | Out-Null
        }
        catch {
            throw "The account '$TaskUsername' could not be resolved: $($_.Exception.Message)"
        }
    }

    $TimeText = $ScheduleTime
    $PatchTuesday = $null
    if ($Schedule -eq 'PatchTuesday') {
        $PatchTuesday = Get-PatchTuesdayStart
        if (-not $script:ScriptBoundParameters.ContainsKey('ScheduleTime')) {
            $TimeText = if ($PatchTuesday) { ([datetime]::Today.Add($PatchTuesday.TimeOfDay)).ToString('HH:mm') } else { '10:30' }
        }
    }

    if ($TimeText -notmatch '^(\d{1,2}):(\d{2})$') {
        throw "-ScheduleTime '$TimeText' is not a valid 24-hour HH:mm time."
    }
    $Hour = [int]$Matches[1]
    $Minute = [int]$Matches[2]
    if ($Hour -gt 23 -or $Minute -gt 59) {
        throw "-ScheduleTime '$TimeText' is not a valid 24-hour HH:mm time."
    }
    # Anchor the trigger on today's date at that time.
    $Start = Get-Date -Hour $Hour -Minute $Minute -Second 0 -Millisecond 0

    # Register-ScheduledTask rejects the MSFT_Task*Monthly*Trigger CIM classes outright ("the parameter is
    # incorrect"), so a monthly schedule is registered with a placeholder weekly trigger and then rewritten
    # through the task's own XML, where Task Scheduler does accept a monthly calendar trigger.
    $CalendarXml = $null
    $MonthsXml = '<Months><January /><February /><March /><April /><May /><June /><July /><August /><September /><October /><November /><December /></Months>'

    switch ($Schedule) {
        'Hourly' {
            # No repetition duration = repeat indefinitely.
            $Trigger = New-ScheduledTaskTrigger -Once -At $Start -RepetitionInterval (New-TimeSpan -Hours 1)
            $When = "every hour, starting at $($Start.ToString('HH:mm'))"
        }
        'Daily' {
            $Trigger = New-ScheduledTaskTrigger -Daily -At $Start
            $When = "every day at $($Start.ToString('HH:mm'))"
        }
        'Weekly' {
            $DayName = if ($ScheduleDay) { $ScheduleDay } else { 'Sunday' }
            $Day = $null
            try { $Day = [System.DayOfWeek][enum]::Parse([System.DayOfWeek], $DayName, $true) }
            catch { throw "-ScheduleDay '$DayName' is not a weekday name (use e.g. Sunday, Monday...)." }
            $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Start
            $When = "every $Day at $($Start.ToString('HH:mm'))"
        }
        'Monthly' {
            $DayNumber = if ($ScheduleDay) { $ScheduleDay } else { '15' }
            if ($DayNumber -notmatch '^\d{1,2}$' -or [int]$DayNumber -lt 1 -or [int]$DayNumber -gt 31) {
                throw "-ScheduleDay '$DayNumber' is not a day of the month (use 1-31) for a monthly schedule."
            }
            $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Start
            $CalendarXml = "<ScheduleByMonth><DaysOfMonth><Day>$([int]$DayNumber)</Day></DaysOfMonth>$MonthsXml</ScheduleByMonth>"
            $When = "on day $DayNumber of every month at $($Start.ToString('HH:mm'))"
        }
        'PatchTuesday' {
            if ($ScheduleDay) {
                Write-HostTimestamp "-ScheduleDay '$ScheduleDay' is ignored by -Schedule PatchTuesday." -ForegroundColor Yellow
            }
            $PacificNote = ''
            if ($PatchTuesday -and -not $script:ScriptBoundParameters.ContainsKey('ScheduleTime') -and $PatchTuesday.TimeOfDay -ne [timespan]::new(10, 30, 0)) {
                $PacificNote = " (10:30 $($PatchTuesday.ZoneName) in local time)"
            }
            $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Start
            if ($PatchTuesday -and $PatchTuesday.CrossesMidnight) {
                # 10:30 Pacific lands on the next local day here, and the Wednesday after the second Tuesday
                # is not always in week 2, so both weeks are triggered - the early one just exits.
                $CalendarXml = "<ScheduleByMonthDayOfWeek><Weeks><Week>2</Week><Week>3</Week></Weeks><DaysOfWeek><Wednesday /></DaysOfWeek>$MonthsXml</ScheduleByMonthDayOfWeek>"
                $When = "on the second and third Wednesday of every month at $($Start.ToString('HH:mm'))$PacificNote, which is the local morning after Patch Tuesday"
            }
            else {
                $CalendarXml = "<ScheduleByMonthDayOfWeek><Weeks><Week>2</Week></Weeks><DaysOfWeek><Tuesday /></DaysOfWeek>$MonthsXml</ScheduleByMonthDayOfWeek>"
                $When = "on the second Tuesday of every month at $($Start.ToString('HH:mm'))$PacificNote"
                if ($PatchTuesday -and $Start.TimeOfDay -lt $PatchTuesday.TimeOfDay) {
                    Write-HostTimestamp "-ScheduleTime $($Start.ToString('HH:mm')) is earlier than $(([datetime]::Today.Add($PatchTuesday.TimeOfDay)).ToString('HH:mm')) (10:30 $($PatchTuesday.ZoneName)), so the task may run before that month's updates are published." -ForegroundColor Yellow
                }
            }
        }
    }

    $Exe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path -Path $PSHOME -ChildPath 'pwsh.exe' } else { Join-Path -Path $PSHOME -ChildPath 'powershell.exe' }
    $ArgumentString = Get-ScheduledTaskArgumentString
    $Action = New-ScheduledTaskAction -Execute $Exe -Argument $ArgumentString -WorkingDirectory (Split-Path -Parent $script:ScriptPath)
    if ($TaskUsername) {
        $Principal = New-ScheduledTaskPrincipal -UserId $TaskUsername -LogonType Password -RunLevel Highest
    } else {
        # SYSTEM needs no stored password and is already elevated for DISM.
        $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 8)

    $RegParams = @{
        TaskName    = $TaskName
        Trigger     = $Trigger
        Action      = $Action
        Principal   = $Principal
        Settings    = $Settings
        Description = 'Rebuilds an up-to-date Windows installation ISO (Windows-ISO-Updater). Skips the build when nothing has changed.'
        Force       = $true
        ErrorAction = 'Stop'
    }
    if ($TaskPassword) { $RegParams['Password'] = $TaskPassword }
    Register-ScheduledTask @RegParams | Out-Null

    if ($CalendarXml) {
        # Monthly triggers can only be set through XML; re-register after swapping the placeholder weekly trigger.
        $TaskXml = (Export-ScheduledTask -TaskName $TaskName) -replace '(?s)<ScheduleByWeek>.*?</ScheduleByWeek>', $CalendarXml
        $XmlRegParams = @{
            TaskName    = $TaskName
            Xml         = $TaskXml
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($TaskUsername) { $XmlRegParams['User'] = $TaskUsername }
        if ($TaskPassword) { $XmlRegParams['Password'] = $TaskPassword }
        Register-ScheduledTask @XmlRegParams | Out-Null
    }

    $PrincipalUser = if ($TaskUsername) { $TaskUsername } else { 'SYSTEM' }
    Write-HostTimestamp "Scheduled task '$TaskName' registered: runs $When as $PrincipalUser." -ForegroundColor Green
    Write-HostTimestamp "  Command: `"$Exe`" $ArgumentString" -ForegroundColor DarkGray
    if (-not $TaskUsername) {
        Write-HostTimestamp '  It runs as SYSTEM, so every path it uses must be a local path SYSTEM can reach (not a mapped drive or a cloud-synced user folder).' -ForegroundColor Yellow
    }
    Write-HostTimestamp "  Each run compares the build stamp in $StampRoot and exits in a minute or two when nothing has changed." -ForegroundColor DarkGray
    Write-HostTimestamp "  Remove it again with: -UnregisterScheduledTask -TaskName `"$TaskName`"" -ForegroundColor DarkGray
}
#endregion

