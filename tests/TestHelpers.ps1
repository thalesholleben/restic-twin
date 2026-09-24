# Dot-sourced by the test files after scripts\common.ps1. Every test works in $TestDrive: nothing
# here may touch a real source folder, a real backup drive or a scheduled task.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

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
    $path = Join-Path $Folder 'settings.psd1'
    $text = "@{`r`n    SourcePath = '$Source'`r`n    DestinationRoot = '$Destination'`r`n$Extra`r`n}`r`n"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'config\excludes.txt') -Destination $Folder
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'config\excludes-mirror.txt') -Destination $Folder
    return $path
}

function Invoke-RepoScript {
    # Runs one of the scripts in a child process of the same PowerShell edition as the test run,
    # so the CI matrix proves both pwsh 7 and Windows PowerShell 5.1.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @()
    )
    $powershell = (Get-Process -Id $PID).Path
    $all = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:RepoRoot "scripts\$Name")) + $Arguments
    $result = Invoke-NativeCapture -FilePath $powershell -Arguments $all
    Add-Member -InputObject $result -NotePropertyName Text -NotePropertyValue ((@($result.StdOut) + @($result.StdErr)) -join "`n")
    return $result
}

function New-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Content = 'x')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}
