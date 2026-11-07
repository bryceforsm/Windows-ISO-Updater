---
description: File ownership and house style for README.md and the docs folder
applyTo: 'docs/**/*.md,README.md'
---

# Documentation

`README.md` is the front door and stays skimmable. Detail lives in `docs/`. Open the one file that owns
the subject rather than reading the folder to work out where something goes, which costs roughly 26k
tokens for a decision this table already makes.

| File | Owns |
| --- | --- |
| `usage.md` | How to run it, worked examples, scenario walkthroughs |
| `parameters.md` | The parameter tables. Change one and update its `HelpMessage` in the same pass |
| `reference.md` | Flow diagram, folder layout, logging, disk space, the build record written onto the ISO |
| `scheduled-runs.md` | Task registration, build stamps, rebuild decisions, `-AutoClean` |
| `design-notes.md` | Why something works the way it does, tradeoffs taken, alternatives rejected |
| `unattended-installs.md` | Answer files with `-UnattendPath`, and the `Examples/` answer file |

If a change genuinely spans two files, put the mechanism in the owning file and a one-line pointer in
the other.

Write for someone running this on their own hardware. Say what to do and what happens, not what the code
does internally, unless the file is `docs/design-notes.md`, where the internals are the point.

Each doc ends with a `[← Back to README](../README.md)` link, paths and parameters are in backticks, and
parameter listings are tables. Do not create new markdown files to describe changes you just made.

## Style check before finishing

Check only the files you edited, style and back-link in one pass. Scanning all of `docs/` re-reads six
files to validate two.

```powershell
foreach ($f in @('docs\usage.md')) {   # list only the files you edited
    Select-String -Path $f -Pattern '—|–' |
        ForEach-Object { "$($_.Filename):$($_.LineNumber) $($_.Line.Trim())" }
    if ((Get-Content $f -Tail 1) -notmatch '\[← Back to README\]') { "$f : missing back-link" }
}
```
