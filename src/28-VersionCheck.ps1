#region Version check
# Each run asks GitHub for the latest release, so an old copy of the script says so. The check must never slow a
# build or stop one. The request starts before the run header and is collected after the environment report,
# which takes about as long, and the whole check gives up after a few seconds. A check that cannot reach GitHub
# is written only to the .log, so an offline or locked-down machine sees nothing about it on the console.
# -SkipVersionCheck turns it off.
$script:VersionCheckUrl = 'https://api.github.com/repos/bryceforsm/Windows-ISO-Updater/releases/latest'
$script:LatestReleaseUrl = 'https://github.com/bryceforsm/Windows-ISO-Updater/releases/latest'

# Sends the request and returns at once, without waiting for the answer. Returns an object holding the pending
# request, or one holding the error when the request could not even be sent.
function Start-VersionCheck {
    param(
        [string]$Url = $script:VersionCheckUrl,
        [int]$TimeoutSeconds = 3
    )
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        # Windows PowerShell 5.1 can still default to TLS 1.0, which GitHub refuses.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Client = New-Object System.Net.Http.HttpClient
        $Client.Timeout = [timespan]::FromSeconds($TimeoutSeconds)
        # GitHub's API refuses a request with no User-Agent. This one names only the script and its version.
        $Client.DefaultRequestHeaders.UserAgent.ParseAdd("Windows-ISO-Updater/$ScriptVersion")
        $Client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
        return [pscustomobject]@{
            Client   = $Client
            Task     = $Client.GetStringAsync($Url)
            Deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{ Client = $null; Task = $null; Deadline = [datetime]::UtcNow; Error = $_.Exception.Message }
    }
}

# Compares this script's version with a release tag. Both are yyyy.MM.dd.<revision>, which [version] orders
# correctly. Status is Latest, Outdated, Newer (a build from main that has not been released yet) or Failed.
function Compare-ScriptVersion {
    param(
        [string]$Current,
        [string]$Latest,
        [string]$Url = $script:LatestReleaseUrl
    )
    $Tag = "$Latest".Trim() -replace '^[vV]', ''
    $CurrentVersion = $null
    $LatestVersion = $null
    if (-not [version]::TryParse("$Current", [ref]$CurrentVersion)) {
        return [pscustomobject]@{ Status = 'Failed'; Latest = $Tag; Url = $Url; Reason = "this script's version '$Current' is not a version number" }
    }
    if (-not [version]::TryParse($Tag, [ref]$LatestVersion)) {
        return [pscustomobject]@{ Status = 'Failed'; Latest = $Tag; Url = $Url; Reason = "the latest release's tag '$Latest' is not a version number" }
    }
    $Status =
        if ($CurrentVersion -lt $LatestVersion) { 'Outdated' }
        elseif ($CurrentVersion -gt $LatestVersion) { 'Newer' }
        else { 'Latest' }
    return [pscustomobject]@{ Status = $Status; Latest = $Tag; Url = $Url; Reason = $null }
}

# Waits for the answer until the check's deadline at most, then compares it with this script's version. Never
# throws: anything that goes wrong comes back as Status Failed with the reason.
function Receive-VersionCheck {
    param(
        [Parameter(Mandatory)]$Check,
        [string]$Current = $ScriptVersion
    )
    $Failed = { param($Reason) [pscustomobject]@{ Status = 'Failed'; Latest = $null; Url = $script:LatestReleaseUrl; Reason = $Reason } }
    try {
        if ($Check.Error) { return & $Failed $Check.Error }
        $Wait = [int][math]::Max(0, ($Check.Deadline - [datetime]::UtcNow).TotalMilliseconds)
        if (-not $Check.Task.Wait($Wait)) {
            if ($Check.Client) { $Check.Client.CancelPendingRequests() }
            return & $Failed 'GitHub did not answer in time'
        }
        $Release = $Check.Task.Result | ConvertFrom-Json
        $Url = if ($Release.html_url) { "$($Release.html_url)" } else { $script:LatestReleaseUrl }
        return Compare-ScriptVersion -Current $Current -Latest "$($Release.tag_name)" -Url $Url
    }
    catch {
        # A failed request surfaces as an AggregateException, whose innermost error is the one worth logging.
        return & $Failed $_.Exception.GetBaseException().Message
    }
    finally {
        if ($Check.Client) { $Check.Client.Dispose() }
    }
}

# Shows the result. A check that failed or was skipped goes only to the .log.
function Write-VersionCheckResult {
    param(
        [Parameter(Mandatory)]$Result,
        [string]$Current = $ScriptVersion
    )
    switch ($Result.Status) {
        'Latest' {
            Write-HostTimestamp ('{0,-15}: v{1} is the latest release' -f 'Version check', $Current) -ForegroundColor Green
        }
        'Outdated' {
            Write-HostTimestamp ('{0,-15}: v{1} is available, and this is v{2}. Download it from {3}' -f 'Version check', $Result.Latest, $Current, $Result.Url) -ForegroundColor Yellow
        }
        'Newer' {
            Write-HostTimestamp ('{0,-15}: v{1} is newer than the latest release, v{2}' -f 'Version check', $Current, $Result.Latest)
        }
        'Skipped' {
            Write-CMTraceLog -Message 'Version check: skipped (-SkipVersionCheck).'
        }
        default {
            Write-CMTraceLog -Message "Version check: could not find out whether v$Current is the latest release ($($Result.Reason)). See $($script:LatestReleaseUrl)."
        }
    }
}
#endregion
