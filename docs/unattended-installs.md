[← Back to README](../README.md)

# Unattended Installs

Pass an answer file with `-UnattendPath` and it is copied to the root of the finished ISO as `autounattend.xml`:

```bat
.\Run-Windows-ISO-Updater.bat -UnattendPath "C:\Answer\autounattend.xml"
```

Windows Setup implicitly reads `\autounattend.xml` from the root of read-only boot media during the `windowsPE` pass, so nothing else is needed. Boot the ISO and Setup applies whatever the file sets, and asks for anything it leaves out. Generate the file with [Windows System Image Manager](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/windows-system-image-manager-technical-reference) (part of the ADK) or a generator such as [schneegans.de/windows/unattend-generator](https://schneegans.de/windows/unattend-generator/).

The script validates that the file exists and is well-formed XML before starting the build, and warns if the root element is not `<unattend>`.

> [!WARNING]
> Two things to watch for with any answer file:
> - **Edition selection.** By default this script drops the editions it is not keeping and renumbers `install.wim`, so an answer file that selects the edition with `/IMAGE/INDEX` will point at the wrong image. The default keeps the highest edition at index 1 (Enterprise, then Pro, then Home, in that order), so index 1 still means what it used to, but `/IMAGE/NAME` is the safer choice. Use it, or build with `-KeepAllEditions`. The script warns when it detects this combination.
> - **Secrets.** Answer files store passwords in plain text or base64 and product keys in the clear. Anyone who can read the ISO can recover them, so treat the finished ISO as a secret and don't commit the answer file to source control.

## Finishing the Updates After Setup

An updated ISO installs Windows at this month's patch level, but a few things can never be put on the media, because they are not packages DISM can add to an image ([why](design-notes.md#what-windows-update-will-still-offer)). [`Examples/autounattend-update-after-setup.xml`](../Examples/autounattend-update-after-setup.xml) takes care of them on the installed machine instead:

```bat
.\Run-Windows-ISO-Updater.bat -UnattendPath ".\Examples\autounattend-update-after-setup.xml"
```

It changes nothing else about Setup. Setup still asks which disk to use, the region, the keyboard and the account, exactly as it would without an answer file, and an Autopilot device still checks in. Nothing in it can wipe a disk, so it is safe to put on any ISO.

### What it does

During Setup's `specialize` pass it writes `C:\Windows\Setup\Scripts\Update-AfterSetup.ps1` and registers a scheduled task that runs it as SYSTEM, two minutes after each startup. On each run the script:

1. **Waits for the setup screens to finish**, so it never competes with the updating that OOBE and Autopilot do themselves.
2. **Waits for an internet connection**, using the same test page Windows uses to decide it is online.
3. **Updates Microsoft Defender's security intelligence.** It changes several times a day, so it is out of date on any ISO the moment the ISO is built. This step is skipped when another antivirus is the active one.
4. **Installs whatever Windows Update still offers:** drivers, the Malicious Software Removal Tool, the Defender platform, and anything published after the ISO was built. It runs up to three rounds, because some updates only appear once others are in.
5. **Asks the Microsoft Store to update its apps**, which are often months old on fresh media. The Store does the downloading in the background.

When a run finds nothing left to install, the task deletes itself. A run that installed something keeps it, so the next startup checks again for anything that only appears after a restart. It stops after five runs regardless, so an update that keeps failing cannot keep it going forever.

### What it leaves alone

- **Restarts.** It never restarts the computer. When an update needs one, the log says so and the moment is yours.
- **Optional and preview updates**, which Settings lists under *Optional updates*. The monthly preview is next month's update released early for testing, for the same reasons the ISO leaves it out ([why](design-notes.md#why-preview-updates-are-left-out)).
- **Feature updates.** Moving to a new Windows release is a decision for whoever owns the machine, not something to slip in after setup.
- **Updates that need someone to answer a prompt**, because nobody is there to answer it.
- **Your update policy.** On a managed machine, Windows Update follows the machine's own policy, so updates come from WSUS, or are deferred, exactly as they would be otherwise.

### Checking what it did

Everything it does is logged to `C:\Windows\Logs\Update-AfterSetup.log`, with each update it installed or skipped by name. While it still has work to do, the task shows in Task Scheduler as **Windows ISO Updater - Updates After Setup**. To stop it early, delete that task.

> [!NOTE]
> Test it once on a machine you can reinstall before deploying from it. The task is registered during the `specialize` pass, and some environments restrict what can run there.

### Using it with your own answer file

To keep your own answer file and add this to it, copy two things from the example into yours:

- **Both `RunSynchronousCommand` entries** from the `specialize` pass, into your file's `Microsoft-Windows-Deployment` component for that pass. Renumber their `<Order>` so they come after your own commands, keeping the extraction command first. Copy the `arm64` component too if you build ARM64 media.
- **The whole `<Extensions>` block** at the end, which carries the script. Windows Setup ignores it. The first command reads it back from the copy of the answer file Setup keeps at `C:\Windows\Panther\unattend.xml`, and writes the script to disk.

If your file came from the schneegans.de generator, it already has an `<Extensions>` block and its own command that writes every `<File>` in it. Add this example's `<File>` element to that block, and copy only the second command, the one that registers the task, ordered after your file's own extraction command.

[← Back to README](../README.md)
