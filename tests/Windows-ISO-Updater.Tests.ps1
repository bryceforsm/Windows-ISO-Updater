# The script mounts images and registers tasks when it runs, so it is never run or dot-sourced here. Only
# the function definitions are lifted out of its AST.
BeforeAll {
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath '..\Windows-ISO-Updater.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $ScriptFile).Path, [ref]$null, [ref]$null)
    $Names = @(
        'ConvertFrom-HotpatchCalendar', 'Read-ConfigFile', 'Format-ShortHash', 'Get-BuildParameterHash', 'Get-DefaultIsoName', 'Get-EditionRank', 'Get-EditionShortName',
        'Get-DismErrorCode', 'Get-DismErrorMeaning', 'Get-DismLogError', 'Get-DismMessage', 'Save-DismLog',
        'Format-ByteProgress', 'Format-Duration', 'Format-ProgressLine', 'Format-WrappedText', 'Get-DismPercent', 'Get-FileDownload', 'Get-RobocopyPercent', 'Test-BitsUsable', 'Test-PathInList', 'Get-WinHttpProxy', 'Test-VirtualMachineModel', 'Format-Gigabytes', 'Format-Uptime', 'Get-HotpatchBaselineKb', 'Get-PatchTuesdayStart', 'Get-ScheduledTaskArgumentString', 'Get-ScriptCommandLine', 'Get-TextSha256',
        'Resolve-EditionIndexes', 'Search-UpdateCatalog', 'Select-DefaultEditions', 'Select-HotpatchBaselineEntry', 'Test-FidoUrl', 'Test-IsHotpatchBaseline',
        'Test-MicrosoftDownloadUrl', 'Test-RebuildNeeded', 'Test-SameWriteTime', 'Test-UpdatePackageFile'
    )
    foreach ($Name in $Names) {
        $Definition = $Ast.Find({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
            }, $true)
        if (-not $Definition) { throw "The script no longer defines $Name." }
        . ([scriptblock]::Create($Definition.Extent.Text))
    }
    function Write-HostTimestamp { param($Message, $ForegroundColor) }
    $script:FidoDefaultUrl = ($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'FidoUrl' }).DefaultValue.Value
    $script:FidoDefaultHash = ($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'FidoSha256' }).DefaultValue.Value

    function New-EditionList {
        param([string[]]$Name)
        $Index = 0
        foreach ($Item in $Name) {
            $Index++
            [pscustomobject]@{ ImageIndex = $Index; ImageName = $Item }
        }
    }
}

Describe 'Test-MicrosoftDownloadUrl' {
    It 'accepts <Url>' -TestCases @(
        @{ Url = 'https://download.microsoft.com/a.iso' }
        @{ Url = 'https://catalog.s.download.windowsupdate.com/c/a.msu' }
        @{ Url = 'https://software.download.prss.microsoft.com/a.iso' }
    ) {
        Test-MicrosoftDownloadUrl -Url $Url | Should -BeTrue
    }

    It 'rejects <Url>' -TestCases @(
        @{ Url = 'http://download.microsoft.com/a.iso' }
        @{ Url = 'https://microsoft.com.evil.example/a.iso' }
        @{ Url = 'https://evilmicrosoft.com/a.iso' }
        @{ Url = 'https://evil.example/microsoft.com/a.iso' }
        @{ Url = 'not a url' }
        @{ Url = '' }
    ) {
        Test-MicrosoftDownloadUrl -Url $Url | Should -BeFalse
    }
}

Describe 'Test-FidoUrl' {
    It 'accepts the default URL' {
        Test-FidoUrl -Url $script:FidoDefaultUrl | Should -BeTrue
    }

    It 'rejects <Url>' -TestCases @(
        @{ Url = 'http://github.com/pbatard/Fido/raw/master/Fido.ps1' }
        @{ Url = 'https://github.com.evil.example/pbatard/Fido/Fido.ps1' }
        @{ Url = 'https://github.com/evil/pbatard/Fido/Fido.ps1' }
        @{ Url = '' }
    ) {
        Test-FidoUrl -Url $Url | Should -BeFalse
    }
}

Describe 'The Fido pin' {
    It 'names one commit rather than a branch' {
        $script:FidoDefaultUrl | Should -Match '/raw/[0-9a-f]{40}/Fido\.ps1$'
    }

    It 'carries a SHA-256' {
        $script:FidoDefaultHash | Should -Match '^[0-9A-Fa-f]{64}$'
    }
}

Describe 'Test-IsHotpatchBaseline' {
    It 'returns <Expected> for <Title>' -TestCases @(
        @{ Title = '2026-01 Cumulative Update'; Expected = $true }
        @{ Title = '2026-04 Cumulative Update'; Expected = $true }
        @{ Title = '2026-07 Cumulative Update'; Expected = $true }
        @{ Title = '2026-10 Cumulative Update'; Expected = $true }
        @{ Title = '2026-09 Cumulative Update'; Expected = $false }
        @{ Title = '2026-11 Cumulative Update'; Expected = $false }
    ) {
        Test-IsHotpatchBaseline -Entry ([pscustomobject]@{ Title = $Title; LastUpdated = [datetime]'2026-11-10' }) | Should -Be $Expected
    }

    It 'falls back to the release date when the title has no month' {
        Test-IsHotpatchBaseline -Entry ([pscustomobject]@{ Title = 'Cumulative Update'; LastUpdated = [datetime]'2026-04-14' }) | Should -BeTrue
    }

    It 'is false with no month at all' {
        Test-IsHotpatchBaseline -Entry ([pscustomobject]@{ Title = 'Cumulative Update'; LastUpdated = $null }) | Should -BeFalse
    }
}

