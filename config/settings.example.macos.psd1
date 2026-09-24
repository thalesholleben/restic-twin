# macOS (beta). Copy this file to config/settings.psd1 and set the first two values.
# Write full paths: a .psd1 file cannot read $HOME or other variables.
@{
    # The folder you want to protect. Outside Desktop, Documents and Downloads is simplest: macOS
    # keeps those three private even from root, and the backup needs Full Disk Access to read them.
    SourcePath      = '/Users/you/Projects'

    # A folder on another physical drive, formatted APFS or Mac OS Extended, with ownership on.
    # Everything restic-twin writes lives under it:
    #   mirror/      plain copy of the latest backup, open it in Finder
    #   history/     the encrypted restic repository, one snapshot per day
    #   reports/     what changed between two snapshots (JSONL, CSV, Markdown)
    #   logs/        one set of logs per run, runs.jsonl and latest.json
    #   recovery/    the repository password and a README on how to restore
    #   hot-copies/  frequent copies of the files listed in HotCopies below
    #   restores/    where restore.ps1 puts what you restore
    DestinationRoot = '/Volumes/Backup/restic-twin'

    # Everything below is optional. The values shown are the defaults.

    # The repository password. Next to the history by default, so losing the Mac does not lose it.
    # That also means whoever takes the backup drive can read it: see SECURITY.md before changing.
    # PasswordFile = '/Volumes/Backup/restic-twin/recovery/restic-password.txt'

    # DailyAt            = '19:00'   # 24-hour clock. A Mac that slept or was off runs it within the hour.
    # KeepDaily          = 7         # one snapshot for each of the last 7 days that had a backup
    # KeepMonthly        = 6         # plus one for each of the last 6 months
    # MinimumFreeSpaceGB = 10        # the run fails before writing anything below this

    # Files that change all day and deserve more than one copy a day. Each entry is copied as a
    # whole into hot-copies/<Name>/<timestamp>/ when any of its files changed, every
    # HotCopyEveryMinutes, while you are logged in. Keep is how many versions stay.
    # HotCopyEveryMinutes = 5
    # HotCopies = @(
    #     @{ Name = 'notes'; Files = @('/Users/you/Projects/notes.md'); Keep = 12 }
    #     @{ Name = 'board'; Files = @('/Users/you/Projects/board.html', '/Users/you/Projects/board.data.js') }
    # )
}
