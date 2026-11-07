#region Image servicing
# The percentage on one of DISM's progress-bar lines, such as "[=====      10.0%      ]", or $null for any
# other line. A comma is allowed as the decimal mark, because DISM formats it in the system's own locale.
function Get-DismPercent {
    param([string]$Line)
    if ($Line -notmatch '^\s*\[[=\s]*(\d{1,3})(?:[.,]\d+)?%[=\s]*\]\s*$') { return $null }
    return [math]::Min(100, [int]$Matches[1])
}

# The line shown while DISM works, such as "      [############--------]  47%  2m 13s", sized to fit the
# console so it is never wrapped onto a second line that \r could not get back to.
function Format-DismProgress {
    param(
        [int]$Percent,
        [TimeSpan]$Elapsed,
        [int]$Width,
        [int]$Indent = 0
    )
    $Tail = ' {0,3}%  {1}' -f $Percent, (Format-Duration $Elapsed)
    # One column is kept free, because writing into the last column makes some consoles wrap.
    $BarWidth = [math]::Min(40, $Width - 1 - $Indent - $Tail.Length - 2)
    if ($BarWidth -lt 10) {
        $Indent = 0
        $BarWidth = [math]::Max(0, $Width - 1 - $Tail.Length - 2)
    }
    $Filled = [int][math]::Floor($BarWidth * $Percent / 100)
    return (' ' * $Indent) + '[' + ('#' * $Filled) + ('-' * ($BarWidth - $Filled)) + ']' + $Tail
}