Describe 'The hotpatch calendar' {
    BeforeAll {
        # Row markup copied from Microsoft's page, including an unplanned baseline and months not yet shipped.
        function New-CalendarRow {
            param($Month, $Release, $Type, $Kb)
            $KbCell = if ($Kb) { "<a href=`"/en-us/help/$Kb`" data-linktype=`"absolute-path`">KB$Kb</a>" } else { '' }
            "<tr>`n<td>$Month</td>`n<td>$Release B</td>`n<td>$Type</td>`n<td>$KbCell</td>`n</tr>"
        }
        $Year = (Get-Date).Year
        $script:CurrentRelease = (Get-Date).ToString('yyyy.MM')
        $script:CalendarHtml = (
            '<table><thead><tr><th>Month</th><th>Update</th><th>Type</th><th>KB</th></tr></thead><tbody>',
            (New-CalendarRow 'January' "$($Year - 1).01" 'Baseline (Restart)' '5000001'),
            (New-CalendarRow 'August' "$($Year - 1).08" 'Hotpatch' '5000002'),
            (New-CalendarRow 'Now' $script:CurrentRelease 'Baseline (Restart)' '5000003'),
            (New-CalendarRow 'Next' "$($Year + 1).01" 'Baseline (Restart)' $null),
            (New-CalendarRow 'After' "$($Year + 1).02" 'Hotpatch' $null),
            '</tbody></table>'
        ) -join "`n"
    }

    BeforeEach {
        $script:HotpatchBaselineChecked = $false
        $script:HotpatchBaseline = $null
    }

    It 'takes the newest baseline that has a KB' {
        $Baseline = ConvertFrom-HotpatchCalendar -Html $script:CalendarHtml
        $Baseline.Kb | Should -Be '5000003'
        $Baseline.Release | Should -Be $script:CurrentRelease
    }

    It 'ignores a hotpatch month even when it is the newest row with a KB' {
        $Html = (New-CalendarRow 'A' '2026.07' 'Baseline (Restart)' '5000010') + (New-CalendarRow 'B' '2026.08' 'Hotpatch' '5000011')
        (ConvertFrom-HotpatchCalendar -Html $Html).Kb | Should -Be '5000010'
    }

    It 'honors a baseline outside the planned months' {
        $Html = (New-CalendarRow 'A' '2026.07' 'Baseline (Restart)' '5000010') + (New-CalendarRow 'B' '2026.09' 'Baseline (Restart)' '5000012')
        (ConvertFrom-HotpatchCalendar -Html $Html).Kb | Should -Be '5000012'
    }

    It 'finds nothing in a page without the table' {
        ConvertFrom-HotpatchCalendar -Html '<html><body>Moved</body></html>' | Should -BeNullOrEmpty
    }

    It 'returns nothing when the page cannot be fetched' {
        Mock Invoke-WebRequest { throw 'blocked' }
        Get-HotpatchBaselineKb | Should -BeNullOrEmpty
    }

    It 'distrusts a calendar that has stopped being updated' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = New-CalendarRow 'A' '2020.01' 'Baseline (Restart)' '5000010' } }
        Get-HotpatchBaselineKb | Should -BeNullOrEmpty
    }

    It 'only fetches the page once in a run' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:CalendarHtml } }
        (Get-HotpatchBaselineKb).Kb | Should -Be '5000003'
        (Get-HotpatchBaselineKb).Kb | Should -Be '5000003'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    Context 'Selecting the package' {
        BeforeAll {
            $script:OutOfBand = [pscustomobject]@{ Title = '2026-10 Cumulative Update (KB5134133)'; Classification = 'Updates'; LastUpdated = [datetime]'2026-10-26' }
            $script:October = [pscustomobject]@{ Title = '2026-10 Cumulative Update (KB5127648)'; Classification = 'Security Updates'; LastUpdated = [datetime]'2026-10-13' }
            $script:September = [pscustomobject]@{ Title = '2026-09 Cumulative Update (KB5124008)'; Classification = 'Security Updates'; LastUpdated = [datetime]'2026-09-08' }
        }

        It 'searches for the KB the calendar names' {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = New-CalendarRow 'Now' (Get-Date).ToString('yyyy.MM') 'Baseline (Restart)' '5124008' } }
            Mock Search-UpdateCatalog { @($script:September) }
            $Selected = Select-HotpatchBaselineEntry -Query 'Cumulative Update' -Candidates @($script:OutOfBand, $script:October)
            $Selected.Title | Should -Match 'KB5124008'
            Should -Invoke Search-UpdateCatalog -ParameterFilter { $Query -eq 'Cumulative Update KB5124008' }
        }

        It 'falls back to a planned-month security update, passing over out-of-band ones' {
            Mock Invoke-WebRequest { throw 'blocked' }
            $Selected = @(Select-HotpatchBaselineEntry -Query 'Cumulative Update' -Candidates @($script:OutOfBand, $script:October, $script:September))
            $Selected.Count | Should -Be 1
            $Selected[0].Title | Should -Match 'KB5127648'
        }

        It 'falls back when the catalog has no package for the KB' {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = New-CalendarRow 'Now' (Get-Date).ToString('yyyy.MM') 'Baseline (Restart)' '5999999' } }
            Mock Search-UpdateCatalog { @() }
            (Select-HotpatchBaselineEntry -Query 'Cumulative Update' -Candidates @($script:October)).Title | Should -Match 'KB5127648'
        }
    }
}

