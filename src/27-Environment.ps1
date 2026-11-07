#region Environment report
# What the log header records about the machine, so a log attached to an issue already answers the questions
# that otherwise take a round of replies: which Windows and DISM did the servicing, what was scanning the
# files, whether the host was waiting on a restart, what the working drive is, and how the downloads reached
# the internet. Every detail is read on its own and turns into "unknown" rather than stopping the run, because
# none of it is worth failing a build over. Nothing that identifies the hardware itself, such as a serial
# number, is read.

# The proxy set with "netsh winhttp set proxy", read from its registry blob rather than from netsh, whose
# output is translated. The blob is a version, a counter, a flags word, then a length-prefixed ASCII string.
function Get-WinHttpProxy {
    param([byte[]]$Settings)
    if (-not $Settings -or $Settings.Length -lt 16) { return $null }
    $Length = [System.BitConverter]::ToInt32($Settings, 12)
    if ($Length -le 0 -or 16 + $Length -gt $Settings.Length) { return $null }
    return [System.Text.Encoding]::ASCII.GetString($Settings, 16, $Length)
}

# Whether the manufacturer and model a machine reports are a hypervisor's. "Hypervisor present" alone cannot
# say, because it is also true on a physical host that has Hyper-V or virtualization-based security turned on.
function Test-VirtualMachineModel {
    param(
        [string]$Manufacturer,
        [string]$Model
    )
    $Text = "$Manufacturer $Model"
    return ($Text -match '(?i)virtual machine|vmware|virtualbox|innotek|qemu|kvm|xen|parallels|bochs|amazon ec2|google compute engine')
}

# How long ago, in the two largest units that matter: "3 days 4 hours", "5 hours 12 minutes", "12 minutes".
function Format-Uptime {
    param([TimeSpan]$Uptime)
    $Part = { param($Count, $Unit) if ($Count -eq 1) { "1 $Unit" } else { "$Count ${Unit}s" } }
    if ($Uptime.TotalDays -ge 1) { return '{0} {1}' -f (& $Part ([int][math]::Floor($Uptime.TotalDays)) 'day'), (& $Part $Uptime.Hours 'hour') }
    if ($Uptime.TotalHours -ge 1) { return '{0} {1}' -f (& $Part $Uptime.Hours 'hour'), (& $Part $Uptime.Minutes 'minute') }
    return (& $Part ([int][math]::Max(0, [math]::Floor($Uptime.TotalMinutes))) 'minute')
}

