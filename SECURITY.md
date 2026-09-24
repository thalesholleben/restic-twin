# Security

## Threat model

1. **Everything runs on the machine of whoever installs it.** There is no server, no account and no
   telemetry. The only network call is the install downloading restic from its official GitHub
   release, checked against SHA256SUMS and against a hash pinned in `install-restic.ps1`.
2. **The daily task runs as SYSTEM**, with the backup privilege that lets it read every file in the
   source, including files only you can open. Its scripts, settings and `restic.exe` run from
   `C:\Program Files\restic-twin`, which only administrators can change, and PowerShell 7 is used
   only from its machine-wide install folder. A script in your profile that SYSTEM runs would let
   anything running as you become SYSTEM.
3. **The history is encrypted by restic** (AES-256 in counter mode with Poly1305) with a random
   48-byte password. By default the password file sits next to the history, on the backup drive,
   readable by SYSTEM, Administrators and you. That keeps the backup restorable when drive C: dies,
   and it means **the encryption does not protect a stolen backup drive**: whoever takes it and reads
   it as an administrator reads the password too. If theft worries you more than a dead C:, move
   `PasswordFile` to C: (see [configuration](docs/configuration.md)). In both cases keep a copy of the
   password offline.
4. **What SYSTEM writes, only SYSTEM and Administrators can change.** With the tasks installed, the
   destination folder, the history, the mirror, the reports, the logs and the recovery notes belong
   to Administrators, and your account can only read them. SYSTEM never reads back a file that a
   normal account can write, so nothing running as you can swap a file under the daily task, turn a
   folder into a junction that makes SYSTEM write elsewhere, or pass restic an argument. The same rule
   keeps ransomware that runs as you away from the history and the mirror. You keep full control of
   `hot-copies\` and `restores\`, which you write yourself. The one value SYSTEM takes from a file it
   wrote, the previous snapshot id, is also checked to be a snapshot id before use.
5. **The mirror and the hot copies are plain files.** No other local account can read the destination
   folders, since they do not inherit the drive's permissions, but any administrator can.
6. **Hot copies run as you**, with your permissions, never elevated.

Out of scope: protecting the backups from someone or something that is already an administrator on
the machine (it can delete the history and the mirror), and an offsite copy. A second drive is not
offsite: see the limits in the [README](README.md#limits). A folder that already held other files
when you installed keeps its permissions, and the installer says so.

## Reporting a vulnerability

Report privately through GitHub Security Advisories:
[report a vulnerability](https://github.com/thalesholleben/restic-twin/security/advisories/new).
Please do not open a public issue for a security problem.

Expect a first reply within 7 days. If the report is confirmed, the fix and the advisory go out
together, and you are credited unless you prefer otherwise.

In scope: anything that lets a user who is not an administrator run code as SYSTEM through
restic-twin, or make it write outside the destination folders; anything that lets such a user change
the history or the mirror after an elevated install; any way the mirror refresh can delete files it
did not create; a password leaking outside the password file; and any file restic-twin writes outside
the locations listed in [how it works](docs/how-it-works.md).

## Supported versions

Fixes target the latest release and `main`.
