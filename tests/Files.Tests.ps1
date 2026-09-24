BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Assert-MirrorTarget' {
    BeforeEach {
        $script:Mirror = Join-Path $TestDrive ('mirror-' + [guid]::NewGuid().ToString('N'))
    }

    It 'never creates a missing mirror folder, which would inherit the permissions of the drive' {
        { Assert-MirrorTarget -MirrorPath $script:Mirror -SourcePath 'C:\src' } | Should -Throw -ExpectedMessage '*is missing. Run scripts\install.ps1 again*'
        $script:Mirror | Should -Not -Exist
    }

    It 'marks an empty folder with the source' {
        New-Item -ItemType Directory -Path $script:Mirror | Out-Null
        Assert-MirrorTarget -MirrorPath $script:Mirror -SourcePath 'C:\src'
        ([IO.File]::ReadAllText((Join-Path $script:Mirror '.restic-twin-mirror'))).Trim() | Should -Be 'C:\src'
    }

    It 'refuses a folder with files it did not create, and leaves them alone' {
        New-TextFile -Path (Join-Path $script:Mirror 'photos\2019.jpg') -Content 'precious'
        { Assert-MirrorTarget -MirrorPath $script:Mirror -SourcePath 'C:\src' } | Should -Throw -ExpectedMessage '*already holds files that restic-twin did not put there*'
        Join-Path $script:Mirror 'photos\2019.jpg' | Should -Exist
        Join-Path $script:Mirror '.restic-twin-mirror' | Should -Not -Exist
    }

    It 'refuses a mirror that belongs to another source' {
        New-TextFile -Path (Join-Path $script:Mirror '.restic-twin-mirror') -Content "C:\other`n"
        { Assert-MirrorTarget -MirrorPath $script:Mirror -SourcePath 'C:\src' } | Should -Throw -ExpectedMessage "*is a copy of 'C:\other'*"
    }

    It 'accepts its own marker in another letter case' {
        New-TextFile -Path (Join-Path $script:Mirror '.restic-twin-mirror') -Content "c:\SRC`n"
        { Assert-MirrorTarget -MirrorPath $script:Mirror -SourcePath 'C:\src' } | Should -Not -Throw
    }
}

Describe 'Update-Mirror' {
    BeforeAll {
        $source = Join-Path $TestDrive 'source'
        $destination = Join-Path $TestDrive 'dest'
        $config = New-TestSettingsFile -Folder (Join-Path $TestDrive 'cfg') -Source $source -Destination $destination
        [IO.File]::WriteAllText((Join-Path $TestDrive 'cfg\excludes-mirror.txt'), "secret.env`r`n")
        $script:Settings = Get-BackupSettings -ConfigPath $config
        New-TextFile -Path (Join-Path $source 'keep.txt') -Content 'v1'
        New-TextFile -Path (Join-Path $source 'app\node_modules\big.js') -Content 'rebuildable'
        New-TextFile -Path (Join-Path $source 'app\index.js') -Content 'code'
        New-TextFile -Path (Join-Path $source 'secret.env') -Content 'TOKEN=1'
        New-Item -ItemType Directory -Path $script:Settings.LogsPath, $script:Settings.MirrorPath -Force | Out-Null
        $script:FirstExit = Update-Mirror -Settings $script:Settings -LogPath (Join-Path $script:Settings.LogsPath 'robocopy_1.log')
    }

    It 'copies the source with a success code' {
        $script:FirstExit | Should -BeLessThan 8
        Get-Content -LiteralPath (Join-Path $script:Settings.MirrorPath 'keep.txt') | Should -Be 'v1'
        Join-Path $script:Settings.MirrorPath 'app\index.js' | Should -Exist
    }

    It 'leaves out both exclude lists' {
        Join-Path $script:Settings.MirrorPath 'app\node_modules' | Should -Not -Exist
        Join-Path $script:Settings.MirrorPath 'secret.env' | Should -Not -Exist
    }

    It 'deletes what left the source but keeps its marker' {
        Remove-Item -LiteralPath (Join-Path $script:Settings.SourcePath 'keep.txt')
        $exit = Update-Mirror -Settings $script:Settings -LogPath (Join-Path $script:Settings.LogsPath 'robocopy_2.log')
        $exit | Should -BeLessThan 8
        Join-Path $script:Settings.MirrorPath 'keep.txt' | Should -Not -Exist
        Join-Path $script:Settings.MirrorPath '.restic-twin-mirror' | Should -Exist
    }

    It 'writes a log robocopy produced itself' {
        Join-Path $script:Settings.LogsPath 'robocopy_1.log' | Should -Exist
    }
}

