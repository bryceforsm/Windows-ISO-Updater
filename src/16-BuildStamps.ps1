#region Build stamps
# A stamp is a small JSON record of one finished build: the SHA-256 of the source ISO, the update packages
# that went into it, the build-affecting parameters, and the ISO that came out. A repeat run compares
# itself with the newest stamp and does nothing when all three still match - which is what makes it safe
# to point an hourly scheduled task at a job that takes an hour or two when it does run.

# Hashes in 4 MB reads rather than through Get-FileHash, whose stream is pulled 4 KB at a time. That is
# invisible on a local SSD and brutal on a share or a cloud-synced folder, where every read is a round trip.
function Get-Sha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$ShowProgress
    )
    $BufferSize = 4MB
    $Algorithm = $null
    $Stream = $null
    $Progress = $null
    try {
        $Length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        # On .NET Framework the base factory hands back the managed implementation, so ask for the
        # hardware-accelerated one by name. It does not exist on .NET, where the factory is already
        # accelerated. Resolved with -as rather than try/catch, because the failed New-Object is a
        # terminating error and PowerShell 7 records it in the transcript even though it is caught.
        $Algorithm = if ('System.Security.Cryptography.SHA256Cng' -as [type]) {
            New-Object System.Security.Cryptography.SHA256Cng
        }
        else {
            [System.Security.Cryptography.SHA256]::Create()
        }
        $Stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read, $BufferSize, [System.IO.FileOptions]::SequentialScan)
        $Buffer = New-Object byte[] $BufferSize
        $Done = [long]0
        $NextPercent = 20
        $Timer = [System.Diagnostics.Stopwatch]::StartNew()
        # Reported only for the multi-gigabyte ISOs, where a slow source can make this take minutes. On a
        # console that is a progress line. Without one (a scheduled run), a line every 20% goes to the
        # transcript instead, so its log still shows the hash moving.
        if ($ShowProgress -and $Length -gt 1GB) { $Progress = New-ProgressLine -Indent 24 }
        while (($Count = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            [void]$Algorithm.TransformBlock($Buffer, 0, $Count, $null, 0)
            $Done += $Count
            if ($Progress) {
                $Percent = [int][math]::Floor(100 * $Done / $Length)
                if ($Progress.Width -gt 0) {
                    if ($Percent -ne $Progress.Percent) {
                        Update-ProgressLine -State $Progress -Percent $Percent -Detail (Format-ByteProgress -Done $Done -Total $Length -Elapsed $Timer.Elapsed)
                    }
                }
                elseif ($Percent -ge $NextPercent -and $Timer.Elapsed.TotalSeconds -gt 0) {
                    Write-HostTimestamp ('    {0}% ({1:N0} MB/s)' -f $Percent, ($Done / 1MB / $Timer.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
                    $NextPercent = $Percent + 20
                }
            }
        }
        [void]$Algorithm.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return [System.BitConverter]::ToString($Algorithm.Hash).Replace('-', '')
    }
    catch { return $null }
    finally {
        if ($Progress) { Clear-ProgressLine -State $Progress }
        if ($Stream) { $Stream.Dispose() }
        if ($Algorithm) { $Algorithm.Dispose() }
    }
}

function Get-TextSha256 {
    param([string]$Text)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Text")) | ForEach-Object { $_.ToString('x2') })) }
    finally { $Sha.Dispose() }
}

# Path, size and SHA-256 of every file under a folder, sorted, with the path relative to the folder itself.
# Hashing is the expensive part, so the records are produced once and then used both to decide whether the
# folder changed since the last build and to list what actually went onto the media.
function Get-FolderFileRecords {
    param([Parameter(Mandatory)][string]$Path)
    $Root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $Records = New-Object System.Collections.Generic.List[object]
    $Files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object -Property FullName)
    foreach ($File in $Files) {
        [void]$Records.Add([ordered]@{
                Path   = $File.FullName.Substring($Root.Length)
                SizeKB = [math]::Round($File.Length / 1KB, 2)
                Sha256 = Get-Sha256 -Path $File.FullName
            })
    }
    return $Records.ToArray()
}

