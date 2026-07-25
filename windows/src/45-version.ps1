function Invoke-Use ([string]$ver) {
    if (-not $ver) { Write-Err "Usage: phpvm use <version>"; return }

    $targetDir = "$VERSIONS_DIR\$ver"
    if (-not (Test-Path $targetDir)) {
        Write-Err "PHP $ver is not installed. Run: phpvm install $ver"
        return
    }
    if (-not (Test-Path "$targetDir\php.exe")) {
        Write-Err "Invalid PHP $ver install: missing $targetDir\php.exe"
        return
    }

    Remove-Junction $CURRENT_LINK
    cmd /c mklink /J `"$CURRENT_LINK`" `"$targetDir`" | Out-Null

    # Persist + apply to current session (idempotent).
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $parts    = $userPath -split ";" | Where-Object { $_ -and $_ -ne $CURRENT_LINK }
    $newPath  = (@($CURRENT_LINK) + $parts -join ";") -replace ";{2,}", ";"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    if ($env:PATH -notlike "*$CURRENT_LINK*") { $env:PATH = "$CURRENT_LINK;$env:PATH" }
    # Propagate the PATH change to the rest of the system so new terminals get it
    # without a logout. This session was already updated on the line above.
    Send-EnvChangeBroadcast

    Write-Ok "Now using PHP $ver"
    try {
        & "$CURRENT_LINK\php.exe" --version 2>$null | Select-Object -First 1 | ForEach-Object { Write-Host "  $_" }
    } catch {
        return
    }
    Write-Dim "Active in this terminal now. Other already-open terminals pick it up when reopened."
}

function Invoke-List {
    $versions = if (Test-Path $VERSIONS_DIR) {
        Get-ChildItem $VERSIONS_DIR -Directory | Sort-Object Name
    } else { @() }

    Write-Host ""
    if (-not $versions) { Write-Dim "No PHP versions installed."; Write-Host ""; return }

    $current = Get-CurrentVersion
    Write-Host "  Installed versions:" -ForegroundColor Cyan
    foreach ($v in $versions) {
        if ($v.Name -eq $current) {
            Write-Host "    -> $($v.Name)  (active)" -ForegroundColor Green
        } else {
            Write-Host "       $($v.Name)" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

function Invoke-Current {
    $cur = Get-CurrentVersion
    if ($cur) {
        Write-Host ""
        Write-Host "  Active: $cur" -ForegroundColor Green
        try {
            & "$CURRENT_LINK\php.exe" --version 2>$null | ForEach-Object { Write-Host "  $_" }
        } catch {
            return
        }
        Write-Host ""
    } else {
        Write-Warn "No PHP version active. Run: phpvm use <version>"
    }
}

function Invoke-Uninstall ([string]$ver) {
    if (-not $ver) { Write-Err "Usage: phpvm uninstall <version>"; return }

    $targetDir = "$VERSIONS_DIR\$ver"
    if (-not (Test-Path $targetDir)) { Write-Err "PHP $ver is not installed."; return }
    if ((Get-CurrentVersion) -eq $ver) {
        Write-Err "Cannot uninstall the active version. Switch first: phpvm use <other-version>"
        return
    }

    Remove-Item $targetDir -Recurse -Force
    Write-Ok "PHP $ver has been removed."
}

function Invoke-Which {
    try { Write-Ok (Get-Command php -ErrorAction Stop).Source }
    catch { Write-Warn "php not found in PATH" }
}

function Invoke-Ini {
    $cur = Get-CurrentVersion
    if (-not $cur) { Write-Err "No active PHP version."; return }
    $ini = "$VERSIONS_DIR\$cur\php.ini"
    if (Test-Path $ini) {
        Write-Step "Opening $ini"
        Start-Process notepad $ini
    } else {
        Write-Err "php.ini not found: $ini"
    }
}
