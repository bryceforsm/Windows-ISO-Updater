<#
.SYNOPSIS
    Stamps a date-based (CalVer) version into this repository's scripts, and can install the Git
    pre-commit hook that does it automatically.

.DESCRIPTION
    The version is yyyy.MM.dd.<revision>, e.g. 2026.08.15.3 for the third stamp made on 15 August 2026.
    The revision restarts at 1 on a new day, so the version always reads as "when was this built, and
    which build of that day is it".

    The version lives in these markers, which are rewritten in place (nothing else in the file is
    touched):

        # Version: 2026.08.15.1          <- comment header (.ps1, .bat, .md)
        :: Version: 2026.08.15.1
        $ScriptVersion = '2026.08.15.1'  <- the variable the script itself reports

.EXAMPLE
    .\tools\Update-Version.ps1 -InstallHook
    Installs the pre-commit hook, so every commit stamps a fresh version and includes it in that commit.

.EXAMPLE
    .\tools\Update-Version.ps1
    Stamps a new version into every versioned file now.

.EXAMPLE
    .\tools\Update-Version.ps1 -Version 2026.09.01.1
    Sets an exact version instead of computing one.

.NOTES
    Running from the hook, only files that are already staged are stamped, and the stamped file is
    re-staged with "git add". If you staged only part of a file (git add -p), that re-stage picks up the
    rest of the file too - stamp and commit those by hand instead.

    Any change to src\ stamps both src files that carry a marker and rebuilds Windows-ISO-Updater.ps1, so the
    combined script always carries the new version. The hook refuses a hand edit to the combined script.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Repository to work on. Defaults to the repository this script lives in')]
    [string]$RepositoryPath,

    [Parameter(HelpMessage = 'Use this exact version instead of computing one from today''s date')]
    [ValidatePattern('^\d{4}\.\d{2}\.\d{2}\.\d+$')]
    [string]$Version,

    [Parameter(HelpMessage = 'Only stamp files that are staged for the next commit. Used by the pre-commit hook')]
    [switch]$StagedOnly,

    [Parameter(HelpMessage = 'Re-stage each file that was changed ("git add"). Used by the pre-commit hook')]
    [switch]$Stage,

    [Parameter(HelpMessage = 'Install the Git pre-commit hook that runs this script, then exit')]
    [switch]$InstallHook,

    [Parameter(HelpMessage = 'Remove the pre-commit hook this script installed, then exit')]
    [switch]$RemoveHook,

    [Parameter(HelpMessage = 'Report what would change without writing anything')]
    [switch]$WhatIfOnly,

    [Parameter(HelpMessage = 'Print only the new version')]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# The files that carry a version marker, relative to the repository root.
$VersionedFiles = @(
    'src\01-Header.ps1',
    'src\03-Startup.ps1',
    'Run-Windows-ISO-Updater.bat'
)
$SourceVersionedFiles = @($VersionedFiles | Where-Object { $_ -like 'src\*' })
$CombinedScript = 'Windows-ISO-Updater.ps1'
$BuildScript = Join-Path -Path $PSScriptRoot -ChildPath 'Build-Script.ps1'

$VersionNumber = '\d{4}\.\d{2}\.\d{2}\.\d+'
# Each marker keeps whatever prefix/suffix it already has, so only the number itself is rewritten.
$Markers = @(
    "(?m)^(?<pre>\s*(?:#|::|REM)\s*Version:\s*)$VersionNumber",
    "(?m)^(?<pre>\s*\`$ScriptVersion\s*=\s*')$VersionNumber(?<post>')"
)

$HookMarker = 'Update-Version.ps1'
$HookBody = @"
#!/bin/sh
# Installed by tools/$HookMarker - stamps a date-based version into the scripts before each commit.
# Remove it again with:  powershell -File tools/Update-Version.ps1 -RemoveHook
cd "`$(git rev-parse --show-toplevel)" || exit 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools/Update-Version.ps1" -StagedOnly -Stage
exit `$?
"@

function Write-Info {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $Output = & git @(@('-C', $RepositoryPath) + $Arguments) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $Output" }
    return $Output
}

# Reads a text file without disturbing its encoding or line endings.
function Get-FileText {
    param([Parameter(Mandatory)][string]$Path)
    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    $HasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    return [pscustomobject]@{
        Text   = [System.IO.File]::ReadAllText($Path)
        HasBom = $HasBom
    }
}

function Set-FileText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$HasBom
    )
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($HasBom)))
}

function Get-NextVersion {
    param([string]$Current)
    $Today = Get-Date -Format 'yyyy.MM.dd'
    if ($Current -match "^$([regex]::Escape($Today))\.(\d+)$") {
        return "$Today.$([int]$Matches[1] + 1)"
    }
    return "$Today.1"
}

# --- Locate the repository ---
if (-not $RepositoryPath) { $RepositoryPath = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $RepositoryPath)) { throw "The repository path '$RepositoryPath' does not exist." }
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path

$IsGitRepo = $false
try { $IsGitRepo = ((Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree')) -join '') -eq 'true' } catch { }

# --- Hook management ---
if ($InstallHook -or $RemoveHook) {
    if (-not $IsGitRepo) { throw "'$RepositoryPath' is not a Git repository, so there is nowhere to put a hook." }
    $HooksDir = Join-Path -Path $RepositoryPath -ChildPath ((Invoke-Git -Arguments @('rev-parse', '--git-path', 'hooks')) -join '')
    $HookPath = Join-Path -Path $HooksDir -ChildPath 'pre-commit'

    if ($RemoveHook) {
        if (-not (Test-Path -LiteralPath $HookPath)) {
            Write-Info 'There is no pre-commit hook to remove.' 'Yellow'
        }
        elseif ((Get-Content -LiteralPath $HookPath -Raw) -notmatch [regex]::Escape($HookMarker)) {
            # Somebody else's hook - deleting it is not this script's business.
            throw "The pre-commit hook at '$HookPath' was not installed by this script. Remove it yourself if that is what you want."
        }
        else {
            Remove-Item -LiteralPath $HookPath -Force
            Write-Info "Removed the pre-commit hook: $HookPath" 'Green'
        }
        exit 0
    }

    if ((Test-Path -LiteralPath $HookPath) -and ((Get-Content -LiteralPath $HookPath -Raw) -notmatch [regex]::Escape($HookMarker))) {
        throw "A different pre-commit hook already exists at '$HookPath'. Move it aside first, or add the line from this script's -InstallHook output to it."
    }
    if (-not (Test-Path -LiteralPath $HooksDir)) { New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null }
    # Git runs the hook through sh, so it needs LF line endings and no byte-order mark.
    Set-FileText -Path $HookPath -Text ($HookBody -replace "`r`n", "`n") -HasBom $false
    Write-Info "Installed the pre-commit hook: $HookPath" 'Green'
    Write-Info '  Every commit now stamps a fresh version into the scripts and includes it in that commit.'
    Write-Info '  Remove it again with: .\tools\Update-Version.ps1 -RemoveHook'
    exit 0
}