# One hash covering every file under a folder, so swapping a driver for a newer one forces a rebuild even
# though the folder path never changed.
function Get-FolderContentHash {
    param([AllowEmptyCollection()][object[]]$Records)
    $Parts = @($Records | ForEach-Object { "$($_.Path.TrimStart('\').ToLowerInvariant())=$($_.Sha256)" })
    return (Get-TextSha256 -Text ($Parts -join '|'))
}

function Format-ShortHash {
    param([string]$Hash)
    if ($Hash -and $Hash.Length -ge 12) { return $Hash.Substring(0, 12) }
    if ($Hash) { return $Hash }
    return '(none)'
}

# Describes the packages that went into a build. Hashing an LCU is not free, so this runs once and both
# the media tattoo and the build stamp use the result.
function Get-UpdateFileRecords {
    param(
        [string[]]$Paths,
        [string]$DownloadDir
    )
    $Records = @()
    foreach ($Path in @($Paths | Sort-Object -Unique)) {
        $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $Item) { continue }
        $Records += [ordered]@{
            FileName           = $Item.Name
            Kb                 = if ($Item.Name -match '(?i)kb(\d{6,})') { "KB$($Matches[1])" } else { '' }
            SizeMB             = [math]::Round($Item.Length / 1MB, 1)
            Sha256             = Get-Sha256 -Path $Item.FullName
            # Only packages this script downloaded itself are ever eligible for -AutoClean.
            FromDownloadFolder = ("$($Item.DirectoryName)".TrimEnd('\') -ieq "$DownloadDir".TrimEnd('\'))
        }
    }
    return $Records
}

# The parameters that change what ends up inside the ISO. Folder, logging and scheduling parameters are
# deliberately left out: moving the working folder does not make last month's ISO wrong.
$script:BuildAffectingParameters = @(
    'WindowsVersion', 'Release', 'Language', 'Edition', 'KeepEditions', 'KeepAllEditions',
    'UpdatePath', 'SkipDotNet', 'SkipSetupDU', 'SkipWinRE', 'BaselineOnly', 'IncludePreview', 'ReapplyUpdates', 'SkipUpdates', 'SkipServicing', 'CompressEsd', 'FastCompression', 'VolumeLabel',
    'SkipTattoo', 'StripImageResidue', 'DriverPath', 'AllowUnsignedDrivers', 'ExtraFilesPath'
)

# Flattens those parameters (current values, not just the ones that were passed) into comparable text.
function Get-BuildParameterSet {
    $Set = [ordered]@{}
    foreach ($Name in $script:BuildAffectingParameters) {
        $Value = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
        $Set[$Name] =
            if ($null -eq $Value) { '' }
            elseif ($Value -is [switch]) { [string][bool]$Value.IsPresent }
            elseif ($Value -is [array]) { (@($Value) | ForEach-Object { "$_" }) -join ',' }
            else { "$Value" }
    }
    # The answer file is copied onto the media, so its CONTENT is part of the build - editing it in place
    # has to force a rebuild even though the path never changed.
    $Set['Unattend'] = if ($script:UnattendHash) { $script:UnattendHash } else { '' }
    # Same for the drivers, which are injected into the images rather than copied onto the media.
    $Set['Drivers'] = if ($script:DriverHash) { $script:DriverHash } else { '' }
    $Set['ExtraFiles'] = if ($script:ExtraFilesHash) { $script:ExtraFilesHash } else { '' }
    # Only present when asked for, so turning it on forces one rebuild without changing every older stamp's hash.
    if ($RecoveryIsoPath) { $Set['RecoveryIso'] = 'True' }
    return $Set
}

function Get-BuildParameterHash {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Set)
    return (Get-TextSha256 -Text ((@($Set.Keys) | ForEach-Object { "$_=$($Set[$_])" }) -join '|'))
}

