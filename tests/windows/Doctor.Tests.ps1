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

    Context 'Test-ExtDirMatch (ext_dir junction equivalence)' {
        It 'Accepts the version-specific ext path' {
            Test-ExtDirMatch "$VERSIONS_DIR\8.5.6\ext" '8.5.6' | Should -BeTrue
        }
        It 'Accepts the current\ext junction spelling' {
            Test-ExtDirMatch "$CURRENT_LINK\ext" '8.5.6' | Should -BeTrue
        }
        It 'Ignores a trailing backslash' {
            Test-ExtDirMatch "$VERSIONS_DIR\8.5.6\ext\" '8.5.6' | Should -BeTrue
        }
        It 'Rejects an unrelated extension_dir' {
            Test-ExtDirMatch 'C:\xampp\php\ext' '8.5.6' | Should -BeFalse
        }
        It 'Rejects an empty extension_dir' {
            Test-ExtDirMatch '' '8.5.6' | Should -BeFalse
        }
    }
}
