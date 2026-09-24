# Windows side of restic-twin, dot-sourced by common.ps1. macos.ps1 defines the same functions for
# macOS; anything both platforms share lives in common.ps1.

$script:ResticFileName = 'restic.exe'
$script:PathExample = 'E:\restic-twin'
# robocopy ignores case, so the snapshot does too.
$script:ResticExcludeFlag = '--iexclude-file'
$script:DailyTaskName = 'restic-twin daily backup'
$script:HotCopyTaskName = 'restic-twin hot copies'
$script:StartNowHint = "Start-ScheduledTask -TaskName 'restic-twin daily backup'"
$script:ElevationHint = 'run it from an elevated PowerShell'
$script:FileManager = 'Explorer'
$script:MirrorTool = 'robocopy'

function Test-VolumeRoot {
    # A whole drive (E:\) is never given new permissions: it holds more than the backups.
    param([Parameter(Mandatory = $true)][string]$Path)
    return ($Path.Length -le 3)
}

function Test-AbsoluteLocalPath {
    param([AllowNull()][object]$Value)
    if ($Value -isnot [string] -or $Value -notmatch '^[A-Za-z]:\\') { return $false }
    try {
        [void][IO.Path]::GetFullPath($Value)
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-ResticPatternRoot {
    # "[" opens a character class in restic's patterns; "[[]" is a literal one. "]" alone is
    # already literal, and "*" and "?" cannot appear in a Windows path.
    param([Parameter(Mandatory = $true)][string]$SourcePath)
    return $SourcePath.TrimEnd('\').Replace('[', '[[]')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InstallRoot {
    # The daily task runs as SYSTEM, so the code it runs has to live where a normal user cannot
    # change it. A clone in your profile is writable by you and by anything running as you.
    return (Join-Path $env:ProgramFiles 'restic-twin')
}

function Get-InstallUser {
    # The account the backups are for: the one running the install, elevated or not.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return @{ Name = $identity.Name; Id = $identity.User.Value }
}

function Get-ExecutionIdentity {
    # Who this run is, for the run record: NT AUTHORITY\SYSTEM under the scheduled task.
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-ResticCacheArguments {
    # restic's default cache is per account (SYSTEM has its own profile), so nothing to add.
    return @()
}

function Get-TaskPowerShellPath {
    # Only hosts installed for the whole machine: the daily task runs them as SYSTEM, and a
    # per-user pwsh (Store, portable, a folder in your profile) is one a normal user can replace.
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $pwsh -PathType Leaf) { return $pwsh }
    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Test-DestinationAvailable {
    param([Parameter(Mandatory = $true)][string]$DestinationRoot)
    $drive = [IO.Path]::GetPathRoot($DestinationRoot)
    if (Test-Path -LiteralPath $drive -PathType Container) { return @{ Ok = $true; Message = $null } }
    return @{ Ok = $false; Message = "Destination drive $drive is not available." }
}

function Get-DestinationFreeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
}

function Get-DiskId {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        return (Get-Partition -DriveLetter ([IO.Path]::GetPathRoot($Path).Substring(0, 1)) -ErrorAction Stop).DiskNumber
    }
    catch {
        return $null
    }
}

function Get-VolumePermissionProblem {
    # FAT32 and exFAT drives have no permissions at all: there is nothing to restrict.
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $format = (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))).DriveFormat
    }
    catch {
        return $null
    }
    if (@('NTFS', 'ReFS') -contains $format) { return $null }
    return "$([IO.Path]::GetPathRoot($Path)) is formatted $format, which has no file permissions: any account on this PC can read and change the backups. NTFS keeps them protected."
}

# ---------------------------------------------------------------------------------------------
# Lock

function Enter-RunLock {
    # Global\ and not Local\: the scheduled run lives in session 0 as SYSTEM, a manual run lives in
    # your session, and a Local\ mutex would let both refresh the mirror at the same time.
    # -Folder is where macOS keeps its lock file; a mutex needs none.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Folder
    )
    try {
        $mutex = New-Object Threading.Mutex($false, "Global\restic-twin-$Name")
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        # Another account (the SYSTEM task) holds it and we may not even open it: that is busy.
        if ($inner -is [UnauthorizedAccessException]) { return $null }
        throw
    }
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        # The previous holder died without releasing it; we own it now.
        if ($inner -isnot [Threading.AbandonedMutexException]) { $mutex.Dispose(); throw }
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-RunLock {
    param([AllowNull()][object]$Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { }
    $Lock.Dispose()
}

# ---------------------------------------------------------------------------------------------
# Mirror

function Get-MirrorArguments {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [AllowEmptyCollection()][string[]]$Exclusions = @(),
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    # /UNILOG writes the log as UTF-16 itself, so no code page ever touches robocopy's paths.
    $arguments = @(
        $Settings.SourcePath, $Settings.MirrorPath,
        '/MIR', '/COPY:DAT', '/DCOPY:DAT', '/Z', '/SL', '/XJ',
        '/R:3', '/W:5', '/MT:16', '/NP', '/BYTES', '/NFL', '/NDL',
        "/UNILOG:$LogPath"
    )
    if ($Exclusions.Count -gt 0) { $arguments += @('/XD') + $Exclusions }
    # The marker is excluded, and robocopy never purges what it excludes, so /MIR keeps it.
    $arguments += @('/XF', $script:MirrorMarkerName) + $Exclusions
    return $arguments
}

function Get-RobocopyErrorLines {
    # The error text is localized ("ERROR 5", "ERRO 5", "FEHLER 5"), the hex code is not.
    param([AllowEmptyCollection()][string[]]$Lines)
    @($Lines | Where-Object { $_ -match '\(0x[0-9A-Fa-f]{8}\)' } | Select-Object -First 3 | ForEach-Object { $_.Trim() })
}

function Invoke-MirrorCopy {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [AllowEmptyCollection()][string[]]$Exclusions = @(),
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    $result = Invoke-NativeCapture -FilePath 'robocopy.exe' -Arguments (Get-MirrorArguments -Settings $Settings -Exclusions $Exclusions -LogPath $LogPath)
    if ($result.ExitCode -ge 8) {
        $logLines = @()
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) { $logLines = [IO.File]::ReadAllLines($LogPath) }
        $detail = @(Get-RobocopyErrorLines -Lines (@($logLines) + @($result.StdOut) + @($result.StdErr)))
        $hint = ''
        if (@($detail | Where-Object { $_ -match '\(0x00000005\)' }).Count -gt 0) {
            $hint += ' Access denied usually means a file only your account can read. The snapshot still has it (restic reads it with backup privileges); list its name in config\excludes-mirror.txt.'
        }
        if (@($detail | Where-Object { $_ -match '\(0x00000020\)' }).Count -gt 0) {
            $hint += ' A program keeps that file open. The snapshot still has it (restic reads it through VSS); if it is always open, like a database or a VM disk, list its name in config\excludes-mirror.txt.'
        }
        throw "Robocopy failed with exit code $($result.ExitCode): $($detail -join ' | ').$hint See $LogPath"
    }
    return $result.ExitCode
}

# ---------------------------------------------------------------------------------------------
# Permissions

function Set-PrivateFolderAcl {
    # The mirror is a plain copy of your files. On a second drive it would otherwise inherit that
    # drive's permissions, which usually let every local account read it.
    #
    # -UserAccess Read is for the folders the SYSTEM task writes once it is installed: a folder you
    # can write is one where anything running as you could swap a file SYSTEM reads back, or turn
    # the folder into a junction that makes SYSTEM write somewhere else. It is also what keeps
    # ransomware running as you away from the history. -Owner hands the folder, and whatever is
    # below it, to Administrators, because an owner can always rewrite the permissions.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Full', 'Read')][string]$UserAccess = 'Full',
        [switch]$Owner,
        [hashtable]$User = (Get-InstallUser)
    )
    if ($Owner) {
        $ErrorActionPreference = 'Continue'
        $null = & icacls.exe $Path /setowner '*S-1-5-32-544' /T /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not give $Path to Administrators (icacls exit code $LASTEXITCODE)." }
        $ErrorActionPreference = 'Stop'
    }
    $userRights = 'FullControl'
    if ($UserAccess -eq 'Read') { $userRights = 'ReadAndExecute, Synchronize' }
    Set-ExactAcl -Path $Path -Directory -Rights @{
        'S-1-5-18'     = 'FullControl'
        'S-1-5-32-544' = 'FullControl'
        ($User.Id)     = $userRights
    }
}