function Read-BuildStamp {
    if (-not (Test-Path -LiteralPath $StampFile -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $StampFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) }
    catch {
        Write-HostTimestamp "  The stamp '$StampFile' could not be read ($($_.Exception.Message)), so this is treated as a first run." -ForegroundColor Yellow
        return $null
    }
}

# The stamp is wanted twice, once to guess Server versus client before an ISO exists and again by the
# rebuild check, and reading it twice would report an unreadable stamp twice.
function Get-PreviousBuildStamp {
    if (-not $script:PreviousStampRead) {
        $script:PreviousStamp = Read-BuildStamp
        $script:PreviousStampRead = $true
    }
    return $script:PreviousStamp
}

# Every stamp still on disk, newest first. -AutoClean uses this to know which downloads and ISOs are ones
# this script produced, so it never touches anything else in those folders.
function Get-BuildStampHistory {
    $Stamps = New-Object System.Collections.Generic.List[object]
    foreach ($File in @(Get-ChildItem -LiteralPath $StampHistoryDir -Filter 'stamp_*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try { $Stamps.Add((Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json)) } catch { }
    }
    return $Stamps.ToArray()
}

# Windows PowerShell 5.1 indents nested JSON to the column of its opening brace, so the deeper parts of
# a stamp end up far off to the right. Re-indent the compressed form to a fixed two spaces instead.
function Format-Json {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [int]$IndentWidth = 2
    )
    $Builder = New-Object System.Text.StringBuilder
    $Newline = [Environment]::NewLine
    $Depth = 0
    $InString = $false
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $Char = $Json[$i]
        if ($InString) {
            # A backslash escapes whatever follows, so consume that before looking for the closing quote.
            if ($Char -eq '\' -and $i + 1 -lt $Json.Length) {
                # 5.1 writes < > & and ' as \u00XX, which is valid JSON but unreadable in a file meant for people.
                $Hex = if ($Json[$i + 1] -eq 'u' -and $i + 5 -lt $Json.Length) { $Json.Substring($i + 2, 4) } else { '' }
                if ($Hex -in '003c', '003e', '0026', '0027') {
                    [void]$Builder.Append([char][Convert]::ToInt32($Hex, 16))
                    $i += 5
                    continue
                }
                [void]$Builder.Append($Char)
                [void]$Builder.Append($Json[++$i])
                continue
            }
            [void]$Builder.Append($Char)
            if ($Char -eq '"') { $InString = $false }
            continue
        }
        if ($Char -eq '"') { $InString = $true; [void]$Builder.Append($Char); continue }
        if ($Char -eq ':') { [void]$Builder.Append(': '); continue }
        if ($Char -eq ',') { [void]$Builder.Append(",$Newline" + (' ' * ($Depth * $IndentWidth))); continue }
        if ($Char -eq '{' -or $Char -eq '[') {
            [void]$Builder.Append($Char)
            $Close = if ($Char -eq '{') { '}' } else { ']' }
            # An empty object or array stays on one line rather than spending three lines on nothing.
            if ($i + 1 -lt $Json.Length -and $Json[$i + 1] -eq $Close) { [void]$Builder.Append($Close); $i++; continue }
            $Depth++
            [void]$Builder.Append($Newline + (' ' * ($Depth * $IndentWidth)))
            continue
        }
        if ($Char -eq '}' -or $Char -eq ']') {
            $Depth--
            [void]$Builder.Append($Newline + (' ' * ($Depth * $IndentWidth)) + $Char)
            continue
        }
        [void]$Builder.Append($Char)
    }
    return $Builder.ToString()
}

