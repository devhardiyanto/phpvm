
function Invoke-Composer {
    $info = Get-PHPBuildInfo
    $loaded = (& $info.Exe -m 2>$null) | ForEach-Object { $_.Trim().ToLower() }
    if ($loaded -notcontains "openssl") {
        Write-Step "Enabling openssl extension (required for Composer) ..."
        Edit-IniExtension "openssl" $true
        Write-Warn "openssl enabled. If Composer install fails, restart terminal first then re-run 'phpvm composer'."
    }

    # One global composer that follows the active PHP version: the phar lives in
    # $PHPVM_DIR and the shim sits in $PHPVM_BIN (already on PATH) and calls
    # whatever `php` resolves to.
    $composerPhar = "$PHPVM_DIR\composer.phar"
    $composerBat  = "$PHPVM_BIN\composer.bat"

    if (Test-Path $composerBat) {
        Write-Warn "Composer already installed at $composerBat"
        Write-Dim "It follows your active PHP version automatically."
        Write-Dim "Run: composer --version"
        return
    }

    $installerUrl  = "https://getcomposer.org/installer"
    $installerFile = "$env:TEMP\composer-setup.php"
    $sigUrl        = "https://composer.github.io/installer.sig"

    Write-Step "Downloading Composer installer ..."
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerFile -UseBasicParsing
        $expectedHash = (Get-WebString $sigUrl).Trim()
    } catch {
        Write-Err "Download failed: $_"
        return
    }

    Write-Step "Verifying installer integrity ..."
    $actualHash = (& $info.Exe -r "echo hash_file('sha384', '$($installerFile -replace '\\','\\\\')');")
    if ($actualHash -ne $expectedHash) {
        Write-Err "Hash mismatch! Installer may be corrupt or tampered."
        Remove-Item $installerFile -Force
        return
    }
    Write-Ok "Hash verified."

    Write-Step "Installing Composer ..."
    if (-not (Test-Path $PHPVM_BIN)) { New-Item -ItemType Directory -Path $PHPVM_BIN -Force | Out-Null }
    Push-Location $PHPVM_DIR
    & $info.Exe $installerFile --quiet --filename composer.phar
    Pop-Location

    if (-not (Test-Path $composerPhar)) {
        Write-Err "composer.phar not created. Check PHP error output above."
        Remove-Item $installerFile -Force
        return
    }

    Remove-Item $installerFile -Force

    # Shim in $PHPVM_BIN (on PATH) calls `php` from PATH - i.e. the active
    # version - so composer follows `phpvm use` without reinstalling.
    $bat = @"
@echo off
php "$composerPhar" %*
"@
    $bat | Set-Content $composerBat -Encoding ASCII
    Write-Ok "Composer installed (global)!"
    Write-Ok "  phar : $composerPhar"
    Write-Ok "  shim : $composerBat"
    Write-Host ""
    # 2>$null: composer writes its PHP-version banner and the "run diagnose" hint
    # to stderr, which would bypass this pipeline and print unindented.
    & $info.Exe $composerPhar --version 2>$null | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Dim "Composer follows your active PHP version - no need to re-run after 'phpvm use'."
}
