#region Getting the ISO
# Uses the community "Fido" helper (which queries Microsoft's own software-download servers) to resolve
# the official, matching Windows ISO download URL. The helper is fetched only from the official GitHub
# repository, validated before it runs (see Test-FidoScript), then run out-of-process with -GetUrl so it
# cannot touch this script's session. Returns the resulting URL string, or $null on failure. The
# resolved URL is verified to point at an official Microsoft host before being returned.
# Fido: https://github.com/pbatard/Fido
function Get-WindowsIsoUrl {
    param(
        [Parameter(Mandatory)][string]$Version,       # 10 or 11
        [Parameter(Mandatory)][string]$Release,        # e.g. Latest, 25H2
        [Parameter(Mandatory)][string]$Language,       # e.g. English
        [Parameter(Mandatory)][string]$Architecture    # x64 / arm64 / x86
    )

    if (-not (Test-FidoUrl -Url $FidoUrl)) {
        Write-HostTimestamp "  The Fido URL does not point at the official https://github.com/pbatard/Fido repository. Refusing to download and run it: $FidoUrl" -ForegroundColor Red
        Write-HostTimestamp '  Download an ISO yourself and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
        return $null
    }

    $FidoScript = Join-Path -Path $env:TEMP -ChildPath "Fido_$(Get-Date -Format 'yyyyMMdd_HHmmss').ps1"
    Write-HostTimestamp '  Fetching the Fido download helper from GitHub...'
    if (-not (Get-FileDownload -Url $FidoUrl -Destination $FidoScript)) {
        Write-HostTimestamp '  Could not download the Fido helper. Provide an ISO manually with -IsoPath instead.' -ForegroundColor Red
        return $null
    }

    if (-not (Test-FidoScript -Path $FidoScript)) {
        Remove-Item -LiteralPath $FidoScript -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Download an ISO yourself and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
        return $null
    }
    Write-HostTimestamp '  Verified the Fido helper came from the official repository and passed its content checks.' -ForegroundColor Green

    Write-HostTimestamp "  Asking Microsoft (via Fido) for the Windows $Version ($Release, $Language, $Architecture) ISO link..."
    $Url = $null
    $Output = $null
    $FidoExit = $null
    $Attempts = $FidoRetryCount + 1
    try {
        for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
            if ($Attempt -gt 1) {
                # Microsoft's anti-bot check ("Sentinel") rejects bursts of requests but usually lets a
                # later one through, and Fido starts a fresh session each time, so backing off is worth it.
                $Wait = [Math]::Min(120, 20 * [Math]::Pow(3, $Attempt - 2))
                Write-HostTimestamp "  Attempt $($Attempt - 1) of $Attempts failed. Waiting $Wait seconds before retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds $Wait
                Write-HostTimestamp "  Retrying (attempt $Attempt of $Attempts)..."
            }

            $Output = $null
            $FidoExit = $null
            try {
                # -GetUrl makes Fido print only the resolved download URL and exit, without downloading anything.
                $FidoArgs = @{
                    Win    = $Version
                    Rel    = $Release
                    Lang   = $Language
                    Arch   = $Architecture
                    GetUrl = $true
                }
                if ($VerbosePreference -ne 'SilentlyContinue') { $FidoArgs['Verbose'] = $true }

                # Prefer running Fido in its own Windows PowerShell process: it keeps third-party code out of
                # this session, and Fido targets Windows PowerShell.
                $WinPs = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (Test-Path -LiteralPath $WinPs) {
                    $ChildArgs = @(
                        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $FidoScript,
                        '-Win', $Version, '-Rel', $Release, '-Lang', $Language, '-Arch', $Architecture, '-GetUrl'
                    )
                    if ($VerbosePreference -ne 'SilentlyContinue') { $ChildArgs += '-Verbose' }
                    $Output = & $WinPs @ChildArgs 2>&1
                    $FidoExit = $LASTEXITCODE
                }
                else {
                    $Output = & $FidoScript @FidoArgs 2>&1
                }
                $Url = ($Output | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1)
                if ($Url) { $Url = $Url.ToString().Trim(); break }
            }
            catch {
                Write-HostTimestamp "  Fido could not resolve a download URL: $($_.Exception.Message)" -ForegroundColor Red
            }

            $Reason = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '(?i)^error' }) | Select-Object -Last 1
            if ($Reason) { Write-HostTimestamp "  Fido: $Reason" -ForegroundColor Yellow }
        }
    }
    finally {
        Remove-Item -LiteralPath $FidoScript -Force -ErrorAction SilentlyContinue
    }

    if (-not $Url) {
        Write-HostTimestamp "  Fido did not return a download URL after $Attempts attempt(s). Microsoft may have changed its download page, throttled this IP address, or the requested release/language is unavailable." -ForegroundColor Red

        # Fido explains the real reason on its own output (rate limiting, unknown release, HTTP errors), so
        # show it rather than leaving the user with only the generic message above.
        $Lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($Lines.Count -gt 0) {
            Write-HostTimestamp "  Fido reported$(if ($null -ne $FidoExit) { " (exit code $FidoExit)" }):" -ForegroundColor Yellow
            $Lines | Select-Object -Last 25 | ForEach-Object { Write-HostTimestamp "    $_" -ForegroundColor Gray }
        }
        else {
            Write-HostTimestamp "  Fido produced no output$(if ($null -ne $FidoExit) { " (exit code $FidoExit)" })." -ForegroundColor Yellow
        }

        Write-HostTimestamp '  Re-run this script with -Verbose to get Fido''s full diagnostics.' -ForegroundColor Yellow
        Write-HostTimestamp '  "Sentinel marked this request as rejected" or a "715-123130" error means Microsoft''s anti-bot check refused the request - usually because this IP address has asked for ISO links too often. Wait a while, try a different network, or just download the ISO yourself.' -ForegroundColor Yellow
        Write-HostTimestamp '  Microsoft''s Media Creation Tool uses different servers and usually still works - re-run with -UseMct to have this script open it for you.' -ForegroundColor Yellow
        Write-HostTimestamp '  Download an ISO yourself and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
        return $null
    }

    if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
        $BadHost = try { ([Uri]$Url).Host } catch { '(unparseable)' }
        Write-HostTimestamp "  The resolved download URL does not point at an official Microsoft host (host: $BadHost). Refusing to download it." -ForegroundColor Red
        return $null
    }
    Write-HostTimestamp "  Verified the ISO download comes from an official Microsoft host: $(([Uri]$Url).Host)" -ForegroundColor Green
    return $Url
}

