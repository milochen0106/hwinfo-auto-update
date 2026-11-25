# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
