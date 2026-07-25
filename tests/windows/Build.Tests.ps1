Describe 'build.ps1' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:BuildPs1 = Join-Path $script:RepoRoot 'build.ps1'
        $script:SrcDir   = Join-Path $script:RepoRoot 'windows\src'
        $script:Generated = Join-Path $script:RepoRoot 'windows\phpvm.ps1'
    }

    It 'Ships every module the generated file was built from' {
        (Get-ChildItem $script:SrcDir -Filter '*.ps1').Count | Should -BeGreaterThan 0
    }

    It 'Keeps windows/phpvm.ps1 in sync with windows/src (drift check)' {
        # Same gate CI runs. Failing here means: pwsh ./build.ps1
        $out = & $script:BuildPs1 -Check 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0 -Because "phpvm.ps1 has drifted:`n$out"
    }

    It 'Marks the generated file as generated' {
        $head = (Get-Content $script:Generated -TotalCount 10) -join "`n"

        $head | Should -Match 'GENERATED FILE - DO NOT EDIT'
        $head | Should -Match 'build\.ps1'
    }

    It 'Puts param() before any executable statement' {
        # PowerShell rejects the script outright otherwise, so the concat order
        # has to keep 00-header.ps1 first.
        $lines = Get-Content $script:Generated
        $firstCode = ($lines | Where-Object { $_.Trim() -and $_.TrimStart() -notlike '#*' } | Select-Object -First 1)

        $firstCode.TrimStart() | Should -BeLike 'param(*'
    }

    It 'Keeps the command dispatch last' {
        $lines = Get-Content $script:Generated
        $dispatch = ($lines | Select-String -SimpleMatch 'if (-not $env:PHPVM_NO_ENTRY)').LineNumber
        $lastFunc = ($lines | Select-String -Pattern '^function ' | Select-Object -Last 1).LineNumber

        $dispatch | Should -BeGreaterThan $lastFunc
    }

    It 'Declares the version exactly once' {
        ($lines = Get-Content $script:Generated | Select-String -Pattern '^\$PHPVM_VERSION').Count |
            Should -Be 1
    }

    It 'Carries no CR - the repo stores LF' {
        $raw = [System.IO.File]::ReadAllText($script:Generated)
        # A dev checkout may be CRLF; only fail on a lone CR the build introduced.
        ($raw -replace "`r`n", '') | Should -Not -Match "`r"
    }
}
