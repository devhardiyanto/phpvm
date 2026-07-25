# -- CA bundle (curl.cainfo / openssl.cafile) ----------------------------------
# Windows PHP builds ship no CA bundle, so every HTTPS request from PHP fails
# with cURL error 60 until one is configured. One shared bundle in $PHPVM_DIR
# serves all installed versions.

# Ensure $PHPVM_CACERT exists; download the Mozilla bundle if missing (or -Force).
# Best-effort: returns the bundle path, or $null when absent and undownloadable.
# Never throws - an offline install must still succeed.
function Get-CABundle ([switch]$Force) {
    if ((Test-Path $PHPVM_CACERT) -and -not $Force) { return $PHPVM_CACERT }

    Write-Step "Downloading CA bundle (curl.se/ca/cacert.pem) ..."
    $tmp = "$env:TEMP\phpvm-cacert.pem"
    try {
        Invoke-Download $PHPVM_CACERT_URL $tmp
        $head = Get-Content $tmp -TotalCount 200 -ErrorAction Stop
        if (-not ($head -match "BEGIN CERTIFICATE")) { throw "not a PEM bundle" }
        Move-Item $tmp $PHPVM_CACERT -Force
        Write-Ok "CA bundle saved: $PHPVM_CACERT"
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Warn "Could not fetch CA bundle: $_"
        if (Test-Path $PHPVM_CACERT) { return $PHPVM_CACERT }
        Write-Dim "HTTPS from PHP may fail with cURL error 60. Retry later: phpvm cacert update"
        return $null
    }
    return $PHPVM_CACERT
}

# Point curl.cainfo and openssl.cafile at $bundlePath in raw php.ini content.
# Uncomments/overwrites existing directives; appends a block when absent.
function Set-IniCACert ([string]$content, [string]$bundlePath) {
    foreach ($key in @("curl.cainfo", "openssl.cafile")) {
        $pattern = "(?m)^;*\s*$([regex]::Escape($key))\s*=.*$"
        $line    = "$key = `"$bundlePath`""
        if ($content -match $pattern) {
            $content = [regex]::Replace($content, $pattern, $line.Replace('$', '$$'))
        } else {
            $content = $content.TrimEnd() + "`r`n$line`r`n"
        }
    }
    return $content
}

# Apply the shared bundle to one php.ini file. No-op if either is missing.
function Update-IniCACert ([string]$iniPath, [string]$bundlePath) {
    if (-not $bundlePath -or -not (Test-Path $iniPath)) { return $false }
    $before = Get-Content $iniPath -Raw
    $after  = Set-IniCACert $before $bundlePath
    if ($after -ne $before) { $after | Set-Content $iniPath -NoNewline }
    return $true
}
