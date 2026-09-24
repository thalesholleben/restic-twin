@AGENTS.md

## Claude Code

- Never run `install.ps1` without `-SkipScheduledTask`, `uninstall.ps1` or `Start-ScheduledTask` to
  "try it out": they register tasks that run as SYSTEM, copy into Program Files and touch the user's
  real backups. The end-to-end test covers the install path in a temp folder.
- Never point a test or a manual run at the user's real `config\settings.psd1`: it names their real
  source and backup drive. Use `-ConfigPath` with a settings file in a temp folder.
