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
    It 'returns true for a Windows executable' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        Test-PeFile -Path (Join-Path $env:SystemRoot 'System32\notepad.exe') | Should -BeTrue
    }

    It 'returns false for a non-executable file' {
        Test-PeFile -Path (Join-Path $PSScriptRoot '..\README.md') | Should -BeFalse
    }

    It 'throws for a missing file' {
        { Test-PeFile -Path (Join-Path $env:TEMP 'does-not-exist-12345.exe') } | Should -Throw
    }
}

Describe 'Test-TrustedInstaller' {
    It 'accepts a valid Microsoft-signed binary when the publisher matches' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        { Test-TrustedInstaller -Path (Join-Path $env:SystemRoot 'System32\notepad.exe') -SubjectPattern 'Microsoft' } | Should -Not -Throw
    }

    It 'rejects a validly signed binary from a different publisher' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe'))) {
        { Test-TrustedInstaller -Path (Join-Path $env:SystemRoot 'System32\notepad.exe') -SubjectPattern 'REALiX' } | Should -Throw
    }

    It 'rejects an unsigned non-executable file' {
        { Test-TrustedInstaller -Path (Join-Path $PSScriptRoot '..\README.md') } | Should -Throw
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
