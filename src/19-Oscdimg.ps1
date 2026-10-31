#region oscdimg and the ADK
# Locates oscdimg.exe (from the Windows ADK Deployment Tools), which is required to recompile the ISO.
# Checks -OscdimgPath, a previously downloaded copy in the work folder, then PATH, then the standard ADK
# install locations. Returns the full path or $null.
function Find-Oscdimg {
    if ($OscdimgPath -and (Test-Path -LiteralPath $OscdimgPath)) { return (Resolve-Path -LiteralPath $OscdimgPath).Path }

    if (Test-Path -LiteralPath $OscdimgLocalPath) { return (Resolve-Path -LiteralPath $OscdimgLocalPath).Path }

    $OnPath = Get-Command 'oscdimg.exe' -ErrorAction SilentlyContinue
    if ($OnPath) { return $OnPath.Source }

    $Roots = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    ) | Where-Object { $_ }
    foreach ($Root in $Roots) {
        $Base = Join-Path $Root 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
        if (Test-Path $Base) {
            $Found = Get-ChildItem -Path $Base -Filter 'oscdimg.exe' -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($Found) { return $Found.FullName }
        }
    }
    return $null
}

# Downloads a standalone oscdimg.exe from Microsoft's public symbol server (msdl.microsoft.com), which
# hosts the binary indexed by its PE TimeDateStamp + SizeOfImage - the technique described at
# https://pete.akeo.ie/2025/06/downloading-oscdimgexe-from-microsoft.html. This avoids installing the
# multi-hundred-MB Windows ADK just to get one ~140 KB executable. The symbol server only returns the
# file when the request carries a symbol-client User-Agent, so one is set explicitly. Because the URL
# pins one exact build, the download is verified against a known SHA-256 (the binary itself is not
# Authenticode signed) as well as its Microsoft version resource.
# Returns the path to the downloaded oscdimg.exe, or $null on failure.
function Get-OscdimgDownload {
    if (-not (Test-MicrosoftDownloadUrl -Url $OscdimgUrl)) {
        Write-HostTimestamp "  The oscdimg URL is not an official Microsoft URL. Refusing to download it: $OscdimgUrl" -ForegroundColor Red
        return $null
    }

    $ToolsDir = Split-Path -Parent $OscdimgLocalPath
    try {
        if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null }
    }
    catch {
        Write-HostTimestamp "  Could not create the tools folder '$ToolsDir': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $Temp = "$OscdimgLocalPath.download"
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    Write-HostTimestamp "  Downloading oscdimg.exe from the Microsoft symbol server: $OscdimgUrl"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $OscdimgUrl -OutFile $Temp -UseBasicParsing -UserAgent 'Microsoft-Symbol-Server/10.0.0.0' -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    if (-not (Test-Path -LiteralPath $Temp)) {
        Write-HostTimestamp '  The symbol server did not return a file.' -ForegroundColor Red
        return $null
    }

    # The symbol server answers a miss with a small HTML/text body, so confirm this really is a PE image.
    # Read the two "MZ" header bytes directly - Get-Content's byte switch differs between PS 5 and 7.
    $IsExe = $false
    try {
        $Stream = [System.IO.File]::OpenRead($Temp)
        try {
            $Header = New-Object byte[] 2
            $IsExe = ($Stream.Read($Header, 0, 2) -eq 2 -and $Header[0] -eq 0x4D -and $Header[1] -eq 0x5A)
        }
        finally { $Stream.Dispose() }
    }
    catch { }
    if (-not $IsExe) {
        Write-HostTimestamp '  The downloaded file is not a Windows executable. Discarding it.' -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Only trust a binary that matches the pinned hash for this exact build. If the URL was overridden
    # (so the hash cannot match), fall back to checking the file's Microsoft version resource.
    if ($OscdimgSha256) {
        $Hash = (Get-FileHash -LiteralPath $Temp -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($Hash -ne $OscdimgSha256) {
            Write-HostTimestamp "  The downloaded oscdimg.exe does not match the expected SHA-256 (got $Hash). Discarding it." -ForegroundColor Red
            Write-HostTimestamp '  If you deliberately pointed -OscdimgUrl at a different build, pass the matching -OscdimgSha256 (or an empty string to skip this check).' -ForegroundColor Yellow
            Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
            return $null
        }
    }
    elseif ((Get-Item -LiteralPath $Temp).VersionInfo.CompanyName -notmatch '(?i)Microsoft') {
        Write-HostTimestamp '  The downloaded file is not a Microsoft binary. Discarding it.' -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    try {
        Move-Item -LiteralPath $Temp -Destination $OscdimgLocalPath -Force -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not save oscdimg.exe to '$OscdimgLocalPath': $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Clear the Mark of the Web so the downloaded binary is not blocked when it runs.
    Unblock-File -LiteralPath $OscdimgLocalPath -ErrorAction SilentlyContinue
    return $OscdimgLocalPath
}

# Downloads the Windows ADK bootstrapper and silently installs ONLY the Deployment Tools feature (which
# contains oscdimg.exe). Returns the oscdimg path on success, or $null.
function Install-AdkDeploymentTools {
    if (-not (Test-MicrosoftDownloadUrl -Url $AdkSetupUrl) -and $AdkSetupUrl -notmatch '(?i)^https://go\.microsoft\.com/') {
        Write-HostTimestamp "  The ADK setup URL is not an official Microsoft URL. Refusing to download it: $AdkSetupUrl" -ForegroundColor Red
        return $null
    }

    $Setup = Join-Path -Path $env:TEMP -ChildPath "adksetup_$(Get-Date -Format 'yyyyMMdd_HHmmss').exe"
    Write-HostTimestamp '  Downloading the Windows ADK setup bootstrapper from Microsoft...'
    if (-not (Get-FileDownload -Url $AdkSetupUrl -Destination $Setup)) {
        Write-HostTimestamp '  Could not download the ADK setup bootstrapper.' -ForegroundColor Red
        return $null
    }

    $Signature = Get-AuthenticodeSignature -LiteralPath $Setup -ErrorAction SilentlyContinue
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(?i)O=Microsoft Corporation') {
        Write-HostTimestamp "  The downloaded ADK setup is not validly signed by Microsoft (status: $($Signature.Status)). Discarding it." -ForegroundColor Red
        Remove-Item -LiteralPath $Setup -Force -ErrorAction SilentlyContinue
        return $null
    }
    Write-HostTimestamp '  Verified the ADK setup bootstrapper carries a valid Microsoft signature.' -ForegroundColor Green

    Write-HostTimestamp '  Installing the ADK Deployment Tools silently (this downloads a few hundred MB and takes a few minutes)...'
    try {
        $Proc = Start-Process -FilePath $Setup -ArgumentList @('/quiet', '/norestart', '/features', 'OptionId.DeploymentTools') -Wait -PassThru -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Write-HostTimestamp "  ADK setup returned exit code $($Proc.ExitCode)." -ForegroundColor Yellow
        }
    }
    catch {
        Write-HostTimestamp "  ADK installation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    finally {
        Remove-Item -LiteralPath $Setup -Force -ErrorAction SilentlyContinue
    }

    return (Find-Oscdimg)
}
#endregion

