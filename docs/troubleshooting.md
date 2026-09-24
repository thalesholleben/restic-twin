# Troubleshooting

Start with `.\scripts\status.ps1`: the last run, its error, the last success and how old it is, the
tasks and the snapshot count. `logs\latest.json` has the same record, and `logs\runs.jsonl` has one
line per run. The error message usually names the log to open next.

## "Snapshot ... was saved, but restic could not read N item(s)"

restic exit code 3. The error names the first five items and restic's reason; the full list is in
`logs\restic-backup_<run>.jsonl`, in the lines with `"message_type":"error"`.

- **An antivirus blocked the file.** Common with security tooling, exploit samples and password
  dumps. Add that one name to `config\excludes.txt`. Do not switch the antivirus off.
- **A name Windows cannot open**, like a file called `nul` created by a tool that ran a Unix command.
  Add `nul` (the shipped list already has it) or delete the file.
- **A file locked by another program, without VSS.** Only happens on manual runs with `-NoVss`: the
  scheduled run reads through VSS.

The run fails on purpose: the snapshot exists, but it has a hole you would not know about.

## "Robocopy failed with exit code 8" (or more)

The mirror could not be refreshed. The error quotes the failing lines of `logs\robocopy_<run>.log`.

- **`(0x00000005)`, access denied.** A file only your account can read. The daily run reads the
  source as SYSTEM: restic has backup privileges and gets the file anyway, robocopy does not. The
  snapshot keeps it, so add its name to `config\excludes-mirror.txt` and it stays in the encrypted
  history and out of the plain mirror. Do not loosen the file's permissions.
- **`(0x00000020)`, the file is in use.** A program holds it open in exclusive mode, like a running
  database or a VM disk. The snapshot has it through VSS. If it is always open, add its name to
  `config\excludes-mirror.txt`.

robocopy waits and retries a locked file 3 times, 5 seconds apart, before giving up on it.

## "Destination drive E:\ is not available"

The drive was not connected, not unlocked (BitLocker), or got another letter. Fix that and start the
task by hand, or wait for tomorrow. A USB drive that gets a different letter each time can be given a
fixed one in Disk Management.

## "... is missing. Run scripts\install.ps1 again"

A folder under the destination was deleted or renamed. Only `install.ps1` creates those folders,
because it gives each one its permissions; a backup or a hot copy that created one itself would leave
it with the drive's permissions, readable by every local account. Run `install.ps1` again, elevated.
It keeps the password and the history as they are.

## "Another backup is running. Nothing to do."

Another run holds the lock, often the scheduled one that started while you ran it by hand. Wait for it
to finish. Nothing is recorded for the run that gave up.

## "VSS snapshots need an elevated shell"

A manual `backup.ps1` from a normal PowerShell. Open it as Administrator. `-NoVss` exists for a quick
test on a setup made with `install.ps1 -SkipScheduledTask`: files held open by other programs may then
be skipped, and the run fails if they are.

## "Access to the path ... is denied", on a manual run

Once the tasks are installed, only SYSTEM and Administrators can write to the history, the mirror, the
reports and the logs, and your account reads them. Run `backup.ps1` from an elevated PowerShell, or
start the task: `Start-ScheduledTask -TaskName 'restic-twin daily backup'`. `status.ps1` and
`restore.ps1` work from a normal shell.

## "There is a restic repository ... but no password file"

The password file was moved or deleted. Put it back at the path in `PasswordFile` from your offline
copy. `install.ps1` refuses to create a new one, because a new password would not open the existing
history. Without the old password the history cannot be decrypted.

## "The mirror at ... is a copy of '...', not of '...'"

`SourcePath` changed while the destination stayed the same. Refreshing the mirror would replace the
old copy with the new source. Point `DestinationRoot` to a new folder, or, if you really mean to reuse
it, delete `mirror\.restic-twin-mirror` and run again. The history is not affected either way.

## "... already holds files that restic-twin did not put there"

The mirror folder existed with files in it before restic-twin ever wrote there. The mirror refresh
deletes anything that is not in the source, so it refuses. Empty that folder or choose another
`DestinationRoot`.

## status.ps1 says the task is "not readable from this shell"

The daily task belongs to SYSTEM, and a normal shell may not read it. Run `status.ps1` elevated.
`logs\scheduled-task.json`, written by `install.ps1`, records how the tasks were registered.

## status.ps1 says the tasks run an older copy

You changed a script or a setting in your clone and did not reinstall. Run `.\scripts\install.ps1`
again, elevated: it refreshes `C:\Program Files\restic-twin` and re-registers the tasks.

## Scripts do not run at all

Windows PowerShell 5.1 ships with scripts disabled. In the shell you use:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

That lasts for that window only. The scheduled tasks pass `-ExecutionPolicy Bypass` themselves.

## The logs folder keeps growing

Each run leaves its logs, most of it restic's progress lines: about 1 MB a run for a folder with a
hundred thousand files. Delete old
`backup_*`, `restic-backup_*`, `robocopy_*`, `retention_*`, `prune_*` and `check_*` files whenever you
like, from an elevated shell since `logs\` belongs to SYSTEM; `latest.json`, `runs.jsonl` and
`last-successful-snapshot.txt` are the ones the scripts read.
