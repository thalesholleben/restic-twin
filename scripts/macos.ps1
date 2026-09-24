# macOS side of restic-twin (beta), dot-sourced by common.ps1. windows.ps1 defines the same
# functions for Windows; anything both platforms share lives in common.ps1.
#
# The model is the Windows one translated: launchd runs the daily backup as root the way the Task
# Scheduler runs it as SYSTEM, the code it runs lives where only root can write, and the folders
# root writes belong to root with mode 700, which you read through an inherited ACL entry.

$script:ResticFileName = 'restic'
$script:PathExample = '/Volumes/Backup/restic-twin'
# rsync matches names with case, so the snapshot does too.
$script:ResticExcludeFlag = '--exclude-file'
$script:DailyLabel = 'com.restic-twin.daily'
$script:HotCopyLabel = 'com.restic-twin.hot-copies'
$script:DailyPlist = '/Library/LaunchDaemons/com.restic-twin.daily.plist'
$script:StartNowHint = 'sudo launchctl kickstart system/com.restic-twin.daily'
$script:ElevationHint = 'run it with sudo'
$script:FileManager = 'Finder'
$script:MirrorTool = 'rsync'
# What your account may do in the folders root writes. Folders and files use different names for the
# same bits; the folder entry is inherited by everything created inside it later.
$script:ReadFolderRights = 'list,search,readattr,readextattr,readsecurity'
$script:ReadFileRights = 'read,readattr,readextattr,readsecurity'

function Test-AbsoluteLocalPath {
    param([AllowNull()][object]$Value)
    if ($Value -isnot [string] -or -not $Value.StartsWith('/')) { return $false }
    try {
        [void][IO.Path]::GetFullPath($Value)
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-ResticPatternRoot {
    # On macOS restic patterns escape with a backslash, and * ? [ \ are all legal in file names.
    param([Parameter(Mandatory = $true)][string]$SourcePath)
    $builder = New-Object Text.StringBuilder
    foreach ($char in $SourcePath.TrimEnd('/').ToCharArray()) {
        if ('*?[\'.IndexOf($char) -ge 0) { [void]$builder.Append('\') }
        [void]$builder.Append($char)
    }
    return $builder.ToString()
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object[]]$Arguments
    )
    $result = Invoke-NativeCapture -FilePath $FilePath -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed (exit code $($result.ExitCode)): $($result.StdErr -join ' ')"
    }
    return $result.StdOut
}

function Test-IsAdministrator {
    return ((@(Invoke-Checked -FilePath '/usr/bin/id' -Arguments @('-u')) -join '').Trim() -eq '0')
}

function Get-InstallRoot {
    # launchd runs the daily backup as root, so the code it runs has to live where only root can
    # write. A clone in your home folder is writable by you and by anything running as you.
    return '/Library/Application Support/restic-twin'
}

function Get-InstallUser {
    # The account the backups are for. Under sudo that is whoever typed sudo, not root.
    if (Test-IsAdministrator) {
        $name = $env:SUDO_USER
        if (-not $name -or $name -eq 'root') {
            throw 'Run this with sudo from your own account, so restic-twin knows whose backups these are.'
        }
    }
    else {
        $name = (@(Invoke-Checked -FilePath '/usr/bin/id' -Arguments @('-un')) -join '').Trim()
    }
    $id = (@(Invoke-Checked -FilePath '/usr/bin/id' -Arguments @('-u', $name)) -join '').Trim()
    return @{ Name = $name; Id = $id }
}

function Get-ExecutionIdentity {
    # Who this run is, for the run record: root under launchd and under sudo.
    return [Environment]::UserName
}

function Get-ResticCacheArguments {
    # sudo keeps your HOME, so restic running as root would put its cache in your Library, owned by
    # root, where your own restic can no longer open it. Root gets a cache of its own.
    if (Test-IsAdministrator) { return @('--cache-dir', '/Library/Caches/restic-twin') }
    return @()
}

function Get-UserHome {
    param([Parameter(Mandatory = $true)][hashtable]$User)
    $line = @(Invoke-Checked -FilePath '/usr/bin/dscl' -Arguments @('.', '-read', "/Users/$($User.Name)", 'NFSHomeDirectory')) -join ' '
    if ($line -notmatch 'NFSHomeDirectory:\s*(/\S.*)$') { throw "Could not find the home folder of $($User.Name)." }
    return $Matches[1].Trim()
}

