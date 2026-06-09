Describe 'Find-PHPVMRC' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Returns $null when no .phpvmrc exists in the chain' {
        $leaf = Join-Path $TestDrive 'a/b/c'
        New-Item -ItemType Directory -Path $leaf -Force | Out-Null
        Find-PHPVMRC -startDir $leaf | Should -BeNullOrEmpty
    }

    It 'Finds .phpvmrc in the current directory' {
        $dir = Join-Path $TestDrive 'p1'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '8.3.0' | Set-Content (Join-Path $dir '.phpvmrc')
        $found = Find-PHPVMRC -startDir $dir
        $found | Should -Be (Resolve-Path (Join-Path $dir '.phpvmrc')).Path
    }

    It 'Walks up to find .phpvmrc in a parent directory' {
        $root = Join-Path $TestDrive 'proj'
        $deep = Join-Path $root 'src/api/controllers'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        '7.4' | Set-Content (Join-Path $root '.phpvmrc')
        $found = Find-PHPVMRC -startDir $deep
        $found | Should -Be (Resolve-Path (Join-Path $root '.phpvmrc')).Path
    }

    It 'Innermost .phpvmrc wins over an outer one' {
        $outer = Join-Path $TestDrive 'workspace'
        $inner = Join-Path $outer 'subproj/src'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        '8.3' | Set-Content (Join-Path $outer '.phpvmrc')
        '7.4' | Set-Content (Join-Path (Split-Path $inner -Parent) '.phpvmrc')
        $found = Find-PHPVMRC -startDir $inner
        $found | Should -Be (Resolve-Path (Join-Path (Split-Path $inner -Parent) '.phpvmrc')).Path
    }
}

Describe 'Read-PHPVMRC' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1
    }

    It 'Reads a plain version string' {
        $f = Join-Path $TestDrive 'rc1'
        '8.3.0' | Set-Content $f
        Read-PHPVMRC $f | Should -Be '8.3.0'
    }

    It 'Trims whitespace' {
        $f = Join-Path $TestDrive 'rc2'
        '  8.3.0  ' | Set-Content $f
        Read-PHPVMRC $f | Should -Be '8.3.0'
    }

    It 'Skips comment lines and takes the first real version' {
        $f = Join-Path $TestDrive 'rc3'
        @('# project: api', '# php 8.3 required', '8.3.0') | Set-Content $f
        Read-PHPVMRC $f | Should -Be '8.3.0'
    }

    It 'Strips inline comments' {
        $f = Join-Path $TestDrive 'rc4'
        '8.3.0  # locked for deployment' | Set-Content $f
        Read-PHPVMRC $f | Should -Be '8.3.0'
    }

    It 'Strips a leading v prefix' {
        $f = Join-Path $TestDrive 'rc5'
        'v8.3.0' | Set-Content $f
        Read-PHPVMRC $f | Should -Be '8.3.0'
    }

    It 'Returns $null for an empty / comment-only file' {
        $f = Join-Path $TestDrive 'rc6'
        @('# only a comment', '') | Set-Content $f
        Read-PHPVMRC $f | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-RCVersion + Invoke-Auto' {
    BeforeAll {
        . $PSScriptRoot/Common.ps1

        # Build a fake $VERSIONS_DIR with three installed versions.
        $fakeRoot = Join-Path $TestDrive 'phpvm-home'
        $fakeVersions = Join-Path $fakeRoot 'versions'
        foreach ($v in '7.4.33','8.3.0','8.3.29') {
            $dir = Join-Path $fakeVersions $v
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir 'php.exe') -Force | Out-Null
        }
        # Reassign $VERSIONS_DIR; functions read it dynamically.
        $VERSIONS_DIR = $fakeVersions
    }

    Context 'Resolve-RCVersion' {
        It 'Passes through a fully-installed version' {
            Resolve-RCVersion '8.3.0' | Should -Be '8.3.0'
        }

        It 'Resolves a partial version to the highest installed patch' {
            Resolve-RCVersion '8.3' | Should -Be '8.3.29'
        }

        It 'Returns $null when nothing matches' {
            Resolve-RCVersion '5.6' | Should -BeNullOrEmpty
        }

        It 'Returns $null for a full semver that is not installed' {
            Resolve-RCVersion '8.3.99' | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-Auto' {
        BeforeEach {
            $env:PHPVM_AUTO_ACTIVE = ''
            $script:OriginalPath = $env:PATH
        }

        AfterEach {
            $env:PATH = $script:OriginalPath
            $env:PHPVM_AUTO_ACTIVE = ''
        }

        It 'Prepends the resolved version directory to $env:PATH' {
            $proj = Join-Path $TestDrive 'inv-auto-1'
            New-Item -ItemType Directory -Path $proj -Force | Out-Null
            '8.3' | Set-Content (Join-Path $proj '.phpvmrc')

            Push-Location $proj
            try { Invoke-Auto -Silent } finally { Pop-Location }

            $env:PHPVM_AUTO_ACTIVE | Should -Be '8.3.29'
            $env:PATH | Should -BeLike "$VERSIONS_DIR\8.3.29;*"
        }

        It 'Is a no-op when the active version already matches' {
            $proj = Join-Path $TestDrive 'inv-auto-2'
            New-Item -ItemType Directory -Path $proj -Force | Out-Null
            '7.4.33' | Set-Content (Join-Path $proj '.phpvmrc')

            Push-Location $proj
            try {
                Invoke-Auto -Silent
                $afterFirst = $env:PATH
                Invoke-Auto -Silent
                $env:PATH | Should -Be $afterFirst
            } finally { Pop-Location }
        }

        It 'Removes the previous prepend when switching projects' {
            $a = Join-Path $TestDrive 'inv-auto-3a'
            $b = Join-Path $TestDrive 'inv-auto-3b'
            New-Item -ItemType Directory -Path $a -Force | Out-Null
            New-Item -ItemType Directory -Path $b -Force | Out-Null
            '7.4.33' | Set-Content (Join-Path $a '.phpvmrc')
            '8.3.0'  | Set-Content (Join-Path $b '.phpvmrc')

            Push-Location $a
            try { Invoke-Auto -Silent } finally { Pop-Location }
            Push-Location $b
            try { Invoke-Auto -Silent } finally { Pop-Location }

            $env:PHPVM_AUTO_ACTIVE | Should -Be '8.3.0'
            ($env:PATH -split ';') | Should -Not -Contain "$VERSIONS_DIR\7.4.33"
            $env:PATH | Should -BeLike "$VERSIONS_DIR\8.3.0;*"
        }

        It 'Clears the prepend when no .phpvmrc is upstream' {
            $proj = Join-Path $TestDrive 'inv-auto-4'
            New-Item -ItemType Directory -Path $proj -Force | Out-Null
            '8.3.0' | Set-Content (Join-Path $proj '.phpvmrc')

            Push-Location $proj
            try { Invoke-Auto -Silent } finally { Pop-Location }

            $orphan = Join-Path $TestDrive 'lone'
            New-Item -ItemType Directory -Path $orphan -Force | Out-Null
            Push-Location $orphan
            try { Invoke-Auto -Silent } finally { Pop-Location }

            $env:PHPVM_AUTO_ACTIVE | Should -BeNullOrEmpty
            ($env:PATH -split ';') | Should -Not -Contain "$VERSIONS_DIR\8.3.0"
        }
    }
}
