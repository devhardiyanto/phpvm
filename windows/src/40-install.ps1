# ==============================================================================
#  CORE COMMANDS
# ==============================================================================

function Invoke-Install ([string]$ver, [string]$flag) {
    # Accept flags in either position, matching the Linux arg loop.
    $noUse      = $false
    $noCacert   = $false
    $positional = @()
    foreach ($a in @($ver, $flag)) {
        if (-not $a)               { continue }
        if ($a -eq "--no-use")     { $noUse = $true }
        elseif ($a -eq "--no-cacert") { $noCacert = $true }
        elseif ($a -like "-*")     { Write-Err "Unknown option: $a. Usage: phpvm install <version> [--no-use] [--no-cacert]"; return }
        else                       { $positional += $a }
    }
    $ver = if ($positional.Count -gt 0) { $positional[0] } else { "" }

    if (-not $ver) { Write-Err "Usage: phpvm install <version> [--no-use]  (e.g. phpvm install 8.3.0)"; return }

    # Allow "8" -> latest 8.x and "8.3" -> latest 8.3.x.
    if ($ver -match '^\d+(\.\d+)?$') {
        Write-Step "Resolving latest patch for PHP $ver ..."
        $resolved = Resolve-LatestPatch $ver
        if (-not $resolved) {
            Write-Err "No patch releases found for PHP $ver"
            Write-Dim "Browse: https://windows.php.net/downloads/releases/"
            return
        }
        Write-Ok "Latest PHP $ver -> $resolved"
        $ver = $resolved
    }

    # Anything that isn't a full x.y.z here would blow up later in Get-VSVersion's
    # [int] cast with a raw PowerShell exception.
    if ($ver -notmatch '^\d+\.\d+\.\d+$') {
        Write-Err "Invalid version '$ver'. Usage: phpvm install <version>  (e.g. phpvm install 8.3.0)"
        if ($ver -eq "composer") { Write-Dim "Did you mean: phpvm composer" }
        return
    }

    $targetDir = "$VERSIONS_DIR\$ver"
    if (Test-Path $targetDir) {
        Write-Warn "PHP $ver is already installed. Run: phpvm use $ver"
        return
    }

    Write-Step "Resolving download for PHP $ver ..."
    $url = Resolve-PHPURL $ver
    if (-not $url) {
        Write-Err "PHP $ver not found on windows.php.net"
        Write-Dim ""
        Write-Dim "Available versions (latest per branch):"
        Write-Dim "  PHP 8.5.x  -> phpvm install 8.5.1"
        Write-Dim "  PHP 8.4.x  -> phpvm install 8.4.16"
        Write-Dim "  PHP 8.3.x  -> phpvm install 8.3.29"
        Write-Dim "  PHP 8.2.x  -> phpvm install 8.2.30"
        Write-Dim "  PHP 8.1.x  -> phpvm install 8.1.34"
        Write-Dim "  PHP 7.4.x  -> phpvm install 7.4.33"
        Write-Dim ""
        Write-Dim "Full list: https://windows.php.net/downloads/releases/"
        return
    }

    $tempFile = "$env:TEMP\phpvm-php-$ver.zip"

    Write-Step "Downloading $(Split-Path $url -Leaf) ..."
    try { Invoke-Download $url $tempFile }
    catch { Write-Err "Download failed: $_"; return }

    if (-not $env:PHPVM_SKIP_HASH) {
        Write-Step "Verifying SHA-256 ..."
        $expected = Get-PHPZipHash $url
        if ($expected) {
            $actual = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Write-Err "SHA-256 mismatch! Aborting."
                Write-Dim "  expected: $expected"
                Write-Dim "  actual:   $actual"
                Remove-Item $tempFile -Force
                return
            }
            Write-Ok "SHA-256 verified."
        } else {
            Write-Warn "No published SHA-256 for $(Split-Path $url -Leaf); continuing unverified."
        }
    }

    Unblock-PHPVMPath $tempFile

    Write-Step "Extracting ..."
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Expand-Archive -Path $tempFile -DestinationPath $targetDir -Force
    Remove-Item $tempFile -Force

    if (-not (Test-Path "$targetDir\php.ini")) {
        $src = @("$targetDir\php.ini-development", "$targetDir\php.ini-production") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($src) { Copy-Item $src "$targetDir\php.ini" }
    }

    # Pin extension_dir to this version's ext folder (absolute path).
    $ini = "$targetDir\php.ini"
    if (Test-Path $ini) {
        $content = Get-Content $ini -Raw
        $extPath = "$targetDir\ext"
        $content = $content -replace '(?m)^;?\s*extension_dir\s*=.*$', "extension_dir = `"$extPath`""
        $content | Set-Content $ini -NoNewline
    }

    # Windows PHP has no CA bundle -> HTTPS from PHP fails (cURL error 60).
    # Point this version at the shared bundle, unless opted out.
    if (-not $noCacert) {
        $bundle = Get-CABundle
        if ($bundle -and (Update-IniCACert $ini $bundle)) {
            Write-Ok "CA bundle configured (curl.cainfo / openssl.cafile)."
        }
    }

    Write-Ok "PHP $ver installed successfully."

    # Activate the freshly installed version right away, unless opted out.
    if ($noUse) {
        Write-Dim "Not switching (--no-use). Run: phpvm use $ver"
    } else {
        Invoke-Use $ver
    }

    Show-OlderPatchHint $ver
}

# `phpvm install 8` resolves to the newest patch and installs it alongside any
# older patch of the same line. Point that out rather than removing it: another
# project may still pin the old patch in .phpvmrc.
function Get-OlderPatch ([string]$ver) {
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { return @() }
    if (-not (Test-Path $VERSIONS_DIR))   { return @() }

    $parts = $ver -split '\.'
    $line  = "$($parts[0]).$($parts[1])"

    return @(
        Get-ChildItem $VERSIONS_DIR -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name |
            Where-Object { $_ -match '^\d+\.\d+\.\d+$' -and $_ -like "$line.*" } |
            Where-Object { [version]$_ -lt [version]$ver } |
            Sort-Object { [version]$_ }
    )
}

function Show-OlderPatchHint ([string]$ver) {
    # The pipeline unrolls a one-element return, and StrictMode has no .Count
    # (nor a working [-1]) on the bare string that leaves behind.
    $older = @(Get-OlderPatch $ver)
    if ($older.Count -eq 0) { return }

    Write-Dim "Older patch of $(($ver -split '\.')[0..1] -join '.') still installed: $($older -join ', ')"
    Write-Dim "Remove it with: phpvm uninstall $($older[-1])"
}
