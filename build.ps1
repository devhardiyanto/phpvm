<#
.SYNOPSIS
    Concatenate windows/src/*.ps1 into the shipped windows/phpvm.ps1.

.DESCRIPTION
    phpvm is distributed as a single file: the installer downloads
    windows/phpvm.ps1 straight from the repo, and `phpvm upgrade` replaces it
    in place. Splitting the sources therefore has to collapse back into one
    file at build time rather than at load time.

    Modules concatenate in filename order, which is why they are numbered.
    The order is load-bearing: 00-header.ps1 opens with param(), which must be
    the first statement in the script, and 99-entry.ps1 closes with the command
    dispatch, which must see every function already defined.

.PARAMETER Check
    Compare instead of write. Exits non-zero when windows/phpvm.ps1 has drifted
    from the modules - this is what CI gates on.

.EXAMPLE
    pwsh ./build.ps1
    pwsh ./build.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root   = $PSScriptRoot
$srcDir = Join-Path $root 'windows\src'
$outFile = Join-Path $root 'windows\phpvm.ps1'

$banner = @'
# ==============================================================================
#  GENERATED FILE - DO NOT EDIT
#  Built from windows/src/*.ps1 (concatenated in filename order).
#  Edit a module there, then run:  pwsh ./build.ps1
#  CI fails the drift check if this file and the modules disagree.
# ==============================================================================
'@

$modules = Get-ChildItem $srcDir -Filter '*.ps1' | Sort-Object Name
if (-not $modules) { throw "No modules found in $srcDir" }

# LF throughout: the repo stores LF and CI greps would trip over stray CRs.
$parts = foreach ($m in $modules) {
    $text = [System.IO.File]::ReadAllText($m.FullName) -replace "`r`n", "`n"
    "# --- src/$($m.Name) " + ('-' * [Math]::Max(1, 74 - $m.Name.Length)) + "`n" + $text.TrimEnd() + "`n"
}
$built = $banner.Replace("`r`n", "`n") + "`n`n" + ($parts -join "`n")

if ($Check) {
    if (-not (Test-Path $outFile)) { throw "Missing $outFile - run ./build.ps1" }
    $current = [System.IO.File]::ReadAllText($outFile) -replace "`r`n", "`n"
    if ($current -ceq $built) {
        Write-Host "OK: windows/phpvm.ps1 matches windows/src/*.ps1 ($($modules.Count) modules)."
        exit 0
    }

    Write-Host "DRIFT: windows/phpvm.ps1 does not match windows/src/*.ps1." -ForegroundColor Red
    Write-Host "Rebuild with: pwsh ./build.ps1" -ForegroundColor Yellow
    $diff = Compare-Object ($current -split "`n") ($built -split "`n")
    $diff | Select-Object -First 20 | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

[System.IO.File]::WriteAllText($outFile, $built, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Built windows/phpvm.ps1 from $($modules.Count) modules ($(($built -split "`n").Count) lines)."
