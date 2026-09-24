# AGENTS.md

Instructions for coding agents working on this repository. Humans: start at
[README.md](README.md).

## What this is

A daily restic backup of one Windows folder to a second drive: an encrypted snapshot through VSS,
a change report, then a robocopy mirror, from a scheduled task that runs as SYSTEM. Plus frequent
"hot copies" of a few listed files. PowerShell only, no dependencies besides restic.

| Path | Role |
|---|---|
| `scripts/common.ps1` | Everything shared: settings and their validation, locks, native calls, reports, mirror guard, hot copies, install helpers |
| `scripts/backup.ps1` | The daily run. Order: lock, checks, snapshot, report, state, mirror, retention, run record |
| `scripts/hot-copy.ps1` | The frequent copies, one run over every set in `HotCopies` |
| `scripts/install.ps1` | Folders, password, repository, recovery notes, copy to Program Files, scheduled tasks |
| `scripts/install-restic.ps1` | Downloads restic into `bin/` and checks it against SHA256SUMS and a pinned hash |
| `scripts/restore.ps1`, `status.ps1`, `uninstall.ps1` | What their names say |
| `scripts/run-hidden.vbs` | Starts PowerShell without a console window for the hot copy task |
| `config/` | `settings.example.psd1` and the two exclude lists. `settings.psd1` is the user's and is ignored by git |
| `tests/` | Pester 5.9.1. Unit tests, real filesystem tests with robocopy, and an end-to-end run with the real restic |

## Commands

```powershell
.\scripts\install-restic.ps1                               # puts restic.exe in bin\ (tests need it)
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path tests -Output Detailed                  # about 40 seconds
powershell -NoProfile -Command "Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester -Path tests"
```

The suite has to be green on both `pwsh` and Windows PowerShell 5.1 (`powershell`). CI runs both on
`windows-latest`.

## Rules that are not obvious

1. **Windows PowerShell 5.1 compatible, and ASCII only.** No `??`, no ternary, no `&&`, no
   `-AsHashtable`. 5.1 reads a file without BOM as ANSI, so every script stays ASCII; a test enforces
   both.
2. **Never `Join-Path` a path under `DestinationRoot` before the drive is checked.** `Join-Path`
   fails when the drive does not exist, and an unplugged backup drive must end in "drive not
   available", not in a crash. Use `[IO.Path]::Combine`.
3. **robocopy `/MIR` only runs through `Update-Mirror`**, which calls `Assert-MirrorTarget` first.
   Never call robocopy with `/MIR` anywhere else, and never weaken the marker check.
4. **Snapshot before mirror.** The history must be safe before the mirror loses anything.
5. **Any restic exit code other than 0 fails the run**, exit code 3 included, and the error has to
   say which items. robocopy 0 to 7 is success, 8 or more fails.
6. **Exclude patterns reach restic anchored under the source** (`Get-ResticExcludeLines`). Passing
   `config\excludes.txt` to restic directly brings back the bug where a parent folder named like a
   pattern excluded everything.
7. **Native calls go through `Invoke-NativeCapture` or `Invoke-NativeLogged`**, which relax
   `$ErrorActionPreference` locally: 5.1 turns native stderr into a terminating error otherwise.
8. **Anything that runs as SYSTEM runs from `C:\Program Files\restic-twin`**, never from the clone,
   and **never reads back a file a normal account can write**. With the tasks installed, the folders
   SYSTEM writes belong to Administrators and the user only reads them (`Set-PrivateFolderAcl -UserAccess
   Read -Owner`). A value read back and passed to restic is validated first (snapshot ids: 64 hex).
   The user's own task (hot copies) writes only under `hot-copies\`.
9. **The installer never replaces a password** and never re-creates a repository.
10. **Tests never touch real folders or tasks.** Everything goes to `$TestDrive` or a temp folder
    the test deletes. Never run `install.ps1` without `-SkipScheduledTask` in a test.
11. Settings are read by `Read-SettingsFile`, which parses and evaluates constants only, as UTF-8.
    Do not go back to `Import-PowerShellDataFile`.
12. When behaviour changes, update `README.md`, `README.pt-BR.md` and the page under `docs/`, and
    add a test that fails without the change.

## What to ignore

`bin/restic.exe`, `bin/version.txt`, `config/settings.psd1`, and anything under a destination folder.