Describe 'Invoke-HotCopySet' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('hot-' + [guid]::NewGuid().ToString('N'))
        $script:A = Join-Path $script:Root 'src\board.html'
        $script:B = Join-Path $script:Root 'src\data\board.data.js'
        New-TextFile -Path $script:A -Content 'html v1'
        New-TextFile -Path $script:B -Content 'data v1'
        $script:Set = @{ Name = 'board'; Files = @($script:A, $script:B); Keep = 3 }
        $script:Copies = Join-Path $script:Root 'hot-copies'
        $script:T0 = [datetime]'2026-09-23T10:00:00'
    }

    It 'copies the whole set into one timestamped folder' {
        $r = Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0
        $r.Result | Should -Be 'copied'
        $r.Version | Should -Be '2026-09-23_100000'
        Get-Content -LiteralPath (Join-Path $script:Copies 'board\2026-09-23_100000\board.html') | Should -Be 'html v1'
        Get-Content -LiteralPath (Join-Path $script:Copies 'board\2026-09-23_100000\board.data.js') | Should -Be 'data v1'
    }

    It 'does nothing when no file changed' {
        Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0 | Out-Null
        $r = Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0.AddMinutes(5)
        $r.Result | Should -Be 'unchanged'
        @(Get-HotCopyVersions -SetPath (Join-Path $script:Copies 'board')).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $script:Copies 'board') -Directory -Filter '.incoming-*').Count | Should -Be 0
    }

    It 'copies both files again when only one of them changed' {
        Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0 | Out-Null
        New-TextFile -Path $script:B -Content 'data v2'
        $r = Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0.AddMinutes(5)
        $r.Result | Should -Be 'copied'
        Get-Content -LiteralPath (Join-Path $script:Copies "board\$($r.Version)\board.data.js") | Should -Be 'data v2'
        Join-Path $script:Copies "board\$($r.Version)\board.html" | Should -Exist
    }

    It 'keeps only the newest Keep versions and never touches other folders' {
        $other = Join-Path $script:Copies 'board\my-notes'
        New-TextFile -Path (Join-Path $other 'keep-me.txt')
        for ($i = 1; $i -le 5; $i++) {
            New-TextFile -Path $script:A -Content "html v$i"
            $r = Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0.AddMinutes($i)
        }
        @(Get-HotCopyVersions -SetPath (Join-Path $script:Copies 'board') | ForEach-Object { $_.Name }) -join ',' | Should -Be '2026-09-23_100300,2026-09-23_100400,2026-09-23_100500'
        $r.Removed -join ',' | Should -Be '2026-09-23_100200'
        Join-Path $other 'keep-me.txt' | Should -Exist
    }

    It 'adds a suffix instead of overwriting a version from the same second, and sorts it numerically' {
        for ($i = 1; $i -le 11; $i++) {
            New-TextFile -Path $script:A -Content "same second $i"
            Invoke-HotCopySet -Set (@{ Name = 'board'; Files = @($script:A); Keep = 100 }) -HotCopiesPath $script:Copies -Now $script:T0 | Out-Null
        }
        $names = @(Get-HotCopyVersions -SetPath (Join-Path $script:Copies 'board') | ForEach-Object { $_.Name })
        $names[0] | Should -Be '2026-09-23_100000'
        $names[-1] | Should -Be '2026-09-23_100000-11'
        Get-Content -LiteralPath (Join-Path $script:Copies 'board\2026-09-23_100000-11\board.html') | Should -Be 'same second 11'
    }

    It 'fails without writing a partial version when a file is missing' {
        Remove-Item -LiteralPath $script:B
        { Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0 } | Should -Throw -ExpectedMessage '*file not found*board.data.js*'
        @(Get-HotCopyVersions -SetPath (Join-Path $script:Copies 'board')).Count | Should -Be 0
    }

    It 'cleans a staging folder left by a crashed run' {
        New-TextFile -Path (Join-Path $script:Copies 'board\.incoming-dead\board.html')
        Invoke-HotCopySet -Set $script:Set -HotCopiesPath $script:Copies -Now $script:T0 | Out-Null
        Join-Path $script:Copies 'board\.incoming-dead' | Should -Not -Exist
    }
}

