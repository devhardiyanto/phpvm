Describe 'Ext subsystem' {
    BeforeAll {
        $env:PHPVM_DIR = Join-Path $TestDrive '.phpvm'
        New-Item -ItemType Directory -Path $env:PHPVM_DIR -Force | Out-Null
        . $PSScriptRoot/Common.ps1

        # Fake ext/ dir: the DLLs phpvm sees when it scans a PHP build.
        $script:ExtDir = Join-Path $TestDrive 'php\ext'
        New-Item -ItemType Directory -Path $script:ExtDir -Force | Out-Null
        foreach ($n in 'curl', 'gd', 'mbstring') {
            Set-Content (Join-Path $script:ExtDir "php_$n.dll") 'stub'
        }

        # `& $info.Exe -m` resolves Exe as a command name, so a function named
        # 'php' stands in for the real binary. Global so it is visible from the
        # dot-sourced phpvm.ps1 functions.
        $script:PhpModules = @('[PHP Modules]', 'Core', 'curl', 'mbstring', '[Zend Modules]')
        function global:php {
            $script:PhpArgs = $args
            if ($args -contains '-m') { return $script:PhpModules }
            return @()
        }

        $script:BuildInfo = @{
            Version = '8.3.10'
            Short   = '8.3'
            TS      = 'nts'
            VS      = 'vs16'
            Arch    = 'x64'
            Exe     = 'php'
            Root    = (Join-Path $TestDrive 'php')
            ExtDir  = $script:ExtDir
            IniPath = (Join-Path $TestDrive 'php\php.ini')
        }
    }

    AfterAll {
        Remove-Item Function:\php -ErrorAction SilentlyContinue
        Remove-Item Env:PHPVM_DIR -ErrorAction SilentlyContinue
    }

    Context 'Ext-List' {
        It 'Marks a loaded DLL [ON] and an unloaded one [off]' {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }

            $out = Ext-List 6>&1 | Out-String

            $out | Should -Match 'curl\s+\[ON\]'
            $out | Should -Match 'gd\s+\[off\]'
            $out | Should -Match 'mbstring\s+\[ON\]'
        }

        It 'Shows the build header and ini path' {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }

            $out = Ext-List 6>&1 | Out-String

            $out | Should -Match 'PHP 8\.3\.10 \[NTS / vs16 / x64\]'
            $out | Should -Match 'php\.ini :'
        }

        It 'Warns instead of throwing when ext/ is missing' {
            $missing = $script:BuildInfo.Clone()
            $missing.ExtDir = Join-Path $TestDrive 'nope\ext'
            Mock -CommandName Get-PHPBuildInfo -MockWith { $missing }

            $out = Ext-List 6>&1 | Out-String

            $out | Should -Match 'ext/ directory not found'
        }
    }

    Context 'Ext-Loaded' {
        It 'Lists modules and drops the [PHP Modules] section headers' {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }

            $out = Ext-Loaded 6>&1 | Out-String

            $out | Should -Match 'Loaded extensions - PHP 8\.3\.10'
            $out | Should -Match 'curl'
            $out | Should -Not -Match '\[PHP Modules\]'
            $out | Should -Not -Match '\[Zend Modules\]'
        }
    }

    Context 'Ext-Info' {
        It 'Emits PHP source, not PowerShell-interpolated garbage' {
            # Regression lock: $r / $classes must reach PHP as literals. Asserting
            # on the function body keeps this honest without a real php.exe.
            $body = (Get-Command Ext-Info).ScriptBlock.ToString()

            $body | Should -Match '\$r = new ReflectionExtension'
            $body | Should -Match '\$r->getName\(\)'
            $body | Should -Match '\$classes'
        }

        It 'Passes the extension name into extension_loaded()' {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }

            $null = Ext-Info 'curl' 6>&1

            ($script:PhpArgs -join ' ') | Should -Match "extension_loaded\('curl'\)"
        }
    }

    Context 'Get-PECLVersions' {
        It 'Parses the release index newest-first' {
            Mock -CommandName Get-WebString -MockWith {
                '<a href="1.2.0/">1.2.0/</a><a href="10.0.1/">10.0.1/</a><a href="2.5.0/">2.5.0/</a>'
            }

            $v = Get-PECLVersions 'redis'

            $v[0] | Should -Be '10.0.1'
            $v[1] | Should -Be '2.5.0'
            $v[2] | Should -Be '1.2.0'
        }

        It 'Returns nothing when the fetch fails' {
            Mock -CommandName Get-WebString -MockWith { throw 'offline' }

            Get-PECLVersions 'nope' | Should -BeNullOrEmpty
        }
    }

    Context 'Install-PECLExt guard' {
        It 'Stops early when the DLL is already present' {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }
            Mock -CommandName Get-PECLVersions -MockWith { @('1.0.0') }

            $out = Install-PECLExt 'curl' 6>&1 | Out-String

            $out | Should -Match 'php_curl\.dll already installed'
            Should -Invoke Get-PECLVersions -Times 0
        }

        It 'Reports an unknown extension instead of downloading' {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }
            Mock -CommandName Get-PECLVersions -MockWith { @() }
            Mock -CommandName Test-URLExists -MockWith { $true }

            $out = Install-PECLExt 'definitely-not-real' 6>&1 | Out-String

            $out | Should -Match "not found on windows\.php\.net"
            Should -Invoke Test-URLExists -Times 0
        }
    }

    Context 'Show-ExtRuntimeNotes' {
        It 'Advises the ODBC driver for sqlsrv' {
            $out = Show-ExtRuntimeNotes 'pdo_sqlsrv' 6>&1 | Out-String
            $out | Should -Match 'ODBC Driver'
        }

        It 'Stays silent for an ordinary extension' {
            $out = Show-ExtRuntimeNotes 'redis' 6>&1 | Out-String
            $out.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'Ext-Laravel preset composition' {
        BeforeEach {
            Mock -CommandName Get-PHPBuildInfo -MockWith { $script:BuildInfo }
            Mock -CommandName Edit-IniExtension -MockWith { }
            Mock -CommandName Install-PECLExt -MockWith { }
        }

        It 'minimal enables bundled DLLs present in the build only' {
            # ext/ holds curl, gd, mbstring. Of those, minimal covers curl+mbstring.
            $null = Ext-Laravel 'minimal' 6>&1

            Should -Invoke Edit-IniExtension -Times 0 -ParameterFilter { $extName -eq 'gd' }
            Should -Invoke Install-PECLExt -Times 0
        }

        It 'minimal skips extensions whose DLL is absent' {
            $out = Ext-Laravel 'minimal' 6>&1 | Out-String

            $out | Should -Match 'skip\s+openssl'
            $out | Should -Match 'Laravel extension setup \(minimal\)'
        }

        It 'minimal points at the full preset in the closing hint' {
            $out = Ext-Laravel 'minimal' 6>&1 | Out-String
            $out | Should -Match 'phpvm ext laravel full'
        }

        It 'full adds gd and installs the redis PECL package' {
            $out = Ext-Laravel 'full' 6>&1 | Out-String

            $out | Should -Match 'Laravel extension setup \(full\)'
            Should -Invoke Edit-IniExtension -ParameterFilter { $extName -eq 'gd' }
            Should -Invoke Install-PECLExt -ParameterFilter { $extName -eq 'redis' }
        }

        It 'Reports already-ON for an extension PHP already loaded' {
            $out = Ext-Laravel 'full' 6>&1 | Out-String

            $out | Should -Match 'curl\s+already ON'
            Should -Invoke Edit-IniExtension -Times 0 -ParameterFilter { $extName -eq 'curl' }
        }

        It 'Defaults to the full preset when no argument is given' {
            $out = Ext-Laravel 6>&1 | Out-String
            $out | Should -Match 'Laravel extension setup \(full\)'
        }
    }

    Context 'Invoke-Ext dispatch' {
        BeforeEach {
            Mock -CommandName Ext-List          -MockWith { }
            Mock -CommandName Ext-Loaded        -MockWith { }
            Mock -CommandName Ext-Info          -MockWith { }
            Mock -CommandName Ext-Laravel       -MockWith { }
            Mock -CommandName Edit-IniExtension -MockWith { }
            Mock -CommandName Install-PECLExt   -MockWith { }
            Mock -CommandName Install-XDebug    -MockWith { }
            Mock -CommandName Show-ExtHelp      -MockWith { }
        }

        It 'Routes list and its ls alias' {
            Invoke-Ext 'list'  '' ''
            Invoke-Ext 'ls'    '' ''
            Should -Invoke Ext-List -Times 2
        }

        It 'Routes loaded' {
            Invoke-Ext 'loaded' '' ''
            Should -Invoke Ext-Loaded -Times 1
        }

        It 'Routes enable/disable with the right toggle' {
            Invoke-Ext 'enable'  'curl' ''
            Invoke-Ext 'disable' 'curl' ''
            Should -Invoke Edit-IniExtension -ParameterFilter { $enable -eq $true }
            Should -Invoke Edit-IniExtension -ParameterFilter { $enable -eq $false }
        }

        It 'Sends install xdebug to the dedicated installer' {
            Invoke-Ext 'install' 'XDebug' ''
            Should -Invoke Install-XDebug -Times 1
            Should -Invoke Install-PECLExt -Times 0
        }

        It 'Sends any other install to PECL, passing the version through' {
            Invoke-Ext 'install' 'redis' '6.0.2'
            Should -Invoke Install-PECLExt -ParameterFilter { $extName -eq 'redis' -and $requestedVer -eq '6.0.2' }
        }

        It 'Routes info and laravel' {
            Invoke-Ext 'info'    'curl'    ''
            Invoke-Ext 'laravel' 'minimal' ''
            Should -Invoke Ext-Info    -ParameterFilter { $extName -eq 'curl' }
            Should -Invoke Ext-Laravel -ParameterFilter { $preset -eq 'minimal' }
        }

        It 'Is case-insensitive on the subcommand' {
            Invoke-Ext 'LIST' '' ''
            Should -Invoke Ext-List -Times 1
        }

        It 'Falls back to help for an unknown subcommand' {
            Invoke-Ext 'frobnicate' '' ''
            Should -Invoke Show-ExtHelp -Times 1
        }

        It 'Errors on usage when a name-taking subcommand gets no name' {
            $out = & {
                Invoke-Ext 'enable'  '' ''
                Invoke-Ext 'disable' '' ''
                Invoke-Ext 'install' '' ''
                Invoke-Ext 'info'    '' ''
            } 6>&1 | Out-String

            $out | Should -Match 'Usage: phpvm ext enable <name>'
            $out | Should -Match 'Usage: phpvm ext disable <name>'
            $out | Should -Match 'Usage: phpvm ext install <name>'
            $out | Should -Match 'Usage: phpvm ext info <name>'
            Should -Invoke Edit-IniExtension -Times 0
            Should -Invoke Install-PECLExt -Times 0
        }
    }
}
