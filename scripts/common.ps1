Set-StrictMode -Version Latest

# Shared by every script in this folder. Keep it compatible with Windows PowerShell 5.1:
# no ternary, no ??, no pipeline chain operators, ASCII only (5.1 reads BOM-less files as ANSI).

$script:ResticTag = 'restic-twin'
$script:DailyTaskName = 'restic-twin daily backup'
$script:HotCopyTaskName = 'restic-twin hot copies'
$script:MirrorMarkerName = '.restic-twin-mirror'
$script:HotCopyVersionPattern = '^\d{4}-\d{2}-\d{2}_\d{6}(-\d+)?$'
$script:AllowedSettings = @('SourcePath', 'DestinationRoot', 'PasswordFile', 'DailyAt', 'KeepDaily', 'KeepMonthly', 'MinimumFreeSpaceGB', 'HotCopyEveryMinutes', 'HotCopies')
$script:AllowedHotCopyKeys = @('Name', 'Files', 'Keep')
# Folders under DestinationRoot that restic-twin owns. The mirror refresh deletes whatever is not in
# the source, so nothing of value may live inside MirrorPath, and nothing we own may overlap another.
$script:ManagedFolders = [ordered]@{
    MirrorPath     = 'mirror'
    RepositoryPath = 'history'
    ReportsPath    = 'reports'
    LogsPath       = 'logs'
    RecoveryPath   = 'recovery'
    HotCopiesPath  = 'hot-copies'
    RestoresPath   = 'restores'
}
$script:LogFile = $null

function Get-BackupProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-InstallRoot {
    # The daily task runs as SYSTEM, so the code it runs has to live where a normal user cannot
    # change it. A clone in your profile is writable by you and by anything running as you.
    return (Join-Path $env:ProgramFiles 'restic-twin')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Add-Utf8Line {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line
    )
    [IO.File]::AppendAllText($Path, $Line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        Add-Utf8Line -Path $script:LogFile -Line $line
    }
}

