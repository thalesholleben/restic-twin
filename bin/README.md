# bin

`scripts\install-restic.ps1` puts `restic.exe` here, with `version.txt` recording the version and
both checksums. Neither file is committed: every clone downloads the official release and checks it
against the hash pinned in the script.
