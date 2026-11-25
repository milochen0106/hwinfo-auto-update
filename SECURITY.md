# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.1.x | Yes |
| 1.0.x | No (superseded by 1.1.0) |

## Security model

The trust anchor is the vendor, REALiX s.r.o.:

- **Version signal**: the official RSS feed at `https://www.hwinfo.com/news.xml/`.
- **winget path**: the installer hash is verified by winget against the vendor's manifest.
- **Direct-download path**: the file must have a structurally valid PE header, a `Valid` Authenticode signature, and an organization field (`O`) exactly equal to `REALiX, s.r.o.`. The SHA-256 is logged for auditing but not pinned. Downloads are staged in a `.part` file and must exceed 10 MB before use.
- **`-InstallerPath`**: the same checks run before execution.
- **`-StalePids`**: a PID is only stopped when the process is a PowerShell host whose command line names one of this project's scripts.

Explicitly out of scope for these checks: a compromised vendor feed, or a leaked vendor code-signing key. Both would produce input that passes every check, because the vendor is the only trusted party.

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

- The two PowerShell scripts in this repository and `lib/HWiNFO.Core.ps1`.
- The documentation's security claims (update sources, signature verification, hash logging, elevation behavior).

Out of scope:

- Vulnerabilities in HWiNFO itself (report those to REALiX s.r.o.).
- Vulnerabilities in winget, curl.exe, or Windows (report those to Microsoft).
- Behavior caused by modified copies of the scripts.