Describe 'Test-UpdatePackageFile' {
    BeforeAll {
        $script:Sample = Join-Path -Path $TestDrive -ChildPath 'sample.bin'
        Set-Content -LiteralPath $script:Sample -Value 'package contents'
        $script:SampleSha1 = (Get-FileHash -LiteralPath $script:Sample -Algorithm SHA1).Hash.ToLower()
    }

    It 'passes when the SHA-1 in the name matches' {
        $Path = Join-Path -Path $TestDrive -ChildPath "windows11.0-kb1-x64_$script:SampleSha1.msu"
        Copy-Item -LiteralPath $script:Sample -Destination $Path
        Test-UpdatePackageFile -Path $Path | Should -BeTrue
    }

    It 'fails when the SHA-1 in the name does not match' {
        $Path = Join-Path -Path $TestDrive -ChildPath ('windows11.0-kb2-x64_' + ('0' * 40) + '.cab')
        Copy-Item -LiteralPath $script:Sample -Destination $Path
        Test-UpdatePackageFile -Path $Path | Should -BeFalse
    }

    It 'passes an unsigned file whose name carries no hash' {
        $Path = Join-Path -Path $TestDrive -ChildPath 'plain.cab'
        Copy-Item -LiteralPath $script:Sample -Destination $Path
        Test-UpdatePackageFile -Path $Path | Should -BeTrue
    }
}

Describe 'Get-FileDownload' {
    BeforeEach {
        $script:Target = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid()).bin"
        Mock Start-BitsTransfer { throw 'BITS is unavailable' }
    }

    It 'gives the file its final name once complete' {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'done' }
        Get-FileDownload -Url 'https://example.test/a' -Destination $script:Target | Should -BeTrue
        Test-Path -LiteralPath $script:Target | Should -BeTrue
        Test-Path -LiteralPath "$script:Target.partial" | Should -BeFalse
    }

    It 'leaves nothing behind when a download dies partway' {
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value 'trunc'
            throw 'connection lost'
        }
        Get-FileDownload -Url 'https://example.test/a' -Destination $script:Target | Should -BeFalse
        Test-Path -LiteralPath $script:Target | Should -BeFalse
        Test-Path -LiteralPath "$script:Target.partial" | Should -BeFalse
    }
}

Describe 'Test-SameWriteTime' {
    BeforeAll {
        $script:WriteTime = [datetime]::new(2026, 10, 28, 17, 20, 29, [System.DateTimeKind]::Utc).AddTicks(801861)
    }

    It 'matches the time after a round trip through JSON' {
        # Windows PowerShell gives the string back and PowerShell 7 a DateTime, and both have to match.
        $Recorded = (@{ Time = $script:WriteTime.ToString('o') } | ConvertTo-Json | ConvertFrom-Json).Time
        Test-SameWriteTime -Recorded $Recorded -Actual $script:WriteTime | Should -BeTrue
    }

    It 'matches the recorded string and a DateTime' {
        Test-SameWriteTime -Recorded $script:WriteTime.ToString('o') -Actual $script:WriteTime | Should -BeTrue
        Test-SameWriteTime -Recorded $script:WriteTime -Actual $script:WriteTime | Should -BeTrue
    }

    It 'does not match a different time, even by a fraction of a second' {
        Test-SameWriteTime -Recorded $script:WriteTime.AddTicks(-801861).ToString('o') -Actual $script:WriteTime | Should -BeFalse
    }

    It 'does not match <Recorded>' -TestCases @(
        @{ Recorded = $null }
        @{ Recorded = '' }
        @{ Recorded = 'not a time' }
    ) {
        Test-SameWriteTime -Recorded $Recorded -Actual $script:WriteTime | Should -BeFalse
    }
}

