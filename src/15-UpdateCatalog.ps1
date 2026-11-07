#region Microsoft Update Catalog helpers
# The Microsoft Update Catalog (catalog.update.microsoft.com) has no public API, so these functions use
# the same technique the community relies on: fetch the search results page and parse it, then POST to the
# download dialog to obtain the direct package URL. Every resolved URL is validated to be a Microsoft host
# before it is downloaded.

# Searches the catalog and returns matching updates as PSCustomObjects (Guid, Title, LastUpdated, SizeMB).
function Search-UpdateCatalog {
    param([Parameter(Mandatory)][string]$Query)

    $EncodedQuery = [System.Uri]::EscapeDataString($Query)
    $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$EncodedQuery"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
        $Response = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not query the Microsoft Update Catalog: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    $Html = $Response.Content
    $Results = New-Object System.Collections.Generic.List[object]

    # The catalog renders each result as an anchor  <a id='<GUID>_link' ...>Title</a>  (note the SINGLE
    # quotes), and its column values live in separate cells whose ids follow the pattern
    # "<GUID>_C<col>_R<row>" - C1=Title, C3=Classification, C4=Last Updated, C6=Size. We find every result
    # by its "_link" anchor, then read that GUID's date/size/classification cells by id.
    $LinkMatches = [regex]::Matches($Html, "(?s)id=['`"]([0-9a-fA-F-]{36})_link['`"][^>]*>(.*?)</a>")
    foreach ($Link in $LinkMatches) {
        $Guid = $Link.Groups[1].Value
        $Title = [System.Net.WebUtility]::HtmlDecode((([regex]::Replace($Link.Groups[2].Value, '<[^>]+>', ' ')).Trim() -replace '\s+', ' '))
        $EscGuid = [regex]::Escape($Guid)

        # Helper to read the visible text of a specific column cell for this GUID.
        $GetCell = {
            param([int]$Col)
            $M = [regex]::Match($Html, "(?s)id=`"${EscGuid}_C${Col}_R\d+`"[^>]*>(.*?)</td>")
            if ($M.Success) {
                return [System.Net.WebUtility]::HtmlDecode((([regex]::Replace($M.Groups[1].Value, '<[^>]+>', ' ')).Trim() -replace '\s+', ' '))
            }
            return $null
        }

        $Classification = & $GetCell 3
        $DateText = & $GetCell 4
        $SizeText = & $GetCell 6

        $LastUpdated = $null
        if ($DateText -and $DateText -match '(\d{1,2}/\d{1,2}/\d{4})') {
            # The catalog always renders this column as US M/d/yyyy, so parsing it under the caller's
            # culture (e.g. en-GB reads d/M/yyyy) silently swaps day and month for two-digit days.
            $Parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($Matches[1], 'M/d/yyyy', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
                $LastUpdated = $Parsed
            }
        }

        $SizeMB = $null
        if ($SizeText -and $SizeText -match '([\d.,]+)\s*(KB|MB|GB)') {
            $Value = [double]($Matches[1] -replace ',', '')
            $SizeMB = switch ($Matches[2]) {
                'KB' { [math]::Round($Value / 1024, 2) }
                'MB' { $Value }
                'GB' { [math]::Round($Value * 1024, 2) }
            }
        }

        $Results.Add([PSCustomObject]@{
            Guid           = $Guid
            Title          = $Title
            Classification = $Classification
            LastUpdated    = $LastUpdated
            SizeMB         = $SizeMB
        })
    }

    return $Results
}

# Resolves the direct download URL(s) for a catalog update GUID by POSTing to the download dialog.
function Get-UpdateCatalogDownloadUrl {
    param([Parameter(Mandatory)][string]$Guid)

    $DialogUrl = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
    $Body = "updateIDs=[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$Guid`",`"updateID`":`"$Guid`"}]&updateIDsBlockedForImport=&wsusApiPresent=&contentImport=&sqlserverImport=&updateID=$Guid"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
        $Response = Invoke-WebRequest -Uri $DialogUrl -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not resolve the download link for $Guid : $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    # The dialog echoes the direct file URLs in JavaScript: downloadInformation[0].files[0].url = '...';
    $Urls = [regex]::Matches($Response.Content, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ } |
        Select-Object -Unique

    return @($Urls)
}

# Looks up which OS build(s) a KB article delivers, from the title of its Microsoft support page - e.g.
# "July 8, 2025-KB5062553 (OS Builds 26100.4652 and 26200.4652)". The Update Catalog itself never states
# the resulting build, and this is the only cheap way to know it BEFORE downloading a multi-GB package.
# Returns a hashtable of build -> UBR, or $null if the page could not be read or parsed.
function Get-KbTargetBuilds {
    param([Parameter(Mandatory)][string]$KbNumber)

    try {
        $Response = Invoke-WebRequest -Uri "https://support.microsoft.com/help/$KbNumber" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    }
    catch { return $null }

    $Title = if ("$($Response.Content)" -match '(?is)<title>(.*?)</title>') { $Matches[1] } else { '' }
    if ($Title -notmatch '(?i)OS Build') { return $null }

    $Builds = @{}
    foreach ($M in [regex]::Matches($Title, '\b(\d{5})\.(\d{1,5})\b')) {
        $Builds[[int]$M.Groups[1].Value] = [int]$M.Groups[2].Value
    }
    if ($Builds.Count -eq 0) { return $null }
    return $Builds
}

function Test-IsHotpatchBaseline {
    param([Parameter(Mandatory)][object]$Entry)
    # Microsoft's planned baseline months, for when its calendar cannot be read. The month in the title wins,
    # because a re-released package gets a newer LastUpdated.
    if ("$($Entry.Title)" -match '^\d{4}-(\d{2})\b') { $Month = [int]$Matches[1] }
    elseif ($Entry.LastUpdated) { $Month = ([datetime]$Entry.LastUpdated).Month }
    else { return $false }
    return (@(1, 4, 7, 10) -contains $Month)
}

# Reads the newest baseline that has a KB out of the hotpatch calendar's HTML. Later months are listed before
# they ship with an empty KB cell, so those rows drop out on their own.
function ConvertFrom-HotpatchCalendar {
    param([string]$Html)

    $Baselines = foreach ($Row in [regex]::Matches("$Html", '(?is)<tr\b.*?</tr>')) {
        $Cells = @([regex]::Matches($Row.Value, '(?is)<td\b[^>]*>(.*?)</td>') | ForEach-Object { ($_.Groups[1].Value -replace '<[^>]+>', '').Trim() })
        if (-not ($Cells | Where-Object { $_ -match '(?i)^baseline' })) { continue }
        $Release = $Cells | Where-Object { $_ -match '^20\d{2}\.\d{2}\b' } | Select-Object -First 1
        $Kb = $Cells | Where-Object { $_ -match '(?i)^KB\d{6,}$' } | Select-Object -First 1
        if ($Release -and $Kb) {
            [pscustomobject]@{ Release = $Release.Substring(0, 7); Kb = $Kb.Substring(2) }
        }
    }
    return ($Baselines | Sort-Object -Property Release -Descending | Select-Object -First 1)
}

# Asks Microsoft's hotpatch calendar for the latest baseline, because the Update Catalog does not mark
# baselines and Microsoft adds extra ones outside the planned months. Windows 11 24H2 and later share these
# KBs, so one page serves them all. The answer is kept for the run, including a failure, so the warning
# appears once. Returns $null when the page cannot be read or has stopped being kept up to date.
function Get-HotpatchBaselineKb {
    param([string]$Url = 'https://support.microsoft.com/en-us/servicing/os/hotpatch/windows-11/2025/release-notes-for-hotpatch-on-windows-11-enterprise-version-25h2')

    if ($script:HotpatchBaselineChecked) { return $script:HotpatchBaseline }
    $script:HotpatchBaselineChecked = $true
    $script:HotpatchBaseline = $null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Baseline = ConvertFrom-HotpatchCalendar -Html (Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop).Content
    }
    catch {
        Write-HostTimestamp "  Could not read Microsoft's hotpatch calendar: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    if (-not $Baseline) {
        Write-HostTimestamp "  Microsoft's hotpatch calendar was read, but no baseline could be found in it." -ForegroundColor Yellow
        return $null
    }

    # Baselines are never more than three months apart, so anything older means the page is no longer current.
    $Now = Get-Date
    $AgeInMonths = (($Now.Year * 12) + $Now.Month) - (([int]$Baseline.Release.Substring(0, 4) * 12) + [int]$Baseline.Release.Substring(5, 2))
    if ($AgeInMonths -gt 4) {
        Write-HostTimestamp "  The newest baseline in Microsoft's hotpatch calendar is $($Baseline.Release), which is too old to trust." -ForegroundColor Yellow
        return $null
    }

    Write-HostTimestamp "  Microsoft's hotpatch calendar names KB$($Baseline.Kb) ($($Baseline.Release)) as the latest baseline." -ForegroundColor DarkGray
    $script:HotpatchBaseline = $Baseline
    return $Baseline
}

# Narrows catalog results to the hotpatch baseline. The calendar's KB is searched for directly, since the
# general query only returns 25 rows. Without one, the newest security update from a planned month is the best
# guess. "Security Updates" keeps out-of-band releases out, and the warning says the choice is unconfirmed.
function Select-HotpatchBaselineEntry {
    param(
        [Parameter(Mandatory)][string]$Query,
        [object[]]$Candidates,
        [string]$TitleInclude,
        [string]$TitleExclude
    )

    $Baseline = Get-HotpatchBaselineKb
    if ($Baseline) {
        $Exact = @(Search-UpdateCatalog -Query "$Query KB$($Baseline.Kb)" | Where-Object { $_.Title -match "(?i)\bKB$($Baseline.Kb)\b" })
        if ($TitleInclude) { $Exact = @($Exact | Where-Object { $_.Title -match $TitleInclude }) }
        if ($TitleExclude) { $Exact = @($Exact | Where-Object { $_.Title -notmatch $TitleExclude }) }
        if ($Exact.Count -gt 0) { return $Exact }
        Write-HostTimestamp "  The catalog has no KB$($Baseline.Kb) for this release." -ForegroundColor Yellow
    }

    Write-HostTimestamp '  WARNING: the baseline could not be confirmed, so the newest security update from January, April, July or October is being used. A baseline Microsoft added outside those months would be missed.' -ForegroundColor Yellow
    return @($Candidates | Where-Object { $_.Classification -eq 'Security Updates' -and (Test-IsHotpatchBaseline -Entry $_) })
}

# The newest cumulative update DISM can integrate into an offline image of this build, or $null for no limit.
# From November 2025 the Windows 10 2004-22H2 updates (builds 19041-19045, which includes LTSC 2021) carry an
# Extended Security Updates step that refuses an offline image: it logs "ESU: Offline is not supported" and DISM
# then calls the image unserviceable. October 2025's is the last one that goes in, so the catalog is capped there
# and the newer updates install once Windows is running. Any LCU lookup that must agree with the download step
# (the build stamp, the recovery ISO's Safe OS bound) applies the same cap.
function Get-OfflineLcuCutoff {
    param([int]$Build)
    if ($Build -ge 19041 -and $Build -le 19045) { return [datetime]::new(2025, 10, 31) }
    return $null
}

# A catalog search returns only its 25 newest matches, so one bounded by an older date can come back with
# nothing old enough. When even the oldest result is newer than the bound, the search is asked again with the
# bound's month in front ("2025-10 Cumulative Update for ..."), which returns the months around it, and the two
# result sets are merged for the caller's -NotAfter filter to choose from.
function Search-UpdateCatalogUpTo {
    param(
        [Parameter(Mandatory)][string]$Query,
        $NotAfter
    )
    $Results = @(Search-UpdateCatalog -Query $Query)
    if (-not $NotAfter -or $Results.Count -eq 0) { return $Results }
    $Dated = @($Results | Where-Object { $_.LastUpdated } | ForEach-Object { [datetime]$_.LastUpdated })
    if ($Dated.Count -gt 0 -and ($Dated | Measure-Object -Minimum).Minimum -le [datetime]$NotAfter) { return $Results }
    $Month = ([datetime]$NotAfter).ToString('yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)
    $Older = @(Search-UpdateCatalog -Query "$Month $Query")
    $Seen = @{}
    return @(@($Results) + @($Older) | Where-Object { $Key = "$($_.Guid)|$($_.Title)"; if ($Seen.ContainsKey($Key)) { $false } else { $Seen[$Key] = $true; $true } })
}

# Titles a cumulative update search turns up that are not the LCU for this media: .NET and Dynamic Updates
# (including the "Dynamic Cumulative Update" twin of each LCU), and for client media the Server LCU of the same
# version, which the "21H2" query returns too and which can carry a later date than the Windows 10 one.
function Get-LcuTitleExclude {
    if ($script:EffectiveServer) { return '(?i)\.net|dynamic (cumulative )?update' }
    return '(?i)\.net|dynamic (cumulative )?update|server operating system'
}

# Which Dynamic Update a catalog entry is: 'SafeOS', 'Setup' or $null. Windows 11 says so in the title, but Windows
# 10 and Server title both kinds plain "Dynamic Update", and size cannot tell them apart (in July 2025 the Windows 10
# Safe OS update was the smaller of the two). The KB's support page title always names the kind, so that decides,
# once per KB per run.
function Get-DynamicUpdateKind {
    param($Entry)
    $Title = "$($Entry.Title)"
    if ($Title -match '(?i)safe os dynamic update') { return 'SafeOS' }
    if ($Title -match '(?i)setup dynamic update') { return 'Setup' }
    if ($Title -notmatch '(?i)\bdynamic update\b') { return $null }
    if ($Title -notmatch '(?i)KB(\d{6,})') { return $null }
    $Kb = $Matches[1]
    if (-not $script:DynamicUpdateKindCache) { $script:DynamicUpdateKindCache = @{} }
    if ($script:DynamicUpdateKindCache.ContainsKey($Kb)) { return $script:DynamicUpdateKindCache[$Kb] }
    $Kind = $null
    try {
        $Page = Invoke-WebRequest -Uri "https://support.microsoft.com/help/$Kb" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        if ("$($Page.Content)" -match '(?is)<title>(.*?)</title>') {
            $PageTitle = $Matches[1]
            if ($PageTitle -match '(?i)safe os dynamic update') { $Kind = 'SafeOS' }
            elseif ($PageTitle -match '(?i)setup dynamic update') { $Kind = 'Setup' }
        }
    }
    catch { Write-HostTimestamp "  Could not read the KB$Kb support page to tell which Dynamic Update it is, so it is passed over." -ForegroundColor DarkYellow }
    $script:DynamicUpdateKindCache[$Kb] = $Kind
    return $Kind
}

# The newest of a set of catalog entries that is the wanted kind of Dynamic Update. Walks them newest first and
# stops at the first match, so at most a few support pages are read.
function Select-DynamicUpdateEntry {
    param(
        [object[]]$Candidates,
        [Parameter(Mandatory)][ValidateSet('SafeOS', 'Setup')][string]$Kind
    )
    $Sorted = @($Candidates | Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.SizeMB }; Descending = $true })
    foreach ($Entry in $Sorted) {
        if ((Get-DynamicUpdateKind -Entry $Entry) -eq $Kind) { return $Entry }
    }
    return $null
}

