[CmdletBinding()]
param(
    [string]$ConfigPath
)

# Frequent plain copies of a few files that change all day, between two daily snapshots. Each set
# of files is copied together into a timestamped folder, only when one of them changed, and only
# the newest N folders are kept. Runs as you, every few minutes, from its own scheduled task.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$settings = Get-BackupSettings -ConfigPath $ConfigPath
if ($settings.HotCopies.Count -eq 0) {
    Write-Output 'No hot copies configured.'
    exit 0
}
if (-not (Test-Path -LiteralPath $settings.HotCopiesPath -PathType Container)) {
    # Only install.ps1 creates it, with its permissions; created here it would inherit the drive's.
    throw "$($settings.HotCopiesPath) is missing. Run $(Show-Path 'scripts\install.ps1') again: it creates it with the right permissions."
}
$lock = Enter-RunLock -Name (Get-RunLockName -Kind hot-copy -Settings $settings) -Folder $settings.HotCopiesPath
if ($null -eq $lock) {
    Write-Output 'Another hot copy run is in progress.'
    exit 0
}

$failed = 0
# In hot-copies\ and not in logs\: this task runs as you, and logs\ belongs to the SYSTEM task.
$logPath = [IO.Path]::Combine($settings.HotCopiesPath, 'hot-copies.log')
function Write-HotCopyLog {
    param([string]$Line)
    Write-Output $Line
    # Best effort: the usual reason to fail is that the backup drive is gone, and then so is the log.
    try { Add-Utf8Line -Path $logPath -Line ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line) } catch { }
}

try {
    foreach ($set in $settings.HotCopies) {
        try {
            $result = Invoke-HotCopySet -Set $set -HotCopiesPath $settings.HotCopiesPath
            if ($result.Result -eq 'unchanged') {
                Write-Output "$($result.Name): unchanged since $($result.Version)"
                continue
            }
            $line = "$($result.Name): copied $($result.Version)"
            if ($result.Removed.Count -gt 0) { $line += " (removed $($result.Removed -join ', '))" }
            Write-HotCopyLog $line
        }
        catch {
            $failed++
            Write-HotCopyLog "$($set.Name): error: $($_.Exception.Message)"
        }
    }
}
finally {
    Exit-RunLock $lock
}

if ($failed -gt 0) { exit 1 }
exit 0