Describe 'hot-copy.ps1' {
    It 'copies each set, reports failures per set and exits 1 when one failed' {
        $source = Join-Path $TestDrive 'hc-source'
        $good = Join-Path $source 'notes.md'
        New-TextFile -Path $good -Content 'n'
        $extra = "    HotCopies = @(@{ Name = 'notes'; Files = @('$good') }, @{ Name = 'gone'; Files = @('$(Join-Path $source 'missing.txt')') })"
        $config = New-TestSettingsFile -Folder (Join-Path $TestDrive 'hc-cfg') -Source $source -Destination (Join-Path $TestDrive 'hc-dest') -Extra $extra
        # install.ps1 creates hot-copies\ with its permissions; the script refuses to run without it.
        $refused = Invoke-RepoScript -Name 'hot-copy.ps1' -Arguments @('-ConfigPath', $config)
        $refused.ExitCode | Should -Be 1
        $refused.Text | Should -BeLike '*hot-copies is missing. Run scripts\install.ps1 again*'
        Join-Path $TestDrive 'hc-dest\hot-copies' | Should -Not -Exist
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'hc-dest\hot-copies') -Force | Out-Null
        $run = Invoke-RepoScript -Name 'hot-copy.ps1' -Arguments @('-ConfigPath', $config)
        $run.ExitCode | Should -Be 1
        $run.Text | Should -BeLike '*notes: copied*'
        $run.Text | Should -BeLike '*gone: error: file not found*'
        @(Get-HotCopyVersions -SetPath (Join-Path $TestDrive 'hc-dest\hot-copies\notes')).Count | Should -Be 1
        # Its log lives with the hot copies: logs\ belongs to the SYSTEM task.
        Get-Content -LiteralPath (Join-Path $TestDrive 'hc-dest\hot-copies\hot-copies.log') -Raw | Should -BeLike '*gone: error*'
        Join-Path $TestDrive 'hc-dest\logs\hot-copies.log' | Should -Not -Exist
    }
}

Describe 'Set-PrivateFolderAcl and Test-PrivateFolderAcl' {
    It 'makes a folder read-only for you and full control for SYSTEM and Administrators' {
        $folder = Join-Path $TestDrive 'acl-read'
        New-Item -ItemType Directory -Path $folder | Out-Null
        Test-PrivateFolderAcl -Path $folder -UserAccess Read | Should -BeFalse
        Set-PrivateFolderAcl -Path $folder -UserAccess Read
        try {
            Test-PrivateFolderAcl -Path $folder -UserAccess Read | Should -BeTrue
            Test-PrivateFolderAcl -Path $folder -UserAccess Full | Should -BeFalse
            { [IO.File]::WriteAllText((Join-Path $folder 'x.txt'), 'x') } | Should -Throw
            @(Get-ChildItem -LiteralPath $folder).Count | Should -Be 0
        }
        finally {
            # Still the owner here, so the permissions can be given back before Pester cleans up.
            Set-PrivateFolderAcl -Path $folder -UserAccess Full
        }
        Test-PrivateFolderAcl -Path $folder -UserAccess Full | Should -BeTrue
        { [IO.File]::WriteAllText((Join-Path $folder 'x.txt'), 'x') } | Should -Not -Throw
    }
}