function Enable-Utf8NativeOutput {
    # restic prints UTF-8, and PowerShell decodes native output with the console code page. Under
    # the Task Scheduler that page is the OEM one (850, 437...), and without this line every path
    # with an accent came out of the reports as mojibake.
    try {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    }
    catch {
        Write-Warning "Could not switch the console to UTF-8, accented paths may be garbled: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------------------------
# Settings

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

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd('\')
    }
    return $full
}

function Test-PathInside {
    # True when $Path is $Parent itself or anything below it. Windows paths ignore case.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    if ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $Parent.TrimEnd('\') + '\'
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-WholeNumber {
    param([AllowNull()][object]$Value, [long]$Minimum, [long]$Maximum)
    if (-not ($Value -is [int] -or $Value -is [long])) { return $false }
    return ($Value -ge $Minimum -and $Value -le $Maximum)
}

function Resolve-BackupSettings {
    # Turns the hashtable read from settings.psd1 into the full settings, or throws one error that
    # lists every problem found, so a typo is fixed in one round instead of five.
    param([Parameter(Mandatory = $true)][hashtable]$Raw)

    $problems = New-Object Collections.Generic.List[string]
    foreach ($key in $Raw.Keys) {
        if ($script:AllowedSettings -notcontains $key) {
            $problems.Add("Unknown setting '$key'. Allowed: $($script:AllowedSettings -join ', ').")
        }
    }

    $s = @{
        PasswordFile        = $null
        DailyAt             = '19:00'
        KeepDaily           = 7
        KeepMonthly         = 6
        MinimumFreeSpaceGB  = 10
        HotCopyEveryMinutes = 5
        HotCopies           = @()
    }
    foreach ($key in $Raw.Keys) {
        if ($script:AllowedSettings -contains $key) { $s[$key] = $Raw[$key] }
    }

    $pathsValid = $true
    foreach ($key in @('SourcePath', 'DestinationRoot')) {
        if (-not $s.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$s[$key])) {
            $problems.Add("$key is required.")
            $pathsValid = $false
        }
        elseif (-not (Test-AbsoluteLocalPath $s[$key])) {
            $problems.Add("$key must be an absolute path on a drive letter, like 'E:\restic-twin': '$($s[$key])'.")
            $pathsValid = $false
        }
        else {
            $s[$key] = ConvertTo-NormalizedPath $s[$key]
        }
    }

    if ($pathsValid) {
        if ((Test-PathInside $s.SourcePath $s.DestinationRoot) -or (Test-PathInside $s.DestinationRoot $s.SourcePath)) {
            $problems.Add('SourcePath and DestinationRoot must not be the same folder or inside each other.')
        }
        # [IO.Path]::Combine and not Join-Path: Join-Path fails when the drive does not exist, and an
        # unplugged backup drive has to end in "drive not available", not in a crash while reading settings.
        foreach ($name in $script:ManagedFolders.Keys) {
            $s[$name] = [IO.Path]::Combine($s.DestinationRoot, $script:ManagedFolders[$name])
        }
        if ([string]::IsNullOrWhiteSpace([string]$s.PasswordFile)) {
            $s.PasswordFile = [IO.Path]::Combine($s.RecoveryPath, 'restic-password.txt')
        }
        if (-not (Test-AbsoluteLocalPath $s.PasswordFile)) {
            $problems.Add("PasswordFile must be an absolute path on a drive letter: '$($s.PasswordFile)'.")
        }
        else {
            $s.PasswordFile = ConvertTo-NormalizedPath $s.PasswordFile
            if (Test-PathInside $s.PasswordFile $s.SourcePath) {
                $problems.Add('PasswordFile must not be inside SourcePath: the mirror would keep it in plain text.')
            }
            foreach ($name in $script:ManagedFolders.Keys) {
                if ($name -ne 'RecoveryPath' -and (Test-PathInside $s.PasswordFile $s[$name])) {
                    $problems.Add("PasswordFile must not be inside $($s[$name]).")
                }
            }
        }
    }

    if ($s.DailyAt -isnot [string] -or $s.DailyAt -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        $problems.Add("DailyAt must be a 24-hour time like '19:00': '$($s.DailyAt)'.")
    }
    if (-not (Test-WholeNumber $s.KeepDaily 1 3650)) { $problems.Add("KeepDaily must be a whole number of at least 1: '$($s.KeepDaily)'.") }
    if (-not (Test-WholeNumber $s.KeepMonthly 0 1200)) { $problems.Add("KeepMonthly must be a whole number, 0 or more: '$($s.KeepMonthly)'.") }
    if (-not (Test-WholeNumber $s.HotCopyEveryMinutes 1 1440)) { $problems.Add("HotCopyEveryMinutes must be a whole number from 1 to 1440: '$($s.HotCopyEveryMinutes)'.") }
    $gb = $s.MinimumFreeSpaceGB
    if (-not (($gb -is [int] -or $gb -is [long] -or $gb -is [double] -or $gb -is [decimal]) -and $gb -ge 0)) {
        $problems.Add("MinimumFreeSpaceGB must be a number, 0 or more: '$gb'.")
    }

    $names = @{}
    $sets = New-Object Collections.Generic.List[hashtable]
    foreach ($set in @($s.HotCopies)) {
        if ($set -isnot [hashtable]) {
            $problems.Add("Each HotCopies entry must look like @{ Name = 'notes'; Files = @('C:\path\file.txt') }.")
            continue
        }
        foreach ($key in $set.Keys) {
            if ($script:AllowedHotCopyKeys -notcontains $key) {
                $problems.Add("Unknown key '$key' in a HotCopies entry. Allowed: $($script:AllowedHotCopyKeys -join ', ').")
            }
        }
        $name = $set['Name']
        if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $problems.Add("HotCopies Name must start with a letter or digit and use only letters, digits, '.', '-' or '_': '$name'.")
            continue
        }
        if ($names.ContainsKey($name)) { $problems.Add("HotCopies Name '$name' is used twice.") }
        $names[$name] = $true

        $files = New-Object Collections.Generic.List[string]
        $leaves = @{}
        if ($null -eq $set['Files'] -or @($set['Files']).Count -eq 0) {
            $problems.Add("HotCopies '$name' has no Files.")
        }
        else {
            foreach ($file in @($set['Files'])) {
                if (-not (Test-AbsoluteLocalPath $file)) {
                    $problems.Add("HotCopies '$name': '$file' is not an absolute path on a drive letter.")
                    continue
                }
                $normalized = ConvertTo-NormalizedPath $file
                if ($pathsValid -and (Test-PathInside $normalized $s.DestinationRoot)) {
                    $problems.Add("HotCopies '$name': '$normalized' is inside DestinationRoot.")
                }
                $leaf = Split-Path -Leaf $normalized
                if ($leaves.ContainsKey($leaf)) {
                    $problems.Add("HotCopies '$name' has two files named '$leaf'. They would land in the same version folder; split them into two entries.")
                }
                $leaves[$leaf] = $true
                $files.Add($normalized)
            }
        }
        $keep = 12
        if ($set.ContainsKey('Keep')) { $keep = $set['Keep'] }
        if (-not (Test-WholeNumber $keep 1 100000)) { $problems.Add("HotCopies '$name': Keep must be a whole number of at least 1: '$keep'.") }
        $sets.Add(@{ Name = $name; Files = $files.ToArray(); Keep = $keep })
    }
    $s.HotCopies = $sets.ToArray()

    if ($problems.Count -gt 0) {
        throw ("Invalid settings:`n- " + ($problems -join "`n- "))
    }
    return $s
}

