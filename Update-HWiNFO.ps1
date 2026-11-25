<#
.SYNOPSIS
    Automatically updates HWiNFO 64 when a new stable release is announced.

.DESCRIPTION
    1. Reads the installed HWiNFO64.EXE version (ProductVersion, e.g. 8.52-6060 -> 8.52).
    2. Reads the official RSS feed (https://www.hwinfo.com/news.xml/) for the latest
       stable release. Beta / RC / pre-release announcements are intentionally ignored.
    3. When a newer stable version is available:
       - Backs up HWiNFO64.INI (preserves user settings).
       - Stops any running HWiNFO64 process.
       - Upgrades via winget (installer hash verified by winget), with a fallback to
         a direct download of the official installer.
       - Verifies the resulting version and optionally restarts HWiNFO.
    4. Writes every step to a log file.

.PARAMETER CheckOnly
    Report the version comparison only; do not download or install anything.

.PARAMETER Force
    Reinstall even when the installed version is equal or newer (repair scenario).

.PARAMETER NoRestore
    Do not restart HWiNFO after the update, even if it was running before.

.PARAMETER InstallerPath
    Use a pre-downloaded installer instead of winget or a network download.

.PARAMETER InstallDir
    Override the HWiNFO installation directory. By default it is detected from the
    Windows uninstall registry keys, then from the standard Program Files paths.

.PARAMETER LogPath
    Log file path. Defaults to Update-HWiNFO.log next to this script.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1 -CheckOnly

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1

.NOTES
    Requires administrator rights to write to Program Files. When scheduled, use
    "Run with highest privileges" (see Bootstrap-HWiNFO-AutoUpdate.ps1).
#>
[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $Force,
    [switch] $NoRestore,
    [string] $InstallerPath,
    [string] $InstallDir,
    [string] $LogPath
)

# $PSScriptRoot is not populated while parameter defaults are bound in PowerShell 5.1.
if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot 'Update-HWiNFO.log'
}

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- constants
$RssUrl      = 'https://www.hwinfo.com/news.xml/'
$DownloadUrl = 'https://www.hwinfo.com/download/'
$WingetId    = 'REALiX.HWiNFO'
$TempRoot    = Join-Path $env:TEMP 'HWiNFO-AutoUpdate'
$BackupRoot  = Join-Path $PSScriptRoot 'HWiNFO-Backups'

# ---------------------------------------------------------------- logging
function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [string] $Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Cannot write log file $LogPath : $($_.Exception.Message)"
    }
}

function ExitWithError {
    param([string] $Message)
    Write-Log $Message 'ERROR'
    exit 1
}

# ---------------------------------------------------------------- path detection
function Get-InstallDirectory {
    param([string] $Override)

    if ($Override) {
        if (Test-Path -LiteralPath (Join-Path $Override 'HWiNFO64.EXE')) {
            return $Override.TrimEnd('\')
        }
        ExitWithError "InstallDir override does not contain HWiNFO64.EXE: $Override"
    }

    # 1) Windows uninstall registry (HWiNFO uses an Inno Setup uninstall entry)
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $entries = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -match 'HWiNFO' -and
                $_.InstallLocation -and
                (Test-Path -LiteralPath (Join-Path $_.InstallLocation.TrimEnd('\') 'HWiNFO64.EXE'))
            }
        if ($entries) {
            return $entries[0].InstallLocation.TrimEnd('\')
        }
    }

    # 2) Standard installation paths
    foreach ($candidate in @('C:\Program Files\HWiNFO64', 'C:\Program Files (x86)\HWiNFO64')) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'HWiNFO64.EXE')) {
            return $candidate
        }
    }

    ExitWithError 'Cannot locate HWiNFO64.EXE. Use -InstallDir to specify the path.'
}

$resolvedInstallDir = Get-InstallDirectory -Override $InstallDir
$ExePath = Join-Path $resolvedInstallDir 'HWiNFO64.EXE'
$IniPath = Join-Path $resolvedInstallDir 'HWiNFO64.INI'