function Write-BuildStamp {
    param([Parameter(Mandatory)]$Stamp)
    try {
        foreach ($Dir in @($StampRoot, $StampHistoryDir)) {
            if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
        }
        $Json = Format-Json -Json ($Stamp | ConvertTo-Json -Depth 8 -Compress)
        Set-Content -LiteralPath $StampFile -Value $Json -Encoding UTF8 -ErrorAction Stop
        $HistoryFile = Join-Path -Path $StampHistoryDir -ChildPath ("stamp_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        Set-Content -LiteralPath $HistoryFile -Value $Json -Encoding UTF8 -ErrorAction Stop
        Write-HostTimestamp "  Stamp written: $StampFile" -ForegroundColor Green
        Write-HostTimestamp "  History copy : $HistoryFile" -ForegroundColor DarkGray
        Get-ChildItem -LiteralPath $StampHistoryDir -Filter 'stamp_*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -Skip $StampHistoryCount |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-HostTimestamp "  Could not write the build stamp: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Hashes already taken for a file, keyed on its path, size and write time. Reading 8 GB costs minutes on
# slow storage, and a run that dies during servicing would otherwise make the next one pay it all over
# again, because the build stamp is only written once a build has finished.
function Read-HashCache {
    if (-not (Test-Path -LiteralPath $HashCacheFile -PathType Leaf)) { return @() }
    try {
        # Windows PowerShell 5.1 emits a deserialised array as ONE pipeline item, so it has to be assigned
        # before @() can enumerate it. Wrapping the call itself yields an array holding a single array.
        $Parsed = Get-Content -LiteralPath $HashCacheFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        return @($Parsed)
    }
    catch { return @() }   # an unreadable cache costs a re-hash, so it is rebuilt rather than reported
}

# True when a write time read back from a stamp or the hash cache is the file's current one. Windows PowerShell
# hands the recorded value back as the round-trip string it was saved as, but PowerShell 7's ConvertFrom-Json
# turns it into a DateTime, whose text form drops the fraction of a second, so comparing text never matches there.
function Test-SameWriteTime {
    param(
        $Recorded,
        [Parameter(Mandatory)][datetime]$Actual
    )
    if (-not $Recorded) { return $false }
    if ($Recorded -isnot [datetime]) {
        $Parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse("$Recorded", [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$Parsed)) { return $false }
        $Recorded = $Parsed
    }
    return ($Recorded.ToUniversalTime().Ticks -eq $Actual.ToUniversalTime().Ticks)
}

function Get-CachedSha256 {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Item)
    foreach ($Entry in @(Read-HashCache)) {
        if ("$($Entry.Path)" -ieq $Item.FullName -and
            "$($Entry.Length)" -eq "$($Item.Length)" -and
            (Test-SameWriteTime -Recorded $Entry.LastWriteTimeUtc -Actual $Item.LastWriteTimeUtc)) {
            return "$($Entry.Sha256)"
        }
    }
    return $null
}

function Set-CachedSha256 {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Item,
        [Parameter(Mandatory)][string]$Sha256
    )
    try {
        $Entries = New-Object System.Collections.Generic.List[object]
        [void]$Entries.Add([ordered]@{
                Path             = $Item.FullName
                Length           = $Item.Length
                LastWriteTimeUtc = $Item.LastWriteTimeUtc.ToString('o')
                Sha256           = $Sha256
                HashedUtc        = (Get-Date).ToUniversalTime().ToString('o')
            })
        foreach ($Entry in @(Read-HashCache)) {
            # Dropping older rows for this path keeps one per file, whatever it hashed to before.
            if ("$($Entry.Path)" -ine $Item.FullName) { [void]$Entries.Add($Entry) }
        }
        if (-not (Test-Path -LiteralPath $StampRoot)) { New-Item -ItemType Directory -Path $StampRoot -Force -ErrorAction Stop | Out-Null }
        $Kept = @($Entries | Select-Object -First 20)
        Set-Content -LiteralPath $HashCacheFile -Value (Format-Json -Json ($Kept | ConvertTo-Json -Depth 4 -Compress)) -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not record the hash for a later run: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# SHA-256 of the source ISO, reused from the stamp when this is provably the same file that was hashed
# last time (same path, size and write time). Re-reading 8 GB on every hourly run buys nothing.
function Get-SourceIsoHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        $Stamp
    )
    $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $Item) { return $null }
    if ($Stamp -and $Stamp.Source -and $Stamp.Source.Sha256 -and
        "$($Stamp.Source.Path)" -ieq $Item.FullName -and
        "$($Stamp.Source.Length)" -eq "$($Item.Length)" -and
        (Test-SameWriteTime -Recorded $Stamp.Source.LastWriteTimeUtc -Actual $Item.LastWriteTimeUtc)) {
        Write-HostTimestamp '  The source ISO is untouched since the last run, so its recorded hash is reused.' -ForegroundColor DarkGray
        return "$($Stamp.Source.Sha256)"
    }
    $Cached = Get-CachedSha256 -Item $Item
    if ($Cached) {
        Write-HostTimestamp '  The source ISO was hashed by an earlier run that did not finish, and it has not changed since, so that hash is reused.' -ForegroundColor DarkGray
        return $Cached
    }
    Write-HostTimestamp "  Hashing the source ISO ($([math]::Round($Item.Length / 1GB, 2)) GB)..."
    $Hash = Get-Sha256 -Path $Path -ShowProgress
    # Saved before the caller does anything else with it, which is the whole point of the cache.
    if ($Hash) { Set-CachedSha256 -Item $Item -Sha256 $Hash }
    return $Hash
}

