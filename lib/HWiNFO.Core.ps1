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
        Returns $true when the file has a structurally plausible PE header.

    .DESCRIPTION
        Checks more than the DOS "MZ" signature: the PE signature at e_lfanew, a
        non-zero machine type, at least one section, and an optional-header magic
        of PE32 (0x10B) or PE32+ (0x20B). This rejects HTML error pages and files
        truncated anywhere before the optional header, but it is still a shape
        check, not proof of integrity: the Authenticode signature check in
        Test-TrustedInstaller is what establishes that the content is the vendor's.
    #>
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 0x40) { return $false }

        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return $false }   # 'MZ'

        $stream.Position = 0x3C                                  # e_lfanew
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -lt 0x40 -or ($peOffset + 0x18) -gt $stream.Length) { return $false }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return $false }   # 'PE' + NUL NUL

        $machine      = $reader.ReadUInt16()
        $sections     = $reader.ReadUInt16()
        $null         = $reader.ReadUInt32()   # TimeDateStamp
        $null         = $reader.ReadUInt32()   # PointerToSymbolTable
        $null         = $reader.ReadUInt32()   # NumberOfSymbols
        $optionalSize = $reader.ReadUInt16()
        $null         = $reader.ReadUInt16()   # Characteristics

        if ($machine -eq 0 -or $sections -eq 0 -or $optionalSize -lt 2) { return $false }
        if (($stream.Position + 2) -gt $stream.Length) { return $false }

        $magic = $reader.ReadUInt16()
        return ($magic -eq 0x010B -or $magic -eq 0x020B)         # PE32 / PE32+
    } finally {
        $stream.Dispose()
    }
}

function Get-CertificateSubjectField {
    <#
    .SYNOPSIS
        Extracts one field (for example O or CN) from a rendered certificate subject.

    .DESCRIPTION
        Values that contain a comma are quoted in a rendered subject, for example
        O="REALiX, s.r.o."; splitting on commas would therefore be wrong. The
        parser honours double quotes and returns $null when the field is absent.

    .EXAMPLE
        Get-CertificateSubjectField -DistinguishedName 'CN="A, B", O="A, B"' -Field 'O'  # -> A, B
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $DistinguishedName,
        [Parameter(Mandatory)][string] $Field
    )

    # (?:^|,\s*) anchors on a field boundary so that O does not match OID.2.5.4.15.
    $pattern = '(?:^|,\s*){0}\s*=\s*(?:"([^"]*)"|([^,]*))' -f [regex]::Escape($Field)
    $match   = [regex]::Match($DistinguishedName, $pattern)
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value.Trim()
}

function Test-TrustedInstaller {
    <#
    .SYNOPSIS
        Validates the Authenticode signature of an installer and checks that the
        signer is the expected publisher.

    .DESCRIPTION
        A "Valid" Authenticode status alone is not enough: the certificate can
        belong to any publisher. The signer's organization field (O) must equal the
        expected publisher exactly, so a certificate whose subject merely contains
        the vendor name somewhere is rejected.

        The comparison is on the legal entity, not on a certificate thumbprint: a
        renewed certificate from the same publisher keeps working, while a stolen
        certificate from another publisher does not.

    .PARAMETER ExpectedPublisher
        Exact organization name (the certificate's O field).
        Default: REALiX, s.r.o. (the HWiNFO vendor).
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $ExpectedPublisher = 'REALiX, s.r.o.'
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

    $subject      = $signature.SignerCertificate.Subject
    $organization = Get-CertificateSubjectField -DistinguishedName $subject -Field 'O'
    if (-not $organization) {
        throw "Signer certificate has no organization (O) field: $subject"
    }
    if ($organization -ne $ExpectedPublisher) {
        throw "Unexpected publisher '$organization' (expected '$ExpectedPublisher')"
    }
    return $true
}

# ---------------------------------------------------------------- stale process cleanup
function Get-PowerShellFileArgument {
    <#
    .SYNOPSIS
        Extracts the script path passed to PowerShell's -File parameter.

    .DESCRIPTION
        Only a real -File argument is recognised. A path that merely appears
        somewhere else in the command line (for example as a value to -Command
        or as a positional argument) is deliberately ignored.

        Returns $null when -File is absent or cannot be parsed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $CommandLine)

    # Quoted values come first so that paths containing spaces are kept intact.
    $pattern = '(?:^|\s)-file(?:=|\s+)(?:"([^"]+)"|''([^'']+)''|(\S+))'
    $match   = [regex]::Match($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }

    foreach ($index in 1..3) {
        if ($match.Groups[$index].Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[$index].Value)) {
            return $match.Groups[$index].Value.Trim('"', "'")
        }
    }
    return $null
}

function Test-StaleProcessMatch {
    <#
    .SYNOPSIS
        Returns $true when a process really is a leftover run of this project's scripts.

    .DESCRIPTION
        Windows reuses process IDs, so a PID recorded during an earlier failure may
        belong to an unrelated program later. A process is only a safe target when
        it is a PowerShell host whose -File argument is exactly one of the expected
        script paths. A substring anywhere in the command line is not accepted.
    #>
    param(
        [string] $ProcessName,
        [string] $CommandLine,
        [Parameter(Mandatory)][string[]] $ExpectedPaths
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    if ($ProcessName -notin @('powershell', 'pwsh')) { return $false }
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }

    $filePath = Get-PowerShellFileArgument -CommandLine $CommandLine
    if (-not $filePath) { return $false }

    foreach ($expected in $ExpectedPaths) {
        if ([string]::IsNullOrWhiteSpace($expected)) { continue }
        if ([string]::Equals($filePath, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
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

function Test-ProtectedRunLocation {
    <#
    .SYNOPSIS
        Returns $true when a script directory is the protected deployment root.

    .DESCRIPTION
        A scheduled task with highest privileges must only load scripts from the
        ACL-hardened location created by the bootstrap. This is a pure path
        comparison; it does not inspect ACLs (that is done by the bootstrap when
        it deploys) and it does not resolve reparse points.
    #>
    param(
        [Parameter(Mandatory)][string] $ScriptDirectory,
        [string] $ProgramDataRoot
    )

    if (-not $ProgramDataRoot) {
        $ProgramDataRoot = Join-Path $env:ProgramData 'HWiNFO-AutoUpdate'
    }

    $expected = [IO.Path]::GetFullPath($ProgramDataRoot).TrimEnd('\')
    $actual   = [IO.Path]::GetFullPath($ScriptDirectory).TrimEnd('\')
    return [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)
}
