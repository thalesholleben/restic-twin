[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipScheduledTask
)

# Prepares the destination (folders, password, restic repository, recovery notes) and registers
# the scheduled tasks. Safe to run again after changing settings: it never replaces a password,
# never re-creates a repository and never touches the history.
#
# The tasks run a copy of this folder installed under Program Files, not this folder itself: the
# daily task runs as SYSTEM, and code in your profile can be changed by anything running as you.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$settings = Get-BackupSettings -ConfigPath $ConfigPath

if (-not $SkipScheduledTask -and -not (Test-IsAdministrator)) {
    throw 'Run install from an elevated PowerShell: the daily task runs as SYSTEM and uses VSS. Pass -SkipScheduledTask to only prepare the folders and the repository.'
}
if (-not (Test-Path -LiteralPath $settings.ResticPath -PathType Leaf)) {
    Write-Host 'restic is not installed yet; installing the pinned version.'
    & (Join-Path $PSScriptRoot 'install-restic.ps1')
}
if (-not (Test-Path -LiteralPath $settings.SourcePath -PathType Container)) {
    throw "Source folder not found: $($settings.SourcePath)"
}
$destinationDrive = [IO.Path]::GetPathRoot($settings.DestinationRoot)
if (-not (Test-Path -LiteralPath $destinationDrive -PathType Container)) {
    throw "Destination drive $destinationDrive is not available."
}

$sourceDisk = Get-DiskNumber -Path $settings.SourcePath
$destinationDisk = Get-DiskNumber -Path $settings.DestinationRoot
if ($null -ne $sourceDisk -and $sourceDisk -eq $destinationDisk) {
    Write-Warning "SourcePath and DestinationRoot are on the same physical disk (disk $sourceDisk). The history still protects you from deleting or overwriting files, but not from that disk failing."
}

# Who may write each folder. With the tasks installed, SYSTEM is the only writer of what it reads
# back (history, mirror, reports, logs, recovery, and the destination above them): your account only
# reads those, and Administrators own them. You keep full control of what you write yourself, the
# hot copies and the restores. Without the tasks (-SkipScheduledTask) you run the backups, so you
# keep full control of everything, as before.
$systemTask = -not $SkipScheduledTask
$systemAccess = 'Full'
if ($systemTask) { $systemAccess = 'Read' }
$folders = New-Object Collections.Generic.List[object]
$rootIsDrive = $settings.DestinationRoot.Length -le 3
if (-not $rootIsDrive) {
    $managedNames = @($script:ManagedFolders.Values)
    $foreign = @()
    if (Test-Path -LiteralPath $settings.DestinationRoot) {
        $foreign = @(Get-ChildItem -LiteralPath $settings.DestinationRoot -Force | Where-Object { $managedNames -notcontains $_.Name })
    }
    if ($foreign.Count -eq 0) {
        $folders.Add(@{ Path = $settings.DestinationRoot; Access = $systemAccess })
    }
    elseif ($systemTask) {
        Write-Warning "$($settings.DestinationRoot) also holds other files, so it is left as it is. Anything running as your account may be able to rename or delete the backup folders inside it; a folder of their own is safer."
    }
}
foreach ($name in @('MirrorPath', 'RepositoryPath', 'ReportsPath', 'LogsPath', 'RecoveryPath')) {
    $folders.Add(@{ Path = $settings[$name]; Access = $systemAccess })
}
foreach ($name in @('HotCopiesPath', 'RestoresPath')) {
    $folders.Add(@{ Path = $settings[$name]; Access = 'Full' })
}
$passwordFolder = Split-Path -Parent $settings.PasswordFile
if (-not (Test-Path -LiteralPath $passwordFolder) -and @($folders | Where-Object { $_.Path -eq $passwordFolder }).Count -eq 0) {
    $folders.Add(@{ Path = $passwordFolder; Access = $systemAccess })
}
# Every folder gets its permissions whether it was just created or already there: an empty mirror
# someone made earlier would otherwise be adopted with the drive's permissions.
foreach ($folder in $folders) {
    if (-not (Test-Path -LiteralPath $folder.Path)) {
        New-Item -ItemType Directory -Path $folder.Path -Force | Out-Null
    }
    $owner = $systemTask -and $folder.Access -eq 'Read'
    if (Test-PrivateFolderAcl -Path $folder.Path -UserAccess $folder.Access -Owner:$owner) { continue }
    try {
        Set-PrivateFolderAcl -Path $folder.Path -UserAccess $folder.Access -Owner:$owner
    }
    catch {
        if ($systemTask) { throw }
        throw "Could not set the permissions of $($folder.Path): $($_.Exception.Message) If an elevated install gave it to Administrators, run install.ps1 elevated and without -SkipScheduledTask."
    }
}
Assert-MirrorTarget -MirrorPath $settings.MirrorPath -SourcePath $settings.SourcePath

