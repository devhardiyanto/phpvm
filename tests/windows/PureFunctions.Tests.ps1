Describe 'Get-VSVersion' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Maps PHP 5.x to vc11' {
        Get-VSVersion '5.6.40' | Should -Be 'vc11'
    }

    It 'Maps PHP 7.0 / 7.1 to vc14' {
        Get-VSVersion '7.0.33' | Should -Be 'vc14'
        Get-VSVersion '7.1.33' | Should -Be 'vc14'
    }

    It 'Maps PHP 7.2 - 7.4 to vc15' {
        Get-VSVersion '7.2.34' | Should -Be 'vc15'
        Get-VSVersion '7.4.33' | Should -Be 'vc15'
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

    It 'Does not throw on non-version input (StrictMode guard)' {
        Get-VSVersion ''         | Should -Be 'vs17'
        Get-VSVersion 'composer' | Should -Be 'vs17'
        Get-VSVersion '8'        | Should -Be 'vs17'
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

    It 'Resolves a bare major to the highest overall patch' {
        Mock -CommandName Get-WebString -MockWith {
            @'
<a href="php-8.3.31-Win32-vs16-x64.zip">...</a>
<a href="php-8.4.22-Win32-vs17-x64.zip">...</a>
<a href="php-8.5.7-Win32-vs17-x64.zip">...</a>
'@
        }
        Resolve-LatestPatch '8' | Should -Be '8.5.7'
    }

    It 'Does not let 8.3 match 8.30.x' {
        Mock -CommandName Get-WebString -MockWith {
            @'
<a href="php-8.3.5-Win32-vs16-x64.zip">...</a>
<a href="php-8.30.1-Win32-vs16-x64.zip">...</a>
'@
        }
        Resolve-LatestPatch '8.3' | Should -Be '8.3.5'
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

    It 'Matches VC14 (PHP 7.0 / 7.1) and VC11 (PHP 5.x) archives' {
        Mock -CommandName Get-WebString -MockWith {
            @'
<a href="php-7.0.0-Win32-VC14-x64.zip">...</a>
<a href="php-7.0.33-Win32-VC14-x64.zip">...</a>
<a href="php-5.6.40-Win32-VC11-x64.zip">...</a>
'@
        }
        Resolve-LatestPatch '7.0' | Should -Be '7.0.33'
        Resolve-LatestPatch '5.6' | Should -Be '5.6.40'
    }
}

Describe 'Get-Levenshtein' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Returns 0 for identical strings' {
        Get-Levenshtein 'install' 'install' | Should -Be 0
    }

    It 'Counts single-edit typos' {
        Get-Levenshtein 'intsall' 'install' | Should -Be 2
        Get-Levenshtein 'usee'    'use'     | Should -Be 1
    }

    It 'Equals the other length when one string is empty' {
        Get-Levenshtein '' 'list' | Should -Be 4
        Get-Levenshtein 'list' '' | Should -Be 4
    }
}

Describe 'Invoke-Unknown' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Suggests the nearest command for a close typo' {
        $out = Invoke-Unknown 'intsall' 6>&1 | Out-String
        $out | Should -Match "is not a phpvm command"
        $out | Should -Match "Did you mean 'install'\?"
    }

    It 'Omits a suggestion when nothing is close' {
        $out = Invoke-Unknown 'zzzzzz' 6>&1 | Out-String
        $out | Should -Match "is not a phpvm command"
        $out | Should -Not -Match "Did you mean"
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
