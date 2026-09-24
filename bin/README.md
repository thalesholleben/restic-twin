# bin

`scripts/install-restic.ps1` puts restic here, `restic.exe` on Windows and `restic` on macOS, with
`version.txt` recording the version and both checksums. Neither file is committed: every clone
downloads the official release and checks it against the hash pinned in the script.