$repositoryExists = Test-Path -LiteralPath (Join-Path $settings.RepositoryPath 'config') -PathType Leaf
$newPassword = $false
if (-not (Test-Path -LiteralPath $settings.PasswordFile -PathType Leaf)) {
    if ($repositoryExists) {
        throw "There is a restic repository at $($settings.RepositoryPath) but no password file at $($settings.PasswordFile). Put the password file back from your offline copy and run install again: a new password would not open the existing history."
    }
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    Write-Utf8NoBom -Path $settings.PasswordFile -Content ([Convert]::ToBase64String($bytes))
    $newPassword = $true
}
if (-not (Set-PasswordFileAcl -Path $settings.PasswordFile)) {
    if ($newPassword) { throw "Could not restrict the permissions of $($settings.PasswordFile)." }
    Write-Warning "Could not restrict the permissions of $($settings.PasswordFile). Make sure only you, SYSTEM and Administrators can read it."
}

if (-not $repositoryExists) {
    $init = Invoke-NativeCapture -FilePath $settings.ResticPath -Arguments ((Get-ResticBaseArguments -Settings $settings) + @('init'))
    if ($init.ExitCode -ne 0) {
        throw "restic init failed (exit code $($init.ExitCode)): $($init.StdErr -join ' ')"
    }
    Write-Host "Created the restic repository at $($settings.RepositoryPath)."
}

