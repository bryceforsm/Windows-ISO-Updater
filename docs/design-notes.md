[← Back to README](../README.md)

# Design Notes

## Why This Exists

The slowest part of standing up a new Windows machine is not the install. Setup itself finishes in minutes. What takes the rest of the afternoon is the first trip through Windows Update, where a cumulative update that is months behind gets downloaded, staged, installed and rebooted through, while you sit and watch. Do that on one machine and it is an annoyance. Do it on a lab, a classroom or a rack of hosts and it is the whole day.

The updates can obviously wait until later, and often they are told to. That still breaks the thing that matters, which is getting a production-ready system in front of someone quickly. A machine that is installed but not yet patched is not finished. It cannot be handed over, it cannot be imaged from, and it will pick its own moment to reboot. The work is not gone, it is just deferred to a worse time.

Skipping the updates outright is worse still, and how much worse depends entirely on how old the source media is. A months-old ISO is missing every fix published since it was cut, so the machine is exposed for as long as it stays that way. Age also causes plain compatibility trouble. Older media can be missing the servicing stack a current update expects, which is what `0x800F0823` means when it appears, and driver and feature support that shipped in later revisions is simply not there yet.

Slipstreaming the update into the media instead moves all of that work to a machine that has time for it. The install starts already patched, and the hour it used to cost happens once, on the build machine, rather than once per deployment.

There are two more wins that come along for free.

**The image is a real `install.wim` again.** Where you get the ISO decides what compression it uses. The Media Creation Tool and most consumer download routes hand you `install.esd`, which is LZMS "recovery" compressed. It is much smaller on disk, but every byte has to be decompressed during apply, and that is CPU-bound work that makes Setup noticeably slower on modest hardware. This script converts `install.esd` to an editable `install.wim` before it services anything, and writes an `install.wim` back out by default, so the finished media applies faster than what you started with. `-CompressEsd` is there if you would rather have the small file, which is mostly useful for getting under the 4 GB FAT32 limit on a UEFI USB stick.

**The ISO carries only the editions you actually deploy.** Retail media ships eleven or so editions you will never install, and all of them are paid for in size and in the length of the edition-picker during Setup. By default the build keeps Enterprise, Pro and Home on client media (whichever of the three the media carries), or a single edition on Server, and `-KeepEditions` lets you name exactly what stays. Between that and the component-store cleanup, the output is usually smaller than the source despite carrying months of extra updates.

## Why Build From Media That Is Already Current

Sometimes the answer comes back that the image already has this month's cumulative update, and the script says so and skips it. That is not a wasted run. The cumulative update is the slowest thing a build does, but it is a long way from being most of what a build does.

**Setup and recovery are patched separately from the OS.** Microsoft publishes the Setup Dynamic Update and the Safe OS Dynamic Update to the Update Catalog rather than into the media, on their own schedule, so no ISO is ever current on them no matter how recently it was cut. The Setup DU refreshes the loose Windows Setup files in the media's `sources` folder, and on Windows 11 24H2 and later, media without it can stop at a bare *"Windows 11 installation has failed"* before it gets anywhere near installing. Both Dynamic Updates are selected from releases up to and including the LCU release date, so neither gets ahead of the OS they are being paired with. The Safe OS DU is the only supported way to patch `winre.wim`, which the cumulative update applied to `install.wim` does not touch at all, so a machine deployed from perfectly patched media routinely ends up with a recovery environment months behind the system it exists to repair. Windows does replace the on-disk recovery image eventually, but [only on some rollup updates](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-recovery-environment--windows-re--technical-reference), and if the new image does not fit it shrinks the Windows partition or orphans the recovery partition to make room. Closing the gap on the media instead is deterministic and costs nothing at deployment time, which is why it is on by default and `-SkipWinRE` is the way out.

Committing a serviced `winre.wim` appends the update rather than replacing what it supersedes, so the build also runs `/StartComponentCleanup /ResetBase` against the recovery image and re-exports it at maximum compression before it goes back into `install.wim`. Without that the recovery image ships hundreds of megabytes larger than it needs to be, which matters more here than anywhere else on the media: Setup sizes the recovery partition for it at install time, and a layout that hardcodes a small one has nowhere to put the difference. The work is skipped entirely when the recovery image is already at the build the Safe OS DU delivers, which is read from the WIM header without mounting anything.

