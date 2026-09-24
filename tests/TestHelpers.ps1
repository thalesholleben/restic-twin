# Dot-sourced by the test files at discovery (for -ForEach and -Skip) and again after
# scripts/common.ps1. Every test works in $TestDrive or in its own temporary folder: nothing here may
# touch a real source folder, a real backup drive or a scheduled job.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:OnWindowsTest = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path variable:IsWindows) -and $IsWindows)
$script:ResticTestName = 'restic'
if ($script:OnWindowsTest) { $script:ResticTestName = 'restic.exe' }
$script:HasRestic = Test-Path -LiteralPath ([IO.Path]::Combine($script:RepoRoot, 'bin', $script:ResticTestName))

function Test-TestElevated {
    if ($script:OnWindowsTest) {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return ((@(& /usr/bin/id -u) -join '').Trim() -eq '0')
}

function Join-TestPath {
    # Join-Path for fixtures written with backslashes: every separator in the child becomes a segment,
    # so the same line works on Windows and on macOS.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )
    $parts = @($Path) + @($ChildPath -split '[\\/]' | Where-Object { $_ })
    return [IO.Path]::Combine([string[]]$parts)
}

function ConvertTo-TestPath {
    # Settings fixtures are written as Windows paths. On macOS the same case becomes C:\a -> /a and
    # E:\a -> /Volumes/E/a.
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:OnWindowsTest) { return $Path }
    if ($Path -match '^([A-Za-z]):\\?(.*)$') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = $Matches[2].Replace('\', '/')
        if ($drive -eq 'C') { return '/' + $rest }
        if ($rest) { return "/Volumes/$drive/$rest" }
        return "/Volumes/$drive"
    }
    return $Path.Replace('\', '/')
}

function Get-TestWorkRoot {
    # A fresh folder for a stateful scenario, outside $TestDrive: Pester deletes what a Context
    # added there when the Context ends. On macOS the real path, because /var is a link to
    # /private/var and restic records a linked parent as a link, not as the folders below it.
    $root = [IO.Path]::GetTempPath()
    if (-not $script:OnWindowsTest -and $root.StartsWith('/var/')) { $root = '/private' + $root }
    return [IO.Path]::Combine($root, 'restic-twin-e2e-' + [guid]::NewGuid().ToString('N'))
}

function Remove-TestFolder {
    # The password file is read-only on purpose and some tests make folders read-only: take
    # everything back before deleting.
    param([AllowNull()][string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    if ($script:OnWindowsTest) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = & icacls.exe $Path /grant "*${sid}:F" /T /C /Q 2>&1
        Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
    }
    else {
        $null = & /bin/chmod -R u+rwX $Path 2>&1
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Set-TestReadOnlyTree {
    # What an elevated install does to the history, as far as a normal account can do it to itself.
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:OnWindowsTest) { Set-PrivateFolderAcl -Path $Path -UserAccess Read }
    else { $null = & /bin/chmod -R a-w $Path 2>&1 }
}

function Reset-TestWritableTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:OnWindowsTest) { Set-PrivateFolderAcl -Path $Path -UserAccess Full }
    else { $null = & /bin/chmod -R u+w $Path 2>&1 }
}

function New-TestSettingsFile {
    # Writes settings.psd1 and the two exclude lists into $Folder, as UTF-8 without BOM on purpose:
    # that is what Notepad saves, and the case Windows PowerShell 5.1 gets wrong on its own.
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Extra = ''
    )
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $path = [IO.Path]::Combine($Folder, 'settings.psd1')
    $text = "@{`r`n    SourcePath = '$Source'`r`n    DestinationRoot = '$Destination'`r`n$Extra`r`n}`r`n"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    foreach ($name in @('excludes.txt', 'excludes-mirror.txt')) {
        Copy-Item -LiteralPath ([IO.Path]::Combine($script:RepoRoot, 'config', $name)) -Destination $Folder
    }
    return $path
}

function Invoke-RepoScript {
    # Runs one of the scripts in a child process of the same PowerShell as the test run, so the CI
    # matrix proves pwsh 7 on Windows and macOS, and Windows PowerShell 5.1.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @()
    )
    $powershell = (Get-Process -Id $PID).Path
    $all = @('-NoLogo', '-NoProfile', '-NonInteractive')
    if ($script:OnWindowsTest) { $all += @('-ExecutionPolicy', 'Bypass') }
    $all += @('-File', [IO.Path]::Combine($script:RepoRoot, 'scripts', $Name)) + $Arguments
    $result = Invoke-NativeCapture -FilePath $powershell -Arguments $all
    Add-Member -InputObject $result -NotePropertyName Text -NotePropertyValue ((@($result.StdOut) + @($result.StdErr)) -join "`n")
    return $result
}

function New-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Content = 'x')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}
