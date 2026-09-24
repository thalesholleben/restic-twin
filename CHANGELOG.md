# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] (2026-09-24)

macOS support, in beta.

### Added

- macOS, on PowerShell 7: the daily backup runs as root under launchd, rsync refreshes the mirror,
  and the folders root writes belong to root with mode 700, readable by your account through one
  inherited ACL entry. The jobs run the installed copy in `/Library/Application Support/restic-twin`,
  through a PowerShell only root can change. Beta: it passes the same suite on a GitHub macOS
  runner, plus a real install as root on a disk image mounted in `/Volumes`, and has not been through
  daily use on a Mac yet.
- `backup.ps1 -IfDue`: runs only when nothing succeeded since the last `DailyAt` and the last attempt
  is at least four hours old. launchd starts the job every hour with it, so a Mac that was off at
  `DailyAt` catches up within the hour.
- A `DestinationRoot` under `/Volumes` has to be a mounted drive. With the drive unplugged the run
  fails, instead of writing a second history into a folder on the boot disk.
- `mirror_exit_code` in the run record, for robocopy or rsync. `robocopy_exit_code` stays on Windows
  for what already reads it.

### Changed

- What differs between the platforms moved from `common.ps1` into `windows.ps1` and `macos.ps1`,
  which define the same functions. Windows behaves as in 1.0.0.

## [1.0.0] (2026-09-23)

First public release, from a personal backup that ran every day for three months.

### Added

- Daily restic snapshot of one folder through VSS, as SYSTEM, at a set time and at the next start
  when the PC was off, with retention of 7 daily and 6 monthly snapshots and a prune and check every
  7 days.
- Change report after every run, in JSONL, CSV (UTF-8 with BOM, formula-safe) and Markdown.
- Plain mirror refreshed with robocopy only after the snapshot, guarded by a marker so it never runs
  into a folder it did not create.
- Hot copies: sets of files copied together every few minutes when one of them changed, keeping the
  newest versions.
- `install.ps1`, which prepares private destination folders, a random password and the repository,
  copies itself to Program Files and registers the tasks there; `uninstall.ps1`, `status.ps1` and
  `restore.ps1`.
- `install-restic.ps1`, which checks the official release against SHA256SUMS and a pinned hash.
- With the tasks installed, the folders the SYSTEM task writes belong to Administrators and are
  read-only for your account, so nothing running as you can tamper with what SYSTEM reads back or
  reach the history and the mirror. `restore.ps1` and `status.ps1` read with `--no-lock`.
- A run lock per destination, shared by the scheduled run and a manual one.
- Settings validation that lists every problem at once, and a settings reader that handles UTF-8
  without BOM on Windows PowerShell 5.1.
- Pester suite with unit, filesystem and end-to-end tests on the real restic, run on PowerShell 7 and
  Windows PowerShell 5.1.

### Fixed, compared with the personal version

- Accented paths were garbled in the change reports: restic's UTF-8 output was decoded with the
  scheduled task's OEM code page.
- An exclude pattern matching a folder above the source excluded the whole source, with exit code 0.
- A manual run and the scheduled one could refresh the mirror at the same time.
- Weekly maintenance ran only on Sundays, so a PC that is off on Sundays never pruned.
- A failed run claimed to retry every 15 minutes; the Task Scheduler never does that for an exit
  code, and the docs now say so.

[1.1.0]: https://github.com/thalesholleben/restic-twin/releases/tag/v1.1.0
[1.0.0]: https://github.com/thalesholleben/restic-twin/releases/tag/v1.0.0
