[CmdletBinding()]
param(
    [string]$Version = '0.19.0',
    [switch]$AllowUnpinned
)

# Downloads the official restic release for this platform into bin\: restic.exe on Windows, restic
# on macOS (Apple silicon or Intel).
#
# The download is checked twice: against the SHA256SUMS file of the release, and against a hash
# pinned in this script when the version was reviewed. SHA256SUMS comes from the same place as the
# download, so on its own it only catches a broken one; the pinned hash also catches a swapped release.

# One clean line instead of a stack trace, and exit code 1 for the scheduler.
trap { [Console]::Error.WriteLine('error: ' + $_.Exception.Message); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$pinned = @{
    'restic_0.19.0_windows_amd64.zip' = '6FA4219A70B1B5D1C429BB106A7F97F3D2A5AAB74494DB2E490B625EDC486D8F'
    'restic_0.19.0_darwin_arm64.bz2'  = '1475397BF759EF4BE16A77B19DEC650BDBFEC00D2CACD82005553411CDD37997'
    'restic_0.19.0_darwin_amd64.bz2'  = 'C9D9A71234BC0955FDBA6DA93CC9375F8793EC1E1CBCE77A91014D536A969148'
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must look like 0.19.0: '$Version'."
}
if ($script:OnWindows) {
    $assetName = "restic_${Version}_windows_amd64.zip"
}
else {
    $machine = (@(Invoke-Checked -FilePath '/usr/bin/uname' -Arguments @('-m')) -join '').Trim()
    $architecture = 'amd64'
    if ($machine -eq 'arm64') { $architecture = 'arm64' }
    $assetName = "restic_${Version}_darwin_$architecture.bz2"
}
if (-not $pinned.ContainsKey($assetName) -and -not $AllowUnpinned) {
    throw "$assetName has no pinned checksum in this script. Pass -AllowUnpinned to trust the SHA256SUMS file of that release on its own."
}

$binPath = [IO.Path]::Combine((Get-BackupProjectRoot), 'bin')
$resticPath = [IO.Path]::Combine($binPath, $script:ResticFileName)
$baseUrl = "https://github.com/restic/restic/releases/download/v$Version"
$tempPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'restic-twin-' + [guid]::NewGuid().ToString('N'))

# Windows PowerShell 5.1 can still default to TLS 1.0, which GitHub refuses. The progress bar
# makes Invoke-WebRequest in 5.1 many times slower.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

try {
    New-Item -ItemType Directory -Path $binPath, $tempPath -Force | Out-Null
    $downloadPath = [IO.Path]::Combine($tempPath, $assetName)
    $sumsPath = [IO.Path]::Combine($tempPath, 'SHA256SUMS')
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$assetName" -OutFile $downloadPath
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS" -OutFile $sumsPath

    $sumLine = Get-Content -LiteralPath $sumsPath | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($assetName) + '$') } | Select-Object -First 1
    if (-not $sumLine) { throw "SHA256SUMS of restic $Version has no line for $assetName." }
    $published = ($sumLine -split '\s+')[0].ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $published) {
        throw "Checksum mismatch for $assetName. SHA256SUMS says $published, the download is $actual."
    }
    if ($pinned.ContainsKey($assetName) -and $actual -ne $pinned[$assetName]) {
        throw "Checksum mismatch for $assetName. This script pinned $($pinned[$assetName]), the release now serves $actual. Do not use it until you know why."
    }

    $extractPath = [IO.Path]::Combine($tempPath, 'extract')
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    if ($script:OnWindows) {
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractPath -Force
        $executable = Get-ChildItem -LiteralPath $extractPath -Filter '*.exe' -File -Recurse | Select-Object -First 1
        if (-not $executable) { throw "No executable inside $assetName." }
        $executablePath = $executable.FullName
    }
    else {
        # macOS ships bunzip2; -c writes the binary to stdout and leaves the download in place.
        $executablePath = [IO.Path]::Combine($extractPath, 'restic')
        $null = Invoke-Checked -FilePath '/bin/sh' -Arguments @('-c', 'bunzip2 -c "$1" > "$2" && chmod 755 "$2"', 'sh', $downloadPath, $executablePath)
    }

    $reported = (& $executablePath version) -join ' '
    if ($LASTEXITCODE -ne 0 -or $reported -notmatch ('^restic ' + [regex]::Escape($Version) + '\b')) {
        throw "The downloaded binary does not report restic ${Version}: '$reported'."
    }

    Copy-Item -LiteralPath $executablePath -Destination $resticPath -Force
    if (-not $script:OnWindows) { $null = Invoke-Checked -FilePath '/bin/chmod' -Arguments @('755', $resticPath) }
    Write-Utf8NoBom -Path ([IO.Path]::Combine($binPath, 'version.txt')) -Content ("restic $Version`nasset $assetName`nasset_sha256 $actual`nbinary_sha256 $((Get-FileHash -LiteralPath $resticPath -Algorithm SHA256).Hash)`n")
    Write-Host "Installed: $reported"
    Write-Host "At: $resticPath"
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
