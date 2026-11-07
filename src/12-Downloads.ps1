#region Downloads
# The percentage on one of robocopy's progress lines, such as "  12.5%", or $null for any other line.
function Get-RobocopyPercent {
    param([string]$Line)
    if ($Line -notmatch '^\s*(\d{1,3})(?:[.,]\d+)?%\s*$') { return $null }
    return [math]::Min(100, [int]$Matches[1])
}

# Moves one multi-GB file with robocopy, which retries a share that blips and whose /J unbuffered mode is
# measurably faster than Copy-Item over SMB. /COPY:DAT is the important part: it takes data, attributes and
# timestamps only, deliberately leaving out S (the ACL), O (the owner) and U (auditing), so a file landing
# on a share inherits that share's permissions and one coming off a share does not carry the server's ACL
# onto the local disk. Throws unless the destination ends up byte-for-byte the size of the source.
# The destination must keep the source file name, which is all this script ever asks of it.
function Copy-LargeFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    $SourceLength = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    $Started = Get-Date

    if (Get-Command -Name 'robocopy.exe' -ErrorAction SilentlyContinue) {
        $SourceDir = Split-Path -Path $Path -Parent
        $TargetDir = Split-Path -Path $Destination -Parent
        # A trailing backslash escapes the closing quote PowerShell adds around an argument containing a
        # space, which is how robocopy ends up seeing two paths run together as one.
        foreach ($Name in 'SourceDir', 'TargetDir') {
            $Value = (Get-Variable -Name $Name -ValueOnly).TrimEnd('\')
            if ($Value -match '^[A-Za-z]:$') { $Value += '\' }
            Set-Variable -Name $Name -Value $Value
        }
        # No /NP or /NFL, because robocopy only reports its percentage with both left off. The percentage lines
        # drive the progress line and are dropped, so the output kept for an error message stays short.
        $RoboArgs = @($SourceDir, $TargetDir, (Split-Path -Leaf $Path),
            '/COPY:DAT', '/J', '/R:2', '/W:5', '/NJH', '/NJS', '/NDL')
        $Progress = New-ProgressLine -Indent 24
        try {
            $RoboOutput = & robocopy.exe @RoboArgs 2>&1 | ForEach-Object {
                $Line = "$_"
                $Percent = Get-RobocopyPercent -Line $Line
                if ($null -eq $Percent) { $Line }
                elseif ($Percent -ne $Progress.Percent) {
                    $Detail = Format-ByteProgress -Done ([long]($SourceLength * $Percent / 100)) -Total $SourceLength -Elapsed ((Get-Date) - $Started)
                    Update-ProgressLine -State $Progress -Percent $Percent -Detail $Detail
                }
            }
        }
        finally { Clear-ProgressLine -State $Progress }
        # robocopy counts anything under 8 as success (0 is "already identical", 1 is "copied").
        if ($LASTEXITCODE -ge 8) {
            $Detail = (@($RoboOutput) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
            throw "robocopy returned exit code $LASTEXITCODE. $Detail"
        }
    }
    else {
        # Only reachable where robocopy has been removed or blocked, and losing a finished build over that
        # would be worse than a slower copy.
        Copy-Item -LiteralPath $Path -Destination $Destination -Force -ErrorAction Stop
    }

    $Copied = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
    if (-not $Copied) { throw "nothing arrived at '$Destination'" }
    if ($Copied.Length -ne $SourceLength) {
        throw "the copy at '$Destination' is $($Copied.Length) bytes against $SourceLength bytes at the source, so it did not arrive intact"
    }
    $Elapsed = (Get-Date) - $Started
    $SpeedMB = if ($Elapsed.TotalSeconds -gt 0) { ($SourceLength / 1MB) / $Elapsed.TotalSeconds } else { 0 }
    Write-HostTimestamp ('  Copied {0:N2} GB in {1} ({2:N0} MB/s).' -f ($SourceLength / 1GB), (Format-Duration $Elapsed), $SpeedMB) -ForegroundColor DarkGray
}

# Downloads a file with BITS when available (resumable, shows progress) and falls back to
# Invoke-WebRequest. Returns $true on success. Never throws.
function Get-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    # The final name only appears once the file is complete, because later runs reuse whatever exists under it.
    $Partial = "$Destination.partial"
    Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue

    # Prefer BITS: it is resumable and far more reliable for multi-GB downloads.
    # Under a scheduled task running as another user, BITS jobs fail to enqueue and this falls through to Invoke-WebRequest below.
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        $Job = $null
        $Progress = $null
        try {
            Write-HostTimestamp '  Downloading with BITS...'
            # Started in the background and polled, so the bytes transferred can be shown as it goes.
            $Job = Start-BitsTransfer -Source $Url -Destination $Partial -Description 'Windows download' -Asynchronous -ErrorAction Stop
            $Progress = New-ProgressLine -Indent 24
            $LastBytes = [long]-1
            $Idle = [System.Diagnostics.Stopwatch]::StartNew()
            while ($Job.JobState -in 'Queued', 'Connecting', 'Transferring', 'TransientError') {
                $Done = [long]$Job.BytesTransferred
                $Total = $Job.BytesTotal
                # The total reads as the largest 64-bit number until the server has said how big the file is.
                if ($Total -gt 0 -and $Total -lt [uint64]::MaxValue) {
                    $Detail = Format-ByteProgress -Done $Done -Total ([long]$Total) -Elapsed ((Get-Date) - $Progress.Start)
                    Update-ProgressLine -State $Progress -Percent ([int][math]::Floor(100 * $Done / $Total)) -Detail $Detail
                }
                # BITS keeps retrying a dead connection for days, so give up on one that has gone quiet and
                # let the direct download below have a go.
                if ($Done -ne $LastBytes) { $LastBytes = $Done; $Idle.Restart() }
                elseif ($Idle.Elapsed.TotalMinutes -ge 5) { throw "no data arrived for 5 minutes (BITS state: $($Job.JobState))" }
                Start-Sleep -Milliseconds 500
            }
            Clear-ProgressLine -State $Progress
            if ($Job.JobState -ne 'Transferred') { throw "the job stopped in state $($Job.JobState): $("$($Job.ErrorDescription)".Trim())" }
            Complete-BitsTransfer -BitsJob $Job -ErrorAction Stop
            $Job = $null
            Move-Item -LiteralPath $Partial -Destination $Destination -Force -ErrorAction Stop
            return $true
        }
        catch {
            if ($Progress) { Clear-ProgressLine -State $Progress }
            if ($Job) { Remove-BitsTransfer -BitsJob $Job -ErrorAction SilentlyContinue; $Job = $null }
            Write-HostTimestamp "  BITS transfer failed ($($_.Exception.Message)). Falling back to a direct download..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
        }
        finally {
            # Reached with a job still set only when the run is stopped mid-download (Ctrl+C), which would
            # otherwise leave BITS fetching a file nobody will collect.
            if ($Progress) { Clear-ProgressLine -State $Progress }
            if ($Job) { Remove-BitsTransfer -BitsJob $Job -ErrorAction SilentlyContinue }
        }
    }

    # Fallback: Invoke-WebRequest. Slower and not resumable, but dependency-free.
    try {
        Write-HostTimestamp '  Downloading with Invoke-WebRequest...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Partial -UseBasicParsing -ErrorAction Stop
        Move-Item -LiteralPath $Partial -Destination $Destination -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-HostTimestamp "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
    }
    return $false
}

