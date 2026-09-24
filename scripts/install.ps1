[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipScheduledTask
)

# Prepares the destination (folders, password, restic repository, recovery notes) and registers
# the scheduled jobs. Safe to run again after changing settings: it never replaces a password,
# never re-creates a repository and never touches the history.
#
# The jobs run a copy of this folder installed where only an administrator can write (Program Files
# on Windows, /Library/Application Support on macOS), not this folder itself: the daily job runs as
# SYSTEM or root, and code in your profile can be changed by anything running as you.

# One clean line instead of a stack trace, and exit code 1 for the scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$settings = Get-BackupSettings -ConfigPath $ConfigPath

if (-not $SkipScheduledTask -and -not (Test-IsAdministrator)) {
    throw "The daily job runs as SYSTEM or root, so install needs an elevated shell: $($script:ElevationHint). Pass -SkipScheduledTask to only prepare the folders and the repository."
}
$user = Get-InstallUser
if (-not (Test-Path -LiteralPath $settings.ResticPath -PathType Leaf)) {
    Write-Host 'restic is not installed yet; installing the pinned version.'
    & (Join-Path $PSScriptRoot 'install-restic.ps1')
}
if (-not (Test-Path -LiteralPath $settings.SourcePath -PathType Container)) {
    throw "Source folder not found: $($settings.SourcePath)"
}
$destination = Test-DestinationAvailable -DestinationRoot $settings.DestinationRoot
if (-not $destination.Ok) {
    throw $destination.Message
}

$sourceDisk = Get-DiskId -Path $settings.SourcePath
$destinationDisk = Get-DiskId -Path $settings.DestinationRoot
if ($null -ne $sourceDisk -and $sourceDisk -eq $destinationDisk) {
    Write-Warning "SourcePath and DestinationRoot are on the same physical disk ($sourceDisk). The history still protects you from deleting or overwriting files, but not from that disk failing."
}
# A drive without file permissions (exFAT, FAT32, or a Mac volume that ignores ownership) cannot
# keep anything private: say so once and leave its permissions alone.
$permissionProblem = Get-VolumePermissionProblem -Path $settings.DestinationRoot
if ($permissionProblem) {
    Write-Warning $permissionProblem
}

# Who may write each folder. With the jobs installed, SYSTEM or root is the only writer of what it
# reads back (history, mirror, reports, logs, recovery, and the destination above them): your
# account only reads those, and administrators own them. You keep full control of what you write
# yourself, the hot copies and the restores. Without the jobs (-SkipScheduledTask) you run the
# backups, so you keep full control of everything.
$systemTask = -not $SkipScheduledTask
$systemAccess = 'Full'
if ($systemTask) { $systemAccess = 'Read' }
$folders = New-Object Collections.Generic.List[object]
if (-not (Test-VolumeRoot -Path $settings.DestinationRoot)) {
    $managedNames = @($script:ManagedFolders.Values)
    $foreign = @()
    if (Test-Path -LiteralPath $settings.DestinationRoot) {
        $foreign = @(Get-ChildItem -LiteralPath $settings.DestinationRoot -Force | Where-Object { $managedNames -notcontains $_.Name -and $_.Name -notmatch '^\.' })
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
    if ($permissionProblem) { continue }
    $owner = $systemTask -and $folder.Access -eq 'Read'
    if (Test-PrivateFolderAcl -Path $folder.Path -UserAccess $folder.Access -Owner:$owner -User $user) { continue }
    try {
        Set-PrivateFolderAcl -Path $folder.Path -UserAccess $folder.Access -Owner:$owner -User $user
    }
    catch {
        if ($systemTask) { throw }
        throw "Could not set the permissions of $($folder.Path): $($_.Exception.Message) If an elevated install gave it to administrators, run install.ps1 elevated and without -SkipScheduledTask."
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
if (-not $permissionProblem -and -not (Set-PasswordFileAcl -Path $settings.PasswordFile -User $user)) {
    if ($newPassword) { throw "Could not restrict the permissions of $($settings.PasswordFile)." }
    Write-Warning "Could not restrict the permissions of $($settings.PasswordFile). Make sure only you and administrators can read it."
}

if (-not $repositoryExists) {
    $init = Invoke-NativeCapture -FilePath $settings.ResticPath -Arguments ((Get-ResticBaseArguments -Settings $settings) + @('init'))
    if ($init.ExitCode -ne 0) {
        throw "restic init failed (exit code $($init.ExitCode)): $($init.StdErr -join ' ')"
    }
    Write-Host "Created the restic repository at $($settings.RepositoryPath)."
}

$installRoot = Get-InstallRoot
$sourceInSnapshot = ConvertTo-SnapshotPath -Path $settings.SourcePath
$recovery = @"
restic-twin recovery notes

Source:        $($settings.SourcePath)
History:       $($settings.RepositoryPath)
Password file: $($settings.PasswordFile)
Mirror:        $($settings.MirrorPath)
Installed at:  $installRoot

Keep a copy of the password file somewhere other than this drive, a password manager is fine.
Without it nobody can decrypt the history, including you.

The mirror is a plain copy of the latest backup: open it in $($script:FileManager).
Do not edit anything inside the history folder by hand.

On another computer, download restic from https://github.com/restic/restic/releases and run:

restic --repo "$($settings.RepositoryPath)" --password-file "<password file>" snapshots
restic --repo "$($settings.RepositoryPath)" --password-file "<password file>" restore latest:$sourceInSnapshot --target "<an empty folder>"

A read-only copy of the history (another drive, a share) needs --no-lock as well.
"@
$newline = [Environment]::NewLine
Write-Utf8NoBom -Path (Join-Path $settings.RecoveryPath 'README.txt') -Content ($recovery.Replace("`r`n", "`n").Replace("`n", $newline) + $newline)

if ($systemTask) {
    # Replacing the installed scripts under a running backup or hot copy would change them mid-run.
    $backupLock = Enter-RunLock -Name (Get-RunLockName -Kind backup -Settings $settings) -Folder $settings.LogsPath
    $hotCopyLock = Enter-RunLock -Name (Get-RunLockName -Kind hot-copy -Settings $settings) -Folder $settings.HotCopiesPath
    try {
        if ($null -eq $backupLock -or $null -eq $hotCopyLock) {
            throw 'A backup or a hot copy is running right now. Run install again when it finishes.'
        }
        Publish-InstalledCopy -Settings $settings -InstallRoot $installRoot
        Register-Schedules -Settings $settings -InstallRoot $installRoot -User $user
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
if ($systemTask) {
    Write-Host "First backup now, instead of waiting for $($settings.DailyAt):"
    Write-Host "  $($script:StartNowHint)"
}
