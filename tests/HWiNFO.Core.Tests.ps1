<#
.SYNOPSIS
    Pester tests for lib\HWiNFO.Core.ps1.

.DESCRIPTION
    These tests are pure: they do not install anything, do not touch the network,
    and do not require HWiNFO to be installed. Signature tests use files that ship
    with Windows and are skipped when those files are unavailable.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\HWiNFO.Core.ps1')
}

Describe 'ConvertTo-HWiNFOReleaseVersion' {
    It 'parses a ProductVersion with a build suffix' {
        ConvertTo-HWiNFOReleaseVersion -Value '8.52-6060' | Should -Be ([version]'8.52')
    }

    It 'parses a three-part version' {
        ConvertTo-HWiNFOReleaseVersion -Value '8.60-6120' | Should -Be ([version]'8.60')
    }

    It 'parses a two-part version without a build suffix' {
        ConvertTo-HWiNFOReleaseVersion -Value '8.6' | Should -Be ([version]'8.6')
    }

    It 'throws on a value that is not a version' {
        { ConvertTo-HWiNFOReleaseVersion -Value 'not-a-version' } | Should -Throw
    }

    It 'throws on an empty string' {
        { ConvertTo-HWiNFOReleaseVersion -Value '' } | Should -Throw
    }
}

Describe 'Get-LatestStableVersionFromXml' {
    BeforeAll {
        $script:FeedWithStableAndBeta = @'
<?xml version="1.0" encoding="utf-8" ?>
<rss version="2.0">
  <channel>
    <title>HWiNFO/32/64 RSS News</title>
    <item><title>HWiNFO v8.60 released</title></item>
    <item><title>HWiNFO v8.61-6125 Beta released</title></item>
    <item><title>HWiNFO v8.58 released</title></item>
  </channel>
</rss>
'@

        $script:FeedOnlyBeta = @'
<?xml version="1.0" encoding="utf-8" ?>
<rss version="2.0">
  <channel>
    <item><title>HWiNFO v8.61-6125 Beta released</title></item>
    <item><title>HWiNFO v8.62 RC released</title></item>
  </channel>
</rss>
'@
    }

    It 'returns the highest stable version and ignores Beta' {
        Get-LatestStableVersionFromXml -Xml $script:FeedWithStableAndBeta |
            Should -Be ([version]'8.60')
    }

    It 'ignores RC and pre-release announcements' {
        { Get-LatestStableVersionFromXml -Xml $script:FeedOnlyBeta } | Should -Throw
    }

    It 'throws when the XML is malformed' {
        { Get-LatestStableVersionFromXml -Xml '<rss><channel>' } | Should -Throw
    }
}

Describe 'Test-PeFile' {
    BeforeAll {
        $script:Notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'

        # Structural rejects: a bare MZ header, and an HTML error page saved as .exe.
        $script:TruncatedExe = Join-Path $TestDrive 'truncated.exe'
        [IO.File]::WriteAllBytes($script:TruncatedExe, [byte[]](0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00))

        $script:HtmlExe = Join-Path $TestDrive 'page.exe'
        Set-Content -LiteralPath $script:HtmlExe -Value '<html><body>403 Forbidden</body></html>' -Encoding ASCII
    }

    It 'returns true for a Windows executable' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        Test-PeFile -Path $script:Notepad | Should -BeTrue
    }

    It 'returns false for a non-executable file' {
        Test-PeFile -Path (Join-Path $PSScriptRoot '..\README.md') | Should -BeFalse
    }

    It 'returns false for a file that only starts with MZ' {
        Test-PeFile -Path $script:TruncatedExe | Should -BeFalse
    }

    It 'returns false for an HTML error page saved as .exe' {
        Test-PeFile -Path $script:HtmlExe | Should -BeFalse
    }

    It 'throws for a missing file' {
        { Test-PeFile -Path (Join-Path $env:TEMP 'does-not-exist-12345.exe') } | Should -Throw
    }
}

