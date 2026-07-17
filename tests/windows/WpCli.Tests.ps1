Describe 'Invoke-WpCli' {
    BeforeAll {
        $env:PHPVM_DIR = Join-Path $TestDrive '.phpvm'
        New-Item -ItemType Directory -Path $env:PHPVM_DIR -Force | Out-Null
        . $PSScriptRoot/Common.ps1

        # Test double for php.exe: any invocation prints $env:FAKE_PHP_HASH,
        # standing in for hash_file('sha512', ...).
        $script:FakePhp = Join-Path $TestDrive 'php.bat'
        "@echo off`r`necho:%FAKE_PHP_HASH%" | Set-Content $FakePhp -Encoding ASCII
    }

    AfterAll {
        Remove-Item Env:PHPVM_DIR       -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_PHP_HASH   -ErrorAction SilentlyContinue
        Remove-Item Env:PHPVM_SKIP_HASH -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $env:FAKE_PHP_HASH = 'cafe123'
        Remove-Item Env:PHPVM_SKIP_HASH -ErrorAction SilentlyContinue
        Remove-Item "$PHPVM_DIR\wp-cli.phar", "$PHPVM_BIN\wp.bat" -Force -ErrorAction SilentlyContinue

        Mock -CommandName Get-PHPBuildInfo -MockWith { @{ Exe = $FakePhp } }
        Mock -CommandName Invoke-WebRequest -MockWith { 'fake phar' | Set-Content $OutFile }
        Mock -CommandName Get-WebString -MockWith { "$env:FAKE_PHP_HASH  wp-cli.phar" }
        Mock -CommandName Write-Err  -MockWith {}
        Mock -CommandName Write-Warn -MockWith {}
    }

    It 'Downloads the phar, verifies the hash, and writes the wp.bat shim' {
        Invoke-WpCli

        Test-Path "$PHPVM_DIR\wp-cli.phar" | Should -BeTrue
        Test-Path "$PHPVM_BIN\wp.bat"      | Should -BeTrue
        Get-Content "$PHPVM_BIN\wp.bat" -Raw | Should -Match ([regex]::Escape("$PHPVM_DIR\wp-cli.phar"))
        Should -Invoke Get-WebString -Times 1
        Should -Invoke Write-Err -Times 0
    }

    It 'Is a no-op when the shim already exists' {
        New-Item -ItemType Directory -Path $PHPVM_BIN -Force | Out-Null
        '@echo off' | Set-Content "$PHPVM_BIN\wp.bat"

        Invoke-WpCli

        Should -Invoke Write-Warn -Times 1 -ParameterFilter { $m -like '*already installed*' }
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'Removes the phar and writes no shim on hash mismatch' {
        Mock -CommandName Get-WebString -MockWith { 'deadbeef  wp-cli.phar' }

        Invoke-WpCli

        Should -Invoke Write-Err -Times 1 -ParameterFilter { $m -like 'SHA-512 mismatch*' }
        Test-Path "$PHPVM_DIR\wp-cli.phar" | Should -BeFalse
        Test-Path "$PHPVM_BIN\wp.bat"      | Should -BeFalse
    }

    It 'Skips verification when PHPVM_SKIP_HASH is set' {
        $env:PHPVM_SKIP_HASH = '1'

        Invoke-WpCli

        Should -Invoke Get-WebString -Times 0
        Test-Path "$PHPVM_BIN\wp.bat" | Should -BeTrue
    }
}