function Read-SettingsFile {
    # What Import-PowerShellDataFile does (parse, then evaluate constants only, no code runs),
    # except the text is read as UTF-8: Windows PowerShell 5.1 reads a file without BOM as ANSI,
    # and a path like C:\Users\<name with an accent> would arrive broken.
    param([Parameter(Mandatory = $true)][string]$Path)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Path), $Path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "$Path line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)"
    }
    $hashtable = $ast.Find({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $false)
    if ($null -eq $hashtable) {
        throw "$Path must contain one @{ ... } block."
    }
    try {
        return $hashtable.SafeGetValue()
    }
    catch {
        throw "$Path may only hold plain values (text, numbers, @() and @{}): $($_.Exception.Message)"
    }
}

function Get-BackupSettings {
    param([string]$ConfigPath)

    $projectRoot = Get-BackupProjectRoot
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $projectRoot 'config\settings.psd1'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Settings not found: $ConfigPath. Copy config\settings.example.psd1 to config\settings.psd1 and set SourcePath and DestinationRoot."
    }
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    $settings = Resolve-BackupSettings -Raw (Read-SettingsFile -Path $ConfigPath)
    $configFolder = Split-Path -Parent $ConfigPath
    $settings.ConfigPath = $ConfigPath
    $settings.ProjectRoot = $projectRoot
    $settings.ResticPath = Join-Path $projectRoot 'bin\restic.exe'
    $settings.ExcludesPath = Join-Path $configFolder 'excludes.txt'
    $settings.MirrorExcludesPath = Join-Path $configFolder 'excludes-mirror.txt'
    return $settings
}

function Get-ExcludePatterns {
    # restic and robocopy both read these names. They agree on names and wildcards, not on paths,
    # so a line with a slash would mean one thing to the snapshot and another to the mirror.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $number = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $number++
        $pattern = $line.Trim()
        if (-not $pattern -or $pattern.StartsWith('#')) { continue }
        if ($pattern.Contains('\') -or $pattern.Contains('/')) {
            throw "$Path line ${number}: '$pattern' is a path. Use a file or folder name, wildcards allowed, because restic and robocopy read paths differently."
        }
        $pattern
    }
}

function Get-ResticExcludeLines {
    # restic matches a bare name against every folder of the absolute path, the parents of the
    # source included. With "build" in the list, a source at D:\build\app was backed up as nothing
    # at all, with exit code 0, while robocopy (which only looks below the source) filled the
    # mirror. Anchoring each name under the source makes the two agree.
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [AllowEmptyCollection()][string[]]$Patterns = @()
    )
    # "[" opens a character class in restic's patterns; "[[]" is a literal one. "]" alone is
    # already literal, and "*" and "?" cannot appear in a Windows path.
    $root = $SourcePath.TrimEnd('\').Replace('[', '[[]')
    foreach ($pattern in $Patterns) {
        "$root\**\$pattern"
    }
}

# ---------------------------------------------------------------------------------------------
# Locks and native commands

function Get-RunLockName {
    # One lock per destination: a manual run and the scheduled one exclude each other, while two
    # unrelated setups on one machine, like two test runs, do not.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('backup', 'hot-copy')][string]$Kind,
        [Parameter(Mandatory = $true)][hashtable]$Settings
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Settings.DestinationRoot.ToLowerInvariant()))
    }
    finally {
        $sha.Dispose()
    }
    return $Kind + '-' + (-join ($digest[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function Enter-RunLock {
    # Global\ and not Local\: the scheduled run lives in session 0 as SYSTEM, a manual run lives in
    # your session, and a Local\ mutex would let both refresh the mirror at the same time.
    param([Parameter(Mandatory = $true)][string]$Name)
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

function Invoke-NativeCapture {
    # Windows PowerShell 5.1 turns native stderr into a terminating error under
    # $ErrorActionPreference = 'Stop', so the preference is relaxed here, in this scope only.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object[]]$Arguments
    )
    $ErrorActionPreference = 'Continue'
    $out = New-Object Collections.Generic.List[string]
    $err = New-Object Collections.Generic.List[string]
    & $FilePath @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { $err.Add($_.ToString()) } else { $out.Add([string]$_) }
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; StdOut = $out.ToArray(); StdErr = $err.ToArray() }
}

function Invoke-NativeLogged {
    # Streams a long-running command into a log file line by line, echoing the interesting lines.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$QuietPattern = '"message_type"\s*:\s*"status"'
    )
    $ErrorActionPreference = 'Continue'
    $writer = New-Object IO.StreamWriter($OutputPath, $false, (New-Object Text.UTF8Encoding($false)))
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = $_.ToString()
            $writer.WriteLine($line)
            if ($line -notmatch $QuietPattern) { Write-Log -Message $line }
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $writer.Dispose()
    }
    return $exitCode
}