Describe 'Reporting a DISM failure' {
    BeforeAll {
        # What DISM prints when a package fails. The line that explains it has neither "error" nor a code.
        $script:DismOutput = @(
            'Deployment Image Servicing and Management tool'
            'Version: 10.0.26100.1150'
            ''
            'Image Version: 10.0.22631.2428'
            ''
            'Processing 1 of 1 - Adding package Package_for_RollupFix~31bf3856ad364e35~amd64~~22621.6000.1.0'
            '[==========================100.0%==========================]'
            'An error occurred - Package_for_RollupFix Error: 0x800f0922'
            ''
            'Error: 0x800f0922'
            ''
            'The specified package is not applicable to this image.'
            ''
            'The DISM log file can be found at C:\Windows\Logs\DISM\dism.log'
        )
    }

    It 'takes the code from DISM''s Error line' {
        Get-DismErrorCode -Output $script:DismOutput -ExitCode 1 | Should -Be '0x800F0922'
    }

    It 'falls back to the exit code, written as hex' {
        Get-DismErrorCode -Output @('nothing useful') -ExitCode -2146498530 | Should -Be '0x800F081E'
    }

    It 'explains a known code whatever its case' {
        Get-DismErrorMeaning -Code '0x800f0922' | Should -Not -BeNullOrEmpty
        Get-DismErrorMeaning -Code '0x80070070' | Should -Match 'disk space'
    }

    It 'returns nothing for an unknown code' {
        Get-DismErrorMeaning -Code '0x12345678' | Should -BeNullOrEmpty
    }

    It 'keeps DISM''s explanation and drops the banner, progress bar and blank lines' {
        $Message = @(Get-DismMessage -Output $script:DismOutput)
        $Message | Should -Contain 'The specified package is not applicable to this image.'
        $Message | Should -Contain 'Error: 0x800f0922'
        $Message | Where-Object { $_ -match '^(Deployment Image|Version:|Image Version:|\[|The DISM log file)' } | Should -BeNullOrEmpty
        $Message | Where-Object { -not $_ } | Should -BeNullOrEmpty
    }

    It 'reads only the Error lines from a DISM log, without their timestamps' {
        $Log = Join-Path -Path $TestDrive -ChildPath 'dism.log'
        Set-Content -LiteralPath $Log -Value @(
            '2026-11-02 20:51:17, Info                  DISM   DISM Package Manager: Processing the package'
            '2026-11-02 20:51:18, Error                 CBS    Failed to install the package. [HRESULT = 0x800f0922]'
            '2026-11-02 20:51:18, Error                 DISM   DISM Package Manager: Failed while processing command add-package. hr:0x800f0922'
        )
        $Errors = @(Get-DismLogError -Path $Log)
        $Errors.Count | Should -Be 2
        $Errors[0] | Should -Be 'CBS Failed to install the package. [HRESULT = 0x800f0922]'
    }

    It 'returns nothing when the DISM log is missing' {
        @(Get-DismLogError -Path (Join-Path -Path $TestDrive -ChildPath 'missing.log')).Count | Should -Be 0
    }

    It 'saves a failed package''s log under the KB and the image' {
        $LogDir = Join-Path -Path $TestDrive -ChildPath 'Logs'
        $LogStamp = '2026-11-02_20-50-53'
        $Source = Join-Path -Path $TestDrive -ChildPath 'pkg.log'
        Set-Content -LiteralPath $Source -Value 'log'
        $Package = 'windows11.0-kb5134130-x64_0e59d2f988a5422dfb489e97faed3b3835fc7568.msu'
        $First = Save-DismLog -Path $Source -Package $Package -ImageLabel 'install.wim index 1 (Windows 11 Pro)'
        Split-Path -Leaf $First | Should -Be 'KB5134130_install.wim_index_1_(Windows_11_Pro).log'
        Split-Path -Leaf (Split-Path -Parent $First) | Should -Be 'Windows-ISO-Updater_2026-11-02_20-50-53_DISM'
        $Second = Save-DismLog -Path $Source -Package $Package -ImageLabel 'install.wim index 1 (Windows 11 Pro)'
        Split-Path -Leaf $Second | Should -Be 'KB5134130_install.wim_index_1_(Windows_11_Pro)_2.log'
    }
}

Describe 'Get-PatchTuesdayStart' {
    It 'returns a time of day' {
        $Start = Get-PatchTuesdayStart
        $Start.TimeOfDay | Should -BeOfType [timespan]
        $Start.CrossesMidnight | Should -BeOfType [bool]
    }
}

Describe 'Get-DismPercent' {
    It 'reads <Expected> from <Line>' -TestCases @(
        @{ Line = '[=                          2.0%                           ]'; Expected = 2 }
        @{ Line = '[==========================100.0%==========================]'; Expected = 100 }
        @{ Line = '[===========                47,5%                          ]'; Expected = 47 }
        @{ Line = '  [====  10%  ]  '; Expected = 10 }
    ) {
        Get-DismPercent -Line $Line | Should -Be $Expected
    }

    It 'ignores <Line>' -TestCases @(
        @{ Line = 'The operation completed successfully.' }
        @{ Line = 'Image Version: 10.0.26100.1' }
        @{ Line = 'Free space is 15% of the disk [warning]' }
        @{ Line = '' }
    ) {
        Get-DismPercent -Line $Line | Should -BeNullOrEmpty
    }
}

Describe 'Get-WinHttpProxy' {
    BeforeAll {
        # The layout "netsh winhttp set proxy" writes: version, counter, flags, then a length-prefixed proxy and bypass list.
        function New-WinHttpSettings {
            param([string]$Proxy, [string]$Bypass = '')
            $Bytes = [System.Collections.Generic.List[byte]]::new()
            $Bytes.AddRange([System.BitConverter]::GetBytes([int]0x28))
            $Bytes.AddRange([System.BitConverter]::GetBytes([int]0))
            $Bytes.AddRange([System.BitConverter]::GetBytes([int]$(if ($Proxy) { 3 } else { 1 })))
            $Bytes.AddRange([System.BitConverter]::GetBytes([int]$Proxy.Length))
            $Bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($Proxy))
            $Bytes.AddRange([System.BitConverter]::GetBytes([int]$Bypass.Length))
            $Bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($Bypass))
            return , $Bytes.ToArray()
        }
    }

    It 'reads the proxy server' {
        Get-WinHttpProxy -Settings (New-WinHttpSettings -Proxy 'proxy.example.test:8080' -Bypass '<local>') | Should -Be 'proxy.example.test:8080'
    }

    It 'returns nothing for a direct connection' {
        Get-WinHttpProxy -Settings (New-WinHttpSettings -Proxy '') | Should -BeNullOrEmpty
    }

    It 'returns nothing for a missing or damaged value' {
        Get-WinHttpProxy -Settings $null | Should -BeNullOrEmpty
        Get-WinHttpProxy -Settings ([byte[]](1, 2, 3)) | Should -BeNullOrEmpty
        $Damaged = New-WinHttpSettings -Proxy 'proxy:8080'
        Get-WinHttpProxy -Settings $Damaged[0..17] | Should -BeNullOrEmpty
    }
}

