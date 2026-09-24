[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NoVss,
    [switch]$SkipMirror,
    [switch]$SkipMaintenance
)

# The daily run: snapshot, change report, then the mirror, then retention. The order matters: the
# history is written before the mirror, so a deletion you did today is still in yesterday's snapshot.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')
Enable-Utf8NativeOutput

$settings = Get-BackupSettings -ConfigPath $ConfigPath
$lock = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings $settings)
if ($null -eq $lock) {
    Write-Host 'Another backup is running. Nothing to do.'
    exit 0
}

$runId = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$startedAt = Get-Date
$status = 'running'
$errorMessage = $null
$previousSnapshotId = $null
$currentSnapshotId = $null
$resticExitCode = $null
$robocopyExitCode = $null
$unreadableCount = 0

function Invoke-Maintenance {
    $baseArguments = Get-ResticBaseArguments -Settings $settings
    $forgetLog = Join-Path $settings.LogsPath "retention_$runId.json"
    $forgetArguments = $baseArguments + @('--json', 'forget', '--tag', $script:ResticTag, '--keep-daily', $settings.KeepDaily, '--keep-monthly', $settings.KeepMonthly)
    $code = Invoke-NativeLogged -FilePath $settings.ResticPath -Arguments $forgetArguments -OutputPath $forgetLog
    if ($code -ne 0) { throw "restic forget failed with exit code $code. See $forgetLog" }

    # Weekly by elapsed time, not by weekday: a PC that is always off on Sundays would never prune.
    $stampPath = Join-Path $settings.LogsPath 'last-maintenance.txt'
    $last = $null
    if (Test-Path -LiteralPath $stampPath -PathType Leaf) {
        try { $last = [DateTimeOffset]::Parse(([IO.File]::ReadAllText($stampPath)).Trim(), [Globalization.CultureInfo]::InvariantCulture) } catch { $last = $null }
    }
    if ($null -ne $last -and ([DateTimeOffset]::Now - $last).TotalDays -lt 7) { return }

    foreach ($command in @('prune', 'check')) {
        $log = Join-Path $settings.LogsPath "${command}_$runId.log"
        $code = Invoke-NativeLogged -FilePath $settings.ResticPath -Arguments ($baseArguments + @($command)) -OutputPath $log
        if ($code -ne 0) { throw "restic $command failed with exit code $code. See $log" }
    }
    Write-Utf8NoBom -Path $stampPath -Content ([DateTimeOffset]::Now.ToString('o', [Globalization.CultureInfo]::InvariantCulture) + "`n")
}