function Get-ResticBaseArguments {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [switch]$ReadOnly
    )
    $arguments = @('--repo', $Settings.RepositoryPath, '--password-file', $Settings.PasswordFile)
    if ($ReadOnly -and -not (Test-IsAdministrator)) {
        # Once the tasks are installed your account only reads the history, so restic cannot write
        # its lock file there. Reading without it is fine; a prune running at the same moment could
        # make the read fail, never damage the repository.
        return $arguments + @('--no-lock')
    }
    # --retry-lock: a restic check or prune you started by hand should delay the nightly run, not fail it.
    return $arguments + @('--retry-lock', '10m')
}

function Get-ResticSnapshots {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [switch]$ReadOnly
    )
    $arguments = (Get-ResticBaseArguments -Settings $Settings -ReadOnly:$ReadOnly) + @('--json', 'snapshots', '--tag', $script:ResticTag)
    $result = Invoke-NativeCapture -FilePath $Settings.ResticPath -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw "Could not list restic snapshots (exit code $($result.ExitCode)): $($result.StdErr -join ' ')"
    }
    $json = ($result.StdOut -join "`n").Trim()
    if (-not $json -or $json -eq 'null') { return }
    $json | ConvertFrom-Json | ForEach-Object { $_ } | Sort-Object { [DateTimeOffset]$_.time }
}

function Get-JsonProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-ResticBackupLog {
    # Pulls the snapshot id and the unreadable items out of `restic backup --json` output, so a
    # failed run can say which files to exclude instead of just "exit code 3".
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $snapshotId = $null
    $unreadable = New-Object Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($line -notmatch '"message_type"\s*:\s*"(summary|error)"') { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        $type = Get-JsonProperty $message 'message_type'
        if ($type -eq 'summary') {
            $id = Get-JsonProperty $message 'snapshot_id'
            if ($id) { $snapshotId = [string]$id }
        }
        elseif ($type -eq 'error') {
            $item = Get-JsonProperty $message 'item'
            $detail = Get-JsonProperty $message 'error'
            $text = Get-JsonProperty $detail 'message'
            if ($null -eq $text) { $text = [string]$detail }
            if ($item) { $unreadable.Add("$item ($text)") } elseif ($text) { $unreadable.Add([string]$text) }
        }
    }
    return [pscustomobject]@{ SnapshotId = $snapshotId; Unreadable = $unreadable.ToArray() }
}

# ---------------------------------------------------------------------------------------------
# Change reports

function ConvertTo-ChangeAction {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Modifier)
    $actions = New-Object Collections.Generic.List[string]
    if ($Modifier.Contains('+')) { $actions.Add('added') }
    if ($Modifier.Contains('-')) { $actions.Add('removed') }
    if ($Modifier.Contains('M')) { $actions.Add('modified') }
    if ($Modifier.Contains('U')) { $actions.Add('metadata') }
    if ($Modifier.Contains('T')) { $actions.Add('type-changed') }
    if ($Modifier.Contains('?')) { $actions.Add('possible-corruption') }
    if ($actions.Count -eq 0) { $actions.Add('unknown') }
    return ($actions -join '+')
}

