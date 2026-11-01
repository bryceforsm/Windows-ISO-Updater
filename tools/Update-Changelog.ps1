<#
.SYNOPSIS
    Moves the Unreleased section of CHANGELOG.md under the current script version, ready for a release.

.DESCRIPTION
    Commit the result on its own in a pull request. The version only changes when a commit touches src, so
    the heading written here still matches the script once that pull request merges. The Release workflow then
    publishes it, and it refuses to run if the script has moved on from the changelog's heading.

.EXAMPLE
    .\tools\Update-Changelog.ps1
    Turns "## [Unreleased]" into a heading that links to the release, "## [2026.10.31.5](<url>) - 2026-10-31",
    and adds a new empty Unreleased section.

.EXAMPLE
    .\tools\Update-Changelog.ps1 -WriteNotesTo notes.md
    Leaves the changelog alone, and writes the current version's notes to notes.md. Fails if it has no
    section. The Release workflow uses this.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Repository to work on. Defaults to the repository this script lives in')]
    [string]$RepositoryPath,

    [Parameter(HelpMessage = 'Write the notes for the current version to this file instead of changing the changelog')]
    [string]$WriteNotesTo
)

$ErrorActionPreference = 'Stop'
# Set here because $PSScriptRoot is empty in a parameter default under Windows PowerShell 5.1.
if (-not $RepositoryPath) { $RepositoryPath = Split-Path -Parent $PSScriptRoot }
$ChangelogFile = Join-Path -Path $RepositoryPath -ChildPath 'CHANGELOG.md'
$ScriptFile = Join-Path -Path $RepositoryPath -ChildPath 'Windows-ISO-Updater.ps1'

if ([System.IO.File]::ReadAllText($ScriptFile) -notmatch "(?m)^\s*\`$ScriptVersion\s*=\s*'([\d.]+)'") {
    throw "Could not read `$ScriptVersion from $ScriptFile."
}
$Version = $Matches[1]

$Original = [System.IO.File]::ReadAllText($ChangelogFile)
$NewLine = if ($Original -match "`r`n") { "`r`n" } else { "`n" }
$Text = $Original -replace '\r?\n', "`n"

# Returns the match for a section's heading and body, which runs up to the next section or the end of the file.
function Get-Section {
    param([string]$Heading)
    return [regex]::Match($Text, "(?ms)^## \[$([regex]::Escape($Heading))\][^\n]*\n(?<body>.*?)(?=^## \[|\z)")
}

$Existing = Get-Section -Heading $Version

if ($WriteNotesTo) {
    if (-not $Existing.Success) {
        throw "CHANGELOG.md has no section for $Version. Run tools\Update-Changelog.ps1 and merge the result, or if it was already run, the script has changed since then and needs running again."
    }
    # A file rather than the console, which could wrap long lines or mangle non-ASCII characters.
    [System.IO.File]::WriteAllText($WriteNotesTo, $Existing.Groups['body'].Value.Trim() + "`n", (New-Object System.Text.UTF8Encoding($false)))
    exit 0
}

if ($Existing.Success) {
    throw "CHANGELOG.md already has a section for $Version, so this version may already be released. Run tools\Update-Version.ps1 to move to a new version first."
}

$Unreleased = Get-Section -Heading 'Unreleased'
if (-not $Unreleased.Success) { throw 'CHANGELOG.md has no "## [Unreleased]" section.' }
$Entries = @($Unreleased.Groups['body'].Value -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^#{3,}\s' })
if ($Entries.Count -eq 0) { throw 'The Unreleased section of CHANGELOG.md is empty, so there is nothing to release.' }

$ReleaseUrl = "https://github.com/bryceforsm/Windows-ISO-Updater/releases/tag/$Version"
$Released = "## [Unreleased]`n`n## [$Version]($ReleaseUrl) - $(Get-Date -Format 'yyyy-MM-dd')`n$($Unreleased.Groups['body'].Value)"
$Updated = $Text.Substring(0, $Unreleased.Index) + $Released + $Text.Substring($Unreleased.Index + $Unreleased.Length)
[System.IO.File]::WriteAllText($ChangelogFile, ($Updated -replace "`n", $NewLine), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "CHANGELOG.md is ready for $Version. Commit only this file in a pull request, merge it, then run the Release workflow."
exit 0
