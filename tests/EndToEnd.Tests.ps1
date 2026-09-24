BeforeDiscovery {
    . ([IO.Path]::Combine($PSScriptRoot, 'TestHelpers.ps1'))
}

BeforeAll {
    . ([IO.Path]::Combine($PSScriptRoot, '..', 'scripts', 'common.ps1'))
    . ([IO.Path]::Combine($PSScriptRoot, 'TestHelpers.ps1'))
}

# One scenario, in order: install, first backup, changes, restore, then the ways a run can fail.
# Uses the real restic from bin (scripts/install-restic.ps1 puts it there), as your own account:
# -NoVss on Windows, because VSS needs an elevated shell. The SYSTEM and root side of an install is
# covered by tests/ci-system-install.ps1 and tests/ci-system-install-macos.ps1.
#
# Not in $TestDrive: Pester deletes whatever a Context created there when the Context ends, and
# that took the second snapshot's pack files out of the repository, silently.
Describe 'restic-twin end to end' -Skip:(-not $script:HasRestic) {
    BeforeAll {
        $script:Work = Get-TestWorkRoot
        $script:Accented = 'relat' + [char]0x00F3 + 'rio-' + [char]0x00E7 + [char]0x00E3 + 'o.md'
        # Under a folder named "build" on purpose: build is in excludes.txt, and restic used to
        # match it against the parents of the source and back up nothing, with exit code 0.
        $script:Source = (Join-TestPath $script:Work 'build\Projetos-') + [char]0x00E7 + [char]0x00E3 + 'o'
        $script:Config = New-TestSettingsFile -Folder (Join-TestPath $script:Work 'cfg') -Source $script:Source -Destination (Join-TestPath $script:Work 'twin') -Extra '    MinimumFreeSpaceGB = 0'
        $script:S = Get-BackupSettings -ConfigPath $script:Config
        $script:BackupArgs = @('-ConfigPath', $script:Config, '-NoVss')

        New-TextFile -Path (Join-TestPath $script:Source 'README.md') -Content 'hello'
        New-TextFile -Path (Join-TestPath $script:Source "docs\$script:Accented") -Content 'v1'
        New-TextFile -Path (Join-TestPath $script:Source 'old.txt') -Content 'bye'
        New-TextFile -Path (Join-TestPath $script:Source 'app\node_modules\dep.js') -Content 'rebuildable'

        function Get-Latest { [IO.File]::ReadAllText((Join-TestPath $script:S.LogsPath 'latest.json')) | ConvertFrom-Json }
        function Get-RunCount { @([IO.File]::ReadAllLines((Join-TestPath $script:S.LogsPath 'runs.jsonl'))).Count }
        function Get-ModeLine { param([string]$Path) (@(& /usr/bin/stat -f '%Su %Lp' $Path) -join '').Trim() }
        function Get-AclEntryCount { param([string]$Path) @(& /bin/ls -led $Path | Where-Object { $_ -match '^\s*\d+:\s' }).Count }

        $script:Install = Invoke-RepoScript -Name 'install.ps1' -Arguments @('-ConfigPath', $script:Config, '-SkipScheduledTask')
        $script:Run1 = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
    }

    AfterAll {
        Remove-TestFolder -Path $script:Work
    }

    It 'install creates the repository, the recovery notes and the mirror marker' {
        $script:Install.ExitCode | Should -Be 0 -Because $script:Install.Text
        Join-TestPath $script:S.RepositoryPath 'config' | Should -Exist
        Join-TestPath $script:S.RecoveryPath 'README.txt' | Should -Exist
        Join-TestPath $script:S.MirrorPath '.restic-twin-mirror' | Should -Exist
        $script:Install.Text | Should -BeLike '*Copy it to a password manager now*'
    }

    It 'install leaves the password and the mirror readable only by you, SYSTEM and Administrators' -Skip:(-not $script:OnWindowsTest) {
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

    It 'install leaves the password and the mirror to you alone, read-only for the password' -Skip:$script:OnWindowsTest {
        $me = (@(& /usr/bin/id -un) -join '').Trim()
        Get-ModeLine $script:S.PasswordFile | Should -Be "$me 400"
        Get-ModeLine $script:S.MirrorPath | Should -Be "$me 700"
        Get-ModeLine $script:S.DestinationRoot | Should -Be "$me 700"
        Get-AclEntryCount $script:S.PasswordFile | Should -Be 0
        Get-AclEntryCount $script:S.MirrorPath | Should -Be 0
    }

    It 'the first backup succeeds, writes a baseline and fills the mirror' {
        $script:Run1.ExitCode | Should -Be 0 -Because $script:Run1.Text
        (Get-Latest).status | Should -Be 'success'
        # The snapshot really holds the files (README, the accented doc, old.txt; not node_modules).
        $summary = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:S.LogsPath -Filter 'restic-backup_*.jsonl' | Select-Object -First 1).FullName | Where-Object { $_ -match '"message_type":"summary"' } | ConvertFrom-Json
        $summary.total_files_processed | Should -Be 3
        @(Get-ChildItem -LiteralPath $script:S.ReportsPath -Recurse -Filter 'baseline_*.md').Count | Should -Be 1
        Get-Content -LiteralPath (Join-TestPath $script:S.MirrorPath "docs\$script:Accented") | Should -Be 'v1'
        Join-TestPath $script:S.MirrorPath 'app\node_modules' | Should -Not -Exist
        (Get-Latest).mirror_exit_code | Should -Not -BeNullOrEmpty
        Join-TestPath $script:S.LogsPath "$($script:MirrorTool)_$((Get-Latest).run_id).log" | Should -Exist
    }

    Context 'second backup, under the console of a scheduled job' {
        BeforeAll {
            New-TextFile -Path (Join-TestPath $script:Source "docs\$script:Accented") -Content 'v2'
            New-TextFile -Path (Join-TestPath $script:Source 'new.txt') -Content 'new'
            Remove-Item -LiteralPath (Join-TestPath $script:Source 'old.txt')

            # On Windows the child inherits this console, and a scheduled task gets the OEM code page.
            # Without Enable-Utf8NativeOutput in backup.ps1 it would decode restic's UTF-8 as code
            # page 850 and write mojibake into the reports.
            $before = $null
            if ($script:OnWindowsTest) {
                $before = [Console]::OutputEncoding.CodePage
                $null = & chcp.com 850 2>&1
            }
            try {
                $script:Run2 = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            }
            finally {
                if ($null -ne $before) { $null = & chcp.com $before 2>&1 }
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
            Join-TestPath $script:S.MirrorPath 'new.txt' | Should -Exist
            Join-TestPath $script:S.MirrorPath 'old.txt' | Should -Not -Exist
            Get-Content -LiteralPath (Join-TestPath $script:S.MirrorPath "docs\$script:Accented") | Should -Be 'v2'
        }

        It 'runs prune and check on the first run only, not again within the week' {
            Join-TestPath $script:S.LogsPath 'last-maintenance.txt' | Should -Exist
            @(Get-ChildItem -LiteralPath $script:S.LogsPath -Filter 'prune_*.log').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $script:S.LogsPath -Filter 'check_*.log').Count | Should -Be 1
        }
    }

    Context 'restore' {
        It 'puts the latest snapshot in a new folder, byte for byte' {
            $target = Join-TestPath $script:Work 'restored'
            $run = Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $target)
            $run.ExitCode | Should -Be 0 -Because $run.Text
            # The content of the source folder lands straight in the target, without the folders
            # above it (C\Users\... on Windows, private/var/... on macOS).
            $first = (ConvertTo-SnapshotPath -Path $script:Source).Split('/')[1]
            Join-TestPath $target $first | Should -Not -Exist
            $files = @(Get-ChildItem -LiteralPath $script:Source -Recurse -File | Where-Object { $_.FullName.Replace('\', '/') -notlike '*/node_modules/*' })
            $files.Count | Should -Be 3 -Because (($files | ForEach-Object { $_.FullName.Substring($script:Source.Length) }) -join ', ')
            foreach ($file in $files) {
                $copy = Join-TestPath $target $file.FullName.Substring($script:Source.Length + 1)
                (Get-FileHash -LiteralPath $copy).Hash | Should -Be (Get-FileHash -LiteralPath $file.FullName).Hash
            }
            Join-TestPath $target 'app\node_modules' | Should -Not -Exist
        }

        It 'restores only what -Include names' {
            $target = Join-TestPath $script:Work 'restored-docs'
            $run = Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $target, '-Include', '/docs')
            $run.ExitCode | Should -Be 0 -Because $run.Text
            Get-Content -LiteralPath (Join-TestPath $target "docs\$script:Accented") | Should -Be 'v2'
            Join-TestPath $target 'README.md' | Should -Not -Exist
        }

        It 'restores from a history your account can only read, as after an elevated install' {
            Set-TestReadOnlyTree -Path $script:S.RepositoryPath
            try {
                $target = Join-TestPath $script:Work 'restored-readonly'
                $run = Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $target)
                $run.ExitCode | Should -Be 0 -Because $run.Text
                Get-Content -LiteralPath (Join-TestPath $target 'new.txt') | Should -Be 'new'
                $status = Invoke-RepoScript -Name 'status.ps1' -Arguments @('-ConfigPath', $script:Config)
                $status.Text | Should -BeLike '*Snapshots:     2*'
                @(Get-ChildItem -LiteralPath (Join-TestPath $script:S.RepositoryPath 'locks')).Count | Should -Be 0
            }
            finally {
                Reset-TestWritableTree -Path $script:S.RepositoryPath
            }
        }

        It 'refuses a target that exists or sits inside the source' {
            $existing = Join-TestPath $script:Work 'restored'
            (Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', $existing)).Text | Should -BeLike '*already exists*'
            (Invoke-RepoScript -Name 'restore.ps1' -Arguments @('-ConfigPath', $script:Config, '-TargetPath', (Join-TestPath $script:Source 'restore-here'))).Text | Should -BeLike '*never go inside the source*'
            Join-TestPath $script:Source 'restore-here' | Should -Not -Exist
        }
    }

    Context 'failures' {
        # On macOS the suite runs as your normal account: root reads a file whatever its mode says.
        It 'a file restic cannot read fails the run, names it, and neither the state nor the mirror move' {
            $locked = Join-TestPath $script:Source 'locked.db'
            New-TextFile -Path $locked -Content 'data'
            New-TextFile -Path (Join-TestPath $script:Source 'after-lock.txt') -Content 'n'
            $stateBefore = [IO.File]::ReadAllText((Join-TestPath $script:S.LogsPath 'last-successful-snapshot.txt'))
            # Windows: a program holding the file open. macOS: a file your account may not read.
            $stream = $null
            if ($script:OnWindowsTest) { $stream = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            else { $null = & /bin/chmod 000 $locked }
            try {
                $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() } else { $null = & /bin/chmod 644 $locked }
            }
            $run.ExitCode | Should -Be 1
            $latest = Get-Latest
            $latest.status | Should -Be 'failed'
            $latest.restic_exit_code | Should -Be 3
            $latest.unreadable_items | Should -Be 1
            $latest.error | Should -BeLike '*could not read 1 item(s)*locked.db*'
            [IO.File]::ReadAllText((Join-TestPath $script:S.LogsPath 'last-successful-snapshot.txt')) | Should -Be $stateBefore
            Join-TestPath $script:S.MirrorPath 'after-lock.txt' | Should -Not -Exist
        }

        It 'a run that finds another one holding the lock exits 0 and records nothing' {
            $runsBefore = Get-RunCount
            $lock = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings $script:S) -Folder $script:S.LogsPath
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
            Write-Utf8NoBom -Path (Join-TestPath $script:S.LogsPath 'last-successful-snapshot.txt') -Content ('f' * 64)
            $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            $run.ExitCode | Should -Be 0 -Because $run.Text
            (Get-Latest).status | Should -Be 'success'
            $run.Text | Should -BeLike '*no longer exists; starting a new baseline*'
            @(Get-ChildItem -LiteralPath $script:S.ReportsPath -Recurse -Filter 'baseline_*.md').Count | Should -Be 2
            Join-TestPath $script:S.MirrorPath 'after-lock.txt' | Should -Exist
        }

        It 'never passes a tampered state file to restic as a flag' {
            $marker = Join-TestPath $script:Work 'pwned.txt'
            $command = "/usr/bin/touch `"$marker`""
            if ($script:OnWindowsTest) { $command = "cmd /c echo x > `"$marker`"" }
            Write-Utf8NoBom -Path (Join-TestPath $script:S.LogsPath 'last-successful-snapshot.txt') -Content "--password-command=$command"
            $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments $script:BackupArgs
            $run.ExitCode | Should -Be 0 -Because $run.Text
            $run.Text | Should -BeLike '*does not hold a snapshot id; starting a new baseline*'
            $marker | Should -Not -Exist
            ([IO.File]::ReadAllText((Join-TestPath $script:S.LogsPath 'last-successful-snapshot.txt'))).Trim() | Should -Match '^[0-9a-f]{64}$'
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

        It 'backup refuses to run without VSS unless told, when the shell is not elevated' -Skip:((-not $script:OnWindowsTest) -or (Test-TestElevated)) {
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
Describe 'managed folders never keep the permissions of the drive' -Skip:(-not $script:HasRestic) {
    BeforeAll {
        $script:Work2 = Get-TestWorkRoot
        $source = Join-TestPath $script:Work2 'src'
        New-TextFile -Path (Join-TestPath $source 'a.txt') -Content 'a'
        $script:Config2 = New-TestSettingsFile -Folder (Join-TestPath $script:Work2 'cfg') -Source $source -Destination (Join-TestPath $script:Work2 'twin') -Extra '    MinimumFreeSpaceGB = 0'
        $script:S2 = Get-BackupSettings -ConfigPath $script:Config2
        # An empty mirror folder someone made before the install, open to every account.
        New-Item -ItemType Directory -Path $script:S2.MirrorPath -Force | Out-Null
        if ($script:OnWindowsTest) {
            $null = & icacls.exe $script:S2.MirrorPath /grant '*S-1-1-0:(OI)(CI)R' 2>&1
        }
        else {
            $null = & /bin/chmod 777 $script:S2.MirrorPath
            $null = & /bin/chmod +a 'group:everyone allow list,search,readattr,file_inherit,directory_inherit' $script:S2.MirrorPath
        }
        # How many ways another account has in: Everyone entries on Windows; ACL entries plus
        # group or other mode bits on macOS.
        function Get-OpenAccess {
            if ($script:OnWindowsTest) {
                return @((Get-Acl -LiteralPath $script:S2.MirrorPath).Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-1-0' }).Count
            }
            $entries = @(& /bin/ls -led $script:S2.MirrorPath | Where-Object { $_ -match '^\s*\d+:\s' }).Count
            $mode = [Convert]::ToInt32((@(& /usr/bin/stat -f '%Lp' $script:S2.MirrorPath) -join '').Trim(), 8)
            if (($mode -band 63) -ne 0) { $entries++ }
            return $entries
        }
    }

    AfterAll {
        Remove-TestFolder -Path $script:Work2
    }

    It 'install takes over an empty mirror that already existed and makes it private' {
        Get-OpenAccess | Should -BeGreaterThan 0
        $run = Invoke-RepoScript -Name 'install.ps1' -Arguments @('-ConfigPath', $script:Config2, '-SkipScheduledTask')
        $run.ExitCode | Should -Be 0 -Because $run.Text
        Get-OpenAccess | Should -Be 0
        Test-PrivateFolderAcl -Path $script:S2.MirrorPath -UserAccess Full | Should -BeTrue
        Join-TestPath $script:S2.MirrorPath '.restic-twin-mirror' | Should -Exist
    }

    It 'a backup refuses to recreate a managed folder that went missing' {
        Remove-Item -LiteralPath $script:S2.MirrorPath -Recurse -Force
        $run = Invoke-RepoScript -Name 'backup.ps1' -Arguments @('-ConfigPath', $script:Config2, '-NoVss')
        $run.ExitCode | Should -Be 1
        $run.Text | Should -BeLike '*mirror is missing. Run scripts*install.ps1 again*'
        $script:S2.MirrorPath | Should -Not -Exist
    }
}