# Resolves the newest catalog entry for a query WITHOUT downloading it - the cheap half of
# Get-LatestCatalogPackage, so a scheduled run can see what Microsoft is offering for the price of one
# web request. Returns $null when the catalog cannot be reached or nothing matches.
function Get-CatalogLatestEntry {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$TitleInclude,
        [string]$TitleExclude,
        [switch]$AllowPreview,
        [switch]$BaselineOnly,
        [datetime]$NotAfter      # optional upper bound - packages released after this date are excluded
    )
    $Results = Search-UpdateCatalog -Query $Query
    if (-not $Results -or $Results.Count -eq 0) { return $null }
    $Filtered = $Results
    if ($TitleInclude) { $Filtered = $Filtered | Where-Object { $_.Title -match $TitleInclude } }
    if ($TitleExclude) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch $TitleExclude } }
    if (-not $AllowPreview) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch '(?i)preview' } }
    if ($PSBoundParameters.ContainsKey('NotAfter')) {
        $Filtered = $Filtered | Where-Object { $_.LastUpdated -and ([datetime]$_.LastUpdated) -le $NotAfter }
    }
    if ($BaselineOnly -and $Filtered) { $Filtered = Select-HotpatchBaselineEntry -Query $Query -Candidates @($Filtered) -TitleInclude $TitleInclude -TitleExclude $TitleExclude }
    if (-not $Filtered) { return $null }
    return ($Filtered |
        Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.SizeMB }; Descending = $true } |
        Select-Object -First 1)
}

# Identifies a catalog entry for comparison: the KB number plus the date Microsoft last touched it, since
# the same KB does get re-released and a re-release is a different package.
function Get-CatalogEntryTag {
    param($Entry)
    if (-not $Entry) { return 'none' }
    $Kb = if ($Entry.Title -match '(?i)KB(\d{6,})') { $Matches[1] } else { $Entry.Guid }
    $Date = if ($Entry.LastUpdated) { ([datetime]$Entry.LastUpdated).ToString('yyyy-MM-dd') } else { '' }
    return "KB$Kb@$Date"
}

