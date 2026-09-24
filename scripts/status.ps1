[CmdletBinding()]
param(
    [string]$ConfigPath
)

# What happened in the last run, when the next one is, and whether anything needs you.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')
Enable-Utf8NativeOutput

$settings = Get-BackupSettings -ConfigPath $ConfigPath

Write-Host "Source:        $($settings.SourcePath)"
Write-Host "Mirror:        $($settings.MirrorPath)"
Write-Host "History:       $($settings.RepositoryPath)"
Write-Host "Schedule:      every day at $($settings.DailyAt)"

$destinationDrive = [IO.Path]::GetPathRoot($settings.DestinationRoot)
$driveReady = Test-Path -LiteralPath $destinationDrive -PathType Container
if (-not $driveReady) {
    Write-Host "Destination:   drive $destinationDrive is not available; plug it in to see the last runs" -ForegroundColor Red
}
else {
    $latestPath = [IO.Path]::Combine($settings.LogsPath, 'latest.json')
    if (Test-Path -LiteralPath $latestPath -PathType Leaf) {
        $latest = [IO.File]::ReadAllText($latestPath) | ConvertFrom-Json
        Write-Host "Last run:      $($latest.status), started $($latest.started_at), finished $($latest.finished_at)"
        if ($latest.current_snapshot) { Write-Host "Snapshot:      $($latest.current_snapshot)" }
        if ($latest.error) { Write-Host "Error:         $($latest.error)" -ForegroundColor Red }
    }
    else {
        Write-Host 'Last run:      none yet' -ForegroundColor Yellow
    }

    $runsPath = [IO.Path]::Combine($settings.LogsPath, 'runs.jsonl')
    $lastSuccess = $null
    if (Test-Path -LiteralPath $runsPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($runsPath)) {
            if ($line -notmatch '"status"\s*:\s*"success"') { continue }
            try {
                # PowerShell 7 turns ISO dates in JSON into DateTime by itself, 5.1 leaves them as text.
                $finished = ($line | ConvertFrom-Json).finished_at
                if ($finished -is [datetime]) { $lastSuccess = [DateTimeOffset]$finished }
                else { $lastSuccess = [DateTimeOffset]::Parse([string]$finished, [Globalization.CultureInfo]::InvariantCulture) }
            }
            catch { }
        }
        if ($lastSuccess) {
            $age = [DateTimeOffset]::Now - $lastSuccess
            $color = 'Gray'
            if ($age.TotalHours -gt 48) { $color = 'Red' }
            Write-Host ([string]::Format([Globalization.CultureInfo]::InvariantCulture, 'Last success:  {0:yyyy-MM-dd HH:mm} ({1:0.#} days ago)', $lastSuccess.LocalDateTime, $age.TotalDays)) -ForegroundColor $color
        }
        else {
            Write-Host 'Last success:  never' -ForegroundColor Red
        }
    }

    if ((Test-Path -LiteralPath $settings.ResticPath) -and (Test-Path -LiteralPath $settings.PasswordFile) -and (Test-Path -LiteralPath ([IO.Path]::Combine($settings.RepositoryPath, 'config')))) {
        try {
            Write-Host "Snapshots:     $(@(Get-ResticSnapshots -Settings $settings -ReadOnly).Count)"
        }
        catch {
            Write-Host "Snapshots:     could not list them: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    foreach ($set in $settings.HotCopies) {
        $versions = @(Get-HotCopyVersions -SetPath ([IO.Path]::Combine($settings.HotCopiesPath, $set.Name)))
        if ($versions.Count -gt 0) {
            Write-Host "Hot copy:      $($set.Name), $($versions.Count) kept, newest $($versions[-1].Name)"
        }
        else {
            Write-Host "Hot copy:      $($set.Name), none yet" -ForegroundColor Yellow
        }
    }
}

foreach ($name in @($script:DailyTaskName, $script:HotCopyTaskName)) {
    try {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $name
        Write-Host "Task:          '$name' $($task.State), next $($info.NextRunTime), last result $($info.LastTaskResult)"
    }
    catch {
        # A task that runs as SYSTEM cannot be read from a shell that is not elevated.
        if ($name -eq $script:DailyTaskName) {
            Write-Host "Task:          '$name' not readable from this shell (run elevated), or not installed" -ForegroundColor Yellow
        }
    }
}

$installRoot = Get-InstallRoot
if (-not $settings.ProjectRoot.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $installRoot)) {
    $different = @(Get-InstalledFileDifferences -Settings $settings)
    if ($different.Count -gt 0) {
        Write-Host "Installed:     the scheduled tasks run an older copy ($($different.Count) file(s) differ). Run scripts\install.ps1 again, elevated." -ForegroundColor Yellow
    }
    else {
        Write-Host 'Installed:     up to date with this folder'
    }
}
