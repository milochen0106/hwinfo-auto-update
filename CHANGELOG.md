# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-11-26

Reliability pass on the update workflow itself. No new dependencies, no change to the public parameters or to the update paths.

### Added

- `tests/Update-HWiNFO.Workflow.Tests.ps1`: 13 integration tests of `Invoke-UpdateWorkflow` and `Invoke-ManualUpgrade` (59 total). Every network call, winget invocation, installer start and running-process lookup is mocked, so the suite stays unprivileged and touches nothing outside a temp directory. Covered: already up to date, downgrade skip, explicit downgrade, `-CheckOnly`, winget success, winget non-zero exit code, winget success with an unchanged binary, supplied installer, verification failure, restart on failure, `-NoRestore`, and installer exit-code handling.
- The workflow can now be exercised without installing anything: `Update-HWiNFO.ps1` calls `exit` only when launched as a file, not when dot-sourced by the tests.

### Changed

- The main flow was extracted into `Invoke-UpdateWorkflow` so its control flow is testable; command-line parameters and exit codes are unchanged.
- README and the Traditional Chinese guide now describe the integration tests and their limits (no real upgrade, no UAC elevation).

## [1.1.2] - 2026-11-26

### Fixed

- `-StalePids` no longer accepts a process merely because the script path appears somewhere in its command line. The command line is parsed for a real `-File` argument (quoted, single-quoted, unquoted or `-File=path`), and the value must match one of the expected scripts exactly (case-insensitive). A path used as a value to `-Command` or another parameter is rejected.

### Added

- Seven helper tests covering false-positive command lines and the supported `-File` forms (46 tests after this release).

## [1.1.1] - 2026-11-26

Bug-fix pass after a second static review. No architecture changes and no new dependencies.

### Fixed

- Signer verification now parses the certificate subject into fields and requires the organization (`O`) to equal `REALiX, s.r.o.` exactly. A substring match such as `REALiX`, or a valid certificate from another publisher, is rejected. The check targets the legal entity rather than a thumbprint, so certificate renewal by the same publisher keeps working.
- HWiNFO shutdown now captures the running PIDs first, stops those PIDs, and polls them for up to 15 seconds. This removes the race where the process exits between `Stop-Process` and a name-based `Wait-Process`.
- `-StalePids` only stops a PID when it belongs to `powershell`/`pwsh` and its command line names one of this project's scripts. Windows reuses PIDs, so an ID alone is not proof of identity.
- Downloads now use a `.part` file that is promoted only after a 10 MB minimum-size check. A failed `curl.exe` run discards its partial file before `Invoke-WebRequest` is attempted, and stale files from earlier runs are never reused.
- `Test-PeFile` now validates the PE signature, machine type, section count and optional-header magic instead of only the `MZ` bytes. The documentation no longer claims the MZ/PE shape check establishes integrity.
- README wording for winget: the SHA-256 comes from the package manifest, not directly from the publisher.

### Added

- Twelve more Pester tests (39 total) covering quoted/ambiguous certificate subject fields, exact publisher rejection, truncated and HTML files, and stale-PID matching.
- A Windows PowerShell 5.1 parse check in CI, which caught a `$variable:` interpolation error in the bootstrap during development.
- A test-status badge in both READMEs linking to the workflow run on `main`.

### Changed

- `Test-TrustedInstaller` parameter renamed from `-SubjectPattern` to `-ExpectedPublisher` (exact match). This is an internal helper; the scripts' public parameters are unchanged.

## [1.1.0] - 2026-11-26

Reliability and security pass. No behaviour change for a healthy installation; all changes affect failure paths and trust checks.

### Added

- `lib/HWiNFO.Core.ps1`: pure, testable helpers (version parsing, RSS parsing, PE header check, Authenticode + signer check, task-name/task-time validation, elevation detection). Both scripts and the test suite dot-source it.
- `tests/HWiNFO.Core.Tests.ps1`: 27 Pester tests that need no network, no installation and no administrator rights.
- `.github/workflows/tests.yml`: CI on `windows-latest` running Pester and PSScriptAnalyzer (error severity).
- Authenticode verification of the direct-download installer: signature status must be `Valid` **and** the signer subject must match `REALiX`; a valid signature from any other publisher is rejected.
- `-AllowDowngrade` switch, so a downgrade is an explicit decision instead of a side effect of `-Force`.

### Fixed

- HWiNFO is now restarted from a `finally` block, so a failed download, a failed installer or a failed verification no longer leaves it closed.
- The bootstrap waits for the elevated child and propagates its exit code instead of always returning success; when Windows forbids the cross-integrity wait it says so and points at the log.
- `Wait-Process` confirms that `HWiNFO64` actually exited before the installer runs; a process that ignores the stop request now aborts the update instead of producing a half-installed state.
- The bootstrap no longer terminates every `winget` process on the machine; only the PIDs passed via `-StalePids` are touched.
- `-TaskName`, `-TaskTime`, `-InstallerPath` and `-StalePids` are validated before elevation, so a typo cannot leave a partially configured task.
- The direct-download path rejects HTML error pages and truncated files by checking the `MZ` header before validating the signature.

### Changed

- README and the Traditional Chinese guide now describe the signature checks, the downgrade rule, the exit-code behaviour and the test workflow.
- The previous statement that the direct-download path only logs a SHA-256 was inaccurate; the hash is still logged for auditing, but execution is now gated on the signature.

## [1.0.2] - 2026-11-25

### Added

- `README.zh-TW.md`: a full Traditional Chinese (Taiwan) guide covering quick start, workflow, prerequisites, usage scenarios, parameters, scheduled task, logs/backups, troubleshooting, privacy audit, limitations, FAQ, and licensing.
- Language switch links in `README.md` and `README.zh-TW.md`.

## [1.0.1] - 2026-11-25

### Changed

- Git commit metadata now uses the GitHub noreply address instead of a personal email address; the public history was rewritten accordingly.
- `README.md` now explicitly documents that no PowerShell modules or plugins are required, and includes a tool/condition matrix describing built-in versus optional prerequisites.

## [1.0.0] - 2026-11-25

### Added

- Initial public release.
- `Update-HWiNFO.ps1`:
  - Stable-release detection via the official HWiNFO RSS feed, excluding Beta / RC / pre-release announcements.
  - Installed-version detection from `HWiNFO64.EXE` metadata.
  - Install-directory auto-detection from the Windows uninstall registry with Program Files fallback and `-InstallDir` override.
  - Timestamped `HWiNFO64.INI` backup before every upgrade.
  - Silent upgrade through winget with publisher hash verification and a direct-download fallback using `curl.exe`.
  - Post-install version verification and optional HWiNFO restart.
  - `-CheckOnly`, `-Force`, `-NoRestore`, `-InstallerPath`, and `-LogPath` parameters.
  - Append-only run log.
- `Bootstrap-HWiNFO-AutoUpdate.ps1`:
  - Self-elevating one-time setup with UAC prompt.
  - Optional stale-process cleanup via `-StalePids`.
  - Daily `HWiNFO-AutoUpdate` scheduled task registration with highest privileges and "start when available".
- Documentation: `README.md`, `LICENSE` (MIT), `SECURITY.md`, `.gitignore`, and this changelog.
