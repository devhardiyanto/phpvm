Describe 'Version commands' {
    BeforeAll {
        $env:PHPVM_DIR = Join-Path $TestDrive '.phpvm'
        New-Item -ItemType Directory -Path $env:PHPVM_DIR -Force | Out-Null
        . $PSScriptRoot/Common.ps1

        # Fake installs: a dir per version, php.exe stubbed as a plain file so the
        # "missing php.exe" guard can be exercised separately.
        function New-FakeVersion ([string]$ver, [switch]$NoExe) {
            $dir = Join-Path $VERSIONS_DIR $ver
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if (-not $NoExe) { Set-Content (Join-Path $dir 'php.exe') 'stub' }
            return $dir
        }

        function New-CurrentJunction ([string]$ver) {
            Remove-Junction $CURRENT_LINK
            cmd /c mklink /J "$CURRENT_LINK" "$VERSIONS_DIR\$ver" | Out-Null
        }
    }

    AfterAll {
        Remove-Junction $CURRENT_LINK
        Remove-Item Env:PHPVM_DIR -ErrorAction SilentlyContinue
    }

    Context 'Get-CurrentVersion / Remove-Junction' {
        It 'Returns $null when no current junction exists' {
            Remove-Junction $CURRENT_LINK
            Get-CurrentVersion | Should -BeNullOrEmpty
        }

        It 'Reads the version off the junction target' {
            New-FakeVersion '8.3.10' | Out-Null
            New-CurrentJunction '8.3.10'

            Get-CurrentVersion | Should -Be '8.3.10'
        }

        It 'Drops the junction without deleting the version it points at' {
            New-FakeVersion '8.3.10' | Out-Null
            New-CurrentJunction '8.3.10'

            Remove-Junction $CURRENT_LINK

            Test-Path $CURRENT_LINK | Should -BeFalse
            Test-Path "$VERSIONS_DIR\8.3.10\php.exe" | Should -BeTrue
        }
    }

    Context 'Invoke-Use guards' {
        # The happy path rewrites the *User* PATH and broadcasts WM_SETTINGCHANGE,
        # so only the pre-PATH guards are exercised here.
        It 'Prints usage when no version is given' {
            $out = Invoke-Use '' 6>&1 | Out-String
            $out | Should -Match 'Usage: phpvm use <version>'
        }

        It 'Refuses a version that is not installed' {
            $out = Invoke-Use '5.4.0' 6>&1 | Out-String
            $out | Should -Match 'PHP 5\.4\.0 is not installed'
            $out | Should -Match 'phpvm install 5\.4\.0'
        }

        It 'Refuses an install directory with no php.exe' {
            New-FakeVersion '7.4.33' -NoExe | Out-Null

            $out = Invoke-Use '7.4.33' 6>&1 | Out-String

            $out | Should -Match 'Invalid PHP 7\.4\.33 install'
            $out | Should -Match 'missing'
        }

        It 'Leaves the current junction untouched when a guard trips' {
            New-FakeVersion '8.3.10' | Out-Null
            New-CurrentJunction '8.3.10'

            $null = Invoke-Use '5.4.0' 6>&1

            Get-CurrentVersion | Should -Be '8.3.10'
        }
    }

    Context 'Invoke-List' {
        It 'Says nothing is installed on an empty versions dir' {
            Remove-Item "$VERSIONS_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Junction $CURRENT_LINK

            $out = Invoke-List 6>&1 | Out-String

            $out | Should -Match 'No PHP versions installed'
        }

        It 'Lists installed versions sorted by name' {
            New-FakeVersion '8.1.2'  | Out-Null
            New-FakeVersion '8.3.10' | Out-Null

            $out = Invoke-List 6>&1 | Out-String

            $out | Should -Match 'Installed versions:'
            $out.IndexOf('8.1.2') | Should -BeLessThan $out.IndexOf('8.3.10')
        }

        It 'Marks the active version with an arrow' {
            New-FakeVersion '8.1.2'  | Out-Null
            New-FakeVersion '8.3.10' | Out-Null
            New-CurrentJunction '8.3.10'

            $out = Invoke-List 6>&1 | Out-String

            $out | Should -Match '->\s+8\.3\.10\s+\(active\)'
            $out | Should -Not -Match '->\s+8\.1\.2'
        }
    }

    Context 'Invoke-Current' {
        It 'Warns when nothing is active' {
            Mock -CommandName Get-CurrentVersion -MockWith { $null }

            $out = Invoke-Current 6>&1 | Out-String

            $out | Should -Match 'No PHP version active'
        }

        It 'Reports the active version' {
            Mock -CommandName Get-CurrentVersion -MockWith { '8.3.10' }

            $out = Invoke-Current 6>&1 | Out-String

            $out | Should -Match 'Active: 8\.3\.10'
        }
    }

    Context 'Invoke-Uninstall' {
        It 'Prints usage when no version is given' {
            $out = Invoke-Uninstall '' 6>&1 | Out-String
            $out | Should -Match 'Usage: phpvm uninstall <version>'
        }

        It 'Refuses a version that is not installed' {
            $out = Invoke-Uninstall '5.4.0' 6>&1 | Out-String
            $out | Should -Match 'PHP 5\.4\.0 is not installed'
        }

        It 'Refuses to remove the active version' {
            New-FakeVersion '8.3.10' | Out-Null
            New-CurrentJunction '8.3.10'

            $out = Invoke-Uninstall '8.3.10' 6>&1 | Out-String

            $out | Should -Match 'Cannot uninstall the active version'
            Test-Path "$VERSIONS_DIR\8.3.10" | Should -BeTrue
        }

        It 'Removes an inactive version from disk' {
            New-FakeVersion '8.3.10' | Out-Null
            New-FakeVersion '8.1.2'  | Out-Null
            New-CurrentJunction '8.3.10'

            $out = Invoke-Uninstall '8.1.2' 6>&1 | Out-String

            $out | Should -Match 'PHP 8\.1\.2 has been removed'
            Test-Path "$VERSIONS_DIR\8.1.2" | Should -BeFalse
        }
    }

    Context 'Invoke-Which' {
        BeforeAll {
            $script:ShimDir = Join-Path $TestDrive 'shim'
            New-Item -ItemType Directory -Path $script:ShimDir -Force | Out-Null
            Set-Content (Join-Path $script:ShimDir 'php.cmd') '@echo off'
        }

        BeforeEach {
            $script:SavedPath = $env:PATH
            # The ext tests stand a global 'php' function up; it would shadow PATH.
            Remove-Item Function:\php -ErrorAction SilentlyContinue
        }

        AfterEach { $env:PATH = $script:SavedPath }

        It 'Reports the resolved php on PATH' {
            $env:PATH = "$script:ShimDir;$env:PATH"

            $out = Invoke-Which 6>&1 | Out-String

            $out | Should -Match 'php\.cmd'
        }

        It 'Warns when php is not on PATH' {
            $env:PATH = Join-Path $TestDrive 'empty'

            $out = Invoke-Which 6>&1 | Out-String

            $out | Should -Match 'php not found in PATH'
        }
    }

    Context 'Invoke-Ini' {
        It 'Errors when no version is active' {
            Mock -CommandName Get-CurrentVersion -MockWith { $null }
            Mock -CommandName Start-Process -MockWith { }

            $out = Invoke-Ini 6>&1 | Out-String

            $out | Should -Match 'No active PHP version'
            Should -Invoke Start-Process -Times 0
        }

        It 'Errors when the active version has no php.ini' {
            New-FakeVersion '8.3.10' | Out-Null
            Remove-Item "$VERSIONS_DIR\8.3.10\php.ini" -Force -ErrorAction SilentlyContinue
            Mock -CommandName Get-CurrentVersion -MockWith { '8.3.10' }
            Mock -CommandName Start-Process -MockWith { }

            $out = Invoke-Ini 6>&1 | Out-String

            $out | Should -Match 'php\.ini not found'
            Should -Invoke Start-Process -Times 0
        }

        It 'Opens the php.ini of the active version' {
            New-FakeVersion '8.3.10' | Out-Null
            Set-Content "$VERSIONS_DIR\8.3.10\php.ini" '; stub'
            Mock -CommandName Get-CurrentVersion -MockWith { '8.3.10' }
            Mock -CommandName Start-Process -MockWith { }

            $out = Invoke-Ini 6>&1 | Out-String

            $out | Should -Match 'Opening .*8\.3\.10\\php\.ini'
            Should -Invoke Start-Process -ParameterFilter { $FilePath -eq 'notepad' }
        }
    }

    Context 'Show-OlderPatchHint' {
        It 'Names the older patches of the same minor line' {
            New-FakeVersion '8.3.1'  | Out-Null
            New-FakeVersion '8.3.10' | Out-Null

            $out = Show-OlderPatchHint '8.3.10' 6>&1 | Out-String

            $out | Should -Match 'Older patch of 8\.3 still installed: 8\.3\.1'
            $out | Should -Match 'phpvm uninstall 8\.3\.1'
        }

        It 'Stays silent when nothing older is installed' {
            Remove-Item "$VERSIONS_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Junction $CURRENT_LINK
            New-FakeVersion '8.3.10' | Out-Null

            $out = Show-OlderPatchHint '8.3.10' 6>&1 | Out-String

            $out.Trim() | Should -BeNullOrEmpty
        }
    }
}
