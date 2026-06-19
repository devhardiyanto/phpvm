# ==============================================================================
#  uninstall.ps1 - remove phpvm from Windows (reverses install.ps1)
#  Run as normal user (no admin required)
#
#  Usage:
#    .\uninstall.ps1                  # interactive confirm, removes everything
#    .\uninstall.ps1 -KeepVersions    # remove phpvm but keep built PHP versions
#    .\uninstall.ps1 -Yes             # no prompt (for automation)
#
#  Removes: %USERPROFILE%\.phpvm and the phpvm entry from your User PATH.
#  Does NOT revert ExecutionPolicy (it is user-wide and may be wanted elsewhere).
# ==============================================================================

param(
    [switch]$KeepVersions,
    [switch]$Yes,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PHPVM_DIR    = if ($env:PHPVM_DIR) { $env:PHPVM_DIR } else { "$env:USERPROFILE\.phpvm" }
$PHPVM_BIN    = "$PHPVM_DIR\bin"
$CURRENT_LINK = "$PHPVM_DIR\current"
$VERSIONS_DIR = "$PHPVM_DIR\versions"

function Write-Ok   ($m) { Write-Host "  $m" -ForegroundColor Green   }
function Write-Step ($m) { Write-Host "  > $m" -ForegroundColor Cyan   }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Err  ($m) { Write-Host "  [error] $m" -ForegroundColor Red }
function Write-Dim  ($m) { Write-Host "  $m" -ForegroundColor DarkGray }

# Broadcast WM_SETTINGCHANGE so running processes drop the removed PATH entry
# without a logout. Best-effort.
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

if ($Help) {
    Write-Host ""
    Write-Host "  phpvm uninstaller"
    Write-Host "    -Yes            Skip the confirmation prompt"
    Write-Host "    -KeepVersions   Remove phpvm but keep built PHP versions"
    Write-Host "    -Help           Show this help"
    Write-Host ""
    return
}

Write-Host ""
Write-Host "  phpvm uninstaller" -ForegroundColor Cyan
Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

if (-not (Test-Path $PHPVM_DIR)) {
    Write-Warn "phpvm not found at $PHPVM_DIR - nothing to remove."
}

if ($KeepVersions) {
    Write-Dim "Will remove phpvm but KEEP built PHP versions in:"
    Write-Dim "  $VERSIONS_DIR"
} else {
    Write-Dim "Will remove EVERYTHING under: $PHPVM_DIR"
    Write-Dim "(including all built PHP versions; pass -KeepVersions to retain them)"
}
Write-Dim "Will remove the phpvm entry from your User PATH."
Write-Host ""

# Confirm unless -Yes.
if (-not $Yes) {
    $reply = Read-Host "  Proceed? [y/N]"
    if ($reply -notmatch '^(y|yes)$') {
        Write-Host "  Aborted. Nothing was changed."
        return
    }
}

# 1. Remove phpvm paths from the User PATH (both the bin shim dir and current).
Write-Step "Cleaning User PATH ..."
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = $userPath -split ";" | Where-Object {
    $_ -and $_ -ne $PHPVM_BIN -and $_ -ne $CURRENT_LINK -and $_ -notlike "$PHPVM_DIR*"
}
$newPath = ($parts -join ";") -replace ";{2,}", ";"
if ($newPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Send-EnvChangeBroadcast
    Write-Ok "Removed phpvm from User PATH."
} else {
    Write-Dim "No phpvm entry found in User PATH."
}

# 2. Remove the phpvm directory.
if (Test-Path $PHPVM_DIR) {
    if ($KeepVersions -and (Test-Path $VERSIONS_DIR)) {
        Write-Step "Removing phpvm (keeping built versions) ..."
        Get-ChildItem -Force $PHPVM_DIR |
            Where-Object { $_.Name -ne "versions" } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
        Write-Ok "Removed phpvm. Kept: $VERSIONS_DIR"
        Write-Dim "Delete it later with: Remove-Item -Recurse -Force `"$PHPVM_DIR`""
    } else {
        Write-Step "Removing $PHPVM_DIR ..."
        # current is a junction; remove the reparse point before the tree.
        if (Test-Path $CURRENT_LINK) {
            $item = Get-Item $CURRENT_LINK -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                cmd /c rmdir "$CURRENT_LINK" | Out-Null
            }
        }
        Remove-Item $PHPVM_DIR -Recurse -Force
        Write-Ok "Removed $PHPVM_DIR"
    }
}

Write-Host ""
Write-Ok "phpvm uninstalled."
Write-Dim "Restart your terminal so the PATH change takes effect."
Write-Host ""
