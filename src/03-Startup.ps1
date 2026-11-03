#region Startup checks and elevation
# Remembered here because inside a function $PSBoundParameters/$MyInvocation describe that function, not
# the script - and the scheduled-task registration has to reproduce this exact command line.
$script:ScriptBoundParameters = $PSBoundParameters
$script:ScriptPath = $PSCommandPath

# Kept in step with the header comment by tools\Update-Version.ps1, and shown in the log and recorded in
# the build stamp so a finished ISO can be traced back to the exact script that built it.
$ScriptVersion = '2026.11.02.3'

# A scheduled run has nobody to answer a prompt.
if ($Scheduled) {
    $Unattended = $true
    $SkipInteractive = $true
}

# Verify this is running on Windows. $IsWindows only exists on PowerShell 6+, where it is the reliable
# test. Windows PowerShell 5.1 is Windows-only, so its absence is itself the answer. This has to come
# before anything that touches CIM, DISM or the registry, all of which are Windows-only.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Host "This script must be run on Windows. You are currently running $($PSVersionTable.OS)." -ForegroundColor Red
    Write-Host "It relies on Windows-only components (DISM, CIM/WMI and the Windows ADK) to service the image." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

# Verify this is running on PowerShell 5 or higher
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "This script requires PowerShell 5.0 or higher. You are currently running $($PSVersionTable.PSVersion)." -ForegroundColor Red
    Write-Host "Please update your PowerShell version to proceed." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

# Started from a PowerShell 7 terminal by way of cmd.exe (the .bat), Windows PowerShell inherits PowerShell 7's
# module folders. pwsh only cleans them out for a powershell.exe it starts itself. Listed first, they make 5.1 try
# PowerShell 7's own Microsoft.PowerShell.Utility and similar, which cannot load here, so commands such as
# Get-FileHash vanish. Must come before the first command that is loaded on demand.
if ($PSVersionTable.PSEdition -eq 'Desktop' -and $env:PSModulePath) {
    $env:PSModulePath = (@($env:PSModulePath -split ';') |
            Where-Object { $_ -and $_ -notmatch '(?i)\\PowerShell\\(\d+(\.\d+)*(-preview)?\\)?Modules\\?$' }) -join ';'
}

