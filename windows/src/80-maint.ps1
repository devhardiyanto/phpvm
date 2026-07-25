function Invoke-FixIni {
    $cur = Get-CurrentVersion
    if (-not $cur) { Write-Err "No active PHP version. Run: phpvm use <version>"; return }

    $targetDir = "$VERSIONS_DIR\$cur"
    $ini       = "$targetDir\php.ini"
    $extPath   = "$targetDir\ext"

    if (-not (Test-Path $ini)) { Write-Err "php.ini not found: $ini"; return }

    $before  = Get-Content $ini -Raw
    $content = $before -replace '(?m)^;?\s*extension_dir\s*=.*$', "extension_dir = `"$extPath`""

    if ($content -eq $before) {
        Write-Warn "extension_dir already correct or not found in php.ini."
    } else {
        $content | Set-Content $ini -NoNewline
        Write-Ok "Fixed extension_dir -> $extPath"
    }

    # Append if extension_dir was missing entirely.
    if ($content -notmatch 'extension_dir\s*=') {
        Add-Content $ini "`nextension_dir = `"$extPath`""
        Write-Ok "Added extension_dir -> $extPath"
    }

    # Repair the CA bundle wiring too - fixes cURL error 60 on installs that
    # predate the shared bundle.
    $bundle = Get-CABundle
    if ($bundle -and (Update-IniCACert $ini $bundle)) {
        Write-Ok "CA bundle configured (curl.cainfo / openssl.cafile)."
    }

    Write-Dim "Verify: phpvm ext list"
}

# phpvm cacert [status|update] - manage the shared CA bundle.
function Invoke-Cacert ([string]$sub) {
    switch ($sub.ToLower()) {
        "update" {
            $bundle = Get-CABundle -Force
            if (-not $bundle) { return }
            $cur = Get-CurrentVersion
            if ($cur) {
                if (Update-IniCACert "$VERSIONS_DIR\$cur\php.ini" $bundle) {
                    Write-Ok "Active php.ini points at the refreshed bundle."
                }
            }
        }
        { $_ -in "", "status" } {
            if (Test-Path $PHPVM_CACERT) {
                $age = [int]((Get-Date) - (Get-Item $PHPVM_CACERT).LastWriteTime).TotalDays
                Write-Ok "CA bundle: $PHPVM_CACERT  (updated $age day(s) ago)"
                Write-Dim "Refresh with: phpvm cacert update"
            } else {
                Write-Warn "No CA bundle yet. Run: phpvm cacert update"
            }
        }
        default {
            Write-Err "Usage: phpvm cacert [status|update]"
        }
    }
}


