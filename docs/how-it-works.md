# How it works

restic-twin is a handful of PowerShell scripts around two tools: restic, for the encrypted history,
and the copy tool the system ships with, for the plain mirror: robocopy on Windows, rsync on macOS.
There is no service, no database and no network call after the install.

What differs between the two systems lives in `scripts/windows.ps1` and `scripts/macos.ps1`, which
define the same functions; everything else is shared. This page describes Windows first; the
[macOS section](#on-macos-beta) lists what changes there.

## The two scheduled tasks (Windows)

| Task | Runs | As | What it runs |
|---|---|---|---|
| `restic-twin daily backup` | every day at `DailyAt`, and at the next start if the PC was off | SYSTEM, highest privileges | `C:\Program Files\restic-twin\scripts\backup.ps1` |
| `restic-twin hot copies` | every `HotCopyEveryMinutes`, only while you are signed in | you, limited | `hot-copy.ps1`, through `run-hidden.vbs` |

The hot copy task exists only when `HotCopies` lists something. It starts `wscript.exe` on
`run-hidden.vbs` instead of PowerShell itself because a task in your session flashes a console window
every time it starts a console program, even with `-WindowStyle Hidden`: the window exists before
PowerShell can hide it. The launcher waits for PowerShell and returns its exit code, so a failure
still shows in the task's Last Run Result.

Both tasks run the copy under `C:\Program Files\restic-twin`, which `install.ps1` refreshes from your
clone every time you run it. The daily task runs as SYSTEM, and a script that SYSTEM runs has to live
where only administrators can write: from a folder in your profile, anything running as you could
rewrite it and get SYSTEM at 19:00. For the same reason the task uses PowerShell 7 only from
`C:\Program Files\PowerShell\7`, and falls back to the Windows PowerShell in `System32`.

## One daily run, in order

1. **Destination.** The destination drive is there, before anything is written: on macOS the lock
   file lives on it, and an unplugged drive must not become a folder on the boot disk.
2. **Lock.** A `Global\` mutex named after the destination folder. `Global\` and not `Local\`,
   because the scheduled run lives in session 0 as SYSTEM and a manual run lives in your session,
   and a per-session lock would let both refresh the mirror at once. A run that finds the lock taken
   exits with 0 and writes no run record.
3. **Checks.** The source exists, restic, the exclude list, the password file and the repository
   are in place, and there is at least `MinimumFreeSpaceGB` free. Any of these missing fails the run
   before the history or the mirror is touched.
4. **Snapshot.** `restic backup` of the source through VSS (`--use-fs-snapshot`), tagged
   `restic-twin`, with the anchored exclude list (see below). Its JSON output goes to
   `logs\restic-backup_<run>.jsonl`.
5. **Change report.** `restic diff --metadata` between the previous successful snapshot and this one,
   written to `reports\<year>\<month>\` as JSONL, CSV and Markdown. The first run writes a baseline
   instead. If the previous snapshot no longer exists, because someone forgot it by hand, the run
   starts a new baseline with a warning instead of failing every day from then on.
6. **State.** The new snapshot id goes to `logs\last-successful-snapshot.txt`: the next report
   compares against it. It is read back only if it looks like a snapshot id (64 hex digits), since it
   becomes an argument of a restic command; anything else starts a new baseline.
7. **Mirror.** robocopy `/MIR` from the source to `mirror\`, with the same exclude list plus
   `excludes-mirror.txt`. Exit codes 0 to 7 are success; 8 or more fails the run, and the error quotes
   the failing lines of the log. On macOS, rsync `-rlt --delete`: 0 and 24 (a file vanished while it
   was copied) are success.
8. **Retention.** `restic forget --tag restic-twin --keep-daily 7 --keep-monthly 6`. When the last
   maintenance is 7 days old or more, `restic prune` and `restic check` too. By elapsed time, not by
   weekday, so a PC that is always off on Sundays still gets it.
9. **Record.** One JSON line in `logs\runs.jsonl` and the same record in `logs\latest.json`: status,
   identity, start and end, snapshots, the restic and mirror exit codes (`mirror_exit_code`, plus
   `robocopy_exit_code` on Windows as in 1.0), unreadable items and the error.

The order is the point of the design. The mirror is only refreshed after the snapshot is safe, so a
file you deleted by mistake disappears from the mirror while it is still in the snapshot of the day
before.

### When restic cannot read a file

restic exits with 3 when it saved a snapshot but skipped items it could not read. restic-twin treats
that as a failed run: the state does not move, the mirror is not refreshed, and the error lists the
first five items with restic's reason. The full list is in the run's `restic-backup_*.jsonl`. The fix
is either an entry in `config\excludes.txt` or a permission change, never switching an antivirus off.

### Retries

The daily task has "restart 3 times every 15 minutes" set, but the Task Scheduler only uses it when
the task fails to start, not when the script exits with 1. A failed run is retried by the next day's
run, or right away if you start it by hand. A repository lock left by a `restic check` you started
yourself is waited for, up to 10 minutes (`--retry-lock`), instead of failing.

## The exclude lists

`config\excludes.txt` is read by both tools: restic for the snapshot, robocopy or rsync for the
mirror. It holds names and wildcards, one per line, with no paths, because the tools agree on names
and not on paths. Windows ignores case, like robocopy (restic gets `--iexclude-file`); macOS matches
it, like rsync (`--exclude-file`). `config\excludes-mirror.txt` adds names for the mirror only (see
[troubleshooting](troubleshooting.md)).

restic matches a bare name against every folder of the absolute path, including the folders above
the source. With `build` in the list and a source at `D:\build\app`, restic would back up nothing and
still exit with 0, while robocopy, which only looks below the source, fills the mirror. So each run
writes `logs\restic-excludes.txt` with every name anchored under the source
(`D:\build\app\**\build`), and restic reads that file instead.

## The mirror marker

robocopy `/MIR`, like rsync `--delete`, deletes whatever the destination has and the source does
not. Before the first refresh, restic-twin requires the mirror folder to be empty, and writes
`mirror\.restic-twin-mirror` holding the source path. Every later refresh checks it: a mirror marked
for another source, or a folder with files and no marker, stops the run. The marker is excluded from
the copy, and neither tool deletes what it excludes.

## Change reports

restic reports a change for every file and also a metadata change for every folder above it. The CSV
and the Markdown leave out metadata-only changes on folders, so the files stay readable; the JSONL
keeps every line restic printed.

| Column | Example |
|---|---|
| `backup_time` | `2026-09-23T19:00:02.1234567-03:00` |
| `previous_snapshot`, `current_snapshot` | full restic ids |
| `modifier` | restic's code: `+`, `-`, `M`, `U`, `T`, `?` |
| `action` | `added`, `removed`, `modified`, `metadata`, `type-changed`, `possible-corruption` |
| `path` | relative to the source, with `/`; folders end with `/` |
| `extension` | `.md`, empty for folders |
| `area` | the first folder of the path, handy for grouping |

The CSV is UTF-8 with BOM, so Excel keeps accents, and a `path` or `area` that starts with `=`, `+`,
`-` or `@` gets a leading apostrophe, so a file name can never become a formula. Scripts should read
the JSONL, which keeps the raw values.

## Hot copies

For each entry of `HotCopies`, every few minutes:

1. Every file of the set has to exist, or the set fails without writing anything.
2. The files are copied into a staging folder, `hot-copies\<name>\.incoming-<guid>`.
3. The copies are compared with the newest version by size and SHA-256. Comparing the copies, not
   the originals, means a file that changes mid-run cannot end up recorded half old and half new.
4. Unchanged: the staging folder is deleted. Changed: it becomes `hot-copies\<name>\<timestamp>`,
   with `-2`, `-3` for a second copy within the same second.
5. Only the newest `Keep` version folders stay. Folders with any other name are never touched.

Copies and errors are logged to `hot-copies\hot-copies.log`; runs that found nothing new are not.
The log sits with the hot copies because this task runs as you, and `logs\` belongs to SYSTEM.

## Who can write what

Once the tasks are installed, on Windows:

| Folder | SYSTEM and Administrators | Your account |
|---|---|---|
| the destination folder itself | full control, owner | read |
| `history\`, `mirror\`, `reports\`, `logs\`, `recovery\` | full control, owner | read |
| `hot-copies\`, `restores\` | full control | full control |
| the password file | read | read |

The rule behind the table: the SYSTEM task never reads back a file that a normal account can write.
If it did, anything running as you could swap that file between the moment SYSTEM writes it and the
moment it reads it, or replace a folder with a junction and have SYSTEM write into a folder of its
choosing. It is also what keeps ransomware that runs as you away from the history and the mirror.

Because your account only reads the history, `restore.ps1` and `status.ps1` run restic with
`--no-lock` when they are not elevated: restic cannot write its lock file there. A prune running at
the same moment could make such a read fail, never damage the repository. A manual `backup.ps1` has
to run elevated.

Without the tasks (`install.ps1 -SkipScheduledTask`) nothing runs as SYSTEM, and you keep full
control of every folder.

Only `install.ps1` creates these folders, and it sets their permissions every time it runs, on a
folder it creates as well as on one it finds, like an empty mirror someone made earlier. A backup or a
hot copy that finds one missing stops and asks for the install instead of creating it: a folder made
there would inherit the drive's permissions, and as SYSTEM the backup could not even give your account
access to it. Folders inside them, like `reports\2026\09\`, inherit the permissions of their parent.

On macOS the same rule holds with root in the place of SYSTEM: see [permissions on
macOS](#permissions-on-macos).

## Encoding

restic prints UTF-8, and PowerShell decodes the output of a native program with the console code
page, which for a scheduled task is the OEM one (850, 437 and so on). Every script that parses restic
output switches the console to UTF-8 first; without that, every path with an accent reached the
reports garbled. robocopy writes its log itself as UTF-16 (`/UNILOG`). Settings files are read as
UTF-8 with or without BOM on both PowerShell editions, and the scripts themselves are plain ASCII.

## Files restic-twin writes

| Where | What |
|---|---|
| `DestinationRoot` and everything under it | the history, the mirror, reports, logs, recovery notes, hot copies, restores |
| `C:\Program Files\restic-twin` | the installed copy of `scripts`, `config` and `bin\restic.exe` |
| Task Scheduler | the two tasks above |
| your clone's `bin\` | `restic.exe` and `version.txt`, downloaded by `install-restic.ps1` |

On macOS:

| Where | What |
|---|---|
| `/Library/Application Support/restic-twin` | the installed copy, and `daily-errors.log`, what the daily job printed on stderr |
| `/Library/LaunchDaemons/com.restic-twin.daily.plist` | the daily job |
| `~/Library/LaunchAgents/com.restic-twin.hot-copies.plist` | the hot copy job, only when `HotCopies` lists something |
| `/Library/Caches/restic-twin` | restic's cache when it runs as root |
| your clone's `bin/` | `restic` and `version.txt` |

`uninstall.ps1` removes the jobs and the installed copy. It never touches `DestinationRoot`.

## On macOS (beta)

The same scripts, in the same order, writing the same folders. What each step uses:

| | Windows | macOS |
|---|---|---|
| Daily job | Task Scheduler task, as SYSTEM | launchd daemon `com.restic-twin.daily`, as root |
| When it runs | at `DailyAt`, and at the next start if the PC was off | at `DailyAt`, and every hour with `-IfDue` |
| Hot copies | a task in your session, through `run-hidden.vbs` | launchd agent `com.restic-twin.hot-copies`, in your session |
| Installed copy | `C:\Program Files\restic-twin` | `/Library/Application Support/restic-twin` |
| PowerShell of the daily job | `C:\Program Files\PowerShell\7`, or Windows PowerShell | `/usr/local/microsoft/powershell/7/pwsh` |
| Snapshot | through VSS | the files as they are: there is no VSS on macOS |
| Mirror | robocopy `/MIR` | rsync `-rlt --delete` |
| Run lock | a `Global\` mutex | an exclusive lock on a file in `logs` (in `hot-copies` for hot copies) |
| Folders the daily job writes | owned by Administrators, you read | owned by root, mode 700, you read through one ACL entry |
| Exclude names | case ignored | case matched |

The daily job runs PowerShell from `/usr/local/microsoft/powershell/7`, where the official package
and `brew install --cask powershell` put it, because root runs it: `install.ps1` refuses a
PowerShell that your account could change, directly or through a folder above it. Without a
snapshot of the file system, a file that a program is writing during the backup is read as it is
at that moment; quit the program that owns a database when you need a consistent copy of it.

### -IfDue

launchd runs a calendar job it missed while the Mac slept, not one it missed while the Mac was off.
So the daily job also starts every hour with `-IfDue`, and `backup.ps1` decides: it runs only when
nothing succeeded since the last `DailyAt` and the last attempt is at least four hours old. A Mac
that was off at 19:00 backs up within the hour after it starts, and a run that keeps failing retries
every four hours, not every hour. An hourly start with nothing to do exits at once and writes no run
record.

### The drive under /Volumes

A drive appears at `/Volumes/<name>` only while it is mounted, and a folder left at that path while
it is not sits on the boot disk. Before the lock and before writing anything, a `DestinationRoot`
under `/Volumes` must be on a mounted drive: unplugged, the run fails with "not connected"; with a
leftover folder in its place, with "not a mounted drive". Either way nothing is written to the
internal disk, and every hourly start fails the same way until the drive is back.

### Permissions on macOS

Once the jobs are installed, the destination folder, `history`, `mirror`, `reports`, `logs` and
`recovery` belong to `root:wheel` with mode 700, and carry one ACL entry, `user:<you> allow
list,search,readattr,readextattr,readsecurity`, which everything root creates in them later
inherits. You open, search and copy from all of it; nothing running as you can write there. The
password file is `root:wheel` mode 400 with the same read entry. `hot-copies` and `restores` are
yours, mode 700. Without the jobs (`-SkipScheduledTask`) every folder is yours, mode 700.

That needs a drive that keeps permissions: APFS or Mac OS Extended with ownership on. On exFAT, or
with "Ignore ownership on this volume" checked, `install.ps1` warns and leaves the permissions alone.

Your own runs of `status.ps1` and `restore.ps1` read the history with `--no-lock`, as on Windows. A
manual backup runs with `sudo`. Under root, restic keeps its cache in `/Library/Caches/restic-twin`:
`sudo` keeps your `HOME`, and restic would otherwise leave files owned by root in your `Library`.
