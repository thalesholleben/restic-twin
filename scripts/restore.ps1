[CmdletBinding()]
param(
    [string]$Snapshot = 'latest',
    [string]$TargetPath,
    [string[]]$Include,
    [string]$ConfigPath
)

# Restores a snapshot into a new folder, never over existing files. Compare what comes back, then
# copy what you need into the source yourself.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$settings = Get-BackupSettings -ConfigPath $ConfigPath
if (-not $TargetPath) {
    $TargetPath = [IO.Path]::Combine($settings.RestoresPath, 'restore_' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
}
if (-not (Test-AbsoluteLocalPath $TargetPath)) {
    throw "TargetPath must be an absolute path on a drive letter: '$TargetPath'."
}
$TargetPath = ConvertTo-NormalizedPath $TargetPath
if (Test-PathInside $TargetPath $settings.SourcePath) {
    throw 'Restores never go inside the source folder. Restore somewhere else, compare, then copy back what you need.'
}
foreach ($name in @('MirrorPath', 'RepositoryPath')) {
    if (Test-PathInside $TargetPath $settings[$name]) {
        throw "Restores never go inside $($settings[$name])."
    }
}
if (Test-Path -LiteralPath $TargetPath) {
    throw "The target already exists: $TargetPath. Choose a new folder, so nothing gets overwritten."
}

New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
# "snapshot:/C/Users/you/Projects" restores what is inside the source folder straight into the
# target. Without it restic rebuilds the whole path (<target>\C\Users\you\...), parents included,
# with the attributes of folders like C:\Users, which are read-only.
$sourceInSnapshot = '/' + $settings.SourcePath.Replace(':', '').Replace('\', '/').TrimEnd('/')
$arguments = (Get-ResticBaseArguments -Settings $settings -ReadOnly) + @('restore', "${Snapshot}:$sourceInSnapshot", '--target', $TargetPath, '--verify')
if ($Snapshot -eq 'latest') {
    # Only our snapshots, in case the repository is shared with other backups.
    $arguments += @('--tag', $script:ResticTag)
}
foreach ($pattern in @($Include)) {
    if ($pattern) { $arguments += @('--include', $pattern) }
}

& $settings.ResticPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "restic restore failed with exit code $LASTEXITCODE."
}
Write-Host "Restored into: $TargetPath"
