BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Source = 'C:\Users\you\Projects'
    $script:When = [datetime]'2026-09-23T19:00:00'
    $script:Accented = 'relat' + [char]0x00F3 + 'rio-' + [char]0x00E7 + [char]0x00E3 + 'o.md'
}

Describe 'ConvertTo-ChangeAction' {
    It 'maps <Modifier> to <Action>' -ForEach @(
        @{ Modifier = '+'; Action = 'added' }
        @{ Modifier = '-'; Action = 'removed' }
        @{ Modifier = 'M'; Action = 'modified' }
        @{ Modifier = 'U'; Action = 'metadata' }
        @{ Modifier = 'T'; Action = 'type-changed' }
        @{ Modifier = '?'; Action = 'possible-corruption' }
        @{ Modifier = 'MU'; Action = 'modified+metadata' }
        @{ Modifier = 'X'; Action = 'unknown' }
    ) {
        ConvertTo-ChangeAction -Modifier $Modifier | Should -Be $Action
    }
}

Describe 'Get-RelativeSnapshotPath' {
    It 'strips the source folder in the form restic writes it' {
        Get-RelativeSnapshotPath -SnapshotPath '/C/Users/you/Projects/app/src/main.ts' -SourcePath $script:Source | Should -Be 'app/src/main.ts'
    }
    It 'accepts the other spellings and ignores case' {
        Get-RelativeSnapshotPath -SnapshotPath '/C:/Users/you/Projects/a.txt' -SourcePath $script:Source | Should -Be 'a.txt'
        Get-RelativeSnapshotPath -SnapshotPath 'c:/users/YOU/projects/a.txt' -SourcePath $script:Source | Should -Be 'a.txt'
    }
    It 'names the source folder itself (root)' {
        Get-RelativeSnapshotPath -SnapshotPath '/C/Users/you/Projects/' -SourcePath $script:Source | Should -Be '(root)'
    }
    It 'returns nothing for the parents of the source and for a sibling with a longer name' {
        Get-RelativeSnapshotPath -SnapshotPath '/C/Users/you/' -SourcePath $script:Source | Should -BeNullOrEmpty
        Get-RelativeSnapshotPath -SnapshotPath '/C/Users/you/Projects2/a.txt' -SourcePath $script:Source | Should -BeNullOrEmpty
    }
    It 'works when the source is a whole drive' {
        Get-RelativeSnapshotPath -SnapshotPath '/D/work/a.txt' -SourcePath 'D:\' | Should -Be 'work/a.txt'
    }
}

Describe 'ConvertFrom-ResticDiff' {
    BeforeAll {
        $lines = @(
            '{"message_type":"change","path":"/C/Users/you/Projects/app/","modifier":"U"}'
            '{"message_type":"change","path":"/C/Users/you/Projects/app/new.ts","modifier":"+"}'
            '{"message_type":"change","path":"/C/Users/you/Projects/app/old.ts","modifier":"-"}'
            '{"message_type":"change","path":"/C/Users/you/Projects/docs/' + $script:Accented + '","modifier":"M"}'
            '{"message_type":"change","path":"/C/Users/you/Projects/assets/","modifier":"+"}'
            '{"message_type":"change","path":"/C/Users/you/","modifier":"U"}'
            ''
            '{"message_type":"statistics","added":{"bytes":2048},"removed":{"bytes":1024}}'
        )
        $script:Parsed = ConvertFrom-ResticDiff -Lines $lines -SourcePath $script:Source -PreviousId 'aaaa1111' -CurrentId 'bbbb2222' -BackupTime $script:When
    }

    It 'drops metadata-only folder changes and paths outside the source' {
        @($script:Parsed.Changes | ForEach-Object { $_.path }) -join '|' | Should -Be ('app/new.ts|app/old.ts|docs/' + $script:Accented + '|assets/')
    }
    It 'keeps accents, area, extension and action per change' {
        $doc = $script:Parsed.Changes | Where-Object { $_.path -like 'docs/*' }
        $doc.path | Should -BeExactly ('docs/' + $script:Accented)
        $doc.area | Should -Be 'docs'
        $doc.extension | Should -Be '.md'
        $doc.action | Should -Be 'modified'
        $doc.previous_snapshot | Should -Be 'aaaa1111'
    }
    It 'gives folders no extension' {
        ($script:Parsed.Changes | Where-Object { $_.path -eq 'assets/' }).extension | Should -Be ''
    }
    It 'keeps the statistics line' {
        $script:Parsed.Statistics.added.bytes | Should -Be 2048
    }
}

