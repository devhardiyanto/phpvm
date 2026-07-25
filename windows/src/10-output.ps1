function Check-PHPVMUpdate {
    if ($env:CI -or $env:PHPVM_NO_UPDATE_CHECK) { return }

    if (Test-Path $PHPVM_LAST_CHECK) {
        $lastCheck = (Get-Item $PHPVM_LAST_CHECK).LastWriteTime
        $elapsed   = (Get-Date) - $lastCheck
        if ($elapsed.TotalSeconds -lt $PHPVM_CHECK_INTERVAL) { return }
    }

    # Touch before fetch so a slow request doesn't trigger repeated retries
    [System.IO.File]::WriteAllText($PHPVM_LAST_CHECK, (Get-Date).ToString())

    try {
        $latest = (Get-WebString $PHPVM_UPDATE_URL 3).Trim()
        if ([string]::IsNullOrEmpty($latest)) { return }

        $current = [version]$PHPVM_VERSION
        $remote  = [version]$latest

        if ($remote -gt $current) {
            Write-Host ""
            Write-Host "  +-------------------------------------------------+" -ForegroundColor Yellow
            Write-Host "  |  phpvm update available: $PHPVM_VERSION -> $latest" -ForegroundColor Yellow
            Write-Host "  |  Get it: https://github.com/devhardiyanto/phpvm  |" -ForegroundColor Yellow
            Write-Host "  +-------------------------------------------------+" -ForegroundColor Yellow
            Write-Host ""
        }
    } catch {
        return
    }
}


function Write-Ok   ($m) { Write-Host "  $m" -ForegroundColor Green  }
function Write-Err  ($m) { Write-Host "  [error] $m" -ForegroundColor Red    }
function Write-Step ($m) { Write-Host "  > $m" -ForegroundColor Cyan   }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Dim  ($m) { Write-Host "  $m" -ForegroundColor DarkGray }

# Broadcast WM_SETTINGCHANGE so running processes (Explorer, and the terminals
# it spawns afterward) refresh their environment block after a User PATH change,
# instead of needing a logout. Best-effort; any failure is swallowed.
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
    $HWND_BROADCAST   = [System.IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $SMTO_ABORTIFHUNG = 0x2
    $out = [System.UIntPtr]::Zero
    try {
        [void][PHPVM.NativeMethods]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [System.IntPtr]::Zero,
            "Environment", $SMTO_ABORTIFHUNG, 5000, [ref]$out)
    } catch { $null = $_ }
}

# -- Init ----------------------------------------------------------------------
function Initialize-PHPVM {
    # GitHub blocks TLS < 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($d in @($PHPVM_DIR, $VERSIONS_DIR, $PHPVM_BIN)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}
