<#
.SYNOPSIS
    Pester tests for lib\HWiNFO.Deploy.ps1.

.DESCRIPTION
    icacls is mocked, so these tests never change real ACLs. ProgramData is
    redirected to a per-test temporary directory and restored afterwards.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\HWiNFO.Core.ps1')
    . (Join-Path $PSScriptRoot '..\lib\HWiNFO.Deploy.ps1')

    $script:OriginalProgramData = $env:ProgramData
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('hwinfo-deploy-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    Mock -CommandName Invoke-Icacls -MockWith {
        $script:IcaclsCalls += ,$IcaclsArgs
    }
    Mock -CommandName Invoke-TakeOwnership -MockWith { }
}

AfterAll {
    $env:ProgramData = $script:OriginalProgramData
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Install-ProtectedDeployment' {
    BeforeEach {
        $script:CaseRoot = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CaseRoot -Force | Out-Null
        $env:ProgramData = $script:CaseRoot

        $script:DeployRoot = Join-Path $script:CaseRoot 'HWiNFO-AutoUpdate'
        $script:SourceRoot = Join-Path $script:CaseRoot 'clone'
        New-Item -ItemType Directory -Path (Join-Path $script:SourceRoot 'lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceRoot 'Update-HWiNFO.ps1') -Value 'update' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:SourceRoot 'Bootstrap-HWiNFO-AutoUpdate.ps1') -Value 'bootstrap' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:SourceRoot 'lib\HWiNFO.Core.ps1') -Value 'core' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:SourceRoot 'lib\HWiNFO.Deploy.ps1') -Value 'deploy' -Encoding UTF8

        $script:IcaclsCalls = @()
    }

    It 'copies the payload, creates Downloads and locks the root owner' {
        Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $script:DeployRoot

        Test-Path -LiteralPath (Join-Path $script:DeployRoot 'Update-HWiNFO.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:DeployRoot 'Bootstrap-HWiNFO-AutoUpdate.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:DeployRoot 'lib\HWiNFO.Core.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:DeployRoot 'lib\HWiNFO.Deploy.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:DeployRoot 'Downloads') | Should -BeTrue

        Should -Invoke -CommandName Invoke-TakeOwnership -Times 1 -ParameterFilter {
            $Path -eq $script:DeployRoot
        }

        $resetCalls = @($script:IcaclsCalls | Where-Object {
            $_[0] -eq $script:DeployRoot -and $_ -contains '/reset'
        })
        $resetCalls.Count | Should -Be 1
    }

    It 'refuses to harden a reparse point under the deployment root' {
        Mock -CommandName Get-ChildItem -MockWith {
            [pscustomobject]@{
                FullName   = 'C:\ProgramData\HWiNFO-AutoUpdate\Downloads'
                PSIsContainer = $true
                Attributes = [IO.FileAttributes]::ReparsePoint
            }
        }

        { Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $script:DeployRoot } |
            Should -Throw '*reparse point*'
    }

    It 'rejects an existing deployment unless -Force is given' {
        Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $script:DeployRoot

        { Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $script:DeployRoot } |
            Should -Throw '*already exists*'
        { Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $script:DeployRoot -Force } |
            Should -Not -Throw
    }

    It 'refuses a deployment root outside ProgramData' {
        $other = Join-Path $script:CaseRoot 'SomewhereElse'
        { Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $other } |
            Should -Throw '*DeployRoot must be*'
    }

    It 'can re-harden a deployment when run from the protected copy itself' {
        Install-ProtectedDeployment -SourceRoot $script:SourceRoot -DeployRoot $script:DeployRoot
        $script:IcaclsCalls = @()

        { Install-ProtectedDeployment -SourceRoot $script:DeployRoot -DeployRoot $script:DeployRoot } |
            Should -Not -Throw
        $script:IcaclsCalls.Count | Should -BeGreaterThan 0
    }
}
