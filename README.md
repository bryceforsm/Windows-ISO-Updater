# Windows ISO Updater

Automate the process of updating Windows installation media. This PowerShell script takes an official Microsoft ISO, slipstreams the latest cumulative updates directly into the Windows image using DISM, and generates a fresh, fully patched bootable ISO. 

Installing Windows from this updated media saves time by eliminating large post-installation update downloads.

## Key Features

* **Safe Execution**: All operations occur within an isolated temporary directory (`C:\WISO-Work` by default). The host system configuration remains untouched.
* **No Manual ADK Setup Needed**: Automatically fetches a verified copy of `oscdimg.exe` from Microsoft servers to compile the media.
* **Official Sources Only**: Downloads packages directly from Microsoft endpoints over HTTPS.
* **Windows Server Support**: Compatible with Windows Server media, detected automatically from the image.
* **Secure Boot Ready**: Microsoft's signed boot files are kept as they are, so the ISO boots with Secure Boot on ([writing it to USB](docs/usage.md#writing-the-iso-to-a-usb-stick)).

---

## Quick Start

1. Place [`Run-Windows-ISO-Updater.bat`](https://github.com/bryceforsm/Windows-ISO-Updater/releases) and [`Windows-ISO-Updater.ps1`](https://github.com/bryceforsm/Windows-ISO-Updater/releases) in the same directory.
2. Put an official Windows ISO in `C:\WISO-Work\Downloads` or specify its location with `-IsoPath`.
3. Right-click `Run-Windows-ISO-Updater.bat` and select **Run as administrator**.
4. Confirm the build settings displayed in the console prompt.

### Command Examples

**Unattended Custom Build:**
```bat
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11.iso" -Edition "Windows 11 Pro" -Unattended
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

## Reporting Issues

For any problem with this tool, please [submit a GitHub issue](https://github.com/bryceforsm/Windows-ISO-Updater/issues).

## License

Distributed under the [MIT License](LICENSE). Third-party utilities and Microsoft updates fetched during runtime remain governed by their respective vendor terms.