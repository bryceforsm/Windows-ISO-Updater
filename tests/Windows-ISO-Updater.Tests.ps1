# The script mounts images and registers tasks when it runs, so it is never run or dot-sourced here. Only
# the function definitions are lifted out of its AST.
BeforeAll {
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath '..\Windows-ISO-Updater.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $ScriptFile).Path, [ref]$null, [ref]$null)
    $Names = @(
        'Format-ShortHash', 'Get-BuildParameterHash', 'Get-DefaultIsoName', 'Get-EditionRank', 'Get-EditionShortName',
        'Get-FileDownload', 'Get-PatchTuesdayStart', 'Get-ScheduledTaskArgumentString', 'Get-ScriptCommandLine', 'Get-TextSha256',
        'Resolve-EditionIndexes', 'Select-DefaultEditions', 'Test-FidoUrl', 'Test-IsHotpatchBaseline', 'Test-MicrosoftDownloadUrl',
        'Test-RebuildNeeded', 'Test-UpdatePackageFile'
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

Describe 'Get-PatchTuesdayStart' {
    It 'returns a time of day' {
        $Start = Get-PatchTuesdayStart
        $Start.TimeOfDay | Should -BeOfType [timespan]
        $Start.CrossesMidnight | Should -BeOfType [bool]
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

Describe 'Passwords stay out of recorded command lines' {
    BeforeEach {
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
