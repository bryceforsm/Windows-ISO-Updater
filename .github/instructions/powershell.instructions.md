---
description: Layout, output, and post-edit validation conventions for the PowerShell in this repo
applyTo: '**/*.ps1'
---

# PowerShell conventions

The layout, output, and step conventions below describe the script built from `src/`. The formatting,
error, and function rules apply to everything under `tools/` as well.

**Source files.** Edit `src/`, then run `tools/Build-Script.ps1`. `Windows-ISO-Updater.ps1` is generated, so
an edit made there is lost. The number in a file's name sets its position in the script: `01` to `03` are
the header, parameters and startup, `10` to `25` the functions by topic, and `30` to `38` the main flow in
run order. A new file only needs a name that sorts into the right place.

**Layout.** Sections are wrapped in `#region Section Name` / `#endregion` so they fold in VS Code. Order
is header comment, `param()`, elevation and platform guards, folder resolution, transcript start, helper
functions, then the main flow. Every function definition lives inside the single outer `#region Functions`,
which is subdivided by topic (downloads, catalog, stamps, mount recovery, servicing and so on), so the
whole ~3,800 lines of helpers collapse to one line and leave the main flow readable. Close a region with a
bare `#endregion`, and put a blank line between one region and the next.

**Parameters.** Every parameter gets a `HelpMessage` written as a full sentence, plus `ValidateSet`,
`ValidateRange`, or `ValidatePattern` where the domain is known. Defaults are inline.

```powershell
[Parameter(HelpMessage = 'Windows version to download/update: 10 or 11. Defaults to 11')]
[ValidateSet('10', '11')]
[string]$WindowsVersion = '11',
```

**Output.** Use `Write-HostTimestamp`, never bare `Write-Host`, so the line lands in the transcript with
a `[MM/dd/yyyy|HH:mm:ss]` prefix. Colors carry meaning and also set CMTrace severity, so Yellow and Red
change how the log renders. Never pick a color for looks.

| Color | Meaning |
| --- | --- |
| Cyan | A major step is starting |
| Green | Success or a verified result |
| Yellow | Warning or a fallback being taken |
| Red | Fatal error |
| DarkGray | Supporting detail, timings, catalog results |

Sub-items are indented two spaces inside the string itself. Durations go through `Format-Duration`.

**Steps.** Wrap any meaningful unit of work in `Invoke-Task`. It prints the description, times the block
in a `finally`, and appends to `$script:StepTimings` for the summary table at the end.

```powershell
Invoke-Task 'Mounting the install image' {
    # work
}
```

**State.** Cross-function state is `$script:`-scoped and declared near the top with a comment explaining
why it outlives the function. Everything else is PascalCase local scope.

**Functions.** Approved verbs only. Keep them pure enough to be extractable by AST for testing, which is
how this repo tests things. Lasting tests go in `tests/`, and `tools/Invoke-Tests.ps1` runs them.

**Errors.** `throw` for anything fatal, with a message that says what to do about it. `exit 1` for
failure, `exit 0` for success, and `exit 10` specifically for `-CheckOnly` deciding a rebuild is needed.
Clean up mounts and temp files in `finally` blocks, and `Stop-Transcript | Out-Null` before exiting.

**Formatting.** Four spaces, OTBS braces, single quotes unless interpolating, no backtick line
continuations.

**Renames.** Renaming a term means renaming it in every `HelpMessage` and inline example variable that
used the old term, in the same pass.

## Validate every edit

Run this once instead of three round trips. It proves syntax only.

```powershell
.\tools\Build-Script.ps1   # also refuses to write a script that does not parse
$p = 'Windows-ISO-Updater.ps1'; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $p), [ref]$null, [ref]$e) | Out-Null
if ($e) { $e | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } } else { 'No parse errors' }
$t = Get-Content $p
'regions: {0} / endregions: {1}' -f ($t | Select-String '^\s*#region').Count, ($t | Select-String '^\s*#endregion').Count
```

Unbalanced regions mean an edit landed inside the wrong block, which parses fine and folds wrong.

## AutoClean compatibility

`Invoke-AutoClean` finds old ISOs two ways, `Output.Path` from the build stamps and a regex fallback that
scans the output folder for files whose stamps have aged out. When an edit touches `Get-DefaultIsoName`,
`IsoNamePrefix`, `IsoNameSuffix`, or the output path assembly in
`#region Decide the output ISO name and volume label`, verify that the `$GeneratedName` regex in
`Invoke-AutoClean` still matches every file name the script can now produce, and update it in the same
edit if it does not.
