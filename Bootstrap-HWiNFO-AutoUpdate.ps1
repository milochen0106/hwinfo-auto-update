<#
.SYNOPSIS
    One-time setup: update HWiNFO with administrator rights and register a daily
    scheduled task that keeps it up to date automatically.

.DESCRIPTION
    Writing to Program Files and registering a task with "highest privileges" both
    require elevation. Running this script triggers a UAC prompt; approve it.
    The elevated process then:
      1. Terminates stale update processes listed in -StalePids (optional repair).
      2. Runs Update-HWiNFO.ps1 (upgrades to the latest stable release).
      3. Registers the scheduled task HWiNFO-AutoUpdate (daily, highest privileges).
    Results are written to Bootstrap-HWiNFO-AutoUpdate.log next to this script.

.PARAMETER TaskName
    Name of the scheduled task. Default: HWiNFO-AutoUpdate.

.PARAMETER TaskTime
    Daily execution time (24-hour HH:mm). Default: 09:00.

.PARAMETER InstallerPath
    Optional path to a pre-downloaded installer; passed through to Update-HWiNFO.ps1.

.PARAMETER StalePids
    Optional list of process IDs from a previous, stuck update run to terminate.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Bootstrap-HWiNFO-AutoUpdate.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '.\Bootstrap-HWiNFO-AutoUpdate.ps1' -TaskTime '18:30'"
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'HWiNFO-AutoUpdate',
    [string] $TaskTime = '09:00',
    [string] $InstallerPath,
    [int[]] $StalePids = @()
)

$ErrorActionPreference = 'Stop'

$root       = $PSScriptRoot
$updateFile = Join-Path $root 'Update-HWiNFO.ps1'
$logFile    = Join-Path $root 'Bootstrap-HWiNFO-AutoUpdate.log'

function Log {
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- self-elevation
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log 'Not running as administrator; requesting elevation (approve the UAC prompt)...'
    $staleArg = if ($StalePids.Count) { '-StalePids ' + ($StalePids -join ',') } else { '' }
    $instArg  = if ($InstallerPath)   { '-InstallerPath "{0}"' -f $InstallerPath } else { '' }
    $argList  = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -TaskName "{1}" -TaskTime "{2}" {3} {4}' -f $PSCommandPath, $TaskName, $TaskTime, $instArg, $staleArg
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru
        Log "Elevation requested, PID=$($proc.Id). Wait for the update to finish."
        exit 0
    } catch {
        Log "Elevation failed: $($_.Exception.Message)"
        exit 1
    }
}

Log 'Running with administrator privileges.'

# ---------------------------------------------------------------- stale process cleanup
foreach ($pidToStop in $StalePids) {
    try {
        Stop-Process -Id $pidToStop -Force -ErrorAction Stop
        Log "Stopped stale process PID=$pidToStop"
    } catch {
        Log "Could not stop PID=$pidToStop : $($_.Exception.Message)"
    }
}
foreach ($proc in @(Get-Process -Name winget -ErrorAction SilentlyContinue)) {
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        Log "Stopped winget PID=$($proc.Id)"
    } catch {
        Log "Could not stop winget PID=$($proc.Id) : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 1. update
Log 'Starting HWiNFO update...'
$updateArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $updateFile
if ($InstallerPath) {
    $updateArgs += ' -InstallerPath "{0}"' -f $InstallerPath
}
$updateProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $updateArgs -Wait -PassThru
$updateExit = $updateProc.ExitCode
Log "Update process exit code: $updateExit"
if ($updateExit -ne 0) {
    Log 'Update failed; still attempting to register the scheduled task so it can retry.'
}

# ---------------------------------------------------------------- 2. scheduled task
try {
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -NonInteractive -File "{0}"' -f $updateFile)
    $trigger = New-ScheduledTaskTrigger -Daily -At $TaskTime
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -RunLevel Highest `
        -Force | Out-Null

    $task = Get-ScheduledTask -TaskName $TaskName
    Log "Scheduled task registered: $TaskName (state: $($task.State), daily at $TaskTime, highest privileges)"
} catch {
    Log "Failed to register the scheduled task: $($_.Exception.Message)"
    exit 1
}

Log 'Done.'