function Set-ExactAcl {
    # Writes the whole access list in one call. icacls /grant:r only replaces the entries of the
    # accounts it names, so an explicit "Everyone: read" someone added earlier would survive it.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Rights,
        [switch]$Directory
    )
    if ($Directory) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $info = New-Object IO.DirectoryInfo($Path)
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $info = New-Object IO.FileInfo($Path)
        $inherit = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $Rights.Keys) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]$Rights[$sid], $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    # Not Set-Acl: in Windows PowerShell 5.1 it also tries to write the owner and the audit list of a
    # folder that is already protected, and fails without the privileges for those. SetAccessControl
    # writes only what changed here, the access list. It moved to an extension class in .NET Core.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
    }
    else {
        $info.SetAccessControl($acl)
    }
}

function Test-PrivateFolderAcl {
    # True when $Path already has exactly what Set-PrivateFolderAcl gives it, so an install can skip
    # re-applying it, which on a mirror with a hundred thousand files takes a while.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Full', 'Read')][string]$UserAccess = 'Full',
        [switch]$Owner,
        [hashtable]$User = (Get-InstallUser)
    )
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    if ($Owner) {
        $ownerSid = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -ne 'S-1-5-32-544' -and $ownerSid -ne 'S-1-5-18') { return $false }
    }
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    $want = @{ 'S-1-5-18' = $full; 'S-1-5-32-544' = $full; ($User.Id) = $full }
    if ($UserAccess -eq 'Read') { $want[$User.Id] = $read }
    $rules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' })
    if ($rules.Count -ne $want.Count -or @($acl.Access | Where-Object { $_.AccessControlType -ne 'Allow' }).Count -gt 0) { return $false }
    foreach ($rule in $rules) {
        $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if (-not $want.ContainsKey($ruleSid) -or $rule.FileSystemRights -ne $want[$ruleSid]) { return $false }
    }
    return $true
}

