[CmdletBinding()]
param()

# Removes the scheduled tasks and the copy under Program Files. Never touches your backups: the
# destination folder, the history, the mirror and the password stay exactly where they are.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-IsAdministrator)) {
    throw 'Run uninstall from an elevated PowerShell: the daily task belongs to SYSTEM.'
}
$installRoot = Get-InstallRoot
if ((Get-BackupProjectRoot).Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Run uninstall.ps1 from your clone, not from $installRoot."
}

foreach ($name in @($script:DailyTaskName, $script:HotCopyTaskName)) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Removed task: $name"
    }
}
if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
    Write-Host "Removed: $installRoot"
}
Write-Host 'Your backups were not touched. Delete the destination folder yourself if you no longer want them.'