try {
    $destinationDrive = [IO.Path]::GetPathRoot($settings.DestinationRoot)
    if (-not (Test-Path -LiteralPath $destinationDrive -PathType Container)) {
        throw "Destination drive $destinationDrive is not available."
    }
    if (-not (Test-Path -LiteralPath $settings.SourcePath -PathType Container)) {
        throw "Source folder not found: $($settings.SourcePath)"
    }
    if (-not (Test-Path -LiteralPath $settings.ResticPath -PathType Leaf)) {
        throw "restic not found at $($settings.ResticPath). Run scripts\install-restic.ps1."
    }
    if (-not (Test-Path -LiteralPath $settings.ExcludesPath -PathType Leaf)) {
        throw "Exclude list not found: $($settings.ExcludesPath)"
    }
    if (-not (Test-Path -LiteralPath $settings.PasswordFile -PathType Leaf)) {
        throw "Password file not found: $($settings.PasswordFile)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $settings.RepositoryPath 'config') -PathType Leaf)) {
        throw "No restic repository at $($settings.RepositoryPath). Run scripts\install.ps1 first."
    }
    if (-not $NoVss -and -not (Test-IsAdministrator)) {
        throw 'VSS snapshots need an elevated shell. Run this from an elevated PowerShell, or pass -NoVss (files held open by other programs may then be skipped).'
    }
    $patterns = @(Get-ExcludePatterns -Path $settings.ExcludesPath)
    # Only install.ps1 creates these, with their permissions. Created here they would inherit the
    # drive's, and as SYSTEM this run could not even grant your account access to them.
    $needed = @('LogsPath', 'ReportsPath')
    if (-not $SkipMirror) { $needed += 'MirrorPath' }
    foreach ($name in $needed) {
        if (-not (Test-Path -LiteralPath $settings[$name] -PathType Container)) {
            throw "$($settings[$name]) is missing. Run scripts\install.ps1 again: it creates it with the right permissions."
        }
    }

    $script:LogFile = Join-Path $settings.LogsPath "backup_$runId.log"
    $resticExcludes = Join-Path $settings.LogsPath 'restic-excludes.txt'
    Write-Utf8NoBom -Path $resticExcludes -Content ((@(Get-ResticExcludeLines -SourcePath $settings.SourcePath -Patterns $patterns) -join "`n") + "`n")

    $free = (New-Object IO.DriveInfo($destinationDrive)).AvailableFreeSpace
    if ($free -lt [long]($settings.MinimumFreeSpaceGB * 1GB)) {
        throw "Only $([math]::Round($free / 1GB, 1)) GB free on $destinationDrive, below MinimumFreeSpaceGB ($($settings.MinimumFreeSpaceGB))."
    }

    Write-Log -Message "Backup started. Source: $($settings.SourcePath)"
    $statePath = Join-Path $settings.LogsPath 'last-successful-snapshot.txt'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $previousSnapshotId = ([IO.File]::ReadAllText($statePath)).Trim()
        # It becomes an argument of a restic command run as SYSTEM: anything but a snapshot id, like
        # "--password-command=...", would be a flag. A bad value just starts a new baseline.
        if ($previousSnapshotId -notmatch '^[0-9a-f]{64}$') {
            if ($previousSnapshotId) { Write-Log -Level WARN -Message "Ignoring $statePath, it does not hold a snapshot id; starting a new baseline." }
            $previousSnapshotId = $null
        }
    }
    if ($previousSnapshotId) { Write-Log -Message "Previous snapshot: $previousSnapshotId" }

    $backupArguments = (Get-ResticBaseArguments -Settings $settings) + @(
        '--json', 'backup', $settings.SourcePath,
        '--tag', $script:ResticTag,
        '--iexclude-file', $resticExcludes
    )
    if (-not $NoVss) { $backupArguments += '--use-fs-snapshot' }
    $resticLog = Join-Path $settings.LogsPath "restic-backup_$runId.jsonl"
    $resticExitCode = Invoke-NativeLogged -FilePath $settings.ResticPath -Arguments $backupArguments -OutputPath $resticLog

    $backup = Read-ResticBackupLog -Lines ([IO.File]::ReadAllLines($resticLog))
    $currentSnapshotId = $backup.SnapshotId
    $unreadableCount = $backup.Unreadable.Count
    if ($resticExitCode -eq 3) {
        # restic saved a snapshot but skipped what it could not read. That is not a backup you can
        # trust blindly, so the run fails, and says exactly which items to exclude or fix.
        $shown = @($backup.Unreadable | Select-Object -First 5) -join '; '
        throw "Snapshot $currentSnapshotId was saved, but restic could not read $unreadableCount item(s): $shown. Exclude them in config\excludes.txt or fix their permissions. Full list in $resticLog"
    }
    if ($resticExitCode -ne 0) {
        throw "restic backup failed with exit code $resticExitCode. See $resticLog"
    }
    if ($currentSnapshotId -notmatch '^[0-9a-f]{64}$') {
        throw "restic finished without reporting a snapshot id. See $resticLog"
    }
    Write-Log -Message "New snapshot: $currentSnapshotId"

    if ($previousSnapshotId) {
        New-ChangeReport -Settings $settings -RunId $runId -StartedAt $startedAt -PreviousId $previousSnapshotId -CurrentId $currentSnapshotId
    }
    else {
        New-BaselineReport -Settings $settings -RunId $runId -StartedAt $startedAt -CurrentId $currentSnapshotId
    }
    Write-Utf8NoBom -Path $statePath -Content ($currentSnapshotId + "`n")

    if (-not $SkipMirror) {
        $robocopyExitCode = Update-Mirror -Settings $settings -LogPath (Join-Path $settings.LogsPath "robocopy_$runId.log")
    }
    if (-not $SkipMaintenance) {
        Invoke-Maintenance
    }

    $status = 'success'
    Write-Log -Message 'Backup finished.'
}
catch {
    $status = 'failed'
    $errorMessage = $_.Exception.Message
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    if ($inner -is [UnauthorizedAccessException] -and -not (Test-IsAdministrator)) {
        $errorMessage += ' Once the tasks are installed only SYSTEM and Administrators can write to the backup folders: run it from an elevated PowerShell.'
    }
    try { Write-Log -Level ERROR -Message $errorMessage } catch { [Console]::Error.WriteLine($errorMessage) }
}
finally {
    $finishedAt = Get-Date
    if (Test-Path -LiteralPath $settings.LogsPath -PathType Container) {
        try {
            $record = [ordered]@{
                run_id             = $runId
                execution_identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                started_at         = $startedAt.ToString('o')
                finished_at        = $finishedAt.ToString('o')
                duration_seconds   = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
                status             = $status
                source             = $settings.SourcePath
                previous_snapshot  = $previousSnapshotId
                current_snapshot   = $currentSnapshotId
                restic_exit_code   = $resticExitCode
                unreadable_items   = $unreadableCount
                robocopy_exit_code = $robocopyExitCode
                error              = $errorMessage
            }
            Add-Utf8Line -Path (Join-Path $settings.LogsPath 'runs.jsonl') -Line ($record | ConvertTo-Json -Compress)
            Write-Utf8NoBom -Path (Join-Path $settings.LogsPath 'latest.json') -Content (($record | ConvertTo-Json) + "`n")
        }
        catch {
            Write-Warning "Could not write the run record: $($_.Exception.Message)"
        }
    }
    Exit-RunLock $lock
}

if ($status -eq 'success') { exit 0 }
exit 1
