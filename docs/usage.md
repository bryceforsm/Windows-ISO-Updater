[← Back to README](../README.md)

# How to Run This Script

The easiest and recommended way to run this script is by using the `Run-Windows-ISO-Updater.bat` file. It automatically handles administrator elevation and PowerShell execution policies.

**As long as you use the batch file, no setup or PowerShell experience is needed.** It requests administrator rights through the normal UAC prompt and runs the script with `-ExecutionPolicy Bypass` scoped to that single run, so your system-wide execution policy is never changed. Running the `.ps1` by hand works too, but then elevation and execution policy are on you.

> [!NOTE]
> This script is primarily designed and tested for Windows 11 with en-US locale. If you are running this on a system with a different locale or Windows 10, some features or output may not work as expected. Please report any locale-specific issues you encounter.

> [!NOTE]
> The script patches the media within its own release. A 24H2 ISO comes out as patched 24H2, not 25H2, so start from media for the release you want ([why](design-notes.md#why-the-release-never-changes)).

## Recommended Method: Using the Batch File

1.  **Download Files:** Make sure both `Run-Windows-ISO-Updater.bat` and `Windows-ISO-Updater.ps1` are saved in the **same folder**.
2.  **Provide an ISO:** Drop a Windows ISO into `C:\WISO-Work\Downloads`, pass one with `-IsoPath`, or drag the ISO onto `Run-Windows-ISO-Updater.bat`, which builds from it. The script does not fetch one for you unless you add `-UseFido` or `-UseMct` ([why](design-notes.md#why-the-iso-has-to-come-from-you)).
3.  **Run the Batch File:** Double-click the `Run-Windows-ISO-Updater.bat` file.
4.  **Administrator Prompt:** A User Account Control (UAC) window will appear asking for administrative privileges. Click **Yes**.
5.  **Follow Prompts:** The script opens in a new window, summarizes what it will do, and asks for confirmation before building.

## Running with Parameters (from Command Line)

To use command-line parameters, run the batch file from a Command Prompt or PowerShell terminal.

1.  Open Command Prompt or PowerShell.
2.  Navigate to the directory where you saved the files (e.g., `cd C:\Users\YourUser\Downloads`).
3.  Run the batch file with your desired parameters. For example:
    ```bat
    .\Run-Windows-ISO-Updater.bat -Unattended -InstallAdk -Edition "Windows 11 Pro"
    ```

Relative paths such as `.\Examples\autounattend-update-after-setup.xml` are read from the folder you ran it in, even after the administrator prompt reopens it in a new window. Run from a terminal, the batch file waits for the script and passes on its exit code, so `-CheckOnly` can be scripted against it. Double-clicked or dropped onto from Explorer, its own window closes as soon as the administrator window opens.

The full list is in [Command-Line Parameters](parameters.md).

## Using a JSON Profile

A profile keeps the settings for a build in a file, so you can repeat it without a long command line and keep one file per image. Each name is a [parameter](parameters.md) without its leading dash:

```json
{
  "_comment": "Monthly Windows 11 build",
  "IsoPath": "D:\\ISOs\\Win11_25H2_original.iso",
  "WorkPath": "D:\\WISO\\Win11",
  "KeepEditions": ["Windows 11 Enterprise", "Windows 11 Pro"],
  "AutoClean": true,
  "KeepIsoCount": 3
}
```

```bat
.\Run-Windows-ISO-Updater.bat -ConfigPath "D:\Profiles\win11.json"

:: The command line wins, so this one run leaves the .NET update out
.\Run-Windows-ISO-Updater.bat -ConfigPath "D:\Profiles\win11.json" -SkipDotNet
```

- Switches take `true` or `false`, and a parameter that takes several values can take a JSON list. Backslashes in paths have to be doubled.
- Relative paths are relative to the profile, not to the folder you ran from.
- Names starting with `_` or `$` are ignored, which is how to leave a comment. Any other name that is not a parameter stops the run, so a typo cannot quietly be ignored.
- These stay on the command line, and the run stops if a profile sets one: `-RegisterScheduledTask`, `-UnregisterScheduledTask`, `-Schedule`, `-ScheduleTime`, `-ScheduleDay`, `-TaskName`, `-TaskUsername`, `-TaskPassword`, `-Scheduled`, `-CheckOnly`, `-ListEditions` and `-Force`. A profile describes a build rather than one run of it, and a password does not belong in a file.

A scheduled task keeps only the path to the profile, so later edits to the file apply to its next run, and an edit that changes what goes in the ISO triggers a rebuild like any other changed setting. If the file is moved or deleted, the task's run fails:

```bat
.\Run-Windows-ISO-Updater.bat -ConfigPath "D:\Profiles\win11.json" -RegisterScheduledTask -Schedule PatchTuesday
```

[`Examples/profile-win11-monthly.json`](../Examples/profile-win11-monthly.json) is a starting point. Unless `-AnonymousTattoo` is on, the build record on the ISO lists what the profile set, so the ISO still says how it was built if the file later changes.

## Updating a Windows Server ISO

Server media is serviced exactly like client media, with no switch to announce it: the script reads the
edition out of the image and adapts the catalog search and the edition keep-list to what it finds. The ISO
has to come from you, though, because neither Fido nor the Media Creation Tool serves Server media, so
download it from the [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter), your Volume
Licensing Service Center, or a Visual Studio subscription first.

```bat
:: Slipstream the latest Server cumulative update into your own Server 2025 ISO
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Server2025.iso"

:: Or drop the ISO into the download folder and let it be picked up automatically
.\Run-Windows-ISO-Updater.bat
```

## Updating a Windows 11 LTSC ISO

Windows 11 LTSC and IoT Enterprise LTSC media work the same way as Windows Server: pass `-IsoPath` or drop
the ISO into the download folder, and the script handles the rest. The key difference is that neither
Fido nor the Media Creation Tool serves LTSC media at all, so you must supply it from the Volume
Licensing Service Center, the Evaluation Center, or a Visual Studio subscription.

```bat
:: Slipstream the latest cumulative update into your own Windows 11 LTSC ISO
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11LTSC.iso"

:: Or drop the ISO into the download folder and let it be picked up automatically
.\Run-Windows-ISO-Updater.bat
```

One thing to note: `-BaselineOnly` does not apply to LTSC media. LTSC has no hotpatch enrollment, so
the cumulative update is applied every month regardless of the month type.

## Windows Server Specific Notes

A few differences worth knowing:

- The release is read from the image, so there is no `-Release` to set. Server 2022 and newer are listed
  in the Microsoft Update Catalog as *"Microsoft server operating system version 21H2/23H2/25H2"* rather
  than by year, and the script builds the right query for you.
- Server media keeps a **single** edition by default, not the up to three tiers that client media keeps, and
  the pick is **Standard (Desktop Experience)**, not Datacenter. An installed Standard server can be upgraded
  to Datacenter in place with `DISM /Set-Edition`, but Datacenter can never be downgraded, so Standard is the
  edition that leaves both options open. Use `-KeepEditions` to pick Datacenter or a Server Core image
  instead, or `-KeepAllEditions` to keep every edition the media carries.
- Microsoft only publishes a **Setup Dynamic Update** for Server 2025 and newer, so on older Server media
  the script reports that none was found and refreshes the media Setup files from `boot.wim` alone.
- `-Server` is **deprecated and no longer needed**. The image is the source of truth, so a Server ISO passed with `-IsoPath` or dropped into the download folder is recognised on its own, and a yellow line names what was found whenever it differs from what the run expected. The switch is still accepted so existing scheduled tasks and wrapper scripts keep running. Before any ISO is in hand the only thing that can tell Server from client is the last build stamp in the same working folder, which is what stops a scheduled Server run whose ISO went missing from downloading client media instead.
- **Give Server its own working folder if you also build client ISOs.** See
  [Building Several Windows Versions Side by Side](#building-several-windows-versions-side-by-side).

## Building Several Windows Versions Side by Side

Everything the script writes lives under one working folder, `C:\WISO-Work` unless you pass `-WorkPath`.
That is deliberate, because a single parameter moves the whole build to another drive, but it does mean a
Windows 11 run and a Windows 10 or Server run share the same downloads, the same build stamps and the same
scratch space. Nothing in the folder layout is scoped by version.

**Give each version its own `-WorkPath`.** That one parameter separates all of it, and there is nothing
else to configure.

```bat
:: Windows 11, the usual case
.\Run-Windows-ISO-Updater.bat -WindowsVersion 11 -WorkPath "D:\WISO\Win11"

:: Windows 10, completely independent of the run above
.\Run-Windows-ISO-Updater.bat -WindowsVersion 10 -Release 22H2 -WorkPath "D:\WISO\Win10"

:: Windows Server, which needs an ISO you supply
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Server2025.iso" -WorkPath "D:\WISO\Server2025"
```

The same applies to two builds of the *same* Windows version that differ in a build-affecting way, such as
one ISO with an answer file and one without, or one trimmed to Pro only and one with every edition. They
are different outputs, so they need different working folders.

### What actually collides

If you would rather share most of the folders and split only what matters, this is what each one does when
two versions share it:

| Folder | Effect of sharing it |
|---|---|
| `Downloads` | **The worst one.** With no `-IsoPath`, the script reuses the most recently modified `.iso` over 3 GB it finds here (or the largest with `-UseLargestIso`), and it does **not** check which Windows version that ISO is. A Windows 10 ISO left in the folder is picked up by a Windows 11 run. Split it with `-DownloadPath`, or always pass `-IsoPath`. |
| `Stamps` | There is one `last-build.json` per stamp folder. Alternating versions overwrite each other's record, so every run decides it must rebuild and `-CheckOnly` always reports a rebuild is needed. Split it with `-StampPath`. |
| `Downloads` (update packages) | `-AutoClean` deletes the `.msu`/`.cab` files recorded in stamp history that the newest build no longer uses, so it deletes the other version's cumulative update. Splitting `-DownloadPath` and `-StampPath` fixes this too. |
| `Output` | Safe. Finished ISO names carry the version (`Win11_`, `Win10_`, `WinSrv2025_`), so they coexist. Note that `-AutoClean` keeps the newest `-KeepIsoCount` (default 3) across **all** versions combined, not per version. |
| `Logs` | Safe, but log rotation keeps the 30 most recent overall, so history is shorter the more versions you run. |
| `ISO`, `Mount`, `Tools` | Safe between runs, since extraction wipes the `ISO` folder at the start of every build anyway. Not safe **during** a run, see below. |

So the minimum split is `-DownloadPath` and `-StampPath`. A separate `-WorkPath` covers both and is easier
to reason about later.

### Do not run two builds at the same time

The script assumes it is the only copy running. Two builds at once fight over the DISM mount folder and the
extraction folder even if everything else is separate, and a DISM mount is tracked per WIM file, so the
second run fails or corrupts the first. Run them one after another. Scheduled tasks should be given start
times far enough apart that a build cannot still be going, or an hour or two apart.

### A shared ISO library

If you keep source ISOs in one place, point `-IsoPath` at the specific file rather than sharing a download
folder. `-IsoPath` also accepts a folder, but it picks the most recently modified ISO inside it by default
(or the largest with `-UseLargestIso`), which is the same trap as a shared `Downloads` folder.

```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "\\nas\isos\Win11_25H2.iso" -WorkPath "D:\WISO\Win11"
```

A source ISO on a network share or a cloud-synced folder is copied into the download folder first, so the
library itself can live wherever is convenient. The working folder still has to be a local disk. Sending the
finished ISO back to the share works the same way round: `-OutputIsoPath "\\nas\isos\patched"` is built in
the working folder and copied over once it is done, so a share that stalls cannot cost the whole build.

### On a schedule

Each version needs its own task name as well as its own working folder, otherwise registering the second
one replaces the first.

```bat
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean ^
  -WindowsVersion 11 -WorkPath "D:\WISO\Win11" -TaskName "Windows ISO Updater - Win11"

.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -ScheduleTime 20:30 -AutoClean ^
  -IsoPath "C:\ISOs\Server2025.iso" -WorkPath "D:\WISO\Server2025" -TaskName "Windows ISO Updater - Server2025"
```

Both tasks run as SYSTEM, so every path has to be a local path SYSTEM can reach. See
[Scheduled Runs](scheduled-runs.md) for the full details.

## Running It on a Schedule

```bat
:: Rebuild monthly, on the 15th at 03:00, and clean up what earlier builds left behind
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule Monthly -ScheduleDay 15 -ScheduleTime 03:00 -AutoClean

:: Or rebuild on Patch Tuesday itself - the second Tuesday of every month, 10:30 Pacific in local time
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean
```

The task runs the script with `-Scheduled`, which compares the run against the stamp left by the last
build and exits within a minute or two when nothing has changed, so scheduling it hourly costs nothing.
See [Scheduled Runs](scheduled-runs.md).

## Removing Editions (Slimming the ISO)

A Windows ISO's `install.wim` usually contains many editions (Home, Home N, Pro, Education, etc.). **By default the script keeps Enterprise, Pro and Home** and removes the rest, which speeds up servicing and produces a smaller ISO. Only the ones the media actually carries are kept, so typical consumer media gives you Pro and Home while business and VL media give you Enterprise and Pro. If the media has none of the three (Education-only media, for example) the highest edition present is kept. On Server media the rule is different: a single edition, the *most upgradeable* one, Standard over Datacenter, because Standard can be upgraded in place but Datacenter cannot be downgraded. Use `-KeepAllEditions` to keep every edition, or `-KeepEditions` to choose exactly which ones to keep.

Every kept edition is serviced by default, so a two-edition build takes roughly twice as long as a one-edition build. Pass `-KeepEditions "Windows 11 Pro"` if you only need one and want the shorter run. If you also narrow `-Edition` to a single one, only that edition is serviced, so any other edition you kept ships unpatched and the script warns about it.

```bat
:: See what editions are inside the ISO first (downloads/uses the ISO, then just lists and exits)
.\Run-Windows-ISO-Updater.bat -ListEditions

:: Keep EVERY edition instead of just the default set
.\Run-Windows-ISO-Updater.bat -KeepAllEditions

:: Build an updated ISO containing ONLY Windows 11 Pro (by name)
.\Run-Windows-ISO-Updater.bat -KeepEditions "Windows 11 Pro"

:: Same idea, selecting by index number instead of name
.\Run-Windows-ISO-Updater.bat -KeepEditions 6,1
```

`-KeepEditions` accepts edition names (partial matches allowed) or index numbers, and overrides the default. Only the kept editions are serviced and re-exported, so the removed editions are gone from the final `install.wim`. If none of your values match any edition in the ISO, all editions are kept instead (the script prints a warning and lists the available editions). A partial mismatch (some values match, some don't) exits with error 1. It works with `-SkipUpdates` too, if you only want to trim editions without integrating updates.

## Speeding Up a Build

DISM has no setting that makes it faster, but most of a build's time goes on things you can choose. In order of how much they usually save:

1. **Keep fewer editions.** Each edition is serviced separately, so the time grows with how many you keep. `-KeepEditions "Windows 11 Pro"` services one instead of three ([Removing Editions](#removing-editions-slimming-the-iso)).
2. **Put the working folder on a fast local SSD.** DISM is mostly limited by the disk, so `-WorkPath` on an NVMe drive is much quicker than on a SATA SSD or a hard disk. Never use a network share or a cloud-synced folder, which the script warns about.
3. **Exclude DISM's working folders from Defender** with `-ExcludeWorkPathFromDefender`. Defender otherwise scans every file DISM writes into a mounted image, and an image holds hundreds of thousands of them, which slows applying updates, the cleanup and the commit.
4. **Use `-FastCompression`.** Exports are much quicker, for an `install.wim` typically 5-15% bigger.
5. **Skip what you do not need.** `-SkipDotNet` leaves out the .NET update, and `-SkipWinRE` leaves the recovery image as the media shipped it. Each saves a whole servicing pass.

```bat
:: A quick build of one edition, for testing
.\Run-Windows-ISO-Updater.bat -KeepEditions "Windows 11 Pro" -FastCompression -ExcludeWorkPathFromDefender
```

### How the Defender exclusion works

`-ExcludeWorkPathFromDefender` is the one speed option that changes the machine rather than the build, so it is off unless you ask for it.

- **Only the folders DISM works in are excluded:** `ISO`, `Mount`, `WinREMount`, `BuildCheck` and `WinRECache` under the working folder (`C:\WISO-Work` by default, or your `-WorkPath`). [Microsoft Defender Exclusions](reference.md#microsoft-defender-exclusions) says what happens in each. `Downloads`, `Output` and `OutputStaging` stay scanned, so files that came from the internet and the finished ISO are still checked. Each of those is read only once, so scanning them costs little.
- The exclusions are added when the build starts its heavy work, after the checks that can end a run early. A run that finds nothing has changed never touches Defender.
- They are **removed when the run ends, however it ends.** A normal finish removes them before the window waits for Enter. For an error, Ctrl+C or a closed window, a small hidden process started with the exclusions waits for the run to end and removes them then.
- If a restart or power cut ends the run, the next run removes the leftover exclusions before it does anything else, whether or not it uses the switch. It knows which ones are its own to remove from `DefenderExclusion.json`, a marker in the working folder.
- Any of those folders **already on Defender's list** before the run, for example because you added them yourself, are left exactly as they were.
- It does nothing when another antivirus is the active one, because Defender's exclusions then change nothing. Exclude the folders in that product instead. Where Defender's exclusions are managed by Group Policy or Intune, a local exclusion may not apply, and the script says so and carries on with scanning as usual.

To check that nothing was left behind, list Defender's exclusions in an elevated PowerShell:

```powershell
(Get-MpPreference).ExclusionPath
```

## Adding Drivers

`-DriverPath` points at a folder of driver packages and injects them into the images. The folder is searched **recursively** for `.inf` files, and each one is added to every serviced edition of `install.wim` and to `boot.wim` index 2.

```bat
:: Add a folder of extracted drivers to the images
.\Run-Windows-ISO-Updater.bat -DriverPath "D:\Drivers\OptiPlex-7010"

:: Trim the drivers into the ISO without integrating any updates
.\Run-Windows-ISO-Updater.bat -SkipUpdates -DriverPath "D:\Drivers\OptiPlex-7010"
```

Things worth knowing:

- **The drivers must be extracted.** A vendor `.exe` or `.msi` installer cannot be injected into an image, only the `.inf` and the `.sys`/`.cat` files beside it. Most vendors publish a driver CAB or a `/e` extraction switch for exactly this.
- **`boot.wim` index 2 matters as much as `install.wim`.** Index 2 is the image Windows Setup boots into, so this is what stops *"We couldn't find any drives"* on a machine with a storage controller the media has no driver for. Index 1 is skipped deliberately, because it is loaded into a RAM disk and never installs anything.
- **Keep the set small.** Everything added to `boot.wim` has to fit in memory when Setup starts, so a whole vendor driver pack is a bad idea. Storage and network drivers are the ones Setup actually needs. The script warns above 500 MB.
- **The architecture has to match.** An x64 driver injected into an ARM64 image is simply rejected, and so is a driver signed by a certificate the image does not trust. Each rejection is reported by name and the rest still go in, so one bad package does not lose the build.
- **`-AllowUnsignedDrivers` relaxes the signature check** in DISM. It does not make Windows load the driver: 64-bit Windows still refuses an unsigned kernel driver at boot unless test signing is on, so this is only useful when the certificate is being trusted some other way.
- **It is build-affecting.** The stamp records a hash of the whole folder, so swapping in a newer driver forces a rebuild on the next scheduled run even though the path did not change.
- **Drivers go in after the updates**, so an inbox driver the cumulative update brings along cannot supersede the one you supplied.

The alternative that needs no rebuild is a `$WinPEDriver$` folder at the root of the USB stick, or of any other drive the machine can see while Setup runs. Windows Setup looks for one on its own, with no answer file needed, and loads its drivers both into Setup and into the Windows it installs. That is the better choice for a driver that only one machine needs.

## Adding Your Own Files to the ISO

`-ExtraFilesPath` copies a folder onto the **root of the finished ISO**, keeping the folder structure. Use it for a scripts folder, an `$OEM$` tree, a `$WinPEDriver$` folder, an image you want to carry along, or anything else you want on the media.

```bat
:: Everything inside Media-Extras ends up at the root of the ISO
.\Run-Windows-ISO-Updater.bat -ExtraFilesPath "D:\Media-Extras"
```

```text
D:\Media-Extras\                 ->  <ISO root>\
  Tools\Diag.ps1                     Tools\Diag.ps1
  $OEM$\$$\Setup\Scripts\...         $OEM$\$$\Setup\Scripts\...
  $WinPEDriver$\nic\e1i68x64.inf     $WinPEDriver$\nic\e1i68x64.inf
```

### Files that replace something already on the media

The copy runs **last**, after the images have been serviced and after `-UnattendPath` has placed `autounattend.xml`, so a file in your folder deliberately wins over the media's own copy. Because that is easy to do by accident, **every file is logged as it goes on** and the ones that landed on top of something are marked:

```text
[08/16/2026|14:22:07]     \autounattend.xml (1.4 KB) REPLACED
[08/16/2026|14:22:07]     \sources\install.wim (4692310.5 KB) REPLACED
[08/16/2026|14:22:07]     \Tools\Diag.ps1 (12.4 KB)
[08/16/2026|14:22:07]     \Tools\Nested\collect.cmd (0.6 KB)
[08/16/2026|14:22:07]   Copied 4 file(s) to the root of the media.
[08/16/2026|14:22:08]   2 of them REPLACED a file the media already had, marked above and listed in the build record.
```

The same list, with the SHA-256 and size of each file, goes into the [build record on the ISO](reference.md#the-build-record-on-the-iso), so months later you can still tell what is on the media apart from what the folder happens to hold today. Four cases get a louder warning, because they undo work the run just did:

- **`sources\install.wim` or `sources\boot.wim`.** The ISO then ships *your* image, not the one this run spent an hour servicing, so none of the updates or drivers applied above are in the finished media. This is printed in red.
- **Boot sectors, boot managers, or `sources\setup.exe` / `setuphost.exe`.** Windows Setup fails during installation if these do not match the version inside `boot.wim`, and a mismatched boot sector can leave the ISO unbootable.
- **`autounattend.xml`.** Your folder's copy is on the ISO instead of the one `-UnattendPath` supplied.
- **Anything under `WISO-Build`.** The build record is written after this step, so it wins. Pass `-SkipTattoo` if you want to keep your own copy there.

Read-only attributes inherited from the source ISO do not block the copy, they are cleared first. The folder is build-affecting and hashed by content, so editing one of the files forces a rebuild on the next scheduled run.

## Writing the ISO to a USB Stick

The ISO this script produces is stock media with Microsoft's boot files and signatures untouched, so it boots on a machine with Secure Boot enabled without any extra steps.

Keep it that way when you write it to a USB stick. Flashing the ISO as it is preserves the signed boot loader, while anything that swaps in its own loader or patches the installer binaries breaks the signature chain, and a machine enforcing Secure Boot will refuse it. If you use Rufus to write the ISO, decline its Windows customization options (the Windows User Experience dialog and any option to swap the boot loader or patch the installer), as those may require disabling Secure Boot. If you want an answer file on the media, use `-UnattendPath` so it goes on before the ISO is built rather than being added afterwards.

## Building a Recovery ISO

Because of a bug in Windows Setup, some Windows 11 media will not let you use the **Repair my PC** option. It appears on the Setup screen but does nothing when clicked, and stock Microsoft media is affected too. That leaves no simple way to reach Startup Repair, System Restore or a recovery command prompt on a PC that will not boot.

`-RecoveryIsoPath` works around it by building a second, much smaller ISO alongside the installation ISO. It boots straight into the Windows Recovery Environment with no Setup screen in front of it, and it carries the recovery image with the latest Safe OS update already applied. It holds only the boot files and the recovery image, never your answer file or extra files, so it is fit to hand out across an organization (Microsoft's license terms still cover what is on it).

```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11.iso" -RecoveryIsoPath "D:\ISOs"
```

Give `-RecoveryIsoPath` a folder to get a generated name such as `Win11_Recovery_x64_26100.6899_20261010-1200.iso`, or a full file path to name it yourself. With `-AutoClean`, the newest `-KeepIsoCount` generated recovery ISOs in that folder are kept and older ones are deleted, counted separately from the installation ISOs.

To build only the recovery ISO, add `-RecoveryIsoOnly`. The source ISO is read in place, `install.wim` is never serviced, and the only download is the Safe OS Dynamic Update, so it finishes in minutes. Without `-RecoveryIsoPath` it lands in the `Output\` folder under the working folder. It keeps no build stamps, so a scheduled run builds a fresh recovery ISO every time it fires ([choosing a schedule](scheduled-runs.md#recovery-isos-on-a-schedule)).

```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11.iso" -RecoveryIsoOnly
```

This is not a layout Microsoft documents. Every file on the recovery ISO is Microsoft's own and unmodified, the boot files keep their signatures so it boots with Secure Boot on, and the recovery image is only updated with Microsoft's Safe OS update. What is not documented is placing that recovery image where install media keeps its Setup image, so Microsoft support will not treat it as a known configuration. If your organization requires officially supported tooling, use one of these instead:

- **A recovery drive.** Run `recoverydrive.exe` on a working PC. It is the documented way to make bootable recovery media, but it writes only to a USB stick, not an ISO, and needs a working machine to run on.
- **The recovery partition on the PC itself.** Hold Shift while clicking Restart, or run `reagentc /boottore` and reboot.
- **WinPE from the Windows ADK.** It gives you a command prompt for repair work, but not the recovery menus.


[← Back to README](../README.md)
