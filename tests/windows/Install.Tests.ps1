Describe 'Invoke-Install version guard' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Rejects a non-version argument instead of throwing' {
        Mock -CommandName Write-Err -MockWith {}
        Mock -CommandName Write-Dim -MockWith {}
        Mock -CommandName Resolve-PHPURL -MockWith { throw 'must not be reached' }

        { Invoke-Install 'composer' } | Should -Not -Throw

        Should -Invoke Write-Err -Times 1 -ParameterFilter {
            $m -like "Invalid version 'composer'*"
        }
        Should -Invoke Resolve-PHPURL -Times 0
    }

    It 'Hints at the composer command on that specific typo' {
        Mock -CommandName Write-Err -MockWith {}
        Mock -CommandName Write-Dim -MockWith {}
        Mock -CommandName Resolve-PHPURL -MockWith { throw 'must not be reached' }

        Invoke-Install 'composer'

        Should -Invoke Write-Dim -Times 1 -ParameterFilter {
            $m -like '*phpvm composer*'
        }
    }

    It 'Rejects a malformed version' {
        Mock -CommandName Write-Err -MockWith {}
        Mock -CommandName Resolve-PHPURL -MockWith { throw 'must not be reached' }

        { Invoke-Install '8.3.x' } | Should -Not -Throw

        Should -Invoke Write-Err -Times 1 -ParameterFilter {
            $m -like 'Invalid version*'
        }
        Should -Invoke Resolve-PHPURL -Times 0
    }
}

Describe 'Invoke-Install --no-use parsing' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    BeforeEach {
        Mock -CommandName Write-Err -MockWith {}
        Mock -CommandName Write-Dim -MockWith {}
        Mock -CommandName Resolve-PHPURL -MockWith { throw 'must not be reached' }
    }

    # The flag must be stripped in either position, matching the Linux arg loop.
    # A deliberately malformed version proves which token was taken as the version.
    It 'Strips the flag when it trails the version' {
        Invoke-Install '8.3.x' '--no-use'
        Should -Invoke Write-Err -Times 1 -ParameterFilter { $m -like "Invalid version '8.3.x'*" }
    }

    It 'Strips the flag when it leads the version' {
        Invoke-Install '--no-use' '8.3.x'
        Should -Invoke Write-Err -Times 1 -ParameterFilter { $m -like "Invalid version '8.3.x'*" }
    }

    It 'Errors on usage when --no-use is passed with no version' {
        Invoke-Install '--no-use' ''
        Should -Invoke Write-Err -Times 1 -ParameterFilter { $m -like 'Usage: phpvm install*' }
    }

    It 'Rejects an unknown option' {
        Invoke-Install '8.3.0' '--bogus'
        Should -Invoke Write-Err -Times 1 -ParameterFilter { $m -like 'Unknown option: --bogus*' }
        Should -Invoke Resolve-PHPURL -Times 0
    }
}

Describe 'Get-OlderPatch' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1

        # Build a fake $VERSIONS_DIR. 8.50.1 is here on purpose: it must not be
        # mistaken for part of the 8.5 line.
        $fakeVersions = Join-Path $TestDrive 'versions'
        foreach ($v in @('7.4.33', '8.3.31', '8.5.2', '8.5.6', '8.5.8', '8.5.10', '8.5.11', '8.50.1')) {
            New-Item -ItemType Directory -Path (Join-Path $fakeVersions $v) -Force | Out-Null
        }
        # Reassign $VERSIONS_DIR; functions read it dynamically.
        $VERSIONS_DIR = $fakeVersions
    }

    It 'Lists only lower patches of the same minor line' {
        Get-OlderPatch '8.5.8' | Should -Be @('8.5.2', '8.5.6')
    }

    It 'Sorts numerically, not lexically' {
        Get-OlderPatch '8.5.11' | Should -Be @('8.5.2', '8.5.6', '8.5.8', '8.5.10')
    }

    It 'Does not treat 8.50.x as part of the 8.5 line' {
        Get-OlderPatch '8.50.1' | Should -BeNullOrEmpty
    }

    It 'Returns nothing when it is the only patch of its line' {
        Get-OlderPatch '8.3.31' | Should -BeNullOrEmpty
    }
}