# Catalog packages carry their own SHA-1 in the file name (name_<40 hex>.msu), which proves the file is whole.
# A name without one falls back to the signature. An unsigned result passes there, since not every older
# package is embedded-signed and DISM still checks the package when it is added.
function Test-UpdatePackageFile {
    param([Parameter(Mandatory)][string]$Path)

    if ((Split-Path -Leaf $Path) -match '_([0-9a-fA-F]{40})\.(msu|cab)$') {
        $Expected = $Matches[1]
        return ((Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash -eq $Expected)
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -eq 'Valid') { return ($Signature.SignerCertificate.Subject -match 'O=Microsoft Corporation') }
    return ($Signature.Status -ne 'HashMismatch')
}

# Verifies a download URL points at an official Microsoft-owned host over HTTPS, so the script never
# downloads content from somewhere it should not. Microsoft serves ISOs and updates from hosts under
# microsoft.com, windowsupdate.com, and delivery.mp.microsoft.com. Returns $true only for an https:// URL
# whose host is one of those domains or a subdomain of them. Using the parsed Host (not a substring of
# the raw URL) avoids spoofing like "microsoft.com.evil.example".
function Test-MicrosoftDownloadUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    try { $Uri = [Uri]$Url } catch { return $false }
    if ($Uri.Scheme -ne 'https') { return $false }
    return ($Uri.Host -match '(?i)(^|\.)(microsoft\.com|windowsupdate\.com)$')
}

# Verifies the Fido helper is being fetched from the official pbatard/Fido repository on GitHub over
# HTTPS. Fido is downloaded and then executed, so a URL pointing anywhere else is arbitrary code
# execution. The parsed Host and path are checked (not a substring of the raw URL) so lookalikes such as
# "github.com.evil.example" or "/evil/pbatard/Fido/" are rejected.
function Test-FidoUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    try { $Uri = [Uri]$Url } catch { return $false }
    if ($Uri.Scheme -ne 'https') { return $false }
    if ($Uri.Host -notin @('github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com', 'codeload.github.com')) { return $false }
    return ($Uri.AbsolutePath -match '(?i)^/pbatard/Fido/')
}