function Format-Gigabytes {
    param([double]$Bytes)
    if ($Bytes -ge 100GB) { return ('{0:N0} GB' -f ($Bytes / 1GB)) }
    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

# Returns the lines of the report as label, value and colour. Yellow marks the one thing worth fixing before
# a build: a restart the host's own servicing stack is waiting on.
function Get-EnvironmentReport {
    param([Parameter(Mandatory)][string]$WorkRoot)

    $Lines = [System.Collections.Generic.List[psobject]]::new()
    $Add = { param($Label, $Value, $Color = 'Gray') $Lines.Add([pscustomobject]@{ Label = $Label; Value = $Value; Color = $Color }) }
    $Os = $null
    try { $Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }

    # Windows, with the patch level (UBR) the CIM caption leaves out.
    try {
        $Current = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $Name = ("$($Os.Caption)" -replace '^Microsoft\s+', '').Trim()
        $Release = if ($Current.DisplayVersion) { " $($Current.DisplayVersion)" } elseif ($Current.ReleaseId) { " $($Current.ReleaseId)" } else { '' }
        & $Add 'Windows' ('{0}{1}, build {2}.{3}, {4}' -f $Name, $Release, $Current.CurrentBuildNumber, $Current.UBR, $Os.OSArchitecture)
    }
    catch { & $Add 'Windows' 'unknown' }

    & $Add 'PowerShell' ('{0} ({1}), host: {2}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $Host.Name)

    # The DISM that services the image is the host's own. One older than the image it services is a common
    # reason an update refuses to apply.
    try {
        $Dism = Get-Command -Name 'dism.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        & $Add 'DISM' ('{0} ({1})' -f $Dism.FileVersionInfo.ProductVersion, $Dism.Source)
    }
    catch { & $Add 'DISM' 'unknown' }

    # Who the run is, and whether BITS can work for that logon (see Test-BitsUsable).
    try {
        $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $Elevated = ([System.Security.Principal.WindowsPrincipal]$Identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $Session = if ($Scheduled) { 'scheduled run' } elseif ([Environment]::UserInteractive) { 'interactive' } else { 'non-interactive' }
        $Bits = if (Test-BitsUsable) { 'BITS available' } else { 'BITS not available for this logon' }
        & $Add 'Run as' ('{0}, {1}, {2}, {3}' -f $Identity.Name, $(if ($Elevated) { 'elevated' } else { 'not elevated' }), $Session, $Bits)
    }
    catch { & $Add 'Run as' 'unknown' }

    # What scans the files DISM writes. Security Center lists third-party products on client Windows only,
    # so on Server just Defender's own state is known.
    try {
        $Products = @()
        try {
            $Products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
                    ForEach-Object { $_.displayName } | Where-Object { $_ -and $_ -notmatch '(?i)^Windows Defender$|^Microsoft Defender' } | Select-Object -Unique)
        }
        catch { }
        $Defender = switch (Get-DefenderState) {
            'Active' { 'Microsoft Defender, real-time protection on' }
            'Off' { 'Microsoft Defender, real-time protection off' }
            'Passive' { 'Microsoft Defender in passive mode' }
            default { 'Microsoft Defender not available' }
        }
        & $Add 'Antivirus' ($(if ($Products) { "$($Products -join ', '); " }) + $Defender)
    }
    catch { & $Add 'Antivirus' 'unknown' }

    # A pending restart from the host's own servicing stack can make DISM refuse to service an offline image.
    # Pending file renames are reported too, but most installers leave those behind, so they are not a warning.
    try {
        $Cbs = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $Wu = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $Renames = [bool](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        if ($Cbs -or $Wu) {
            $Why = @(if ($Cbs) { 'servicing stack' }; if ($Wu) { 'Windows Update' }) -join ' and '
            & $Add 'Restart pending' "yes, for the $Why. Restart before building if DISM fails to apply an update." 'Yellow'
        }
        elseif ($Renames) { & $Add 'Restart pending' 'no, though some files are waiting to be replaced at the next restart' }
        else { & $Add 'Restart pending' 'no' }
    }
    catch { & $Add 'Restart pending' 'unknown' }

    # A machine up for weeks has had longer for servicing and updates to queue work behind a restart.
    try {
        if (-not $Os -or -not $Os.LastBootUpTime) { throw 'no boot time' }
        $Boot = [datetime]$Os.LastBootUpTime
        & $Add 'Last restart' ('{0} at {1} ({2} ago)' -f (Get-FriendlyDate -Date $Boot), $Boot.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), (Format-Uptime -Uptime ((Get-Date) - $Boot)))
    }
    catch { & $Add 'Last restart' 'unknown' }

    # The working drive decides most of a build's speed (see docs\usage.md, Speeding Up a Build). The disk
    # behind it is read from the Storage WMI classes, because the Storage module's own commands take most of a
    # second just to load.
    try {
        $Letter = (Split-Path -Path $WorkRoot -Qualifier).TrimEnd(':')
        $Volume = [System.IO.DriveInfo]::new($Letter)
        $Drive = '{0}: {1}, {2} free of {3}' -f $Letter, $Volume.DriveFormat, (Format-Gigabytes $Volume.AvailableFreeSpace), (Format-Gigabytes $Volume.TotalSize)
        try {
            $Storage = 'root/Microsoft/Windows/Storage'
            $DiskNumber = (Get-CimInstance -Namespace $Storage -ClassName MSFT_Partition -Filter "DriveLetter='$Letter'" -ErrorAction Stop | Select-Object -First 1).DiskNumber
            $Physical = Get-CimInstance -Namespace $Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$DiskNumber" } | Select-Object -First 1
            if ($Physical) {
                $Bus = switch ([int]$Physical.BusType) { 1 { 'SCSI' } 3 { 'ATA' } 7 { 'USB' } 8 { 'RAID' } 9 { 'iSCSI' } 10 { 'SAS' } 11 { 'SATA' } 12 { 'SD card' } 14 { 'virtual' } 15 { 'virtual' } 16 { 'Storage Spaces' } 17 { 'NVMe' } default { '' } }
                $Media = switch ([int]$Physical.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { 'disk' } }
                $Drive += ", on $("$Bus $Media".Trim()) ($("$($Physical.FriendlyName)".Trim()))"
            }
        }
        catch { }
        & $Add 'Working drive' $Drive
    }
    catch { & $Add 'Working drive' 'unknown' }

    # BITS follows the user's proxy settings, and Invoke-WebRequest the same, while the WinHTTP proxy covers
    # services. Either one can be the reason a download fails.
    try {
        $Target = [uri]'https://catalog.update.microsoft.com'
        $UserProxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($Target)
        $Parts = @()
        if ($UserProxy -and $UserProxy.Host -ne $Target.Host) { $Parts += "user $($UserProxy.GetLeftPart([System.UriPartial]::Authority))" }
        $WinHttp = Get-WinHttpProxy -Settings (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -ErrorAction SilentlyContinue).WinHttpSettings
        if ($WinHttp) { $Parts += "WinHTTP $WinHttp" }
        & $Add 'Proxy' $(if ($Parts) { $Parts -join '; ' } else { 'none, direct connection' })
    }
    catch { & $Add 'Proxy' 'unknown' }

    # Explains a slow run. The model is the marketing name, never a serial number. The processor name comes
    # from the registry because Win32_Processor takes over a second, and that cost is also why only threads
    # are shown: the physical core count is only in Win32_Processor.
    try {
        $System = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $Machine = "$("$($System.Manufacturer)".Trim()) $("$($System.Model)".Trim())".Trim()
        if (Test-VirtualMachineModel -Manufacturer $System.Manufacturer -Model $System.Model) { $Machine += ' (virtual machine)' }
        $CpuName = "$((Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString)" -replace '\s+', ' '
        if (-not $CpuName.Trim()) { $CpuName = 'processor unknown' }
        $Memory = if ($Os) { '{0} memory, {1} free' -f (Format-Gigabytes ([double]$Os.TotalVisibleMemorySize * 1KB)), (Format-Gigabytes ([double]$Os.FreePhysicalMemory * 1KB)) } else { 'memory unknown' }
        & $Add 'Hardware' ('{0}; {1}, {2} threads; {3}' -f $Machine, $CpuName.Trim(), [Environment]::ProcessorCount, $Memory)
    }
    catch { & $Add 'Hardware' 'unknown' }

    return $Lines
}
#endregion
#endregion

