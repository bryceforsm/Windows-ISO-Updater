# Windows ISO Updater

Automate the process of updating Windows installation media. This PowerShell script takes an official Microsoft ISO, slipstreams the latest cumulative updates directly into the Windows image using DISM, and generates a fresh, fully patched bootable ISO. 

Installing Windows from this updated media saves time by eliminating large post-installation update downloads.

## Key Features

* **Safe Execution**: All servicing happens inside a working folder (`C:\WISO-Work` by default), never on the running Windows. Outside that folder it only changes the host when asked to, with `-InstallAdk` or `-RegisterScheduledTask`, or if a mount cannot be released, when it registers a boot task that clears the mount and deletes itself.
* **No Manual ADK Setup Needed**: Automatically fetches a verified copy of `oscdimg.exe` from Microsoft servers to compile the media.
* **Official Sources by Default**: Downloads packages directly from Microsoft endpoints over HTTPS. The one exception is the optional `-UseFido` ISO download, which fetches a community helper from GitHub, pinned by hash.
* **Windows Server Support**: Compatible with Windows Server media, detected automatically from the image.
* **Secure Boot Ready**: Microsoft's signed boot files are kept as they are, so the ISO boots with Secure Boot on ([writing it to USB](docs/usage.md#writing-the-iso-to-a-usb-stick)).

---

## Quick Start

1. Place [`Run-Windows-ISO-Updater.bat`](https://github.com/bryceforsm/Windows-ISO-Updater/releases) and [`Windows-ISO-Updater.ps1`](https://github.com/bryceforsm/Windows-ISO-Updater/releases) in the same directory.
2. Put an official Windows ISO in `C:\WISO-Work\Downloads` or specify its location with `-IsoPath`.
3. Right-click `Run-Windows-ISO-Updater.bat` and select **Run as administrator**.
4. Confirm the build settings displayed in the console prompt.

To verify a download, compare `Get-FileHash .\Windows-ISO-Updater.ps1` with the `Windows-ISO-Updater.SHA256SUMS.txt` file attached to the release.

### Command Examples

**Unattended Custom Build:**
```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11.iso" -Edition "Windows 11 Pro" -Unattended
```

**Repeatable Build from a [JSON Profile](docs/usage.md#using-a-json-profile):**
```bat
.\Run-Windows-ISO-Updater.bat -ConfigPath "D:\Profiles\win11.json"
```

**Windows Server Build:**
```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Server2025.iso"
```

---

## Requirements

* Windows 10, Windows Server 2016, or newer
* PowerShell 5.1 or newer
* Administrator permissions
* Active internet connection for update retrieval
* Sufficient local storage space (at least 50 GB free recommended)
* A local disk for the working folder, not a network share or a cloud-synced folder ([why](docs/reference.md#keep-the-working-folder-on-a-local-disk))

---

## Documentation Links

<!-- github-only -->
For search and easier navigation, read the documentation at [bryceforsm.github.io/Windows-ISO-Updater](https://bryceforsm.github.io/Windows-ISO-Updater/).

<!-- /github-only -->
* [Usage Guide](docs/usage.md)
* [Command-Line Parameters](docs/parameters.md)
* [Scheduled Automation](docs/scheduled-runs.md)
* [Unattended Setups](docs/unattended-installs.md)
* [Architecture and Design Details](docs/design-notes.md)
* [Technical Reference](docs/reference.md)
* [Change Log](CHANGELOG.md)

## Reporting Issues

For any problem with this tool, please [submit a GitHub issue](https://github.com/bryceforsm/Windows-ISO-Updater/issues).

**Attach the logs from the run.** They show what the tool found, chose and did at each step, so an issue that includes them can usually be fixed without a round of follow-up questions. They are in the `Logs` folder under the working folder (`<WorkPath>\Logs`, or `-LogPath` if you set it). Attach these files from the run that went wrong:

* `Windows-ISO-Updater_<date>_<time>.log`, the main log
* `Windows-ISO-Updater_<date>_<time>_console.txt`, everything that appeared on screen
* The `Windows-ISO-Updater_<date>_<time>_DISM` folder, if there is one. It is only created when an update failed to apply.

Please also include:

* The command you ran, or the JSON profile if you used `-ConfigPath`
* Whether you started it from Windows PowerShell, PowerShell 7 or the `.bat` file
* Where the source ISO came from, for example the Microsoft website, the Evaluation Center or Visual Studio subscriptions

The logs record the computer name and the full paths the run used, which often include your Windows user name. Look them over and replace anything you would rather not post before attaching them. See [Logging](docs/reference.md#logging) for what each file contains.

Issues and pull requests with no activity for 90 days are marked as stale and closed 14 days later. Any comment keeps one open.

## Feature Requests

Ideas are welcome. [Open a GitHub issue](https://github.com/bryceforsm/Windows-ISO-Updater/issues) that describes what you want to do and why the tool does not cover it today. An example of the command or setup you have in mind helps.

This tool is built to run hands off, from a single command or a scheduled task, and is kept tightly scoped to automating updated install media. Requests are weighed against that. Features that need someone at the screen, such as a graphical interface, may not be added, because they would make the tool more complex to use and to maintain without helping the automated builds it exists for.

## License

Distributed under the [MIT License](LICENSE). Third-party utilities and Microsoft updates fetched during runtime remain governed by their respective vendor terms.