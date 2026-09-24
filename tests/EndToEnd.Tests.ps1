BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

# One scenario, in order: install, first backup, changes, restore, then the ways a run can fail.
# Uses the real restic from bin\ (scripts\install-restic.ps1 puts it there) and -NoVss, because
# VSS needs an elevated shell.
#
# Not in $TestDrive: Pester deletes whatever a Context created there when the Context ends, and
# that took the second snapshot's pack files out of the repository, silently.
Describe 'restic-twin end to end' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..\bin\restic.exe'))) {
    BeforeAll {
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('restic-twin-e2e-' + [guid]::NewGuid().ToString('N'))
        $script:Accented = 'relat' + [char]0x00F3 + 'rio-' + [char]0x00E7 + [char]0x00E3 + 'o.md'
        # Under a folder named "build" on purpose: build is in excludes.txt, and restic used to
        # match it against the parents of the source and back up nothing, with exit code 0.
        $script:Source = (Join-Path $script:Work 'build\Projetos-') + [char]0x00E7 + [char]0x00E3 + 'o'
        $script:Config = New-TestSettingsFile -Folder (Join-Path $script:Work 'cfg') -Source $script:Source -Destination (Join-Path $script:Work 'twin') -Extra '    MinimumFreeSpaceGB = 0'
        $script:S = Get-BackupSettings -ConfigPath $script:Config
        $script:BackupArgs = @('-ConfigPath', $script:Config, '-NoVss')

        New-TextFile -Path (Join-Path $script:Source 'README.md') -Content 'hello'
        New-TextFile -Path (Join-Path $script:Source "docs\$script:Accented") -Content 'v1'
        New-TextFile -Path (Join-Path $script:Source 'old.txt') -Content 'bye'
        New-TextFile -Path (Join-Path $script:Source 'app\node_modules\dep.js') -Content 'rebuildable'

        function Get-Latest { [IO.File]::ReadAllText((Join-Path $script:S.LogsPath 'latest.json')) | ConvertFrom-Json }
        function Get-RunCount { @([IO.File]::ReadAllLines((Join-Path $script:S.LogsPath 'runs.jsonl'))).Count }

        $script:Install = Invoke-RepoScript -Name 'install.ps1' -Arguments @('-ConfigPath', $script:Config, '-SkipScheduledTask')
        $script:Run1 = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
    }

    AfterAll {
        # The password file is read-only on purpose; take everything back before deleting.
        if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $null = & icacls.exe $script:Work /grant "*${sid}:F" /T /C /Q 2>&1
            Get-ChildItem -LiteralPath $script:Work -Recurse -Force | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            Remove-Item -LiteralPath $script:Work -Recurse -Force
        }
    }

    It 'install creates the repository, the recovery notes and the mirror marker' {
        $script:Install.ExitCode | Should -Be 0 -Because $script:Install.Text
        Join-Path $script:S.RepositoryPath 'config' | Should -Exist
        Join-Path $script:S.RecoveryPath 'README.txt' | Should -Exist
        Join-Path $script:S.MirrorPath '.restic-twin-mirror' | Should -Exist
        $script:Install.Text | Should -BeLike '*Copy it to a password manager now*'
    }

    It 'install leaves the password and the mirror readable only by you, SYSTEM and Administrators' {
        $allowed = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        foreach ($path in @($script:S.PasswordFile, $script:S.MirrorPath)) {
            $acl = Get-Acl -LiteralPath $path
            $acl.AreAccessRulesProtected | Should -BeTrue -Because "$path must not inherit the drive's permissions"
            foreach ($rule in $acl.Access) {
                $allowed | Should -Contain $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            }
        }
        $writable = @((Get-Acl -LiteralPath $script:S.PasswordFile).Access | Where-Object { $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData })
        $writable.Count | Should -Be 0
    }

    It 'the first backup succeeds, writes a baseline and fills the mirror' {
        $script:Run1.ExitCode | Should -Be 0 -Because $script:Run1.Text
        (Get-Latest).status | Should -Be 'success'
        # The snapshot really holds the files (README, the accented doc, old.txt; not node_modules).
        $summary = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:S.LogsPath -Filter 'restic-backup_*.jsonl' | Select-Object -First 1).FullName | Where-Object { $_ -match '"message_type":"summary"' } | ConvertFrom-Json
        $summary.total_files_processed | Should -Be 3
        @(Get-ChildItem -LiteralPath $script:S.ReportsPath -Recurse -Filter 'baseline_*.md').Count | Should -Be 1
        Get-Content -LiteralPath (Join-Path $script:S.MirrorPath "docs\$script:Accented") | Should -Be 'v1'
        Join-Path $script:S.MirrorPath 'app\node_modules' | Should -Not -Exist
    }

    Context 'second backup, with the console on code page 850 like a scheduled task' {
        BeforeAll {
            New-TextFile -Path (Join-Path $script:Source "docs\$script:Accented") -Content 'v2'
            New-TextFile -Path (Join-Path $script:Source 'new.txt') -Content 'new'
            Remove-Item -LiteralPath (Join-Path $script:Source 'old.txt')

            # The child inherits this console. Without Enable-Utf8NativeOutput in backup.ps1 it would
            # decode restic's UTF-8 as code page 850 and write mojibake into the reports.
            $before = [Console]::OutputEncoding.CodePage
            $null = & chcp.com 850 2>&1
            try {
                $script:Run2 = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            }
            finally {
                $null = & chcp.com $before 2>&1
            }
            $csv = Get-ChildItem -LiteralPath $script:S.ReportsPath -Recurse -Filter 'changes_*.csv' | Sort-Object Name | Select-Object -Last 1
            $script:Rows = @(Import-Csv -LiteralPath $csv.FullName -Encoding UTF8)
            $script:Jsonl = [IO.File]::ReadAllText([IO.Path]::ChangeExtension($csv.FullName, '.jsonl'))
        }

        It 'succeeds' {
            $script:Run2.ExitCode | Should -Be 0 -Because $script:Run2.Text
        }

        It 'reports what was added, removed and modified, with the accents intact' {
            ($script:Rows | Where-Object { $_.path -ceq "docs/$script:Accented" }).action | Should -Be 'modified'
            ($script:Rows | Where-Object { $_.path -eq 'new.txt' }).action | Should -Be 'added'
            ($script:Rows | Where-Object { $_.path -eq 'old.txt' }).action | Should -Be 'removed'
            $script:Jsonl | Should -BeLike "*$script:Accented*"
        }

        It 'refreshes the mirror after the snapshot' {
            Join-Path $script:S.MirrorPath 'new.txt' | Should -Exist
            Join-Path $script:S.MirrorPath 'old.txt' | Should -Not -Exist
            Get-Content -LiteralPath (Join-Path $script:S.MirrorPath "docs\$script:Accented") | Should -Be 'v2'
        }

        It 'runs prune and check on the first run only, not again within the week' {
            Join-Path $script:S.LogsPath 'last-maintenance.txt' | Should -Exist
            @(Get-ChildItem -LiteralPath $script:S.LogsPath -Filter 'prune_*.log').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $script:S.LogsPath -Filter 'check_*.log').Count | Should -Be 1
        }
    }

    Context 'restore' {
        It 'puts the latest snapshot in a new folder, byte for byte' {
            $target = Join-Path $script:Work 'restored'
            $run = Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $target)
            $run.ExitCode | Should -Be 0 -Because $run.Text
            # The content of the source folder lands straight in the target, without C\Users\... above it.
            Join-Path $target 'C' | Should -Not -Exist
            $files = @(Get-ChildItem -LiteralPath $script:Source -Recurse -File | Where-Object { $_.FullName -notlike '*\node_modules\*' })
            $files.Count | Should -Be 3 -Because (($files | ForEach-Object { $_.FullName.Substring($script:Source.Length) }) -join ', ')
            foreach ($file in $files) {
                $copy = Join-Path $target $file.FullName.Substring($script:Source.Length + 1)
                (Get-FileHash -LiteralPath $copy).Hash | Should -Be (Get-FileHash -LiteralPath $file.FullName).Hash
            }
            Join-Path $target 'app\node_modules' | Should -Not -Exist
        }

        It 'restores only what -Include names' {
            $target = Join-Path $script:Work 'restored-docs'
            $run = Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $target, '-Include', '/docs')
            $run.ExitCode | Should -Be 0 -Because $run.Text
            Get-Content -LiteralPath (Join-Path $target "docs\$script:Accented") | Should -Be 'v2'
            Join-Path $target 'README.md' | Should -Not -Exist
        }

        It 'restores from a history your account can only read, as after an elevated install' {
            Set-PrivateFolderAcl -Path $script:S.RepositoryPath -UserAccess Read
            try {
                $target = Join-Path $script:Work 'restored-readonly'
                $run = Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $target)
                $run.ExitCode | Should -Be 0 -Because $run.Text
                Get-Content -LiteralPath (Join-Path $target 'new.txt') | Should -Be 'new'
                $status = Invoke-RepoScript -Name 'status.ps1' -Arguments @('-ConfigPath', $script:Config)
                $status.Text | Should -BeLike '*Snapshots:     2*'
                @(Get-ChildItem -LiteralPath (Join-Path $script:S.RepositoryPath 'locks')).Count | Should -Be 0
            }
            finally {
                Set-PrivateFolderAcl -Path $script:S.RepositoryPath -UserAccess Full
            }
        }

        It 'refuses a target that exists or sits inside the source' {
            $existing = Join-Path $script:Work 'restored'
            (Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $existing)).Text | Should -BeLike '*already exists*'
            (Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', (Join-Path $script:Source 'restore-here'))).Text | Should -BeLike '*never go inside the source*'
            Join-Path $script:Source 'restore-here' | Should -Not -Exist
        }
    }

    Context 'failures' {
        It 'a file restic cannot read fails the run, names it, and neither the state nor the mirror move' {
            $locked = Join-Path $script:Source 'locked.db'
            New-TextFile -Path $locked -Content 'data'
            New-TextFile -Path (Join-Path $script:Source 'after-lock.txt') -Content 'n'
            $stateBefore = [IO.File]::ReadAllText((Join-Path $script:S.LogsPath 'last-successful-snapshot.txt'))
            $stream = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            }
            finally {
                $stream.Dispose()
            }
            $run.ExitCode | Should -Be 1
            $latest = Get-Latest
            $latest.status | Should -Be 'failed'
            $latest.restic_exit_code | Should -Be 3
            $latest.unreadable_items | Should -Be 1
            $latest.error | Should -BeLike '*could not read 1 item(s)*locked.db*'
            [IO.File]::ReadAllText((Join-Path $script:S.LogsPath 'last-successful-snapshot.txt')) | Should -Be $stateBefore
            Join-Path $script:S.MirrorPath 'after-lock.txt' | Should -Not -Exist
        }

        It 'a run that finds another one holding the lock exits 0 and records nothing' {
            $runsBefore = Get-RunCount
            $lock = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings $script:S)
            try {
                $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            }
            finally {
                Exit-RunLock $lock
            }
            $run.ExitCode | Should -Be 0
            $run.Text | Should -BeLike '*Another backup is running*'
            Get-RunCount | Should -Be $runsBefore
        }

        It 'starts a new baseline when the previous snapshot no longer exists' {
            Write-Utf8NoBom -Path (Join-Path $script:S.LogsPath 'last-successful-snapshot.txt') -Content ('f' * 64)
            $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            $run.ExitCode | Should -Be 0 -Because $run.Text
            (Get-Latest).status | Should -Be 'success'
            $run.Text | Should -BeLike '*no longer exists; starting a new baseline*'
            @(Get-ChildItem -LiteralPath $script:S.ReportsPath -Recurse -Filter 'baseline_*.md').Count | Should -Be 2
            Join-Path $script:S.MirrorPath 'after-lock.txt' | Should -Exist
        }

        It 'never passes a tampered state file to restic as a flag' {
            $marker = Join-Path $script:Work 'pwned.txt'
            Write-Utf8NoBom -Path (Join-Path $script:S.LogsPath 'last-successful-snapshot.txt') -Content "--password-command=cmd /c echo x > `"$marker`""
            $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            $run.ExitCode | Should -Be 0 -Because $run.Text
            $run.Text | Should -BeLike '*does not hold a snapshot id; starting a new baseline*'
            $marker | Should -Not -Exist
            ([IO.File]::ReadAllText((Join-Path $script:S.LogsPath 'last-successful-snapshot.txt'))).Trim() | Should -Match '^[0-9a-f]{64}$'
        }

        It 'install refuses a repository whose password is missing instead of making a new one' {
            $moved = $script:S.PasswordFile + '.away'
            Move-Item -LiteralPath $script:S.PasswordFile -Destination $moved
            try {
                $run = Invoke-RepoScript -Name 'install.ps1' -Arguments @('-ConfigPath', $script:Config, '-SkipScheduledTask')
                $run.ExitCode | Should -Not -Be 0
                $run.Text | Should -BeLike '*no password file*a new password would not open the existing history*'
                $script:S.PasswordFile | Should -Not -Exist
            }
            finally {
                Move-Item -LiteralPath $moved -Destination $script:S.PasswordFile
            }
        }

        It 'backup refuses to run without VSS unless told, when the shell is not elevated' -Skip:(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments @('-ConfigPath', $script:Config)
            $run.ExitCode | Should -Be 1
            (Get-Latest).error | Should -BeLike '*VSS snapshots need an elevated shell*'
        }
    }

    It 'status reads the last run and counts the snapshots' {
        $run = Invoke-RepoScript -Name 'status.ps1' -Arguments @('-ConfigPath', $script:Config)
        $run.ExitCode | Should -Be 0 -Because $run.Text
        $run.Text | Should -BeLike '*Last run:*'
        $run.Text | Should -BeLike '*Snapshots:*'
    }
}

# The permissions of the folders restic-twin writes into, including the ones it finds already there.
Describe 'managed folders never keep the permissions of the drive' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..\bin\restic.exe'))) {
    BeforeAll {
        $script:Work2 = Join-Path ([IO.Path]::GetTempPath()) ('restic-twin-e2e-' + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $script:Work2 'src'
        New-TextFile -Path (Join-Path $source 'a.txt') -Content 'a'
        $script:Config2 = New-TestSettingsFile -Folder (Join-Path $script:Work2 'cfg') -Source $source -Destination (Join-Path $script:Work2 'twin') -Extra '    MinimumFreeSpaceGB = 0'
        $script:S2 = Get-BackupSettings -ConfigPath $script:Config2
        # An empty mirror folder someone made before the install, readable by Everyone.
        New-Item -ItemType Directory -Path $script:S2.MirrorPath -Force | Out-Null
        $null = & icacls.exe $script:S2.MirrorPath /grant '*S-1-1-0:(OI)(CI)R' 2>&1
        function Get-EveryoneRules { @((Get-Acl -LiteralPath $script:S2.MirrorPath).Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-1-0' }) }
    }

    AfterAll {
        if ($script:Work2 -and (Test-Path -LiteralPath $script:Work2)) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $null = & icacls.exe $script:Work2 /grant "*${sid}:F" /T /C /Q 2>&1
            Remove-Item -LiteralPath $script:Work2 -Recurse -Force
        }
    }

    It 'install takes over an empty mirror that already existed and makes it private' {
        @(Get-EveryoneRules).Count | Should -BeGreaterThan 0
        $run = Invoke-RepoScript -Name 'install.ps1' -Arguments @('-ConfigPath', $script:Config2, '-SkipScheduledTask')
        $run.ExitCode | Should -Be 0 -Because $run.Text
        @(Get-EveryoneRules).Count | Should -Be 0
        Test-PrivateFolderAcl -Path $script:S2.MirrorPath -UserAccess Full | Should -BeTrue
        Join-Path $script:S2.MirrorPath '.restic-twin-mirror' | Should -Exist
    }

    It 'a backup refuses to recreate a managed folder that went missing' {
        Remove-Item -LiteralPath $script:S2.MirrorPath -Recurse -Force
        $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments @('-ConfigPath', $script:Config2, '-NoVss')
        $run.ExitCode | Should -Be 1
        $run.Text | Should -BeLike '*\mirror is missing. Run scripts\install.ps1 again*'
        $script:S2.MirrorPath | Should -Not -Exist
    }
}
