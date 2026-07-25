function Invoke-WpCli {
    $info = Get-PHPBuildInfo

    # Same global-phar-plus-shim shape as Composer: phar in $PHPVM_DIR, shim in
    # $PHPVM_BIN calls whatever `php` resolves to, so wp follows `phpvm use`.
    $wpPhar = "$PHPVM_DIR\wp-cli.phar"
    $wpBat  = "$PHPVM_BIN\wp.bat"

    if (Test-Path $wpBat) {
        Write-Warn "WP-CLI already installed at $wpBat"
        Write-Dim "It follows your active PHP version automatically."
        Write-Dim "Run: wp --version"
        return
    }

    $pharUrl = "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
    $hashUrl = "$pharUrl.sha512"

    Write-Step "Downloading WP-CLI ..."
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $pharUrl -OutFile $wpPhar -UseBasicParsing
    } catch {
        Write-Err "Download failed: $_"
        return
    }

    if (-not $env:PHPVM_SKIP_HASH) {
        Write-Step "Verifying SHA-512 ..."
        try { $expectedHash = ((Get-WebString $hashUrl).Trim() -split '\s+')[0] }
        catch { Write-Err "Could not fetch checksum: $_"; Remove-Item $wpPhar -Force; return }
        $actualHash = (& $info.Exe -r "echo hash_file('sha512', '$($wpPhar -replace '\\','\\\\')');")
        if ($actualHash -ne $expectedHash) {
            Write-Err "SHA-512 mismatch! Phar may be corrupt or tampered."
            Remove-Item $wpPhar -Force
            return
        }
        Write-Ok "SHA-512 verified."
    }

    if (-not (Test-Path $PHPVM_BIN)) { New-Item -ItemType Directory -Path $PHPVM_BIN -Force | Out-Null }
    $bat = @"
@echo off
php "$wpPhar" %*
"@
    $bat | Set-Content $wpBat -Encoding ASCII
    Write-Ok "WP-CLI installed (global)!"
    Write-Ok "  phar : $wpPhar"
    Write-Ok "  shim : $wpBat"
    Write-Host ""
    & $info.Exe $wpPhar --version 2>$null | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Dim "WP-CLI follows your active PHP version - no need to re-run after 'phpvm use'."
}
