# CI only. Installs restic-twin for real on a throwaway Windows machine, runs the daily task as SYSTEM
# (with VSS), checks the result and uninstalls. It registers scheduled tasks and writes to Program
# Files: never run it on a computer you care about.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\common.ps1')

if (-not (Test-IsAdministrator)) { throw 'This script needs an elevated shell (it is meant for CI runners).' }
if ($env:GITHUB_ACTIONS -ne 'true' -and $env:RESTIC_TWIN_ALLOW_SYSTEM_INSTALL -ne '1') {
    throw 'Refusing to run outside GitHub Actions. Set RESTIC_TWIN_ALLOW_SYSTEM_INSTALL=1 on a throwaway machine.'
}

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "ok: $Message"
}

function Invoke-Step {
    param([string]$Script, [string[]]$Arguments = @())
    $result = Invoke-NativeCapture -FilePath (Get-TaskPowerShellPath) -Arguments (@('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo "scripts\$Script")) + $Arguments)
    ($result.StdOut + $result.StdErr) | ForEach-Object { Write-Host "  | $_" }
    return $result.ExitCode
}

$work = 'C:\restic-twin-ci'
$destinationRoot = 'C:\restic-twin-ci-dest'
if (Test-Path -LiteralPath 'D:\' -PathType Container) { $destinationRoot = 'D:\restic-twin-ci-dest' }
$source = Join-Path $work ('Projetos-' + [char]0x00E7 + [char]0x00E3 + 'o')
$config = Join-Path $work 'cfg'
New-Item -ItemType Directory -Path (Join-Path $source 'docs'), (Join-Path $source 'app\node_modules'), $config -Force | Out-Null
Set-Content -LiteralPath (Join-Path $source 'README.md') -Value 'hello'
Set-Content -LiteralPath (Join-Path $source ('docs\relat' + [char]0x00F3 + 'rio.md')) -Value 'v1'
Set-Content -LiteralPath (Join-Path $source 'app\node_modules\dep.js') -Value 'rebuildable'
$notes = Join-Path $source 'notes.md'
Set-Content -LiteralPath $notes -Value 'n'
Copy-Item -Path (Join-Path $repo 'config\excludes*.txt') -Destination $config
$settingsText = "@{`r`n    SourcePath = '$source'`r`n    DestinationRoot = '$destinationRoot'`r`n    MinimumFreeSpaceGB = 1`r`n    HotCopies = @(@{ Name = 'notes'; Files = @('$notes') })`r`n}`r`n"
[IO.File]::WriteAllText((Join-Path $config 'settings.psd1'), $settingsText, (New-Object Text.UTF8Encoding($false)))
$settings = Get-BackupSettings -ConfigPath (Join-Path $config 'settings.psd1')
$installRoot = Get-InstallRoot

try {
    Write-Host '--- install'
    Assert-That ((Invoke-Step 'install.ps1' @('-ConfigPath', $settings.ConfigPath)) -eq 0) 'install.ps1 exits 0'
    Assert-That (Test-Path -LiteralPath (Join-Path $installRoot 'scripts\backup.ps1')) 'the scripts were copied to Program Files'
    Assert-That (Test-Path -LiteralPath (Join-Path $installRoot 'bin\restic.exe')) 'restic.exe was copied to Program Files'
    $daily = Get-ScheduledTask -TaskName $script:DailyTaskName
    Assert-That ($daily.Principal.UserId -match 'SYSTEM') "the daily task runs as SYSTEM ($($daily.Principal.UserId))"
    Assert-That ($daily.Actions[0].Execute -like "$env:ProgramFiles*" -or $daily.Actions[0].Execute -like "$env:WINDIR*") "the daily task runs a machine-wide PowerShell ($($daily.Actions[0].Execute))"
    Assert-That ($daily.Actions[0].Arguments -like "*$installRoot\scripts\backup.ps1*") 'the daily task runs the installed copy'
    $hot = Get-ScheduledTask -TaskName $script:HotCopyTaskName
    Assert-That ($hot.Actions[0].Execute -like '*wscript.exe') 'the hot copy task starts through wscript.exe'
    foreach ($name in @('DestinationRoot', 'RepositoryPath', 'MirrorPath', 'ReportsPath', 'LogsPath', 'RecoveryPath')) {
        Assert-That (Test-PrivateFolderAcl -Path $settings[$name] -UserAccess Read -Owner) "$name is owned by Administrators and read-only for the user"
    }
    foreach ($name in @('HotCopiesPath', 'RestoresPath')) {
        Assert-That (Test-PrivateFolderAcl -Path $settings[$name] -UserAccess Full) "$name stays writable for the user"
    }

    Write-Host '--- the daily task, as SYSTEM, with VSS'
    $before = (Get-ScheduledTaskInfo -TaskName $script:DailyTaskName).LastRunTime
    Start-ScheduledTask -TaskName $script:DailyTaskName
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 5
        $info = Get-ScheduledTaskInfo -TaskName $script:DailyTaskName
        $state = (Get-ScheduledTask -TaskName $script:DailyTaskName).State
    } while (((Get-Date) -lt $deadline) -and ($state -eq 'Running' -or $info.LastRunTime -eq $before))
    $latestPath = Join-Path $settings.LogsPath 'latest.json'
    if (Test-Path -LiteralPath $latestPath) { Get-Content -LiteralPath $latestPath | ForEach-Object { Write-Host "  | $_" } }
    Assert-That ($info.LastTaskResult -eq 0) "the task's last result is 0 ($($info.LastTaskResult))"
    $latest = [IO.File]::ReadAllText($latestPath) | ConvertFrom-Json
    Assert-That ($latest.status -eq 'success') 'latest.json says success'
    Assert-That ($latest.execution_identity -match 'SYSTEM|S-1-5-18') "the run was SYSTEM's ($($latest.execution_identity))"
    Assert-That (Test-Path -LiteralPath (Join-Path $settings.MirrorPath ('docs\relat' + [char]0x00F3 + 'rio.md'))) 'the mirror holds the accented file'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $settings.MirrorPath 'app\node_modules'))) 'the mirror leaves node_modules out'
    Assert-That (@(Get-ChildItem -LiteralPath $settings.ReportsPath -Recurse -Filter 'baseline_*.md').Count -eq 1) 'a baseline report was written'
    $resticLog = Get-ChildItem -LiteralPath $settings.LogsPath -Filter 'restic-backup_*.jsonl' | Select-Object -First 1
    $summary = Get-Content -LiteralPath $resticLog.FullName | Where-Object { $_ -match '"message_type":"summary"' } | ConvertFrom-Json
    Assert-That ($summary.total_files_processed -eq 3) "the snapshot holds the 3 files ($($summary.total_files_processed))"

    Write-Host '--- status, elevated'
    Assert-That ((Invoke-Step 'status.ps1' @('-ConfigPath', $settings.ConfigPath)) -eq 0) 'status.ps1 exits 0'
}
finally {
    Write-Host '--- uninstall'
    $uninstallExit = Invoke-Step 'uninstall.ps1'
}
Assert-That ($uninstallExit -eq 0) 'uninstall.ps1 exits 0'
Assert-That (-not (Get-ScheduledTask -TaskName $script:DailyTaskName -ErrorAction SilentlyContinue)) 'the daily task is gone'
Assert-That (-not (Get-ScheduledTask -TaskName $script:HotCopyTaskName -ErrorAction SilentlyContinue)) 'the hot copy task is gone'
Assert-That (-not (Test-Path -LiteralPath $installRoot)) 'the Program Files copy is gone'
Assert-That (Test-Path -LiteralPath (Join-Path $settings.RepositoryPath 'config')) 'the backups are still there'
