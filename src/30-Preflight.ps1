#region Run header
Write-Host $LineBreak
Write-HostTimestamp "Windows ISO Updater v$ScriptVersion (slipstream latest updates into a new ISO) on $($env:ComputerName)" -ForegroundColor Cyan
Write-HostTimestamp "Run date       : $(Get-FriendlyDate)"
if ($ConfigPath) {
    Write-HostTimestamp "Profile        : $ConfigPath"
    Write-HostTimestamp "  Settings applied from it: $(if ($script:ProfileValues.Count -gt 0) { @($script:ProfileValues.Keys) -join ', ' } else { 'none' })" -ForegroundColor DarkGray
}
# Recorded because culture-sensitive parsing (e.g. the catalog's "Last Updated" column) breaks only on
# non-en-US machines, so the log needs to say what locale actually ran without asking the reporter to check.
# Script-scoped so the build tattoo, written much later, can reuse this instead of reading it a second time.
$script:CurrentCulture   = [System.Globalization.CultureInfo]::CurrentCulture
$script:CurrentUICulture = [System.Globalization.CultureInfo]::CurrentUICulture
$script:SystemLocale     = try { (Get-WinSystemLocale -ErrorAction Stop).Name } catch { 'unknown' }
Write-HostTimestamp "Locale         : Thread culture $($script:CurrentCulture.Name), UI culture $($script:CurrentUICulture.Name), system locale $script:SystemLocale"
# The machine this run is on, so a log attached to an issue already says (see Get-EnvironmentReport).
foreach ($EnvLine in (Get-EnvironmentReport -WorkRoot $WorkRoot)) {
    $EnvText = '{0,-15}: {1}' -f $EnvLine.Label, $EnvLine.Value
    if ($EnvLine.Color -eq 'Gray') { Write-HostTimestamp $EnvText }
    else { Write-HostTimestamp $EnvText -ForegroundColor $EnvLine.Color }
}
if ($ServiceWinRE) {
    Write-HostTimestamp '-ServiceWinRE is deprecated and does nothing. The recovery image is serviced by default now, so pass -SkipWinRE to turn it off.' -ForegroundColor Yellow
}
if ($Server) {
    Write-HostTimestamp '-Server is deprecated and no longer needed. Server media is detected from the image itself, so -IsoPath pointed at a Server ISO (or one dropped into the download folder) is enough.' -ForegroundColor Yellow
}
if ($RecoveryIsoOnly) {
    if ($CheckOnly) {
        Write-HostTimestamp '-CheckOnly cannot be combined with -RecoveryIsoOnly, which keeps no build stamps to compare against.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $RecoveryIgnored = @('Edition', 'KeepEditions', 'KeepAllEditions', 'UpdatePath', 'SkipDotNet', 'SkipSetupDU', 'BaselineOnly',
        'VerifyPatchLevel', 'CompressEsd', 'FastCompression', 'ExcludeWorkPathFromDefender', 'UnattendPath', 'DriverPath', 'AllowUnsignedDrivers', 'ExtraFilesPath',
        'SkipTattoo', 'AnonymousTattoo', 'StripImageResidue', 'VolumeLabel', 'IsoNamePrefix', 'IsoNameSuffix', 'Force', 'NoStamp', 'StampPath') |
        Where-Object { $script:ScriptBoundParameters.ContainsKey($_) -or $script:ProfileValues.Contains($_) }
    if ($RecoveryIgnored) {
        Write-HostTimestamp "-RecoveryIsoOnly builds only the recovery ISO, so these are ignored: $((@($RecoveryIgnored) | ForEach-Object { "-$_" }) -join ', ')" -ForegroundColor Yellow
    }
}
# Raised before the log existed, so the console already showed it and only the .log still needs it.
if ($script:LogDirProblem) { Write-CMTraceLog -Message $script:LogDirProblem -Type 2 }
# With -Server gone, the last build here is the only thing that knows this is Server media before an ISO
# has been found, which is what keeps a scheduled Server run from downloading client media by mistake.
if (-not $script:EffectiveServer -and -not $NoStamp) {
    $LastStamp = Get-PreviousBuildStamp
    if ($LastStamp -and $LastStamp.Image) { $script:EffectiveServer = [bool]$LastStamp.Image.Server }
}
Write-Host $LineBreak

