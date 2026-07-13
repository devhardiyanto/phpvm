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