# The updates a build with the current parameters would integrate right now, as "Role=KB@date" strings.
# Comparing this list with the one in the last stamp is what tells a scheduled run whether anything new
# has been published. Returns $null when the catalog could not be reached at all, so the caller can tell
# "nothing new" apart from "could not find out".
function Get-ExpectedUpdateSet {
    param(
        [string]$FeatureName,
        [string]$CatalogArch
    )

    if ($SkipUpdates) { return @('None') }
    if ($UpdatePath) {
        # Locally supplied packages: their names and sizes are the identity, no catalog involved.
        $Files = @(Get-ChildItem -Path $UpdatePath -Include '*.msu', '*.cab' -File -Recurse -ErrorAction SilentlyContinue)
        return @($Files | ForEach-Object { "Local=$($_.Name):$($_.Length)" } | Sort-Object)
    }
    if (-not $CatalogArch) { return $null }
    # The server product name carries no branding of its own, so without a feature update it matches every
    # Server release in the catalog and no query can identify this media.
    if ($script:EffectiveServer -and -not $FeatureName) { return $null }

    $Product = Get-CatalogProductQuery -FeatureUpdate $FeatureName
    $Include = '(?i)cumulative update (preview )?for (windows|microsoft server operating system)'
    $Exclude = '(?i)\.net|dynamic update'
    $Set = New-Object System.Collections.Generic.List[string]
    $script:CatalogTitles = @{}

    # Same queries (including the broader fallback) the download step uses, so the two always agree.
    $Lcu = Get-CatalogLatestEntry -Query "Cumulative Update for $Product for $CatalogArch-based Systems" -TitleInclude $Include -TitleExclude $Exclude -AllowPreview:$IncludePreview -BaselineOnly:$BaselineOnly
    if (-not $Lcu -and -not $script:EffectiveServer) {
        $Lcu = Get-CatalogLatestEntry -Query "Cumulative Update for $(Get-CatalogProductQuery) for $CatalogArch-based Systems" -TitleInclude $Include -TitleExclude $Exclude -AllowPreview:$IncludePreview -BaselineOnly:$BaselineOnly
    }
    if (-not $Lcu) { return $null }
    $script:CatalogTitles['LCU'] = $Lcu.Title
    $Set.Add("LCU=$(Get-CatalogEntryTag -Entry $Lcu)")

    if (-not $SkipDotNet) {
        $DotNet = Get-CatalogLatestEntry -Query "Cumulative Update for .NET Framework $Product for $CatalogArch" -TitleInclude '(?i)\.net framework' -TitleExclude '(?i)dynamic update' -AllowPreview:$IncludePreview
        $Set.Add("DotNet=$(Get-CatalogEntryTag -Entry $DotNet)")
        if ($DotNet) { $script:CatalogTitles['DotNet'] = $DotNet.Title }
    }
    if (-not $SkipSetupDU) {
        # Bounds the Setup Dynamic Update by the LCU's own date so a stamp comparison always agrees with
        # what the download step would actually pick (see Get-LatestCatalogPackage's -NotAfter).
        $SetupDuArgs = @{ Query = "Setup Dynamic Update $Product $CatalogArch"; TitleInclude = '(?i)setup dynamic update'; AllowPreview = $IncludePreview }
        if ($Lcu.LastUpdated) { $SetupDuArgs.NotAfter = $Lcu.LastUpdated }
        $SetupDu = Get-CatalogLatestEntry @SetupDuArgs
        $Set.Add("SetupDU=$(Get-CatalogEntryTag -Entry $SetupDu)")
        if ($SetupDu) { $script:CatalogTitles['SetupDU'] = $SetupDu.Title }
    }
    if (-not $SkipWinRE) {
        # Server media labels the Safe OS package plain "Dynamic Update", so the Setup one is excluded by
        # name instead of the Safe OS one being required by name. Bounded by the LCU's date for the same
        # reason the Setup DU is, so a stamp comparison agrees with what the download step would pick.
        $SafeInclude = if ($script:EffectiveServer) { '(?i)dynamic update' } else { '(?i)safe os dynamic update' }
        $SafeOsArgs = @{ Query = "Safe OS Dynamic Update $Product $CatalogArch"; TitleInclude = $SafeInclude; TitleExclude = '(?i)setup dynamic update'; AllowPreview = $IncludePreview }
        if ($Lcu.LastUpdated) { $SafeOsArgs.NotAfter = $Lcu.LastUpdated }
        $SafeOs = Get-CatalogLatestEntry @SafeOsArgs
        $Set.Add("SafeOS=$(Get-CatalogEntryTag -Entry $SafeOs)")
        if ($SafeOs) { $script:CatalogTitles['SafeOS'] = $SafeOs.Title }
    }
    return @($Set)
}

