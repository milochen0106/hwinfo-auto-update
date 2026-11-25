<#
.SYNOPSIS
    Deployment helpers used by Bootstrap-HWiNFO-AutoUpdate.ps1.

.DESCRIPTION
    Unlike HWiNFO.Core.ps1, these helpers perform file-system and icacls I/O.
    They are kept separate so Pester can test them with mocked icacls/takeown calls.
    Dot-source HWiNFO.Core.ps1 first because Test-ProtectedRunLocation is used.
#>

function Invoke-Icacls {
    <#
    .SYNOPSIS
        Runs icacls and turns a non-zero exit code into a terminating error.
    #>
    param([Parameter(Mandatory)][string[]] $IcaclsArgs)

    & icacls @IcaclsArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls $($IcaclsArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-TakeOwnership {
    <#
    .SYNOPSIS
        Assigns ownership to BUILTIN\Administrators using takeown /A.

    .DESCRIPTION
        icacls /setowner to a group SID fails with access denied (exit 5) even
        from an elevated shell: it does not enable SeTakeOwnershipPrivilege.
        takeown /A enables that privilege and sets the owner directly to the
        Administrators group, which is the owner this deployment requires.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
    & $takeown /F $Path /A | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "takeown /A failed for $Path with exit code $LASTEXITCODE"
    }
}

function Protect-HWiNFODeployRoot {
    <#
    .SYNOPSIS
        Removes inherited ACLs and grants access only to SYSTEM and Administrators.

    .DESCRIPTION
        Owner must also be changed to BUILTIN\Administrators. If the owner stays
        the individual admin account, the same person's standard token still has
        implicit WRITE_DAC and can restore write access to the scripts.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to use a reparse point as the deployment root: $Path"
    }

    $system = '*S-1-5-18'        # NT AUTHORITY\SYSTEM
    $admins = '*S-1-5-32-544'    # BUILTIN\Administrators

    # /reset replaces any explicit ACEs planted before this script ran; without it
    # /inheritance:r only removes inherited entries and keeps an attacker's grant.
    Invoke-Icacls @($Path, '/reset')
    Invoke-Icacls @($Path, '/inheritance:r')
    Invoke-TakeOwnership -Path $Path
    Invoke-Icacls @($Path, '/grant:r', "${system}:(OI)(CI)F")
    Invoke-Icacls @($Path, '/grant:r', "${admins}:(OI)(CI)F")

    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to harden a reparse point under the deployment root: $($_.FullName)"
        }
        $permission = if ($_.PSIsContainer) { '(OI)(CI)F' } else { 'F' }
        Invoke-Icacls @($_.FullName, '/reset')
        Invoke-Icacls @($_.FullName, '/inheritance:r')
        Invoke-TakeOwnership -Path $_.FullName
        Invoke-Icacls @($_.FullName, '/grant:r', "${system}:$permission")
        Invoke-Icacls @($_.FullName, '/grant:r', "${admins}:$permission")
    }
}

function Install-ProtectedDeployment {
    <#
    .SYNOPSIS
        Copies the payload into ProgramData and locks it down before it is used.
    #>
    param(
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $DeployRoot,
        [switch] $Force
    )

    $expected = Join-Path $env:ProgramData 'HWiNFO-AutoUpdate'
    if ([IO.Path]::GetFullPath($DeployRoot) -ne [IO.Path]::GetFullPath($expected)) {
        throw "DeployRoot must be $expected"
    }

    if (-not (Test-ProtectedRunLocation -ScriptDirectory $SourceRoot -ProgramDataRoot $expected) -and
        (Test-Path -LiteralPath (Join-Path $DeployRoot 'Update-HWiNFO.ps1')) -and
        -not $Force) {
        throw "A protected deployment already exists at $DeployRoot. Run Bootstrap from there, or pass -ForceRedeploy explicitly."
    }

    New-Item -ItemType Directory -Path (Join-Path $DeployRoot 'lib') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DeployRoot 'Downloads') -Force | Out-Null

    foreach ($relative in @(
        'Update-HWiNFO.ps1',
        'Bootstrap-HWiNFO-AutoUpdate.ps1',
        'lib\HWiNFO.Core.ps1',
        'lib\HWiNFO.Deploy.ps1'
    )) {
        $source = Join-Path $SourceRoot $relative
        $destination = Join-Path $DeployRoot $relative
        if ([IO.Path]::GetFullPath($source) -eq [IO.Path]::GetFullPath($destination)) {
            continue   # already running from the protected deployment
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    Protect-HWiNFODeployRoot -Path $DeployRoot
}
