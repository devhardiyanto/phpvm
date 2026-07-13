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
