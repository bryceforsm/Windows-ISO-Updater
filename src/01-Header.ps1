# Windows ISO Updater
# Version: 2026.11.02.1   (date-based, stamped automatically by tools\Update-Version.ps1 on commit)
#
#region Script overview
# This script builds a fully up-to-date ("slipstreamed") Windows 11, Windows 10 or Windows Server
# 2016-2025 installation ISO.
# It takes an official Microsoft ISO, downloads the latest cumulative update(s) from the Microsoft Update
# Catalog, integrates those updates directly into the Windows images inside the ISO, and then recompiles a
# brand-new, bootable ISO that already contains this month's patches.
#
# Building patched media means a fresh install (or in-place upgrade) starts already updated, instead of
# spending an hour downloading and installing the same cumulative update after Setup finishes.
#
# It performs the following actions:
#   1. Takes the ISO from you: -IsoPath, or any ISO already sitting in the download folder. Nothing is
#      downloaded automatically unless you ask for it, because Microsoft rate-limits and can temporarily
#      block IPs that make repeated ISO requests, which makes an automatic download the least dependable
#      part of a run. -UseFido opts into fetching the matching official Microsoft ISO with the community
#      "Fido" helper (which queries Microsoft's own software-download servers), retrying blocked link
#      requests with a backoff (-FidoRetryCount). -UseMct instead opens Microsoft's Media Creation Tool,
#      which talks to different servers but has no headless mode, so you click through its last few pages
#      yourself. Either way Windows Server media has to be supplied by hand, because neither source
#      serves it. Server versus client is worked out from the image, so no switch announces it.
#   2. Extracts the ISO to a writable working folder.
#   3. Detects the Windows feature-update (e.g. 25H2) and architecture from the image, then downloads the
#      latest combined Servicing Stack + Cumulative Update (LCU) - and the .NET cumulative update
#      (on by default, disable with -SkipDotNet) - from the Microsoft Update Catalog. The optional
#      preview updates released late in the month are passed over unless -IncludePreview says otherwise.
#      You may instead point at your own .msu/.cab files with -UpdatePath.
#   4. Integrates the update(s) offline with DISM into install.wim (by default the other editions are
#      dropped and only the kept ones are serviced - on client media Enterprise, Pro and Home, whichever
#      of them the media carries, or on Server media the most upgradeable one, Standard over Datacenter -
#      so use -KeepAllEditions or -KeepEditions to change this), boot.wim (Windows Setup / WinPE), and
#      winre.wim (recovery), which gets the Safe OS Dynamic Update rather than the cumulative update and
#      is then re-exported so it stays small enough for the recovery partition (disable with -SkipWinRE).
#      -DriverPath also injects a folder of .inf driver packages into
#      every serviced edition and into boot.wim index 2, so Setup itself can see the hardware.
#   5. Refreshes the loose Setup files on the media: first applies the Setup Dynamic Update to the
#      sources folder (on by default, disable with -SkipSetupDU), then overwrites sources\setup.exe,
#      sources\setuphost.exe and the boot managers from the serviced boot.wim - Windows Setup fails if
#      those binaries don't match the version inside boot.wim - then cleans up the component store
#      (/StartComponentCleanup /ResetBase) and re-exports install.wim to shrink it.
#   6. Recompiles a new bootable ISO with oscdimg (downloaded from Microsoft if not already installed
#      with the Windows ADK), preserving both the BIOS and
#      UEFI boot sectors so the new ISO boots on legacy and modern PCs alike. An answer file supplied with
#      -UnattendPath is placed at the root of the media as autounattend.xml, which Windows Setup reads
#      automatically when the ISO is booted, and -ExtraFilesPath copies a folder of your own files onto
#      the media, reporting anything it replaces. A \WISO-Build folder is also written onto the media (turn it
#      off with -SkipTattoo) recording what the ISO was made from, which updates applied or failed, what
#      was kept and stripped, who built it and when, plus a copy of the script that built it.
#      -AnonymousTattoo leaves the machine, user and local paths out of it, for media handed to others.
#   7. Records a "stamp" of the finished build (the source ISO's hash, the updates that went in, the
#      parameters used and the ISO that came out) and keeps a history of them. The next run compares
#      itself with that stamp first and exits in a minute or two when nothing has changed, which is what
#      makes it safe to run this from a scheduled task - see -Scheduled and -RegisterScheduledTask.
#      -AutoClean then prunes the update packages and generated ISOs that earlier builds left behind.
#
# This is disk- and time-intensive: with the default parameters a full run normally takes an hour or two.
# It needs a lot of free space (the download, the extracted media, the mounted image, and the exported
# image all coexist) and DISM servicing/cleanup can take a long time.
# Nothing on the running machine is changed - all servicing happens against files in the working folder.
# -------------------------------------------------
# How to Run .PS1 Script with PowerShell:
# NOTE: It is recommended to use the "Run-Windows-ISO-Updater.bat" to invoke this script. However, you can run the .PS1 directly if needed.
# 1.  Open PowerShell as an Administrator: Right-click your Start Menu and select "Terminal (Admin)".
# 2.  Enable Script Execution for this window only (if needed): Set-ExecutionPolicy Bypass -Scope Process -Force
# 3.  Run the Script from that window: .\Windows-ISO-Updater.ps1
# -------------------------------------------------
#endregion

