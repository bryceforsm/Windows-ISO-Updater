# Change Log

What changed in each release. Versions are dates, `yyyy.MM.dd.<revision>`. Releases before this file was added are described on the [Releases page](https://github.com/bryceforsm/Windows-ISO-Updater/releases).

## [Unreleased]

### Added

- The console is easier to follow during a long build. See [Watching a Build's Progress](docs/usage.md#watching-a-builds-progress).
  - The window title names the current step and its percentage, and in Windows Terminal the tab and taskbar button fill up as a progress bar.
  - Each step starts with a cyan heading ruled out to the edge of the window.
  - Success, warning and error lines start with a symbol (`✓`, `!`, `✗`), and the progress bar is drawn with solid blocks.
  - The finished run's ISO path, size, build, editions and run time are shown together in a box. The `.log` gets the same rows as plain lines.
  - When a run you started yourself ends after a minute or more, the console bell sounds and the taskbar button flashes. Runs with `-Unattended` or `-Scheduled` stay quiet.
  - The symbols depend on what the console can show. Windows Terminal, the VS Code terminal and UTF-8 consoles get the full set. A classic console gets only characters from its code page, and redirected output, scheduled runs and other code pages get plain ASCII, so nothing shows up as `?`. The `.log` never gets any of them.
- Each run now checks GitHub for a newer release while it writes the log header, and the console says `Version check  : v... is the latest release`, or which newer version is available and where to get it. The check gives up after 3 seconds and overlaps the machine report, so it barely slows a run. When GitHub cannot be reached, only the log mentions it. `-SkipVersionCheck` turns the check off. See [Command-Line Parameters](docs/parameters.md).
- `-IgnoreOfflineUpdateCap` turns off the offline update cap, so Windows 10, Windows 10 LTSB 2016 and Windows Server media past its end of support gets the catalog's newest cumulative update instead of the last one before Extended Security Updates. **This will likely break the build.** ESU updates refuse to install on an offline image, and the script has no workaround for that, so DISM fails on the update and that edition ships without it. The run plan and the log warn in yellow, and the `\WISO-Build` record and the build stamp mark the cap `Ignored`. It is a build parameter, so turning it on or off forces a rebuild. It is recorded only while it is on, so build stamps from earlier versions still match. See [Windows 10 Media Stops at the October 2025 Update](docs/usage.md#windows-10-media-stops-at-the-october-2025-update).

### Changed

- Console lines now start with just the time, `[18:00:41]`, instead of `[11/18/2026|18:00:41]`, so messages have 11 more columns before they wrap. The run header still gives the date, a run that goes past midnight prints one line saying the date has changed, and the `.log` keeps the full date and time on every line.
- Secondary console lines, such as `Step finished in`, are no longer shown in dark gray, which was hard to read. They now use the console's normal text color. Warnings, errors and successes keep their colors.
- `Run-Windows-ISO-Updater.bat` now runs the script in PowerShell 7 when it is installed, and in Windows PowerShell 5.1 when it is not, ahead of Windows PowerShell's deprecation. The `pwsh.exe` it finds has to start and report version 7 or newer, so a broken install or a leftover PowerShell 6 falls back to Windows PowerShell too. The first line of the run says which one it chose. To stay on Windows PowerShell, run `powershell.exe -File .\Windows-ISO-Updater.ps1`. See [How to Run This Script](docs/usage.md).
- Windows Server media is now updated only as far as the last cumulative update before its Extended Security Updates begin: October 2026 for Windows 10 LTSB 2016 and January 2027 for Server 2016 (the same build, told apart by whether the media is Server), January 2029 for Server 2019 (and Windows 10 LTSC 2019), October 2031 for Server 2022 and November 2034 for Server 2025. ESU updates are expected to refuse an offline image the way Windows 10's have since November 2025, and without a cap each build would fail on the update and ship that edition with no update at all. LTSB 2016's cap applies from now, since its first ESU update was published in November 2026. The others change nothing until a release's first ESU update is published, starting with Server 2016 in February 2027, and a cap will be removed if that update turns out to install offline. The later updates install once Windows is running, on a server enrolled in ESU. See [Windows Server Specific Notes](docs/usage.md#windows-server-specific-notes).
- The log line about an offline update cap now appears only once the cap can hold an update back, when its cutoff has passed. Before, Windows 10 media printed it on every run, and Server media would have said its updates carried an ESU step years before support ended. The line names the release, and for a cap that has not been confirmed yet it says so and suggests `-UpdatePath` to try a newer update. It is also logged when a recovery ISO is built or the build stamp is checked, once per run.
- The `\WISO-Build` record and the build stamp now include `Updates.OfflineCap` when a cap chose the cumulative update: the release, the last month allowed, and whether the cap is confirmed. A Server 2016 ISO in 2028 then explains why it carries the January 2027 update. See [The Build Record on the ISO](docs/reference.md#the-build-record-on-the-iso).

## [2026.11.07.5](https://github.com/bryceforsm/Windows-ISO-Updater/releases/tag/2026.11.07.5) - 2026-11-07

### Added

- Every run's log now starts with a short report on the machine: the Windows version and patch level, PowerShell and DISM versions, who the run is and whether BITS can work for it, the active antivirus, whether a restart is pending and when the machine last restarted, the working drive's file system, free space and disk type, any proxy, and the hardware. A log attached to an issue then answers the usual first questions. A restart pending for the servicing stack or Windows Update is shown in yellow, because it can make DISM fail. See [Logging](docs/reference.md#logging).
- `Examples/autounattend-update-after-setup.xml` finishes the updates an ISO cannot carry, once Windows is installed: Defender's security intelligence, whatever Windows Update still offers (drivers, the Malicious Software Removal Tool, anything published after the ISO was built), and the Microsoft Store's apps. It changes nothing else about Setup and never restarts the computer. See [Finishing the Updates After Setup](docs/unattended-installs.md#finishing-the-updates-after-setup).

### Changed

- `-UseFido` now runs Fido v1.72, which adds UEFI Shell 26H2 downloads and changes nothing about how Windows ISOs are fetched.
- While DISM applies an update or cleans up an image, the time beside the progress bar now counts up every second, even when DISM prints nothing for minutes. Before, the line only changed when DISM's percentage did, so a long quiet stretch looked like a hang. After a minute at the same percentage, the line adds `still working (no change for ...)`, and committing and exporting an image do the same. A note before the first update explains that DISM's percentage is only a rough guide and can sit at one figure for a long time before jumping. See [Watching a Build's Progress](docs/usage.md#watching-a-builds-progress).

### Removed

- The four experimental example answer files (`autounattend-lab-admin.xml`, `autounattend-gold-image.xml`, `autounattend-ultimate.xml` and `autounattend-driver-install.xml`) and `tools/Sync-EmbeddedDriverScripts.ps1`, which only kept copies of the driver scripts inside one of them. The driver scripts in `tools/` remain, and work on their own.

### Fixed

- An image that DISM reports can no longer be serviced is now discarded instead of saved, so that edition ships exactly as the source media had it. Before, it was saved anyway and could be left half-updated, with a build number from an update that never finished installing. The summary at the end lists the image and every update it lost.
- The servicing stack update bundled inside the cumulative update is now applied to each image on its own, before any update. Before, it was left for DISM to install as part of the cumulative update, which fails with `0x800F0823` on media whose servicing stack is too old, and the failed attempt can leave the image unserviceable. If an update still fails with `0x800F0823`, the servicing stack is applied again before the second attempt, where before the update was just tried again.
- A standalone servicing stack update in the `-UpdatePath` folder is now recognised and applied on its own, first. Before, it was only staged beside the highest-numbered package as if it were a checkpoint, so it never went in.
- The .NET cumulative update for Windows 10 and Server 2022 now applies both of its packages, for .NET 4.8 and 4.8.1. Before, the 4.8 package was treated as a checkpoint of the 4.8.1 one and never applied, so an image with .NET 4.8 did not get the update.
- The tip about repacked or UUP media is now shown only for the error it describes, `0x80070228`. Before, any failure whose message mentioned `Unattend.xml` showed it, and most do.
- Failed DISM exit codes are printed as hex, such as `0x800F0823`, instead of as a large negative number.
- Windows 10 media at build 19041, 19042 or 19043 (2004, 20H2 and 21H1, and LTSC 2021 media, which also reports 19041) is now recognised straight away and searched for as 21H2. Those releases share 21H2's cumulative update, and Microsoft still publishes it under that name. Before, the run spent a few minutes mounting the image to read its release name, and said the build was newer than any release the script knew.
- A step that took over an hour could have its hours rounded up in the timing, such as 1h 36m shown as 2h 36m.
- Windows 10 media from version 2004 to 22H2, including LTSC 2021, is now updated with the October 2025 cumulative update (KB5066791) instead of failing. Every cumulative update for these releases since November 2025 has an Extended Security Updates step that refuses an offline image, so DISM stopped with `0x80073713`, the image was discarded and that edition shipped with no update at all. The later updates install once Windows is running. When an update still fails this way, such as one supplied with `-UpdatePath`, the tip names the ESU step instead of blaming the media. See [Windows 10 Media Stops at the October 2025 Update](docs/usage.md#windows-10-media-stops-at-the-october-2025-update).
- Windows 10 and Server 2022 media now get the Setup and Safe OS Dynamic Updates. The catalog titles both plain "Dynamic Update" for these releases, so Windows 10 media got neither, and Server media took whichever was larger, which is not always the Safe OS one. Each is now identified by its catalog description. See [How the Dynamic Updates Are Told Apart](docs/design-notes.md#how-the-dynamic-updates-are-told-apart).
- A Windows 10 search could pick the Windows 11 or Server Dynamic Update of the same version, because the catalog returns them for the same query, and could pick a Server cumulative update released later than the Windows 10 one. Dynamic Updates must now name the media's own product and architecture, and a client search passes over Server cumulative updates.

## [2026.11.06.8](https://github.com/bryceforsm/Windows-ISO-Updater/releases/tag/2026.11.06.8) - 2026-11-06

### Added

- `-ExcludeWorkPathFromDefender` excludes the folders where DISM does its work from Microsoft Defender real-time scanning while the build runs, which speeds up applying updates, the cleanup and committing the images. It is off by default. The exclusions are removed when the run ends, however it ends, and any that were already there are left alone. Downloads and the finished ISO are still scanned. See [Speeding Up a Build](docs/usage.md#speeding-up-a-build).

### Changed

- The long steps now show a progress bar with a percentage, instead of sitting silent for several minutes: applying updates, cleaning up the component store, exporting images, downloading the ISO and update packages, copying an ISO to or from a network share, and hashing the ISO. Downloads and copies also show how much has transferred and how fast. The bar updates in place, is cleared when the step finishes, and is not written to the transcript or the log.
- Committing and unmounting an image shows progress the whole way through. DISM says nothing for the first few minutes of a commit, so the line shows `Preparing the commit`, then how much has been written to the image, such as `Writing the image: 1.24 GB so far (2m 10s)`. It switches to a bar with a percentage once DISM starts reporting one. A commit has two stages, saving the image and then unmounting it, and each has its own bar, so the line is labeled with the stage.
- Images are now exported and committed with `dism.exe` instead of the DISM PowerShell cmdlets, which is what makes their progress visible. A failure now reports DISM's error code and message.
- A scheduled task registered with `-TaskUsername` now downloads directly instead of trying BITS first, because BITS only transfers files for a signed-in user. A task running as SYSTEM still uses BITS.
- A BITS download that receives nothing for five minutes, or does not start within two, now gives up and falls back to a direct download. Before, BITS could keep retrying a dead connection indefinitely.
- When the run has a console, the transcript no longer gets a line at every 20% while the ISO is hashed, because the bar replaces them. A run without a console, such as a scheduled one, still logs them.
- Long console lines now wrap between words instead of being cut mid-word at the edge of the window. The rest of a wrapped line is indented to start under the message, not under the timestamp. The transcript has the same line breaks, and the CMTrace log still has each message on one line.

## [2026.11.02.5](https://github.com/bryceforsm/Windows-ISO-Updater/releases/tag/2026.11.02.5) - 2026-11-02

### Changed

- When an update fails to apply, the run now says what the DISM error code usually means, prints DISM's whole message instead of only the lines containing "error", and shows the errors from DISM's log. The end of the run lists every package that failed and the image it failed on, including `boot.wim` and the recovery image. See [Logging](docs/reference.md#logging).
- With `-KeepAllEditions`, the run now lists the editions it is keeping, with their index numbers.
- DISM's log for each failed package is now saved in a `_DISM` folder beside the run's logs, so the `Logs` folder holds everything a bug report needs.
- The checksum file attached to each release is now `Windows-ISO-Updater.SHA256SUMS.txt`. Windows opens it without asking which app to use, and the release page lists it after the two files it checks. `2026.10.31.5` keeps its `SHA256SUMS` file.

### Fixed

- The `Finished ISO` line printed at startup no longer claims the ISO will be named `Win11_EntPro_...` when the source is Windows Server or a release that has not been read yet. It now shows placeholders for the parts that come from the image, such as `<release>_<edition>_<arch>_...`. The finished ISO was always named correctly. ([#17](https://github.com/bryceforsm/Windows-ISO-Updater/issues/17))
- A run started from a PowerShell 7 terminal no longer stops after downloading an update with `The term 'Get-FileHash' is not recognized`. Windows PowerShell was picking up PowerShell 7's module folders and could not load its own built-in commands.
- Under PowerShell 7, a repeat run no longer hashes the whole source ISO again when it has not changed. The recorded file time never matched there, so the saved hash was never reused.
- Build stamps written under PowerShell 7 and read under Windows PowerShell, or the other way round, now match when a path contains non-ASCII characters.
- The cleanup task that removes a stuck mount folder after a restart now works when the working folder's path contains non-ASCII characters and the run used PowerShell 7.
- Started from PowerShell 7 without administrator rights, the script now restarts elevated in PowerShell 7 instead of switching to Windows PowerShell.

## [2026.10.31.5](https://github.com/bryceforsm/Windows-ISO-Updater/releases/tag/2026.10.31.5) - 2026-10-31

### Added

- `-ConfigPath` loads build settings from a JSON profile, so a build can be repeated without a long command line. See [Using a JSON Profile](docs/usage.md#using-a-json-profile).
- Each release now includes a `SHA256SUMS` file for checking the download.

### Changed

- `-BaselineOnly` now uses the latest baseline on Microsoft's hotpatch calendar instead of the newest cumulative update. This covers extra baselines outside January, April, July and October. If the calendar cannot be read, the run warns and uses the newest security update from those four months. The next run may rebuild once because the expected update changes.
- `-UseFido` now runs one pinned version of Fido, checked by SHA-256. Overriding `-FidoUrl` now also needs `-FidoSha256`, either the new hash or an empty string.
- Running the `.ps1` directly now keeps the original window open until the elevated run finishes, and returns its exit code.

### Fixed

- The task password no longer appears on a command line when the script relaunches itself elevated, and it can no longer reach the build record on the ISO.
- A download that fails partway can no longer be reused by a later run. Update packages are also checked for damage before they are reused.
- Relaunching elevated now keeps relative paths, several `-KeepEditions` values and paths ending in a backslash intact.
