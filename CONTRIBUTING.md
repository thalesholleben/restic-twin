# Contributing

Thanks for wanting to improve restic-twin. It is deliberately small: PowerShell scripts, restic and
the copy tool the system already has (robocopy, rsync), no modules to install, no service. Please
keep it that way. If an idea needs a package, a server or a new config format, open an issue with
the use case first.

## Running it

```powershell
git clone https://github.com/thalesholleben/restic-twin.git
cd restic-twin
./scripts/install-restic.ps1
Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser
Invoke-Pester -Path tests -Output Detailed
```

On Windows, run the suite on Windows PowerShell 5.1 too (`powershell -NoProfile`, with Pester 5.9.1
installed for it). On macOS, run it with `pwsh` from your own account, not with `sudo`. Do not test a
change by installing it on your machine: `install.ps1` registers jobs that run as SYSTEM or root
against your real folders. The end-to-end test runs the whole install, backup and restore path in a
temporary folder, with the real restic, and CI installs for real on throwaway runners.

## Before opening a pull request

1. The suite is green on PowerShell 7 and on Windows PowerShell 5.1. A change that touches macOS
   also needs the macOS jobs of CI green: they are the only Mac the project tests on.
2. Behaviour changed: `README.md`, `README.pt-BR.md` and the page under `docs/` say so.
3. New behaviour comes with a test that fails without it. For a fix, undo the fix once and watch the
   test fail before you push.
4. Scripts stay ASCII and Windows PowerShell 5.1 compatible. The rules in [AGENTS.md](AGENTS.md)
   apply to people too.

## House rules

- **Never lose data quietly.** A run that could not do everything it promised fails, and its error
  says what to do next.
- **The mirror copy stays behind the mirror marker.** robocopy `/MIR` and rsync `--delete` are the
  only commands here that delete files.
- **A platform difference is one function in each adapter**, `windows.ps1` and `macos.ps1`.
- **Tests use temporary folders only**, and never register a scheduled job.
- Comments explain why, not what. If a line is strange because of a Windows or macOS detail, name the
  detail.

## Commits and pull requests

Small commits, present tense, plain English ("anchor exclude patterns under the source", not "fixed
stuff"). One topic per pull request. Describe what changed, how you tested it, and what you left out
on purpose.

## Reporting bugs

Open an issue with your Windows or macOS version, your PowerShell version, the restic version from
`bin/version.txt`, what you ran and what happened, plus `logs/latest.json` with your paths replaced.
Never attach logs or reports that show file names you would not publish.

Security problems do not go in issues: see [SECURITY.md](SECURITY.md).
