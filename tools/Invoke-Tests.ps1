<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester tests, the same way CI does.

.DESCRIPTION
    Nothing here runs Windows-ISO-Updater.ps1. Exits 0 when everything passes and 1 otherwise. Needs Pester 5
    and PSScriptAnalyzer. Windows ships Pester 3, which cannot run these tests.

.EXAMPLE
    Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -SkipPublisherCheck -Force
    Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

Import-Module PSScriptAnalyzer
Import-Module Pester -MinimumVersion 5.0

$Settings = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
$Findings = @(
    Invoke-ScriptAnalyzer -Path (Join-Path -Path $RepoRoot -ChildPath 'Windows-ISO-Updater.ps1') -Settings $Settings
    Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings $Settings
)
foreach ($Finding in $Findings) {
    Write-Host "$($Finding.ScriptName):$($Finding.Line) [$($Finding.RuleName)] $($Finding.Message)" -ForegroundColor Red
}
Write-Host "PSScriptAnalyzer: $($Findings.Count) finding(s)."

$Configuration = New-PesterConfiguration
$Configuration.Run.Path = Join-Path -Path $RepoRoot -ChildPath 'tests'
$Configuration.Run.PassThru = $true
$Configuration.Output.Verbosity = 'Normal'
$Result = Invoke-Pester -Configuration $Configuration

if ($Findings.Count -gt 0 -or $Result.Result -ne 'Passed') { exit 1 }
exit 0
