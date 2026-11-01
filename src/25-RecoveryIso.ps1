#region Recovery ISO
# Builds the recovery ISO from a recovery image and a folder holding the media's boot files. The media's BCD
# boots whatever sits at \sources\boot.wim, so the recovery image placed there beside those boot files is a
# complete recovery disc with no Setup screen in front of it. Returns the path of the finished ISO.
function New-RecoveryIso {
    param(
        [Parameter(Mandatory)][string]$WinReWim,
        [Parameter(Mandatory)][string]$BootSource,
        [string]$BootManagerDir,
        [int]$Build,
        [string]$Architecture
    )

    $RecoveryRoot = Join-Path -Path $RecoveryMediaDir -ChildPath 'ISO'
    if (Test-Path -LiteralPath $RecoveryRoot) { Remove-Item -LiteralPath $RecoveryRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path (Join-Path $RecoveryRoot 'sources') -Force -ErrorAction Stop | Out-Null
    # Boot files only, so an answer file holding passwords never lands on media meant for handing out.
    foreach ($Name in 'boot', 'efi', 'bootmgr', 'bootmgr.efi') {
        $From = Join-Path -Path $BootSource -ChildPath $Name
        if (Test-Path -LiteralPath $From) { Copy-Item -LiteralPath $From -Destination $RecoveryRoot -Recurse -Force -ErrorAction Stop }
    }
    # Copied off read-only media, and the boot managers below have to be replaceable.
    Get-ChildItem -LiteralPath $RecoveryRoot -Recurse -Force -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }

    # Matched to the serviced recovery image, the same way a full build matches the media's to boot.wim.
    if ($BootManagerDir) {
        foreach ($File in @(Get-ChildItem -LiteralPath $RecoveryRoot -Recurse -Force -Filter 'b*.efi' -File -ErrorAction SilentlyContinue)) {
            $Source = switch -Regex ($File.Name) {
                '^(bootmgfw|bootx64|bootia32|bootaa64)\.efi$' { Join-Path -Path $BootManagerDir -ChildPath 'bootmgfw.efi' }
                '^bootmgr\.efi$' { Join-Path -Path $BootManagerDir -ChildPath 'bootmgr.efi' }
                default { $null }
            }
            if ($Source -and (Test-Path -LiteralPath $Source)) { Copy-Item -LiteralPath $Source -Destination $File.FullName -Force -ErrorAction Stop }
        }
    }

    Write-HostTimestamp '  Placing the recovery image where the media boots from (sources\boot.wim)...'
    Export-WindowsImage -SourceImagePath $WinReWim -SourceIndex 1 -DestinationImagePath (Join-Path $RecoveryRoot 'sources\boot.wim') -CompressionType Max -Setbootable -ErrorAction Stop | Out-Null

    $Re = Get-WinReVersion -WinReWim $WinReWim
    $WindowsTag =
        if ($script:EffectiveServer) { Get-ServerReleaseName -Build $Build }
        elseif ($Build -ge 22000) { 'Win11' }
        elseif ($Build -gt 0) { 'Win10' }
        else { 'Windows' }
    $NameParts = @($WindowsTag, 'Recovery', ($Architecture -replace '[^A-Za-z0-9]', ''))
    if ($Re) { $NameParts += "$($Re.Build).$($Re.Ubr)" }
    $RecoveryName = ((@($NameParts) + (Get-Date -Format 'yyyyMMdd-HHmm')) -join '_') + '.iso'
    $Target = if ($RecoveryIsoFile) { $RecoveryIsoFile } else { Join-Path -Path $RecoveryIsoDir -ChildPath $RecoveryName }
    # Same 32-character rule as the main label, and the architecture is the first thing to go.
    $Label = ($NameParts -join '_').ToUpperInvariant() -replace '[^A-Z0-9]', '_'
    if ($Label.Length -gt 32) { $Label = $Label -replace '_(X64|X86|ARM64|AMD64)_', '_' }
    if ($Label.Length -gt 32) { $Label = $Label.Substring(0, 32) }
    $Label = $Label.Trim('_')

    # Built locally and copied over for the same reason as the main ISO.
    $TargetIsRemote = Test-RemotePath -Path (Split-Path -Path $Target -Parent)
    $BuildTarget = $Target
    if ($TargetIsRemote) {
        New-Item -ItemType Directory -Path $IsoStageDir -Force -ErrorAction SilentlyContinue | Out-Null
        $BuildTarget = Join-Path -Path $IsoStageDir -ChildPath (Split-Path -Leaf $Target)
    }
    if (Test-Path -LiteralPath $BuildTarget) { Remove-Item -LiteralPath $BuildTarget -Force -ErrorAction SilentlyContinue }

    $BootData = Get-OscdimgBootData -MediaRoot $RecoveryRoot
    if (-not $BootData) { throw 'the media has no boot sectors, so a recovery ISO built from it would not boot' }
    $RecoveryArgs = @('-m', '-o', '-u2', '-udfver102', "-l$Label", "-bootdata:$BootData", $RecoveryRoot, $BuildTarget)
    Write-HostTimestamp "  Running: `"$Oscdimg`" $($RecoveryArgs -join ' ')" -ForegroundColor DarkGray
    $Proc = Start-Process -FilePath $Oscdimg -ArgumentList $RecoveryArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
    if ($Proc.ExitCode -ne 0) { throw "oscdimg returned exit code $($Proc.ExitCode)" }
    if (-not (Test-Path -LiteralPath $BuildTarget)) { throw 'oscdimg reported success but no ISO was written' }
    if ($TargetIsRemote) {
        Copy-LargeFile -Path $BuildTarget -Destination $Target
        Remove-Item -LiteralPath $BuildTarget -Force -ErrorAction SilentlyContinue
    }

    Write-HostTimestamp ('  Recovery ISO created ({0:N0} MB, volume label {1}).' -f ((Get-Item -LiteralPath $Target).Length / 1MB), $Label) -ForegroundColor Green
    if ($Re) { Write-HostTimestamp "  It boots the recovery environment at $($Re.Version)." -ForegroundColor DarkGray }
    return $Target
}

# Keeps the newest generated recovery ISOs in a folder and deletes the rest. No stamp records them, so only
# names this script generates are candidates, and a file path the user chose is overwritten each build anyway.
# Returns how many went and how much space that freed, for -AutoClean's summary.
function Remove-StaleRecoveryIso {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$KeepCount = 3,
        [string[]]$Protected
    )

    $ProtectedPaths = @(@($Protected) | Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\').ToLowerInvariant() })
    $RecoveryName = '^(Win10|Win11|Windows|WinSrv[A-Za-z0-9]*)_Recovery_[A-Za-z0-9]+(_[\d.]+)?_\d{8}-\d{4}\.iso$'
    $RecoveryIsos = @(Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $RecoveryName } |
        Sort-Object -Property LastWriteTime -Descending)
    if ($RecoveryIsos.Count -gt 0) {
        Write-HostTimestamp "  Found $($RecoveryIsos.Count) generated recovery ISO(s), keeping the newest $KeepCount." -ForegroundColor DarkGray
    }

    $Removed = 0
    $FreedMB = 0
    foreach ($Item in @($RecoveryIsos | Select-Object -Skip $KeepCount | Where-Object { $ProtectedPaths -notcontains $_.FullName.ToLowerInvariant() })) {
        try {
            $SizeMB = $Item.Length / 1MB
            Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
            $Removed++
            $FreedMB += $SizeMB
            Write-HostTimestamp ('  Deleted old recovery ISO: {0} ({1:N0} MB)' -f $Item.Name, $SizeMB) -ForegroundColor DarkGray
        }
        catch { Write-HostTimestamp "  Could not delete '$($Item.FullName)': $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($Removed -eq 0) { Write-HostTimestamp '  No old recovery ISOs to remove.' -ForegroundColor DarkGray }
    return [pscustomobject]@{ Removed = $Removed; FreedMB = $FreedMB }
}
#endregion
#endregion

