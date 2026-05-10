# ==============================================================================
#  install.ps1 — phpvm installer for Windows
#  Run as normal user (no admin required)
#  Usage: .\install.ps1
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PHPVM_VERSION = "1.0.0"
$PHPVM_DIR     = if ($env:PHPVM_DIR) { $env:PHPVM_DIR } else { "$env:USERPROFILE\.phpvm" }
$PHPVM_BIN     = "$PHPVM_DIR\bin"

function Write-Ok   ($m) { Write-Host "  $m" -ForegroundColor Green  }
function Write-Step ($m) { Write-Host "  > $m" -ForegroundColor Cyan   }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "  phpvm $PHPVM_VERSION — PHP Version Manager for Windows" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# 1. Create directories
Write-Step "Creating directory structure ..."
foreach ($d in @($PHPVM_DIR, "$PHPVM_DIR\versions", $PHPVM_BIN)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# 2. Copy phpvm.ps1
$scriptSrc = Join-Path $PSScriptRoot "phpvm.ps1"
if (-not (Test-Path $scriptSrc)) {
    Write-Host "  [error] phpvm.ps1 not found next to install.ps1" -ForegroundColor Red
    exit 1
}
Copy-Item $scriptSrc "$PHPVM_DIR\phpvm.ps1" -Force
Write-Ok "Copied phpvm.ps1 -> $PHPVM_DIR\phpvm.ps1"

# 3. Create CMD launcher (phpvm.cmd) — works in CMD and PowerShell
$cmdLauncher = '@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.phpvm\phpvm.ps1" %*'

# Respect custom PHPVM_DIR in CMD launcher
if ($env:PHPVM_DIR) {
    $cmdLauncher = "@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File `"$PHPVM_DIR\phpvm.ps1`" %*"
}

$cmdLauncher | Set-Content "$PHPVM_BIN\phpvm.cmd" -Encoding ASCII
Write-Ok "Created CMD launcher -> $PHPVM_BIN\phpvm.cmd"

# 4. Create PS1 shim — PowerShell prefers .ps1 over .cmd in same folder
$psShim = "& `"$PHPVM_DIR\phpvm.ps1`" @args"
$psShim | Set-Content "$PHPVM_BIN\phpvm.ps1" -Encoding UTF8
Write-Ok "Created PS shim      -> $PHPVM_BIN\phpvm.ps1"

# 5. Add PHPVM_BIN to user PATH (idempotent)
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User") ?? ""
if ($userPath -notlike "*$PHPVM_BIN*") {
    $newPath = "$PHPVM_BIN;$userPath" -replace ";{2,}", ";"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Ok "Added to user PATH   -> $PHPVM_BIN"
} else {
    Write-Warn "$PHPVM_BIN already in PATH, skipping."
}

# 6. Ensure ExecutionPolicy allows running scripts (CurrentUser only, no admin)
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -in @("Restricted", "Undefined")) {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-Ok "ExecutionPolicy set to RemoteSigned (CurrentUser scope)"
}

# Done
Write-Host ""
Write-Host "  ✓ phpvm installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Restart your terminal, then:" -ForegroundColor Cyan
Write-Host "    phpvm install 8.3.0"
Write-Host "    phpvm use 8.3.0"
Write-Host "    phpvm list"
Write-Host ""