function Get-RelativeSnapshotPath {
    # restic writes C:\Users\you\Projects\a.txt as /C/Users/you/Projects/a.txt. Returns the part
    # after the source folder, '(root)' for the folder itself, or $null for anything outside it.
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    $path = $SnapshotPath.Replace('\', '/').Trim()
    $source = $SourcePath.Replace('\', '/').TrimEnd('/')
    foreach ($candidate in @(('/' + $source.Replace(':', '')), ('/' + $source), $source)) {
        if ($path.Equals($candidate, [StringComparison]::OrdinalIgnoreCase) -or $path.Equals($candidate + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return '(root)'
        }
        if ($path.StartsWith($candidate + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $path.Substring($candidate.Length + 1)
        }
    }
    return $null
}

function ConvertFrom-ResticDiff {
    # Returns the changes worth reading. Metadata-only changes on folders are dropped: every file
    # change touches the timestamps of all its parent folders, and they would bury the files.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$PreviousId,
        [Parameter(Mandatory = $true)][string]$CurrentId,
        [Parameter(Mandatory = $true)][datetime]$BackupTime
    )
    $changes = New-Object Collections.Generic.List[object]
    $statistics = $null
    foreach ($line in $Lines) {
        if (-not $line.Trim()) { continue }
        $message = $line | ConvertFrom-Json
        $type = Get-JsonProperty $message 'message_type'
        if ($type -eq 'statistics') { $statistics = $message; continue }
        if ($type -ne 'change') { continue }
        $modifier = [string](Get-JsonProperty $message 'modifier')
        $snapshotPath = [string](Get-JsonProperty $message 'path')
        if ($modifier -eq 'U' -and $snapshotPath.EndsWith('/')) { continue }
        $relative = Get-RelativeSnapshotPath -SnapshotPath $snapshotPath -SourcePath $SourcePath
        if ($null -eq $relative) { continue }
        $area = '(root)'
        if ($relative -ne '(root)') { $area = ($relative -split '/')[0] }
        $extension = ''
        if (-not $relative.EndsWith('/') -and $relative -ne '(root)') {
            $extension = [IO.Path]::GetExtension($relative).ToLowerInvariant()
        }
        $changes.Add([pscustomobject][ordered]@{
                backup_time       = $BackupTime.ToString('o')
                previous_snapshot = $PreviousId
                current_snapshot  = $CurrentId
                modifier          = $modifier
                action            = ConvertTo-ChangeAction -Modifier $modifier
                path              = $relative
                extension         = $extension
                area              = $area
            })
    }
    return [pscustomobject]@{ Changes = $changes.ToArray(); Statistics = $statistics }
}

function ConvertTo-SafeCsvCell {
    # A file named "=HYPERLINK(...)" would become a live formula when the CSV opens in a
    # spreadsheet. The JSONL next to it keeps the raw value for scripts.
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '^[=+\-@\t\r]') { return "'" + $Value }
    return $Value
}

$script:ChangeColumns = @('backup_time', 'previous_snapshot', 'current_snapshot', 'modifier', 'action', 'path', 'extension', 'area')

function Write-ChangeCsv {
    # UTF-8 with BOM: without it Excel reads the file as ANSI and garbles accented paths.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $lines = @(($script:ChangeColumns | ForEach-Object { '"' + $_ + '"' }) -join ',')
    if ($Changes.Count -gt 0) {
        $safe = $Changes | ForEach-Object {
            $row = [ordered]@{}
            foreach ($column in $script:ChangeColumns) { $row[$column] = $_.$column }
            $row.path = ConvertTo-SafeCsvCell $row.path
            $row.area = ConvertTo-SafeCsvCell $row.area
            [pscustomobject]$row
        }
        $lines = @($safe | ConvertTo-Csv -NoTypeInformation)
    }
    [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
}

function Format-ByteCount {
    param([double]$Bytes)
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($Bytes -ge 1024 -and $index -lt $units.Count - 1) { $Bytes /= 1024; $index++ }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.#} {1}', $Bytes, $units[$index])
}

function New-ChangeMarkdown {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [AllowNull()][object]$Statistics,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$PreviousId,
        [Parameter(Mandatory = $true)][string]$CurrentId
    )
    $b = New-Object Text.StringBuilder
    [void]$b.AppendLine("# Changes in backup $RunId")
    [void]$b.AppendLine()
    [void]$b.AppendLine(('- Previous snapshot: `{0}`' -f $PreviousId))
    [void]$b.AppendLine(('- Current snapshot: `{0}`' -f $CurrentId))
    [void]$b.AppendLine("- Changed paths: $($Changes.Count)")
    if ($Statistics) {
        $added = Get-JsonProperty (Get-JsonProperty $Statistics 'added') 'bytes'
        $removed = Get-JsonProperty (Get-JsonProperty $Statistics 'removed') 'bytes'
        if ($null -ne $added) { [void]$b.AppendLine("- Added to the snapshot: $(Format-ByteCount $added)") }
        if ($null -ne $removed) { [void]$b.AppendLine("- Removed from the snapshot: $(Format-ByteCount $removed)") }
    }
    $sections = @(
        @{ Title = 'By action'; Property = 'action'; Top = 0 },
        @{ Title = 'Areas with the most changes'; Property = 'area'; Top = 20 },
        @{ Title = 'Extensions with the most changes'; Property = 'extension'; Top = 20 }
    )
    foreach ($section in $sections) {
        [void]$b.AppendLine()
        [void]$b.AppendLine("## $($section.Title)")
        [void]$b.AppendLine()
        $groups = @($Changes | Group-Object -Property $section.Property | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
        if ($section.Top -gt 0) { $groups = @($groups | Select-Object -First $section.Top) }
        foreach ($group in $groups) {
            $name = $group.Name
            if ([string]::IsNullOrEmpty($name)) { $name = '(none)' }
            [void]$b.AppendLine("- ${name}: $($group.Count)")
        }
    }
    [void]$b.AppendLine()
    [void]$b.AppendLine('## First 100 changes')
    [void]$b.AppendLine()
    foreach ($change in @($Changes | Select-Object -First 100)) {
        [void]$b.AppendLine(('- [{0}] `{1}`' -f $change.action, $change.path))
    }
    if ($Changes.Count -gt 100) {
        [void]$b.AppendLine("- ... and $($Changes.Count - 100) more in the CSV next to this file.")
    }
    return $b.ToString()
}

function Get-ReportFolder {
    param([Parameter(Mandatory = $true)][hashtable]$Settings, [Parameter(Mandatory = $true)][datetime]$When)
    $folder = Join-Path (Join-Path $Settings.ReportsPath $When.ToString('yyyy')) $When.ToString('MM')
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    return $folder
}

function New-BaselineReport {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][string]$CurrentId
    )
    $base = Join-Path (Get-ReportFolder -Settings $Settings -When $StartedAt) "baseline_${RunId}_$($CurrentId.Substring(0, 8))"
    $record = [ordered]@{ message_type = 'baseline'; created_at = $StartedAt.ToString('o'); snapshot = $CurrentId; source = $Settings.SourcePath } | ConvertTo-Json -Compress
    Write-Utf8NoBom -Path ($base + '.jsonl') -Content ($record + "`n")
    Write-ChangeCsv -Changes @() -Path ($base + '.csv')
    Write-Utf8NoBom -Path ($base + '.md') -Content ("# Baseline snapshot`n`nFirst snapshot of this history: ``$CurrentId``.`n`nThere is nothing to compare it with yet; the next backup gets a change report.`n")
    Write-Log -Message "Baseline report written: $base.md"
}

function New-ChangeReport {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][string]$PreviousId,
        [Parameter(Mandatory = $true)][string]$CurrentId
    )
    $arguments = (Get-ResticBaseArguments -Settings $Settings) + @('--json', 'diff', '--metadata', $PreviousId, $CurrentId)
    $diff = Invoke-NativeCapture -FilePath $Settings.ResticPath -Arguments $arguments
    if ($diff.ExitCode -ne 0) {
        $known = @(Get-ResticSnapshots -Settings $Settings | ForEach-Object { $_.id })
        if ($known -notcontains $PreviousId) {
            # Someone forgot or pruned it by hand. Failing here would fail every run from now on.
            Write-Log -Level WARN -Message "Previous snapshot $PreviousId no longer exists; starting a new baseline."
            New-BaselineReport -Settings $Settings -RunId $RunId -StartedAt $StartedAt -CurrentId $CurrentId
            return
        }
        throw "restic diff failed (exit code $($diff.ExitCode)): $($diff.StdErr -join ' ')"
    }
    $base = Join-Path (Get-ReportFolder -Settings $Settings -When $StartedAt) "changes_${RunId}_$($CurrentId.Substring(0, 8))"
    Write-Utf8NoBom -Path ($base + '.jsonl') -Content (($diff.StdOut -join "`n") + "`n")
    $parsed = ConvertFrom-ResticDiff -Lines $diff.StdOut -SourcePath $Settings.SourcePath -PreviousId $PreviousId -CurrentId $CurrentId -BackupTime $StartedAt
    Write-ChangeCsv -Changes $parsed.Changes -Path ($base + '.csv')
    Write-Utf8NoBom -Path ($base + '.md') -Content (New-ChangeMarkdown -Changes $parsed.Changes -Statistics $parsed.Statistics -RunId $RunId -PreviousId $PreviousId -CurrentId $CurrentId)
    Write-Log -Message "Change report written: $base.md ($($parsed.Changes.Count) changed paths)"
}

