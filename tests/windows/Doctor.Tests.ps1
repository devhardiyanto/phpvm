Describe 'Invoke-Doctor' {
    BeforeAll {
        $env:PHPVM_DIR = Join-Path $TestDrive '.phpvm'
        New-Item -ItemType Directory -Path $env:PHPVM_DIR -Force | Out-Null
        . $PSScriptRoot/Common.ps1
    }

    AfterAll {
        Remove-Item Env:PHPVM_DIR -ErrorAction SilentlyContinue
    }

    It 'Warns and summarizes when no active PHP version is set' {
        Mock -CommandName Get-CurrentVersion -MockWith { $null }

        $out = Invoke-Doctor 6>&1 | Out-String

        $out | Should -Match 'environment health check'
        $out | Should -Match 'No active PHP version'
        $out | Should -Match 'warning\(s\)'
    }

    It 'Reports the active version and never throws' {
        Mock -CommandName Get-CurrentVersion -MockWith { '8.3.0' }
        # IniPath null -> exercises the "no php.ini" branch without hitting php.exe.
        Mock -CommandName Get-PHPBuildInfo -MockWith { @{ Exe = 'php'; IniPath = $null; ExtDir = 'C:\x\ext' } }

        $out = Invoke-Doctor 6>&1 | Out-String

        $out | Should -Match 'Active PHP version: 8\.3\.0'
    }
}
