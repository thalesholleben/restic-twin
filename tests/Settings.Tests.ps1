BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Resolve-Test {
        param([hashtable]$Override = @{})
        $raw = @{ SourcePath = 'C:\Data\Projects'; DestinationRoot = 'E:\restic-twin' }
        foreach ($key in $Override.Keys) { $raw[$key] = $Override[$key] }
        return Resolve-BackupSettings -Raw $raw
    }
}

Describe 'Resolve-BackupSettings' {
    It 'derives every folder from DestinationRoot and fills the defaults' {
        $s = Resolve-Test
        $s.MirrorPath | Should -Be 'E:\restic-twin\mirror'
        $s.RepositoryPath | Should -Be 'E:\restic-twin\history'
        $s.PasswordFile | Should -Be 'E:\restic-twin\recovery\restic-password.txt'
        $s.RestoresPath | Should -Be 'E:\restic-twin\restores'
        $s.DailyAt | Should -Be '19:00'
        $s.KeepDaily | Should -Be 7
        $s.KeepMonthly | Should -Be 6
        @($s.HotCopies).Count | Should -Be 0
    }

    It 'normalizes trailing slashes and dot segments' {
        $s = Resolve-Test @{ SourcePath = 'C:\Data\.\Projects\'; DestinationRoot = 'E:\' }
        $s.SourcePath | Should -Be 'C:\Data\Projects'
        $s.DestinationRoot | Should -Be 'E:\'
        $s.MirrorPath | Should -Be 'E:\mirror'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a missing SourcePath'; Override = @{ SourcePath = $null }; Message = '*SourcePath is required*' }
        @{ Case = 'a relative path'; Override = @{ SourcePath = 'Projects' }; Message = '*SourcePath must be an absolute path*' }
        @{ Case = 'a network path'; Override = @{ DestinationRoot = '\\nas\backup' }; Message = '*DestinationRoot must be an absolute path*' }
        @{ Case = 'a destination inside the source'; Override = @{ DestinationRoot = 'C:\Data\Projects\backup' }; Message = '*must not be the same folder or inside each other*' }
        @{ Case = 'a source inside the destination'; Override = @{ SourcePath = 'E:\restic-twin\work' }; Message = '*must not be the same folder or inside each other*' }
        @{ Case = 'the same folder in another case'; Override = @{ DestinationRoot = 'c:\data\PROJECTS' }; Message = '*must not be the same folder or inside each other*' }
        @{ Case = 'a password inside the source'; Override = @{ PasswordFile = 'C:\Data\Projects\key.txt' }; Message = '*PasswordFile must not be inside SourcePath*' }
        @{ Case = 'a password inside the mirror'; Override = @{ PasswordFile = 'E:\restic-twin\mirror\key.txt' }; Message = '*PasswordFile must not be inside E:\restic-twin\mirror*' }
        @{ Case = 'a password inside the history'; Override = @{ PasswordFile = 'E:\restic-twin\history\key.txt' }; Message = '*PasswordFile must not be inside E:\restic-twin\history*' }
        @{ Case = 'a misspelled key'; Override = @{ KeepDialy = 3 }; Message = "*Unknown setting 'KeepDialy'*" }
        @{ Case = 'an impossible time'; Override = @{ DailyAt = '25:00' }; Message = '*DailyAt must be a 24-hour time*' }
        @{ Case = 'zero daily snapshots'; Override = @{ KeepDaily = 0 }; Message = '*KeepDaily must be a whole number of at least 1*' }
        @{ Case = 'a number written as text'; Override = @{ KeepMonthly = '6' }; Message = '*KeepMonthly must be a whole number*' }
        @{ Case = 'negative free space'; Override = @{ MinimumFreeSpaceGB = -1 }; Message = '*MinimumFreeSpaceGB must be a number, 0 or more*' }
    ) {
        { Resolve-Test $Override } | Should -Throw -ExpectedMessage $Message
    }

    It 'accepts a password file outside the destination, and inside recovery' {
        (Resolve-Test @{ PasswordFile = 'C:\ProgramData\restic-twin\key.txt' }).PasswordFile | Should -Be 'C:\ProgramData\restic-twin\key.txt'
        (Resolve-Test @{ PasswordFile = 'E:\restic-twin\recovery\other.txt' }).PasswordFile | Should -Be 'E:\restic-twin\recovery\other.txt'
    }

    It 'lists every problem in one error, not only the first' {
        $message = $null
        try { Resolve-Test @{ KeepDaily = 0; DailyAt = 'noon'; Typo = 1 } } catch { $message = $_.Exception.Message }
        $message | Should -BeLike '*KeepDaily*'
        $message | Should -BeLike '*DailyAt*'
        $message | Should -BeLike '*Typo*'
    }

    Context 'HotCopies' {
        It 'normalizes a valid entry and defaults Keep to 12' {
            $s = Resolve-Test @{ HotCopies = @(@{ Name = 'notes'; Files = 'C:\Data\Projects\notes.md' }) }
            $s.HotCopies[0].Name | Should -Be 'notes'
            $s.HotCopies[0].Files -join '|' | Should -Be 'C:\Data\Projects\notes.md'
            $s.HotCopies[0].Keep | Should -Be 12
        }

        It 'rejects <Case>' -ForEach @(
            @{ Case = 'a name with a slash'; Sets = @(@{ Name = 'a/b'; Files = @('C:\x.txt') }); Message = '*HotCopies Name must start with a letter*' }
            @{ Case = 'the same name twice'; Sets = @(@{ Name = 'a'; Files = @('C:\x.txt') }, @{ Name = 'A'; Files = @('C:\y.txt') }); Message = "*HotCopies Name 'A' is used twice*" }
            @{ Case = 'no files'; Sets = @(@{ Name = 'a'; Files = @() }); Message = "*HotCopies 'a' has no Files*" }
            @{ Case = 'a relative file'; Sets = @(@{ Name = 'a'; Files = @('notes.md') }); Message = '*is not an absolute path*' }
            @{ Case = 'two files with one name'; Sets = @(@{ Name = 'a'; Files = @('C:\one\index.html', 'C:\two\INDEX.html') }); Message = "*has two files named*" }
            @{ Case = 'a file inside the destination'; Sets = @(@{ Name = 'a'; Files = @('E:\restic-twin\mirror\x.txt') }); Message = '*is inside DestinationRoot*' }
            @{ Case = 'an unknown key'; Sets = @(@{ Name = 'a'; Files = @('C:\x.txt'); Every = 5 }); Message = "*Unknown key 'Every'*" }
            @{ Case = 'Keep = 0'; Sets = @(@{ Name = 'a'; Files = @('C:\x.txt'); Keep = 0 }); Message = '*Keep must be a whole number of at least 1*' }
        ) {
            { Resolve-Test @{ HotCopies = $Sets } } | Should -Throw -ExpectedMessage $Message
        }
    }
}

Describe 'Get-BackupSettings' {
    It 'reads a UTF-8 file without BOM with an accented path, on either PowerShell' {
        $source = (Join-Path $TestDrive 'Usu') + [char]0x00E1 + 'rio\Projetos'
        $config = New-TestSettingsFile -Folder (Join-Path $TestDrive 'cfg') -Source $source -Destination (Join-Path $TestDrive 'dest')
        $s = Get-BackupSettings -ConfigPath $config
        $s.SourcePath | Should -BeExactly $source
        $s.ExcludesPath | Should -Be (Join-Path $TestDrive 'cfg\excludes.txt')
    }

    It 'refuses a settings file that runs code' {
        $config = Join-Path $TestDrive 'evil.psd1'
        [IO.File]::WriteAllText($config, "@{ SourcePath = (Get-Date).ToString(); DestinationRoot = 'E:\x' }")
        { Get-BackupSettings -ConfigPath $config } | Should -Throw -ExpectedMessage '*may only hold plain values*'
    }

    It 'says how to create the settings when the file is missing' {
        { Get-BackupSettings -ConfigPath (Join-Path $TestDrive 'nope.psd1') } | Should -Throw -ExpectedMessage '*Copy config\settings.example.psd1*'
    }

    It 'accepts the shipped example as it is' {
        $s = Get-BackupSettings -ConfigPath (Join-Path $script:RepoRoot 'config\settings.example.psd1')
        $s.SourcePath | Should -Be 'C:\Users\you\Projects'
    }
}

Describe 'Get-ExcludePatterns' {
    It 'skips comments and blank lines and trims the rest' {
        $file = Join-Path $TestDrive 'ex.txt'
        [IO.File]::WriteAllText($file, "# comment`r`n`r`n  node_modules  `r`n*.tmp`r`n")
        @(Get-ExcludePatterns -Path $file) -join '|' | Should -Be 'node_modules|*.tmp'
    }

    It 'rejects a path, because restic and robocopy would read it differently' {
        $file = Join-Path $TestDrive 'ex-path.txt'
        [IO.File]::WriteAllText($file, "ok`r`nsrc/build`r`n")
        { @(Get-ExcludePatterns -Path $file) } | Should -Throw -ExpectedMessage '*line 2*is a path*'
    }

    It 'returns nothing for a missing file' {
        @(Get-ExcludePatterns -Path (Join-Path $TestDrive 'missing.txt')).Count | Should -Be 0
    }

    It 'ships lists that pass its own check' {
        @(Get-ExcludePatterns -Path (Join-Path $script:RepoRoot 'config\excludes.txt')).Count | Should -BeGreaterThan 10
        { @(Get-ExcludePatterns -Path (Join-Path $script:RepoRoot 'config\excludes-mirror.txt')) } | Should -Not -Throw
    }
}

Describe 'Get-ResticExcludeLines' {
    It 'anchors every name under the source, so a parent folder called build does not exclude it' {
        @(Get-ResticExcludeLines -SourcePath 'D:\build\app' -Patterns @('build', '*.tmp')) -join '|' | Should -Be 'D:\build\app\**\build|D:\build\app\**\*.tmp'
    }
    It 'works for a whole drive' {
        @(Get-ResticExcludeLines -SourcePath 'D:\' -Patterns @('node_modules')) | Should -Be 'D:\**\node_modules'
    }
    It 'makes a [ in the source path literal' {
        @(Get-ResticExcludeLines -SourcePath 'C:\work\[old] app' -Patterns @('dist')) | Should -Be 'C:\work\[[]old] app\**\dist'
    }
    It 'returns nothing for an empty list' {
        @(Get-ResticExcludeLines -SourcePath 'C:\work' -Patterns @()).Count | Should -Be 0
    }
}

Describe 'Test-PathInside' {
    It 'does not mistake a sibling with a longer name for a child' {
        Test-PathInside 'C:\Data\Projects2' 'C:\Data\Projects' | Should -BeFalse
        Test-PathInside 'C:\Data\Projects\a' 'C:\Data\Projects' | Should -BeTrue
        Test-PathInside 'E:\anything' 'E:\' | Should -BeTrue
    }
}

Describe 'Repository hygiene' {
    It '<Name> parses without errors on this PowerShell' -ForEach @(Get-ChildItem (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It '<Name> is plain ASCII, so Windows PowerShell 5.1 reads it the same way' -ForEach @(Get-ChildItem (Join-Path $PSScriptRoot '..\scripts') -File | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
