<#
.SYNOPSIS
    Automatically updates HWiNFO 64 when a new stable release is announced.

.DESCRIPTION
    1. Reads the installed HWiNFO64.EXE version (ProductVersion, e.g. 8.52-6060 -> 8.52).
    2. Reads the official RSS feed (https://www.hwinfo.com/news.xml/) for the latest
       stable release. Beta / RC / pre-release announcements are intentionally ignored.
    3. When a newer stable version is available:
       - Backs up HWiNFO64.INI (preserves user settings).
       - Stops any running HWiNFO64 process and waits until it has actually exited.
       - Upgrades via winget (installer hash verified by winget), with a fallback to
         a direct download of the official installer. The fallback validates the PE
         header and the Authenticode signature (status and signer subject).
       - Verifies the resulting version.
       - Restarts HWiNFO if it was running before, even when the update failed.
    4. Writes every step to a log file.

.PARAMETER CheckOnly
    Report the version comparison only; do not download or install anything.

.PARAMETER Force
    Reinstall even when the installed version equals the announced version.
    Force never downgrades; use -AllowDowngrade for that.

.PARAMETER AllowDowngrade
    Explicitly allow installing an older version than the one currently installed.

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

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1 -Force

.NOTES
    Requires administrator rights to write to Program Files. When scheduled, use
    "Run with highest privileges" (see Bootstrap-HWiNFO-AutoUpdate.ps1).
#>
[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $Force,
    [switch] $AllowDowngrade,
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

. (Join-Path $PSScriptRoot 'lib\HWiNFO.Core.ps1')

# ---------------------------------------------------------------- constants
$RssUrl      = 'https://www.hwinfo.com/news.xml/'
$DownloadUrl = 'https://www.hwinfo.com/download/'
$WingetId    = 'REALiX.HWiNFO'
$TempRoot    = Join-Path $env:TEMP 'HWiNFO-AutoUpdate'
$BackupRoot  = Join-Path $PSScriptRoot 'HWiNFO-Backups'
# Every HWiNFO installer is ~20 MB; anything far smaller is an error page or a
# truncated transfer, not an installer.
$MinimumInstallerBytes = 10MB

# ---------------------------------------------------------------- logging
function Write-UpdateLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output for interactive and scheduled runs; every line is also written to the log file.')]
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

# ---------------------------------------------------------------- path detection
function Get-InstallDirectory {
    param([string] $Override)

    if ($Override) {
        if (Test-Path -LiteralPath (Join-Path $Override 'HWiNFO64.EXE')) {
            return $Override.TrimEnd('\')
        }
        throw "InstallDir override does not contain HWiNFO64.EXE: $Override"
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

    throw 'Cannot locate HWiNFO64.EXE. Use -InstallDir to specify the path.'
}

$resolvedInstallDir = Get-InstallDirectory -Override $InstallDir
$ExePath = Join-Path $resolvedInstallDir 'HWiNFO64.EXE'
$IniPath = Join-Path $resolvedInstallDir 'HWiNFO64.INI'

# ---------------------------------------------------------------- version helpers
function Get-LocalVersion {
    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "HWiNFO executable not found: $ExePath"
    }
    $vi  = (Get-Item -LiteralPath $ExePath).VersionInfo
    $raw = $vi.ProductVersion
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $vi.FileVersion }
    return ConvertTo-HWiNFOReleaseVersion -Value $raw
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
        return Get-LatestStableVersionFromXml -Xml $content
    } catch {
        throw "Failed to read the official release feed: $($_.Exception.Message)"
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
        Write-UpdateLog "Could not parse the download page, deriving the URL from the version: $($_.Exception.Message)" 'WARN'
    }

    # Fallback convention: 8.60 -> hwi64_860.exe, 8.52 -> hwi64_852.exe
    $tag = '{0}{1:00}' -f $Version.Major, $Version.Minor
    return "https://www.hwinfo.com/files/hwi64_$tag.exe"
}

# ---------------------------------------------------------------- upgrade paths
function Stop-HWiNFOProcess {
    <#
    .SYNOPSIS
        Stops every given HWiNFO64 process and waits until the PIDs disappear.

    .DESCRIPTION
        Works on captured process IDs rather than on the process name. A process
        can exit between Stop-Process and Wait-Process, and a name-based wait then
        fails even though the upgrade could proceed safely; polling the captured
        PIDs removes that race.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Unattended update script; -WhatIf is deliberately not part of the contract.')]
    param([Parameter(Mandatory)][int[]] $ProcessId)

    $pending = @($ProcessId)
    foreach ($targetId in $pending) {
        try {
            Stop-Process -Id $targetId -Force -ErrorAction Stop
        } catch {
            # Already exited: the polling loop below is the authority on that.
            Write-UpdateLog "HWiNFO64 PID=$targetId was already gone ($($_.Exception.Message))" 'WARN'
        }
    }

    $deadline = (Get-Date).AddSeconds(15)
    while ($true) {
        $alive = @($pending | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { return }
        if ((Get-Date) -ge $deadline) {
            throw "HWiNFO64 did not exit within 15 seconds (PID: $($alive -join ', ')); aborting to avoid a partial install"
        }
        Start-Sleep -Milliseconds 250
    }
}

function Invoke-WingetUpgrade {
    param([Parameter(Mandatory)][version] $Version)

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-UpdateLog 'winget not found; skipping the winget path' 'WARN'
        return $false
    }

    Write-UpdateLog "Installing $WingetId $Version via winget (installer hash verified by winget against its manifest)"
    $wingetArgs = @(
        'install', '--id', $WingetId, '--exact',
        '--version', $Version.ToString(), '--force',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    try {
        $output = & winget @wingetArgs 2>&1 | Out-String
        Write-UpdateLog ("winget output:`n" + $output.Trim())
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-UpdateLog "winget exited with code $LASTEXITCODE; falling back to direct download" 'WARN'
        return $false
    } catch {
        Write-UpdateLog "winget failed: $($_.Exception.Message); falling back to direct download" 'WARN'
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
            throw "Specified installer does not exist: $LocalInstaller"
        }
        $installer = $LocalInstaller
        Write-UpdateLog "Using specified installer: $installer"
    } else {
        $url = Get-InstallerUrl -Version $Version
        if (-not (Test-Path -LiteralPath $TempRoot)) {
            New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
        }
        $installer = Join-Path $TempRoot ("hwi64_{0}.exe" -f $Version.ToString().Replace('.', ''))
        $partial   = "$installer.part"

        # A previous run may have left a truncated file behind. Download into a
        # .part file and only promote it after the size check, so "the file exists"
        # never means "the download succeeded".
        Remove-Item -LiteralPath $partial, $installer -Force -ErrorAction SilentlyContinue

        Write-UpdateLog "Downloading official installer: $url"
        # The official CDN rejects Invoke-WebRequest with 403 in some environments;
        # curl.exe with a browser UA works and is used first when available.
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --silent --show-error --max-time 300 `
                -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36' `
                -e 'https://www.hwinfo.com/download/' `
                -o $partial $url 2>&1 | ForEach-Object { Write-UpdateLog $_ }

            if ($LASTEXITCODE -ne 0) {
                Write-UpdateLog "curl exited with code $LASTEXITCODE; discarding the partial download" 'WARN'
            } elseif (-not (Test-Path -LiteralPath $partial)) {
                Write-UpdateLog 'curl reported success but produced no file' 'WARN'
            } elseif ((Get-Item -LiteralPath $partial).Length -lt $MinimumInstallerBytes) {
                Write-UpdateLog ("curl produced an implausibly small file ({0} bytes); discarding it" -f (Get-Item -LiteralPath $partial).Length) 'WARN'
            } else {
                Move-Item -LiteralPath $partial -Destination $installer -Force
            }

            if (-not (Test-Path -LiteralPath $installer)) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not (Test-Path -LiteralPath $installer)) {
            Write-UpdateLog 'curl is unavailable or failed; trying Invoke-WebRequest' 'WARN'
            try {
                Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing `
                    -TimeoutSec 300 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
                $downloadedSize = (Get-Item -LiteralPath $partial).Length
                if ($downloadedSize -lt $MinimumInstallerBytes) {
                    throw "Downloaded file is implausibly small ($downloadedSize bytes)"
                }
                Move-Item -LiteralPath $partial -Destination $installer -Force
            } catch {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                throw "Failed to download the official installer: $($_.Exception.Message)"
            }
        }
    }

    # Integrity gate: reject HTML error pages, truncated files, and installers
    # that are not signed by the expected publisher.
    if (-not (Test-PeFile -Path $installer)) {
        throw "Downloaded file is not a structurally valid Windows executable: $installer"
    }
    Test-TrustedInstaller -Path $installer | Out-Null
    $hash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
    Write-UpdateLog "Installer verified. SHA256: $hash"

    Write-UpdateLog 'Running silent install (/VERYSILENT /SUPPRESSMSGBOXES /NORESTART)'
    $proc = Start-Process -FilePath $installer `
        -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' `
        -Wait -PassThru
    Write-UpdateLog "Installer exit code: $($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) {
        throw "Installer reported failure (exit code $($proc.ExitCode))"
    }
}

