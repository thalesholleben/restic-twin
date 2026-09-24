# Copilot instructions

restic-twin is a daily restic backup of one folder to a second drive, in PowerShell: an encrypted
snapshot, a change report, then a plain mirror, from a job that runs as SYSTEM on Windows (VSS,
robocopy) or as root on macOS (launchd, rsync; beta), plus frequent copies of a few listed files.

## Running and validating

```powershell
./scripts/install-restic.ps1                    # restic into bin/, needed by the end-to-end test
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path tests -Output Detailed
```

The suite must pass on PowerShell 7 and on Windows PowerShell 5.1 on Windows, and on PowerShell 7 on
macOS. CI runs all three.

## Layout

- `scripts/common.ps1`: settings and validation, locks, native calls, reports, mirror guard, hot copies.
- `scripts/windows.ps1`, `scripts/macos.ps1`: the same functions for each platform (paths,
  permissions, lock, mirror copy, schedules). `common.ps1` loads the one for the running OS.
- `scripts/backup.ps1`: the daily run. `hot-copy.ps1`, `install.ps1`, `install-restic.ps1`,
  `restore.ps1`, `status.ps1`, `uninstall.ps1`: what their names say.
- `config/`: the two settings examples and the exclude lists. `settings.psd1` belongs to the user.
- `tests/`: Pester 5.9.1, always against temporary folders.

## Rules

- Windows PowerShell 5.1 syntax and ASCII only in `scripts/`, `macos.ps1` included.
- A platform difference goes into both adapters as one function, not into an `if` in `common.ps1`.
- Use `[IO.Path]::Combine`, not `Join-Path`, for paths on the backup drive before the drive is checked.
- The mirror copy (robocopy `/MIR`, rsync `--delete`) only through `Update-Mirror`, which checks the
  mirror marker first.
- The snapshot always comes before the mirror; any restic exit code other than 0 fails the run.
- Exclude patterns reach restic anchored under the source, through `Get-ResticExcludeLines`.
- Code that runs as SYSTEM or root runs from the installed copy, never from the clone.
- Tests never register jobs and never touch real folders.