Describe 'Enter-RunLock' {
    It 'lets one holder in at a time, across processes' {
        $lock = Enter-RunLock -Name "test-$PID"
        try {
            $lock | Should -Not -BeNullOrEmpty
            $powershell = (Get-Process -Id $PID).Path
            $probe = ". '$(Join-Path $script:RepoRoot 'scripts\common.ps1')'; if (`$null -eq (Enter-RunLock -Name 'test-$PID')) { exit 7 } else { exit 0 }"
            $other = Invoke-NativeCapture -FilePath $powershell -Arguments @('-NoProfile', '-NonInteractive', '-Command', $probe)
            $other.ExitCode | Should -Be 7
        }
        finally {
            Exit-RunLock $lock
        }
        $again = Enter-RunLock -Name "test-$PID"
        $again | Should -Not -BeNullOrEmpty
        Exit-RunLock $again
    }
}

Describe 'Get-RunLockName' {
    It 'names one lock per destination, ignoring case' {
        $a = @{ DestinationRoot = 'E:\restic-twin' }
        (Get-RunLockName -Kind backup -Settings $a) | Should -Be (Get-RunLockName -Kind backup -Settings @{ DestinationRoot = 'e:\RESTIC-TWIN' })
        (Get-RunLockName -Kind backup -Settings $a) | Should -Not -Be (Get-RunLockName -Kind backup -Settings @{ DestinationRoot = 'F:\restic-twin' })
        (Get-RunLockName -Kind backup -Settings $a) | Should -Not -Be (Get-RunLockName -Kind hot-copy -Settings $a)
        (Get-RunLockName -Kind backup -Settings $a) | Should -Match '^backup-[0-9a-f]{16}$'
    }

    It 'blocks a second run on the same destination and not a run on another one, across processes' {
        $here = @{ DestinationRoot = (Join-Path $TestDrive "lock-a-$PID") }
        $lock = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings $here)
        try {
            $lock | Should -Not -BeNullOrEmpty
            $powershell = (Get-Process -Id $PID).Path
            $common = Join-Path $script:RepoRoot 'scripts\common.ps1'
            foreach ($case in @(@{ Destination = $here.DestinationRoot; Expected = 7 }, @{ Destination = (Join-Path $TestDrive "lock-b-$PID"); Expected = 0 })) {
                $probe = ". '$common'; `$l = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings @{ DestinationRoot = '$($case.Destination)' }); if (`$null -eq `$l) { exit 7 }; Exit-RunLock `$l; exit 0"
                (Invoke-NativeCapture -FilePath $powershell -Arguments @('-NoProfile', '-NonInteractive', '-Command', $probe)).ExitCode | Should -Be $case.Expected
            }
        }
        finally {
            Exit-RunLock $lock
        }
    }
}

Describe 'run-hidden.vbs' {
    BeforeAll {
        $script:Wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
        $script:Vbs = Join-Path $script:RepoRoot 'scripts\run-hidden.vbs'
        $script:PowerShellPath = (Get-Process -Id $PID).Path
    }

    It 'returns the exit code of the program it ran, with arguments that contain spaces' -Skip:(-not (Test-Path (Join-Path $env:WINDIR 'System32\wscript.exe'))) {
        $marker = Join-Path $TestDrive 'folder with spaces\ran.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
        $command = "Set-Content -LiteralPath '$marker' -Value ok; exit 7"
        $process = Start-Process -FilePath $script:Wscript -ArgumentList @('//B', '//Nologo', "`"$script:Vbs`"", "`"$script:PowerShellPath`"", '-NoProfile', '-Command', "`"$command`"") -Wait -PassThru
        $process.ExitCode | Should -Be 7
        $marker | Should -Exist
    }

    It 'exits 1 when the program cannot be started' -Skip:(-not (Test-Path (Join-Path $env:WINDIR 'System32\wscript.exe'))) {
        $process = Start-Process -FilePath $script:Wscript -ArgumentList @('//B', '//Nologo', "`"$script:Vbs`"", '"C:\does not exist\nothing.exe"') -Wait -PassThru
        $process.ExitCode | Should -Be 1
    }
}
