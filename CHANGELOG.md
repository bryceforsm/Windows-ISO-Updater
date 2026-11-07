# Change Log

What changed in each release. Versions are dates, `yyyy.MM.dd.<revision>`. Releases before this file was added are described on the [Releases page](https://github.com/bryceforsm/Windows-ISO-Updater/releases).

## [Unreleased]

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