# Translates the Fido-style language name (-Language) into the locale code the Media Creation Tool wants
# for /MediaLangCode. Falls back to en-US when the name cannot be matched.
function Get-MctLanguageCode {
    param([Parameter(Mandatory)][string]$Name)

    if ($MctLangCode) { return $MctLangCode }

    # Names where Microsoft's ISO list and .NET's culture names disagree, or where the generic lookup
    # below would pick the wrong region.
    switch -Regex ($Name) {
        '(?i)^english international$'          { return 'en-GB' }
        '(?i)^english$'                        { return 'en-US' }
        '(?i)^chinese.*simplified'             { return 'zh-CN' }
        '(?i)^chinese.*traditional'            { return 'zh-TW' }
        '(?i)^(brazilian portuguese|portuguese \(brazil\))$' { return 'pt-BR' }
        '(?i)^portuguese( \(portugal\))?$'     { return 'pt-PT' }
        '(?i)^spanish \(mexico\)$'             { return 'es-MX' }
        '(?i)^serbian latin$'                  { return 'sr-Latn-RS' }
    }

    # Otherwise resolve the language name to its neutral culture and take that culture's default region
    # (e.g. French -> fr -> fr-FR), which matches how Microsoft names its media.
    $Neutral = [System.Globalization.CultureInfo]::GetCultures('NeutralCultures') |
        Where-Object { $_.EnglishName -eq $Name } | Select-Object -First 1
    if ($Neutral) {
        try { return [System.Globalization.CultureInfo]::CreateSpecificCulture($Neutral.Name).Name } catch { }
    }

    Write-HostTimestamp "  Could not map the language '$Name' to a Media Creation Tool locale code, so en-US is used. Override it with -MctLangCode." -ForegroundColor Yellow
    return 'en-US'
}

