<#
.SYNOPSIS
    Renders a mock console screenshot of a Windows ISO Updater run as an SVG, for the README.

.DESCRIPTION
    A real build needs administrator rights, an ISO and the best part of an hour, so the README image is
    drawn from a scripted transcript instead. The lines below copy the messages the script prints, in the
    same [MM/dd/yyyy|HH:mm:ss] format and console colors, inside a Windows Terminal style frame.

    The clock is fixed and only moves when the transcript says so, and each step's "Step finished in" line,
    the longest step and the total run time are worked out from that clock. Rendering the same transcript twice gives
    the same file, so the SVG only changes in a diff when the transcript, the version or the layout does.

    When a message in src\ changes wording, change it here too, so the picture keeps matching the script.

.EXAMPLE
    .\tools\New-ReadmeScreenshot.ps1
    Writes docs\images\console.svg, stamped with the version in src\03-Startup.ps1.

.EXAMPLE
    .\tools\New-ReadmeScreenshot.ps1 -Columns 140 -OutputPath "$env:TEMP\console.svg"
    Renders a wider window somewhere else.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Where the SVG is written')]
    [string]$OutputPath,

    [Parameter(HelpMessage = 'Console width in characters. Longer lines wrap between words, as the script wraps them')]
    [ValidateRange(60, 220)]
    [int]$Columns = 100,

    [Parameter(HelpMessage = 'Version shown in the header. Defaults to the one in src\03-Startup.ps1')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path -Path $RepoRoot -ChildPath 'docs\images\console.svg' }
if (-not $Version) {
    $Startup = Get-Content -LiteralPath (Join-Path -Path $RepoRoot -ChildPath 'src\03-Startup.ps1') -Raw
    if ($Startup -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Version = $Matches[1] }
    else { throw 'Could not read $ScriptVersion from src\03-Startup.ps1. Pass -Version instead.' }
}

#region Transcript helpers
# Fixed, so every render of the same transcript is byte-identical.
$script:Clock = [datetime]::new(2026, 10, 14, 9, 12, 3)
$script:RunStart = $script:Clock
$script:Lines = [System.Collections.Generic.List[psobject]]::new()
$script:Steps = [System.Collections.Generic.List[psobject]]::new()

# Durations and line wrapping come from the script itself, lifted out of its AST the way tests\ does, so the
# picture wraps and times exactly as a real run would. The script is never run.
$ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $RepoRoot -ChildPath 'Windows-ISO-Updater.ps1'), [ref]$null, [ref]$null)
foreach ($Name in 'Format-Duration', 'Format-WrappedText') {
    $Definition = $ScriptAst.Find({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
        }, $true)
    if (-not $Definition) { throw "Windows-ISO-Updater.ps1 no longer defines $Name." }
    . ([scriptblock]::Create($Definition.Extent.Text))
}

# Write-HostLog. Continuations are indented by -Indent, as Write-HostTimestamp and Write-HostLog do.
function Add-Raw {
    param([string]$Text = '', [string]$Color = 'Gray', [int]$Indent = 0)
    foreach ($Part in (Format-WrappedText -Text $Text -Width $Columns -Indent $Indent)) {
        $script:Lines.Add([pscustomobject]@{ Text = $Part; Color = $Color })
    }
}

# Write-HostTimestamp. -Wait moves the clock forward before the line is stamped.
function Add-Line {
    param([string]$Text, [string]$Color = 'Gray', [double]$Wait = 0)
    $script:Clock = $script:Clock.AddSeconds($Wait)
    $Stamp = $script:Clock.ToString('[MM/dd/yyyy|HH:mm:ss]', [System.Globalization.CultureInfo]::InvariantCulture)
    # The same indent Write-HostTimestamp works out: under the message, including its own leading spaces.
    $Indent = $Stamp.Length + 1 + ($Text.Length - $Text.TrimStart().Length)
    Add-Raw -Text "$Stamp $Text" -Color $Color -Indent $Indent
}

function Add-Rule { Add-Raw -Text ('-' * $Columns) }

# A PowerShell prompt, coloured the way PSReadLine colours what is typed after it. Each segment is a piece
# of text and its console colour, and the whole line has to fit in -Columns.
function Add-Prompt {
    param([object[]]$Segments)
    $script:Lines.Add([pscustomobject]@{ Text = (($Segments | ForEach-Object { $_[0] }) -join ''); Color = 'Gray'; Segments = $Segments })
}

# Invoke-Task: the description, whatever the step prints, then its duration and a rule.
function Add-Step {
    param([string]$Description, [scriptblock]$Body, [double]$Wait = 0)
    Add-Line $Description -Wait $Wait
    $Start = $script:Clock
    & $Body
    $Elapsed = $script:Clock - $Start
    $script:Steps.Add([pscustomobject]@{ Description = $Description; Duration = $Elapsed })
    Add-Line "  Step finished in $(Format-Duration $Elapsed)." -Color DarkGray
    Add-Rule
}
#endregion

