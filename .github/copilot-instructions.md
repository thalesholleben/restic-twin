# Copilot instructions

restic-twin is a daily restic backup of one Windows folder to a second drive, in PowerShell: an
encrypted snapshot through VSS, a change report, then a robocopy mirror, from a scheduled task that
runs as SYSTEM, plus frequent copies of a few listed files.

## Running and validating

```powershell
.\scripts\install-restic.ps1                    # restic.exe into bin\, needed by the end-to-end test
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path tests -Output Detailed
```

The suite must pass on PowerShell 7 and on Windows PowerShell 5.1. CI runs both on `windows-latest`.

## Layout

- `scripts/common.ps1`: settings and validation, locks, native calls, reports, mirror guard, hot copies.
- `scripts/backup.ps1`: the daily run. `hot-copy.ps1`, `install.ps1`, `install-restic.ps1`,
  `restore.ps1`, `status.ps1`, `uninstall.ps1`: what their names say.
- `config/`: `settings.example.psd1` and the exclude lists. `settings.psd1` belongs to the user.
- `tests/`: Pester 5.9.1, always against temporary folders.

## Rules

- Windows PowerShell 5.1 syntax and ASCII only in `scripts/`.
- Use `[IO.Path]::Combine`, not `Join-Path`, for paths on the backup drive before the drive is checked.
- robocopy `/MIR` only through `Update-Mirror`, which checks the mirror marker first.
- The snapshot always comes before the mirror; any restic exit code other than 0 fails the run.
- Exclude patterns reach restic anchored under the source, through `Get-ResticExcludeLines`.
- Code that runs as SYSTEM runs from `C:\Program Files\restic-twin`, never from the clone.
- Tests never register tasks and never touch real folders.
