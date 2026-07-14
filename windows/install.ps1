# ==============================================================================
#  install.ps1 - phpvm installer for Windows
#  Run as normal user (no admin required)
#  Usage: irm https://raw.githubusercontent.com/devhardiyanto/phpvm/main/windows/install.ps1 | iex
#     or: .\install.ps1   (from a clone, with phpvm.ps1 alongside)
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PHPVM_VERSION = "1.9.1"
$PHPVM_DIR     = if ($env:PHPVM_DIR) { $env:PHPVM_DIR } else { "$env:USERPROFILE\.phpvm" }
$PHPVM_BIN     = "$PHPVM_DIR\bin"

function Write-Ok   ($m) { Write-Host "  $m" -ForegroundColor Green  }
function Write-Step ($m) { Write-Host "  > $m" -ForegroundColor Cyan   }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }

# Broadcast WM_SETTINGCHANGE so new terminals pick up the PATH without a logout.
function Send-EnvChangeBroadcast {
    if (-not ("PHPVM.NativeMethods" -as [type])) {
        try {
            Add-Type -Namespace PHPVM -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
        } catch { return }
    }
    $out = [System.UIntPtr]::Zero
    try {
        [void][PHPVM.NativeMethods]::SendMessageTimeout(
            [System.IntPtr]0xffff, 0x1A, [System.IntPtr]::Zero,
            "Environment", 0x2, 5000, [ref]$out)
    } catch { $null = $_ }
}

Write-Host ""
Write-Host "  phpvm $PHPVM_VERSION - PHP Version Manager for Windows" -ForegroundColor Cyan
Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# 1. Create directories
Write-Step "Creating directory structure ..."
foreach ($d in @($PHPVM_DIR, "$PHPVM_DIR\versions", $PHPVM_BIN)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# 2. Obtain phpvm.ps1 - from the clone if we are running off disk, otherwise
#    from the repo, so `irm .../install.ps1 | iex` works with nothing local.
#    ($PSScriptRoot is empty when this script is piped into iex.)
$PHPVM_REPO = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main"
$scriptSrc  = if ($PSScriptRoot) { Join-Path $PSScriptRoot "phpvm.ps1" } else { $null }

if ($scriptSrc -and (Test-Path $scriptSrc)) {
    Copy-Item $scriptSrc "$PHPVM_DIR\phpvm.ps1" -Force
    Write-Ok "Copied phpvm.ps1     -> $PHPVM_DIR\phpvm.ps1"
} else {
    Write-Step "Downloading phpvm.ps1 ..."
    try {
        Invoke-WebRequest -Uri "$PHPVM_REPO/windows/phpvm.ps1" `
                          -OutFile "$PHPVM_DIR\phpvm.ps1" -UseBasicParsing
    } catch {
        # throw, not exit: under `irm ... | iex` an `exit` would close the user's
        # whole session instead of just aborting the install.
        Write-Host "  [error] Could not download phpvm.ps1: $_" -ForegroundColor Red
        throw "phpvm install aborted."
    }
    Write-Ok "Downloaded phpvm.ps1 -> $PHPVM_DIR\phpvm.ps1"
}
Unblock-File "$PHPVM_DIR\phpvm.ps1"

# 3. Create CMD launcher (phpvm.cmd) - works in CMD and PowerShell
$cmdLauncher = '@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.phpvm\phpvm.ps1" %*'

# Respect custom PHPVM_DIR in CMD launcher
if ($env:PHPVM_DIR) {
    $cmdLauncher = "@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File `"$PHPVM_DIR\phpvm.ps1`" %*"
}

$cmdLauncher | Set-Content "$PHPVM_BIN\phpvm.cmd" -Encoding ASCII
Write-Ok "Created CMD launcher -> $PHPVM_BIN\phpvm.cmd"

# 4. Create PS1 shim - PowerShell prefers .ps1 over .cmd in same folder
$psShim = "& `"$PHPVM_DIR\phpvm.ps1`" @args"
$psShim | Set-Content "$PHPVM_BIN\phpvm.ps1" -Encoding UTF8
Write-Ok "Created PS shim      -> $PHPVM_BIN\phpvm.ps1"

# 5. Add PHPVM_BIN to user PATH (idempotent)
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($null -eq $userPath) { $userPath = "" }
if ($userPath -notlike "*$PHPVM_BIN*") {
    $newPath = "$PHPVM_BIN;$userPath" -replace ";{2,}", ";"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Send-EnvChangeBroadcast
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
Write-Host "  OK phpvm installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Restart your terminal, then:" -ForegroundColor Cyan
Write-Host "    phpvm install 8.3.0"
Write-Host "    phpvm use 8.3.0"
Write-Host "    phpvm list"
Write-Host ""
