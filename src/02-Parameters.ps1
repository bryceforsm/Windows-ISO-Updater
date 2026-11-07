#region Parameters
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'TaskPassword',
    Justification = 'Register-ScheduledTask -Password requires [string]. The value is excluded from all command-line surfaces and logs by design.')]
param(
    [Parameter(HelpMessage = 'Runs the script without any confirmation prompts')]
    [switch]$Unattended,

    [Parameter(HelpMessage = 'Path to an existing Windows ISO to update instead of downloading one from Microsoft. May also be a folder, in which case the most recently modified .iso over 3 GB directly inside it is used by default (the search is not recursive); see -UseLargestIso to pick by size instead')]
    [string]$IsoPath,

    [Parameter(HelpMessage = 'When -IsoPath (or the download folder) is a directory holding more than one .iso, pick the largest .iso over 3 GB instead of the most recently modified one')]
    [switch]$UseLargestIso,

    [Parameter(HelpMessage = 'Windows version to download when no ISO is supplied: 10 or 11. Defaults to 11. Once an ISO is mounted, catalog searches use the version the image itself reports, not this parameter, so it does not need to match -IsoPath media')]
    [ValidateSet('10', '11')]
    [string]$WindowsVersion = '11',

    [Parameter(HelpMessage = 'Deprecated and no longer needed. Server media (2016 through 2025) is detected from the image itself, so pointing -IsoPath at a Server ISO or dropping one into the download folder is enough, and -WindowsVersion, -Release and -Language are ignored once it is detected. Still accepted so existing scheduled tasks and wrapper scripts keep running, and before any ISO is in hand it is treated as a hint that no client ISO should be downloaded')]
    [switch]$Server,

    [Parameter(HelpMessage = 'Fido release to request (e.g. 25H2, 24H2) or "Latest". Defaults to Latest')]
    [string]$Release = 'Latest',

    [Parameter(HelpMessage = 'ISO language as named by Microsoft/Fido (e.g. English, "English International"). Defaults to English')]
    [string]$Language = 'English',

    [Parameter(HelpMessage = 'Which edition inside install.wim to service: "All" (default) or an edition name like "Windows 11 Pro"')]
    [string]$Edition = 'All',

    [Parameter(HelpMessage = 'Editions to KEEP in the final ISO, removing the rest to slim it down. Accepts edition names like "Windows 11 Pro" (partial matches allowed) or index numbers, comma-separated. Overrides the default of keeping Enterprise, Pro and Home')]
    [string[]]$KeepEditions,

    [Parameter(HelpMessage = 'Keep every edition in the final ISO. By default only some are kept to speed up servicing and shrink the ISO: on client media Enterprise, Pro and Home, whichever of them the media carries, or on Server media the most upgradeable one (Standard over Datacenter, since Standard can be upgraded in place but Datacenter cannot be downgraded)')]
    [switch]$KeepAllEditions,

    [Parameter(HelpMessage = 'Only list the editions/indexes inside the ISO''s install.wim and exit (does not download updates or build anything). Useful for choosing -Edition/-KeepEditions values')]
    [switch]$ListEditions,

    [Parameter(HelpMessage = 'Folder containing your own .msu/.cab update packages to integrate instead of fetching from the Microsoft Update Catalog')]
    [string]$UpdatePath,

    [Parameter(HelpMessage = 'Skip downloading and integrating the latest .NET cumulative update. The .NET update is included by default, so use this switch to leave it out')]
    [switch]$SkipDotNet,

    [Parameter(HelpMessage = 'Skip the Setup Dynamic Update that refreshes the loose Windows Setup files on the media. It is included by default, and without it the Windows 11 24H2+ Setup engine can fail with "Windows 11 installation has failed"')]
    [switch]$SkipSetupDU,

    [Parameter(HelpMessage = 'Skip servicing the recovery image (winre.wim). It is serviced by default with the Safe OS Dynamic Update, then cleaned and re-exported so it does not grow. Without it a deployed machine keeps whatever recovery environment the source media shipped, which Windows only replaces on some rollup updates')]
    [switch]$SkipWinRE,

    [Parameter(HelpMessage = 'Deprecated and ignored. Recovery image servicing is on by default now, so use -SkipWinRE to turn it off. Accepted so existing scheduled tasks and wrapper scripts that still pass it keep running')]
    [switch]$ServiceWinRE,

    [Parameter(HelpMessage = 'Integrate the latest hotpatch baseline named by Microsoft''s hotpatch calendar rather than the newest cumulative update. If the calendar cannot be read, the newest security update from January, April, July or October is used with a warning. Use only for Windows 11 Enterprise 25H2 media enrolled in Intune or Azure Arc hotpatch.')]
    [switch]$BaselineOnly,

    [Parameter(HelpMessage = 'Allow the optional preview updates Microsoft publishes late in the month (titled "... Preview of Monthly Quality Rollup" or "Cumulative Update Preview") to be selected. They are excluded by default because they are next month''s fixes released early for testing, so they carry a higher build than anything Windows Update will offer the finished media. Useful for validating a coming update, not for production media')]
    [switch]$IncludePreview,

    [Parameter(HelpMessage = 'Mount the image read-only and read its real patch level from the registry before deciding whether the cumulative update is needed. By default the build recorded in the WIM header is trusted, which is instant but is wrong on some media (UUP-built and Media Creation Tool images can report an old revision while being fully patched, or the reverse). Costs a few minutes')]
    [switch]$VerifyPatchLevel,

    [Parameter(HelpMessage = 'Integrate every update even when the image already carries the latest cumulative update. By default media that is already current is left exactly as Microsoft shipped it, with no .NET update, Dynamic Update or boot.wim servicing. The build stamp still applies, so this rebuilds once and then only when something changes. WARNING: enabling this may leave the Setup binaries on the media mismatched with the ones inside boot.wim, which can stop Windows 11 Setup Dynamic Update from completing when imaging a computer with Windows 11')]
    [switch]$ReapplyUpdates,

    [Parameter(HelpMessage = 'Skip integrating updates entirely and simply extract and recompile the ISO (useful for testing the build pipeline)')]
    [switch]$SkipUpdates,

    [Parameter(HelpMessage = 'Extract and recompile the ISO without applying any updates, drivers, or WIM servicing. Combine with -UnattendPath or -ExtraFilesPath to inject files into the extracted layout before it is repacked.')]
    [switch]$SkipServicing,

    [Parameter(HelpMessage = 'Export the finished image as install.esd (LZMS "recovery" compression) instead of install.wim. Typically 25-40% smaller, which can bring the image under the 4 GB FAT32 limit for UEFI USB sticks, but the export is slow and the finished media cannot be serviced again without converting it back')]
    [switch]$CompressEsd,

    [Parameter(HelpMessage = 'Use Fast WIM compression instead of Max when exporting install.wim, boot.wim, or converting install.esd. Builds faster with a slightly larger output WIM. Has no effect when -CompressEsd is active.')]
    [switch]$FastCompression,

    [Parameter(HelpMessage = 'Exclude the folders DISM works in (ISO, Mount, WinREMount, BuildCheck and WinRECache under the working folder) from Microsoft Defender real-time scanning while the build runs, which speeds up every DISM step. The exclusions are removed when the run ends, however it ends, and any that were already there are left alone. Downloads and the finished ISO are still scanned')]
    [switch]$ExcludeWorkPathFromDefender,

    [Parameter(HelpMessage = 'Path to an unattended answer file to place on the finished ISO as \autounattend.xml, so Windows Setup runs without prompting')]
    [string]$UnattendPath,

    [Parameter(HelpMessage = 'Folder of driver packages (.inf and their .sys/.cat files) to inject into the images. Searched recursively. Every serviced edition of install.wim gets them, and so does boot.wim index 2, so Windows Setup itself can see storage controllers and network adapters the media has no driver for')]
    [string]$DriverPath,

    [Parameter(HelpMessage = 'Inject drivers even when they are unsigned or signed by a certificate the image does not trust. Off by default. 64-bit Windows refuses to load an unsigned driver at boot unless test signing is enabled, so this is only useful for drivers whose certificate is added separately')]
    [switch]$AllowUnsignedDrivers,

    [Parameter(HelpMessage = 'Folder whose contents are copied onto the root of the finished ISO, keeping the folder structure. Files that land on top of something the media already has are reported individually')]
    [string]$ExtraFilesPath,

    [Parameter(HelpMessage = 'Do not tattoo the finished ISO. By default a \WISO-Build folder is added to the media recording what this build was made from, which updates applied or failed, what was kept and stripped, who built it and when, plus a copy of the script that made it')]
    [switch]$SkipTattoo,

    [Parameter(HelpMessage = 'Leave the build machine name, user name, script path, command line and log path out of the \WISO-Build record, and reduce the -DriverPath, -ExtraFilesPath and -UpdatePath folders to their last component. Use it for media you hand to other people')]
    [switch]$AnonymousTattoo,

    [Parameter(HelpMessage = 'Directory to download the ISO/updates into. Defaults to a Downloads folder inside the working folder. Needs several GB free')]
    [string]$DownloadPath,

    [Parameter(HelpMessage = 'Working folder used to extract and service the media. Must be on a fast drive with lots of free space. Defaults to <SystemDrive>\WISO-Work')]
    [string]$WorkPath,

    [Parameter(HelpMessage = 'Where to write the recompiled ISO. Give it a full file path to name the ISO yourself, or a folder to keep the generated name and only change where it lands. Defaults to the Output folder under the working folder')]
    [string]$OutputIsoPath,

    [Parameter(HelpMessage = 'Text to prepend to the auto-generated ISO file name (e.g. "Company-" produces Company-Win11_Pro_x64_....iso). Has no effect when -OutputIsoPath is a full file path')]
    [string]$IsoNamePrefix,

    [Parameter(HelpMessage = 'Text to append to the auto-generated ISO file name base, before the .iso extension (e.g. "-Unattended" produces Win11_Pro_x64_...-Unattended.iso). Has no effect when -OutputIsoPath is a full file path')]
    [string]$IsoNameSuffix,

    [Parameter(HelpMessage = 'Volume label written into the finished ISO, which is what File Explorer shows and what Rufus and Ventoy copy onto the USB stick. Defaults to a label describing the contents, such as WIN11_ENTPRO_X64_26100_4652. Maximum 32 characters, no spaces')]
    [ValidatePattern('^[A-Za-z0-9._-]{1,32}$')]
    [string]$VolumeLabel,

    [Parameter(HelpMessage = 'Also build a small recovery ISO that boots straight into the Windows Recovery Environment (Startup Repair, System Restore, Uninstall Updates, Command Prompt), using the recovery image from the serviced install.wim. Give it a full file path, or a folder to keep the generated name. It carries only the boot files and the recovery image, never the answer file or the -ExtraFilesPath content. -AutoClean keeps the newest -KeepIsoCount generated recovery ISOs in that folder, counted separately from the installation ISOs')]
    [string]$RecoveryIsoPath,

    [Parameter(HelpMessage = 'Build only the recovery ISO and stop. The source ISO is read in place rather than extracted, install.wim is never serviced, and only the Safe OS Dynamic Update is downloaded, so it takes minutes rather than hours. Written to -RecoveryIsoPath, or to the Output folder under the working folder when that is not given. Keeps no build stamps, so every run builds a fresh one')]
    [switch]$RecoveryIsoOnly,

    [Parameter(HelpMessage = 'Full path to oscdimg.exe if the Windows ADK is installed in a non-standard location')]
    [string]$OscdimgPath,

    [Parameter(HelpMessage = 'If oscdimg.exe (Windows ADK Deployment Tools) is not found, download and silently install it from Microsoft')]
    [switch]$InstallAdk,

    [Parameter(HelpMessage = 'Skip the standalone oscdimg.exe download from the Microsoft symbol server and require the Windows ADK instead')]
    [switch]$SkipOscdimgDownload,

    [Parameter(HelpMessage = 'Download the ISO with the Fido helper when you have not supplied one. Off by default, because Microsoft blocks the download-link requests Fido makes often enough that passing your own ISO with -IsoPath is the more reliable way to run this')]
    [switch]$UseFido,

    [Parameter(HelpMessage = 'Override the URL used to fetch the Fido download helper')]
    [string]$FidoUrl = 'https://github.com/pbatard/Fido/raw/266084e3765ab8bf96767bd55c51b0ee70934551/Fido.ps1',

    [Parameter(HelpMessage = 'Expected SHA-256 of the downloaded Fido.ps1. Defaults to the pinned version. Pass an empty string to skip the hash check (needed if you override -FidoUrl without giving the new hash)')]
    [string]$FidoSha256 = '89A26B4A8BE2721E610BA3F563EC44024E6CF7975938EE5B61D624D2BFBF4643',

    [Parameter(HelpMessage = 'How many extra attempts to make if Fido cannot resolve a download link (Microsoft''s anti-bot check often clears on a later attempt). Defaults to 2')]
    [ValidateRange(0, 10)]
    [int]$FidoRetryCount = 2,

    [Parameter(HelpMessage = 'Get the ISO with Microsoft''s Media Creation Tool instead of supplying one yourself or using -UseFido. MCT cannot run headless, so you click through its wizard and save the ISO into the download folder')]
    [switch]$UseMct,

    [Parameter(HelpMessage = 'Override the URL used to download the Media Creation Tool')]
    [string]$MctUrl,

    [Parameter(HelpMessage = 'Edition passed to the Media Creation Tool''s /MediaEdition switch (e.g. Professional, Enterprise, Education). Only used with -MctPreselect, and it makes MCT ask for a product key')]
    [string]$MctEdition,

    [Parameter(HelpMessage = 'Launch the Media Creation Tool with the architecture/language/edition switches pre-filled. Off by default because driving MCT that way makes it demand a product key')]
    [switch]$MctPreselect,

    [Parameter(HelpMessage = 'Language code passed to the Media Creation Tool''s /MediaLangCode switch (e.g. en-US). Derived from -Language when not set')]
    [string]$MctLangCode,

    [Parameter(HelpMessage = 'Override the URL used to download the Windows ADK setup bootstrapper (Deployment Tools)')]
    [string]$AdkSetupUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980',

    [Parameter(HelpMessage = 'Override the Microsoft symbol server URL used to download a standalone oscdimg.exe')]
    [string]$OscdimgUrl = 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/688CABB065000/oscdimg.exe',

    [Parameter(HelpMessage = 'Expected SHA-256 of the downloaded oscdimg.exe. Pass an empty string to skip the hash check (needed if you override -OscdimgUrl)')]
    [string]$OscdimgSha256 = '2000160B2C5044691B2F9A0AC308E5207F273D4880A572457AF16D05886BA861',

    [Parameter(HelpMessage = 'Directory to write log files to. Defaults to a "Logs" folder inside the working folder, so everything the script writes stays in one place')]
    [string]$LogPath,

    [Parameter(HelpMessage = 'Directory to keep the build stamps in (the JSON record of what each finished build contained). Defaults to a "Stamps" folder inside the working folder')]
    [string]$StampPath,

    [Parameter(HelpMessage = 'How many past stamps to keep in the stamp history folder. Defaults to 30')]
    [ValidateRange(1, 1000)]
    [int]$StampHistoryCount = 30,

    [Parameter(HelpMessage = 'Run as a scheduled/unattended job: no prompts, no "press enter to exit", and the whole build is skipped when the last stamp shows that nothing has changed')]
    [switch]$Scheduled,

    [Parameter(HelpMessage = 'Rebuild even when the stamp says nothing has changed since the last build')]
    [switch]$Force,

    [Parameter(HelpMessage = 'Only report whether a rebuild is needed and exit without building anything. Exit code 0 = nothing to do, 10 = a rebuild is needed')]
    [switch]$CheckOnly,

    [Parameter(HelpMessage = 'Ignore the stamps completely: do not read one to skip the run, and do not write one at the end')]
    [switch]$NoStamp,

    [Parameter(HelpMessage = 'After a successful build, delete the update packages this script downloaded for previous builds and all but the newest generated ISOs')]
    [switch]$AutoClean,

    [Parameter(HelpMessage = 'Strip servicing residue from each image before committing it: DISM logs, temp files, and leftovers such as $Recycle.Bin that clean Microsoft media never contains. Off by default, so the images are committed exactly as DISM left them. Not everything that looks like leftover state is, some of it is there by design, so test an ISO built with this switch by installing from it once before you deploy from it')]
    [switch]$StripImageResidue,

    [Parameter(HelpMessage = 'How many generated ISOs -AutoClean keeps (newest first). Defaults to 3')]
    [ValidateRange(1, 100)]
    [int]$KeepIsoCount = 3,

    [Parameter(HelpMessage = 'Create (or update) a scheduled task that runs this script with the other parameters you passed, then exit without building')]
    [switch]$RegisterScheduledTask,

    [Parameter(HelpMessage = 'Delete the scheduled task named by -TaskName, then exit')]
    [switch]$UnregisterScheduledTask,

    [Parameter(HelpMessage = 'How often the registered task runs: Hourly, Daily, Weekly, Monthly or PatchTuesday. Defaults to Monthly. PatchTuesday runs on the second Tuesday of every month, half an hour after Microsoft publishes that month''s updates')]
    [ValidateSet('Hourly', 'Daily', 'Weekly', 'Monthly', 'PatchTuesday')]
    [string]$Schedule = 'Monthly',

    [Parameter(HelpMessage = 'Time of day the registered task starts, as HH:mm (24-hour). Defaults to 03:00, or for -Schedule PatchTuesday to whatever 10:30 Pacific (DST included) is in this machine''s time zone')]
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$ScheduleTime = '03:00',

    [Parameter(HelpMessage = 'Which day the registered task runs: a weekday name for -Schedule Weekly (default Sunday), or a day number 1-31 for -Schedule Monthly (default 15, a few days after Patch Tuesday). Ignored by -Schedule PatchTuesday, which picks the day itself')]
    [string]$ScheduleDay,

    [Parameter(HelpMessage = 'Name of the scheduled task to create or delete. Defaults to "Windows ISO Updater"')]
    [string]$TaskName = 'Windows ISO Updater',

    [Parameter(HelpMessage = 'Username of the account to run the scheduled task as (e.g. DOMAIN\SvcAccount). Defaults to SYSTEM when omitted.')]
    [string]$TaskUsername,

    [Parameter(HelpMessage = 'Password for the TaskUsername account. Never stored in the task action arguments or written to logs.')]
    [string]$TaskPassword,

    [Parameter(HelpMessage = 'Path to a JSON profile holding build settings, named after these parameters, so a build can be repeated without a long command line. Anything also passed on the command line wins. Relative paths inside it are relative to the profile. Task registration, one-off actions such as -CheckOnly and passwords cannot go in a profile')]
    [string]$ConfigPath,

    [Parameter(HelpMessage = 'Ask for the -TaskUsername password at startup without echoing it. Added automatically when the script relaunches itself elevated, so the password never appears on a command line')]
    [switch]$PromptTaskPassword,

    [switch]$SkipInteractive # Skips the interactive confirmation prompt
)
#endregion

