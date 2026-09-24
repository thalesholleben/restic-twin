# CI only. Installs restic-twin for real on a throwaway Mac: the daily job as root under launchd,
# the destination on a disk image formatted APFS and mounted in /Volumes like a backup drive. Checks
# the run, what your account may read and write, the drive going away, then uninstalls. It writes to
# /Library and loads launchd jobs: never run it on a Mac you care about.
#
#   sudo --preserve-env=GITHUB_ACTIONS pwsh -NoProfile -File tests/ci-system-install-macos.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
. ([IO.Path]::Combine($repo, 'scripts', 'common.ps1'))

if (-not $script:OnMac) { throw 'This is the macOS system test; tests/ci-system-install.ps1 is the Windows one.' }
if (-not (Test-IsAdministrator)) { throw 'Run it with sudo (it is meant for CI runners).' }
if ($env:GITHUB_ACTIONS -ne 'true' -and $env:RESTIC_TWIN_ALLOW_SYSTEM_INSTALL -ne '1') {
    throw 'Refusing to run outside GitHub Actions. Set RESTIC_TWIN_ALLOW_SYSTEM_INSTALL=1 on a throwaway Mac.'
}

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "ok: $Message"
}

$user = Get-InstallUser
$powershell = Get-TaskPowerShellPath

function Invoke-Step {
    # A script of this repo as root, or with -AsUser as the account the backups are for.
    param([string]$Script, [string[]]$Arguments = @(), [switch]$AsUser)
    $command = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', [IO.Path]::Combine($repo, 'scripts', $Script)) + $Arguments
    if ($AsUser) { $result = Invoke-NativeCapture -FilePath '/usr/bin/sudo' -Arguments (@('-H', '-u', $user.Name, $powershell) + $command) }
    else { $result = Invoke-NativeCapture -FilePath $powershell -Arguments $command }
    (@($result.StdOut) + @($result.StdErr)) | ForEach-Object { Write-Host "  | $_" }
    return $result
}

function Invoke-AsUser {
    param([string]$FilePath, [string[]]$Arguments)
    return Invoke-NativeCapture -FilePath '/usr/bin/sudo' -Arguments (@('-u', $user.Name, $FilePath) + $Arguments)
}

function Get-DailyJob {
    $print = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('print', "system/$($script:DailyLabel)")
    $job = @{ Loaded = ($print.ExitCode -eq 0); State = ''; Runs = 0; LastExit = '' }
    foreach ($line in $print.StdOut) {
        if (-not $job.State -and $line -match '^\s*state = (.+)$') { $job.State = $Matches[1].Trim() }
        elseif ($line -match '^\s*runs = (\d+)') { $job.Runs = [int]$Matches[1] }
        elseif (-not $job.LastExit -and $line -match '^\s*last exit code = (.+)$') { $job.LastExit = $Matches[1].Trim() }
    }
    return $job
}

