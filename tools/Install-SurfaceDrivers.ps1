<#
.SYNOPSIS
    Downloads Microsoft Surface driver MSI packages, organised into one folder per model, and installs
    the ones for the machine it runs on unless -DownloadOnly is given.

.DESCRIPTION
    The script discovers all available Surface driver packages by scraping the Microsoft
    Surface drivers support page, then resolves each link to a direct MSI download URL. It downloads
    each package to:

        <OutputPath>\<WMI Model Name>\<filename>.msi

    Folder names are the exact strings returned by (Get-CimInstance Win32_ComputerSystem).Model on
    the target hardware, so a later step can match a machine to its folder with a substring match
    against that value.

    If a file is already present it is skipped, so re-runs are safe and incremental. BITS is used
    when available, with a fallback to Invoke-WebRequest.

.PARAMETER OutputPath
    Root folder to write driver packages into. Each model gets a subfolder named after its exact
    WMI model string. Defaults to .\Drivers in the current directory.

.PARAMETER WindowsVersion
    Windows version the drivers must target: 10 or 11. Defaults to 11.

.PARAMETER Models
    One or more model names to download, matching entries in the internal catalog. Omit to download
    all models that have a driver for the requested Windows version.

.PARAMETER ListModels
    List available models in the catalog and exit without downloading anything.

.PARAMETER Quiet
    Suppress detail lines; show only headings and the final summary.

.PARAMETER DownloadOnly
    Download driver packages without installing anything, for staging on deployment media. Downloads every catalogued model, or only -Models if given, into -OutputPath.

.PARAMETER ProxyUrl
    Proxy server URL to route Surface support page scraping and driver package downloads, including
    their BITS transfers, through, for example http://proxy.example.com:8080. Omit to use the
    machine's default network configuration.

.EXAMPLE
    .\tools\Install-SurfaceDrivers.ps1
    Detects this device's Surface model, downloads its driver package, and installs it via msiexec. Must be run elevated. This is the default behavior.

.EXAMPLE
    .\tools\Install-SurfaceDrivers.ps1 -DownloadOnly
    Downloads Windows 11 driver packages for every catalogued model into .\Drivers\, without installing anything.

.EXAMPLE
    .\tools\Install-SurfaceDrivers.ps1 -DownloadOnly -Models 'Surface Pro 9', 'Surface Laptop 5' -OutputPath D:\DriverStaging
    Downloads only the two named models to D:\DriverStaging, without installing anything.

.EXAMPLE
    .\tools\Install-SurfaceDrivers.ps1 -ListModels
    Prints the catalog table and exits without downloading anything.

.EXAMPLE
    .\tools\Install-SurfaceDrivers.ps1 -DownloadOnly -WindowsVersion 10 -Quiet
    Downloads Windows 10 packages for all supported models, showing only headings and the summary.

.EXAMPLE
    .\tools\Install-SurfaceDrivers.ps1 -ProxyUrl 'http://proxy.example.com:8080'
    Runs the default behavior with all outbound traffic, including BITS transfers, routed through the
    given proxy.

.NOTES
    Folder names match the exact string returned by (Get-CimInstance Win32_ComputerSystem).Model on
    the target hardware.

    To stage packages on boot media, place the Drivers\ output under $OEM$\$1\. Windows Setup copies
    $OEM$\$1\ to C:\ before the specialize pass runs, so C:\Drivers\ is populated for anything that
    installs from it during or after setup.

    Model names and download links are discovered at runtime from
    https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface
    so the catalog is always current. No hardcoded ID table needs updating.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Root folder to write driver packages into. Each model gets a subfolder named after its exact WMI model string. Defaults to .\Drivers in the current directory.')]
    [string]$OutputPath = '.\Drivers',

    [Parameter(HelpMessage = 'Windows version the drivers must target: 10 or 11. Defaults to 11.')]
    [ValidateSet('10', '11')]
    [string]$WindowsVersion = '11',

    [Parameter(HelpMessage = 'One or more model names to download, matching entries in the internal catalog. Omit to download all models that have a driver for the requested Windows version.')]
    [string[]]$Models,

    [Parameter(HelpMessage = 'List available models in the catalog and exit without downloading anything.')]
    [switch]$ListModels,

    [Parameter(HelpMessage = 'Download driver packages without installing anything, for staging on deployment media. Downloads every catalogued model, or only -Models if given, into -OutputPath.')]
    [switch]$DownloadOnly,

    [Parameter(HelpMessage = 'Suppress detail lines; show only headings and the final summary.')]
    [switch]$Quiet,

    [Parameter(HelpMessage = "Proxy server URL to route Surface support page scraping and driver package downloads, including their BITS transfers, through, for example http://proxy.example.com:8080. Omit to use the machine's default network configuration.")]
    [ValidateScript({
        $ParsedUri = $null
        if (-not [Uri]::TryCreate($_, [UriKind]::Absolute, [ref]$ParsedUri)) {
            throw "The value '$_' is not a valid absolute URI."
        }
        $true
    })]
    [string]$ProxyUrl
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# .NET Framework caps concurrent connections per host at 2 by default, which would bottleneck the parallel fetches below
[Net.ServicePointManager]::DefaultConnectionLimit = 16
# support.microsoft.com's WAF rejects PowerShell's default User-Agent as bot traffic, so every request wears a browser one
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

