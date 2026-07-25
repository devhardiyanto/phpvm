Describe 'Tools and maintenance commands' {
    BeforeAll {
        $env:PHPVM_DIR = Join-Path $TestDrive '.phpvm'
        New-Item -ItemType Directory -Path $env:PHPVM_DIR -Force | Out-Null
        . $PSScriptRoot/Common.ps1

        New-Item -ItemType Directory -Path $VERSIONS_DIR -Force | Out-Null
        New-Item -ItemType Directory -Path $PHPVM_BIN    -Force | Out-Null

        # See Ext.Tests.ps1: `& $info.Exe` resolves Exe as a command name.
        $script:PhpModules = @('Core', 'curl', 'openssl')
        function global:php { if ($args -contains '-m') { return $script:PhpModules }; return @() }

        $script:BuildInfo = @{
            Version = '8.3.10'
            Short   = '8.3'
            TS      = 'nts'
            VS      = 'vs16'
            Arch    = 'x64'
            Exe     = 'php'
            Root    = (Join-Path $TestDrive 'php')
            ExtDir  = (Join-Path $TestDrive 'php\ext')
            IniPath = (Join-Path $TestDrive 'php\php.ini')
        }
    }

    AfterAll {
        Remove-Item Function:\php -ErrorAction SilentlyContinue
        Remove-Item Env:PHPVM_DIR -ErrorAction SilentlyContinue
    }

    Context 'Invoke-Composer' {
        AfterEach {
            Remove-Item "$PHPVM_BIN\composer.bat" -Force -ErrorAction SilentlyContinue
        }

        It 'Stops at the shim when Composer is already installed' {
            Mock -CommandName Get-PHPBuildInfo   -MockWith { $script:BuildInfo }
            Mock -CommandName Invoke-WebRequest  -MockWith { }
            Set-Content "$PHPVM_BIN\composer.bat" '@echo off'

            $out = Invoke-Composer 6>&1 | Out-String

            $out | Should -Match 'Composer already installed'
            $out | Should -Match 'follows your active PHP version'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'Leaves openssl alone when PHP already loads it' {
            Mock -CommandName Get-PHPBuildInfo   -MockWith { $script:BuildInfo }
            Mock -CommandName Edit-IniExtension  -MockWith { }
            Mock -CommandName Invoke-WebRequest  -MockWith { throw 'no network in tests' }

            $null = Invoke-Composer 6>&1

            Should -Invoke Edit-IniExtension -Times 0
        }

        It 'Enables openssl first when it is missing' {
            Mock -CommandName Get-PHPBuildInfo   -MockWith { $script:BuildInfo }
            Mock -CommandName Edit-IniExtension  -MockWith { }
            Mock -CommandName Invoke-WebRequest  -MockWith { throw 'no network in tests' }
            $script:PhpModules = @('Core', 'curl')

            $out = Invoke-Composer 6>&1 | Out-String

            $out | Should -Match 'Enabling openssl extension'
            Should -Invoke Edit-IniExtension -ParameterFilter { $extName -eq 'openssl' -and $enable -eq $true }

            $script:PhpModules = @('Core', 'curl', 'openssl')
        }

        It 'Reports a failed download instead of throwing' {
            Mock -CommandName Get-PHPBuildInfo  -MockWith { $script:BuildInfo }
            Mock -CommandName Invoke-WebRequest -MockWith { throw 'connection reset' }

            $out = Invoke-Composer 6>&1 | Out-String

            $out | Should -Match 'Download failed'
        }
    }

    Context 'Invoke-Cacert' {
        AfterEach {
            Remove-Item $PHPVM_CACERT -Force -ErrorAction SilentlyContinue
        }

        It 'Warns when no bundle has been fetched yet' {
            $out = Invoke-Cacert 'status' 6>&1 | Out-String
            $out | Should -Match 'No CA bundle yet'
        }

        It 'Treats an empty subcommand as status' {
            $out = Invoke-Cacert '' 6>&1 | Out-String
            $out | Should -Match 'No CA bundle yet'
        }

        It 'Reports the bundle path and its age' {
            Set-Content $PHPVM_CACERT '-----BEGIN CERTIFICATE-----'

            $out = Invoke-Cacert 'status' 6>&1 | Out-String

            $out | Should -Match 'CA bundle:'
            $out | Should -Match 'updated 0 day\(s\) ago'
            $out | Should -Match 'phpvm cacert update'
        }

        It 'Rewires the active php.ini on update' {
            New-Item -ItemType Directory -Path "$VERSIONS_DIR\8.3.10" -Force | Out-Null
            Set-Content "$VERSIONS_DIR\8.3.10\php.ini" ';curl.cainfo ='
            Mock -CommandName Get-CABundle      -MockWith { $PHPVM_CACERT }
            Mock -CommandName Get-CurrentVersion -MockWith { '8.3.10' }

            $out = Invoke-Cacert 'update' 6>&1 | Out-String

            $out | Should -Match 'Active php\.ini points at the refreshed bundle'
            Should -Invoke Get-CABundle -ParameterFilter { $Force -eq $true }
        }

        It 'Bails out quietly when the bundle cannot be fetched' {
            Mock -CommandName Get-CABundle       -MockWith { $null }
            Mock -CommandName Get-CurrentVersion -MockWith { '8.3.10' }

            $null = Invoke-Cacert 'update' 6>&1

            Should -Invoke Get-CurrentVersion -Times 0
        }

        It 'Prints usage for an unknown subcommand' {
            $out = Invoke-Cacert 'frobnicate' 6>&1 | Out-String
            $out | Should -Match 'Usage: phpvm cacert \[status\|update\]'
        }
    }

    Context 'Invoke-FixIni' {
        BeforeEach {
            Mock -CommandName Get-CurrentVersion -MockWith { '8.3.10' }
            # Keep the CA-bundle repair out of the network.
            Mock -CommandName Get-CABundle -MockWith { $null }
            New-Item -ItemType Directory -Path "$VERSIONS_DIR\8.3.10" -Force | Out-Null
        }

        It 'Errors when no version is active' {
            Mock -CommandName Get-CurrentVersion -MockWith { $null }

            $out = Invoke-FixIni 6>&1 | Out-String

            $out | Should -Match 'No active PHP version'
        }

        It 'Errors when php.ini is missing' {
            Remove-Item "$VERSIONS_DIR\8.3.10\php.ini" -Force -ErrorAction SilentlyContinue

            $out = Invoke-FixIni 6>&1 | Out-String

            $out | Should -Match 'php\.ini not found'
        }

        It 'Repoints a stale extension_dir at the active version' {
            Set-Content "$VERSIONS_DIR\8.3.10\php.ini" "extension_dir = `"C:\xampp\php\ext`"`nmemory_limit = 128M"

            $out = Invoke-FixIni 6>&1 | Out-String

            $out | Should -Match 'Fixed extension_dir'
            $ini = Get-Content "$VERSIONS_DIR\8.3.10\php.ini" -Raw
            $ini | Should -Match ([regex]::Escape("extension_dir = `"$VERSIONS_DIR\8.3.10\ext`""))
            $ini | Should -Match 'memory_limit = 128M'
        }

        It 'Uncomments a commented-out extension_dir' {
            Set-Content "$VERSIONS_DIR\8.3.10\php.ini" ';extension_dir = "ext"'

            $null = Invoke-FixIni 6>&1

            $ini = Get-Content "$VERSIONS_DIR\8.3.10\php.ini" -Raw
            $ini | Should -Not -Match '^;extension_dir'
            $ini | Should -Match ([regex]::Escape("$VERSIONS_DIR\8.3.10\ext"))
        }

        It 'Appends extension_dir when the directive is absent entirely' {
            Set-Content "$VERSIONS_DIR\8.3.10\php.ini" 'memory_limit = 128M'

            $out = Invoke-FixIni 6>&1 | Out-String

            $out | Should -Match 'Added extension_dir'
            (Get-Content "$VERSIONS_DIR\8.3.10\php.ini" -Raw) |
                Should -Match ([regex]::Escape("extension_dir = `"$VERSIONS_DIR\8.3.10\ext`""))
        }

        It 'Settles - a second run reports nothing left to change' {
            # First pass still rewrites: the (?m)$ match swallows the CR of a
            # CRLF ini, so the line differs by its line ending even when the
            # path is already right. It converges on the second pass.
            Set-Content "$VERSIONS_DIR\8.3.10\php.ini" "extension_dir = `"$VERSIONS_DIR\8.3.10\ext`""
            $null = Invoke-FixIni 6>&1

            $out = Invoke-FixIni 6>&1 | Out-String

            $out | Should -Match 'already correct or not found'
            $out | Should -Not -Match 'Added extension_dir'
        }
    }

    Context 'phpvm hook' {
        BeforeAll {
            $script:RealProfile = $PROFILE
            $script:FakeProfile = Join-Path $TestDrive 'profile\Microsoft.PowerShell_profile.ps1'
            New-Item -ItemType Directory -Path (Split-Path $script:FakeProfile) -Force | Out-Null
            $global:PROFILE = [PSCustomObject]@{ CurrentUserCurrentHost = $script:FakeProfile }
        }

        AfterAll { $global:PROFILE = $script:RealProfile }

        BeforeEach {
            Remove-Item $script:FakeProfile -Force -ErrorAction SilentlyContinue
        }

        It 'Reports "not installed" when there is no $PROFILE' {
            $out = Show-PHPVMHookStatus 6>&1 | Out-String
            $out | Should -Match 'hook not installed'
        }

        It 'Creates the profile and writes the hook' {
            $out = Install-PHPVMHook 6>&1 | Out-String

            $out | Should -Match 'Installed hook ->'
            (Get-Content $script:FakeProfile -Raw) | Should -Match 'phpvm-auto-hook'
        }

        It 'Emits a prompt hook that calls phpvm auto -Silent' {
            $snippet = Get-PHPVMHookSnippet

            $snippet | Should -Match 'function global:prompt'
            $snippet | Should -Match 'phpvm auto -Silent'
            # The PowerShell vars must survive as literals, not be interpolated
            # while the snippet is being built.
            $snippet | Should -Match '\$global:__phpvm_prev_prompt'
        }

        It 'Is idempotent - a second enable warns instead of duplicating' {
            $null = Install-PHPVMHook 6>&1
            $out  = Install-PHPVMHook 6>&1 | Out-String

            $out | Should -Match 'already installed'
            $hits = ([regex]::Matches((Get-Content $script:FakeProfile -Raw), 'phpvm-auto-hook')).Count
            $hits | Should -Be 1
        }

        It 'Reports installed once the hook is in place' {
            $null = Install-PHPVMHook 6>&1

            $out = Show-PHPVMHookStatus 6>&1 | Out-String

            $out | Should -Match 'Hook installed in'
        }

        It 'Strips the hook back out and keeps surrounding content' {
            Set-Content $script:FakeProfile "Set-Alias ll Get-ChildItem"
            $null = Install-PHPVMHook 6>&1

            $out = Uninstall-PHPVMHook 6>&1 | Out-String

            $out | Should -Match 'Removed hook from'
            $content = Get-Content $script:FakeProfile -Raw
            $content | Should -Not -Match 'phpvm-auto-hook'
            $content | Should -Match 'Set-Alias ll Get-ChildItem'
        }

        It 'Warns when disabling a hook that was never installed' {
            Set-Content $script:FakeProfile "Set-Alias ll Get-ChildItem"

            $out = Uninstall-PHPVMHook 6>&1 | Out-String

            $out | Should -Match 'hook not found'
        }

        It 'Warns when disabling with no $PROFILE at all' {
            $out = Uninstall-PHPVMHook 6>&1 | Out-String
            $out | Should -Match 'No \$PROFILE found'
        }

        Context 'Invoke-Hook dispatch' {
            BeforeEach {
                Mock -CommandName Install-PHPVMHook   -MockWith { }
                Mock -CommandName Uninstall-PHPVMHook -MockWith { }
                Mock -CommandName Show-PHPVMHookStatus -MockWith { }
            }

            It 'Routes enable / disable / status' {
                Invoke-Hook 'enable'
                Invoke-Hook 'disable'
                Invoke-Hook 'status'

                Should -Invoke Install-PHPVMHook    -Times 1
                Should -Invoke Uninstall-PHPVMHook  -Times 1
                Should -Invoke Show-PHPVMHookStatus -Times 1
            }

            It 'Is case-insensitive' {
                Invoke-Hook 'ENABLE'
                Should -Invoke Install-PHPVMHook -Times 1
            }

            It 'Shows usage for anything else' {
                $out = Invoke-Hook 'frobnicate' 6>&1 | Out-String

                $out | Should -Match 'phpvm hook enable'
                $out | Should -Match 'phpvm hook disable'
                $out | Should -Match 'phpvm hook status'
                Should -Invoke Install-PHPVMHook -Times 0
            }
        }
    }

    Context 'Invoke-Upgrade' {
        It 'Reports up to date when the remote version is not newer' {
            Mock -CommandName Get-WebString     -MockWith { '0.0.1' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $out = Invoke-Upgrade 6>&1 | Out-String

            $out | Should -Match 'Already up to date'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'Reports an unreachable GitHub instead of throwing' {
            Mock -CommandName Get-WebString     -MockWith { throw 'dns failure' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $out = Invoke-Upgrade 6>&1 | Out-String

            $out | Should -Match 'Could not reach GitHub'
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }
}