#endregion

#region Scheduled task registration (-RegisterScheduledTask / -UnregisterScheduledTask)
# Both of these only touch Task Scheduler and then exit, with nothing downloaded or built.
if ($UnregisterScheduledTask) {
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-HostTimestamp "Scheduled task '$TaskName' removed." -ForegroundColor Green
        }
        else {
            Write-HostTimestamp "No scheduled task named '$TaskName' exists." -ForegroundColor Yellow
        }
    }
    catch {
        Write-HostTimestamp "Could not remove the scheduled task '$TaskName': $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Stop-Transcript | Out-Null
    exit 0
}

if ($RegisterScheduledTask) {
    try {
        Register-UpdaterScheduledTask
    }
    catch {
        Write-HostTimestamp "Could not register the scheduled task: $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-Host $LineBreak
    Stop-Transcript | Out-Null
    exit 0
}

$WinInfo = Get-InstalledWindowsInfo

# Warn if a working/download/log path looks like a cloud-synced folder - servicing from there is unreliable.
$CloudPattern = '(?i)[\\/](My Drive|Google Drive|GoogleDrive|OneDrive|OneDrive - |Dropbox|iCloudDrive|Box)[\\/]'
foreach ($Pair in @(@{ Name = 'Working folder'; Path = $WorkRoot }, @{ Name = 'Download folder'; Path = $DlDir }, @{ Name = 'Log folder'; Path = $LogDir })) {
    if ($Pair.Path -match $CloudPattern -or $Pair.Path -match '(?i)OneDrive') {
        Write-HostTimestamp "WARNING: The $($Pair.Name.ToLower()) is on a cloud-synced path ($($Pair.Path))." -ForegroundColor Yellow
        Write-HostTimestamp "         DISM cannot reliably service files that a cloud client streams/dehydrates. Use -WorkPath and -DownloadPath to point at a LOCAL disk (e.g. C:\WISO-Work)." -ForegroundColor Yellow
    }
}

foreach ($Dir in @($WorkRoot, $DlDir)) {
    try {
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
    }
    catch {
        Write-HostTimestamp "Could not create the folder '$Dir': $($_.Exception.Message). Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}

# These two lines describe the download request, so they are misleading once a local ISO exists: it
# decides the architecture and release, not the host or the parameters.
$LocalIsoAvailable = if ($IsoPath) {
    [bool]((Test-Path -LiteralPath $IsoPath -PathType Leaf) -or
        ((Test-Path -LiteralPath $IsoPath -PathType Container) -and (Find-SourceIso -Directory $IsoPath -Largest:$UseLargestIso)))
}
else {
    [bool](Find-SourceIso -Directory $DlDir -Largest:$UseLargestIso)
}
if (-not $LocalIsoAvailable) {
    Write-HostTimestamp "Architecture   : $($WinInfo.Architecture)"
    if ($script:EffectiveServer) { Write-HostTimestamp 'Target         : Windows Server (whatever release the ISO you supply contains)' }
    else { Write-HostTimestamp "Target         : Windows $WindowsVersion ($Release, $Language)" }
    Write-Host $LineBreak
}
Write-HostLog 'Everything this run writes goes under the working folder:' -ForegroundColor Cyan
Write-HostLog "  Working folder   : $WorkRoot"
Write-HostLog "    Extracted media: $ExtractDir"
Write-HostLog "    DISM mount     : $MountDir"
Write-HostLog "  Downloads        : $DlDir"
if (-not $IsoPath) { Write-HostLog '                     (drop your own .iso here and it is used instead of downloading one)' -ForegroundColor DarkGray }
Write-HostLog "  Logs             : $LogDir"
if (-not $NoStamp) { Write-HostLog "  Build stamps     : $StampRoot" }
# Nothing has read the image yet, so only the parts settled before then are filled in. Only a client download
# knows its release in advance; a local ISO or Server media is named after whatever the image turns out to be.
$IsoNameRelease = if (-not $LocalIsoAvailable -and -not $script:EffectiveServer) { "Win$WindowsVersion" } else { '<release>' }
$IsoNameBase = "$($IsoNameRelease)_<edition>_<arch>_<language>_<build>.<UBR>_<date-time>"
$IsoNameExample = "$IsoNamePrefix$IsoNameBase$IsoNameSuffix.iso"
Write-HostLog "  Finished ISO     : $(if ($OutputIsoPath) { $OutputIsoPath } else { Join-Path $FinishedIsoDir $IsoNameExample })"
Write-Host ''
Write-HostLog '  Nothing outside these folders is changed. -WorkPath moves all of it, and -DownloadPath, -LogPath' -ForegroundColor DarkGray
Write-HostLog '  and -OutputIsoPath override the individual folders.' -ForegroundColor DarkGray
Write-Host $LineBreak

#endregion

#region One run at a time per work folder
# Everything past this point assumes it owns the mount directories, so a second run sharing a work folder
# would discard the first one's live mount as if it were stale. Keyed on the work folder, so runs pointed
# at different -WorkPath folders are still free to go side by side. The mutex is never released explicitly:
# Windows drops it when the process ends, and a waiter that inherits an abandoned one is the owner anyway.
$WorkKeyBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::Unicode.GetBytes($WorkRoot.TrimEnd('\').ToLowerInvariant()))
$WorkKey = ([System.BitConverter]::ToString($WorkKeyBytes) -replace '-', '').Substring(0, 16)
$script:RunMutex = New-Object System.Threading.Mutex($false, "Global\WindowsIsoUpdater_$WorkKey")
$HaveRunMutex = $false
try { $HaveRunMutex = $script:RunMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $HaveRunMutex = $true }
if (-not $HaveRunMutex) {
    Write-HostTimestamp "Another Windows-ISO-Updater run is already using $WorkRoot." -ForegroundColor Red
    Write-HostTimestamp '  Wait for it to finish, or start this one with a different -WorkPath so the two do not share a mount folder.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

#endregion

#region Clean up leftovers from an interrupted run
# Runs whether or not this run asks for an exclusion, because a stale one should not outlive the run that made it.
Clear-StaleDefenderExclusion

# Add-UpdateGroup stages each package in its own pkgstage_* folder, the serviced recovery image waits in
# WinRECache, -RecoveryIsoPath assembles its media in RecoveryMedia, and a servicing stack pulled out of an
# update waits in ServicingStack (or ssucheck_* while a package is being identified). All are deleted when the step that
# made them finishes, but a run that was killed outright never reaches that and leaves several GB behind.
# Cleared before the free space check so the reading reflects what is really available.
$StaleStages = @(Get-ChildItem -LiteralPath $WorkRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'pkgstage_*' -or $_.Name -like 'ssucheck_*' -or $_.Name -in 'WinRECache', 'RecoveryMedia', 'ServicingStack' })
if ($StaleStages.Count -gt 0) {
    $StageFreedMB = 0
    $StageRemoved = 0
    foreach ($Stale in $StaleStages) {
        try {
            $StageSizeMB = (Get-ChildItem -LiteralPath $Stale.FullName -File -Recurse -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum / 1MB
            Remove-Item -LiteralPath $Stale.FullName -Recurse -Force -ErrorAction Stop
            $StageRemoved++
            $StageFreedMB += $StageSizeMB
        }
        catch {
            Write-HostTimestamp "  Could not remove the leftover staging folder '$($Stale.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($StageRemoved -gt 0) {
        Write-HostTimestamp ('Removed {0} staging folder(s) left behind by an interrupted run, freeing {1:N0} MB.' -f $StageRemoved, $StageFreedMB) -ForegroundColor DarkGray
        Write-Host $LineBreak
    }
}

# An ISO staged for a network destination is deleted the moment it has been copied, so anything still here
# belongs to a run that died in between, or to a copy that failed and has since been dealt with by hand.
foreach ($StaleIso in @(Get-ChildItem -LiteralPath $IsoStageDir -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
    try {
        $StaleSizeMB = $StaleIso.Length / 1MB
        Remove-Item -LiteralPath $StaleIso.FullName -Force -ErrorAction Stop
        Write-HostTimestamp ('Removed a staged ISO left behind by an interrupted run: {0} ({1:N0} MB).' -f $StaleIso.Name, $StaleSizeMB) -ForegroundColor DarkGray
        Write-Host $LineBreak
    }
    catch {
        Write-HostTimestamp "  Could not remove the staged ISO '$($StaleIso.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# A run killed while an image was mounted leaves the mount folders full of files owned by TrustedInstaller,
# and DISM will not mount into a directory that is not empty. Released here rather than at first use so the
# problem surfaces in seconds instead of after the download and extraction have already run.
$MountsCleared = $false
foreach ($StaleName in @('Mount', 'WinREMount', 'BuildCheck')) {
    $StalePath = Join-Path -Path $WorkRoot -ChildPath $StaleName
    if (-not (Test-Path -LiteralPath $StalePath)) { continue }

    if (-not (Get-ChildItem -LiteralPath $StalePath -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $StalePath -Force -ErrorAction SilentlyContinue
        continue
    }

    Write-HostTimestamp "A previous run left files behind in $StalePath, clearing them..." -ForegroundColor Yellow
    try {
        # Releases any mount DISM still tracks there first, because deleting a tracked mount folder orphans it.
        Reset-MountDirectory -Path $StalePath
        Remove-Item -LiteralPath $StalePath -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Cleared.' -ForegroundColor Green
        $MountsCleared = $true
    }
    catch {
        Write-HostTimestamp "  $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}
if ($MountsCleared) { Write-Host $LineBreak }

#endregion

#region Disk space check
# DISM mounts and services images inside the working folder, which a network share cannot support.
if (Test-RemotePath -Path $WorkRoot) {
    Write-HostTimestamp "The working folder is not on a local disk: $WorkRoot" -ForegroundColor Red
    Write-HostTimestamp '  A UNC path, a mapped network drive, or a drive letter that does not exist in this session cannot be used to mount and service images. Point -WorkPath at a local drive with plenty of free space.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# The download (~8 GB), extracted media (~8 GB), the mounted image, and the re-exported image all coexist
# during the build, so the working drive needs plenty of headroom.
$FreeGB = Get-DriveFreeGB -Path $WorkRoot
if ($null -eq $FreeGB) {
    Write-HostTimestamp 'Could not determine free disk space on the working drive. Continuing with caution.' -ForegroundColor Yellow
}
else {
    Write-HostTimestamp "Free space on the working drive: $FreeGB GB"
    # A recovery-only run stages at most one edition converted out of an install.esd.
    $RequiredGB = if ($RecoveryIsoOnly) { 10 } else { 50 }
    if ($FreeGB -lt $RequiredGB) {
        if ($CheckOnly) {
            # -CheckOnly builds nothing, so it only needs to say that a build would not fit right now.
            Write-HostTimestamp "Less than $RequiredGB GB is free on the working drive, so a build could not run here as things stand." -ForegroundColor Yellow
        }
        else {
            Write-HostTimestamp "CRITICAL: Less than $RequiredGB GB free on the working drive. Building a patched ISO needs a lot of scratch space. Free up space, choose another drive with -WorkPath, and try again." -ForegroundColor Red
            Stop-Transcript | Out-Null
            exit 1
        }
    }
}
Write-Host $LineBreak

#endregion

#region Validate the output ISO location
# The rest of the build takes hours and oscdimg is the last thing it runs, so a missing folder, a share
# that is not writable, or an ISO still mounted from a previous run has to be caught here instead.
$OutputIsRemote = $false
if (-not $ListEditions -and -not $CheckOnly -and -not $RecoveryIsoOnly) {
    $OutputDir = if ($OutputIsoPath) { Split-Path -Path $OutputIsoPath -Parent } else { $FinishedIsoDir }
    $OutputProblem = Get-OutputPathProblem -Directory $OutputDir -FilePath $OutputIsoPath
    if ($OutputProblem) {
        Write-HostTimestamp 'The finished ISO could not be written where it is meant to go.' -ForegroundColor Red
        Write-HostTimestamp "  $OutputProblem" -ForegroundColor Red
        Write-HostTimestamp '  Fix the destination or point -OutputIsoPath somewhere else, then run again.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    if ($OutputIsoPath) {
        Write-HostTimestamp "Output ISO     : $OutputIsoPath" -ForegroundColor Green
        if ($OutputIsoPath -notmatch '(?i)\.iso$') {
            Write-HostTimestamp '  That name does not end in .iso, so nothing will recognise the file as an image.' -ForegroundColor Yellow
        }
        if (Test-Path -LiteralPath $OutputIsoPath -PathType Leaf) {
            Write-HostTimestamp '  An ISO already exists at that path and will be replaced.' -ForegroundColor Yellow
        }
    }
    else {
        Write-HostTimestamp "Output folder  : $OutputDir" -ForegroundColor Green
    }
    # A mapped drive or a share is writable here yet absent under the scheduled task's logon session.
    $OutputIsRemote = Test-RemotePath -Path $OutputDir
    if ($OutputIsRemote) {
        Write-HostTimestamp '  That is a network location. Drive mappings belong to a logon session, so a scheduled run may not see it. A UNC path is the safer choice.' -ForegroundColor Yellow
        Write-HostTimestamp "  The ISO will be built in $IsoStageDir and copied there once it is finished, so a share that stalls cannot cost the whole build." -ForegroundColor DarkGray
    }
    # Only worth saying when the ISO lands somewhere other than the working drive, which was measured above.
    $OutputQualifier = try { Split-Path -Path $OutputDir -Qualifier -ErrorAction SilentlyContinue } catch { $null }
    $WorkQualifier   = try { Split-Path -Path $WorkRoot -Qualifier -ErrorAction SilentlyContinue } catch { $null }
    if ($OutputQualifier -and $OutputQualifier -ne $WorkQualifier) {
        $OutputFreeGB = Get-DriveFreeGB -Path $OutputDir
        if ($null -ne $OutputFreeGB -and $OutputFreeGB -lt 12) {
            Write-HostTimestamp "  Only $OutputFreeGB GB is free there, and a finished ISO is usually 5 to 8 GB." -ForegroundColor Yellow
        }
    }
    Write-Host $LineBreak
}
if ($RecoveryIsoDir -and -not $ListEditions -and -not $CheckOnly) {
    $RecoveryProblem = Get-OutputPathProblem -Directory $RecoveryIsoDir -FilePath $RecoveryIsoFile
    if ($RecoveryProblem) {
        Write-HostTimestamp 'The recovery ISO could not be written where it is meant to go.' -ForegroundColor Red
        Write-HostTimestamp "  $RecoveryProblem" -ForegroundColor Red
        Write-HostTimestamp '  Fix the destination or point -RecoveryIsoPath somewhere else, then run again.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-HostTimestamp "Recovery ISO   : $(if ($RecoveryIsoFile) { $RecoveryIsoFile } else { "$RecoveryIsoDir (generated name)" })" -ForegroundColor Green
    Write-Host $LineBreak
}

#endregion

#region Validate the unattended answer file
$ResolvedUnattend = $null
$UnattendText = $null
if ($UnattendPath) {
    if (-not (Test-Path -LiteralPath $UnattendPath -PathType Leaf)) {
        Write-HostTimestamp "The answer file '$UnattendPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $ResolvedUnattend = (Resolve-Path -LiteralPath $UnattendPath).Path
    $UnattendDoc = New-Object System.Xml.XmlDocument
    $UnattendDoc.XmlResolver = $null  # do not resolve external entities (XXE)
    try {
        $UnattendDoc.Load($ResolvedUnattend)
    }
    catch {
        Write-HostTimestamp "The answer file '$ResolvedUnattend' is not valid XML: $($_.Exception.Message). Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $UnattendText = $UnattendDoc.OuterXml
    # Hashed for the build stamp: editing the answer file in place has to force a rebuild even though its
    # path never changed.
    $script:UnattendHash = Get-TextSha256 -Text $UnattendText
    Write-HostTimestamp "Answer file    : $ResolvedUnattend" -ForegroundColor Green
    if ($UnattendDoc.DocumentElement.Name -ne 'unattend') {
        Write-HostTimestamp "  Warning: the root element is <$($UnattendDoc.DocumentElement.Name)>, not <unattend>. Windows Setup will ignore this file." -ForegroundColor Yellow
    }
    if ($UnattendText -match '(?i)<(Password|AdministratorPassword|ProductKey)\b') {
        Write-HostTimestamp '  NOTE: this answer file contains password/product key elements. Windows stores these in plain text or base64, and the finished ISO is not encrypted - anyone who can read the ISO can recover them.' -ForegroundColor Yellow
    }
    Write-Host $LineBreak
}

#endregion

#region Validate the driver folder
$ResolvedDriverPath = $null
if ($DriverPath) {
    if (-not (Test-Path -LiteralPath $DriverPath -PathType Container)) {
        Write-HostTimestamp "The driver folder '$DriverPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $ResolvedDriverPath = (Resolve-Path -LiteralPath $DriverPath).Path
    $script:DriverInfFiles = @(Get-ChildItem -LiteralPath $ResolvedDriverPath -Filter '*.inf' -File -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName)
    if ($script:DriverInfFiles.Count -eq 0) {
        Write-HostTimestamp "No .inf files were found anywhere under '$ResolvedDriverPath'. Extract the vendor's driver package first - an .exe or .msi installer cannot be injected into an image." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    # Hashed for the build stamp: dropping a newer driver in has to force a rebuild even though the path
    # never changed.
    $script:DriverHash = Get-FolderContentHash -Records @(Get-FolderFileRecords -Path $ResolvedDriverPath)
    $DriverSizeMB = [math]::Round((Get-ChildItem -LiteralPath $ResolvedDriverPath -File -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-HostTimestamp "Drivers        : $($script:DriverInfFiles.Count) .inf package(s) in $ResolvedDriverPath ($DriverSizeMB MB)" -ForegroundColor Green
    if ($AllowUnsignedDrivers) {
        Write-HostTimestamp '  -AllowUnsignedDrivers is set, so DISM will accept drivers the image does not trust. 64-bit Windows still refuses to load an unsigned driver at boot unless test signing is on.' -ForegroundColor Yellow
    }
    # WinPE runs entirely from a RAM disk, so a large driver set in boot.wim can leave a machine unable to
    # start Setup at all.
    if ($DriverSizeMB -gt 500) {
        Write-HostTimestamp "  That is a large set to add to boot.wim, which Windows Setup loads into memory. Consider narrowing it to the storage and network drivers Setup actually needs." -ForegroundColor Yellow
    }
    Write-Host $LineBreak
}

#endregion

#region Validate the extra files folder
$ResolvedExtraFiles = $null
if ($ExtraFilesPath) {
    if (-not (Test-Path -LiteralPath $ExtraFilesPath -PathType Container)) {
        Write-HostTimestamp "The extra files folder '$ExtraFilesPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $ResolvedExtraFiles = (Resolve-Path -LiteralPath $ExtraFilesPath).Path
    # Hashed and listed here rather than during the copy, so the run is priced and the rebuild decision is
    # made before anything is extracted.
    $script:ExtraFileRecords = @(Get-FolderFileRecords -Path $ResolvedExtraFiles)
    if ($script:ExtraFileRecords.Count -eq 0) {
        Write-HostTimestamp "The extra files folder '$ResolvedExtraFiles' is empty. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $script:ExtraFilesHash = Get-FolderContentHash -Records $script:ExtraFileRecords
    $ExtraSizeMB = [math]::Round((($script:ExtraFileRecords | ForEach-Object { $_['SizeKB'] } | Measure-Object -Sum).Sum) / 1024, 1)
    Write-HostTimestamp "Extra files    : $($script:ExtraFileRecords.Count) file(s) in $ResolvedExtraFiles ($ExtraSizeMB MB), copied to the root of the ISO" -ForegroundColor Green
    Write-Host $LineBreak
}

#endregion