# The catalog search for a Dynamic Update of this media: the query, and a title pattern that holds the result to
# this product and architecture. The search matches words loosely, so a Windows 10 22H2 query also returns the
# Windows 11 22H2 and Server 21H2 Dynamic Updates; titles write "Windows 11, version 24H2" where the product says
# "Windows 11 Version 24H2", so spaces in the product match a comma too.
function Get-DynamicUpdateSearch {
    param(
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$CatalogArch
    )
    $ProductPattern = (($Product -split '\s+') | ForEach-Object { [regex]::Escape($_) }) -join '[\s,]+'
    return @{
        Query        = "Dynamic Update $Product $CatalogArch"
        TitleInclude = "(?i)dynamic update for $ProductPattern\b.*\b$([regex]::Escape($CatalogArch))-based"
    }
}

# Finds the newest cumulative update in the catalog for a given search query, downloads it to the download
# folder, and returns the local .msu path (or $null on failure). Preview releases are left out unless
# -AllowPreview says otherwise.
function Get-LatestCatalogPackage {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$DownloadDir,
        [string]$TitleInclude,   # regex the title MUST match (e.g. cumulative update wording)
        [string]$TitleExclude,   # regex the title must NOT match (e.g. ".net", "dynamic")
        [switch]$AllowPreview,
        [int]$CurrentBuild,      # OS build already in the image - set to enable the up-to-date check
        [int]$CurrentUbr,        # UBR from the WIM header, trusted unless -VerifyPatchLevel is set
        [string]$VerifyWimPath,  # WIM to read the real UBR out of when the header is not trusted
        [switch]$VerifyPatchLevel,
        [switch]$Reapply,        # download and return the package even when the image already has it
        [ref]$AlreadyCurrent,    # receives the image's confirmed build when the update is not needed
        [switch]$BaselineOnly,
        [datetime]$NotAfter,     # optional upper bound - packages released after this date are excluded
        [ref]$SelectedDate,      # receives the selected package's LastUpdated, for bounding a later query by it
        [ValidateSet('SafeOS', 'Setup')][string]$DynamicUpdateKind  # keep only this kind of Dynamic Update
    )

    Write-HostTimestamp "  Searching the Microsoft Update Catalog for: $Query"
    $Results = Search-UpdateCatalogUpTo -Query $Query -NotAfter $(if ($PSBoundParameters.ContainsKey('NotAfter')) { $NotAfter })
    if (-not $Results -or $Results.Count -eq 0) {
        Write-HostTimestamp '  No catalog results were returned for that query.' -ForegroundColor Yellow
        return $null
    }
    Write-HostTimestamp "  Found $($Results.Count) catalog result(s), selecting the best match..."

    # Narrow to the packages we actually want, then take the newest by date (largest as a tie-break).
    $Filtered = $Results
    if ($TitleInclude) { $Filtered = $Filtered | Where-Object { $_.Title -match $TitleInclude } }
    if ($TitleExclude) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch $TitleExclude } }
    if (-not $AllowPreview) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch '(?i)preview' } }
    if ($PSBoundParameters.ContainsKey('NotAfter')) {
        # e.g. keeps the Setup Dynamic Update no newer than the LCU it ships alongside.
        $Filtered = $Filtered | Where-Object { $_.LastUpdated -and ([datetime]$_.LastUpdated) -le $NotAfter }
    }
    if ($DynamicUpdateKind -and $Filtered) { $Filtered = Select-DynamicUpdateEntry -Candidates @($Filtered) -Kind $DynamicUpdateKind }
    if (-not $Filtered) {
        Write-HostTimestamp '  No catalog results matched the expected update type after filtering.' -ForegroundColor Yellow
        return $null
    }
    if ($BaselineOnly) {
        $Filtered = Select-HotpatchBaselineEntry -Query $Query -Candidates @($Filtered) -TitleInclude $TitleInclude -TitleExclude $TitleExclude
        if (-not $Filtered) {
            Write-HostTimestamp '  -BaselineOnly: the catalog results hold no baseline cumulative update.' -ForegroundColor Yellow
            $script:LcuSkippedBaselineOnly = $true
            return $null
        }
    }

    $Selected = $Filtered |
        Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.SizeMB }; Descending = $true } |
        Select-Object -First 1
    if (-not $Selected) {
        Write-HostTimestamp '  Could not select a suitable update from the catalog results.' -ForegroundColor Yellow
        return $null
    }

    Write-HostTimestamp "  Selected: $($Selected.Title)$(if ($Selected.LastUpdated) { " (released $(Get-FriendlyDate -Date $Selected.LastUpdated))" })" -ForegroundColor Green
    if ($SelectedDate) { $SelectedDate.Value = $Selected.LastUpdated }

    $PrimaryKb = if ($Selected.Title -match '(?i)KB(\d{6,})') { $Matches[1] } else { $null }

    # If the image is already at (or past) the build this KB delivers, there is nothing to gain from
    # downloading and integrating it - that is the hour-long part of the run.
    if ($CurrentBuild -gt 0 -and $PrimaryKb) {
        # Newer catalog titles carry the build, e.g. "(KB5129195) (26300.9457)", and are there on release day
        # when the support page often is not yet.
        $Targets = @{}
        foreach ($M in [regex]::Matches("$($Selected.Title)", '\((\d{5})\.(\d{1,5})\)')) {
            $Targets[[int]$M.Groups[1].Value] = [int]$M.Groups[2].Value
        }
        if (-not $Targets.ContainsKey($CurrentBuild)) { $Targets = Get-KbTargetBuilds -KbNumber $PrimaryKb }
        $TargetUbr = if ($Targets -and $Targets.ContainsKey($CurrentBuild)) { [int]$Targets[$CurrentBuild] } else { 0 }
        if ($TargetUbr -eq 0) {
            Write-HostTimestamp "  Neither the catalog title nor the KB$PrimaryKb support page says which $CurrentBuild build it delivers, so it cannot be checked against the image and will be integrated." -ForegroundColor Yellow
        }
        # A hive read already paid for this run (an unrecognised release name) is used for free.
        $AlreadyRead = $VerifyWimPath -and $script:WimBuildCache -and $script:WimBuildCache.ContainsKey("$VerifyWimPath|1")
        $CurrentAt = $null
        $HeaderTrusted = $false
        if ($TargetUbr -gt 0 -and $VerifyWimPath -and ($VerifyPatchLevel -or $AlreadyRead)) {
            Write-HostTimestamp "  The media header says $CurrentBuild.$CurrentUbr and KB$PrimaryKb delivers $CurrentBuild.$TargetUbr. Reading the image's real patch level before deciding..."
            $Confirmed = Get-WimBuildViaMount -WimPath $VerifyWimPath
            $ConfirmedUbr = if ("$Confirmed" -match '\b\d+\.\d+\.\d+\.(\d+)') { [int]$Matches[1] } else { 0 }
            if ($ConfirmedUbr -ge $TargetUbr) { $CurrentAt = $Confirmed }
            else { Write-HostTimestamp "  The image is at $(if ($Confirmed) { $Confirmed } else { 'an unknown build' }), so KB$PrimaryKb is needed." -ForegroundColor Yellow }
        }
        elseif ($TargetUbr -gt 0 -and $CurrentUbr -ge $TargetUbr) {
            $CurrentAt = "10.0.$CurrentBuild.$CurrentUbr"
            $HeaderTrusted = $true
        }
        elseif ($TargetUbr -gt 0) {
            Write-HostTimestamp "  The media header says $CurrentBuild.$CurrentUbr and KB$PrimaryKb delivers $CurrentBuild.$TargetUbr, so the update will be integrated."
            Write-HostTimestamp '  If this media is already patched and the header is out of date, -VerifyPatchLevel reads the real level and can skip it.' -ForegroundColor DarkGray
        }

        if ($CurrentAt) {
            if (-not $Reapply) {
                Write-HostTimestamp "  The image is already at $CurrentAt and KB$PrimaryKb delivers $CurrentBuild.$TargetUbr, so it adds nothing - skipping the download and the integration." -ForegroundColor Green
                if ($HeaderTrusted) { Write-HostTimestamp '  The header was trusted without mounting the image. Use -VerifyPatchLevel to confirm it against the registry.' -ForegroundColor DarkGray }
                if ($AlreadyCurrent) { $AlreadyCurrent.Value = $CurrentAt }
                return $null
            }
            Write-HostTimestamp "  The image is already at $CurrentAt, which includes KB$PrimaryKb, but -ReapplyUpdates was specified, so it is integrated anyway." -ForegroundColor Yellow
            $script:LcuReapplied = $true
        }
    }

    # A single catalog entry can resolve to MULTIPLE .msu files. For Windows 11 24H2/25H2, Microsoft uses
    # "checkpoint cumulative updates": the latest LCU download also includes one or more baseline/checkpoint
    # packages that MUST be integrated first. So download every file the dialog returns and order them so
    # the checkpoint/baseline packages come before the main LCU (identified by the KB in the title).
    $Urls = @(Get-UpdateCatalogDownloadUrl -Guid $Selected.Guid)
    $FileUrls = @($Urls | Where-Object { $_ -match '\.(msu|cab)(\?|$)' })
    if (-not $FileUrls) { $FileUrls = $Urls }
    if (-not $FileUrls -or $FileUrls.Count -eq 0) {
        Write-HostTimestamp '  The catalog did not return a download URL for the selected update.' -ForegroundColor Yellow
        return $null
    }

    # Extracts the numeric KB from a URL/filename for ordering (checkpoints ascending, LCU last).
    $GetKb = { param($Text) if ($Text -match '(?i)kb(\d{6,})') { [int]$Matches[1] } else { 0 } }

    $Downloaded = New-Object System.Collections.Generic.List[object]
    foreach ($Url in $FileUrls) {
        if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
            $BadHost = try { ([Uri]$Url).Host } catch { '(unparseable)' }
            Write-HostTimestamp "  Skipping a download URL that is not an official Microsoft host (host: $BadHost)." -ForegroundColor Yellow
            continue
        }

        $FileName = $null
        try { $FileName = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath) } catch { }
        if (-not $FileName) { $FileName = "$($Selected.Guid)_$(& $GetKb $Url).msu" }
        $Destination = Join-Path -Path $DownloadDir -ChildPath $FileName

        if ((Test-Path -LiteralPath $Destination) -and -not (Test-UpdatePackageFile -Path $Destination)) {
            Write-HostTimestamp "  The existing copy of $FileName failed its integrity check, so it is being downloaded again." -ForegroundColor Yellow
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $Destination) {
            Write-HostTimestamp "  Already downloaded - reusing: $FileName" -ForegroundColor DarkGray
        }
        else {
            Write-HostTimestamp "  Downloading $FileName ..."
            if (-not (Get-FileDownload -Url $Url -Destination $Destination)) {
                Write-HostTimestamp "  Failed to download $FileName." -ForegroundColor Red
                return $null
            }
            if (-not (Test-UpdatePackageFile -Path $Destination)) {
                Write-HostTimestamp "  The downloaded $FileName failed its integrity check, so it was discarded." -ForegroundColor Red
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                return $null
            }
            Write-HostTimestamp "    Downloaded ($([math]::Round((Get-Item -LiteralPath $Destination).Length / 1MB, 1)) MB)." -ForegroundColor Green
        }

        $Kb = & $GetKb $FileName
        $IsPrimary = ($PrimaryKb -and $FileName -match "(?i)kb$PrimaryKb")
        $Downloaded.Add([PSCustomObject]@{ Path = $Destination; Kb = $Kb; IsPrimary = [bool]$IsPrimary })
    }

    if ($Downloaded.Count -eq 0) {
        Write-HostTimestamp '  No update packages could be downloaded.' -ForegroundColor Red
        return $null
    }

    # Order: non-primary (checkpoints/SSU) first (oldest KB first), then the primary LCU last. If we could
    # not identify the primary KB, fall back to plain KB-ascending order.
    $Ordered = @(
        ($Downloaded | Where-Object { -not $_.IsPrimary } | Sort-Object Kb)
        ($Downloaded | Where-Object { $_.IsPrimary } | Sort-Object Kb)
    )
    if ($Downloaded.Count -gt 1) {
        Write-HostTimestamp "  This update includes $($Downloaded.Count) package(s), which will be integrated in this order:"
        $Ordered | ForEach-Object { Write-HostTimestamp "    - $(Split-Path -Leaf $_.Path)$(if ($_.IsPrimary) { ' (main cumulative update)' })" }
    }

    return @($Ordered | ForEach-Object { $_.Path })
}

#endregion