$errorsLog = [IO.Path]::Combine((Get-InstallRoot), 'daily-errors.log')
$script:ErrorLinesShown = 0
function Start-DailyJob {
    # What launchd does at DailyAt or on the hourly start: one run of the job, waited for.
    $deadline = (Get-Date).AddMinutes(5)
    $job = Get-DailyJob
    while ($job.State -eq 'running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $job = Get-DailyJob }
    $runs = $job.Runs
    $null = Invoke-Checked -FilePath '/bin/launchctl' -Arguments @('kickstart', "system/$($script:DailyLabel)")
    do {
        Start-Sleep -Seconds 2
        $job = Get-DailyJob
    } while ((Get-Date) -lt $deadline -and ($job.State -eq 'running' -or $job.Runs -le $runs))
    Write-Host "  | launchd: state $($job.State), runs $($job.Runs), last exit code $($job.LastExit)"
    if (Test-Path -LiteralPath $errorsLog) {
        $lines = @([IO.File]::ReadAllLines($errorsLog))
        $lines | Select-Object -Skip $script:ErrorLinesShown | ForEach-Object { Write-Host "  | stderr: $_" }
        $script:ErrorLinesShown = $lines.Count
    }
    return $job
}

$volume = '/Volumes/RTWIN'
$image = '/private/tmp/restic-twin-ci.dmg'
function Mount-TestVolume {
    $null = Invoke-Checked -FilePath '/usr/bin/hdiutil' -Arguments @('attach', $image)
    if (-not (Test-Path -LiteralPath $volume -PathType Container)) { throw "The disk image did not mount at $volume." }
    # What Get Info calls "Ignore ownership on this volume", off: install.ps1 warns when it is on.
    $null = Invoke-Checked -FilePath '/usr/sbin/diskutil' -Arguments @('enableOwnership', $volume)
}
function Dismount-TestVolume {
    $null = Invoke-Checked -FilePath '/usr/bin/hdiutil' -Arguments @('detach', $volume)
}

if (Test-Path -LiteralPath $volume) { throw "$volume already exists; this test needs that name free." }
# One outer finally owns the disk image, the volume and the work folder, so a failure anywhere,
# setup and the closing asserts included, leaves the runner with no RTWIN volume mounted, no dmg and
# no work folder.
$work = [IO.Path]::Combine((Get-UserHome -User $user), 'restic-twin-ci')
try {
    $null = Invoke-Checked -FilePath '/usr/bin/hdiutil' -Arguments @('create', '-size', '200m', '-fs', 'APFS', '-volname', 'RTWIN', '-ov', $image)
    Mount-TestVolume

    $source = [IO.Path]::Combine($work, 'Projetos-' + [char]0x00E7 + [char]0x00E3 + 'o')
    $config = [IO.Path]::Combine($work, 'cfg')
    $accented = 'relat' + [char]0x00F3 + 'rio.md'
    foreach ($folder in @([IO.Path]::Combine($source, 'docs'), [IO.Path]::Combine($source, 'app', 'node_modules'), $config)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    Set-Content -LiteralPath ([IO.Path]::Combine($source, 'README.md')) -Value 'hello'
    Set-Content -LiteralPath ([IO.Path]::Combine($source, 'docs', $accented)) -Value 'v1'
    Set-Content -LiteralPath ([IO.Path]::Combine($source, 'app', 'node_modules', 'dep.js')) -Value 'rebuildable'
    $notes = [IO.Path]::Combine($source, 'notes.md')
    Set-Content -LiteralPath $notes -Value 'n'
    Copy-Item -Path ([IO.Path]::Combine($repo, 'config', 'excludes*.txt')) -Destination $config
    # 200 MB of disk image: MinimumFreeSpaceGB has to go.
    $settingsText = "@{`n    SourcePath = '$source'`n    DestinationRoot = '$volume/restic-twin'`n    MinimumFreeSpaceGB = 0`n    HotCopies = @(@{ Name = 'notes'; Files = @('$notes') })`n}`n"
    [IO.File]::WriteAllText([IO.Path]::Combine($config, 'settings.psd1'), $settingsText, (New-Object Text.UTF8Encoding($false)))
    # Your files, as they would be: this script runs as root.
    $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @('-R', "$($user.Name):staff", $work)
    $settings = Get-BackupSettings -ConfigPath ([IO.Path]::Combine($config, 'settings.psd1'))
    $installRoot = Get-InstallRoot
    $runsPath = [IO.Path]::Combine($settings.LogsPath, 'runs.jsonl')

    try {
        Write-Host '--- install, with sudo'
        Assert-That ((Invoke-Step 'install.ps1' @('-ConfigPath', $settings.ConfigPath)).ExitCode -eq 0) 'install.ps1 exits 0'
        Assert-That (Test-RootOnly -Path ([IO.Path]::Combine($installRoot, 'scripts', 'backup.ps1'))) 'the installed scripts, and every folder above them, belong to root and only root can write them'
        Assert-That (Test-RootOnly -Path ([IO.Path]::Combine($installRoot, 'bin', 'restic'))) 'the installed restic belongs to root and only root can write it'
        Assert-That (Test-RootOnly -Path $script:DailyPlist) 'the daemon plist belongs to root'
        $plist = [IO.File]::ReadAllText($script:DailyPlist)
        Assert-That ($plist.Contains("<string>$powershell</string>")) "the daily job runs the PowerShell installed for the whole Mac ($powershell)"
        Assert-That ($plist.Contains([IO.Path]::Combine($installRoot, 'scripts', 'backup.ps1')) -and $plist.Contains('<string>-IfDue</string>')) 'the daily job runs the installed copy, with -IfDue'
        Assert-That (Get-DailyJob).Loaded 'launchd loaded the daily job'
        foreach ($name in @('DestinationRoot', 'RepositoryPath', 'MirrorPath', 'ReportsPath', 'LogsPath', 'RecoveryPath')) {
            Assert-That (Test-PrivateFolderAcl -Path $settings[$name] -UserAccess Read -Owner -User $user) "$name belongs to root, mode 700, and $($user.Name) reads it through one inherited entry"
        }
        foreach ($name in @('HotCopiesPath', 'RestoresPath')) {
            Assert-That (Test-PrivateFolderAcl -Path $settings[$name] -UserAccess Full -User $user) "$name belongs to $($user.Name), mode 700"
        }
        $passwordMode = (@(Invoke-Checked -FilePath '/usr/bin/stat' -Arguments @('-f', '%Su %Lp', $settings.PasswordFile)) -join '').Trim()
        Assert-That ($passwordMode -eq 'root 400') "the password file is root's, mode 400 ($passwordMode)"
        $agentPlist = Get-HotCopyPlistPath -User $user
        $agentOwner = ''
        if (Test-Path -LiteralPath $agentPlist) { $agentOwner = (@(Invoke-Checked -FilePath '/usr/bin/stat' -Arguments @('-f', '%Su', $agentPlist)) -join '').Trim() }
        Assert-That ($agentOwner -eq $user.Name) "the hot copy agent is in $agentPlist and belongs to $($user.Name)"

        Write-Host '--- the daily job, as root under launchd'
        $job = Start-DailyJob
        $latestPath = [IO.Path]::Combine($settings.LogsPath, 'latest.json')
        if (Test-Path -LiteralPath $latestPath) { Get-Content -LiteralPath $latestPath | ForEach-Object { Write-Host "  | $_" } }
        Assert-That ($job.LastExit -eq '0') "the job's last exit code is 0 ($($job.LastExit))"
        $latest = [IO.File]::ReadAllText($latestPath) | ConvertFrom-Json
        Assert-That ($latest.status -eq 'success') 'latest.json says success'
        Assert-That ($latest.execution_identity -eq 'root') "the run was root's ($($latest.execution_identity))"
        Assert-That (Test-Path -LiteralPath ([IO.Path]::Combine($settings.MirrorPath, 'docs', $accented))) 'the mirror holds the accented file'
        Assert-That (-not (Test-Path -LiteralPath ([IO.Path]::Combine($settings.MirrorPath, 'app', 'node_modules')))) 'the mirror leaves node_modules out'
        Assert-That (@(Get-ChildItem -LiteralPath $settings.ReportsPath -Recurse -Filter 'baseline_*.md').Count -eq 1) 'a baseline report was written'
        $resticLog = Get-ChildItem -LiteralPath $settings.LogsPath -Filter 'restic-backup_*.jsonl' | Select-Object -First 1
        $summary = Get-Content -LiteralPath $resticLog.FullName | Where-Object { $_ -match '"message_type":"summary"' } | ConvertFrom-Json
        Assert-That ($summary.total_files_processed -eq 3) "the snapshot holds the 3 files ($($summary.total_files_processed))"
        $userCache = [IO.Path]::Combine((Get-UserHome -User $user), 'Library', 'Caches', 'restic')
        $cacheOwner = $user.Name
        if (Test-Path -LiteralPath $userCache) { $cacheOwner = (@(Invoke-Checked -FilePath '/usr/bin/stat' -Arguments @('-f', '%Su', $userCache)) -join '').Trim() }
        Assert-That ($cacheOwner -eq $user.Name) "root left nothing of its own in $userCache"

        Write-Host "--- what $($user.Name) may read and write"
        Assert-That ((Invoke-AsUser '/bin/cat' @($latestPath)).ExitCode -eq 0) 'the user reads the run record root wrote'
        $readme = Invoke-AsUser '/bin/cat' @([IO.Path]::Combine($settings.MirrorPath, 'README.md'))
        Assert-That ($readme.ExitCode -eq 0 -and ($readme.StdOut -join '') -eq 'hello') 'the user reads the mirror'
        Assert-That ((Invoke-AsUser '/bin/cat' @($settings.PasswordFile)).ExitCode -eq 0) 'the user reads the password, for restores'
        foreach ($name in @('LogsPath', 'MirrorPath', 'RepositoryPath', 'RecoveryPath')) {
            $probe = [IO.Path]::Combine($settings[$name], 'written-by-user')
            Assert-That ((Invoke-AsUser '/usr/bin/touch' @($probe)).ExitCode -ne 0 -and -not (Test-Path -LiteralPath $probe)) "the user cannot write in $name"
        }
        Assert-That ((Invoke-AsUser '/bin/rm' @('-f', $settings.PasswordFile)).ExitCode -ne 0 -and (Test-Path -LiteralPath $settings.PasswordFile)) 'the user cannot delete the password'
        $status = Invoke-Step 'status.ps1' @('-ConfigPath', $settings.ConfigPath) -AsUser
        Assert-That ($status.ExitCode -eq 0 -and ($status.StdOut -join "`n") -match 'Snapshots:\s+1') 'status.ps1, as the user, counts the snapshot in the history root owns'
        Assert-That (($status.StdOut -join "`n") -match 'Installed:\s+up to date') 'status.ps1 finds the installed copy up to date'
        Assert-That ((Invoke-Step 'restore.ps1' @('-ConfigPath', $settings.ConfigPath) -AsUser).ExitCode -eq 0) 'restore.ps1 runs as the user'
        $restored = @(Get-ChildItem -LiteralPath $settings.RestoresPath -Directory)
        Assert-That ($restored.Count -eq 1 -and (Get-Content -LiteralPath ([IO.Path]::Combine($restored[0].FullName, 'README.md'))) -eq 'hello') 'the restore lands in restores, byte for byte'
        Assert-That ((Invoke-Step 'hot-copy.ps1' @('-ConfigPath', $settings.ConfigPath) -AsUser).ExitCode -eq 0) 'hot-copy.ps1 runs as the user'
        Assert-That (@(Get-HotCopyVersions -SetPath ([IO.Path]::Combine($settings.HotCopiesPath, 'notes'))).Count -ge 1) 'a hot copy of notes.md is there'

        Write-Host '--- the hourly start, with today already done (-IfDue)'
        $runsBefore = @([IO.File]::ReadAllLines($runsPath)).Count
        $job = Start-DailyJob
        Assert-That ($job.LastExit -eq '0') "the job exits 0 ($($job.LastExit))"
        Assert-That (@([IO.File]::ReadAllLines($runsPath)).Count -eq $runsBefore) 'and records no new run'

        Write-Host '--- the backup drive unplugged'
        Dismount-TestVolume
        $job = Start-DailyJob
        Assert-That ($job.LastExit -eq '1') "the job fails ($($job.LastExit))"
        Assert-That (-not (Test-Path -LiteralPath $volume)) "nothing created $volume on the boot disk"
        Assert-That ([IO.File]::ReadAllText($errorsLog) -match 'is not connected') 'its error says the drive is not connected'

        Write-Host "--- a leftover $volume folder on the boot disk"
        New-Item -ItemType Directory -Path $volume | Out-Null
        try {
            $job = Start-DailyJob
            Assert-That ($job.LastExit -eq '1') "the job fails ($($job.LastExit))"
            Assert-That (@(Get-ChildItem -LiteralPath $volume -Force).Count -eq 0) 'and writes nothing into that folder'
            Assert-That ([IO.File]::ReadAllText($errorsLog) -match 'not a mounted drive') 'its error says the folder is not a mounted drive'
        }
        finally {
            Remove-Item -LiteralPath $volume -Recurse -Force
        }
    }
    finally {
        Write-Host '--- uninstall'
        if (-not (Test-Path -LiteralPath $volume)) {
            try { Mount-TestVolume } catch { Write-Host "  | could not mount the disk image again: $($_.Exception.Message)" }
        }
        $uninstall = Invoke-Step 'uninstall.ps1'
    }
    Assert-That ($uninstall.ExitCode -eq 0) 'uninstall.ps1 exits 0'
    Assert-That (-not (Get-DailyJob).Loaded) 'launchd no longer has the daily job'
    Assert-That (-not (Test-Path -LiteralPath $script:DailyPlist)) 'the daemon plist is gone'
    Assert-That (-not (Test-Path -LiteralPath (Get-HotCopyPlistPath -User $user))) 'the hot copy agent is gone'
    Assert-That (-not (Test-Path -LiteralPath $installRoot)) 'the installed copy is gone'
    Assert-That (Test-Path -LiteralPath ([IO.Path]::Combine($settings.RepositoryPath, 'config'))) 'the backups are still there'
}
finally {
    Write-Host '--- teardown'
    if (Test-Path -LiteralPath $volume) {
        # -force: an earlier failure may leave a file open on the volume, and a plain detach would hang.
        $detach = Invoke-NativeCapture -FilePath '/usr/bin/hdiutil' -Arguments @('detach', $volume, '-force')
        if ($detach.ExitCode -ne 0) { Write-Host "  | could not detach ${volume}: $($detach.StdErr -join ' ')" }
    }
    foreach ($leftover in @($image, $work)) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