# Fallback for when Fido cannot get a link (usually because Microsoft's anti-bot check blocked this IP):
# downloads Microsoft's own Media Creation Tool and runs it. MCT has no switch to choose ISO output or a
# target path, so it cannot be driven headlessly - the user clicks through the wizard and saves the ISO
# into the download folder, which this function then picks up. Returns the ISO path, or $null.
function Get-IsoViaMct {
    param(
        [Parameter(Mandatory)][string]$Version,        # 10 or 11
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][string]$DownloadDir
    )

    # Microsoft's permanent fwlinks for the Media Creation Tool on the software-download pages.
    $Url = if ($MctUrl) { $MctUrl } elseif ($Version -eq '10') { 'https://go.microsoft.com/fwlink/?LinkId=691209' } else { 'https://go.microsoft.com/fwlink/?linkid=2156295' }
    if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
        Write-HostTimestamp "  The Media Creation Tool URL is not an official Microsoft URL. Refusing to download it: $Url" -ForegroundColor Red
        return $null
    }

    $Mct = Join-Path -Path $DownloadDir -ChildPath "MediaCreationTool_$(Get-Date -Format 'yyyyMMdd_HHmmss').exe"
    Write-HostTimestamp '  Downloading the Media Creation Tool from Microsoft...'
    if (-not (Get-FileDownload -Url $Url -Destination $Mct)) {
        Write-HostTimestamp '  Could not download the Media Creation Tool.' -ForegroundColor Red
        return $null
    }

    # Unlike Fido and oscdimg, MCT is Authenticode signed, so require a valid Microsoft signature.
    $Signature = Get-AuthenticodeSignature -LiteralPath $Mct -ErrorAction SilentlyContinue
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(?i)O=Microsoft Corporation') {
        Write-HostTimestamp "  The downloaded Media Creation Tool is not validly signed by Microsoft (status: $($Signature.Status)). Discarding it." -ForegroundColor Red
        Remove-Item -LiteralPath $Mct -Force -ErrorAction SilentlyContinue
        return $null
    }
    Write-HostTimestamp '  Verified the Media Creation Tool''s Microsoft signature.' -ForegroundColor Green

    $MctArch = switch ($Architecture) { 'arm64' { 'ARM64' } 'x86' { 'x86' } default { 'x64' } }
    $LangCode = Get-MctLanguageCode -Name $Language
    # Driving MCT with its channel/edition switches puts it in the "enter your product key" flow, so the
    # plain wizard is used unless -MctPreselect asks for the pre-filled one.
    $MctArgs = @('/Eula', 'Accept')
    if ($MctPreselect) {
        $MctArgs += @('/Retail', '/MediaArch', $MctArch, '/MediaLangCode', $LangCode)
        if ($MctEdition) { $MctArgs += @('/MediaEdition', $MctEdition) }
    }

    Write-Host ''
    if ($MctPreselect) {
        Write-HostLog 'The Media Creation Tool is about to open with your choices pre-selected:' -ForegroundColor Cyan
        Write-HostLog "  Windows $Version, $MctArch, $LangCode, $(if ($MctEdition) { $MctEdition } else { 'all editions' })"
        Write-Host ''
        Write-HostLog 'If it asks for a product key, enter one of Microsoft''s published generic edition-selection' -ForegroundColor Yellow
        Write-HostLog 'keys (Pro is VK7JG-NPHTM-C97JM-9MPGT-3V66T), or re-run without -MctPreselect to get the' -ForegroundColor Yellow
        Write-HostLog 'ordinary wizard, which never asks for one.' -ForegroundColor Yellow
        Write-Host ''
    }
    else {
        Write-HostLog 'The Media Creation Tool is about to open. Asked for these in its window:' -ForegroundColor Cyan
        Write-HostLog "  Windows $Version, $MctArch, $LangCode, all editions"
        Write-Host ''
    }
    Write-HostLog 'It cannot be automated any further - Microsoft provides no switch to pick ISO output or a' -ForegroundColor Yellow
    Write-HostLog 'save location - so in its window please:' -ForegroundColor Yellow
    Write-HostLog '  1. Accept the licence terms if prompted.'
    Write-HostLog '  2. Choose "Create installation media (USB flash drive, DVD, or ISO file) for another PC".'
    Write-HostLog "  3. Set the language and architecture ($LangCode, $MctArch), or leave the recommended options ticked."
    Write-HostLog '  4. Choose "ISO file".'
    Write-HostLog "  5. Save it into this folder: $DownloadDir" -ForegroundColor Green
    Write-HostLog '  6. Let the download finish, then click Finish.'
    Write-Host ''
    Write-HostLog 'This script waits until the Media Creation Tool closes, then continues on its own.' -ForegroundColor Cyan
    Write-Host ''
    if ($Unattended -or $SkipInteractive) {
        Write-HostTimestamp '  Note: the Media Creation Tool has no unattended ISO mode, so this step needs someone at the keyboard.' -ForegroundColor Yellow
    }

    $Existing = @(Get-ChildItem -Path $DownloadDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    try {
        Write-HostTimestamp '  Waiting for the Media Creation Tool to finish...'
        Start-Process -FilePath $Mct -ArgumentList $MctArgs -Wait -ErrorAction Stop | Out-Null
    }
    catch {
        Write-HostTimestamp "  The Media Creation Tool could not be started: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    finally {
        Remove-Item -LiteralPath $Mct -Force -ErrorAction SilentlyContinue
    }

    # Prefer an ISO that was not there before MCT ran, otherwise take the largest one in the folder.
    $Iso = Get-ChildItem -Path $DownloadDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 3GB -and $Existing -notcontains $_.FullName } |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if (-not $Iso) {
        $Iso = Get-ChildItem -Path $DownloadDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 3GB } | Sort-Object -Property Length -Descending | Select-Object -First 1
    }
    if ($Iso) {
        Write-HostTimestamp "  Found the ISO the Media Creation Tool produced: $($Iso.FullName) ($([math]::Round($Iso.Length / 1GB, 2)) GB)" -ForegroundColor Green
        return $Iso.FullName
    }

    Write-HostTimestamp "  No ISO turned up in $DownloadDir." -ForegroundColor Yellow
    if ($Unattended -or $SkipInteractive) { return $null }
    $Answer = Read-Host 'If you saved it somewhere else, enter the full path to the ISO now (or press Enter to cancel)'
    if ($Answer -and (Test-Path -LiteralPath $Answer.Trim('"'))) { return (Resolve-Path -LiteralPath $Answer.Trim('"')).Path }
    return $null
}

# Picks the Windows ISO out of a folder: by default the most recently modified .iso over 3 GB, so a fresh
# drop-in wins over an older one sitting next to it; -Largest instead picks by size, e.g. to prefer a full
# retail image over a smaller trial ISO with a newer timestamp. Anything under 3 GB is skipped so driver
# discs and other small images sharing the folder are ignored. Not recursive, because an ISO library is
# usually one folder deep and walking a whole drive to guess would be worse than being told.
function Find-SourceIso {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(HelpMessage = 'Pick the largest .iso instead of the most recently modified one')]
        [switch]$Largest
    )
    $Candidates = Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 3GB }
    if ($Largest) {
        return ($Candidates | Sort-Object -Property Length -Descending | Select-Object -First 1)
    }
    return ($Candidates | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1)
}
#endregion

