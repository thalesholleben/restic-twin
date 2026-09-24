# Restore

Pick the shortest way back:

| You need | Go to |
|---|---|
| The current version of a file | `mirror\`. It is a plain copy: open it, copy the file out. |
| A version from the last hour of a file you listed in `HotCopies` | `hot-copies\<name>\<timestamp>\`, also plain files. |
| An older version, or a file that is gone | the history, with `restore.ps1`. |

The mirror is refreshed every day, so never edit files inside it: the next run puts it back in line
with the source.

## restore.ps1

It restores into a new folder, never over existing files, and never inside the source or the mirror.
You compare what came back and copy what you need yourself.

```powershell
.\scripts\restore.ps1                                   # the latest snapshot, into restores\restore_<timestamp>
.\scripts\restore.ps1 -TargetPath D:\restored\monday    # somewhere else, a folder that does not exist yet
.\scripts\restore.ps1 -Include '/docs'                  # only the docs folder at the top of the source
.\scripts\restore.ps1 -Include 'notes.md'               # every notes.md, at any depth
.\scripts\restore.ps1 -Snapshot 4bd2e9a1                # an older snapshot, by id
```

What lands in the target is the content of the source folder itself, not the whole path above it.
`-Include` patterns are relative to the source: a pattern that starts with `/` is anchored at its
top, any other pattern matches at any depth. `--verify` is always on, so restic reads every restored
file back and checks it against the history.

It works from a normal shell: your account can read the history, and restic then runs with
`--no-lock`, because it cannot write its lock file there. Run it elevated when you want every Windows
attribute and permission back; without elevation the content comes back identical, but restic may not
be able to reapply some metadata.

## Finding the snapshot you want

```powershell
$restic = '.\bin\restic.exe'
$repo = 'E:\restic-twin\history'
$password = 'E:\restic-twin\recovery\restic-password.txt'

& $restic --repo $repo --password-file $password --no-lock snapshots
& $restic --repo $repo --password-file $password --no-lock find 'notes.md'
& $restic --repo $repo --password-file $password --no-lock ls 4bd2e9a1 /C/Users/you/Projects/docs
```

Inside a snapshot, `C:\Users\you\Projects` is written `/C/Users/you/Projects`. The change reports in
`reports\` tell you on which day a file changed or disappeared, which is usually the fastest way to
pick the snapshot.

## On another computer

Everything you need is on the backup drive, plus the password if you moved it:

1. Download restic for Windows from the [official releases](https://github.com/restic/restic/releases).
2. Read `recovery\README.txt` on the drive: it has the exact paths.
3. List the snapshots and restore one:

```powershell
restic --repo E:\restic-twin\history --password-file E:\restic-twin\recovery\restic-password.txt snapshots
restic --repo E:\restic-twin\history --password-file E:\restic-twin\recovery\restic-password.txt restore latest:/C/Users/you/Projects --target D:\restored
```

restic runs on Linux and macOS too, so the history can be read from any machine, not only Windows.

Do not edit, rename or delete anything inside `history\` by hand. restic keeps it consistent; a file
removed there can corrupt snapshots that look unrelated.
