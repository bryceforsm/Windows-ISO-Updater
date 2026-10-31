#region Build tattoo
# The stamp lives on the build machine, which is no help to whoever is holding the ISO a year from now.
# The tattoo is the same story written onto the media itself, so the finished ISO explains itself.

# The parameters this run was started with, rebuilt as a command line. Only what was passed on the command
# line appears, so defaults stay out of it and the answer file's contents are never reproduced here.
function Get-ScriptCommandLine {
    $Arguments = New-Object System.Collections.Generic.List[string]
    $Arguments.Add((Split-Path -Leaf $script:ScriptPath))
    foreach ($Name in @($script:ScriptBoundParameters.Keys)) {
        # This text is written onto the media, so a password must never reach it.
        if ($Name -eq 'TaskPassword') { continue }
        $Value = $script:ScriptBoundParameters[$Name]
        if ($Value -is [switch]) {
            if ($Value.IsPresent) { $Arguments.Add("-$Name") }
            continue
        }
        $Arguments.Add("-$Name")
        foreach ($Item in @($Value)) { $Arguments.Add("`"$Item`"") }
    }
    return ($Arguments -join ' ')
}

# Renders the record as indented text. Deliberately generic, so a field added to the record shows up in
# the report without this having to know about it.
function Format-TattooText {
    param(
        $Value,
        [int]$Indent = 0
    )

    $Pad = ' ' * ($Indent * 2)
    $Lines = New-Object System.Collections.Generic.List[string]

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($Key in @($Value.Keys)) {
            $Item = $Value[$Key]
            if ($Item -is [System.Collections.IDictionary]) {
                $Lines.Add("$Pad${Key}:")
                $Lines.AddRange([string[]]@(Format-TattooText -Value $Item -Indent ($Indent + 1)))
                continue
            }
            if ($Item -is [System.Array] -or $Item -is [System.Collections.IList]) {
                $Entries = @($Item)
                if ($Entries.Count -eq 0) { $Lines.Add("$Pad${Key}: (none)"); continue }
                $Lines.Add("$Pad${Key}:")
                foreach ($Entry in $Entries) {
                    if ($Entry -is [System.Collections.IDictionary]) {
                        # Indented one level deeper than the bullet so the rest of the entry lines up under it.
                        $Block = @(Format-TattooText -Value $Entry -Indent ($Indent + 2))
                        if ($Block.Count -gt 0) { $Block[0] = "$Pad  - " + $Block[0].Substring(($Indent + 2) * 2) }
                        $Lines.AddRange([string[]]$Block)
                        $Lines.Add('')
                    }
                    else { $Lines.Add("$Pad  - $Entry") }
                }
                continue
            }
            $Text = if ($null -eq $Item -or "$Item" -eq '') { '(none)' } else { "$Item" }
            $Lines.Add("$Pad${Key}: $Text")
        }
    }
    else {
        $Lines.Add("$Pad$Value")
    }

    return $Lines.ToArray()
}

# Writes the record folder into the extracted media, just before oscdimg packages it. Failing to do so
# must never cost the build, so everything in here is best-effort.
function Write-BuildTattoo {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Info,
        [string]$FolderName = 'WISO-Build',
        [string]$ScriptSource
    )

    $Folder = Join-Path -Path $MediaRoot -ChildPath $FolderName
    try {
        if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null

        $Header = @(
            'Windows ISO Updater - build record'
            ('=' * 60)
            'This folder was added by Windows-ISO-Updater and is not part of the original'
            'Microsoft media. Windows Setup ignores it, and deleting it changes nothing.'
            ''
        )
        Set-Content -LiteralPath (Join-Path $Folder 'build-info.txt') -Value ($Header + @(Format-TattooText -Value $Info)) -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $Folder 'build-info.json') -Value (Format-Json -Json ($Info | ConvertTo-Json -Depth 8 -Compress)) -Encoding UTF8 -ErrorAction Stop

        if ($ScriptSource -and (Test-Path -LiteralPath $ScriptSource -PathType Leaf)) {
            Copy-Item -LiteralPath $ScriptSource -Destination (Join-Path $Folder (Split-Path -Leaf $ScriptSource)) -Force -ErrorAction Stop
        }

        $SizeKB = [math]::Round((Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum / 1KB, 1)
        Write-HostTimestamp "  Wrote \$FolderName to the media ($SizeKB KB): build-info.txt, build-info.json and a copy of the script." -ForegroundColor Green
        return $true
    }
    catch {
        Write-HostTimestamp "  Could not write the build record onto the media: $($_.Exception.Message). The ISO is unaffected." -ForegroundColor Yellow
        return $false
    }
}
#endregion

