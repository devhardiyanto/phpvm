Describe 'Bootstrap' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Dot-sources phpvm.ps1 without running the entry switch' {
        Get-Command Get-VSVersion -CommandType Function | Should -Not -BeNullOrEmpty
    }

    It 'Exposes $PHPVM_VERSION matching version.txt' {
        $expected = (Get-Content (Join-Path $PSScriptRoot '..\..\version.txt') -Raw).Trim()
        $PHPVM_VERSION | Should -Be $expected
    }
}