Describe 'Test-VirtualMachineModel' {
    It 'recognises <Manufacturer> <Model>' -TestCases @(
        @{ Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine' }
        @{ Manufacturer = 'VMware, Inc.'; Model = 'VMware20,1' }
        @{ Manufacturer = 'innotek GmbH'; Model = 'VirtualBox' }
        @{ Manufacturer = 'QEMU'; Model = 'Standard PC (Q35 + ICH9, 2009)' }
        @{ Manufacturer = 'Amazon EC2'; Model = 't3.large' }
    ) {
        Test-VirtualMachineModel -Manufacturer $Manufacturer -Model $Model | Should -BeTrue
    }

    It 'leaves <Manufacturer> <Model> alone' -TestCases @(
        @{ Manufacturer = 'Dell Inc.'; Model = 'OptiPlex 7090' }
        @{ Manufacturer = 'Microsoft Corporation'; Model = 'Surface Laptop 5' }
        @{ Manufacturer = 'ASUS'; Model = 'System Product Name' }
    ) {
        Test-VirtualMachineModel -Manufacturer $Manufacturer -Model $Model | Should -BeFalse
    }
}

Describe 'Format-Uptime' {
    It 'shows <Expected>' -TestCases @(
        @{ Uptime = [TimeSpan]::new(3, 4, 30, 0); Expected = '3 days 4 hours' }
        @{ Uptime = [TimeSpan]::new(1, 1, 0, 0); Expected = '1 day 1 hour' }
        @{ Uptime = [TimeSpan]::new(0, 5, 12, 0); Expected = '5 hours 12 minutes' }
        @{ Uptime = [TimeSpan]::new(0, 1, 1, 0); Expected = '1 hour 1 minute' }
        @{ Uptime = [TimeSpan]::new(0, 0, 12, 40); Expected = '12 minutes' }
        @{ Uptime = [TimeSpan]::new(0, 0, 0, 30); Expected = '0 minutes' }
    ) {
        Format-Uptime -Uptime $Uptime | Should -Be $Expected
    }
}

Describe 'Format-Gigabytes' {
    It 'shows <Expected> for <Bytes> bytes' -TestCases @(
        @{ Bytes = 1.5GB; Expected = '1.5 GB' }
        @{ Bytes = 63.7GB; Expected = '63.7 GB' }
        @{ Bytes = 476.9GB; Expected = '477 GB' }
    ) {
        Format-Gigabytes -Bytes $Bytes | Should -Be $Expected
    }
}

Describe 'Test-PathInList' {
    It 'finds the working folder whatever its case or trailing backslash' {
        Test-PathInList -List @('D:\Other', 'c:\wiso-work\') -Path 'C:\WISO-Work' | Should -BeTrue
    }

    It 'does not take a folder whose name only starts the same' {
        Test-PathInList -List @('C:\WISO-Work2', 'C:\WISO-Work\Mount') -Path 'C:\WISO-Work' | Should -BeFalse
    }

    It 'copes with an empty exclusion list' {
        Test-PathInList -List $null -Path 'C:\WISO-Work' | Should -BeFalse
    }
}

Describe 'Test-BitsUsable' {
    It 'allows a signed-in user' {
        Test-BitsUsable -UserSid 'S-1-5-21-1-2-3-1001' -GroupSids @('S-1-1-0', 'S-1-5-4', 'S-1-5-11') | Should -BeTrue
    }

    It 'allows <Name>, whose jobs run without anyone signed in' -TestCases @(
        @{ Name = 'SYSTEM'; Sid = 'S-1-5-18' }
        @{ Name = 'LOCAL SERVICE'; Sid = 'S-1-5-19' }
        @{ Name = 'NETWORK SERVICE'; Sid = 'S-1-5-20' }
    ) {
        Test-BitsUsable -UserSid $Sid -GroupSids @('S-1-5-6') | Should -BeTrue
    }

    It 'refuses a scheduled task running as a user who is not signed in' {
        Test-BitsUsable -UserSid 'S-1-5-21-1-2-3-1001' -GroupSids @('S-1-1-0', 'S-1-5-3', 'S-1-5-11') | Should -BeFalse
    }
}

Describe 'Get-RobocopyPercent' {
    It 'reads <Expected> from <Line>' -TestCases @(
        @{ Line = '  0.1%'; Expected = 0 }
        @{ Line = ' 47.5%'; Expected = 47 }
        @{ Line = ' 12,5%'; Expected = 12 }
        @{ Line = '100%'; Expected = 100 }
    ) {
        Get-RobocopyPercent -Line $Line | Should -Be $Expected
    }

    It 'ignores <Line>' -TestCases @(
        @{ Line = "`t    New File  `t`t 800.0 m`tC:\src\big.bin" }
        @{ Line = '[====   10.0%   ]' }
        @{ Line = '' }
    ) {
        Get-RobocopyPercent -Line $Line | Should -BeNullOrEmpty
    }
}

Describe 'Format-ProgressLine' {
    It 'fills the bar in proportion to the percentage' {
        $Line = Format-ProgressLine -Percent 50 -Detail '2m 13s' -Width 120 -Indent 4
        $Line | Should -Be ('    [' + ('#' * 20) + ('-' * 20) + ']  50%  2m 13s')
    }

    It 'never reaches the last column, whatever the width' {
        foreach ($Width in 20, 30, 40, 60, 80, 200) {
            foreach ($Percent in 0, 37, 100) {
                $Line = Format-ProgressLine -Percent $Percent -Detail '6.84 of 6.84 GB, 112 MB/s' -Width $Width -Indent 28
                $Line.Length | Should -BeLessThan $Width
            }
        }
    }

    It 'shows the detail alone when there is no percentage' {
        Format-ProgressLine -Percent -1 -Detail 'Writing the image: 1.24 GB so far (2m 10s)' -Width 120 -Indent 4 |
            Should -Be '    Writing the image: 1.24 GB so far (2m 10s)'
    }

    It 'keeps a detail-only line out of the last column' {
        $Line = Format-ProgressLine -Percent -1 -Detail ('x' * 60) -Width 50 -Indent 26
        $Line.Length | Should -BeLessThan 50
    }

    It 'drops the indent on a narrow console rather than squeezing the bar to nothing' {
        $Line = Format-ProgressLine -Percent 10 -Detail '5.0s' -Width 40 -Indent 28
        $Line | Should -Match '^\[[#-]{10,}\]'
    }
}

Describe 'Format-ByteProgress' {
    It 'shows gigabytes for a large transfer' {
        Format-ByteProgress -Done 1.5GB -Total 6GB -Elapsed ([TimeSpan]::FromSeconds(30)) | Should -Be '1.50 of 6.00 GB, 51 MB/s'
    }

    It 'shows megabytes for a small transfer' {
        Format-ByteProgress -Done 100MB -Total 400MB -Elapsed ([TimeSpan]::FromSeconds(10)) | Should -Be '100 of 400 MB, 10 MB/s'
    }

    It 'leaves the speed out until a second has passed' {
        Format-ByteProgress -Done 1MB -Total 400MB -Elapsed ([TimeSpan]::FromMilliseconds(200)) | Should -Be '1 of 400 MB'
    }
}

Describe 'Format-WrappedText' {
    It 'leaves a line that fits alone' {
        $Lines = @(Format-WrappedText -Text 'short line' -Width 40 -Indent 4)
        $Lines | Should -Be @('short line')
    }

    It 'does not wrap when the width is unknown' {
        $Text = 'x ' * 200
        @(Format-WrappedText -Text $Text -Width 0) | Should -Be @($Text)
    }

    It 'breaks between words and indents the continuation' {
        $Lines = @(Format-WrappedText -Text '[stamp] one two three four five' -Width 20 -Indent 8)
        $Lines | Should -Be @('[stamp] one two', '        three four', '        five')
    }

    It 'breaks a path after a separator' {
        $Lines = @(Format-WrappedText -Text 'saved to C:\Work\Output\image.iso' -Width 22 -Indent 3)
        $Lines[0] | Should -Be 'saved to'
        $Lines[1] | Should -Be '   C:\Work\Output\'
        $Lines[2] | Should -Be '   image.iso'
    }

    It 'cuts a word only when it is wider than the console' {
        $Lines = @(Format-WrappedText -Text ('a' * 25) -Width 10)
        $Lines | Should -Be @(('a' * 10), ('a' * 10), ('a' * 5))
    }

    It 'drops an indent that would leave too little room' {
        $Lines = @(Format-WrappedText -Text '[a long timestamp] word word word' -Width 24 -Indent 19)
        $Lines | Should -Be @('[a long timestamp] word', 'word word')
    }

    It 'never writes a line wider than the console, and loses no words' {
        $Text = '[10/14/2026|09:13:38] Keeping only the Enterprise, Pro and Home editions to speed up the build: C:\WISO-Work\Output\Win11_25H2_Pro_x64_en-US_26200.7019.iso'
        foreach ($Width in 30, 47, 80, 100) {
            $Lines = @(Format-WrappedText -Text $Text -Width $Width -Indent 22)
            $Lines | ForEach-Object { $_.Length | Should -BeLessOrEqual $Width }
            (($Lines | ForEach-Object { $_.Trim() }) -join '') -replace '\s', '' | Should -Be ($Text -replace '\s', '')
        }
    }
}

Describe 'Select-DefaultEditions' {
    It 'keeps Enterprise, Pro and Home, highest tier first' {
        $Images = New-EditionList 'Windows 11 Home', 'Windows 11 Home N', 'Windows 11 Home Single Language', 'Windows 11 Education', 'Windows 11 Pro', 'Windows 11 Pro N', 'Windows 11 Pro Education', 'Windows 11 Pro for Workstations', 'Windows 11 Enterprise'
        Select-DefaultEditions -Images $Images | Should -Be @(9, 5, 1)
    }

    It 'keeps only the tiers the media carries' {
        Select-DefaultEditions -Images (New-EditionList 'Windows 11 Education', 'Windows 11 Pro') | Should -Be @(2)
    }

    It 'still keeps something when no tier matches' {
        Select-DefaultEditions -Images (New-EditionList 'Windows 11 Education') | Should -Be @(1)
    }

    It 'prefers Standard with the Desktop Experience on Server media' {
        $Images = New-EditionList 'Windows Server 2025 Standard', 'Windows Server 2025 Standard (Desktop Experience)', 'Windows Server 2025 Datacenter', 'Windows Server 2025 Datacenter (Desktop Experience)'
        Select-DefaultEditions -Images $Images -ServerMedia | Should -Be @(2)
    }
}

Describe 'Resolve-EditionIndexes' {
    BeforeAll {
        $script:Images = New-EditionList 'Windows 11 Home', 'Windows 11 Pro', 'Windows 11 Pro N'
    }

    It 'splits a comma-separated token' {
        Resolve-EditionIndexes -Images $script:Images -Tokens '1,3' | Should -Be @(1, 3)
    }

    It 'prefers an exact name over a partial match' {
        Resolve-EditionIndexes -Images $script:Images -Tokens 'Windows 11 Pro' | Should -Be @(2)
    }

    It 'reports what it could not match' {
        $Unmatched = $null
        Resolve-EditionIndexes -Images $script:Images -Tokens 'Home,Ultimate' -Unmatched ([ref]$Unmatched) | Should -Be @(1)
        @($Unmatched) | Should -Be @('Ultimate')
    }
}

Describe 'Get-DefaultIsoName' {
    It 'describes the media' {
        $script:EffectiveServer = $false
        $Name = Get-DefaultIsoName -Images (New-EditionList 'Windows 11 Pro') -Indexes 1 -BuildString '10.0.26100.4061' -Architecture 'x64' -Locale 'en-US'
        $Name | Should -Match '^Win11_Pro_x64_enUS_26100\.4061_\d{8}-\d{4}\.iso$'
    }
}

Describe 'Test-RebuildNeeded' {
    BeforeEach {
        $script:Parameters = [ordered]@{ SkipDotNet = 'False' }
        $Iso = Join-Path -Path $TestDrive -ChildPath 'out.iso'
        Set-Content -LiteralPath $Iso -Value 'iso'
        $script:Stamp = [pscustomobject]@{
            Source         = [pscustomobject]@{ Sha256 = 'AAAA' }
            ParametersHash = Get-BuildParameterHash -Set $script:Parameters
            Parameters     = [pscustomobject]@{ SkipDotNet = 'False' }
            Updates        = [pscustomobject]@{ Catalog = @('LCU=KB1') }
            Output         = [pscustomobject]@{ Path = $Iso }
        }
    }

    It 'skips when nothing changed' {
        (Test-RebuildNeeded -Stamp $script:Stamp -SourceHash 'AAAA' -ParameterSet $script:Parameters -ExpectedUpdates 'LCU=KB1').Rebuild | Should -BeFalse
    }

    It 'rebuilds with no stamp' {
        (Test-RebuildNeeded -Stamp $null -SourceHash 'AAAA' -ParameterSet $script:Parameters -ExpectedUpdates 'LCU=KB1').Rebuild | Should -BeTrue
    }

    It 'rebuilds when the source ISO changed' {
        (Test-RebuildNeeded -Stamp $script:Stamp -SourceHash 'BBBB' -ParameterSet $script:Parameters -ExpectedUpdates 'LCU=KB1').Rebuild | Should -BeTrue
    }

    It 'rebuilds when a build parameter changed' {
        $Changed = [ordered]@{ SkipDotNet = 'True' }
        (Test-RebuildNeeded -Stamp $script:Stamp -SourceHash 'AAAA' -ParameterSet $Changed -ExpectedUpdates 'LCU=KB1').Rebuild | Should -BeTrue
    }

    It 'rebuilds when a newer update is available' {
        (Test-RebuildNeeded -Stamp $script:Stamp -SourceHash 'AAAA' -ParameterSet $script:Parameters -ExpectedUpdates 'LCU=KB2').Rebuild | Should -BeTrue
    }

    It 'rebuilds when the last ISO is gone' {
        Remove-Item -LiteralPath $script:Stamp.Output.Path
        (Test-RebuildNeeded -Stamp $script:Stamp -SourceHash 'AAAA' -ParameterSet $script:Parameters -ExpectedUpdates 'LCU=KB1').Rebuild | Should -BeTrue
    }

    It 'does not rebuild just because the catalog is unreachable' {
        $Result = Test-RebuildNeeded -Stamp $script:Stamp -SourceHash 'AAAA' -ParameterSet $script:Parameters -ExpectedUpdates $null
        $Result.Rebuild | Should -BeFalse
        $Result.Reasons -join ' ' | Should -Match 'could not be reached'
    }
}

Describe 'Read-ConfigFile' {
    BeforeAll {
        # Reads the real parameter block. Get-Command only parses the script and does not run it.
        $script:RealParameters = (Get-Command -Name (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\Windows-ISO-Updater.ps1')).Path).Parameters
        $script:ProfileFile = Join-Path -Path $TestDrive -ChildPath 'profile.json'
        function Read-TestProfile {
            param([string]$Json)
            [System.IO.File]::WriteAllText($script:ProfileFile, $Json)
            Read-ConfigFile -Path $script:ProfileFile -Parameters $script:RealParameters -PathParameter @('IsoPath', 'WorkPath')
        }
    }

    It 'converts each kind of value to its parameter type' {
        $Values = Read-TestProfile '{ "Language": "English", "KeepIsoCount": 5, "AutoClean": true, "SkipDotNet": false, "KeepEditions": ["Pro", "Home"] }'
        $Values['Language'] | Should -Be 'English'
        $Values['KeepIsoCount'] | Should -Be 5
        $Values['AutoClean'].IsPresent | Should -BeTrue
        $Values['SkipDotNet'].IsPresent | Should -BeFalse
        $Values['KeepEditions'] | Should -Be @('Pro', 'Home')
    }

    It 'accepts a single string for a list parameter' {
        $Values = Read-TestProfile '{ "KeepEditions": "Pro" }'
        , $Values['KeepEditions'] | Should -BeOfType [string[]]
    }

    It 'uses the spelling of the real parameter name' {
        @((Read-TestProfile '{ "autoclean": true }').Keys) | Should -Be @('AutoClean')
    }

    It 'makes a relative path relative to the profile' {
        (Read-TestProfile '{ "IsoPath": "isos\\a.iso" }')['IsoPath'] | Should -Be (Join-Path -Path $TestDrive -ChildPath 'isos\a.iso')
    }

    It 'leaves an absolute path alone' {
        (Read-TestProfile '{ "WorkPath": "D:\\WISO" }')['WorkPath'] | Should -Be 'D:\WISO'
    }

    It 'ignores comments, $schema and nulls' {
        (Read-TestProfile '{ "_comment": "x", "$schema": "y", "Language": null }').Count | Should -Be 0
    }

    It 'refuses <Name> because it belongs on the command line' -TestCases @(
        @{ Name = 'ConfigPath' }, @{ Name = 'TaskPassword' }, @{ Name = 'PromptTaskPassword' }, @{ Name = 'TaskUsername' }, @{ Name = 'TaskName' }
        @{ Name = 'RegisterScheduledTask' }, @{ Name = 'UnregisterScheduledTask' }, @{ Name = 'Schedule' }, @{ Name = 'ScheduleTime' }, @{ Name = 'ScheduleDay' }
        @{ Name = 'Scheduled' }, @{ Name = 'CheckOnly' }, @{ Name = 'ListEditions' }, @{ Name = 'Force' }
    ) {
        $script:RealParameters.ContainsKey($Name) | Should -BeTrue
        { Read-TestProfile "{ `"$Name`": `"x`" }" } | Should -Throw '*cannot be set in a profile*'
    }

    It 'refuses <Json>' -TestCases @(
        @{ Json = '{ "IsoPth": "a.iso" }'; Message = '*not a parameter*' }
        @{ Json = '{ "Verbose": true }'; Message = '*not a parameter*' }
        @{ Json = '{ "AutoClean": "yes" }'; Message = '*true or false*' }
        @{ Json = '{ "Language": ["a", "b"] }'; Message = '*single value*' }
        @{ Json = '{ "Language": true }'; Message = '*single value*' }
        @{ Json = '{ "KeepEditions": [true] }'; Message = '*list of strings*' }
        @{ Json = '["IsoPath"]'; Message = '*JSON object*' }
        @{ Json = '{ not json'; Message = '*not valid JSON*' }
        @{ Json = ''; Message = '*JSON object*' }
    ) {
        { Read-TestProfile $Json } | Should -Throw $Message
    }

    It 'refuses a missing file' {
        { Read-ConfigFile -Path (Join-Path -Path $TestDrive -ChildPath 'missing.json') -Parameters $script:RealParameters } | Should -Throw '*was not found*'
    }

    It 'loads the example profile' {
        $Example = Join-Path -Path $PSScriptRoot -ChildPath '..\Examples\profile-win11-monthly.json'
        $Values = Read-ConfigFile -Path (Resolve-Path -LiteralPath $Example).Path -Parameters $script:RealParameters -PathParameter @('IsoPath')
        $Values['KeepEditions'].Count | Should -Be 2
    }
}

Describe 'Recorded command lines with a profile' {
    It 'writes out what the profile set, leaving out switches set to false' {
        $script:ScriptPath = 'C:\Tools\Windows-ISO-Updater.ps1'
        $script:ScriptBoundParameters = @{ ConfigPath = 'D:\p.json' }
        $script:ProfileValues = [ordered]@{ Language = 'English'; AutoClean = [switch]$true; SkipDotNet = [switch]$false }
        $Line = Get-ScriptCommandLine
        $Line | Should -Match '-ConfigPath "D:\\p\.json"'
        $Line | Should -Match '-Language "English"'
        $Line | Should -Match '-AutoClean'
        $Line | Should -Not -Match 'SkipDotNet'
    }

    It 'keeps only -ConfigPath in the scheduled task, so later profile edits apply' {
        $script:ScriptPath = 'C:\Tools\Windows-ISO-Updater.ps1'
        $script:ScriptBoundParameters = @{ ConfigPath = 'D:\p.json' }
        $script:ProfileValues = [ordered]@{ Language = 'English' }
        $Line = Get-ScheduledTaskArgumentString
        $Line | Should -Match "-ConfigPath 'D:\\p\.json'"
        $Line | Should -Not -Match 'Language'
    }
}

Describe 'Passwords stay out of recorded command lines' {
    BeforeEach {
        $script:ProfileValues = [ordered]@{}
        $script:ScriptPath = 'C:\Tools\Windows-ISO-Updater.ps1'
        $script:ScriptBoundParameters = @{
            IsoPath            = 'D:\a.iso'
            TaskUsername       = 'DOMAIN\Svc'
            TaskPassword       = 'hunter2'
            PromptTaskPassword = [switch]$true
        }
    }

    It 'leaves the password out of the build record command line' {
        $Line = Get-ScriptCommandLine
        $Line | Should -Not -Match 'hunter2'
        $Line | Should -Match 'D:\\a\.iso'
    }

    It 'leaves the password and its prompt out of the scheduled task' {
        $Line = Get-ScheduledTaskArgumentString
        $Line | Should -Not -Match 'hunter2'
        $Line | Should -Not -Match 'PromptTaskPassword'
        $Line | Should -Match '-Scheduled'
    }
}