function Test-RootOnly {
    # The path and every folder above it belong to root and nobody else can write them: otherwise
    # whoever can replace that file, or a folder on the way to it, can run code as root.
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $Path
    while ($current) {
        $stat = (@(Invoke-Checked -FilePath '/usr/bin/stat' -Arguments @('-f', '%u %Lp', $current)) -join ' ').Trim() -split ' '
        if ($stat[0] -ne '0') { return $false }
        if (([Convert]::ToInt32($stat[1], 8) -band 18) -ne 0) { return $false }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $true
}

function Get-TaskPowerShellPath {
    # launchd runs it as root, so it has to be a PowerShell only root can replace. The official
    # package, which brew install --cask powershell also runs, puts it in /usr/local/microsoft.
    $candidates = @('/usr/local/microsoft/powershell/7/pwsh')
    $current = (Get-Process -Id $PID).Path
    if ($current) {
        $target = (Get-Item -LiteralPath $current).ResolveLinkTarget($true)
        if ($target) { $current = $target.FullName }
        $candidates += $current
    }
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-RootOnly -Path $candidate)) { return $candidate }
    }
    throw 'The backup runs as root, so it needs a PowerShell installed for the whole Mac, which only root can change: brew install --cask powershell, or the .pkg from github.com/PowerShell/PowerShell/releases. A PowerShell your account can write would let anything running as you run code as root.'
}

function Get-MountPoint {
    # The volume a path lives on, as df sees it: "/" for the boot disk, "/Volumes/Backup" for a drive.
    param([Parameter(Mandatory = $true)][string]$Path)
    $existing = $Path
    while ($existing -and -not (Test-Path -LiteralPath $existing)) { $existing = Split-Path -Parent $existing }
    if (-not $existing) { $existing = '/' }
    $lines = @(Invoke-Checked -FilePath '/bin/df' -Arguments @('-Pk', $existing))
    $last = $lines[-1]
    if ($last -notmatch '^(.+?)\s+\d+\s+\d+\s+(\d+)\s+\d+%\s+(/.*)$') { throw "Could not read the output of df for ${existing}: $last" }
    return [pscustomobject]@{ Device = $Matches[1]; AvailableKB = [long]$Matches[2]; MountPoint = $Matches[3] }
}

function Get-DiskutilInfo {
    param([Parameter(Mandatory = $true)][string]$Target)
    $text = (@(Invoke-Checked -FilePath '/usr/sbin/diskutil' -Arguments @('info', '-plist', $Target)) -join "`n") -replace '<!DOCTYPE[^>]*>', ''
    $info = @{}
    $nodes = @(([xml]$text).plist.dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
    for ($i = 0; $i + 1 -lt $nodes.Count; $i += 2) {
        if ($nodes[$i].Name -ne 'key') { continue }
        $value = $nodes[$i + 1]
        if ($value.Name -eq 'true') { $info[$nodes[$i].InnerText] = $true }
        elseif ($value.Name -eq 'false') { $info[$nodes[$i].InnerText] = $false }
        else { $info[$nodes[$i].InnerText] = $value.InnerText }
    }
    return $info
}

function Test-DestinationAvailable {
    # /Volumes/<name> exists only while that drive is mounted. A folder there that is not a mount
    # point is a leftover on the boot disk, and writing into it would fill the internal drive.
    param([Parameter(Mandatory = $true)][string]$DestinationRoot)
    if ($DestinationRoot -match '^/Volumes/([^/]+)') {
        $volume = '/Volumes/' + $Matches[1]
        if (-not (Test-Path -LiteralPath $volume -PathType Container)) {
            return @{ Ok = $false; Message = "The drive $volume is not connected." }
        }
        if ((Get-MountPoint -Path $volume).MountPoint -ne $volume) {
            return @{ Ok = $false; Message = "$volume is a folder on the boot disk, not a mounted drive. Connect the drive and try again." }
        }
    }
    return @{ Ok = $true; Message = $null }
}

function Test-VolumeRoot {
    # A whole drive (/Volumes/Backup) is never given new permissions: it holds more than the backups.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return ((Get-MountPoint -Path $Path).MountPoint -eq $Path)
}

function Get-DestinationFreeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-MountPoint -Path $Path).AvailableKB * 1024
}

function Get-DiskId {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        return (Get-DiskutilInfo -Target (Get-MountPoint -Path $Path).Device)['ParentWholeDisk']
    }
    catch {
        return $null
    }
}