Describe 'Write-ChangeCsv' {
    It 'writes UTF-8 with BOM so a spreadsheet keeps the accents' {
        $path = Join-Path $TestDrive 'a.csv'
        $change = [pscustomobject][ordered]@{ backup_time = 't'; previous_snapshot = 'p'; current_snapshot = 'c'; modifier = 'M'; action = 'modified'; path = 'docs/' + $script:Accented; extension = '.md'; area = 'docs' }
        Write-ChangeCsv -Changes @($change) -Path $path
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0..2] -join ',' | Should -Be '239,187,191'
        [IO.File]::ReadAllText($path) | Should -BeLike ('*docs/' + $script:Accented + '*')
    }
    It 'neutralizes a file name that a spreadsheet would run as a formula' {
        $path = Join-Path $TestDrive 'b.csv'
        $change = [pscustomobject][ordered]@{ backup_time = 't'; previous_snapshot = 'p'; current_snapshot = 'c'; modifier = '+'; action = 'added'; path = '=HYPERLINK("http://x")'; extension = ''; area = '=HYPERLINK("http://x")' }
        Write-ChangeCsv -Changes @($change) -Path $path
        $row = @(Import-Csv -LiteralPath $path)[0]
        $row.path | Should -Be "'=HYPERLINK(`"http://x`")"
        $row.area | Should -Be "'=HYPERLINK(`"http://x`")"
    }
    It 'writes only the header when nothing changed' {
        $path = Join-Path $TestDrive 'c.csv'
        Write-ChangeCsv -Changes @() -Path $path
        @(Get-Content -LiteralPath $path).Count | Should -Be 1
        (Get-Content -LiteralPath $path -TotalCount 1) | Should -Be '"backup_time","previous_snapshot","current_snapshot","modifier","action","path","extension","area"'
    }
}

Describe 'New-ChangeMarkdown' {
    It 'counts by action and lists the first changes' {
        $changes = @(1..3 | ForEach-Object { [pscustomobject]@{ action = 'added'; area = 'app'; extension = '.ts'; path = "app/$_.ts" } }) + @([pscustomobject]@{ action = 'removed'; area = 'docs'; extension = ''; path = 'docs/' })
        $md = New-ChangeMarkdown -Changes $changes -Statistics $null -RunId 'r1' -PreviousId 'p' -CurrentId 'c'
        $md | Should -BeLike '*- Changed paths: 4*'
        $md | Should -BeLike '*- added: 3*'
        $md | Should -BeLike '*- removed: 1*'
        $md | Should -BeLike '*- (none): 1*'
        # A backtick escapes the next character in a -like pattern, so this one is a plain Contains.
        $md.Contains('- [added] `app/1.ts`') | Should -BeTrue
    }
    It 'points to the CSV beyond 100 changes' {
        $changes = @(1..105 | ForEach-Object { [pscustomobject]@{ action = 'added'; area = 'a'; extension = '.x'; path = "a/$_.x" } })
        New-ChangeMarkdown -Changes $changes -Statistics $null -RunId 'r' -PreviousId 'p' -CurrentId 'c' | Should -BeLike '*and 5 more in the CSV*'
    }
}

Describe 'Read-ResticBackupLog' {
    It 'finds the snapshot id and every item restic could not read' {
        $lines = @(
            '{"message_type":"status","percent_done":0.5}'
            '{"message_type":"error","error":{"message":"The process cannot access the file"},"during":"archival","item":"C:\\Users\\you\\Projects\\locked.db"}'
            '{"message_type":"error","error":"old restic writes a plain string","during":"scan","item":"C:\\Users\\you\\Projects\\nul"}'
            'not json at all'
            '{"message_type":"summary","files_new":3,"snapshot_id":"0123456789abcdef"}'
        )
        $result = Read-ResticBackupLog -Lines $lines
        $result.SnapshotId | Should -Be '0123456789abcdef'
        $result.Unreadable.Count | Should -Be 2
        $result.Unreadable[0] | Should -Be 'C:\Users\you\Projects\locked.db (The process cannot access the file)'
        $result.Unreadable[1] | Should -BeLike 'C:\Users\you\Projects\nul (old restic*'
    }
}

Describe 'Get-RobocopyErrorLines' {
    It 'finds errors in any language by the hex code' {
        $lines = @(
            '   Total    Copied   Skipped',
            '2026/09/06 19:05:12 ERRO 5 (0x00000005) Copiando Arquivo C:\src\.env.app-production',
            'Acesso negado.',
            '2026/09/06 19:05:13 ERROR 32 (0x00000020) Copying File C:\src\open.db'
        )
        $found = @(Get-RobocopyErrorLines -Lines $lines)
        $found.Count | Should -Be 2
        $found[0] | Should -BeLike '*ERRO 5 (0x00000005)*'
    }
}
