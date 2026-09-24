[CmdletBinding()]
param()

# Removes the scheduled jobs and the installed copy (Program Files on Windows, /Library/Application
# Support on macOS). Never touches your backups: the destination folder, the history, the mirror and
# the password stay exactly where they are.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-IsAdministrator)) {
    throw "Run uninstall elevated ($($script:ElevationHint)): the daily job belongs to SYSTEM or root."
}
$user = Get-InstallUser
$installRoot = Get-InstallRoot
if ((Get-BackupProjectRoot).Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Run uninstall.ps1 from your clone, not from $installRoot."
}

Unregister-Schedules -User $user
if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
    Write-Host "Removed: $installRoot"
}
Write-Host 'Your backups were not touched. Delete the destination folder yourself if you no longer want them.'