$installRoot = Get-InstallRoot
$sourceInSnapshot = '/' + $settings.SourcePath.Replace(':', '').Replace('\', '/').TrimEnd('/')
$recovery = @"
restic-twin recovery notes

Source:        $($settings.SourcePath)
History:       $($settings.RepositoryPath)
Password file: $($settings.PasswordFile)
Mirror:        $($settings.MirrorPath)
Installed at:  $installRoot

Keep a copy of the password file somewhere other than this drive, a password manager is fine.
Without it nobody can decrypt the history, including you.

The mirror is a plain copy of the latest backup: open it in Explorer.
Do not edit anything inside the history folder by hand.

On another computer, download restic from https://github.com/restic/restic/releases and run:

restic --repo "$($settings.RepositoryPath)" --password-file "<password file>" snapshots
restic --repo "$($settings.RepositoryPath)" --password-file "<password file>" restore latest:$sourceInSnapshot --target "<an empty folder>"

A read-only copy of the history (another drive, a share) needs --no-lock as well.
"@
Write-Utf8NoBom -Path (Join-Path $settings.RecoveryPath 'README.txt') -Content ($recovery.Replace("`r`n", "`n").Replace("`n", "`r`n") + "`r`n")

if (-not $SkipScheduledTask) {
    Import-Module ScheduledTasks
    # Replacing the installed scripts under a running backup or hot copy would change them mid-run.
    $backupLock = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings $settings)
    $hotCopyLock = Enter-RunLock -Name (Get-RunLockName -Kind hot-copy -Settings $settings)
    try {
        if ($null -eq $backupLock -or $null -eq $hotCopyLock) {
            throw 'A backup or a hot copy is running right now. Run install again when it finishes.'
        }
        if (-not $settings.ProjectRoot.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($folder in @('scripts', 'config', 'bin')) {
                New-Item -ItemType Directory -Path (Join-Path $installRoot $folder) -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $settings.ProjectRoot 'scripts\*') -Include '*.ps1', '*.vbs' -Destination (Join-Path $installRoot 'scripts') -Force
            Copy-Item -LiteralPath $settings.ConfigPath -Destination (Join-Path $installRoot 'config\settings.psd1') -Force
            foreach ($file in @($settings.ExcludesPath, $settings.MirrorExcludesPath)) {
                if (Test-Path -LiteralPath $file -PathType Leaf) { Copy-Item -LiteralPath $file -Destination (Join-Path $installRoot 'config') -Force }
            }
            Copy-Item -LiteralPath $settings.ResticPath -Destination (Join-Path $installRoot 'bin\restic.exe') -Force
        }

        $powershell = Get-TaskPowerShellPath
        $dailyAction = New-ScheduledTaskAction -Execute $powershell -WorkingDirectory $installRoot `
            -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $installRoot 'scripts\backup.ps1'))
        $dailySettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)
        Register-ScheduledTask -TaskName $script:DailyTaskName -Force `
            -Action $dailyAction `
            -Trigger (New-ScheduledTaskTrigger -Daily -At $settings.DailyAt) `
            -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
            -Settings $dailySettings `
            -Description "restic-twin: encrypted snapshot, change report and mirror of $($settings.SourcePath)." | Out-Null
        Write-Host "Registered '$($script:DailyTaskName)': every day at $($settings.DailyAt), as SYSTEM, and at the next start if the PC was off."

        $hotCopyTask = Get-ScheduledTask -TaskName $script:HotCopyTaskName -ErrorAction SilentlyContinue
        if ($settings.HotCopies.Count -gt 0) {
            $hotCopyArguments = '//B //Nologo "{0}" "{1}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{2}"' -f `
            (Join-Path $installRoot 'scripts\run-hidden.vbs'), $powershell, (Join-Path $installRoot 'scripts\hot-copy.ps1')
            $hotCopySettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $script:HotCopyTaskName -Force `
                -Action (New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument $hotCopyArguments -WorkingDirectory $installRoot) `
                -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $settings.HotCopyEveryMinutes)) `
                -Principal (New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited) `
                -Settings $hotCopySettings `
                -Description 'restic-twin: frequent plain copies of the files listed in HotCopies.' | Out-Null
            Write-Host "Registered '$($script:HotCopyTaskName)': every $($settings.HotCopyEveryMinutes) minutes while you are signed in."
        }
        elseif ($hotCopyTask) {
            Unregister-ScheduledTask -TaskName $script:HotCopyTaskName -Confirm:$false
            Write-Host "Removed '$($script:HotCopyTaskName)': HotCopies is empty."
        }

        $taskRecord = @(foreach ($name in @($script:DailyTaskName, $script:HotCopyTaskName)) {
                $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                if ($task) {
                    $next = (Get-ScheduledTaskInfo -TaskName $name).NextRunTime
                    if ($next) { $next = $next.ToString('o') }
                    [ordered]@{
                        task_name     = $name
                        user_id       = $task.Principal.UserId
                        execute       = $task.Actions[0].Execute
                        arguments     = $task.Actions[0].Arguments
                        next_run_time = $next
                    }
                }
            })
        $recordJson = ConvertTo-Json -InputObject ([ordered]@{ validated_at = (Get-Date).ToString('o'); tasks = $taskRecord }) -Depth 4
        Write-Utf8NoBom -Path (Join-Path $settings.LogsPath 'scheduled-task.json') -Content ($recordJson + "`n")
    }
    finally {
        Exit-RunLock $hotCopyLock
        Exit-RunLock $backupLock
    }
}

Write-Host ''
Write-Host "History: $($settings.RepositoryPath)"
Write-Host "Mirror:  $($settings.MirrorPath)"
if ($newPassword) {
    Write-Warning "A new password was created in $($settings.PasswordFile). Copy it to a password manager now: without it the history cannot be restored."
}
if (-not $SkipScheduledTask) {
    Write-Host "First backup now, instead of waiting for $($settings.DailyAt):"
    Write-Host "  & '$(Join-Path $installRoot 'scripts\backup.ps1')'"
}