# ---------------------------------------------------------------------------------------------
# Mirror

function Assert-MirrorTarget {
    # robocopy /MIR deletes whatever the destination has and the source does not. It only ever
    # runs into a folder that is empty or carries our marker naming this very source.
    param(
        [Parameter(Mandatory = $true)][string]$MirrorPath,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    $marker = Join-Path $MirrorPath $script:MirrorMarkerName
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $owner = ([IO.File]::ReadAllText($marker)).Trim()
        if (-not $owner.Equals($SourcePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The mirror at $MirrorPath is a copy of '$owner', not of '$SourcePath'. Refreshing it would replace that copy. Use another DestinationRoot, or delete $marker if you really mean to reuse it."
        }
        return
    }
    # Never created here: install.ps1 creates every managed folder with its permissions, and a folder
    # made here would inherit the drive's, which usually let every local account read a plain copy.
    if (-not (Test-Path -LiteralPath $MirrorPath -PathType Container)) {
        throw "The mirror folder $MirrorPath is missing. Run scripts\install.ps1 again: it creates it with the right permissions."
    }
    if (@(Get-ChildItem -LiteralPath $MirrorPath -Force | Select-Object -First 1).Count -gt 0) {
        throw "$MirrorPath already holds files that restic-twin did not put there, and the mirror refresh deletes anything that is not in the source. Empty that folder or choose another DestinationRoot."
    }
    Write-Utf8NoBom -Path $marker -Content ($SourcePath + "`n")
}

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

function Update-Mirror {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    Assert-MirrorTarget -MirrorPath $Settings.MirrorPath -SourcePath $Settings.SourcePath
    $exclusions = @(Get-ExcludePatterns -Path $Settings.ExcludesPath) + @(Get-ExcludePatterns -Path $Settings.MirrorExcludesPath)
    Write-Log -Message "Refreshing the mirror in $($Settings.MirrorPath)."
    $result = Invoke-NativeCapture -FilePath 'robocopy.exe' -Arguments (Get-MirrorArguments -Settings $Settings -Exclusions $exclusions -LogPath $LogPath)
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
    Write-Log -Message "Mirror refreshed; robocopy exit code $($result.ExitCode)."
    return $result.ExitCode
}

# ---------------------------------------------------------------------------------------------
# Hot copies

function Get-HotCopyVersions {
    # Version folders, oldest first. "2026-09-23_101500-2" is a second copy in the same second.
    param([Parameter(Mandatory = $true)][string]$SetPath)
    if (-not (Test-Path -LiteralPath $SetPath -PathType Container)) { return }
    Get-ChildItem -LiteralPath $SetPath -Directory |
        Where-Object { $_.Name -match $script:HotCopyVersionPattern } |
        Sort-Object -Property @{ Expression = { $_.Name.Substring(0, 17) } }, @{ Expression = { if ($_.Name.Length -gt 17) { [int]$_.Name.Substring(18) } else { 1 } } }
}

function Test-SameFolderContent {
    param([Parameter(Mandatory = $true)][string]$Left, [Parameter(Mandatory = $true)][string]$Right)
    $a = @(Get-ChildItem -LiteralPath $Left -File | Sort-Object Name)
    $b = @(Get-ChildItem -LiteralPath $Right -File | Sort-Object Name)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i].Name -ne $b[$i].Name -or $a[$i].Length -ne $b[$i].Length) { return $false }
        if ((Get-FileHash -LiteralPath $a[$i].FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $b[$i].FullName -Algorithm SHA256).Hash) { return $false }
    }
    return $true
}