# ---------------------------------------------------------------- version helpers
function Get-LocalVersion {
    if (-not (Test-Path -LiteralPath $ExePath)) {
        ExitWithError "HWiNFO executable not found: $ExePath"
    }
    $vi  = (Get-Item -LiteralPath $ExePath).VersionInfo
    $raw = $vi.ProductVersion
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $vi.FileVersion }

    # 8.52-6060 -> 8.52
    if ($raw -match '^(\d+\.\d+)') {
        return [version] $Matches[1]
    }
    ExitWithError "Cannot parse installed version: $raw"
}

function Get-LatestStableVersion {
    try {
        $response = Invoke-WebRequest -Uri $RssUrl -UseBasicParsing -TimeoutSec 30
        # Invoke-WebRequest may return byte[] depending on the PowerShell host.
        $content = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string] $response.Content
        }
        [xml] $feed = $content

        $candidates = @()
        foreach ($item in $feed.rss.channel.item) {
            $title = [string] $item.title
            # Stable announcement format: "HWiNFO v8.60 released".
            # Exclude Beta / RC / pre-release announcements.
            if ($title -match 'HWiNFO\s+v(\d+\.\d+)(?:-\d+)?\s+released' -and
                $title -notmatch 'Beta|RC|pre.?release') {
                $candidates += [version] $Matches[1]
            }
        }
        if ($candidates.Count -eq 0) {
            ExitWithError 'No stable release announcement found in the official RSS feed'
        }
        return ($candidates | Sort-Object -Descending | Select-Object -First 1)
    } catch {
        ExitWithError "Failed to read the official release feed: $($_.Exception.Message)"
    }
}

function Get-InstallerUrl {
    param([Parameter(Mandatory)][version] $Version)

    try {
        $response = Invoke-WebRequest -Uri $DownloadUrl -UseBasicParsing -TimeoutSec 30
        $html = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string] $response.Content
        }
        # Prefer the "Local (U.S.)" installer link from the download page.
        if ($html -match 'href="(https?://www\.hwinfo\.com/files/hwi64_\d+\.exe)"') {
            return $Matches[1]
        }
        if ($html -match 'href="(/files/hwi64_\d+\.exe)"') {
            return 'https://www.hwinfo.com' + $Matches[1]
        }
    } catch {
        Write-Log "Could not parse the download page, deriving the URL from the version: $($_.Exception.Message)" 'WARN'
    }

    # Fallback convention: 8.60 -> hwi64_860.exe, 8.52 -> hwi64_852.exe
    $tag = '{0}{1:00}' -f $Version.Major, $Version.Minor
    return "https://www.hwinfo.com/files/hwi64_$tag.exe"
}

# ---------------------------------------------------------------- upgrade paths
function Invoke-WingetUpgrade {
    param([Parameter(Mandatory)][version] $Version)

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log 'winget not found; skipping the winget path' 'WARN'
        return $false
    }

    Write-Log "Installing $WingetId $Version via winget (publisher hash verified by winget)"
    $wingetArgs = @(
        'install', '--id', $WingetId, '--exact',
        '--version', $Version.ToString(), '--force',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    try {
        $output = & winget @wingetArgs 2>&1 | Out-String
        Write-Log ("winget output:`n" + $output.Trim())
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Log "winget exited with code $LASTEXITCODE; falling back to direct download" 'WARN'
        return $false
    } catch {
        Write-Log "winget failed: $($_.Exception.Message); falling back to direct download" 'WARN'
        return $false
    }
}