# Runs dism.exe and returns everything it printed, leaving $LASTEXITCODE as DISM set it. DISM redraws its
# progress bar with carriage returns, and PowerShell hands each redraw over as a line of its own, so the
# percentage can be read off as it goes and shown on a single line that is overwritten in place, then
# cleared when DISM finishes. That line is written straight to the console rather than through Write-Host,
# so it never reaches the transcript or the CMTrace log, and it is skipped when output is redirected.
function Invoke-Dism {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$Indent = 28
    )

    $Width = Get-ConsoleWidth
    $Start = Get-Date
    $Shown = -1
    $Drawn = $false
    try {
        & dism.exe @ArgumentList 2>&1 | ForEach-Object {
            $Line = "$_"
            if ($Width -gt 0) {
                $Percent = Get-DismPercent -Line $Line
                # DISM redraws the bar many times per percent, so the console is only touched when the number moves.
                if ($null -ne $Percent -and $Percent -ne $Shown) {
                    $Shown = $Percent
                    try {
                        [Console]::Write("`r" + (Format-DismProgress -Percent $Percent -Elapsed ((Get-Date) - $Start) -Width $Width -Indent $Indent))
                        $Drawn = $true
                    }
                    catch { $Width = 0 }   # a host without a real console, so stop trying
                }
            }
            $Line
        }
    }
    finally {
        # Blank the progress line, so the next message starts on a clean line, as it would have without it.
        if ($Drawn) {
            try { [Console]::Write("`r" + (' ' * ($Width - 1)) + "`r") } catch { }
        }
    }
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
        New-Item -ItemType Directory -Path $SsuDir -Force -ErrorAction Stop | Out-Null

        # Try the usual SSU-*.cab name first, because pulling every cab out unpacks the multi-GB LCU payload
        # as well.
        $Ssu = $null
        foreach ($Pattern in @('-F:*SSU*.cab', '-F:*.cab')) {
            & expand.exe "$PackagePath" $Pattern "$SsuDir" | Out-Null
            $Ssu = Get-ChildItem -LiteralPath $SsuDir -Filter '*.cab' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)ssu|servicingstack' } |
                Sort-Object -Property Length -Descending |
                Select-Object -First 1
            if ($Ssu) { break }
        }
        if (-not $Ssu) {
            Write-HostTimestamp '      No servicing stack package is bundled inside this update, so it cannot be applied on its own.' -ForegroundColor DarkYellow
            return $false
        }

        Write-HostTimestamp "      Applying the bundled servicing stack update first: $($Ssu.Name)" -ForegroundColor DarkYellow
        Invoke-Dism -ArgumentList (@("/Image:$MountDir", '/Add-Package', "/PackagePath:$($Ssu.FullName)") + $LogArgs) | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
            Write-HostTimestamp '      Servicing stack updated.' -ForegroundColor Green
            return $true
        }
        Write-HostTimestamp "      The servicing stack update did not apply either (exit code $LASTEXITCODE)." -ForegroundColor DarkYellow
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
        '0X80070070' { 'there is not enough free disk space on the working drive'; break }
        '0X80070005' { 'access was denied, often because antivirus or another program is holding files in the mounted image'; break }
        '0X80070020' { 'another program has a file in the mounted image open, often antivirus, Explorer or the search indexer'; break }
        '0X8007000D' { 'the package file is damaged, so delete it from the download folder and run again to fetch a fresh copy'; break }
        '0X80070002' { 'DISM could not find a file it needed, such as the package itself or a checkpoint update staged with it'; break }
        default { $null }
    }
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

        # Run DISM, and if it fails on the first try, retry once - transient issues (locked files, a busy
        # servicing stack, a momentary I/O hiccup) often clear on a second attempt.
        $MaxAttempts = 2
        for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
            $Output = Invoke-Dism -ArgumentList "/Image:$MountDir", '/Add-Package', "/PackagePath:$Target", "/LogPath:$DismLog"
            $ExitCode = $LASTEXITCODE

            if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
                Write-HostTimestamp '      Applied.' -ForegroundColor Green
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Applied' -Detail $RecordDetail -Checkpoints $Checkpoints
                return $true
            }
            if ($Output -match '0x800f081e') {
                Write-HostTimestamp '      Already present / not applicable - skipping.' -ForegroundColor DarkGray
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Skipped' -Detail 'Already present or not applicable (0x800F081E)' -Checkpoints $Checkpoints
                return $true
            }

            if ($Attempt -lt $MaxAttempts) {
                Write-HostTimestamp "      DISM /Add-Package failed (exit code $ExitCode). Retrying once..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds 5
            }
        }

        # 0x800F0823 is CBS_E_NEW_SERVICING_STACK_REQUIRED, so retrying the same package can never work
        # until the image's servicing stack is brought forward.
        if (($Output -match '0x800f0823') -and (Add-ServicingStack -MountDir $MountDir -PackagePath $Target -StageDir $Stage -LogPath $DismLog)) {
            Write-HostTimestamp '      Retrying the update now the servicing stack is current...' -ForegroundColor DarkYellow
            $Output = Invoke-Dism -ArgumentList "/Image:$MountDir", '/Add-Package', "/PackagePath:$Target", "/LogPath:$DismLog"
            $ExitCode = $LASTEXITCODE
            if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
                Write-HostTimestamp '      Applied.' -ForegroundColor Green
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Applied' -Detail 'Applied after the servicing stack was brought forward (0x800F0823)' -Checkpoints $Checkpoints
                return $true
            }
        }

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
        # Both failures mention "Unattend.xml", which is a red herring, so the error code decides the advice.
        if ($Output -match '0x800f0823') {
            Write-HostTimestamp '      Tip: 0x800F0823 means the image needs a newer servicing stack than it has, and the one' -ForegroundColor DarkGray
            Write-HostTimestamp '      bundled in this update did not take. Base media several years older than the update is the' -ForegroundColor DarkGray
            Write-HostTimestamp '      usual cause. Try newer media, or apply the standalone SSU for this release to the mounted' -ForegroundColor DarkGray
            Write-HostTimestamp '      image by hand before re-running.' -ForegroundColor DarkGray
        }
        elseif ($Output -match '0x80070228' -or $Output -match '(?i)Unattend\.xml') {
            # A hash mismatch here just means the base image's files don't match their manifests - usually a
            # repacked/UUP ISO rather than a clean Microsoft one. It's informational, not a crash.
            Write-HostTimestamp '      Tip: this is typically the base image, not the update - the install.wim files did not match' -ForegroundColor DarkGray
            Write-HostTimestamp '      their manifests (common with repacked/UUP ISOs). A clean official Microsoft ISO usually resolves it.' -ForegroundColor DarkGray
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
        Export-WindowsImage -SourceImagePath $WinReWim -SourceIndex 1 -DestinationImagePath $Temp -CompressionType Max -ErrorAction Stop | Out-Null
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

