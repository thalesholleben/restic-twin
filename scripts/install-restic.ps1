[CmdletBinding()]
param(
    [string]$Version = '0.19.0',
    [switch]$AllowUnpinned
)

# Downloads the official restic release for Windows into bin\restic.exe.
#
# The zip is checked twice: against the SHA256SUMS file of the release, and against a hash pinned
# in this script when the version was reviewed. SHA256SUMS comes from the same place as the zip,
# so on its own it only catches a broken download; the pinned hash also catches a swapped release.

# One clean line instead of a stack trace, and exit code 1 for the Task Scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$pinned = @{
    '0.19.0' = '6FA4219A70B1B5D1C429BB106A7F97F3D2A5AAB74494DB2E490B625EDC486D8F'
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must look like 0.19.0: '$Version'."
}
if (-not $pinned.ContainsKey($Version) -and -not $AllowUnpinned) {
    throw "restic $Version has no pinned checksum in this script. Pass -AllowUnpinned to trust the SHA256SUMS file of that release on its own."
}

$binPath = Join-Path (Get-BackupProjectRoot) 'bin'
$resticPath = Join-Path $binPath 'restic.exe'
$assetName = "restic_${Version}_windows_amd64.zip"
$baseUrl = "https://github.com/restic/restic/releases/download/v$Version"
$tempPath = Join-Path ([IO.Path]::GetTempPath()) ('restic-twin-' + [guid]::NewGuid().ToString('N'))

# Windows PowerShell 5.1 can still default to TLS 1.0, which GitHub refuses. The progress bar
# makes Invoke-WebRequest in 5.1 many times slower.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

try {
    New-Item -ItemType Directory -Path $binPath, $tempPath -Force | Out-Null
    $zipPath = Join-Path $tempPath $assetName
    $sumsPath = Join-Path $tempPath 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$assetName" -OutFile $zipPath
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS" -OutFile $sumsPath

    $sumLine = Get-Content -LiteralPath $sumsPath | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($assetName) + '$') } | Select-Object -First 1
    if (-not $sumLine) { throw "SHA256SUMS of restic $Version has no line for $assetName." }
    $published = ($sumLine -split '\s+')[0].ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $published) {
        throw "Checksum mismatch for $assetName. SHA256SUMS says $published, the download is $actual."
    }
    if ($pinned.ContainsKey($Version) -and $actual -ne $pinned[$Version]) {
        throw "Checksum mismatch for $assetName. This script pinned $($pinned[$Version]), the release now serves $actual. Do not use it until you know why."
    }

    $extractPath = Join-Path $tempPath 'extract'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $executable = Get-ChildItem -LiteralPath $extractPath -Filter '*.exe' -File -Recurse | Select-Object -First 1
    if (-not $executable) { throw "No executable inside $assetName." }

    $reported = (& $executable.FullName version) -join ' '
    if ($LASTEXITCODE -ne 0 -or $reported -notmatch ('^restic ' + [regex]::Escape($Version) + '\b')) {
        throw "The downloaded binary does not report restic ${Version}: '$reported'."
    }

    Copy-Item -LiteralPath $executable.FullName -Destination $resticPath -Force
    Write-Utf8NoBom -Path (Join-Path $binPath 'version.txt') -Content ("restic $Version`nasset $assetName`nasset_sha256 $actual`nbinary_sha256 $((Get-FileHash -LiteralPath $resticPath -Algorithm SHA256).Hash)`n")
    Write-Host "Installed: $reported"
    Write-Host "At: $resticPath"
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