# Carries the anonymous session cookie the first support.microsoft.com request receives into every
# later call, so details.aspx fetches aren't treated as sessionless and bounced to sign-in.
$script:WebSession = $null

# Splatted onto every Invoke-WebRequest call so -ProxyUrl, when given, is the only place proxy routing is decided
$script:WebRequestProxyArgs = @{}
if ($ProxyUrl) {
    $script:WebRequestProxyArgs['Proxy'] = $ProxyUrl
}

# Lets the per-model loop tell an unavailable catalog listing (404, JSON error, or no files) apart from a transient resolution failure.
$script:LastResolveFailureWasRetired = $false

# Tracks whether any installed package needs a reboot (msiexec exit 3010), so the script can surface that in its own exit code.
$script:RebootRequired = $false

function Get-CatalogFromSupportPage {
    param([string]$WindowsVersion)

    $MainUrl = 'https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface'
    $FamilyBase = 'https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface-'
    $Catalog = [ordered]@{}

    # Specialize can start before DHCP settles, so keep retrying for about three minutes.
    $MainResponse = $null
    for ($Attempt = 1; $Attempt -le 18 -and -not $MainResponse; $Attempt++) {
        try {
            [void]($MainResponse = Invoke-WebRequest -Uri $MainUrl -UseBasicParsing -TimeoutSec 30 -SessionVariable NewWebSession -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
            $script:WebSession = $NewWebSession
        }
        catch {
            Write-Host "  Attempt $Attempt of 18 to fetch Surface support page failed - $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        if (-not $MainResponse) {
            Start-Sleep -Seconds 10
        }
    }
    if (-not $MainResponse) {
        Write-Host 'Failed to fetch Surface support page after 18 attempts.' -ForegroundColor Red
        return $Catalog
    }

    $MainText = $null
    $NextMatches = [regex]::Matches($MainResponse.Content, '<script id="__NEXT_DATA__"[^>]*>([\s\S]+?)</script>')
    if ($NextMatches.Count -gt 0) {
        $MainText = $NextMatches[0].Groups[1].Value
    }
    if (-not $MainText) {
        $MainText = $MainResponse.Content
    }
    $MainText = $MainText -replace '\\/', '/'

    # Family sub-pages carry the full path prefix plus a distinct slug
    $SlugMatches = [regex]::Matches($MainText, 'download-drivers-and-firmware-for-surface-([a-z][a-z0-9-]*)')
    $FamilyUrls = New-Object System.Collections.ArrayList
    $SeenSlugs = @{}
    foreach ($SlugMatch in $SlugMatches) {
        $FamilyUrl = $FamilyBase + $SlugMatch.Groups[1].Value
        if (-not $SeenSlugs.ContainsKey($FamilyUrl)) {
            [void]$FamilyUrls.Add($FamilyUrl)
            $SeenSlugs[$FamilyUrl] = $true
        }
    }

    # Guarantee well-known families are visited even if absent from the __NEXT_DATA__ blob
    foreach ($KnownSlug in @('book', 'go', 'hub', 'laptop', 'laptop-go', 'pro', 'studio')) {
        $FamilyUrl = $FamilyBase + $KnownSlug
        if (-not $SeenSlugs.ContainsKey($FamilyUrl)) {
            [void]$FamilyUrls.Add($FamilyUrl)
            $SeenSlugs[$FamilyUrl] = $true
        }
    }

    if ($FamilyUrls.Count -eq 0) {
        Write-Host '  Warning: no family sub-pages found on the main support page.' -ForegroundColor Yellow
        return $Catalog
    }

    # Fetch each level of sub-pages concurrently; parsing and $Catalog/$Visited writes stay single-threaded here
    $Visited = @{}
    $CurrentLevel = New-Object System.Collections.ArrayList
    foreach ($FamilyUrl in $FamilyUrls) {
        [void]$CurrentLevel.Add($FamilyUrl)
        $Visited[$FamilyUrl] = $true
    }
    $CurrentLevel = @($CurrentLevel)

    while ($CurrentLevel.Count -gt 0) {
        Write-Host "  Scanning level with $($CurrentLevel.Count) page(s)..." -ForegroundColor DarkGray
        $LevelResults = Invoke-ParallelWebRequest -Uris $CurrentLevel -WebSession $script:WebSession -UserAgent $script:UserAgent -ProxyUrl $ProxyUrl
        $NextLevel = New-Object System.Collections.ArrayList

        foreach ($r in $LevelResults) {
            if (-not $r.Success) {
                Write-Host "  Warning: failed to fetch '$($r.Uri)' - $($r.Error)" -ForegroundColor Yellow
                continue
            }

            $PageText = $r.Content -replace '\\/', '/'

            # Discover model sub-pages linked from this family page and queue any not yet seen
            $SubSlugMatches = [regex]::Matches($PageText, 'download-drivers-and-firmware-for-surface-([a-z][a-z0-9-]*)')
            foreach ($SubSlugMatch in $SubSlugMatches) {
                $SubUrl = $FamilyBase + $SubSlugMatch.Groups[1].Value
                if (-not $Visited.ContainsKey($SubUrl) -and -not $SeenSlugs.ContainsKey($SubUrl)) {
                    [void]$NextLevel.Add($SubUrl)
                    $Visited[$SubUrl] = $true
                    $SeenSlugs[$SubUrl] = $true
                }
            }

            # Table rows pair model name (first td) with download link href (second td)
            $RowPattern = '<tr>\s*<td>\s*([^<>]{1,100}?)\s*</td>\s*<td>[^<]*<a[^>]+href="(https://www\.microsoft\.com/(?:[a-z-]+/)?download/details\.aspx\?id=\d+)"'
            $RowMatches = [regex]::Matches($PageText, $RowPattern)
            foreach ($RowMatch in $RowMatches) {
                $ModelName = $RowMatch.Groups[1].Value.Trim()
                $DownloadUrl = $RowMatch.Groups[2].Value
                if ($ModelName -and -not $Catalog.Contains($ModelName)) {
                    $Catalog[$ModelName] = $DownloadUrl
                }
            }
        }

        $CurrentLevel = @($NextLevel)
    }

    return $Catalog
}

function Invoke-ParallelWebRequest {
    param(
        [string[]]$Uris,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [int]$TimeoutSec = 30,
        [int]$MaxConcurrency = 8,
        [string]$UserAgent = $script:UserAgent,
        [string]$ProxyUrl
    )

    $Pool = [runspacefactory]::CreateRunspacePool(1, $MaxConcurrency)
    $Pool.Open()

    $ScriptBlock = {
        param($Uri, $WebSession, $TimeoutSec, $UserAgent, $ProxyUrl)

        try {
            $RequestParams = @{ Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; UserAgent = $UserAgent }
            if ($WebSession) { $RequestParams['WebSession'] = $WebSession }
            if ($ProxyUrl) { $RequestParams['Proxy'] = $ProxyUrl }
            $Response = Invoke-WebRequest @RequestParams
            [pscustomobject]@{
                Uri     = $Uri
                Content = $Response.Content
                Success = $true
                Error   = $null
            }
        }
        catch {
            [pscustomobject]@{
                Uri     = $Uri
                Content = $null
                Success = $false
                Error   = $_.Exception.Message
            }
        }
    }

    $Pipelines = New-Object System.Collections.ArrayList
    foreach ($Uri in $Uris) {
        $Pipeline = [powershell]::Create()
        $Pipeline.RunspacePool = $Pool
        [void]$Pipeline.AddScript($ScriptBlock).AddArgument($Uri).AddArgument($WebSession).AddArgument($TimeoutSec).AddArgument($UserAgent).AddArgument($ProxyUrl)
        $AsyncResult = $Pipeline.BeginInvoke()
        [void]$Pipelines.Add(@{ Pipeline = $Pipeline; AsyncResult = $AsyncResult })
    }

    # AddRange would bulk-copy via PSDataCollection's ICollection.CopyTo, which casts to PSObject[] and fails against ArrayList's object[] store
    $Results = New-Object System.Collections.ArrayList
    foreach ($Entry in $Pipelines) {
        foreach ($Item in $Entry.Pipeline.EndInvoke($Entry.AsyncResult)) {
            [void]$Results.Add($Item)
        }
        $Entry.Pipeline.Dispose()
    }

    $Pool.Close()
    $Pool.Dispose()

    return @($Results)
}

function Select-HighestVersionUrl {
    param(
        [string[]]$Urls,
        [string]$VersionTag
    )

    $Filtered = @($Urls | Where-Object { $_ -like "*$VersionTag*" })
    if ($Filtered.Count -eq 0) {
        $Filtered = $Urls
    }

    $Best = $null
    $BestVersion = $null
    foreach ($Candidate in $Filtered) {
        $FileName = $Candidate.Split('/')[-1]
        $VersionMatch = [regex]::Match($FileName, '(\d+\.\d+\.\d+\.\d+)')
        if ($VersionMatch.Success) {
            try {
                $Ver = [Version]$VersionMatch.Groups[1].Value
                if ($null -eq $BestVersion -or $Ver -gt $BestVersion) {
                    $BestVersion = $Ver
                    $Best = $Candidate
                }
            }
            catch { }
        }
    }

    if ($Best) {
        return $Best
    }
    return $Filtered[0]
}

function Resolve-MsiDownloadUrl {
    param(
        [string]$Url,
        [string]$WindowsVersion
    )

    $script:LastResolveFailureWasRetired = $false

    $VersionTag = if ($WindowsVersion -eq '10') { '_Win10_' } else { '_Win11_' }
    $MsiPattern = 'https://download\.microsoft\.com/[^"'']+\.msi'

    # Extract ?id= for use in details-page URL construction
    $Id = $null
    if ($Url -match '\?id=(\d+)') {
        $Id = $Matches[1]
    }

    # The details.aspx page itself carries the download links as an embedded JSON blob, so no
    # separate confirmation.aspx step is needed. fwlink URLs carry no id, keep the legacy no_redirect
    # fetch for those.
    $FetchUrl = $null
    if ($Id) {
        $FetchUrl = "https://www.microsoft.com/en-us/download/details.aspx?id=$Id"
    }
    elseif ($Url -match 'go\.microsoft\.com/fwlink') {
        $FetchUrl = if ($Url -match '&no_redirect=true') { $Url } else { "$Url&no_redirect=true" }
    }

    if (-not $FetchUrl) {
        Write-Host "  Warning: cannot construct details URL for '$Url'" -ForegroundColor Yellow
        return $null
    }

    $SpaResponse = $null
    try {
        $SpaRequestParams = @{ Uri = $FetchUrl; UseBasicParsing = $true; TimeoutSec = 30; UserAgent = $script:UserAgent }
        if ($script:WebSession) { $SpaRequestParams['WebSession'] = $script:WebSession }
        if ($ProxyUrl) { $SpaRequestParams['Proxy'] = $ProxyUrl }
        [void]($SpaResponse = Invoke-WebRequest @SpaRequestParams)
    }
    catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            Write-Host "  Retired listing (404): Microsoft no longer hosts a download page for $Url" -ForegroundColor DarkGray
            $script:LastResolveFailureWasRetired = $true
            return $null
        }
        Write-Host "  Warning: could not resolve download URL for '$Url' - $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    # A redirect to the Microsoft account sign-in page means every remaining model will hit the same
    # wall, this is a systemic auth gate, not a per-model regex miss, so the caller must be told apart
    # from a plain no-URL result.
    $FinalUri = $null
    if ($SpaResponse.BaseResponse -and $SpaResponse.BaseResponse.ResponseUri) {
        $FinalUri = $SpaResponse.BaseResponse.ResponseUri.AbsoluteUri
    }
    if ($FinalUri -and ($FinalUri -match 'login\.live\.com' -or $FinalUri -match 'oauth20_authorize')) {
        throw "Microsoft redirected the download page to sign-in ($FinalUri) instead of returning the file link. Downloads cannot continue without an authenticated session."
    }

    # Feed the raw, still-escaped JSON text to ConvertFrom-Json so it unescapes '\/' itself, rather
    # than reusing the page-wide unescape meant for the raw-HTML fallback scan below.
    $Dlc = $null
    $DlcMatch = [regex]::Match($SpaResponse.Content, 'window\.__DLCDetails__=(\{[\s\S]+?\});\s*</script>', 'IgnoreCase')
    if ($DlcMatch.Success) {
        try {
            $Dlc = ConvertFrom-Json -InputObject $DlcMatch.Groups[1].Value
        }
        catch {
            $Dlc = $null
        }
    }

    if (-not $Dlc) {
        # No __DLCDetails__ blob, or it failed to parse. Fall back to scanning raw HTML for a direct msi link.
        $SpaContent = $SpaResponse.Content -replace '\\/', '/'
        $Candidates = @()
        $UrlMatches = [regex]::Matches($SpaContent, $MsiPattern)
        foreach ($m in $UrlMatches) {
            $Candidates += $m.Value
        }
        if ($Candidates.Count -eq 0) {
            Write-Host "  Warning: could not resolve download URL for '$Url' - no __DLCDetails__ JSON and no direct msi link found" -ForegroundColor Yellow
            return $null
        }
        return Select-HighestVersionUrl -Urls $Candidates -VersionTag $VersionTag
    }

    $DlcError = $Dlc.dlcDetailsView.error
    if ($DlcError) {
        Write-Host "  No download available for '$Url' - $DlcError" -ForegroundColor DarkGray
        $script:LastResolveFailureWasRetired = $true
        return $null
    }

    $Candidates = @($Dlc.dlcDetailsView.downloadFile | ForEach-Object { $_.url })
    if ($Candidates.Count -eq 0) {
        Write-Host "  No download available for '$Url'" -ForegroundColor DarkGray
        $script:LastResolveFailureWasRetired = $true
        return $null
    }

    return Select-HighestVersionUrl -Urls $Candidates -VersionTag $VersionTag
}