function Invoke-ManualUpgrade {
    param(
        [Parameter(Mandatory)][version] $Version,
        [string] $LocalInstaller
    )

    if ($LocalInstaller) {
        if (-not (Test-Path -LiteralPath $LocalInstaller)) {
            ExitWithError "Specified installer does not exist: $LocalInstaller"
        }
        $installer = $LocalInstaller
        Write-Log "Using specified installer: $installer"
    } else {
        $url = Get-InstallerUrl -Version $Version
        if (-not (Test-Path -LiteralPath $TempRoot)) {
            New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
        }
        $installer = Join-Path $TempRoot ("hwi64_{0}.exe" -f $Version.ToString().Replace('.', ''))

        Write-Log "Downloading official installer: $url"
        # The official CDN rejects Invoke-WebRequest with 403 in some environments;
        # curl.exe with a browser UA works and is used first when available.
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --silent --show-error --max-time 300 `
                -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36' `
                -e 'https://www.hwinfo.com/download/' `
                -o $installer $url 2>&1 | ForEach-Object { Write-Log $_ }
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $installer)) {
                Write-Log 'curl download failed; trying Invoke-WebRequest' 'WARN'
            }
        }
        if (-not (Test-Path -LiteralPath $installer)) {
            try {
                Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing `
                    -TimeoutSec 300 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
            } catch {
                ExitWithError "Failed to download the official installer: $($_.Exception.Message)"
            }
        }
    }

    $hash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
    Write-Log "Installer SHA256: $hash"
    Write-Log 'Running silent install (/VERYSILENT /SUPPRESSMSGBOXES /NORESTART)'
    try {
        $proc = Start-Process -FilePath $installer `
            -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' `
            -Wait -PassThru
        Write-Log "Installer exit code: $($proc.ExitCode)"
        if ($proc.ExitCode -ne 0) {
            ExitWithError "Installer reported failure (exit code $($proc.ExitCode))"
        }
    } catch {
        ExitWithError "Silent install failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- main
Write-Log '========== HWiNFO auto-update check started =========='
Write-Log "Install directory: $resolvedInstallDir"

$localVersion = Get-LocalVersion
Write-Log "Installed version: $localVersion"

$latestVersion = Get-LatestStableVersion
Write-Log "Latest stable version: $latestVersion (source: $RssUrl)"

$needUpdate = ($latestVersion -gt $localVersion) -or $Force
if (-not $needUpdate) {
    Write-Log 'Already up to date.'
    Write-Log '========== Check completed =========='
    exit 0
}
if ($CheckOnly) {
    Write-Log "New version $latestVersion available (-CheckOnly; no changes made)." 'WARN'
    Write-Log '========== Check completed =========='
    exit 0
}

Write-Log "Updating: $localVersion -> $latestVersion"

# Back up user settings before the installer touches the install directory.
if (-not (Test-Path -LiteralPath $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
}
if (Test-Path -LiteralPath $IniPath) {
    $backup = Join-Path $BackupRoot ('HWiNFO64.{0}.INI' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $IniPath -Destination $backup -Force
    Write-Log "Backed up settings: $backup"
}

# Inno Setup cannot overwrite files that are in use.
$wasRunning = @(Get-Process -Name HWiNFO64 -ErrorAction SilentlyContinue).Count -gt 0
if ($wasRunning) {
    Write-Log 'Stopping running HWiNFO64...'
    Stop-Process -Name HWiNFO64 -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Update order: explicit installer > winget > direct download
if ($InstallerPath) {
    Invoke-ManualUpgrade -Version $latestVersion -LocalInstaller $InstallerPath
} else {
    $updated = Invoke-WingetUpgrade -Version $latestVersion
    if (-not $updated) {
        Invoke-ManualUpgrade -Version $latestVersion
    }
}

# Verify the result.
$afterVersion = Get-LocalVersion
Write-Log "Version after update: $afterVersion"
if ($afterVersion -lt $latestVersion) {
    ExitWithError "Update verification failed: expected >= $latestVersion, got $afterVersion"
}

if ($wasRunning -and -not $NoRestore) {
    Write-Log 'Restarting HWiNFO...'
    Start-Process -FilePath $ExePath
}

Write-Log "Update complete: $localVersion -> $afterVersion"
Write-Log '========== Check completed =========='
exit 0