Describe 'Get-CertificateSubjectField' {
    It 'reads a quoted organization containing a comma' {
        Get-CertificateSubjectField `
            -DistinguishedName 'CN="REALiX, s.r.o.", O="REALiX, s.r.o.", C=SK' `
            -Field 'O' | Should -Be 'REALiX, s.r.o.'
    }

    It 'reads an unquoted field' {
        Get-CertificateSubjectField `
            -DistinguishedName 'CN=Example Ltd, O=Example Ltd, C=GB' `
            -Field 'O' | Should -Be 'Example Ltd'
    }

    It 'does not confuse O with OID fields' {
        Get-CertificateSubjectField `
            -DistinguishedName 'OID.2.5.4.15=Private Organization, O="REALiX, s.r.o."' `
            -Field 'O' | Should -Be 'REALiX, s.r.o.'
    }

    It 'returns null when the field is absent' {
        Get-CertificateSubjectField -DistinguishedName 'CN=Example Ltd' -Field 'O' |
            Should -BeNullOrEmpty
    }
}

Describe 'Test-TrustedInstaller' {
    BeforeAll {
        $script:Notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    }

    It 'accepts a valid Microsoft-signed binary when the publisher matches' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        { Test-TrustedInstaller -Path $script:Notepad -ExpectedPublisher 'Microsoft Corporation' } | Should -Not -Throw
    }

    It 'rejects a validly signed binary from a different publisher' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        { Test-TrustedInstaller -Path $script:Notepad } | Should -Throw '*Unexpected publisher*'
    }

    It 'rejects a publisher name that only appears inside a longer organization' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        { Test-TrustedInstaller -Path $script:Notepad -ExpectedPublisher 'Microsoft' } | Should -Throw '*Unexpected publisher*'
    }

    It 'rejects an unsigned non-executable file' {
        { Test-TrustedInstaller -Path (Join-Path $PSScriptRoot '..\README.md') } | Should -Throw
    }
}

Describe 'Test-StaleProcessMatch' {
    BeforeAll {
        $script:UpdateScript = 'C:\Scripts\Update-HWiNFO.ps1'
    }

    It 'accepts a PowerShell host that runs the update script' {
        Test-StaleProcessMatch `
            -ProcessName 'powershell' `
            -CommandLine 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -File "C:\Scripts\Update-HWiNFO.ps1"' `
            -ExpectedPaths $script:UpdateScript | Should -BeTrue
    }

    It 'accepts pwsh and is case-insensitive about the path' {
        Test-StaleProcessMatch `
            -ProcessName 'pwsh' `
            -CommandLine 'C:\Program Files\PowerShell\7\pwsh.exe -File "c:\scripts\update-hwinfo.ps1"' `
            -ExpectedPaths $script:UpdateScript | Should -BeTrue
    }

    It 'rejects the same command line when the host is not PowerShell' {
        Test-StaleProcessMatch `
            -ProcessName 'notepad' `
            -CommandLine 'notepad.exe "C:\Scripts\Update-HWiNFO.ps1"' `
            -ExpectedPaths $script:UpdateScript | Should -BeFalse
    }

    It 'rejects a PowerShell host that runs something else' {
        Test-StaleProcessMatch `
            -ProcessName 'powershell' `
            -CommandLine 'powershell.exe -File "C:\Scripts\other.ps1"' `
            -ExpectedPaths $script:UpdateScript | Should -BeFalse
    }

    It 'rejects a process without a readable command line' {
        Test-StaleProcessMatch -ProcessName 'powershell' -CommandLine '' -ExpectedPaths $script:UpdateScript |
            Should -BeFalse
    }
}

Describe 'Test-ValidTaskTime' {
    It 'accepts <Value>' -ForEach @(
        @{ Value = '00:00' }
        @{ Value = '09:00' }
        @{ Value = '23:59' }
    ) {
        Test-ValidTaskTime -Value $Value | Should -BeTrue
    }

    It 'rejects <Value>' -ForEach @(
        @{ Value = '24:00' }
        @{ Value = '9:00' }
        @{ Value = '09:60' }
        @{ Value = '' }
        @{ Value = '09:00:00' }
    ) {
        Test-ValidTaskTime -Value $Value | Should -BeFalse
    }
}

Describe 'Test-ValidTaskName' {
    It 'accepts a normal task name' {
        Test-ValidTaskName -Value 'HWiNFO-AutoUpdate' | Should -BeTrue
    }

    It 'rejects an empty name' {
        Test-ValidTaskName -Value '' | Should -BeFalse
    }

    It 'rejects a name containing a backslash' {
        Test-ValidTaskName -Value 'bad\name' | Should -BeFalse
    }

    It 'rejects a name containing a colon' {
        Test-ValidTaskName -Value 'bad:name' | Should -BeFalse
    }

    It 'rejects a name longer than 200 characters' {
        Test-ValidTaskName -Value ('a' * 201) | Should -BeFalse
    }
}