function Get-VolumePermissionProblem {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $mount = (Get-MountPoint -Path $Path).MountPoint
        $info = Get-DiskutilInfo -Target $mount
    }
    catch {
        return $null
    }
    $type = [string]$info['FilesystemType']
    if (@('exfat', 'msdos', 'ntfs') -contains $type) {
        return "$mount is formatted $type, which has no file permissions: anything running on this Mac can read and change the backups. APFS or Mac OS Extended keeps them protected."
    }
    if ($info.ContainsKey('GlobalPermissionsEnabled') -and $info['GlobalPermissionsEnabled'] -eq $false) {
        return "$mount ignores ownership (Get Info, 'Ignore ownership on this volume'), so the permissions that protect the backups do not apply. Turn it off with: sudo diskutil enableOwnership '$mount'"
    }
    return $null
}

# ---------------------------------------------------------------------------------------------
# Lock

function Enter-RunLock {
    # An exclusive lock on a file in the destination, which the root job and a sudo run both reach.
    # Not in /tmp: anyone can create files there, and so block the backup or plant a link.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Folder
    )
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "$Folder is missing. Run $(Show-Path 'scripts\install.ps1') again: it creates it with the right permissions."
    }
    $path = [IO.Path]::Combine($Folder, ".$Name.lock")
    try {
        # Read access is enough to hold the lock, so a root-created lock file still works for you.
        return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Read, [IO.FileShare]::None)
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [IO.IOException]) { return $null }
        throw
    }
}

function Exit-RunLock {
    param([AllowNull()][object]$Lock)
    if ($null -ne $Lock) { $Lock.Dispose() }
}

# ---------------------------------------------------------------------------------------------
# Mirror

function Invoke-MirrorCopy {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [AllowEmptyCollection()][string[]]$Exclusions = @(),
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    # -rlt and not -a: -a would copy owners and permissions, and a file you own in the mirror is one
    # you can change. The marker is excluded, and rsync never deletes what it excludes.
    $arguments = @('-rlt', '--delete', "--exclude=$($script:MirrorMarkerName)") + @($Exclusions | ForEach-Object { "--exclude=$_" })
    $arguments += @(($Settings.SourcePath.TrimEnd('/') + '/'), ($Settings.MirrorPath.TrimEnd('/') + '/'))
    $result = Invoke-NativeCapture -FilePath '/usr/bin/rsync' -Arguments $arguments
    Write-Utf8NoBom -Path $LogPath -Content (((@($result.StdOut) + @($result.StdErr)) -join "`n") + "`n")
    # 24: files vanished while rsync was copying them, which is normal in a folder in use.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 24) {
        $detail = @($result.StdErr | Select-Object -First 3)
        $hint = ''
        if (@($result.StdErr | Where-Object { $_ -match 'Operation not permitted' }).Count -gt 0) {
            $hint = ' macOS keeps some folders private even from root: give Full Disk Access to restic-twin (see troubleshooting), or move the source out of Desktop, Documents and Downloads.'
        }
        elseif (@($result.StdErr | Where-Object { $_ -match 'Permission denied' }).Count -gt 0) {
            $hint = " A file only its owner can read. The snapshot still has it; list its name in $(Show-Path 'config\excludes-mirror.txt')."
        }
        throw "rsync failed with exit code $($result.ExitCode): $($detail -join ' | ').$hint See $LogPath"
    }
    return $result.ExitCode
}

# ---------------------------------------------------------------------------------------------
# Permissions

function Invoke-AclCleanup {
    # chmod -N drops every ACL entry. On a file that has none it has nothing to do, and older
    # releases report that as an error, so its exit code does not count.
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Recurse)
    $arguments = @('-N', $Path)
    if ($Recurse) { $arguments = @('-R', '-N', $Path) }
    $null = Invoke-NativeCapture -FilePath '/bin/chmod' -Arguments $arguments
}

function Set-PrivateFolderAcl {
    # Mode 700 and one owner: no other account can even look inside. -UserAccess Read -Owner gives
    # the folder and everything in it to root and lets you read through an ACL entry that whatever
    # root creates in it later inherits; your account cannot write there, so nothing running as you
    # can swap a file root reads back or reach the history. Without -Owner the folder is yours.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Full', 'Read')][string]$UserAccess = 'Full',
        [switch]$Owner,
        [hashtable]$User = (Get-InstallUser)
    )
    if ($Owner) {
        $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @('-R', 'root:wheel', $Path)
        $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('-R', 'go-w', $Path)
    }
    elseif ((Test-IsAdministrator) -and $User.Name -ne 'root') {
        $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @('-R', $User.Name, $Path)
    }
    Invoke-AclCleanup -Path $Path -Recurse
    $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('700', $Path)
    if ($UserAccess -eq 'Read') {
        $null = Invoke-Checked -FilePath '/usr/bin/find' -Arguments @($Path, '-mindepth', '1', '-type', 'd', '-exec', '/bin/chmod', '+a', "user:$($User.Name) allow $($script:ReadFolderRights)", '{}', '+')
        $null = Invoke-Checked -FilePath '/usr/bin/find' -Arguments @($Path, '-mindepth', '1', '-type', 'f', '-exec', '/bin/chmod', '+a', "user:$($User.Name) allow $($script:ReadFileRights)", '{}', '+')
        $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('+a', "user:$($User.Name) allow $($script:ReadFolderRights),file_inherit,directory_inherit", $Path)
    }
}

