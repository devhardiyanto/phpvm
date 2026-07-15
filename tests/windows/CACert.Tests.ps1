Describe 'Set-IniCACert' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
        $script:Bundle = 'C:\Users\test\.phpvm\cacert.pem'
    }

    It 'Uncomments and points both directives at the bundle' {
        $ini = @"
[curl]
;curl.cainfo =

[openssl]
;openssl.cafile=
"@
        $out = Set-IniCACert $ini $Bundle
        $out | Should -Match ([regex]::Escape("curl.cainfo = `"$Bundle`""))
        $out | Should -Match ([regex]::Escape("openssl.cafile = `"$Bundle`""))
        $out | Should -Not -Match '(?m)^;+\s*curl\.cainfo'
    }

    It 'Overwrites directives that already have a value' {
        $ini = "curl.cainfo = `"D:\old\ca.pem`"`r`nopenssl.cafile = `"D:\old\ca.pem`""
        $out = Set-IniCACert $ini $Bundle
        $out | Should -Not -Match ([regex]::Escape('D:\old\ca.pem'))
        $out | Should -Match ([regex]::Escape("curl.cainfo = `"$Bundle`""))
    }

    It 'Appends both directives when absent' {
        $out = Set-IniCACert "memory_limit = 128M" $Bundle
        $out | Should -Match ([regex]::Escape("curl.cainfo = `"$Bundle`""))
        $out | Should -Match ([regex]::Escape("openssl.cafile = `"$Bundle`""))
    }

    It 'Is idempotent' {
        $once  = Set-IniCACert ";curl.cainfo =`r`n;openssl.cafile =" $Bundle
        $twice = Set-IniCACert $once $Bundle
        $twice | Should -Be $once
    }

    It 'Does not touch unrelated lines' {
        $ini = "extension_dir = `"C:\php\ext`"`r`n;curl.cainfo ="
        $out = Set-IniCACert $ini $Bundle
        $out | Should -Match ([regex]::Escape("extension_dir = `"C:\php\ext`""))
    }
}

Describe 'Update-IniCACert' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Patches a php.ini file on disk' {
        $ini = Join-Path $TestDrive 'php.ini'
        ";curl.cainfo =`r`n;openssl.cafile =" | Set-Content $ini -NoNewline
        Update-IniCACert $ini 'C:\bundle\cacert.pem' | Should -BeTrue
        Get-Content $ini -Raw | Should -Match ([regex]::Escape('curl.cainfo = "C:\bundle\cacert.pem"'))
    }

    It 'Returns $false when php.ini is missing' {
        Update-IniCACert (Join-Path $TestDrive 'nope.ini') 'C:\bundle\cacert.pem' | Should -BeFalse
    }

    It 'Returns $false when bundle path is empty' {
        $ini = Join-Path $TestDrive 'php2.ini'
        'x = 1' | Set-Content $ini
        Update-IniCACert $ini '' | Should -BeFalse
    }
}

Describe 'Get-CABundle' {
    BeforeAll {
        $env:PHPVM_DIR = Join-Path $TestDrive '.phpvm'
        New-Item -ItemType Directory -Path $env:PHPVM_DIR -Force | Out-Null
        . $PSScriptRoot/Common.ps1
    }

    AfterAll {
        Remove-Item Env:PHPVM_DIR -ErrorAction SilentlyContinue
    }

    It 'Returns the existing bundle without downloading' {
        '-----BEGIN CERTIFICATE-----' | Set-Content $PHPVM_CACERT
        Mock -CommandName Invoke-Download -MockWith { throw 'should not be called' }
        Get-CABundle | Should -Be $PHPVM_CACERT
        Remove-Item $PHPVM_CACERT -Force
    }

    It 'Downloads and keeps a valid PEM bundle' {
        Mock -CommandName Invoke-Download -MockWith {
            param($url, $dest)
            "-----BEGIN CERTIFICATE-----`nMIIB...`n-----END CERTIFICATE-----" | Set-Content $dest
        }
        Get-CABundle | Should -Be $PHPVM_CACERT
        Test-Path $PHPVM_CACERT | Should -BeTrue
        Remove-Item $PHPVM_CACERT -Force
    }

    It 'Rejects a payload that is not a PEM bundle and returns $null' {
        Mock -CommandName Invoke-Download -MockWith {
            param($url, $dest)
            '<html>proxy login</html>' | Set-Content $dest
        }
        Get-CABundle 3> $null | Should -BeNullOrEmpty
        Test-Path $PHPVM_CACERT | Should -BeFalse
    }
}
