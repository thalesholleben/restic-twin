# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/thalesholleben/restic-twin/releases/tag/v1.0.0
