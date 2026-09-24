# AGENTS.md

Instructions for coding agents working on this repository. Humans: start at
[README.md](README.md).

## What this is

A daily restic backup of one folder to a second drive: an encrypted snapshot, a change report, then
a plain mirror, from a job that runs as SYSTEM on Windows (Task Scheduler, VSS, robocopy) or as root
on macOS (launchd, rsync; macOS is beta). Plus frequent "hot copies" of a few listed files.
PowerShell only, no dependencies besides restic.

| Path | Role |
|---|---|
| `scripts/common.ps1` | Everything both platforms share: settings and their validation, locks, native calls, reports, mirror guard, hot copies, run history, installed copy |
| `scripts/windows.ps1`, `scripts/macos.ps1` | The platform adapters. Both define the same functions and variables (paths, permissions, lock, mirror copy, schedules); `common.ps1` dot-sources the one for the running OS |
| `scripts/backup.ps1` | The daily run. Order: destination check, lock, checks, snapshot, report, state, mirror, retention, run record. `-IfDue` is for launchd's hourly start |
| `scripts/hot-copy.ps1` | The frequent copies, one run over every set in `HotCopies` |
| `scripts/install.ps1` | Folders, password, repository, recovery notes, the installed copy, the scheduled jobs |
| `scripts/install-restic.ps1` | Downloads restic into `bin/` and checks it against SHA256SUMS and a pinned hash |
| `scripts/restore.ps1`, `status.ps1`, `uninstall.ps1` | What their names say |
| `scripts/run-hidden.vbs` | Windows only: starts PowerShell without a console window for the hot copy task |
| `config/` | `settings.example.psd1`, `settings.example.macos.psd1` and the two exclude lists. `settings.psd1` is the user's and is ignored by git |
| `tests/` | Pester 5.9.1. Unit tests, real filesystem tests with robocopy or rsync, and an end-to-end run with the real restic. `ci-system-install.ps1` and `ci-system-install-macos.ps1` install for real and run only in CI |

## Commands

```powershell
./scripts/install-restic.ps1                               # puts restic in bin/ (tests need it)
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path tests -Output Detailed                  # about a minute
powershell -NoProfile -Command "Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester -Path tests"
```

The suite has to be green on `pwsh` and on Windows PowerShell 5.1 (`powershell`) on Windows, and on
`pwsh` on macOS. CI runs all three, plus a real install as SYSTEM on Windows and as root on macOS.
Nobody on the project runs macOS every day: a change to `macos.ps1` is only as tested as the macOS
jobs of CI.

## Rules that are not obvious

1. **Windows PowerShell 5.1 compatible, and ASCII only.** No `??`, no ternary, no `&&`, no
   `-AsHashtable`. 5.1 reads a file without BOM as ANSI, so every script stays ASCII; a test enforces
   both. `macos.ps1` too: 5.1 parses it even though it never runs it.
2. **A platform difference is a function in both adapters**, with the same name and parameters.
   `common.ps1` and the entry scripts call it; they check `$script:OnWindows` or `$script:OnMac` only
   for a message or a flag that exists on one side (VSS), never to branch on logic an adapter can own.
3. **Never `Join-Path` a path under `DestinationRoot` before the drive is checked.** `Join-Path`
   fails when the drive does not exist, and an unplugged backup drive must end in "not available",
   not in a crash. Use `[IO.Path]::Combine`. On macOS `Test-DestinationAvailable` also refuses a
   `/Volumes/<name>` that is not a mount point: writing there would fill the boot disk.
4. **The mirror copy (robocopy `/MIR`, rsync `--delete`) only runs through `Update-Mirror`**, which
   calls `Assert-MirrorTarget` first. Never call either anywhere else, and never weaken the marker
   check.
5. **Snapshot before mirror.** The history must be safe before the mirror loses anything.
6. **Any restic exit code other than 0 fails the run**, exit code 3 included, and the error has to
   say which items. robocopy 0 to 7 is success, 8 or more fails; rsync 0 and 24 (files vanished
   mid-copy) are success.
7. **Exclude patterns reach restic anchored under the source** (`Get-ResticExcludeLines`). Passing
   `config/excludes.txt` to restic directly brings back the bug where a parent folder named like a
   pattern excluded everything. Windows matches without case (`--iexclude-file`, like robocopy),
   macOS with case (`--exclude-file`, like rsync).
8. **Native calls go through `Invoke-NativeCapture` or `Invoke-NativeLogged`**, which relax
   `$ErrorActionPreference` locally: 5.1 turns native stderr into a terminating error otherwise. On
   macOS call tools by absolute path (`/usr/bin/rsync`): launchd gives the job a minimal `PATH`.
9. **Anything that runs as SYSTEM or root runs from the installed copy** (`C:\Program Files\restic-twin`,
   `/Library/Application Support/restic-twin`), never from the clone, through a PowerShell only an
   administrator can replace, and **never reads back a file a normal account can write**. With the
   jobs installed, the folders the job writes belong to Administrators (Windows) or to root with mode
   700 (macOS), and the user only reads them (`Set-PrivateFolderAcl -UserAccess Read -Owner`; on
   macOS through one inherited ACL entry). A value read back and passed to restic is validated first
   (snapshot ids: 64 hex). The user's own job (hot copies) writes only under `hot-copies/`.
10. **The installer never replaces a password** and never re-creates a repository.
11. **Tests never touch real folders or jobs.** Everything goes to `$TestDrive` or a temp folder the
    test deletes. Never run `install.ps1` without `-SkipScheduledTask` in a test. The two
    `ci-system-install*.ps1` scripts refuse to run outside GitHub Actions.
12. Settings are read by `Read-SettingsFile`, which parses and evaluates constants only, as UTF-8.
    Do not go back to `Import-PowerShellDataFile`.
13. When behaviour changes, update `README.md`, `README.pt-BR.md` and the page under `docs/`, and
    add a test that fails without the change.

## What to ignore

`bin/restic.exe`, `bin/restic`, `bin/version.txt`, `config/settings.psd1`, and anything under a
destination folder.
