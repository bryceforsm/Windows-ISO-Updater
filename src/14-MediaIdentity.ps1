#region Identifying the media
# The media's installation language. DISM's image object has no DefaultLanguage property (it exposes a
# Languages list plus DefaultLanguageIndex, and that list is often empty on Microsoft media), so
# sources\lang.ini, which Setup itself reads, is the fallback. Returns a culture name or $null.
function Get-MediaLanguage {
    param(
        $ImageInfo,
        [string]$MediaRoot
    )

    if ($ImageInfo -and $ImageInfo.Languages -and $ImageInfo.Languages.Count -gt 0) {
        $Index = [int]$ImageInfo.DefaultLanguageIndex
        if ($Index -lt 0 -or $Index -ge $ImageInfo.Languages.Count) { $Index = 0 }
        $Lang = "$($ImageInfo.Languages[$Index])".Trim()
        if ($Lang) { return $Lang }
    }

    if ($MediaRoot) {
        $LangIni = Join-Path -Path $MediaRoot -ChildPath 'sources\lang.ini'
        if (Test-Path -LiteralPath $LangIni -PathType Leaf) {
            $InSection = $false
            foreach ($Line in (Get-Content -LiteralPath $LangIni -ErrorAction SilentlyContinue)) {
                $Trimmed = $Line.Trim()
                if ($Trimmed -match '^\[(.+)\]$') { $InSection = ($Matches[1] -eq 'Available UI Languages'); continue }
                if ($InSection -and $Trimmed -match '^([A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})+)\s*=') { return $Matches[1] }
            }
        }
    }
    return $null
}

# Maps a Windows build number to its marketing feature-update name (used to build catalog search queries).
function Get-FeatureUpdateName {
    param([Parameter(Mandatory)][int]$Build)
    switch ($Build) {
        26300  { '26H2'; break }
        26200  { '25H2'; break }
        26100  { '24H2'; break }   # also Windows Server 2025
        25398  { '23H2'; break }   # Windows Server, version 23H2
        22631  { '23H2'; break }
        22621  { '22H2'; break }
        22000  { '21H2'; break }
        20348  { '21H2'; break }   # Windows Server 2022
        19045  { '22H2'; break }   # Windows 10
        19044  { '21H2'; break }   # Windows 10
        17763  { '1809'; break }   # Windows Server 2019 / Windows 10 1809
        14393  { '1607'; break }   # Windows Server 2016
        default { $null }
    }
}

# The table above can only know releases that existed when this script was last touched, and every catalog
# query is built from its answer. The image does not have that problem: Setup records the marketing name in
# the offline SOFTWARE hive as DisplayVersion, so media from a release nobody has heard of yet still says
# what it is. That costs a read-only mount, which is why it is a fallback and not the first move.
function Resolve-FeatureUpdateName {
    param(
        [Parameter(Mandatory)][int]$Build,
        [string]$WimPath
    )

    $Known = Get-FeatureUpdateName -Build $Build
    if ($Known) { return $Known }
    # Nothing before Windows 10 records DisplayVersion, and those releases are all in the table already.
    if ($Build -lt 10240) { return $null }
    if (-not $WimPath -or -not (Test-Path -LiteralPath $WimPath)) { return $null }

    Write-HostTimestamp "  Build $Build is newer than any release this script has a name for, so the image is being asked directly. This takes a few minutes..." -ForegroundColor Yellow
    $BuildString = Get-WimBuildViaMount -WimPath $WimPath
    # Get-MountedImageBuild appends the hive's DisplayVersion in brackets, e.g. "10.0.26200.9168 (25H2)".
    if ("$BuildString" -match '\(\s*(\d{2}H\d|\d{4})\s*\)') {
        $Name = $Matches[1].ToUpperInvariant()
        Write-HostTimestamp "  The image identifies itself as $Name, so that is what the Microsoft Update Catalog will be asked for." -ForegroundColor Green
        return $Name
    }
    Write-HostTimestamp '  The image does not record a release name either, so the catalog search cannot be narrowed by version.' -ForegroundColor Yellow
    return $null
}

# The product wording the Microsoft Update Catalog uses in update titles, e.g. "Windows 11 Version 25H2".
# Microsoft stopped naming Server media after its year with Server 2022, so anything newer than Server
# 2019 is listed as "Microsoft server operating system version <feature update>" instead.
function Get-CatalogProductQuery {
    param([string]$FeatureUpdate)

    if (-not $script:EffectiveServer) {
        return "Windows $script:EffectiveWindowsVersion$(if ($FeatureUpdate) { " Version $FeatureUpdate" })"
    }
    switch ($FeatureUpdate) {
        '1607' { return 'Windows Server 2016' }
        '1809' { return 'Windows Server 2019' }
    }
    return "Microsoft server operating system$(if ($FeatureUpdate) { " version $FeatureUpdate" })"
}

# Marketing release name for a Windows Server build, used in the output ISO file name. Server images
# carry no branding of their own beyond the build number.
function Get-ServerReleaseName {
    param([int]$Build)
    switch ($Build) {
        26100  { 'WinSrv2025'; break }
        25398  { 'WinSrv23H2'; break }
        20348  { 'WinSrv2022'; break }
        17763  { 'WinSrv2019'; break }
        14393  { 'WinSrv2016'; break }
        default { 'WinSrv' }
    }
}

#endregion

