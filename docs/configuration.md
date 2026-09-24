# Configuration

Everything lives in `config/settings.psd1`, created by you from `config/settings.example.psd1` on
Windows or `config/settings.example.macos.psd1` on a Mac. Two values are required; the rest have
defaults. After any change, run `install.ps1` again, elevated (with `sudo` on macOS): the scheduled
jobs run the installed copy, and `status.ps1` tells you when that copy is older than your clone.

```powershell
@{
    SourcePath      = 'C:\Users\you\Projects'
    DestinationRoot = 'E:\restic-twin'
}
```

On macOS:

```powershell
@{
    SourcePath      = '/Users/you/Projects'
    DestinationRoot = '/Volumes/Backup/restic-twin'
}
```

Write full paths. A `.psd1` file cannot read `$env:USERPROFILE`, `$HOME` or any other variable, and
it can only hold plain values: text, numbers, `@()` and `@{}`. A file that tries to run code is
refused.

## Settings

| Setting | Default | What it is |
|---|---|---|
| `SourcePath` | required | The folder you protect. An absolute path: on a drive letter on Windows, starting with `/` on macOS. |
| `DestinationRoot` | required | The folder on the second drive that receives everything. A whole drive like `E:\` works. On macOS, a folder under `/Volumes/<drive>`. |
| `PasswordFile` | `<DestinationRoot>/recovery/restic-password.txt` | The repository password. See the trade-off below. |
| `DailyAt` | `'19:00'` | Time of the daily run, 24-hour clock. |
| `KeepDaily` | `7` | How many days keep one snapshot each. At least 1. |
| `KeepMonthly` | `6` | How many months keep one snapshot each. 0 turns monthly snapshots off. |
| `MinimumFreeSpaceGB` | `10` | Below this on the destination drive the run fails before writing anything. |
| `HotCopyEveryMinutes` | `5` | How often the hot copy job runs, from 1 to 1440. |
| `HotCopies` | `@()` | The sets of files for hot copies. See below. |

The settings are checked before any script does anything, and every problem is listed in one error.
These stop a run:

- a path that is relative, on a network share, of the other platform, or not a path;
- a source and a destination that are the same folder or sit one inside the other;
- a password file inside the source (the mirror would keep it in plain text) or inside the mirror,
  the history, the reports, the logs, the hot copies or the restores;
- a time that is not a 24-hour time, a number written as text, a negative number;
- a key that does not exist, like `KeepDialy`.

## The folders under DestinationRoot

| Folder | Holds |
|---|---|
| `mirror` | the plain copy of the source; only restic-twin writes here |
| `history` | the restic repository |
| `reports/<year>/<month>` | change reports |
| `logs` | `latest.json`, `runs.jsonl`, per-run logs, the anchored exclude list |
| `recovery` | the password (by default) and `README.txt` with restore commands |
| `hot-copies/<name>/<timestamp>` | hot copy versions |
| `restores` | the default target of `restore.ps1` |

The names are fixed. `install.ps1` gives each of them permissions of its own, so the plain mirror does
not inherit those of the drive, which on a second drive usually let every local account read it.
With the jobs installed, your account reads everything but writes only `hot-copies` and `restores`;
the rest belongs to SYSTEM and Administrators on Windows, and to root on macOS (see
[who can write what](how-it-works.md#who-can-write-what)). Give restic-twin a folder of its own:
a `DestinationRoot` that already holds other files keeps its permissions, and the installer warns
about it.

On macOS the drive has to keep permissions: APFS or Mac OS Extended, with "Ignore ownership on this
volume" off in the drive's Get Info window. On exFAT, or with ownership ignored, anything running on
the Mac can read and change the backups; `install.ps1` warns and leaves the permissions alone.

## The password file, and where to keep it

By default the password sits next to the history, on the backup drive. That way, if the computer's
own disk dies, the drive with your backups also has the key to open them. The price is that whoever
takes the backup drive and can read it as an administrator can read the password too, so the
encryption does not protect a stolen drive.

If a stolen backup drive worries you more than a dead internal disk, put the password on the
internal disk, outside the source, and keep a copy of it offline:

```powershell
PasswordFile = 'C:\ProgramData\restic-twin\restic-password.txt'                       # Windows
PasswordFile = '/Library/Application Support/restic-twin-key/restic-password.txt'    # macOS
```

Not inside the installed copy (`C:\Program Files\restic-twin`, `/Library/Application
Support/restic-twin`): `uninstall.ps1` deletes that folder.

Either way, copy the password to a password manager the day you install. Without it nobody can
decrypt the history. `install.ps1` creates a random password only when there is no repository yet,
and stops if a repository exists and its password file is missing.

## Exclude lists

`config/excludes.txt` leaves names out of the snapshot and the mirror. One name per line, `*` and `?`
allowed, `#` starts a comment. Case is ignored on Windows, as robocopy does, and matched on macOS, as
rsync does. No paths: a line with `\` or `/` is refused, because restic and the mirror copy read
paths differently. Each name matches files and folders at any depth below the source, never the
source or its parents.

The shipped list only holds what can be rebuilt or is temporary: dependency folders, build output,
caches, Python environments, editor swap files, `.DS_Store`. Keep it that way. If your antivirus
blocks a file or Windows cannot open a name (a file literally called `nul`), add that one name.

`config/excludes-mirror.txt` leaves names out of the mirror only. The snapshot still keeps them. It is
for files that should exist only encrypted, like production secrets, for files that only your
account can read on Windows (see [troubleshooting](troubleshooting.md)), and for files that are always
open in exclusive mode.

## Hot copies

```powershell
HotCopyEveryMinutes = 5
HotCopies = @(
    @{ Name = 'notes'; Files = @('C:\Users\you\Projects\notes.md'); Keep = 12 }
    @{ Name = 'board'; Files = @('C:\Users\you\Projects\board.html', 'C:\Users\you\Projects\board.data.js') }
)
```

| Key | Rule |
|---|---|
| `Name` | Starts with a letter or digit; letters, digits, `.`, `-`, `_`. Unique, case ignored. It is the folder name under `hot-copies`. |
| `Files` | One or more absolute paths, outside `DestinationRoot`. Two files with the same name cannot share a set, because each version is one folder. |
| `Keep` | How many versions stay. Default 12, which at 5 minutes is at least one hour of changes. |

The files of one set are copied together and compared together: when a page and its data file only
make sense as a pair, put them in one set. A set is copied only when one of its files changed.

After adding, changing or emptying `HotCopies`, run `install.ps1` again: it registers the hot copy
job (a task on Windows, a launchd agent on macOS), updates its interval, or removes it when the list
is empty.
