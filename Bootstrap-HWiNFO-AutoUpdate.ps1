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

    The non-elevated parent tries to wait for the elevated process so its exit
    code reflects the real result. If the wait is not permitted (a common Windows
    restriction when a lower-integrity process waits on a higher-integrity one),
    the parent reports the elevated PID and exits 0; the log then holds the final
    result.

.PARAMETER TaskName
    Name of the scheduled task. Default: HWiNFO-AutoUpdate.

.PARAMETER TaskTime
    Daily execution time (24-hour HH:mm). Default: 09:00.

.PARAMETER InstallerPath
    Optional path to a pre-downloaded installer; passed through to Update-HWiNFO.ps1.

.PARAMETER StalePids
    Optional list of process IDs from a previous, stuck update run to terminate.
    Only the listed PIDs are touched; unrelated winget processes are never stopped.
    A PID is accepted only if it currently belongs to powershell/pwsh with this
    project's script as its -File argument. Windows can reuse a PID between that
    check and termination, so pass only freshly observed, trusted PIDs.

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

. (Join-Path $root 'lib\HWiNFO.Core.ps1')

function Write-BootstrapLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output for interactive and scheduled runs; every line is also written to the log file.')]
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- input validation (before elevation)
$validationErrors = @()
if (-not (Test-ValidTaskName -Value $TaskName)) {
    $validationErrors += "Invalid task name '$TaskName'. It must be non-empty, at most 200 characters, and must not contain \\ / : * ? `" < > |."
}
if (-not (Test-ValidTaskTime -Value $TaskTime)) {
    $validationErrors += "Invalid task time '$TaskTime'. Use 24-hour HH:mm, for example 09:00 or 18:30."
}
if ($InstallerPath) {
    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        $validationErrors += "InstallerPath does not exist: $InstallerPath"
    } elseif ([IO.Path]::GetExtension($InstallerPath) -ne '.exe') {
        $validationErrors += "InstallerPath must point to an .exe file: $InstallerPath"
    }
}
foreach ($stalePid in $StalePids) {
    if ($stalePid -le 0) {
        $validationErrors += "StalePids must contain positive process IDs; got $stalePid."
    }
}
if ($validationErrors.Count -gt 0) {
    foreach ($validationError in $validationErrors) {
        Write-BootstrapLog "Validation error: $validationError"
    }
    exit 1
}

# ---------------------------------------------------------------- self-elevation
if (-not (Test-IsElevated)) {
    Write-BootstrapLog 'Not running as administrator; requesting elevation (approve the UAC prompt)...'
    $staleArg = if ($StalePids.Count) { '-StalePids ' + ($StalePids -join ',') } else { '' }
    $instArg  = if ($InstallerPath)   { '-InstallerPath "{0}"' -f $InstallerPath } else { '' }
    $argList  = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -TaskName "{1}" -TaskTime "{2}" {3} {4}' -f $PSCommandPath, $TaskName, $TaskTime, $instArg, $staleArg
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru
    } catch {
        Write-BootstrapLog "Elevation failed: $($_.Exception.Message)"
        exit 1
    }

    Write-BootstrapLog "Elevation requested, PID=$($proc.Id)."
    try {
        $proc.WaitForExit()
        Write-BootstrapLog "Elevated process exited with code $($proc.ExitCode)."
        exit $proc.ExitCode
    } catch {
        Write-BootstrapLog "Cannot wait for the elevated process ($($_.Exception.Message)). Check $logFile for the final result."
        exit 0
    }
}

Write-BootstrapLog 'Running with administrator privileges.'

# ---------------------------------------------------------------- stale process cleanup
foreach ($pidToStop in $StalePids) {
    if ($pidToStop -eq $PID) { continue }

    $target = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $pidToStop" -ErrorAction SilentlyContinue
    if (-not $target) {
        Write-BootstrapLog "Stale process PID=$pidToStop is not running; nothing to stop."
        continue
    }

    # Windows reuses PIDs: the recorded ID may now belong to an unrelated program.
    # Only PowerShell hosts whose command line names this project's scripts are
    # considered safe targets.
    $processName = [IO.Path]::GetFileNameWithoutExtension($target.Name)
    $isExpected  = Test-StaleProcessMatch `
        -ProcessName $processName `
        -CommandLine $target.CommandLine `
        -ExpectedPaths @($updateFile, $PSCommandPath)

    if (-not $isExpected) {
        Write-BootstrapLog "Refusing to stop PID=$($pidToStop): $($target.Name) is not a leftover run of this project's scripts. Re-check the PID before trying again."
        continue
    }

    try {
        Stop-Process -Id $pidToStop -Force -ErrorAction Stop
        Write-BootstrapLog "Stopped stale process PID=$pidToStop ($($target.Name))."
    } catch {
        Write-BootstrapLog "Could not stop PID=$pidToStop : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 1. update
Write-BootstrapLog 'Starting HWiNFO update...'
$updateArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $updateFile
if ($InstallerPath) {
    $updateArgs += ' -InstallerPath "{0}"' -f $InstallerPath
}
$updateProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $updateArgs -Wait -PassThru
$updateExit = $updateProc.ExitCode
if ($updateExit -eq 0) {
    Write-BootstrapLog 'Update succeeded.'
} else {
    Write-BootstrapLog "Update failed with exit code $updateExit. If update steps were interrupted, HWiNFO is restarted by Update-HWiNFO.ps1 when it was running before the update."
}

# ---------------------------------------------------------------- 2. scheduled task
$taskRegistered = $false
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
    Write-BootstrapLog "Scheduled task registered: $TaskName (state: $($task.State), daily at $TaskTime, highest privileges)"
    $taskRegistered = $true
} catch {
    Write-BootstrapLog "Failed to register the scheduled task: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- result
if ($updateExit -ne 0) {
    Write-BootstrapLog "Done with errors (update exit code: $updateExit, task registered: $taskRegistered)."
    exit $updateExit
}
if (-not $taskRegistered) {
    Write-BootstrapLog 'Done with errors (update succeeded, task registration failed).'
    exit 1
}

Write-BootstrapLog 'Done (update succeeded and scheduled task is registered).'
exit 0