# Validates a downloaded Fido.ps1 BEFORE it is executed. Fido is not code-signed, so there is no
# signature to check, so instead this confirms the file really is Fido and contains nothing that Fido has
# any business doing. Checks, in order: the pinned SHA-256 (-FidoSha256), a sane file size, that
# it parses as PowerShell, that it carries Fido's header and -GetUrl parameter, and that it invokes no
# code-execution, persistence or security-tampering commands. Parsing only builds an AST - it never runs
# the script. Returns $true if the file passes.
function Test-FidoScript {
    param([Parameter(Mandatory)][string]$Path)

    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    Write-HostTimestamp "  Fido SHA-256: $Hash"
    if ($FidoSha256) {
        if ($Hash -ne $FidoSha256.Trim()) {
            Write-HostTimestamp "  Fido does not match the pinned SHA-256 ($($FidoSha256.Trim())). Refusing to run it." -ForegroundColor Red
            return $false
        }
        Write-HostTimestamp '  Fido matches the pinned SHA-256.' -ForegroundColor Green
    }

    # A 404/HTML error page or a truncated download is nothing like the real ~55 KB script.
    $Size = (Get-Item -LiteralPath $Path).Length
    if ($Size -lt 20KB -or $Size -gt 1MB) {
        Write-HostTimestamp "  The downloaded Fido helper is $Size bytes, which is not a plausible size for Fido.ps1. Refusing to run it." -ForegroundColor Red
        return $false
    }

    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$ParseErrors)
    if ($ParseErrors) {
        Write-HostTimestamp "  The downloaded Fido helper is not valid PowerShell ($($ParseErrors.Count) parse error(s)). Refusing to run it." -ForegroundColor Red
        return $false
    }

    $Text = Get-Content -LiteralPath $Path -Raw
    if ($Text -notmatch '(?im)^#\s*Fido\s+v[\d.]+' -or $Text -notmatch '(?i)Copyright[^\r\n]*Pete Batard') {
        Write-HostTimestamp '  The downloaded file does not look like Fido (its header and copyright notice are missing). Refusing to run it.' -ForegroundColor Red
        return $false
    }

    $ParamNames = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if ('GetUrl' -notin $ParamNames) {
        Write-HostTimestamp '  The downloaded Fido helper does not declare the -GetUrl parameter this script relies on. Refusing to run it.' -ForegroundColor Red
        return $false
    }

    # Fido resolves and downloads ISOs, so it never needs to run generated code, spawn shells, install
    # services or scheduled tasks, or touch the registry, boot configuration or Defender.
    $Banned = @(
        'Invoke-Expression', 'iex', 'Set-ExecutionPolicy', 'Register-ScheduledTask', 'schtasks', 'schtasks.exe',
        'New-Service', 'Set-Service', 'sc.exe', 'Add-MpPreference', 'Set-MpPreference', 'New-LocalUser',
        'Add-LocalGroupMember', 'reg', 'reg.exe', 'regedit', 'regedit.exe', 'regsvr32', 'regsvr32.exe',
        'bcdedit', 'bcdedit.exe', 'certutil', 'certutil.exe', 'bitsadmin', 'bitsadmin.exe', 'mshta', 'mshta.exe',
        'rundll32', 'rundll32.exe', 'wmic', 'wmic.exe', 'vssadmin', 'vssadmin.exe', 'diskpart', 'diskpart.exe',
        'cmd', 'cmd.exe', 'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe',
        'msiexec', 'msiexec.exe', 'wscript', 'wscript.exe', 'cscript', 'cscript.exe',
        'msbuild', 'msbuild.exe', 'installutil', 'installutil.exe', 'regasm', 'regasm.exe',
        'regsvcs', 'regsvcs.exe'
    )
    $Used = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
    $Hits = @($Used | Where-Object { $Banned -contains $_ } | Sort-Object -Unique)
    if ($Hits.Count -gt 0) {
        Write-HostTimestamp "  The downloaded Fido helper calls commands Fido has no reason to use: $($Hits -join ', '). Refusing to run it." -ForegroundColor Red
        return $false
    }

    # Catch the same thing hidden behind obfuscation rather than a plain command call.
    if ($Text -match '(?i)FromBase64String|-\s*Encoded\s*Command|\benc\b\s+[A-Za-z0-9+/=]{40,}') {
        Write-HostTimestamp '  The downloaded Fido helper contains encoded/obfuscated code. Refusing to run it.' -ForegroundColor Red
        return $false
    }

    return $true
}
#endregion

