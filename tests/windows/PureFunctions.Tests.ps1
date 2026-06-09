Describe 'Get-VSVersion' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Maps PHP 7.x to vc15' {
        Get-VSVersion '7.4.33' | Should -Be 'vc15'
        Get-VSVersion '7.0.0'  | Should -Be 'vc15'
    }

    It 'Maps PHP 8.0 - 8.3 to vs16' {
        Get-VSVersion '8.0.30' | Should -Be 'vs16'
        Get-VSVersion '8.1.34' | Should -Be 'vs16'
        Get-VSVersion '8.2.30' | Should -Be 'vs16'
        Get-VSVersion '8.3.29' | Should -Be 'vs16'
    }

    It 'Maps PHP 8.4+ to vs17' {
        Get-VSVersion '8.4.16' | Should -Be 'vs17'
        Get-VSVersion '8.5.1'  | Should -Be 'vs17'
    }

    It 'Defaults to vs17 for future majors' {
        Get-VSVersion '9.0.0' | Should -Be 'vs17'
    }
}

Describe 'Get-WebString' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Returns string content as-is' {
        Mock -CommandName Invoke-WebRequest -MockWith {
            [pscustomobject]@{ Content = "1.4.6`n" }
        }
        Get-WebString 'https://example.test/version.txt' | Should -Be "1.4.6`n"
    }

    It 'Decodes byte[] content as UTF-8' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("hash-abc-123")
        Mock -CommandName Invoke-WebRequest -MockWith {
            [pscustomobject]@{ Content = $bytes }
        }
        Get-WebString 'https://example.test/installer.sig' | Should -Be 'hash-abc-123'
    }
}

Describe 'Resolve-LatestPatch' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Picks the highest patch from a release index' {
        Mock -CommandName Get-WebString -MockWith {
            @'
<a href="php-8.3.10-Win32-vs16-x64.zip">...</a>
<a href="php-8.3.29-Win32-vs16-x64.zip">...</a>
<a href="php-8.3.5-nts-Win32-vs16-x64.zip">...</a>
<a href="php-8.4.0-Win32-vs17-x64.zip">...</a>
'@
        }
        Resolve-LatestPatch '8.3' | Should -Be '8.3.29'
    }

    It 'Returns $null when no patches match' {
        Mock -CommandName Get-WebString -MockWith { '<html>empty</html>' }
        Resolve-LatestPatch '8.9' | Should -BeNullOrEmpty
    }

    It 'Matches uppercase VC15 used by PHP 7.x archives' {
        Mock -CommandName Get-WebString -MockWith {
            @'
<a href="php-7.3.0-Win32-VC15-x64.zip">...</a>
<a href="php-7.3.33-Win32-VC15-x64.zip">...</a>
<a href="php-7.3.33-nts-Win32-VC15-x64.zip">...</a>
'@
        }
        Resolve-LatestPatch '7.3' | Should -Be '7.3.33'
    }
}

Describe 'Get-PHPZipHash' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Returns lowercase hex digest for a known zip' {
        $hash = 'a' * 64
        Mock -CommandName Get-WebString -MockWith {
            "$hash  php-8.3.29-Win32-vs16-x64.zip`nffffffff  other.zip"
        }
        Get-PHPZipHash 'https://windows.php.net/downloads/releases/php-8.3.29-Win32-vs16-x64.zip' | Should -Be $hash
    }

    It 'Accepts the binary-mode asterisk prefix on filename' {
        $hash = 'b' * 64
        Mock -CommandName Get-WebString -MockWith {
            "$hash *php-8.3.29-Win32-vs16-x64.zip"
        }
        Get-PHPZipHash 'https://windows.php.net/downloads/releases/php-8.3.29-Win32-vs16-x64.zip' | Should -Be $hash
    }

    It 'Returns $null when checksum is missing for the file' {
        Mock -CommandName Get-WebString -MockWith {
            "$('c' * 64)  some-other-build.zip"
        }
        Get-PHPZipHash 'https://windows.php.net/downloads/releases/php-8.3.29-Win32-vs16-x64.zip' | Should -BeNullOrEmpty
    }

    It 'Returns $null when sha256sum.txt cannot be fetched' {
        Mock -CommandName Get-WebString -MockWith { throw '404' }
        Get-PHPZipHash 'https://windows.php.net/downloads/releases/php-8.3.29-Win32-vs16-x64.zip' | Should -BeNullOrEmpty
    }
}

Describe 'Get-XDebugHash' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Extracts the digest from a sibling .sha256 file' {
        $hash = 'd' * 64
        Mock -CommandName Get-WebString -MockWith { "$hash  php_xdebug-3.4.0-8.3-vs16-x86_64.dll`n" }
        Get-XDebugHash 'https://xdebug.org/files/php_xdebug-3.4.0-8.3-vs16-x86_64.dll' | Should -Be $hash
    }

    It 'Returns $null when .sha256 cannot be fetched' {
        Mock -CommandName Get-WebString -MockWith { throw 'not found' }
        Get-XDebugHash 'https://xdebug.org/files/php_xdebug-3.4.0-8.3-vs16-x86_64.dll' | Should -BeNullOrEmpty
    }
}

Describe 'Edit-IniExtension regex behaviour' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Enables a commented-out extension by stripping the leading semicolon' {
        $tmpDir = New-Item -ItemType Directory -Path "$env:TEMP\phpvm-tests-$([guid]::NewGuid())" -Force
        $iniFile = Join-Path $tmpDir 'php.ini'
        $extDir  = Join-Path $tmpDir 'ext'
        New-Item -ItemType Directory -Path $extDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $extDir 'php_curl.dll') -Force | Out-Null

        @'
;extension=php_curl.dll
extension=mbstring
'@ | Set-Content $iniFile

        Mock -CommandName Get-PHPBuildInfo -MockWith {
            @{ ExtDir = $extDir; IniPath = $iniFile }
        }

        Edit-IniExtension 'curl' $true

        $after = Get-Content $iniFile -Raw
        $after | Should -Match '(?m)^extension\s*=\s*(?:php_)?curl(?:\.dll)?\s*$'
        $after | Should -Not -Match '(?m)^;\s*extension\s*=\s*(?:php_)?curl'

        Remove-Item $tmpDir -Recurse -Force
    }

    It 'Disables an enabled extension by commenting it out' {
        $tmpDir = New-Item -ItemType Directory -Path "$env:TEMP\phpvm-tests-$([guid]::NewGuid())" -Force
        $iniFile = Join-Path $tmpDir 'php.ini'
        $extDir  = Join-Path $tmpDir 'ext'
        New-Item -ItemType Directory -Path $extDir -Force | Out-Null

        'extension=curl' | Set-Content $iniFile

        Mock -CommandName Get-PHPBuildInfo -MockWith {
            @{ ExtDir = $extDir; IniPath = $iniFile }
        }

        Edit-IniExtension 'curl' $false

        (Get-Content $iniFile -Raw) | Should -Match '(?m)^;extension\s*=\s*curl\s*$'

        Remove-Item $tmpDir -Recurse -Force
    }
}
