BeforeAll {
    $script:Tool = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\tools\Update-Changelog.ps1')).Path

    function Invoke-ChangelogTool {
        param([string[]]$Arguments)
        # The tool reports failures on stderr, which 5.1 would otherwise raise here as an error of its own.
        $ErrorActionPreference = 'Continue'
        $Output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Tool -RepositoryPath $script:Repo @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($Output -join "`n") }
    }

    function Set-Changelog {
        param([string]$Text)
        [System.IO.File]::WriteAllText($script:Changelog, $Text)
    }
}

Describe 'Update-Changelog' {
    BeforeEach {
        $script:Repo = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        $script:Changelog = Join-Path -Path $script:Repo -ChildPath 'CHANGELOG.md'
        [System.IO.File]::WriteAllText((Join-Path -Path $script:Repo -ChildPath 'Windows-ISO-Updater.ps1'), "`$ScriptVersion = '2026.11.01.2'`r`n")
    }

    It 'moves the Unreleased entries under the current version and leaves older sections alone' {
        Set-Changelog "# Changelog`n`n## [Unreleased]`n`n### Fixed`n`n- A bug`n`n## [2026.10.01.1] - 2026-10-01`n`n- Old`n"
        (Invoke-ChangelogTool).ExitCode | Should -Be 0
        $Text = [System.IO.File]::ReadAllText($script:Changelog)
        $Today = Get-Date -Format 'yyyy-MM-dd'
        $Text | Should -BeExactly "# Changelog`n`n## [Unreleased]`n`n## [2026.11.01.2] - $Today`n`n### Fixed`n`n- A bug`n`n## [2026.10.01.1] - 2026-10-01`n`n- Old`n"
    }

    It 'keeps CRLF line endings' {
        Set-Changelog "## [Unreleased]`r`n`r`n- A bug`r`n"
        (Invoke-ChangelogTool).ExitCode | Should -Be 0
        [System.IO.File]::ReadAllText($script:Changelog) | Should -Not -Match '(?<!\r)\n'
    }

    It 'refuses an empty Unreleased section, even with its subheadings' {
        Set-Changelog "## [Unreleased]`n`n### Fixed`n`n## [2026.10.01.1]`n`n- Old`n"
        $Result = Invoke-ChangelogTool
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'nothing to release'
    }

    It 'refuses a version that already has a section' {
        Set-Changelog "## [Unreleased]`n`n- New`n`n## [2026.11.01.2] - 2026-11-01`n`n- Old`n"
        $Before = [System.IO.File]::ReadAllText($script:Changelog)
        $Result = Invoke-ChangelogTool
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'already has a section'
        [System.IO.File]::ReadAllText($script:Changelog) | Should -BeExactly $Before
    }

    It 'writes only the current version''s notes, intact, without changing the changelog' {
        $LongLine = '- ' + ('long ' * 60).Trim()
        $Text = "## [Unreleased]`n`n- Later`n`n## [2026.11.01.2] - 2026-11-01`n`n### Fixed`n`n$LongLine`n`n## [2026.10.01.1]`n`n- Old`n"
        Set-Changelog $Text
        $Notes = Join-Path -Path $script:Repo -ChildPath 'notes.md'
        (Invoke-ChangelogTool -Arguments @('-WriteNotesTo', $Notes)).ExitCode | Should -Be 0
        [System.IO.File]::ReadAllText($Notes) | Should -BeExactly "### Fixed`n`n$LongLine`n"
        [System.IO.File]::ReadAllText($script:Changelog) | Should -BeExactly $Text
    }

    It 'fails when the script has moved on from the changelog' {
        Set-Changelog "## [Unreleased]`n`n## [2026.10.01.1] - 2026-10-01`n`n- Old`n"
        $Notes = Join-Path -Path $script:Repo -ChildPath 'notes.md'
        $Result = Invoke-ChangelogTool -Arguments @('-WriteNotesTo', $Notes)
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'no section for 2026\.11\.01\.2'
        Test-Path -LiteralPath $Notes | Should -BeFalse
    }

    It 'finds the repository on its own when no path is given' {
        $ErrorActionPreference = 'Continue'
        $Output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Tool -WriteNotesTo (Join-Path -Path $script:Repo -ChildPath 'notes.md') 2>&1 | ForEach-Object { "$_" }
        ($Output -join ' ') | Should -Not -Match 'Split-Path|empty string'
    }
}

Describe 'The changelog in this repository' {
    It 'has an Unreleased section for the next change to go in' {
        [System.IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath '..\CHANGELOG.md')) | Should -Match '(?m)^## \[Unreleased\]\s*$'
    }
}