function Invoke-HotCopySet {
    # Copies every file of the set into a staging folder first and compares the copies, not the
    # originals, with the newest version: a file that changes mid-run cannot end up half-recorded.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Set,
        [Parameter(Mandatory = $true)][string]$HotCopiesPath,
        [datetime]$Now = (Get-Date)
    )
    foreach ($file in $Set.Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "file not found: $file" }
    }
    $setPath = Join-Path $HotCopiesPath $Set.Name
    New-Item -ItemType Directory -Path $setPath -Force | Out-Null
    Get-ChildItem -LiteralPath $setPath -Directory -Filter '.incoming-*' | Remove-Item -Recurse -Force
    $incoming = Join-Path $setPath ('.incoming-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $incoming | Out-Null
    try {
        foreach ($file in $Set.Files) { Copy-Item -LiteralPath $file -Destination $incoming }
        $versions = @(Get-HotCopyVersions -SetPath $setPath)
        if ($versions.Count -gt 0 -and (Test-SameFolderContent -Left $incoming -Right $versions[-1].FullName)) {
            return [pscustomobject]@{ Name = $Set.Name; Result = 'unchanged'; Version = $versions[-1].Name; Removed = @() }
        }
        $stamp = $Now.ToString('yyyy-MM-dd_HHmmss')
        $version = $stamp
        $n = 1
        while (Test-Path -LiteralPath (Join-Path $setPath $version)) { $n++; $version = "$stamp-$n" }
        Move-Item -LiteralPath $incoming -Destination (Join-Path $setPath $version)
        $incoming = $null
        $versions = @(Get-HotCopyVersions -SetPath $setPath)
        $removed = @()
        if ($versions.Count -gt $Set.Keep) {
            foreach ($old in @($versions | Select-Object -First ($versions.Count - $Set.Keep))) {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
                $removed += $old.Name
            }
        }
        return [pscustomobject]@{ Name = $Set.Name; Result = 'copied'; Version = $version; Removed = $removed }
    }
    finally {
        if ($incoming -and (Test-Path -LiteralPath $incoming)) { Remove-Item -LiteralPath $incoming -Recurse -Force }
    }
}