function Get-NormalizedModelTokens {
    param([string]$Text)

    if (-not $Text) { return @() }

    # Baseboard/ComputerSystem strings use commas for edition info where the catalog uses parentheses, normalize both to bare words
    $Clean = $Text -replace '(?i)^\s*Microsoft\s+', ''
    $Clean = $Clean -replace '[(),]', ' '
    $Clean = $Clean -replace '\s+', ' '
    $Clean = $Clean.Trim().ToLowerInvariant()
    if (-not $Clean) { return @() }
    return @($Clean -split ' ')
}

function Get-BestCatalogMatch {
    param(
        [string[]]$CatalogKeys,
        [string[]]$Candidates
    )

    # A catalog key matches only if every one of its words appears somewhere in the candidate text, word count decides which candidate/key pair wins so a specific edition beats a generic family name
    $Best = $null
    $BestScore = 0

    foreach ($Candidate in $Candidates) {
        if (-not $Candidate) { continue }
        $CandidateTokens = @(Get-NormalizedModelTokens -Text $Candidate)
        if ($CandidateTokens.Count -eq 0) { continue }

        foreach ($Key in $CatalogKeys) {
            $KeyTokens = @(Get-NormalizedModelTokens -Text $Key)
            if ($KeyTokens.Count -eq 0) { continue }

            $MatchedCount = @($KeyTokens | Where-Object { $CandidateTokens -contains $_ }).Count
            if ($MatchedCount -eq $KeyTokens.Count -and $MatchedCount -gt $BestScore) {
                $BestScore = $MatchedCount
                $Best = $Key
            }
        }
    }

    return $Best
}

