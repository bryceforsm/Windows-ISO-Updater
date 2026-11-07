---
description: Semantics and editing rules for the autounattend answer file in Examples/
applyTo: 'Examples/**/*.xml'
---

# The answer file in `Examples/`

`autounattend-update-after-setup.xml` is fed to the script via `-UnattendPath`. It is hand-written for
this repository, not generated, and its header comment is the user-facing description of what it does.

- **It takes over nothing in Setup.** It only adds two `RunSynchronous` commands to the `specialize`
  pass: one that writes the embedded script to disk, and one that runs it with `-Register` to create
  the startup task. Keep it that way. Anything that answers a Setup question, partitions a disk or
  skips OOBE changes what the file is, and breaks the promise in its header and in
  `docs/unattended-installs.md` that it is safe on any ISO.
- **Both architectures carry the same commands.** The `amd64` and `arm64` `Microsoft-Windows-Deployment`
  components must stay identical, because Setup only runs the one that matches the media.
- **Payloads are wrapped in CDATA,** so they need no XML escaping and must never contain `]]>`. Because
  of the CDATA, the extraction command reads `$xml.unattend.Extensions.ExtractScript.InnerText`. Without
  `.InnerText` the property is the element, which turns into the literal text "System.Xml.XmlElement".
- **The `<Extensions>` namespace is `https://github.com/bryceforsm/Windows-ISO-Updater/unattend`.**
  `tools/Test-Dependencies.ps1` finds the payloads by it, so change both together.
- **The payload runs as SYSTEM under Windows PowerShell 5.1**, first during `specialize` and then from
  the startup task. It must never restart the computer, never install feature updates or optional
  (`BrowseOnly`) updates, and always remove its own task once there is nothing left to do or after
  `$MaxRuns`.
- **Update the header comment and `docs/unattended-installs.md`** in the same edit when the behaviour
  changes, so neither describes something the file no longer does.

## Validate, parse only

Never execute a payload script to check it. It installs updates and registers a task as SYSTEM.

```powershell
$ErrorActionPreference = 'Stop'
$f = 'Examples\autounattend-update-after-setup.xml'
$doc = New-Object System.Xml.XmlDocument
$doc.Load((Resolve-Path -LiteralPath $f))
$mgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$mgr.AddNamespace('e', 'https://github.com/bryceforsm/Windows-ISO-Updater/unattend')
$bad = 0
foreach ($node in $doc.SelectNodes('//e:File | //e:ExtractScript', $mgr)) {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseInput($node.InnerText, [ref]$null, [ref]$errs) | Out-Null
    if ($errs) { $bad++; $errs | ForEach-Object { "  $($_.Extent.StartLineNumber): $($_.Message)" } }
}
# What the specialize command will hand to [scriptblock]::Create, read but not run.
$x = [xml]::new(); $x.Load((Resolve-Path $f).Path)
"{0}: XML ok, {1} payload error(s), extraction script starts '{2}'" -f $f, $bad, $x.unattend.Extensions.ExtractScript.InnerText.Trim().Split("`n")[0]
```

XML that fails to load, payloads that fail to parse, and an extraction script that does not start with
`param(` are all blocking.