function Set-PasswordFileAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$User = (Get-InstallUser)
    )
    try {
        Set-ExactAcl -Path $Path -Rights @{
            'S-1-5-18'     = 'Read, Synchronize'
            'S-1-5-32-544' = 'Read, Synchronize'
            ($User.Id)     = 'Read, Synchronize'
        }
        return $true
    }
    catch {
        return $false
    }
}

function Protect-InstalledCopy {
    # Program Files already lets only administrators write; the copy inherits that.
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
}

# ---------------------------------------------------------------------------------------------
# Schedules

function Register-Schedules {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][hashtable]$User
    )
    Import-Module ScheduledTasks
    $powershell = Get-TaskPowerShellPath
    $dailyAction = New-ScheduledTaskAction -Execute $powershell -WorkingDirectory $InstallRoot `
        -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallRoot 'scripts\backup.ps1'))
    $dailySettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $script:DailyTaskName -Force `
        -Action $dailyAction `
        -Trigger (New-ScheduledTaskTrigger -Daily -At $Settings.DailyAt) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
        -Settings $dailySettings `
        -Description "restic-twin: encrypted snapshot, change report and mirror of $($Settings.SourcePath)." | Out-Null
    Write-Host "Registered '$($script:DailyTaskName)': every day at $($Settings.DailyAt), as SYSTEM, and at the next start if the PC was off."

    $hotCopyTask = Get-ScheduledTask -TaskName $script:HotCopyTaskName -ErrorAction SilentlyContinue
    if ($Settings.HotCopies.Count -gt 0) {
        $hotCopyArguments = '//B //Nologo "{0}" "{1}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{2}"' -f `
        (Join-Path $InstallRoot 'scripts\run-hidden.vbs'), $powershell, (Join-Path $InstallRoot 'scripts\hot-copy.ps1')
        $hotCopySettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $script:HotCopyTaskName -Force `
            -Action (New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument $hotCopyArguments -WorkingDirectory $InstallRoot) `
            -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $Settings.HotCopyEveryMinutes)) `
            -Principal (New-ScheduledTaskPrincipal -UserId $User.Name -LogonType Interactive -RunLevel Limited) `
            -Settings $hotCopySettings `
            -Description 'restic-twin: frequent plain copies of the files listed in HotCopies.' | Out-Null
        Write-Host "Registered '$($script:HotCopyTaskName)': every $($Settings.HotCopyEveryMinutes) minutes while you are signed in."
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
    Write-Utf8NoBom -Path (Join-Path $Settings.LogsPath 'scheduled-task.json') -Content ($recordJson + "`n")
}

function Unregister-Schedules {
    param([hashtable]$User = (Get-InstallUser))
    foreach ($name in @($script:DailyTaskName, $script:HotCopyTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Removed task: $name"
        }
    }
}

function Get-ScheduleStatusLines {
    foreach ($name in @($script:DailyTaskName, $script:HotCopyTaskName)) {
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $name
            "Task:          '$name' $($task.State), next $($info.NextRunTime), last result $($info.LastTaskResult)"
        }
        catch {
            # A task that runs as SYSTEM cannot be read from a shell that is not elevated.
            if ($name -eq $script:DailyTaskName) {
                "Task:          '$name' not readable from this shell (run elevated), or not installed"
            }
        }
    }
}
