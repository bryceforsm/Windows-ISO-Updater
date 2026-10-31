<#
.SYNOPSIS
    Combines the files in src\ into Windows-ISO-Updater.ps1.

.DESCRIPTION
    src\ is what gets edited, and Windows-ISO-Updater.ps1 is what gets released, run and read on GitHub. The
    files are joined in name order with nothing between them, so a file's position is set by its number.
    Nothing here runs the script. Exits 0 on success, and 1 when a parse fails or -Check finds a stale file.

.EXAMPLE
    .\tools\Build-Script.ps1
    Rebuilds Windows-ISO-Updater.ps1. The pre-commit hook does this on every commit that touches src\.

.EXAMPLE
    .\tools\Build-Script.ps1 -Check
    Writes nothing, and fails if Windows-ISO-Updater.ps1 does not match src\. CI runs this.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Fail if the combined script does not match src, without writing anything')]
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutputFile = Join-Path -Path $RepoRoot -ChildPath 'Windows-ISO-Updater.ps1'
$Banner = "# GENERATED FILE. Edit the files in src\ and run tools\Build-Script.ps1, because changes made here are overwritten.`r`n"

# Ordinal, so the order cannot change with the culture of the machine doing the build.
[string[]]$Names = @(Get-ChildItem -LiteralPath (Join-Path -Path $RepoRoot -ChildPath 'src') -Filter '*.ps1' -File | ForEach-Object { $_.Name })
if ($Names.Count -eq 0) { throw 'No source files were found in src.' }
[array]::Sort($Names, [StringComparer]::Ordinal)

$Builder = New-Object System.Text.StringBuilder
[void]$Builder.Append($Banner)
foreach ($Name in $Names) {
    $Text = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'src') -ChildPath $Name))
    # Windows PowerShell 5.1 reads a file with no byte-order mark as ANSI, so anything else would be mangled at run time.
    if ($Text -match '[^\x00-\x7F]') { throw "src\$Name contains a non-ASCII character. The combined script has to stay ASCII." }
    [void]$Builder.Append(($Text -replace '\r?\n', "`r`n"))
}
$Combined = $Builder.ToString()

$ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($Combined, [ref]$null, [ref]$ParseErrors) | Out-Null
if ($ParseErrors) {
    # Line numbers are in the combined script, because a block can span two source files.
    foreach ($ParseError in $ParseErrors) { Write-Host "Line $($ParseError.Extent.StartLineNumber): $($ParseError.Message)" -ForegroundColor Red }
    Write-Host 'The combined script does not parse, so nothing was written.' -ForegroundColor Red
    exit 1
}

if ($Check) {
    $Current = if (Test-Path -LiteralPath $OutputFile) { [System.IO.File]::ReadAllText($OutputFile) } else { '' }
    # Compared without line endings, because Git may have checked the file out with either kind.
    if (($Current -replace '\r?\n', "`n") -cne ($Combined -replace '\r?\n', "`n")) {
        Write-Host 'Windows-ISO-Updater.ps1 does not match src. Edit src\, then run tools\Build-Script.ps1.' -ForegroundColor Red
        exit 1
    }
    Write-Host "Windows-ISO-Updater.ps1 matches the $($Names.Count) files in src."
    exit 0
}

[System.IO.File]::WriteAllText($OutputFile, $Combined, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Built Windows-ISO-Updater.ps1 from $($Names.Count) files in src."
exit 0