# Verify you are running on Windows 10 (or Windows Server 2016) or higher
$OsInfo = Get-CimInstance -Class Win32_OperatingSystem
if ([int]($OsInfo).BuildNumber -lt 10240) {
    Write-Host "This script is designed for Windows 10 or higher. You are running $($OsInfo.Caption) (Build $($OsInfo.BuildNumber))." -ForegroundColor Red
    Write-Host "Running on an unsupported OS may have unintended consequences." -ForegroundColor Yellow
    Write-Host "The script will exit in 10 seconds." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

$PathParameters = @('IsoPath', 'UpdatePath', 'UnattendPath', 'DriverPath', 'ExtraFilesPath', 'DownloadPath', 'WorkPath', 'OutputIsoPath', 'RecoveryIsoPath', 'OscdimgPath', 'LogPath', 'StampPath')

# Reads a JSON profile into parameter names and values. It lives here rather than with the other functions
# because a profile can change what the elevation check below does, and functions are not defined until later.
# A profile describes a build, so task registration and one-off actions stay on the command line, and a file
# on disk is no place for a password. Names starting with _ or $ are ignored, which allows comments and $schema.
function Read-ConfigFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [string[]]$PathParameter
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The profile '$Path' was not found." }
    try { $Json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "The profile '$Path' is not valid JSON: $($_.Exception.Message)" }
    if ($Json -isnot [System.Management.Automation.PSCustomObject]) { throw "The profile '$Path' must be a JSON object of parameter names and values." }

    $CommandLineOnly = @('ConfigPath', 'TaskPassword', 'PromptTaskPassword', 'TaskUsername', 'TaskName', 'RegisterScheduledTask', 'UnregisterScheduledTask',
        'Schedule', 'ScheduleTime', 'ScheduleDay', 'Scheduled', 'CheckOnly', 'ListEditions', 'Force')
    $CommonParameters = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $ProfileFolder = Split-Path -Parent $Path

    $Values = [ordered]@{}
    foreach ($Property in $Json.PSObject.Properties) {
        $Key = $Property.Name
        if ($Key -match '^[_$]') { continue }
        if ($CommandLineOnly -contains $Key) { throw "'$Key' in '$Path' cannot be set in a profile. Pass -$Key on the command line." }
        if (-not $Parameters.ContainsKey($Key) -or $CommonParameters -contains $Key) { throw "'$Key' in '$Path' is not a parameter of this script." }

        $Name = $Parameters[$Key].Name
        $Type = $Parameters[$Key].ParameterType
        $Value = $Property.Value
        if ($null -eq $Value) { continue }

        if ($Type -eq [switch]) {
            if ($Value -isnot [bool]) { throw "'$Name' in '$Path' must be true or false." }
            $Value = [switch]$Value
        }
        elseif ($Type -eq [string[]]) {
            if (@($Value | Where-Object { $_ -isnot [string] -and $_ -isnot [int] }).Count -gt 0) { throw "'$Name' in '$Path' must be a string or a list of strings." }
            $Value = [string[]]@($Value)
        }
        elseif (($Value -is [array]) -or ($Value -is [System.Management.Automation.PSCustomObject]) -or ($Value -is [bool])) {
            throw "'$Name' in '$Path' must be a single value."
        }
        elseif ($Value -is [string] -and $Value -and $PathParameter -contains $Name -and -not [System.IO.Path]::IsPathRooted($Value)) {
            $Value = [System.IO.Path]::GetFullPath((Join-Path -Path $ProfileFolder -ChildPath $Value))
        }
        $Values[$Name] = $Value
    }
    return $Values
}

