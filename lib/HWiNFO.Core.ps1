<#
.SYNOPSIS
    Pure, testable helpers shared by Update-HWiNFO.ps1 and
    Bootstrap-HWiNFO-AutoUpdate.ps1.

.DESCRIPTION
    This file defines functions only. It performs no I/O and no installation.
    Dot-source it from a script or from Pester tests:

        . (Join-Path $PSScriptRoot 'lib\HWiNFO.Core.ps1')
#>

# ---------------------------------------------------------------- versions
function ConvertTo-HWiNFOReleaseVersion {
    <#
    .SYNOPSIS
        Converts a ProductVersion-style string to a comparable [version].
    .EXAMPLE
        ConvertTo-HWiNFOReleaseVersion '8.52-6060'  # -> 8.52
    #>
    param([Parameter(Mandatory)][string] $Value)

    if ($Value -match '^(\d+\.\d+)') {
        return [version] $Matches[1]
    }
    throw "Cannot parse HWiNFO version: '$Value'"
}

function Get-LatestStableVersionFromXml {
    <#
    .SYNOPSIS
        Parses the official HWiNFO RSS feed and returns the highest stable
        release version, excluding Beta / RC / pre-release announcements.
    #>
    param([Parameter(Mandatory)][string] $Xml)

    try {
        [xml] $feed = $Xml
    } catch {
        throw "Feed is not valid XML: $($_.Exception.Message)"
    }

    $candidates = @()
    foreach ($item in $feed.rss.channel.item) {
        $title = [string] $item.title
        if ($title -match 'HWiNFO\s+v(\d+\.\d+)(?:-\d+)?\s+released' -and
            $title -notmatch 'Beta|RC|pre.?release') {
            $candidates += [version] $Matches[1]
        }
    }

    if ($candidates.Count -eq 0) {
        throw 'No stable release announcement found in the feed'
    }
    return ($candidates | Sort-Object -Descending | Select-Object -First 1)
}

# ---------------------------------------------------------------- installer trust
function Test-PeFile {
    <#
    .SYNOPSIS
        Returns $true when the file starts with the DOS "MZ" signature.
    #>
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    $stream = [IO.File]::OpenRead($Path)
    try {
        $mz1 = $stream.ReadByte()
        $mz2 = $stream.ReadByte()
        return ($mz1 -eq 0x4D -and $mz2 -eq 0x5A)
    } finally {
        $stream.Dispose()
    }
}

function Test-TrustedInstaller {
    <#
    .SYNOPSIS
        Validates the Authenticode signature of an installer and checks that
        the signer subject matches the expected publisher.

    .DESCRIPTION
        A "Valid" Authenticode status alone is not enough: the certificate can
        belong to any publisher. Both the status and the signer subject are
        verified. The default subject pattern is the HWiNFO vendor REALiX.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $SubjectPattern = 'REALiX'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode signature is not valid (status: $($signature.Status))"
    }
    if (-not $signature.SignerCertificate) {
        throw 'Authenticode signature has no signer certificate'
    }
    if ($signature.SignerCertificate.Subject -notmatch $SubjectPattern) {
        throw "Unexpected signer: $($signature.SignerCertificate.Subject)"
    }
    return $true
}

# ---------------------------------------------------------------- input validation
function Test-ValidTaskTime {
    <#
    .SYNOPSIS
        Returns $true for a 24-hour HH:mm value (00:00 through 23:59).
    #>
    param([string] $Value)
    return ($Value -match '^([01]\d|2[0-3]):[0-5]\d$')
}

function Test-ValidTaskName {
    <#
    .SYNOPSIS
        Returns $true for a non-empty task name without characters that the
        Task Scheduler does not allow.
    #>
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -gt 200) { return $false }
    if ($Value -match '[\\/:*?"<>|]') { return $false }
    return $true
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        Returns $true when the current process has administrator rights.
    #>
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