#region Transcript
# A Windows 11 25H2 build from an ISO dropped into the download folder, with the default edition trimming.
# The KB numbers, builds, timings and machine name are made up to look right, not to be right. Don't look
# too closely ;)
$Iso = 'C:\WISO-Work\Downloads\Win11_25H2_English_x64.iso'
$Output = 'C:\WISO-Work\Output\Win11_25H2_Pro_x64_en-US_26200.7019_20261014-1003.iso'

Add-Prompt @(@('PS C:\WISO> ', 'Gray'), @('.\Windows-ISO-Updater.ps1', 'Yellow'), @(' -Unattended', 'DarkGray'))
Add-Rule
Add-Line "Windows ISO Updater v$Version (slipstream latest updates into a new ISO) on LAB-BUILD01" -Color Cyan
Add-Line 'Run date       : October 14th 2026'
Add-Rule
Add-Line 'Free space on the working drive: 412 GB'
Add-Rule
Add-Line "An ISO is already downloaded - reusing it: $Iso (7.31 GB)" -Color Green
Add-Rule
Add-Step "Extracting the ISO contents to C:\WISO-Work\Extract ..." {
    Add-Line '  Extraction complete.' -Color Green -Wait 94
    Add-Line '  Dismounted the source ISO.' -Color DarkGray -Wait 1
}
Add-Line 'Image build    : 10.0.26200.6584 (25H2)'
Add-Line 'Image arch     : amd64'
Add-Line 'Keeping only the Enterprise, Pro and Home editions the media carries to speed up the build: Windows 11 Home, Windows 11 Pro, Windows 11 Enterprise. Use -KeepAllEditions to keep them all, or -KeepEditions to choose.' -Color Cyan
Add-Rule
Add-Step 'Downloading the latest cumulative update from the Microsoft Update Catalog...' {
    Add-Line '  Selected: 2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5071021) (released October 13th 2026)' -Color Green -Wait 4
    Add-Line '  Found 2 package(s).' -Color Green -Wait 148
}
Add-Step 'Servicing install.wim index 3 (Windows 11 Pro)...' {
    Add-Line '    Mounting the image...' -Wait 2
    Add-Line '    Servicing the recovery image (winre.wim)...' -Wait 38
    Add-Line '    Applying updates to install.wim...' -Wait 315
    Add-Line '    Cleaning up the component store (/StartComponentCleanup /ResetBase)...' -Wait 742
    Add-Line '    Committing and unmounting...' -Wait 486
    Add-Line '    Index 3 done.' -Color Green -Wait 97
}
Add-Step 'Servicing boot.wim index 2 (Microsoft Windows Setup (amd64))...' {
    Add-Line '    boot.wim index 2 done.' -Color Green -Wait 263
}
Add-Step "Recompiling the bootable ISO to $Output ..." {
    Add-Line '  Volume label: W11_25H2_X64_2610' -Color DarkGray -Wait 1
    Add-Line '  New ISO created (6.84 GB).' -Color Green -Wait 171
}

# The real run prints a per-step timing table here. It is left out to keep the image a sensible height.
$Slowest = $script:Steps | Sort-Object -Property Duration -Descending | Select-Object -First 1
Add-Line "Longest step: $($Slowest.Description) ($(Format-Duration $Slowest.Duration))" -Color DarkGray
$Finished = $script:Clock.AddSeconds(2)
Add-Line ('Total run time: {0} (started {1}, finished {2})' -f (Format-Duration ($Finished - $script:RunStart)), $script:RunStart.ToString('HH:mm:ss'), $Finished.ToString('HH:mm:ss')) -Color Cyan -Wait 2
Add-Rule
Add-Line 'Done. Your updated Windows installation ISO is ready:' -Color Green
Add-Line "  $Output" -Color Green
Add-Line '  Open \WISO-Build on the ISO for the record of how it was built.' -Color DarkGray
Add-Rule
Add-Line 'Windows ISO Updater script finished.' -Color Green
Add-Raw
Add-Prompt @(@('PS C:\WISO> ', 'Gray'), @('_', 'Cursor'))
#endregion

#region SVG
# Windows Terminal's "Campbell Powershell" scheme: the console blue Windows PowerShell has always opened in,
# with the Campbell colours on top. Cursor stands in for the blinking cursor at the last prompt.
$Background = '#012456'
$Palette = @{
    Cursor   = '#FFFFFF'
    Gray     = '#CCCCCC'
    DarkGray = '#767676'
    Cyan     = '#61D6D6'
    Green    = '#16C60C'
    Yellow   = '#F9F1A5'
    Red      = '#E74856'
}
$FontSize = 13
$CharWidth = 7.83          # Cascadia Mono and Consolas advance about 0.6 em per character
$LineHeight = 17
$Pad = 14
$TitleBar = 34
$Width = [math]::Ceiling($Pad * 2 + $Columns * $CharWidth)
$Height = [math]::Ceiling($TitleBar + $Pad * 2 + $script:Lines.Count * $LineHeight)
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