function Test-PrivateFolderAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Full', 'Read')][string]$UserAccess = 'Full',
        [switch]$Owner,
        [hashtable]$User = (Get-InstallUser)
    )
    $stat = (@(Invoke-Checked -FilePath '/usr/bin/stat' -Arguments @('-f', '%Su %Lp', $Path)) -join ' ').Trim() -split ' '
    $expectedOwner = $User.Name
    if ($Owner) { $expectedOwner = 'root' }
    if ($stat[0] -ne $expectedOwner -or $stat[1] -ne '700') { return $false }
    $entries = @(Invoke-Checked -FilePath '/bin/ls' -Arguments @('-led', $Path) | Where-Object { $_ -match '^\s*\d+:\s' })
    if ($UserAccess -eq 'Full') { return ($entries.Count -eq 0) }
    if ($entries.Count -ne 1) { return $false }
    $entry = $entries[0]
    return ($entry -match ('user:' + [regex]::Escape($User.Name) + ' allow ') -and $entry -match '\blist\b' -and $entry -match '\bsearch\b' -and
        $entry -match 'file_inherit' -and $entry -match 'directory_inherit' -and $entry -notmatch 'write|add_|delete|chown')
}

function Set-PasswordFileAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$User = (Get-InstallUser)
    )
    try {
        Invoke-AclCleanup -Path $Path
        if (Test-IsAdministrator) {
            $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @('root:wheel', $Path)
            $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('400', $Path)
            $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('+a', "user:$($User.Name) allow $($script:ReadFileRights)", $Path)
        }
        else {
            $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('400', $Path)
        }
        return $true
    }
    catch {
        return $false
    }
}

function Protect-InstalledCopy {
    # What launchd runs as root may only be changed by root.
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @('-R', 'root:wheel', $InstallRoot)
    $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('-R', 'go-w', $InstallRoot)
    $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('755', $InstallRoot, [IO.Path]::Combine($InstallRoot, 'bin', $script:ResticFileName))
}

# ---------------------------------------------------------------------------------------------
# Schedules

function New-LaunchPlist {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Schedule,
        [Parameter(Mandatory = $true)][string]$ErrorLog
    )
    $argumentLines = ($Arguments | ForEach-Object { '    <string>' + [Security.SecurityElement]::Escape($_) + '</string>' }) -join "`n"
    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$Label</string>
  <key>ProgramArguments</key>
  <array>
$argumentLines
  </array>
$Schedule
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>$([Security.SecurityElement]::Escape($ErrorLog))</string>
</dict>
</plist>
"@
}

function Get-HotCopyPlistPath {
    param([Parameter(Mandatory = $true)][hashtable]$User)
    return [IO.Path]::Combine((Get-UserHome -User $User), 'Library', 'LaunchAgents', "$($script:HotCopyLabel).plist")
}

function Register-Schedules {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][hashtable]$User
    )
    $powershell = Get-TaskPowerShellPath
    $time = $Settings.DailyAt -split ':'
    # launchd starts a job it missed while the Mac slept, not one it missed while the Mac was off.
    # So the job also wakes every hour, and -IfDue decides: due when nothing succeeded since the
    # last DailyAt and the last attempt is at least four hours old.
    $schedule = @"
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$([int]$time[0])</integer>
    <key>Minute</key>
    <integer>$([int]$time[1])</integer>
  </dict>
  <key>StartInterval</key>
  <integer>3600</integer>