# ---------------------------------------------------------------- main
Write-UpdateLog '========== HWiNFO auto-update check started =========='
Write-UpdateLog "Install directory: $resolvedInstallDir"

$updateError = $null
$afterVersion = $null
$wasRunning = $false

try {
    $localVersion = Get-LocalVersion
    Write-UpdateLog "Installed version: $localVersion"

    $latestVersion = Get-LatestStableVersion
    Write-UpdateLog "Latest stable version: $latestVersion (source: $RssUrl)"

    if ($latestVersion -lt $localVersion -and -not $AllowDowngrade) {
        Write-UpdateLog "Installed version $localVersion is newer than the feed announcement ($latestVersion). Skipping to avoid a downgrade; use -AllowDowngrade to override." 'WARN'
        Write-UpdateLog '========== Check completed =========='
        exit 0
    }

    $needUpdate = ($latestVersion -gt $localVersion) -or
                  $Force -or
                  ($AllowDowngrade -and $latestVersion -lt $localVersion)

    if (-not $needUpdate) {
        Write-UpdateLog 'Already up to date.'
        Write-UpdateLog '========== Check completed =========='
        exit 0
    }
    if ($CheckOnly) {
        Write-UpdateLog "New version $latestVersion available (-CheckOnly; no changes made)." 'WARN'
        Write-UpdateLog '========== Check completed =========='
        exit 0
    }

    Write-UpdateLog "Updating: $localVersion -> $latestVersion"

    # Back up user settings before the installer touches the install directory.
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    if (Test-Path -LiteralPath $IniPath) {
        $backup = Join-Path $BackupRoot ('HWiNFO64.{0}.INI' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $IniPath -Destination $backup -Force
        Write-UpdateLog "Backed up settings: $backup"
    }

    # Inno Setup cannot overwrite files that are in use.
    $runningIds = @(Get-Process -Name HWiNFO64 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id)
    $wasRunning = $runningIds.Count -gt 0
    if ($wasRunning) {
        Write-UpdateLog ("Stopping running HWiNFO64 (PID: {0})..." -f ($runningIds -join ', '))
        Stop-HWiNFOProcess -ProcessId $runningIds
        Write-UpdateLog 'HWiNFO64 stopped.'
    }

    # Update order: explicit installer > winget > direct download
    if ($InstallerPath) {
        Invoke-ManualUpgrade -Version $latestVersion -LocalInstaller $InstallerPath
    } else {
        $updated = Invoke-WingetUpgrade -Version $latestVersion
        if ($updated) {
            # winget can report success without replacing the binary (for example when the
            # installed package is not the one it manages). Verify before trusting it.
            $probe = Get-LocalVersion
            if ($probe -lt $latestVersion) {
                Write-UpdateLog "winget reported success but the installed version is still $probe; falling back to direct download" 'WARN'
                $updated = $false
            }
        }
        if (-not $updated) {
            Invoke-ManualUpgrade -Version $latestVersion
        }
    }

    # Verify the result.
    $afterVersion = Get-LocalVersion
    Write-UpdateLog "Version after update: $afterVersion"
    if ($AllowDowngrade) {
        if ($afterVersion -ne $latestVersion) {
            throw "Update verification failed: expected exactly $latestVersion, got $afterVersion"
        }
    } elseif ($afterVersion -lt $latestVersion) {
        throw "Update verification failed: expected >= $latestVersion, got $afterVersion"
    }
} catch {
    $updateError = $_
    Write-UpdateLog "Update failed: $($_.Exception.Message)" 'ERROR'
} finally {
    # Always restore the previous run state, including on failure.
    if ($wasRunning -and -not $NoRestore) {
        try {
            Write-UpdateLog 'Restarting HWiNFO...'
            Start-Process -FilePath $ExePath -ErrorAction Stop
        } catch {
            Write-UpdateLog "Failed to restart HWiNFO: $($_.Exception.Message)" 'WARN'
        }
    }
}

if ($updateError) {
    Write-UpdateLog '========== Check completed with errors =========='
    exit 1
}

Write-UpdateLog "Update complete: $localVersion -> $afterVersion"
Write-UpdateLog '========== Check completed =========='
exit 0