Every edition carries its own copy of `winre.wim`, so servicing one index leaves the others alone, but on a given medium they are normally the same image. Nothing inside a recovery environment is edition-specific, and the WIM stores the identical copies once. So the build hashes each edition's recovery image before touching it, does the real work for the first one, and drops that serviced result straight into every later edition whose source hashes the same. On three-edition client media that turns three mount, patch, clean and re-export cycles into one. Hashing rather than assuming is what makes it safe: media that really does ship a different recovery image per edition simply misses the cache and gets serviced properly.

The build each recovery image is at gets read from its WIM header, which needs no mount and so happens even under `-SkipWinRE`, and it is reported per edition at the end of the run and written into the build record on the media. That header can be trusted here in a way `install.wim`'s cannot, because the Safe OS DU rebuilds and re-stamps the recovery image rather than patching it in place. It is the one number that says what a machine deployed from this ISO will actually boot into when Windows will not start.

**.NET runs on its own calendar.** The .NET Framework cumulative update is a separate package with its own release cadence, so media that is current on the OS update is usually still behind on .NET.

**Most of the run is not updates at all.** The `install.esd` conversion and the edition trimming above happen at any patch level, and so does everything the build exists to put on the media: drivers with `-DriverPath`, the answer file with `-UnattendPath`, your own files with `-ExtraFilesPath`, and the [build record](reference.md#the-build-record-on-the-iso) that tells whoever finds the ISO a year from now exactly what went into it and what it was made from. Those are the reasons to build a deployment ISO in the first place. The updates are just the part that used to cost an afternoon.

**Asking is cheap, and the answer expires.** Deciding that an image is already patched costs a catalog lookup and a read-only mount rather than a servicing pass, and [`-CheckOnly`](scheduled-runs.md#when-a-run-decides-to-rebuild) answers the question without building anything at all. So the useful way to read a run that skips the update is not "there was no point", it is "the media is still good this month". Point a scheduled task at it and the same run that costs minutes today is the one that catches the next Patch Tuesday on its own, which is the whole reason the rebuild-avoidance model exists.

## Why the ISO Has to Come From You

The script does not download a Windows ISO on its own. You pass one with `-IsoPath` or drop one into the download folder, and if neither is there the run stops and tells you so. The automatic download exists, but it is opt-in behind `-UseFido`, and that is deliberate.

It leans on the community [Fido](https://github.com/pbatard/Fido) helper, which asks Microsoft's software-download servers for a link the same way the download page does. Microsoft treats repeated automated requests as abuse, and blocks are common enough that they should be expected rather than treated as a fault:

- *"Error: Sentinel marked this request as rejected"*
- a *715-123130* error on the download page
- a link that resolves but returns an HTML error page instead of 8 GB of ISO

The block is usually per-IP and temporary, so `-UseFido` retries a few times with a growing delay (`-FidoRetryCount`, two extra attempts by default), and the script can then offer Microsoft's Media Creation Tool because MCT talks to different servers and often still works. Both are workarounds for a problem you can avoid outright, and neither is something to build a monthly routine on.

Making the download opt-in also keeps third-party code out of a default run. Fido is not signed, so the script pins one commit by SHA-256 and also checks its source, size, contents and behaviour before executing it. None of that happens unless you ask for it.

**Download the ISO once, keep it, and point every build at it.** Get it from [microsoft.com/software-download](https://www.microsoft.com/software-download), the Media Creation Tool, the Microsoft Evaluation Center, your Volume Licensing Service Center or a Visual Studio subscription:

```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "D:\ISOs\Win11_25H2_original.iso"
```

That is faster on every run after the first, it does not depend on Microsoft's mood, and it is the only option for Windows Server media and Windows 11 LTSC/IoT Enterprise LTSC, which neither Fido nor MCT serves at all. LTSC media comes from the Volume Licensing Service Center, the Evaluation Center, or a Visual Studio or Visual Studio subscription.

It matters most for scheduled tasks. A blocked link request in an unattended run has nothing to fall back on, since the Media Creation Tool cannot run headless, so a task that depends on the automatic download eventually fails for reasons outside your control. A pristine source ISO kept on disk makes the run deterministic, and every build then re-reads the same source, which is exactly what the [rebuild-avoidance model](scheduled-runs.md#when-a-run-decides-to-rebuild) expects.

The one thing to watch is that a source ISO **ages**. It never stops working, because the cumulative update is cumulative, but media several years older than the update can run into `0x800F0823` (*the image needs a newer servicing stack*). Refresh the source ISO once a year or so, and the drift takes care of itself.

## How the Already-Patched Check Works

Integrating a cumulative update is the expensive part of a run (mount, apply, component cleanup, re-export), so the script checks whether the image already has that update before downloading it. Re-applying a present update is harmless (DISM returns `0x800f081e`, "not applicable", and the script treats that as success), but it costs the better part of an hour.

The check has to bridge two things that don't reference each other: the image reports a **build and UBR** (for example `26100.4946`), while the Update Catalog reports a **KB number**. The bridge is the KB's own support page, whose title reads `... KB5062553 (OS Builds 26100.4652 and 26200.4652)`. That gives the UBR the update delivers, before anything is downloaded.

Two sources can answer "is the image already at that UBR", and they trade speed against certainty:

- **By default the WIM header decides.** Its `SPBuild` is read without mounting anything, so the check is instant. If it is at or past the update's UBR the update is skipped, otherwise it is integrated.
- **`-VerifyPatchLevel` reads the image itself.** The image is mounted read-only and its real build is read from the `SOFTWARE` hive, which then decides in both directions. The header is wrong on some media (UUP-built and Media Creation Tool images can report `.1` while being fully patched, or a revision they never shipped with), so this is the switch to reach for when a run keeps re-integrating an update the image already has, or when the source ISO did not come straight from Microsoft.
- If the hive was already read earlier in the run (a release the script had no name for), that read is reused for free and wins over the header even without the switch.
- Anything unknown (support page unreachable, title format changed, hive unreadable, out-of-band release missing from the page) **fails open** and the update is downloaded and applied as usual.

Re-applying an update the image already has only wastes time, since DISM reports it as not applicable. The risk worth knowing about is the other direction, a header that claims a newer revision than the image really carries, which the default trusts and `-VerifyPatchLevel` catches.

When the image is already current, the rest of the media is left alone as well: no .NET update, no Setup or Safe OS Dynamic Update, and no `boot.wim` servicing. Media Microsoft published at the latest cumulative update is already internally consistent, with the loose Setup binaries in `sources` matching the ones inside `boot.wim`. Servicing only some of those parts is how the two drift apart, and Windows 11 Setup Dynamic Update can then fail partway through imaging. `-ReapplyUpdates` overrides this and integrates everything regardless, which is why it carries that warning. It is a build-affecting parameter, so turning it on forces exactly one rebuild and the build stamp then stops it repeating until something else changes.

## How a New Windows Release Is Recognised

Every Update Catalog query the script makes is built around a release name, for example `Cumulative Update for Windows 11 Version 25H2 for x64-based Systems`. Nothing in the WIM header carries that name, only a build number, so the two have to be connected somehow.

A lookup table covers the builds that existed when the script was last touched. That is fast and works offline, but on its own it would rot: when 26H2 or 27H2 ships, its build is not in the table, the version token drops out of the query, and the search widens to every Windows 11 release at once. Since several releases are serviced in parallel and their updates all publish on the same Patch Tuesday, the "newest" result is then effectively arbitrary. The update would download, DISM would reject it as not applicable, and the run would finish with a bootable but unpatched ISO.

So when the table has no answer, the script asks the media instead. Setup records the marketing name in the image's `SOFTWARE` hive as `DisplayVersion`, which is the same value `winver` shows, and mounting read-only to read it is the same trick the already-patched check uses. Media from a release that did not exist when this script was written still says exactly what it is.

The cost is one read-only mount, so it is arranged not to be paid twice:

- Builds already in the table skip this lookup entirely and never mount for the sake of naming the release.
- A run that makes no catalog queries (`-SkipUpdates`, or `-UpdatePath` supplying packages directly) never mounts either, because it has nothing to search for.
- The result is cached for the run, so the already-patched check that follows reuses the same read rather than mounting a second time.

If the image has no `DisplayVersion` either, client media falls back to the broad query with a warning, and Server media stops instead. The Server product name without a version reads `Microsoft server operating system`, which matches every Server release ever published, so a broad search there is guaranteed to return the wrong thing.

## Why the Release Never Changes

The release the media starts on is the release it finishes on. A 24H2 ISO comes out as a fully patched 24H2 ISO, never as 25H2, and a 23H2 ISO stays 23H2. The release name read from the image is what every catalog query is built from, so the script only ever looks for that release's updates.

Moving between releases is a different kind of change from patching one, and Microsoft delivers it in two ways:

| Jump | How Microsoft ships it | Can the script do it? |
| --- | --- | --- |
| Between releases that share a code base, such as 24H2 to 25H2 | A small enablement package that switches on features already present but turned off | Not yet. The package can be added to an offline image with DISM, but the script has no logic to find or apply it. |
| Between releases on different builds, such as 23H2 to 24H2 | A new operating system build, 22631 to 26100 in that case | No. No number of updates turns one build into another, so this needs new media. |

To build the newer release, start from media for that release. Pass a 25H2 ISO with `-IsoPath`, or download one with `-UseFido -Release 25H2`. A machine installed from older media is not stuck there either: Windows Update offers it the feature update once it is online, unless policy holds it back.

## Why Both boot.wim Indexes Are Serviced

`boot.wim` never becomes the installed OS (index 1 is Windows PE, index 2 is Windows Setup), so patching it looks like time that could be saved. It isn't, and both indexes get the same treatment as `install.wim`:

- **Secure Boot revocations.** The media's `bootmgfw.efi` and `bootmgr.efi` are taken from index 2. Once a machine has the CVE-2023-24932 revocations in its DBX and SBAT, media carrying pre-revocation boot managers will not boot at all, and that failure happens before Setup starts, so there is nothing to recover from.
- **Setup binary version match.** The cumulative update raises the version of `setup.exe` and `setuphost.exe` *inside* index 2. If those don't match the loose copies in the media's `sources` folder, Windows Setup fails with errors such as "A media driver your computer needs is missing." The script therefore copies the serviced binaries out of index 2 and overwrites the ones on the media, after the Setup Dynamic Update has been applied.
- **Inbox drivers.** WinPE's storage, NVMe and network drivers come from the cumulative update. An unpatched WinPE on recent hardware can boot to a Setup screen that sees no disks.

Index 1 is serviced as well rather than index 2 alone. It is the repair and recovery environment launched from the media, and leaving two images inside one WIM at different patch levels is a configuration Microsoft neither ships nor tests.

The .NET cumulative update is offered to `boot.wim` along with everything else, even though WinPE has no .NET Framework to patch. DISM reports it as not applicable (`0x800f081e`) and the run continues, which keeps the servicing order identical for every image at the cost of one wasted package expansion per index.

## What Windows Update Will Still Offer

A machine installed from a freshly built ISO still shows a few pending items on its first check for updates. That is expected rather than a gap in the build: the script integrates component-store packages, and Windows Update also delivers things that are not component-store packages at all. Those cannot be slipstreamed by any means.

- **Standalone tools shipped as an `.exe`.** Some Update Catalog entries are ordinary programs rather than servicing packages. The monthly Malicious Software Removal Tool is the one you will see most often. There is nothing inside them for DISM to bind into an offline image, and a fresh build ships every Patch Tuesday, so a baked-in copy would be superseded within weeks and offered again regardless.
- **Definition updates.** Microsoft Defender's security intelligence and the Windows Security platform updates are classified in the catalog as *Definition Updates*, the same category as virus signatures, and also ship as an `.exe`. They are re-released several times a day, so media is stale before the build finishes.

`DISM /Add-Package` only consumes `.msu`/`.cab` packages that bind into the component store by build number, which is exactly what makes a cumulative update integrable and these not. Passing one to `-UpdatePath` fails its `.msu`/`.cab` check.

So they stay a post-install task. Left alone, Windows Update installs them on its own within a day of the machine going online. If you want them handled deterministically, do it from the answer file rather than the media:

- Pull Defender's platform and intelligence updates at first logon with the in-box client, which needs no download URL:
  ```powershell
  & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -SignatureUpdate
  ```
- Stop the removal tool being offered at all, if you consider Defender sufficient, by setting `DontOfferThroughWUAU` to `1` under `HKLM\SOFTWARE\Policies\Microsoft\MRT`.

Neither is worth doing in a gold image before sealing: definitions age out while the image sits in storage, so run them at deployment instead.

## Why Preview Updates Are Left Out

Late each month Microsoft publishes an optional *"Cumulative Update Preview"*, the same rollup that will ship as next month's Patch Tuesday update, released early for organisations that want to test it. The catalog returns it alongside the real one and it is always the newer entry, so picking newest-first would quietly grab it every time. The default is to pass it over.

The reason is that media is not a test machine. An ISO built from a preview installs a build Windows Update will not offer anyone until the following Patch Tuesday, which puts the deployed machine ahead of the fleet it is joining and of whatever your patch baseline is measured against. A preview is also, by Microsoft's own description, not fully validated. It is the wrong thing to stamp into media that will be reused for months.

`-IncludePreview` turns the filter off when testing a coming update against your image is the point. It applies to every catalog query the run makes rather than just the cumulative update, because a preview month is a state to test in, not a package to mix into an otherwise stable set. Because the flag changes what ends up inside the ISO, it is part of the build parameter set, so turning it on or off forces a rebuild rather than the next run deciding nothing has changed.

The title filter that identifies a cumulative update deliberately accepts the "Preview" wording and lets the preview filter make the decision. Excluding previews by making the pattern fail to match them would work by accident, and it would mean `-IncludePreview` silently did nothing.

## Why Not Re-Update an ISO This Script Built

Feeding last month's output back in as next month's input looks like it should save time. It doesn't, and it costs you things that are hard to get back. **Keep the original Microsoft ISO and rebuild from it every time.**

The saving isn't real. Cumulative updates are cumulative, so applying October's LCU to pristine media does the same work as applying it to media patched in September. It is one package either way, of roughly the same size, and every expensive step is identical: extraction, the DISM mount, `/Add-Package`, the `/ResetBase` component cleanup, `Export-WindowsImage` and `oscdimg`. The only step chaining skips is downloading the ISO, which you already skip by keeping the source on disk and passing `-IsoPath`.

What it breaks:

- **The rebuild-avoidance model.** [`Test-RebuildNeeded`](scheduled-runs.md#when-a-run-decides-to-rebuild) keys on the source ISO's SHA-256. Every build produces a new output with a new hash, so if that output becomes the next input, the source never matches the stamp, every scheduled run rebuilds, and `-CheckOnly` always reports that a rebuild is needed.
- **Failures compound silently.** When a package won't apply, the script warns that the edition *"kept its original patch level"* and finishes the ISO anyway. Against pristine media that is one build you throw away. In a chain, that image becomes the base for every build after it and the drift is invisible.
- **Some choices can't be undone.** Editions dropped in one build are gone from every descendant, so you could not get Home back without starting over. Media built with `-CompressEsd` cannot be serviced again at all, because recovery-compressed images are not mountable for servicing.

Component store growth, the one argument that would favour a fresh base, is already handled: each serviced edition gets `/Cleanup-Image /StartComponentCleanup /ResetBase`, so superseded components are stripped rather than accumulating build over build.

The intended setup is a pristine ISO kept somewhere permanent, with its own working folder:

```bat
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean ^
  -IsoPath "D:\ISOs\Win11_25H2_original.iso" -WorkPath "D:\WISO\Win11"
```

`-AutoClean` prunes old outputs and superseded update packages on its own, and because it only deletes files a stamp recorded, the source ISO is never touched.

## Why Re-Exporting Shrinks the Image

Every serviced image in the build gets exported to a new file afterwards, which looks like an expensive copy for nothing. It is the only step that actually makes the file smaller.

A `.wim` is an append-only archive. It holds one shared pool of file resources plus a separate metadata index per image inside it, and DISM never rewrites that pool in place:

- **Servicing appends.** Applying a cumulative update writes the new version of every changed file as a fresh resource at the end of the archive. The old versions are still sitting in the file, they have just stopped being referenced by the image metadata. This is why `install.wim` and `boot.wim` both *grow* during servicing, often well past what the update itself weighs.
- **Deleting does not delete.** `/Cleanup-Image /ResetBase` strips superseded components from WinSxS, and dropping an edition with `-KeepEditions` removes an index. Both only unlink references. The bytes stay exactly where they were.

`Export-WindowsImage` is what rebuilds the file. It reads the metadata for the index you asked for, copies only the resources that index actually points at into a brand new archive, and leaves everything unreferenced behind. That is the entire shrink. Without it, `/ResetBase` reclaims nothing you can measure and the finished ISO ships larger than the media you started from.

Two things come along with the rebuild:

- **Recompression.** The export writes at whatever compression you ask for, so an image that arrived as `Fast` comes out `Max`, or as `recovery` with `-CompressEsd`.
- **Fresh single-instancing.** Resources shared by the remaining editions are stored once again rather than carried as whatever the old layout left behind. This is also why dropping editions saves less than you would expect: most of what you removed was shared with the editions you kept, so only the genuinely edition-specific files go away.

The cost is that an export needs room for a full second copy of the image while it runs. The build checks free space before starting one and skips that particular export with a warning if the drive cannot take it, shipping the serviced but unshrunk image rather than failing the run. `winre.wim` gets the same treatment for a different reason: it has to stay small enough to live in the recovery partition, which servicing can easily push it past.

## Why Two Identical Builds Aren't the Same Size

The finished ISO's SHA-256 changes on **every** build, even from the same source and the same update, because `oscdimg` writes timestamps into the ISO and the output file name embeds the build date and time. Byte-identical output was never a goal. Size, though, should be stable to within a few megabytes, and a bigger gap than that is worth explaining.

Offline servicing writes into the image as it works: `Windows\Logs\CBS`, `Windows\Logs\DISM`, `$WinREAgent` state, temp files. How much it writes depends on how chatty DISM was on that particular run, and all of it is committed and exported with the image. That is the main source of run-to-run size drift, so `-StripImageResidue` clears it just before `Dismount-WindowsImage -Save`:

* Contents of `Windows\Logs\CBS`, `Logs\DISM`, `Logs\DPX`, `Logs\MoSetup`, `Logs\WindowsUpdate`, `Windows\Temp` and `Windows\SoftwareDistribution\Download`, keeping the folders themselves.
* `$WinREAgent`.
* Only the `.log`, `.etl` and `.evtx` files in `Windows\Panther`. The folder is left in place and any XML in it is kept, because a captured image can legitimately keep the answer file that built it there.

Windows recreates all of it on first boot. The same pass also removes `Windows.old`, `$WINDOWS.~BT`, `$WINDOWS.~WS`, `$Recycle.Bin`, `System Volume Information`, `pagefile.sys`, `hiberfil.sys` and `swapfile.sys`, and **warns** when it finds any of them, because none belong in clean Microsoft media. Finding one means the source ISO was built from a captured machine rather than downloaded from Microsoft, which is worth knowing on the first build rather than on the first deployed machine. DISM's default capture exclusion list does not exclude them, so a naive `/Capture-Image` carries them into every deployment.

The switch is off by default because a build that touches nothing inside the image is the easier one to reason about when something goes wrong, and none of this residue affects whether the media installs. Turn it on when consistent ISO sizes matter more than that.

It is still a switch that deletes things out of a Windows image, and the list above is a judgement about what is safe to remove rather than anything Microsoft documents as disposable. Not every file or folder that looks like leftover state is leftover. Some of it exists by design and is read again later by Setup, by first boot or by the recovery environment, and the failure from removing one of those does not show up at build time. It shows up on a machine. **Install once from an ISO built with this switch and confirm Setup, first boot and recovery all behave before deploying from it**, and re-test after a feature update changes what the media contains.

What remains after that is genuine variance in what `/ResetBase` managed to reclaim, which depends on the component store's state at that moment. Running the cleanup more than once does not help, since a completed `/ResetBase` has already removed every superseded component and a second pass rescans the whole store to reclaim nothing. It also runs per edition, so repeating it is expensive.

If two builds still differ by hundreds of megabytes, compare their stamps rather than guessing. A `Result` of `SuccessWithWarnings` means a package failed to apply to at least one edition and that ISO is genuinely under-patched.

## How This Was Built

Most of the code here was written with an AI model. That is worth saying plainly rather than leaving it to be guessed at, because it changes the questions a reader should ask.

What it does not mean is that it was left to run on its own. Every line was reviewed and every path was tested by hand on real media, by someone with twenty years in Windows IT who was writing PowerShell long before any of this was available. No autopilot, no accepting a diff because it looked plausible, and nothing shipped that had not actually been run.

The design is mine. Even on the strongest models available, the concepts and the methods came first, from experience, and the model wrote against them. That distinction turned out to be the whole difference. Handed a goal and left to work out the approach, the models I tried stalled, went in circles or produced something confidently wrong. Handed a decided approach, they were genuinely quick at turning it into working code.

The parts of this script that matter most are the ones that came from knowing the terrain rather than from a model:

- The already-patched check is **deliberately asymmetric** and fails open, because a wrong skip silently ships an unpatched ISO. A model optimising for a clean-looking implementation trusts the WIM header and moves on.
- `Test-RebuildNeeded` runs **before** extraction, since a check that costs an hour of extraction is not a check worth having on a schedule.
- Monthly scheduled triggers are registered through exported XML, because the obvious `Register-ScheduledTask -Trigger` route returns `0x80070057` on client Windows no matter what you set.
- Windows PowerShell 5.1 is the target throughout, which rules out a long list of syntax and a few overloads that look correct and refuse to bind.

None of those came out of a prompt. They came out of having been bitten before, and the reason they are written down here is so the next person does not have to be.

## Offline Servicing and Hot-Patch Eligibility

Windows 11 25H2 Enterprise supports hot-patching through Intune or Azure Arc on a quarterly cadence. January, April, July and October are planned as full cumulative update baselines, and Microsoft adds extra ones when a security issue calls for it, as it did in June and September 2026. The other months receive lightweight in-memory hot patches that do not rewrite image files on disk.

Hotpatch updates cannot be applied offline via DISM at all. A regular cumulative update replaces binaries on disk, which is exactly what DISM's offline package injection does. A hotpatch instead modifies already-loaded code in the running kernel's address space and has no files to swap into a WIM image, so there is nothing for DISM to inject. The intended workflow is to offline-service the ISO with the baseline CU using `-BaselineOnly`, deploy the image, enroll the device in Intune or Azure Arc hotpatch policy, and let Windows Update deliver the in-quarter hotpatches to the live system at runtime.

When this tool integrates the Latest Cumulative Update offline with DISM, the WIM is updated by direct package injection rather than through the online Windows Update Agent and CBS stack that a running system uses. The CBS state the hot-patch subsystem reads to confirm baseline eligibility is built up by that online stack during a normal update, and offline servicing does not replicate it fully.

If the integrated LCU is a non-baseline (in-quarter) update, the resulting image may not carry the CBS metadata the hot-patch system expects. The symptom is that hot patches fail to apply and the machine waits until the next baseline month before hot-patching resumes.

For environments where hot-patch eligibility is a hard requirement, two postures are reliable:

- **Service against a known baseline CU.** Build against the latest baseline on [Microsoft's hotpatch calendar](https://support.microsoft.com/en-us/servicing/os/hotpatch/windows-11/2025/release-notes-for-hotpatch-on-windows-11-enterprise-version-25h2). The resulting image starts at baseline level and is eligible for hot patches in the months that follow.
- **Deploy a lightly-patched image and patch online first.** Build the ISO against any available LCU, deploy the machine, and let Windows Update apply the current LCU through the normal online stack before enrolling the device in Intune hot-patch policy. This guarantees that CBS state is established the way Microsoft's hot-patch stack expects.

The script also provides a `-BaselineOnly` switch for automating the first posture. When set, it reads the latest baseline KB from Microsoft's hotpatch calendar and fetches that package from the Update Catalog, so a build in November still gets October's baseline, whatever patch level the source ISO started from. The calendar has to decide because the catalog cannot: baselines carry ordinary cumulative update titles, and hotpatch packages do not appear in its search results. A later out-of-band update is passed over too, because it is not the baseline.

If the calendar cannot be read, is out of date, or names a KB the catalog does not have for this release, the run warns and falls back to the newest security update from January, April, July or October. That can miss a baseline Microsoft added outside those months. If there is no such update either, the image keeps the source ISO's patch level.

This is a known tradeoff in offline servicing, not a defect in this tool.

[← Back to README](../README.md)