function Get-DriverPackage {
    param(
        [string]$Url,
        [string]$DestinationFolder
    )

    New-Item -ItemType Directory -Force -Path $DestinationFolder | Out-Null
    $FileName = $Url.Split('/')[-1]
    $DestFile = Join-Path -Path $DestinationFolder -ChildPath $FileName

    if (Test-Path -LiteralPath $DestFile) {
        if (-not $Quiet) {
            Write-Host "    Already present: $FileName" -ForegroundColor DarkGray
        }
        return $true
    }

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            try {
                $BitsProxyArgs = @{}
                if ($ProxyUrl) {
                    $BitsProxyArgs['ProxyUsage'] = 'Override'
                    $BitsProxyArgs['ProxyList'] = $ProxyUrl
                }
                [void](Start-BitsTransfer -Source $Url -Destination $DestFile -DisplayName $FileName -ErrorAction Stop @BitsProxyArgs)
            }
            catch {
                Write-Host "    BITS failed, falling back to WebRequest - $($_.Exception.Message)" -ForegroundColor Yellow
                [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
            }
        }
        else {
            [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
        }
        Unblock-File -LiteralPath $DestFile -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Write-Host "    Download failed - $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $DestFile) {
            Remove-Item -LiteralPath $DestFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# Resolve to an absolute path before any path operations.
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

# Bulk parameters opt out of installing on this device, so local install is the default only when none of them are given.
$DoLocalInstall = -not $DownloadOnly -and -not $ListModels -and -not ($Models -and $Models.Count -gt 0)

if ($DoLocalInstall -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Host 'Installing on this device runs msiexec and requires an elevated (Administrator) PowerShell session. Re-run from an elevated prompt, or pass -DownloadOnly to just download the package.' -ForegroundColor Red
    exit 1
}

if ($ListModels) {
    Write-Host 'Fetching model catalog from Microsoft Support...' -ForegroundColor DarkGray
    $LiveCatalog = Get-CatalogFromSupportPage -WindowsVersion $WindowsVersion
    if ($LiveCatalog.Count -eq 0) {
        Write-Host 'No driver links found on the support page. Check network access and try again.' -ForegroundColor Red
        exit 1
    }
    Write-Host 'Available models:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('{0,-40} {1}' -f 'Model', 'URL') -ForegroundColor Cyan
    Write-Host ('-' * 100) -ForegroundColor DarkGray
    foreach ($Name in ($LiveCatalog.Keys | Sort-Object)) {
        Write-Host ('{0,-40} {1}' -f $Name, $LiveCatalog[$Name])
    }
    Write-Host ''
    exit 0
}

Write-Host 'Fetching model catalog from Microsoft Support...' -ForegroundColor DarkGray
$LiveCatalog = Get-CatalogFromSupportPage -WindowsVersion $WindowsVersion

if ($LiveCatalog.Count -eq 0) {
    Write-Host 'No driver links found on the support page. Check network access and try again.' -ForegroundColor Red
    exit 1
}

if ($DoLocalInstall) {
    $LocalModel = (Get-CimInstance -ClassName Win32_ComputerSystem).Model
    $LocalBaseboard = (Get-CimInstance -ClassName Win32_BaseBoard).Product
    if (-not $Quiet) {
        Write-Host "Detected device model: $LocalModel" -ForegroundColor DarkGray
        Write-Host "Detected baseboard product: $LocalBaseboard" -ForegroundColor DarkGray
    }

    $MatchedModel = Get-BestCatalogMatch -CatalogKeys @($LiveCatalog.Keys) -Candidates @($LocalBaseboard, $LocalModel)

    if (-not $MatchedModel) {
        Write-Host "No catalog entry matches this device (model '$LocalModel', baseboard '$LocalBaseboard'). Use -ListModels to see what's available." -ForegroundColor Red
        exit 1
    }

    Write-Host "Matched catalog model: $MatchedModel" -ForegroundColor Cyan
    $Models = @($MatchedModel)
}

if ($Models -and $Models.Count -gt 0) {
    foreach ($RequestedName in $Models) {
        if (-not $LiveCatalog.Contains($RequestedName)) {
            Write-Host "Warning: '$RequestedName' is not in the catalog; use -ListModels to see available models." -ForegroundColor Yellow
        }
    }
    $TargetModels = @($Models | Where-Object { $LiveCatalog.Contains($_) })
}
else {
    $TargetModels = @($LiveCatalog.Keys)
}

if ($TargetModels.Count -eq 0) {
    Write-Host "No models to process for Windows $WindowsVersion." -ForegroundColor Yellow
    exit 0
}

Write-Host "Surface driver download - Windows $WindowsVersion - $($TargetModels.Count) model(s)" -ForegroundColor Cyan
Write-Host "Output: $OutputPath" -ForegroundColor DarkGray
Write-Host ''

$SummaryRows = New-Object System.Collections.Generic.List[object]
$AuthGateHit = $false

foreach ($ModelName in ($TargetModels | Sort-Object)) {
    if (-not $Quiet) {
        Write-Host "  $ModelName" -ForegroundColor Cyan
    }

    $DriverUrl = $LiveCatalog[$ModelName]
    $ModelFolder = Join-Path -Path $OutputPath -ChildPath $ModelName

    if (-not $Quiet) {
        Write-Host "    Resolving $DriverUrl ..." -ForegroundColor DarkGray
    }

    try {
        $MsiUrl = Resolve-MsiDownloadUrl -Url $DriverUrl -WindowsVersion $WindowsVersion
    }
    catch {
        Write-Host ''
        Write-Host "Stopping: Microsoft's download pages are requiring sign-in to reach the driver link, so this run cannot continue. Sign in to https://www.microsoft.com/download in a browser first, then re-run. ($($_.Exception.Message))" -ForegroundColor Red
        $AuthGateHit = $true
        break
    }
    if (-not $MsiUrl) {
        if ($script:LastResolveFailureWasRetired) {
            $SummaryRows.Add([pscustomobject]@{
                Model  = $ModelName
                Result = 'Unavailable'
                Detail = $DriverUrl
            })
        }
        else {
            Write-Host "  Warning: no download URL found for '$ModelName' ($DriverUrl)." -ForegroundColor Yellow
            $SummaryRows.Add([pscustomobject]@{
                Model  = $ModelName
                Result = 'Failed - no URL'
                Detail = $DriverUrl
            })
        }
        continue
    }

    if (-not $Quiet) {
        Write-Host "    $MsiUrl" -ForegroundColor DarkGray
    }

    $FileName = $MsiUrl.Split('/')[-1]
    $DestFile = Join-Path -Path $ModelFolder -ChildPath $FileName
    $AlreadyPresent = Test-Path -LiteralPath $DestFile

    $Success = Get-DriverPackage -Url $MsiUrl -DestinationFolder $ModelFolder

    if ($Success) {
        $ResultLabel = if ($AlreadyPresent) { 'Already present' } else { 'Downloaded' }
        if ((-not $Quiet) -and (-not $AlreadyPresent)) {
            Write-Host "    Downloaded: $FileName" -ForegroundColor Green
        }

        if ($DoLocalInstall) {
            if (-not $Quiet) {
                Write-Host "    Installing $FileName ..." -ForegroundColor DarkGray
            }
            $InstallProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$DestFile`" /quiet /norestart" -Wait -PassThru
            if ($InstallProcess.ExitCode -eq 0 -or $InstallProcess.ExitCode -eq 3010) {
                if ($InstallProcess.ExitCode -eq 3010) {
                    Write-Host '    Installed successfully (reboot required)' -ForegroundColor Green
                    $script:RebootRequired = $true
                    $ResultLabel = 'Installed (reboot required)'
                }
                else {
                    Write-Host '    Installed successfully' -ForegroundColor Green
                    $ResultLabel = 'Installed'
                }
            }
            else {
                Write-Host "    Install failed (exit $($InstallProcess.ExitCode))" -ForegroundColor Red
                $ResultLabel = "Install failed ($($InstallProcess.ExitCode))"
            }
        }

        $SummaryRows.Add([pscustomobject]@{
            Model  = $ModelName
            Result = $ResultLabel
            Detail = $DestFile
        })
    }
    else {
        $SummaryRows.Add([pscustomobject]@{
            Model  = $ModelName
            Result = 'Failed'
            Detail = $MsiUrl
        })
    }
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('-' * 80) -ForegroundColor DarkGray

foreach ($Row in $SummaryRows) {
    $RowColor = switch ($Row.Result) {
        'Downloaded'                  { 'Green' }
        'Installed'                   { 'Green' }
        'Installed (reboot required)' { 'Yellow' }
        'Already present'             { 'DarkGray' }
        'Unavailable'                 { 'DarkGray' }
        default                       { 'Yellow' }
    }
    Write-Host ('{0,-40} {1,-16} {2}' -f $Row.Model, $Row.Result, $Row.Detail) -ForegroundColor $RowColor
}

Write-Host ''
if ($AuthGateHit) {
    exit 1
}
if ($script:RebootRequired) {
    exit 3010
}
exit 0