# ---------------------------------------------------------------------------------------------
# Install helpers

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
        [switch]$Owner
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
        ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) = $userRights
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
        [switch]$Owner
    )
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    if ($Owner) {
        $ownerSid = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -ne 'S-1-5-32-544' -and $ownerSid -ne 'S-1-5-18') { return $false }
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    $want = @{ 'S-1-5-18' = $full; 'S-1-5-32-544' = $full; $sid = $full }
    if ($UserAccess -eq 'Read') { $want[$sid] = $read }
    $rules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' })
    if ($rules.Count -ne $want.Count -or @($acl.Access | Where-Object { $_.AccessControlType -ne 'Allow' }).Count -gt 0) { return $false }
    foreach ($rule in $rules) {
        $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if (-not $want.ContainsKey($ruleSid) -or $rule.FileSystemRights -ne $want[$ruleSid]) { return $false }
    }
    return $true
}

function Set-PasswordFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        Set-ExactAcl -Path $Path -Rights @{
            'S-1-5-18'     = 'Read, Synchronize'
            'S-1-5-32-544' = 'Read, Synchronize'
            ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) = 'Read, Synchronize'
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-DiskNumber {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        return (Get-Partition -DriveLetter ([IO.Path]::GetPathRoot($Path).Substring(0, 1)) -ErrorAction Stop).DiskNumber
    }
    catch {
        return $null
    }
}

function Get-TaskPowerShellPath {
    # Only hosts installed for the whole machine: the daily task runs them as SYSTEM, and a
    # per-user pwsh (Store, portable, a folder in your profile) is one a normal user can replace.
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $pwsh -PathType Leaf) { return $pwsh }
    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-InstalledFileDifferences {
    # Compares what the scheduled tasks run (the installed copy) with this folder and its settings.
    param([Parameter(Mandatory = $true)][hashtable]$Settings)
    $installRoot = Get-InstallRoot
    $pairs = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Settings.ProjectRoot 'scripts') -File | Where-Object { $_.Extension -in '.ps1', '.vbs' })) {
        $pairs += , @($file.FullName, (Join-Path $installRoot ('scripts\' + $file.Name)))
    }
    $pairs += , @($Settings.ConfigPath, (Join-Path $installRoot 'config\settings.psd1'))
    foreach ($path in @($Settings.ExcludesPath, $Settings.MirrorExcludesPath)) {
        $pairs += , @($path, (Join-Path $installRoot ('config\' + (Split-Path -Leaf $path))))
    }
    $pairs += , @($Settings.ResticPath, (Join-Path $installRoot 'bin\restic.exe'))
    foreach ($pair in $pairs) {
        $here = Test-Path -LiteralPath $pair[0] -PathType Leaf
        $there = Test-Path -LiteralPath $pair[1] -PathType Leaf
        if (-not $here -and -not $there) { continue }
        if ($here -ne $there -or (Get-FileHash -LiteralPath $pair[0]).Hash -ne (Get-FileHash -LiteralPath $pair[1]).Hash) {
            $pair[1]
        }
    }
}
