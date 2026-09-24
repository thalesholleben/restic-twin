# Copy this file to config\settings.psd1 and set the first two values.
# Write full paths: a .psd1 file cannot read $env:USERPROFILE or other variables.
@{
    # The folder you want to protect.
    SourcePath      = 'C:\Users\you\Projects'

    # A folder on another physical drive. Everything restic-twin writes lives under it:
    #   mirror\      plain copy of the latest backup, open it in Explorer
    #   history\     the encrypted restic repository, one snapshot per day
    #   reports\     what changed between two snapshots (JSONL, CSV, Markdown)
    #   logs\        one set of logs per run, runs.jsonl and latest.json
    #   recovery\    the repository password and a README on how to restore
    #   hot-copies\  frequent copies of the files listed in HotCopies below
    #   restores\    where restore.ps1 puts what you restore
    DestinationRoot = 'E:\restic-twin'

    # Everything below is optional. The values shown are the defaults.

    # The repository password. Next to the history by default, so losing drive C: does not lose it.
    # That also means whoever takes the backup drive can read it: see SECURITY.md before changing.
    # PasswordFile = 'E:\restic-twin\recovery\restic-password.txt'

    # DailyAt            = '19:00'   # 24-hour clock. A PC that was off runs it at the next start.
    # KeepDaily          = 7         # one snapshot for each of the last 7 days that had a backup
    # KeepMonthly        = 6         # plus one for each of the last 6 months
    # MinimumFreeSpaceGB = 10        # the run fails before writing anything below this

    # Files that change all day and deserve more than one copy a day. Each entry is copied as a
    # whole into hot-copies\<Name>\<timestamp>\ when any of its files changed, every
    # HotCopyEveryMinutes, while you are signed in. Keep is how many versions stay.
    # HotCopyEveryMinutes = 5
    # HotCopies = @(
    #     @{ Name = 'notes'; Files = @('C:\Users\you\Projects\notes.md'); Keep = 12 }
    #     @{ Name = 'board'; Files = @('C:\Users\you\Projects\board.html', 'C:\Users\you\Projects\board.data.js') }
    # )
}