# Decides whether this run has anything to do. Returns the decision plus the reasons behind it, so the
# log always says why an hour of work is - or is not - about to start.
function Test-RebuildNeeded {
    param(
        $Stamp,
        [string]$SourceHash,
        [System.Collections.IDictionary]$ParameterSet,
        [string[]]$ExpectedUpdates
    )

    $Reasons = New-Object System.Collections.Generic.List[string]

    if (-not $Stamp) {
        $Reasons.Add('no previous stamp was found, so this is treated as a first build')
        return [pscustomobject]@{ Rebuild = $true; Reasons = @($Reasons) }
    }

    if ("$($Stamp.Source.Sha256)" -ne "$SourceHash") {
        $Reasons.Add("the source ISO changed (stamp: $(Format-ShortHash "$($Stamp.Source.Sha256)"), now: $(Format-ShortHash $SourceHash))")
    }

    if ("$($Stamp.ParametersHash)" -ne (Get-BuildParameterHash -Set $ParameterSet)) {
        $Changed = @()
        foreach ($Key in @($ParameterSet.Keys)) {
            $Old = if ($Stamp.Parameters -and ($Stamp.Parameters.PSObject.Properties.Name -contains $Key)) { "$($Stamp.Parameters.$Key)" } else { '(not recorded)' }
            if ($Old -ne "$($ParameterSet[$Key])") { $Changed += "$Key '$Old' -> '$($ParameterSet[$Key])'" }
        }
        $Reasons.Add("the build parameters changed$(if ($Changed) { ": $($Changed -join ', ')" })")
    }

    $Recorded = @()
    if ($Stamp.Updates -and $Stamp.Updates.Catalog) { $Recorded = @($Stamp.Updates.Catalog | ForEach-Object { "$_" } | Sort-Object) }
    if ($null -eq $ExpectedUpdates) {
        # A network blip must not trigger a two-hour rebuild, so the next scheduled run will look again.
        $Reasons.Add('the Microsoft Update Catalog could not be reached, so this run assumes nothing new has been published')
    }
    elseif ($Recorded.Count -eq 0) {
        $Reasons.Add('the last stamp did not record which updates were used')
    }
    else {
        $Now = @($ExpectedUpdates | ForEach-Object { "$_" } | Sort-Object)
        if (($Recorded -join '|') -ne ($Now -join '|')) {
            $Reasons.Add("the available updates changed (stamp: $($Recorded -join ', ') / now: $($Now -join ', '))")
        }
    }

    if (-not $Stamp.Output -or -not $Stamp.Output.Path) {
        $Reasons.Add('the last stamp does not name an output ISO')
    }
    elseif (-not (Test-Path -LiteralPath "$($Stamp.Output.Path)" -PathType Leaf)) {
        $Reasons.Add("the ISO from the last build is gone ($($Stamp.Output.Path))")
    }

    # The catalog-unreachable note is informational only - on its own it is not a reason to rebuild.
    $Blocking = @($Reasons | Where-Object { $_ -notmatch 'could not be reached' })
    return [pscustomobject]@{ Rebuild = ($Blocking.Count -gt 0); Reasons = @($Reasons) }
}

#endregion

