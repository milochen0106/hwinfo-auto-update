# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |

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

- The two PowerShell scripts in this repository.
- The documentation's security claims (update sources, hash verification, elevation behavior).

Out of scope:

- Vulnerabilities in HWiNFO itself (report those to REALiX s.r.o.).
- Vulnerabilities in winget, curl.exe, or Windows (report those to Microsoft).
- Behavior caused by modified copies of the scripts.