# What the profile set, kept apart from the bound parameters so the elevated relaunch and a registered task
# pass -ConfigPath and read the file again, which means later edits to the profile apply to them.
$script:ProfileValues = [ordered]@{}
if ($ConfigPath) {
    try {
        $ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
        $PSBoundParameters['ConfigPath'] = $ConfigPath
        $ProfileEntries = Read-ConfigFile -Path $ConfigPath -Parameters $MyInvocation.MyCommand.Parameters -PathParameter $PathParameters
        foreach ($ProfileName in @($ProfileEntries.Keys)) {
            if ($PSBoundParameters.ContainsKey($ProfileName)) { continue }
            # The parameter's validation attributes still apply to the variable, so a bad value fails here.
            try { Set-Variable -Name $ProfileName -Value $ProfileEntries[$ProfileName] -ErrorAction Stop }
            catch { throw "'$ProfileName' in '$ConfigPath' has a value this script does not accept: $($_.Exception.Message)" }
            $script:ProfileValues[$ProfileName] = $ProfileEntries[$ProfileName]
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}

# Self-elevate the script if required
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
        $ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
        # Re-add any passed parameters. An elevated process starts in System32, so relative paths are made absolute.
        foreach ($Parameter in $PSBoundParameters.Keys) {
            if ($Parameter -eq 'TaskPassword') { continue }
            $Value = $PSBoundParameters[$Parameter]
            if ($Value -is [switch]) {
                if ($Value.IsPresent) { $ArgumentList += "-$Parameter" }
            }
            else {
                if ($Value -and $PathParameters -contains $Parameter) {
                    $Value = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)
                }
                # -File cannot carry an array, and -KeepEditions splits a comma-separated string itself.
                # Backslashes before a quote are doubled so a path such as "D:\ISOs\" keeps its closing quote.
                $Text = (@($Value) -join ',') -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
                $ArgumentList += "-$Parameter"
                $ArgumentList += "`"$Text`""
            }
        }

        # The elevated process asks for the password itself, so it never sits on a command line.
        if ($PSBoundParameters.ContainsKey('TaskUsername') -and -not $Unattended -and -not $SkipInteractive -and -not $PromptTaskPassword) {
            $ArgumentList += '-PromptTaskPassword'
        }

        # Waiting hands the exit code back to the caller, which is how -CheckOnly reports its 0 or 10.
        try {
            # The same edition this run started in, so running from pwsh does not quietly switch to Windows PowerShell.
            $PsExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path -Path $PSHOME -ChildPath 'pwsh.exe' } else { Join-Path -Path $PSHOME -ChildPath 'powershell.exe' }
            $Elevated = Start-Process -FilePath $PsExe -Verb Runas -ArgumentList $ArgumentList -Wait -PassThru -ErrorAction Stop
            exit $Elevated.ExitCode
        }
        catch {
            Write-Host "Could not start the elevated session: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }
}

if ($PromptTaskPassword -and -not $TaskPassword) {
    $SecurePassword = Read-Host "Password for $TaskUsername" -AsSecureString
    $PasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try { $TaskPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($PasswordPointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPointer) }
}

# Add a Window Title
$Host.UI.RawUI.WindowTitle = "Windows ISO Updater - Running as Administrator - $env:COMPUTERNAME"

#endregion

#region Resolve working folders
# Everything this script writes lives under the working folder, so a single -WorkPath moves the whole
# build (downloads, extracted media, DISM mount, logs) to another drive. These MUST be on a local, fixed
# disk: cloud-synced folders (Google Drive, OneDrive, Dropbox, etc.) turn files into on-demand
# placeholders and sync them in the background, which makes DISM unable to read the .msu/.wim reliably
# ("An error occurred applying the Unattend.xml file from the .msu package"). They also need lots of free
# space and, ideally, no spaces in the path (oscdimg's -bootdata dislikes spaces, so short paths are used
# to work around it regardless).
# Made absolute without requiring it to exist yet, so the drive checks further down see a qualifier even
# when a relative -WorkPath was passed.
$WorkRoot   = if ($WorkPath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath) } else { Join-Path -Path $env:SystemDrive -ChildPath 'WISO-Work' }
$ExtractDir = Join-Path -Path $WorkRoot -ChildPath 'ISO'
$MountDir   = Join-Path -Path $WorkRoot -ChildPath 'Mount'
# Where the serviced recovery image waits between editions. Its own folder because it outlives the step
# that made it, unlike the re-export temporaries that come and go inside one, so it is one thing to delete.
$WinReCacheDir = Join-Path -Path $WorkRoot -ChildPath 'WinRECache'
# Where -RecoveryIsoPath keeps the recovery image between being copied out of install.wim and being packaged,
# which is most of the run because the installation ISO is built in between.
$RecoveryMediaDir = Join-Path -Path $WorkRoot -ChildPath 'RecoveryMedia'
# Where a standalone oscdimg.exe is cached if it has to be downloaded, so later runs reuse it.
$OscdimgLocalPath = Join-Path -Path $WorkRoot -ChildPath 'Tools\oscdimg.exe'
# Downloads and logs default under the work root - NOT the script folder, which may sit on a cloud-synced
# drive (this repo, for example, lives under a Google Drive "My Drive" path).
$DlDir      = if ($DownloadPath) { $DownloadPath } else { Join-Path -Path $WorkRoot -ChildPath 'Downloads' }
$LogDirWanted = if ($LogPath) { $LogPath } else { Join-Path -Path $WorkRoot -ChildPath 'Logs' }
# The finished ISO gets its own folder so it is never mistaken for a source ISO sitting in Downloads.
$FinishedIsoDir = Join-Path -Path $WorkRoot -ChildPath 'Output'
if ($OutputIsoPath) {
    # Absolute from the start, so the run header, the write check, the stamp and the tattoo all quote one path.
    $OutputIsoPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputIsoPath)
    $OutputIsFolder = $false
    try {
        $OutputIsFolder = ($OutputIsoPath -match '[\\/]$') -or
            -not [System.IO.Path]::GetExtension($OutputIsoPath) -or
            (Test-Path -LiteralPath $OutputIsoPath -PathType Container -ErrorAction Stop)
    }
    catch { }   # a malformed or unreachable path is reported properly by the output check further down
    # A folder is shorthand for "put it there under the generated name". Clearing the path is what hands the
    # naming back to the default, so nothing downstream needs a special case.
    if ($OutputIsFolder) {
        $FinishedIsoDir = $OutputIsoPath
        $OutputIsoPath  = $null
    }
}
# Read the same way as -OutputIsoPath, so a folder means "there, under the generated name".
$RecoveryIsoDir  = $null
$RecoveryIsoFile = $null
if ($RecoveryIsoPath) {
    $RecoveryIsoFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RecoveryIsoPath)
    $RecoveryIsFolder = $false
    try {
        $RecoveryIsFolder = ($RecoveryIsoFull -match '[\\/]$') -or
            -not [System.IO.Path]::GetExtension($RecoveryIsoFull) -or
            (Test-Path -LiteralPath $RecoveryIsoFull -PathType Container -ErrorAction Stop)
    }
    catch { }   # a malformed or unreachable path is reported properly by the output check further down
    if ($RecoveryIsFolder) {
        $RecoveryIsoDir = $RecoveryIsoFull
    }
    else {
        $RecoveryIsoFile = $RecoveryIsoFull
        $RecoveryIsoDir  = Split-Path -Path $RecoveryIsoFull -Parent
    }
}
elseif ($RecoveryIsoOnly) {
    $RecoveryIsoDir = $FinishedIsoDir
}
# oscdimg writes an ISO as hours of small writes, which a share cannot be trusted with, so a network
# destination is built here first and copied over as one sequential pass at the end.
$IsoStageDir = Join-Path -Path $WorkRoot -ChildPath 'OutputStaging'
# Stamps record what each finished build contained, so a scheduled run can tell whether building again
# would produce anything new. -StampPath moves them (e.g. onto a share, so several machines share state).
$StampRoot       = if ($StampPath) { $StampPath } else { Join-Path -Path $WorkRoot -ChildPath 'Stamps' }
$StampHistoryDir = Join-Path -Path $StampRoot -ChildPath 'History'
$StampFile       = Join-Path -Path $StampRoot -ChildPath 'last-build.json'
# A stamp is only written when a build succeeds, so hashes are kept here as well the moment they are read.
$HashCacheFile   = Join-Path -Path $StampRoot -ChildPath 'hash-cache.json'

#endregion

#region Start Logging
# Create the log folder, falling back to the script folder if it cannot be used.
$LogDir = $PSScriptRoot
try {
    if (-not (Test-Path $LogDirWanted)) {
        New-Item -ItemType Directory -Path $LogDirWanted -Force -ErrorAction Stop | Out-Null
    }
    $LogDir = $LogDirWanted
}
catch {
    $script:LogDirProblem = "Could not use the log folder '$LogDirWanted': $($_.Exception.Message). Falling back to the script folder."
    Write-Warning $script:LogDirProblem
}
$LogStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
# The .log is the one to open, written in the format CMTrace parses. The transcript beside it keeps the raw
# console record, which still holds the prompts, the plan and any error text that never reaches a log call.
$LogFile        = Join-Path -Path $LogDir -ChildPath "Windows-ISO-Updater_$LogStamp.log"
$TranscriptFile = Join-Path -Path $LogDir -ChildPath "Windows-ISO-Updater_${LogStamp}_console.txt"
Start-Transcript -Path $TranscriptFile | Out-Null

# Read by Write-CMTraceLog, which is defined further down but has to know where to write before any caller runs.
$script:CMTraceLog    = $LogFile
$script:LogComponent  = 'Startup'
$script:LogScriptName = if ($script:ScriptPath) { Split-Path -Leaf $script:ScriptPath } else { 'Windows-ISO-Updater.ps1' }

# Rotate logs: keep only the 30 most recent of each, delete the rest
foreach ($LogPattern in 'Windows-ISO-Updater_*.log', 'Windows-ISO-Updater_*_console.txt') {
    Get-ChildItem -Path $LogDir -Filter $LogPattern -File |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

$ProgressPreference = 'SilentlyContinue'
$LineBreakCharacter = '-'
$LineBreak = $null
1..$($Host.UI.RawUI.BufferSize.Width) | ForEach-Object {
    $LineBreak += $LineBreakCharacter
}

# Wall-clock start of the run plus the per-step durations collected by Invoke-Task, reported at the end.
$script:ScriptStartTime = Get-Date
$script:StepTimings = [System.Collections.Generic.List[psobject]]::new()
# Captured from the serviced image while it is still mounted, so the final report does not have to mount it again.
$script:FinalBuildString = $null
# Same idea as FinalBuildString, but the shipped display language, read from the offline SYSTEM hive.
$script:FinalImageLocale = $null
# The source media's installation language, the fallback whenever no image was mounted to read the hive.
$script:MediaLanguage = $null
# Filled in as servicing happens, because by the time the tattoo is written the images are already
# dismounted and DISM's own log is the only other record of which package landed on which image.
$script:TattooServicing   = New-Object System.Collections.Generic.List[object]
$script:TattooResidueMB   = 0
$script:TattooResidueFound = New-Object System.Collections.Generic.List[string]
# Sampled as the run goes, because winre.wim only exists while its edition is mounted and install.wim is
# gone by the time the report runs, so neither can be measured after the fact.
$script:WimSizes = New-Object System.Collections.Generic.List[psobject]
# The recovery image serviced for the first edition, with the hash of the source it was made from, so the
# editions that ship the same one can take a copy instead of repeating the work.
$script:WinReCachePath = $null
$script:WinReCacheHash = $null
# What recovery environment each edition carries, sampled while its install.wim index is mounted.
$script:WinReVersions = New-Object System.Collections.Generic.List[psobject]
# Keyed on WIM path and index, because reading a build costs a read-only mount and more than one caller wants it.
$script:WimBuildCache = @{}
# Each serviced edition's build, read while it is mounted, so the tattoo shows an edition whose LCU failed.
$script:EditionBuilds = New-Object System.Collections.Generic.List[object]
# Catalog titles by role, filled beside the KB tags because only the title names the product unambiguously.
$script:CatalogTitles = @{}
# The -DriverPath set, resolved once during validation and reused by every image the run services.
$script:DriverInfFiles = @()
$script:DriverHash     = $null
# Filled in while -ExtraFilesPath is copied, because by tattoo time the media already looks merged.
$script:ExtraFilesHash      = $null
$script:ExtraFilesCopied    = 0
$script:ExtraFileRecords    = @()
$script:ExtraFileOverwrites = New-Object System.Collections.Generic.List[string]
# Taken while a staged ISO is still local, so the stamp does not have to read it back over the wire.
$script:OutputIsoSha256 = $null
# Set only when -IsoPath was copied into $DlDir from a remote/cloud path, so the stamp can tell that copy
# apart from an ISO the user placed in $DlDir themselves - the two must never be cleaned up the same way.
$script:SourceLocalCopy = $null
# Read by Get-CatalogProductQuery for client media. Starts as -WindowsVersion, then corrected once the
# mounted (or stamped) image's own build number is known, so an ISO that does not match -WindowsVersion
# still gets the right catalog search.
$script:EffectiveWindowsVersion = $WindowsVersion
# Read the same way by every Server/client branch below. The image itself is the source of truth and
# overwrites this the moment one is extracted, so the deprecated -Server switch and the last build stamp
# only ever serve as a guess for the steps that have to run before any ISO is in hand.
$script:EffectiveServer = [bool]$Server
#endregion

