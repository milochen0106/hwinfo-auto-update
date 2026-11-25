# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.3.x | Yes |
| 1.2.x | Superseded (upgrade recommended) |
| 1.1.x | No (superseded by 1.2.0) |
| 1.0.x | No (superseded by 1.1.0) |

## Security model

The trust anchor is the vendor, REALiX s.r.o.:

- **Version signal**: the official RSS feed at `https://www.hwinfo.com/news.xml/`.
- **winget path**: the installer hash is verified by winget against the vendor's manifest.
- **Direct-download path**: the file must have a structurally valid PE header, a `Valid` Authenticode signature, and an organization field (`O`) exactly equal to `REALiX, s.r.o.`. The SHA-256 is logged for auditing but not pinned. Downloads are staged in a `.part` file and must exceed 10 MB before use.
- **`-InstallerPath`**: a caller-supplied file is first copied into the protected `Downloads\` staging directory, and the same checks run against that staged copy, never against the writable original path.
- **`-StalePids`**: a PID is only stopped when the process is `powershell`/`pwsh` and the parsed `-File` argument is exactly one of this project's script paths. A path that merely appears elsewhere in the command line is rejected.

### Privilege boundary (1.3.0+)

A scheduled task with `RunLevel Highest` executes code as an administrator, so the
scripts it loads must not be writable by a standard user. Bootstrap now:

1. Copies `Update-HWiNFO.ps1`, both `lib\*.ps1` files and itself into
   `%ProgramData%\HWiNFO-AutoUpdate\`.
2. Resets any pre-existing explicit ACEs with `icacls /reset`, removes inherited
   ACLs on that directory and everything under it, sets the owner to
   `BUILTIN\Administrators`, and grants full control only to `SYSTEM` and
   `BUILTIN\Administrators`. `/reset` matters because a standard user can create
   a same-named directory in `%ProgramData%` first; without it, an explicit ACE
   they planted would survive `/inheritance:r`. Owner is changed because a
   remaining individual owner retains implicit `WRITE_DAC` under their standard
   token and could otherwise restore their own write access. Reparse points at
   the root or anywhere below it are rejected.
3. Registers the task to run the **deployed** script with `-WorkingDirectory`
   pointing at the protected root and an absolute `powershell.exe` path. The
   clone in Downloads/Desktop is only a deployment package, never the task target.

`Update-HWiNFO.ps1` refuses to run from any directory other than the protected
root unless `-AllowUnprotectedRun` is passed explicitly; that switch exists only
for development and tests. A deployment root that is a reparse point is rejected.

After the first deployment, running Bootstrap again from a user-writable clone
is rejected unless `-ForceRedeploy` is given, so a tampered clone cannot silently
replace the protected installation. `-ForceRedeploy` is an explicit operator
action: it means you have inspected the package you are deploying.

Explicitly out of scope for these checks:

- A compromised vendor feed, or a leaked vendor code-signing key. Both would produce input that passes every check, because the vendor is the only trusted party.
- The residual time-of-check/time-of-use (TOCTOU) race in `-StalePids`: Windows can reuse a PID after identity verification but before `Stop-Process`. The identity check reduces the chance considerably but cannot eliminate it without holding a process handle from verification through termination. Only pass freshly observed PIDs whose provenance you trust; do not pass guessed or uncertain PIDs.
- Newly created files inside the protected root (logs, backups, staged installers) take the creating process's owner under Windows defaults. A standard user who is the same account can therefore change that file's DACL via `WRITE_DAC`. The scripts and `lib` are protected from this because they are hardened at deploy time and never recreated by the scheduled task; a staged installer could in principle be altered between verification and execution by a process running under the operator's own account. This does not cross an account boundary (an attacker would already need that account's credentials), but it is not eliminated by the directory ACL alone. Holding a file handle open from verification through execution would require a different design and is not currently implemented.
- A tampered deployment package deliberately deployed with `-ForceRedeploy` by an operator who did not inspect it. This is equivalent to the operator running untrusted code as administrator directly.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** on this repository
(Security → Report a vulnerability) rather than opening a public issue.

Include:

- The affected file and line range.
- A description of the impact and the conditions required to trigger it.
- Steps to reproduce, if applicable.

You should receive an acknowledgement within 7 days. Please do not disclose the
issue publicly until a fix has been released or the report has been declined.

## Scope

In scope:

- The two PowerShell scripts in this repository, `lib/HWiNFO.Core.ps1` and `lib/HWiNFO.Deploy.ps1`.
- The documentation's security claims (update sources, signature verification, hash logging, elevation behavior, protected deployment ACLs).

Out of scope:

- Vulnerabilities in HWiNFO itself (report those to REALiX s.r.o.).
- Vulnerabilities in winget, curl.exe, or Windows (report those to Microsoft).
- Behavior caused by modified copies of the scripts.
