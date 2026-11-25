<#
.SYNOPSIS
    Integration tests for the update workflow in Update-HWiNFO.ps1.

.DESCRIPTION
    The script is dot-sourced with a fake install directory, so its path setup and
    entry point are exercised while every external effect (network, winget, the
    installer and running processes) is mocked. Nothing is installed or restarted
    and no file outside a temporary test directory is changed.
#>

BeforeAll {
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('hwinfo-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:FakeInstallDir = Join-Path $script:TestRoot 'HWiNFO64'
    New-Item -ItemType Directory -Path $script:FakeInstallDir -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $script:FakeInstallDir 'HWiNFO64.EXE') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $script:FakeInstallDir 'HWiNFO64.INI') -Force | Out-Null
    $script:FakeLog = Join-Path $script:TestRoot 'update.log'

    # A dot-source defines the functions but must not start the update or call exit.
    . (Join-Path $PSScriptRoot '..\Update-HWiNFO.ps1') `
        -InstallDir $script:FakeInstallDir -LogPath $script:FakeLog -AllowUnprotectedRun

    # Keep every side effect (backup copies, staged installers, log lines) inside
    # the temp directory instead of the repo's protected Downloads folder.
    $TempRoot = Join-Path $script:TestRoot 'Downloads'
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    $BackupRoot = Join-Path $script:TestRoot 'HWiNFO-Backups'
    Mock -CommandName Write-UpdateLog -MockWith { }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-UpdateWorkflow' {
    BeforeAll {
        # Get-LocalVersion is called once at the start and again after the update;
        # a queue lets a test describe the exact observed sequence.
        Mock -CommandName Get-LocalVersion -MockWith {
            if ($script:LocalVersions.Count -gt 0) {
                $next = [version] $script:LocalVersions[0]
                $script:LocalVersions = @($script:LocalVersions | Select-Object -Skip 1)
                return $next
            }
            return [version]'8.52'
        }
        Mock -CommandName Get-LatestStableVersion -MockWith { [version]'8.60' }
        Mock -CommandName Invoke-WingetUpgrade -MockWith { $true }
        Mock -CommandName Invoke-ManualUpgrade -MockWith { }
        Mock -CommandName Stop-HWiNFOProcess -MockWith { }
        Mock -CommandName Start-Process -MockWith { }
        Mock -CommandName Get-Process -MockWith { }
        Mock -CommandName Test-PeFile -MockWith { $true }
        Mock -CommandName Test-TrustedInstaller -MockWith { }
        Mock -CommandName Get-FileHash -MockWith { @{ Hash = 'TESTHASH' } }
    }

    BeforeEach {
        $script:LocalVersions = @()
    }

    It 'returns 0 without changing anything when already up to date' {
        Mock -CommandName Get-LatestStableVersion -MockWith { [version]'8.52' }

        Invoke-UpdateWorkflow | Should -Be 0
        Should -Invoke -CommandName Invoke-WingetUpgrade -Times 0
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 0
    }

    It 'skips a downgrade unless the caller explicitly allows it' {
        Mock -CommandName Get-LatestStableVersion -MockWith { [version]'8.40' }

        Invoke-UpdateWorkflow | Should -Be 0
        Should -Invoke -CommandName Invoke-WingetUpgrade -Times 0
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 0
    }

    It 'allows an explicit downgrade and verifies the exact version' {
        Mock -CommandName Get-LatestStableVersion -MockWith { [version]'8.40' }
        $script:LocalVersions = @([version]'8.52', [version]'8.40', [version]'8.40')

        Invoke-UpdateWorkflow -AllowDowngrade | Should -Be 0
        Should -Invoke -CommandName Invoke-WingetUpgrade -Times 1 -ParameterFilter {
            $Version -eq [version]'8.40'
        }
    }

    It 'reports a new version without changes under -CheckOnly' {
        Invoke-UpdateWorkflow -CheckOnly | Should -Be 0
        Should -Invoke -CommandName Invoke-WingetUpgrade -Times 0
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 0
    }

    It 'uses winget when winget actually replaces the binary' {
        $script:LocalVersions = @([version]'8.52', [version]'8.60', [version]'8.60')

        Invoke-UpdateWorkflow | Should -Be 0
        Should -Invoke -CommandName Invoke-WingetUpgrade -Times 1 -ParameterFilter {
            $Version -eq [version]'8.60'
        }
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 0
    }

    It 'falls back to the direct download when winget returns a non-zero exit code' {
        Mock -CommandName Invoke-WingetUpgrade -MockWith { $false }
        $script:LocalVersions = @([version]'8.52', [version]'8.60')

        Invoke-UpdateWorkflow | Should -Be 0
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 1
    }

    It 'falls back when winget reports success but the binary is unchanged' {
        $script:LocalVersions = @([version]'8.52', [version]'8.52', [version]'8.60')

        Invoke-UpdateWorkflow | Should -Be 0
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 1
    }

    It 'uses the supplied installer instead of winget' {
        $installer = Join-Path $script:TestRoot 'supplied.exe'
        New-Item -ItemType File -Path $installer -Force | Out-Null
        $script:LocalVersions = @([version]'8.52', [version]'8.60')

        Invoke-UpdateWorkflow -InstallerPath $installer | Should -Be 0
        Should -Invoke -CommandName Invoke-WingetUpgrade -Times 0
        Should -Invoke -CommandName Invoke-ManualUpgrade -Times 1 -ParameterFilter {
            $LocalInstaller -eq $installer
        }
    }

    It 'returns 1 when the post-update version is still old' {
        $script:LocalVersions = @([version]'8.52', [version]'8.52')

        Invoke-UpdateWorkflow | Should -Be 1
    }

    It 'restarts HWiNFO even when the update fails' {
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 4242 } }
        Mock -CommandName Invoke-WingetUpgrade -MockWith { $false }
        Mock -CommandName Invoke-ManualUpgrade -MockWith { throw 'download failed' }

        Invoke-UpdateWorkflow | Should -Be 1
        Should -Invoke -CommandName Stop-HWiNFOProcess -Times 1
        Should -Invoke -CommandName Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq $ExePath
        }
    }

    It 'does not restart HWiNFO with -NoRestore' {
        Mock -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 4242 } }
        Mock -CommandName Invoke-WingetUpgrade -MockWith { $false }
        Mock -CommandName Invoke-ManualUpgrade -MockWith { throw 'download failed' }

        Invoke-UpdateWorkflow -NoRestore | Should -Be 1
        Should -Invoke -CommandName Start-Process -Times 0
    }
}

Describe 'Invoke-ManualUpgrade' {
    BeforeAll {
        Mock -CommandName Test-PeFile -MockWith { $true }
        Mock -CommandName Test-TrustedInstaller -MockWith { }
        Mock -CommandName Get-FileHash -MockWith { @{ Hash = 'TESTHASH' } }
    }

    BeforeEach {
        Get-ChildItem -LiteralPath $TempRoot -Filter 'manual-*.exe' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    It 'aborts when the installer returns a non-zero exit code' {
        $installer = Join-Path $script:TestRoot 'failing-installer.exe'
        New-Item -ItemType File -Path $installer -Force | Out-Null
        Mock -CommandName Start-Process -MockWith { [pscustomobject]@{ ExitCode = 5 } }

        { Invoke-ManualUpgrade -Version '8.60' -LocalInstaller $installer } |
            Should -Throw '*exit code 5*'
    }

    It 'completes when the installer returns zero' {
        $installer = Join-Path $script:TestRoot 'passing-installer.exe'
        New-Item -ItemType File -Path $installer -Force | Out-Null
        Mock -CommandName Start-Process -MockWith { [pscustomobject]@{ ExitCode = 0 } }

        { Invoke-ManualUpgrade -Version '8.60' -LocalInstaller $installer } |
            Should -Not -Throw
    }

    It 'copies a supplied installer into the protected staging directory' {
        $source = Join-Path $script:TestRoot 'source-installer.exe'
        Set-Content -LiteralPath $source -Value 'payload' -Encoding UTF8
        Mock -CommandName Start-Process -MockWith { [pscustomobject]@{ ExitCode = 0 } }

        Invoke-ManualUpgrade -Version '8.60' -LocalInstaller $source

        $staged = @(Get-ChildItem -LiteralPath $TempRoot -Filter 'manual-*.exe')
        $staged.Count | Should -Be 1
        (Get-Content -LiteralPath $staged[0].FullName -Raw).Trim() | Should -Be 'payload'
    }
}