# True when the ini's extension_dir points at the active version's ext folder.
# `current` is a junction to versions\<cur>, so the versions\<cur>\ext and
# current\ext spellings name the same directory - accept either rather than
# string-comparing and false-flagging a valid setup.
function Test-ExtDirMatch ([string]$iniExtDir, [string]$cur) {
    if (-not $iniExtDir) { return $false }
    $acceptable = @("$VERSIONS_DIR\$cur\ext", "$CURRENT_LINK\ext") |
        ForEach-Object { $_.TrimEnd('\') }
    return ($acceptable -icontains $iniExtDir.TrimEnd('\'))
}

# Read-only health check. Never mutates state - every finding points at the
# command that fixes it. Exit-code-neutral: it's a report, not a gate.
function Invoke-Doctor {
    Write-Host ""
    Write-Host "  phpvm doctor - environment health check" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------" -ForegroundColor Cyan

    function Doctor-Ok   ($m) { Write-Host "  [ok]   $m" -ForegroundColor Green;  $script:__docOk++ }
    function Doctor-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:__docWarn++ }
    $script:__docOk = 0; $script:__docWarn = 0

    # 1. Active version + junction health.
    $cur = Get-CurrentVersion
    if ($cur) {
        Doctor-Ok "Active PHP version: $cur"
    } else {
        Doctor-Warn "No active PHP version. Run: phpvm use <version>"
    }

    # 2. PATH shadowing: whichever php.exe resolves first is what runs. If it
    #    isn't phpvm's, a XAMPP/Laragon/system PHP is winning.
    $phpSources = @(Get-Command php.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    if ($phpSources.Count -eq 0) {
        Doctor-Warn "No 'php' found on PATH. Open a new terminal after 'phpvm use', or check PATH."
    } else {
        $first = $phpSources[0]
        if ($first -like "$CURRENT_LINK*" -or $first -like "$PHPVM_BIN*" -or $first -like "$VERSIONS_DIR*") {
            Doctor-Ok "'php' resolves to phpvm: $first"
        } else {
            Doctor-Warn "'php' resolves to a non-phpvm install: $first"
            Write-Dim "phpvm's bin must come first on PATH. Open a new terminal after 'phpvm use'."
        }
        $conflict = $phpSources | Where-Object { $_ -match '(?i)xampp|laragon|wamp' } | Select-Object -First 1
        if ($conflict) {
            Doctor-Warn "Another PHP toolchain on PATH: $conflict"
            Write-Dim "XAMPP/Laragon/WAMP can shadow phpvm. Remove it from PATH or reorder."
        }
    }

    # 3. ext_dir mismatch: php.ini's extension_dir must match the active build's
    #    ext folder, or bundled extensions silently fail to load.
    if ($cur) {
        try {
            $info = Get-PHPBuildInfo
            if ($info.IniPath -and (Test-Path $info.IniPath)) {
                $iniExtDir = Invoke-PHP $info.Exe "echo ini_get('extension_dir');"
                if (Test-ExtDirMatch $iniExtDir $cur) {
                    Doctor-Ok "extension_dir matches active build."
                } else {
                    Doctor-Warn "extension_dir mismatch: '$iniExtDir' != '$($info.ExtDir)'"
                    Write-Dim "Fix with: phpvm fix-ini"
                }
            } else {
                Doctor-Warn "No php.ini loaded for the active version."
                Write-Dim "Fix with: phpvm fix-ini"
            }
        } catch {
            Doctor-Warn "Could not read active PHP build info: $_"
        }
    }

    # 4. CA bundle (HTTPS/TLS for composer, ext downloads).
    if (Test-Path $PHPVM_CACERT) {
        $age = [int]((Get-Date) - (Get-Item $PHPVM_CACERT).LastWriteTime).TotalDays
        Doctor-Ok "CA bundle present ($age day(s) old)."
    } else {
        Doctor-Warn "No CA bundle. Run: phpvm cacert update"
    }

    # 5. VC++ runtime: prebuilt PHP (vs16/vs17) needs the VC++ 2015-2022 redist.
    if (Test-Path "$env:SystemRoot\System32\vcruntime140.dll") {
        Doctor-Ok "VC++ runtime (vcruntime140.dll) present."
    } else {
        Doctor-Warn "VC++ runtime not found. PHP may fail to start."
        Write-Dim "Install: https://aka.ms/vs/17/release/vc_redist.x64.exe"
    }

    Write-Host ""
    if ($script:__docWarn -eq 0) {
        Write-Ok "All checks passed ($script:__docOk ok)."
    } else {
        Write-Warn "$script:__docWarn warning(s), $script:__docOk ok. See fixes above."
    }
    Write-Host ""
}

function Invoke-Upgrade {
    $scriptUrl  = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/windows/phpvm.ps1"
    $versionUrl = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
    $scriptDest = "$PHPVM_DIR\phpvm.ps1"

    Write-Step "Checking latest version ..."
    try {
        $latest = (Get-WebString $versionUrl 5).Trim()
    } catch {
        Write-Err "Could not reach GitHub. Check your connection."
        return
    }

    if ([version]$latest -le [version]$PHPVM_VERSION) {
        Write-Ok "Already up to date. (phpvm $PHPVM_VERSION)"
        return
    }

    Write-Step "Upgrading phpvm $PHPVM_VERSION -> $latest ..."

    $backup = "$PHPVM_DIR\phpvm.ps1.bak"
    Copy-Item $scriptDest $backup -Force
    Write-Dim "Backup saved: $backup"

    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptDest -UseBasicParsing
        Unblock-File $scriptDest
        Write-Ok "phpvm upgraded to $latest!"
    } catch {
        Write-Err "Upgrade failed: $_"
        Copy-Item $backup $scriptDest -Force
        Write-Warn "Rolled back to previous version."
    }
}