function ConvertTo-XmlText {
    param([string]$Text)
    # Browsers collapse runs of spaces in SVG text whatever xml:space says, which would break the indents
    # and column padding. A no-break space is never collapsed and is just as wide in a monospace font.
    return [System.Security.SecurityElement]::Escape($Text).Replace(' ', '&#160;')
}

$Sb = [System.Text.StringBuilder]::new()
$null = $Sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}" role="img" aria-label="Console output of a Windows ISO Updater run">' -f $Width, $Height))
$null = $Sb.AppendLine('  <!-- Generated by tools/New-ReadmeScreenshot.ps1. Edit the transcript there and re-run it rather than editing this file. -->')
$null = $Sb.AppendLine(('  <rect width="{0}" height="{1}" rx="8" fill="{2}"/>' -f $Width, $Height, $Background))
# Windows Terminal's title bar: one tab with the PowerShell icon and its close button, the new-tab and
# profile buttons beside it, and the minimise / maximise / close glyphs on the right.
$null = $Sb.AppendLine(('  <path d="M0 8a8 8 0 0 1 8-8h{0}a8 8 0 0 1 8 8v{1}H0z" fill="#202020"/>' -f ($Width - 16), ($TitleBar - 8)))
$null = $Sb.AppendLine(('  <path d="M8 {0}V12a4 4 0 0 1 4-4h252a4 4 0 0 1 4 4v{1}z" fill="{2}"/>' -f $TitleBar, ($TitleBar - 12), $Background))
$null = $Sb.AppendLine('  <path d="M21 14h14l-3 12H18z" fill="#2F7BD1"/><path d="M23 17l4 3-5 3M27 24h3" stroke="#FFFFFF" stroke-width="1.4" fill="none"/>')
$null = $Sb.AppendLine('  <text x="43" y="25" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="12" fill="#FFFFFF">Administrator: Windows PowerShell</text>')
$null = $Sb.AppendLine('  <g stroke="#CCCCCC" stroke-width="1" fill="none"><path d="M247 17l6 6M253 17l-6 6"/><path d="M284 15v10M279 20h10"/><path d="M304 18l4 4 4-4"/></g>')
$null = $Sb.AppendLine(('  <g stroke="#CCCCCC" stroke-width="1" fill="none"><path d="M{0} 17h10"/><rect x="{1}" y="12" width="9" height="9"/><path d="M{2} 12l9 9M{3} 12l-9 9"/></g>' -f ($Width - 128), ($Width - 82), ($Width - 36), ($Width - 27)))
$null = $Sb.AppendLine(('  <g font-family="Cascadia Mono, Consolas, Menlo, DejaVu Sans Mono, monospace" font-size="{0}">' -f $FontSize))
$Y = $TitleBar + $Pad + $FontSize
foreach ($Line in $script:Lines) {
    if ($Line.PSObject.Properties['Segments']) {
        $Spans = foreach ($Seg in $Line.Segments) {
            $Fill = $Palette[$Seg[1]]
            if (-not $Fill) { throw "No palette entry for console color '$($Seg[1])'." }
            '<tspan fill="{0}">{1}</tspan>' -f $Fill, (ConvertTo-XmlText $Seg[0])
        }
        $null = $Sb.AppendLine(('    <text x="{0}" y="{1}">{2}</text>' -f $Pad, $Y.ToString($Inv), ($Spans -join '')))
    }
    elseif ($Line.Text.Length -gt 0) {
        $Fill = $Palette[$Line.Color]
        if (-not $Fill) { throw "No palette entry for console color '$($Line.Color)'." }
        $null = $Sb.AppendLine(('    <text x="{0}" y="{1}" fill="{2}">{3}</text>' -f $Pad, $Y.ToString($Inv), $Fill, (ConvertTo-XmlText $Line.Text)))
    }
    $Y += $LineHeight
}
$null = $Sb.AppendLine('  </g>')
$null = $Sb.AppendLine('</svg>')

$OutDir = Split-Path -Parent $OutputPath
if ($OutDir -and -not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir }
# LF and no BOM, so the file diffs the same whichever PowerShell wrote it.
[System.IO.File]::WriteAllText($OutputPath, ($Sb.ToString() -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath ($($script:Lines.Count) lines, ${Width}x${Height})" -ForegroundColor Green
#endregion