"@
    $daily = New-LaunchPlist -Label $script:DailyLabel -Schedule $schedule -ErrorLog ([IO.Path]::Combine($InstallRoot, 'daily-errors.log')) `
        -Arguments @($powershell, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', [IO.Path]::Combine($InstallRoot, 'scripts', 'backup.ps1'), '-IfDue')
    Write-Utf8NoBom -Path $script:DailyPlist -Content $daily
    $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @('root:wheel', $script:DailyPlist)
    $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('644', $script:DailyPlist)
    $null = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('bootout', "system/$($script:DailyLabel)")
    $null = Invoke-Checked -FilePath '/bin/launchctl' -Arguments @('bootstrap', 'system', $script:DailyPlist)
    Write-Host "Registered '$($script:DailyLabel)': every day at $($Settings.DailyAt), as root, and within the hour after the Mac wakes or starts if it missed one."

    $agentPlist = Get-HotCopyPlistPath -User $User
    $domain = "gui/$($User.Id)"
    if ($Settings.HotCopies.Count -gt 0) {
        $agentFolder = Split-Path -Parent $agentPlist
        if (-not (Test-Path -LiteralPath $agentFolder)) {
            New-Item -ItemType Directory -Path $agentFolder -Force | Out-Null
            $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @($User.Name, $agentFolder)
        }
        $agentLog = [IO.Path]::Combine((Get-UserHome -User $User), 'Library', 'Logs', 'restic-twin-hot-copies.log')
        $agent = New-LaunchPlist -Label $script:HotCopyLabel -ErrorLog $agentLog `
            -Schedule ("  <key>StartInterval</key>`n  <integer>$($Settings.HotCopyEveryMinutes * 60)</integer>") `
            -Arguments @($powershell, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', [IO.Path]::Combine($InstallRoot, 'scripts', 'hot-copy.ps1'))
        Write-Utf8NoBom -Path $agentPlist -Content $agent
        $null = Invoke-Checked -FilePath '/usr/sbin/chown' -Arguments @("$($User.Name):staff", $agentPlist)
        $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('644', $agentPlist)
        $null = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('bootout', "$domain/$($script:HotCopyLabel)")
        $loaded = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('bootstrap', $domain, $agentPlist)
        if ($loaded.ExitCode -eq 0) {
            Write-Host "Registered '$($script:HotCopyLabel)': every $($Settings.HotCopyEveryMinutes) minutes while you are logged in."
        }
        else {
            Write-Warning "Hot copies are set up in $agentPlist, but launchd did not load them now ($($loaded.StdErr -join ' ')). They start at your next login."
        }
    }
    elseif (Test-Path -LiteralPath $agentPlist) {
        $null = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('bootout', "$domain/$($script:HotCopyLabel)")
        Remove-Item -LiteralPath $agentPlist -Force
        Write-Host "Removed '$($script:HotCopyLabel)': HotCopies is empty."
    }

    $record = [ordered]@{
        validated_at = (Get-Date).ToString('o')
        jobs         = @(
            [ordered]@{ label = $script:DailyLabel; plist = $script:DailyPlist; user = 'root'; program = $powershell }
            [ordered]@{ label = $script:HotCopyLabel; plist = $agentPlist; user = $User.Name; installed = (Test-Path -LiteralPath $agentPlist) }
        )
    }
    Write-Utf8NoBom -Path ([IO.Path]::Combine($Settings.LogsPath, 'scheduled-task.json')) -Content ((ConvertTo-Json -InputObject $record -Depth 4) + "`n")
}

function Unregister-Schedules {
    param([hashtable]$User = (Get-InstallUser))
    $null = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('bootout', "system/$($script:DailyLabel)")
    if (Test-Path -LiteralPath $script:DailyPlist) {
        Remove-Item -LiteralPath $script:DailyPlist -Force
        Write-Host "Removed job: $($script:DailyLabel)"
    }
    $agentPlist = Get-HotCopyPlistPath -User $User
    $null = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('bootout', "gui/$($User.Id)/$($script:HotCopyLabel)")
    if (Test-Path -LiteralPath $agentPlist) {
        Remove-Item -LiteralPath $agentPlist -Force
        Write-Host "Removed job: $($script:HotCopyLabel)"
    }
}

function Get-ScheduleStatusLines {
    $userId = $null
    try { $userId = (Get-InstallUser).Id } catch { }
    $targets = @(@{ Label = $script:DailyLabel; Domain = 'system' })
    if ($userId) { $targets += @{ Label = $script:HotCopyLabel; Domain = "gui/$userId" } }
    foreach ($target in $targets) {
        $result = Invoke-NativeCapture -FilePath '/bin/launchctl' -Arguments @('print', "$($target.Domain)/$($target.Label)")
        if ($result.ExitCode -eq 0) {
            $state = @($result.StdOut | Where-Object { $_ -match '^\s*state = ' } | Select-Object -First 1) -replace '^\s*state = ', ''
            $last = @($result.StdOut | Where-Object { $_ -match '^\s*last exit code = ' } | Select-Object -First 1) -replace '^\s*last exit code = ', ''
            "Job:           '$($target.Label)' $state, last exit code $last"
        }
        elseif ($target.Label -eq $script:DailyLabel) {
            "Job:           '$($target.Label)' not installed"
        }
    }
}