# --- Work out which files to stamp ---
$Targets = $VersionedFiles
if ($StagedOnly) {
    if (-not $IsGitRepo) { throw "'$RepositoryPath' is not a Git repository, so nothing can be staged." }
    $Staged = @(Invoke-Git -Arguments @('diff', '--cached', '--name-only', '--diff-filter=ACMR') | ForEach-Object { "$_".Trim() })
    $Targets = @($VersionedFiles | Where-Object { $Staged -contains ($_ -replace '\\', '/') })
    $SourceStaged = @($Staged | Where-Object { $_ -like 'src/*' }).Count -gt 0
    if ($SourceStaged) {
        $Targets = @($Targets + $SourceVersionedFiles | Select-Object -Unique)
    }
    elseif ($Staged -contains $CombinedScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BuildScript -Check | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$CombinedScript is generated and has been edited by hand. Make the change in src\, then run tools\Build-Script.ps1." }
    }
    if ($Targets.Count -eq 0) {
        Write-Info 'No versioned files are staged, so the version is left alone.' 'DarkGray'
        exit 0
    }
}

$Targets = @($Targets | Where-Object { Test-Path -LiteralPath (Join-Path $RepositoryPath $_) })
if ($Targets.Count -eq 0) { throw 'None of the versioned files were found in this repository.' }

# --- Work out the new version ---
# The first versioned file is the reference, so every file always ends up on the same number.
$Primary = Get-FileText -Path (Join-Path $RepositoryPath $VersionedFiles[0])
$Current = if ($Primary.Text -match $VersionNumber) { $Matches[0] } else { $null }
$NewVersion = if ($Version) { $Version } else { Get-NextVersion -Current $Current }

if ($Quiet) { Write-Host $NewVersion }
else { Write-Host "Version: $(if ($Current) { "$Current -> " })$NewVersion" -ForegroundColor Cyan }

# --- Stamp it in ---
$Changed = @()
foreach ($Relative in $Targets) {
    $Path = Join-Path -Path $RepositoryPath -ChildPath $Relative
    $File = Get-FileText -Path $Path
    $Text = $File.Text
    $Hits = 0
    foreach ($Marker in $Markers) {
        $Text = [regex]::Replace($Text, $Marker, {
            param($Match)
            return "$($Match.Groups['pre'].Value)$NewVersion$($Match.Groups['post'].Value)"
        })
        # Count the markers found so a file that quietly lost its marker is reported instead of ignored.
        $Hits += ([regex]::Matches($File.Text, $Marker)).Count
    }

    if ($Hits -eq 0) {
        Write-Warning "$Relative has no version marker - add a '# Version: 0000.00.00.0' line to it."
        continue
    }
    if ($Text -eq $File.Text) {
        Write-Info "  $Relative is already at $NewVersion ($Hits marker(s))." 'DarkGray'
        continue
    }
    if ($WhatIfOnly) {
        Write-Info "  $Relative would be updated ($Hits marker(s))." 'Yellow'
        continue
    }
    Set-FileText -Path $Path -Text $Text -HasBom $File.HasBom
    $Changed += $Relative
    Write-Info "  $Relative updated ($Hits marker(s))." 'Green'
}

# Rebuilt even when no marker moved, because the staged change may be in any file in src.
if (-not $WhatIfOnly -and @($Targets | Where-Object { $_ -like 'src\*' }).Count -gt 0) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BuildScript
    if ($LASTEXITCODE -ne 0) { throw 'The combined script could not be built, so the commit was stopped.' }
    $Changed += $CombinedScript
}

if ($Stage -and -not $WhatIfOnly -and $Changed.Count -gt 0) {
    Invoke-Git -Arguments (@('add', '--') + $Changed) | Out-Null
    Write-Info "  Re-staged: $($Changed -join ', ')" 'DarkGray'
}

exit 0
