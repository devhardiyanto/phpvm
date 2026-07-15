# ==============================================================================
#  phpvm.ps1 - PHP Version Manager for Windows
#  Compatible with: CMD (via phpvm.cmd shim) and PowerShell
#  Repo: https://github.com/devhardiyanto/phpvm
# ==============================================================================

param(
    [Parameter(Position = 0)] [string]$Command  = "",
    [Parameter(Position = 1)] [string]$SubOrVer = "",
    [Parameter(Position = 2)] [string]$Arg2     = "",
    [Parameter(Position = 3)] [string]$Arg3     = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Constants -----------------------------------------------------------------
$PHPVM_VERSION = "1.10.0"
$PHPVM_DIR     = if ($env:PHPVM_DIR) { $env:PHPVM_DIR } else { "$env:USERPROFILE\.phpvm" }
$VERSIONS_DIR  = "$PHPVM_DIR\versions"
$CURRENT_LINK  = "$PHPVM_DIR\current"
$PHPVM_BIN     = "$PHPVM_DIR\bin"
$PHPVM_CACERT  = "$PHPVM_DIR\cacert.pem"
$PHPVM_CACERT_URL = "https://curl.se/ca/cacert.pem"

# -- Update checker (once per day, via version.txt) ---------------------------
$PHPVM_UPDATE_URL   = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
$PHPVM_LAST_CHECK   = "$PHPVM_DIR\.last_update_check"
$PHPVM_CHECK_INTERVAL = 86400  # 24 hours in seconds

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

# -- PHP build metadata --------------------------------------------------------
# Some Windows PHP builds leak warnings into stdout; strip them.
function Invoke-PHP ([string]$exe, [string]$code) {
    $out = & $exe -r $code 2>$null
    $clean = $out | Where-Object { $_ -notmatch "^(PHP )?(Warning|Notice|Deprecated|Fatal|Parse)" }
    return ($clean -join "").Trim()
}

function Get-PHPBuildInfo ([string]$phpExe = "") {
    if (-not $phpExe) {
        if (Test-Path "$CURRENT_LINK\php.exe") { $phpExe = "$CURRENT_LINK\php.exe" }
        else { throw "No active PHP version. Run: phpvm use <version>" }
    }

    $raw  = (& $phpExe -i 2>$null) | Where-Object { $_ -notmatch "^(PHP )?(Warning|Notice|Deprecated)" }

    $version = Invoke-PHP $phpExe "echo PHP_VERSION;"
    if ($version -match '(\d+\.\d+\.\d+)') { $version = $Matches[1] }
    $short = $version -replace '^(\d+\.\d+)\..*', '$1'

    # Both lines can be absent when php -i fails or emits garbage; .ToString()
    # on the empty pipeline would throw a raw MethodInvocationException.
    $tsLine = $raw | Select-String "Thread Safety" | Select-Object -First 1
    $isTS   = $tsLine -and ($tsLine.ToString() -match "enabled")

    $compLine = $raw | Select-String "Compiler" | Select-Object -First 1
    $compLine = if ($compLine) { $compLine.ToString() } else { "" }
    $vs = switch -Regex ($compLine) {
        "MSVC17|VS17" { "vs17"; break }
        "MSVC16|VS16" { "vs16"; break }
        "MSVC15|VS15" { "vs15"; break }
        default        { Get-VSVersion $version }
    }

    # Derive ext dir from exe; php.ini may still point at a system PHP.
    $phpRoot = Split-Path $phpExe -Parent
    $extDir  = "$phpRoot\ext"

    $iniPath = Invoke-PHP $phpExe "echo php_ini_loaded_file();"

    return @{
        Version = $version
        Short   = $short
        TS      = if ($isTS) { "ts" } else { "nts" }
        VS      = $vs
        Arch    = "x64"
        Exe     = $phpExe
        Root    = $phpRoot
        ExtDir  = $extDir
        IniPath = $iniPath
    }
}


# -- Resolve PHP download URL --------------------------------------------------
# Per windows.php.net: 5.x -> vc11, 7.0-7.1 -> vc14, 7.2-7.4 -> vc15,
# 8.0-8.3 -> vs16, 8.4+ -> vs17.
function Get-VSVersion ([string]$ver) {
    # Anything that isn't x.y... would blow up the [int] casts below.
    if ($ver -notmatch '^\d+\.\d+') { return "vs17" }
    $major = [int]($ver -split '\.')[0]
    $minor = [int]($ver -split '\.')[1]
    if ($major -eq 5)                          { return "vc11" }
    if ($major -eq 7 -and $minor -le 1)        { return "vc14" }
    if ($major -eq 7)                          { return "vc15" }
    if ($major -eq 8 -and $minor -le 3)        { return "vs16" }
    if ($major -eq 8 -and $minor -ge 4)        { return "vs17" }
    return "vs17"
}

function Resolve-PHPURL ([string]$ver) {
    $vs = Get-VSVersion $ver
    $urls = @(
        "https://windows.php.net/downloads/releases/php-$ver-Win32-$vs-x64.zip"
        "https://windows.php.net/downloads/releases/php-$ver-nts-Win32-$vs-x64.zip"
        "https://windows.php.net/downloads/releases/archives/php-$ver-Win32-$vs-x64.zip"
        "https://windows.php.net/downloads/releases/archives/php-$ver-nts-Win32-$vs-x64.zip"
    )
    foreach ($url in $urls) {
        try {
            $req = [System.Net.WebRequest]::Create($url)
            $req.Method  = "HEAD"
            $req.Timeout = 5000
            $res = $req.GetResponse()
            $res.Close()
            return $url
        } catch {
            continue
        }
    }
    return $null
}

# Resolve a partial version to the highest patch published on windows.php.net.
#   "8"   -> latest 8.x   (e.g. 8.5.7)
#   "8.3" -> latest 8.3.x (e.g. 8.3.31)
function Resolve-LatestPatch ([string]$request) {
    $found = @()
    # Capture the full x.y.z from any Win32 build name.
    # (?i) - older archives use uppercase (VC11/VC14/VC15); newer lowercase (vs16/vs17).
    $pattern = '(?i)php-(\d+\.\d+\.\d+)-(?:nts-)?Win32-(?:vs1[567]|vc1[145])-x64\.zip'

    foreach ($index in @(
        "https://windows.php.net/downloads/releases/"
        "https://windows.php.net/downloads/releases/archives/"
    )) {
        try {
            $html = Get-WebString $index 5
        } catch { continue }
        foreach ($m in [regex]::Matches($html, $pattern)) {
            $found += $m.Groups[1].Value
        }
    }

    if (-not $found) { return $null }
    # Keep versions whose prefix matches the request. The '(\.|$)' guard stops
    # "8.3" from matching "8.30.x" and "8" from matching "18.x".
    $filter = '^' + [regex]::Escape($request) + '(\.|$)'
    $cand   = $found | Where-Object { $_ -match $filter }
    if (-not $cand) { return $null }
    return ($cand | Sort-Object -Unique | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

# -- Junction helpers ----------------------------------------------------------
function Get-CurrentVersion {
    if (-not (Test-Path $CURRENT_LINK)) { return $null }
    $item = Get-Item $CURRENT_LINK -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # On PS 5.1 Target can be missing or empty for some reparse points;
        # Split-Path $null would throw under StrictMode.
        $target = if ($item.PSObject.Properties['Target']) { @($item.Target)[0] } else { $null }
        if (-not $target) { return $null }
        return Split-Path $target -Leaf
    }
    return $null
}

function Remove-Junction ([string]$path) {
    if (Test-Path $path) {
        $item = Get-Item $path -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            [System.IO.Directory]::Delete($path)
        } else {
            Remove-Item $path -Recurse -Force
        }
    }
}

# -- Download helper -----------------------------------------------------------
# Progress is only worth drawing for the PHP zips (tens of MB); the Xdebug DLL
# and ext zips are small enough that a bar would just flicker.
$script:PROGRESS_MIN_BYTES = 5MB

function Format-Bytes ([double]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N1} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    return "{0:N0} KB" -f ($bytes / 1KB)
}

function Format-Duration ([double]$seconds) {
    if ($seconds -lt 0 -or [double]::IsInfinity($seconds) -or [double]::IsNaN($seconds)) { return "--:--" }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($seconds))
    if ($ts.TotalHours -ge 1) { return "{0:d1}:{1:d2}:{2:d2}" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds }
    return "{0:d2}:{1:d2}" -f $ts.Minutes, $ts.Seconds
}

# Streams $url to $dest, drawing a byte-level progress line on stderr so stdout
# stays pipe-clean. Falls back to a plain copy when the size is unknown, the
# payload is small, or stderr is redirected (CI, tests).
function Invoke-Download ([string]$url, [string]$dest) {
    $ProgressPreference = "SilentlyContinue"

    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "phpvm/$PHPVM_VERSION"
        $resp  = $req.GetResponse()
        $total = [long]$resp.ContentLength
    } catch {
        if ($resp) { $resp.Dispose() }
        # Anything odd about the response: let Invoke-WebRequest deal with it.
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        return
    }

    $showProgress = ($total -ge $script:PROGRESS_MIN_BYTES) -and (-not [Console]::IsErrorRedirected)

    $input_  = $resp.GetResponseStream()
    $output = [System.IO.File]::Create($dest)
    $buffer = New-Object byte[] 81920
    $read      = 0
    $sw        = [Diagnostics.Stopwatch]::StartNew()
    $lastDraw  = 0

    try {
        while (($n = $input_.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $n)
            $read += $n

            if (-not $showProgress) { continue }
            # Throttle redraws; repainting per 80 KB chunk is pure overhead.
            if ($sw.ElapsedMilliseconds - $lastDraw -lt 120 -and $read -lt $total) { continue }
            $lastDraw = $sw.ElapsedMilliseconds

            $elapsed = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $speed   = $read / $elapsed
            $eta     = if ($speed -gt 0) { ($total - $read) / $speed } else { -1 }
            $pct     = [int](100 * $read / $total)

            $line = "  {0,3}%  {1} / {2}  ({3}/s, eta {4})" -f `
                $pct, (Format-Bytes $read), (Format-Bytes $total),
                (Format-Bytes $speed), (Format-Duration $eta)
            [Console]::Error.Write(("`r" + $line.PadRight(70)))
        }
    } finally {
        $output.Dispose()
        $input_.Dispose()
        $resp.Dispose()
        if ($showProgress) { [Console]::Error.Write("`r" + (" " * 70) + "`r") }
    }
}


function Get-WebString ([string]$url, [int]$timeoutSec = 5) {
    $ProgressPreference = "SilentlyContinue"
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec
    $c = $resp.Content
    if ($c -is [byte[]]) { $c = [System.Text.Encoding]::UTF8.GetString($c) }
    return [string]$c
}

function Unblock-PHPVMPath ([string]$path) {
    if (-not (Test-Path $path)) { return }

    try {
        Unblock-File -Path $path -ErrorAction SilentlyContinue
        if (Test-Path $path -PathType Container) {
            Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                Unblock-File -ErrorAction SilentlyContinue
        }
    } catch {
        return
    }
}

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

# Look up the expected SHA-256 for a PHP zip on windows.php.net.
# Returns lowercase hex digest, or $null if no checksum is published.
function Get-PHPZipHash ([string]$zipUrl) {
    $sumUrl  = ($zipUrl -replace '/[^/]+\.zip$', '/') + 'sha256sum.txt'
    $zipName = Split-Path $zipUrl -Leaf
    try { $sums = Get-WebString $sumUrl 10 } catch { return $null }

    foreach ($line in $sums -split "`r?`n") {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($zipName))\s*$") {
            return $Matches[1].ToLower()
        }
    }
    return $null
}

# Fetch a sibling .sha256 file (xdebug.org convention) and return its digest.
function Get-XDebugHash ([string]$dllUrl) {
    try { $content = Get-WebString "$dllUrl.sha256" 10 } catch { return $null }
    if ($content -match '([0-9a-fA-F]{64})') { return $Matches[1].ToLower() }
    return $null
}

function Test-URLExists ([string]$url) {
    $ProgressPreference = "SilentlyContinue"
    # HEAD via Invoke-WebRequest follows 30x redirects (windows.php.net -> downloads.php.net).
    try {
        $r = Invoke-WebRequest -Uri $url -Method Head -MaximumRedirection 5 `
                               -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch {
        # Some mirrors reject HEAD (405) -- fall back to a 1-byte ranged GET.
        try {
            $r = Invoke-WebRequest -Uri $url -Method Get -MaximumRedirection 5 `
                                   -UseBasicParsing -TimeoutSec 5 `
                                   -Headers @{ Range = "bytes=0-0" } -ErrorAction Stop
            return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
        } catch { return $false }
    }
}

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
    $older = Get-OlderPatch $ver
    if ($older.Count -eq 0) { return }

    Write-Dim "Older patch of $(($ver -split '\.')[0..1] -join '.') still installed: $($older -join ', ')"
    Write-Dim "Remove it with: phpvm uninstall $($older[-1])"
}

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

# ==============================================================================
#  AUTO-SWITCH (.phpvmrc)
# ==============================================================================

# Walk from $startDir up to the drive root looking for a .phpvmrc file.
function Find-PHPVMRC ([string]$startDir = '') {
    if (-not $startDir) { $startDir = (Get-Location).Path }
    $dir = $startDir
    while ($dir) {
        $rc = Join-Path $dir '.phpvmrc'
        if (Test-Path $rc -PathType Leaf) { return $rc }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
    return $null
}

# Return the first non-comment, non-empty line of an rc file. Strips a leading
# `v` (some users write `v8.3.0`) and any trailing whitespace.
function Read-PHPVMRC ([string]$rcFile) {
    if (-not (Test-Path $rcFile -PathType Leaf)) { return $null }
    foreach ($line in (Get-Content $rcFile)) {
        $line = ($line -replace '#.*$').Trim()
        if ($line) { return ($line -replace '^v', '') }
    }
    return $null
}

# Map an rc version (8.3, 8.3.0, 5.6.40) onto an installed version directory.
# Full semver passes through if installed; partial picks the highest installed
# patch. Returns $null if no matching version is installed locally.
function Resolve-RCVersion ([string]$requested) {
    if (-not $requested) { return $null }
    $target = "$VERSIONS_DIR\$requested"
    if (Test-Path "$target\php.exe") { return $requested }

    if ($requested -match '^\d+\.\d+$') {
        $prefix = "$requested."
        $match = Get-ChildItem $VERSIONS_DIR -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith($prefix) -and (Test-Path "$($_.FullName)\php.exe") } |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
        if ($match) { return $match.Name }
    }
    return $null
}

# Session-only PATH switch driven by .phpvmrc. Tracks the active version in
# $env:PHPVM_AUTO_ACTIVE so repeat calls are no-ops and leaving a project
# cleanly removes the prepended path.
function Invoke-Auto ([switch]$Silent) {
    $rcFile = Find-PHPVMRC

    if (-not $rcFile) {
        if ($env:PHPVM_AUTO_ACTIVE) {
            $old = "$VERSIONS_DIR\$($env:PHPVM_AUTO_ACTIVE)"
            $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_ -ne $old }) -join ';'
            $env:PHPVM_AUTO_ACTIVE = ''
            if (-not $Silent) { Write-Dim "Cleared auto PHP (no .phpvmrc upstream)." }
        }
        return
    }

    $requested = Read-PHPVMRC $rcFile
    if (-not $requested) {
        if (-not $Silent) { Write-Warn "$rcFile is empty or comment-only." }
        return
    }

    $resolved = Resolve-RCVersion $requested
    if (-not $resolved) {
        if (-not $Silent) {
            Write-Warn "PHP $requested (from $rcFile) is not installed."
            Write-Dim "Run: phpvm install $requested"
        }
        return
    }

    if ($env:PHPVM_AUTO_ACTIVE -eq $resolved) { return }

    if ($env:PHPVM_AUTO_ACTIVE) {
        $old = "$VERSIONS_DIR\$($env:PHPVM_AUTO_ACTIVE)"
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_ -ne $old }) -join ';'
    }

    $new = "$VERSIONS_DIR\$resolved"
    $env:PATH = "$new;$env:PATH"
    $env:PHPVM_AUTO_ACTIVE = $resolved
    if (-not $Silent) {
        Write-Ok "Auto-switched to PHP $resolved  (from $rcFile)"
    }
}

# Manage the $PROFILE snippet that runs `phpvm auto -Silent` on each prompt.
$script:PHPVM_HOOK_MARKER = '# phpvm-auto-hook (managed by `phpvm hook`)'

function Get-PHPVMHookSnippet {
    @"

$($script:PHPVM_HOOK_MARKER)
if (Get-Command phpvm -ErrorAction SilentlyContinue) {
    `$global:__phpvm_prev_prompt = `$function:prompt
    function global:prompt {
        try { phpvm auto -Silent } catch {}
        if (`$global:__phpvm_prev_prompt) { & `$global:__phpvm_prev_prompt }
        else { "PS `$(`$ExecutionContext.SessionState.Path.CurrentLocation)`$('>' * (`$nestedPromptLevel + 1)) " }
    }
}
"@
}

function Install-PHPVMHook {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }
    $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($existing -and $existing.Contains($script:PHPVM_HOOK_MARKER)) {
        Write-Warn "phpvm hook already installed in $profilePath"
        return
    }
    Add-Content -Path $profilePath -Value (Get-PHPVMHookSnippet)
    Write-Ok "Installed hook -> $profilePath"
    Write-Dim "Open a new PowerShell window to activate."
}

function Uninstall-PHPVMHook {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path $profilePath)) {
        Write-Warn "No `$PROFILE found at $profilePath"
        return
    }
    $content = Get-Content $profilePath -Raw
    if (-not $content.Contains($script:PHPVM_HOOK_MARKER)) {
        Write-Warn "phpvm hook not found in $profilePath"
        return
    }
    # Strip from marker to the matching closing brace of the `if` block.
    $pattern = "(?ms)\r?\n?" + [regex]::Escape($script:PHPVM_HOOK_MARKER) + ".*?^\}\s*"
    $cleaned = [regex]::Replace($content, $pattern, '')
    Set-Content -Path $profilePath -Value $cleaned -NoNewline
    Write-Ok "Removed hook from $profilePath"
    Write-Dim "Open a new PowerShell window for the change to take effect."
}

function Show-PHPVMHookStatus {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path $profilePath)) {
        Write-Dim "No `$PROFILE at $profilePath - hook not installed."
        return
    }
    $content = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($script:PHPVM_HOOK_MARKER)) {
        Write-Ok "Hook installed in $profilePath"
    } else {
        Write-Dim "Hook not installed. Run: phpvm hook install"
    }
}

function Invoke-Hook ([string]$sub) {
    switch ($sub.ToLower()) {
        'install'   { Install-PHPVMHook }
        'uninstall' { Uninstall-PHPVMHook }
        'remove'    { Uninstall-PHPVMHook }
        'status'    { Show-PHPVMHookStatus }
        default     {
            Write-Host ""
            Write-Host "  phpvm hook - manage the PowerShell auto-switch hook" -ForegroundColor Cyan
            Write-Host "    phpvm hook install    Add the prompt hook to `$PROFILE"
            Write-Host "    phpvm hook uninstall  Remove the hook"
            Write-Host "    phpvm hook status     Check whether the hook is installed"
            Write-Host ""
        }
    }
}

# ==============================================================================
#  EXT COMMANDS
# ==============================================================================

function Ext-List {
    $info = Get-PHPBuildInfo
    Write-Host ""
    Write-Host "  PHP $($info.Version) [$($info.TS.ToUpper()) / $($info.VS) / $($info.Arch)]" -ForegroundColor Cyan
    Write-Host "  php.ini : $($info.IniPath)" -ForegroundColor DarkGray
    Write-Host "  ext dir : $($info.ExtDir)" -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Test-Path $info.ExtDir)) { Write-Warn "ext/ directory not found."; return }

    $loaded = (& $info.Exe -m 2>$null) | ForEach-Object { $_.Trim().ToLower() }
    $dlls   = Get-ChildItem $info.ExtDir -Filter "php_*.dll" | Sort-Object Name

    Write-Host "  EXTENSION             STATUS" -ForegroundColor Yellow
    Write-Host "  -----------------------------"
    foreach ($dll in $dlls) {
        $name = $dll.BaseName -replace '^php_', ''
        $on   = $loaded -contains $name.ToLower()
        $pad  = $name.PadRight(22)
        if ($on) { Write-Host "  $pad [ON]" -ForegroundColor Green }
        else     { Write-Host "  $pad [off]" -ForegroundColor DarkGray }
    }
    Write-Host ""
    Write-Dim "phpvm ext enable <name>   phpvm ext disable <name>   phpvm ext install <name>"
    Write-Host ""
}

function Ext-Loaded {
    $info = Get-PHPBuildInfo
    Write-Host ""
    Write-Host "  Loaded extensions - PHP $($info.Version):" -ForegroundColor Cyan
    & $info.Exe -m 2>$null | Where-Object { $_ -notmatch '^\[' } | Sort-Object |
        ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    Write-Host ""
}

function Edit-IniExtension ([string]$extName, [bool]$enable) {
    $info    = Get-PHPBuildInfo
    $iniPath = $info.IniPath

    if (-not $iniPath -or -not (Test-Path $iniPath)) {
        Write-Err "php.ini not found. Run: phpvm ini"
        return
    }

    $extLower = $extName.ToLower()
    $content  = Get-Content $iniPath -Raw

    $zendExts = @("xdebug", "opcache", "ioncube_loader")
    $prefix   = if ($zendExts -contains $extLower) { "zend_extension" } else { "extension" }

    # Matches `;extension=name`, `extension=name`, or `extension=php_name.dll`.
    $linePattern = "(?im)^(;+\s*)?($prefix\s*=\s*(?:php_)?$([regex]::Escape($extLower))(?:\.dll)?)\s*$"

    if ($enable) {
        if ($content -match $linePattern) {
            $newContent = [regex]::Replace($content, $linePattern, '$2')
            if ($newContent -eq $content) { Write-Warn "'$extName' is already enabled." }
            else { $newContent | Set-Content $iniPath -NoNewline; Write-Ok "Enabled: $extName" }
        } else {
            $dllPath = "$($info.ExtDir)\php_$extLower.dll"
            if (-not (Test-Path $dllPath)) {
                Write-Err "DLL not found: $dllPath"
                Write-Dim "Install it first: phpvm ext install $extName"
                return
            }
            Add-Content $iniPath "`n$prefix=$extLower"
            Write-Ok "Enabled: $extName  (added to php.ini)"
        }
    } else {
        if ($content -match $linePattern) {
            $newContent = [regex]::Replace($content, $linePattern, ';$2')
            $newContent | Set-Content $iniPath -NoNewline
            Write-Ok "Disabled: $extName"
        } else {
            Write-Warn "'$extName' not found in php.ini."
        }
    }
}

function Get-PECLVersions ([string]$extName) {
    try {
        $html = Get-WebString "https://windows.php.net/downloads/pecl/releases/$extName/"
        $m    = [regex]::Matches($html, 'href="(\d+\.\d+[\.\d]*)/?">') 
        return $m | ForEach-Object { $_.Groups[1].Value } | Sort-Object { [version]$_ } -Descending
    } catch { return @() }
}

function Install-PECLExt ([string]$extName, [string]$requestedVer = "") {
    $info = Get-PHPBuildInfo
    Write-Step "PHP $($info.Version) [$($info.TS) / $($info.VS) / $($info.Arch)]"

    $dllDest = "$($info.ExtDir)\php_$extName.dll"
    if (Test-Path $dllDest) {
        Write-Warn "php_$extName.dll already installed. Run: phpvm ext enable $extName"
        return
    }

    Write-Step "Fetching available versions for '$extName' ..."
    $versions = Get-PECLVersions $extName
    if (-not $versions) {
        Write-Err "Extension '$extName' not found on windows.php.net/downloads/pecl/releases/"
        Write-Dim "Browse: https://windows.php.net/downloads/pecl/releases/"
        return
    }

    $tryVersions = if ($requestedVer) { @($requestedVer) } else { $versions | Select-Object -First 5 }
    $phpShort    = $info.Short
    $ts          = $info.TS
    $vs          = $info.VS
    $arch        = $info.Arch

    $foundUrl = $null
    $foundZip = $null

    :outer foreach ($ver in $tryVersions) {
        $base = "https://windows.php.net/downloads/pecl/releases/$extName/$ver"
        foreach ($candidate in @(
            "php_$extName-$ver-$phpShort-$ts-$vs-$arch.zip"
            "php_$extName-$ver-$phpShort-nts-$vs-$arch.zip"
            "php_$extName-$ver-$phpShort-ts-$vs-$arch.zip"
        )) {
            if (Test-URLExists "$base/$candidate") {
                $foundUrl = "$base/$candidate"
                $foundZip = $candidate
                break outer
            }
        }
    }

    if (-not $foundUrl) {
        Write-Err "No compatible package found for: $extName (PHP $phpShort $ts $vs $arch)"
        Write-Dim "Browse: https://windows.php.net/downloads/pecl/releases/$extName/"
        return
    }

    $tempZip     = "$env:TEMP\phpvm-pecl-$extName.zip"
    $tempExtract = "$env:TEMP\phpvm-pecl-$extName"

    Write-Step "Downloading $foundZip ..."
    Invoke-Download $foundUrl $tempZip

    Unblock-PHPVMPath $tempZip

    Write-Step "Extracting ..."
    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
    Unblock-PHPVMPath $tempExtract

    $dll = Get-ChildItem $tempExtract -Filter "php_$extName.dll" -Recurse | Select-Object -First 1
    if (-not $dll) { Write-Err "php_$extName.dll not found in archive."; return }

    Copy-Item $dll.FullName $dllDest -Force
    Unblock-PHPVMPath $dllDest
    Write-Ok "Installed: php_$extName.dll"

    # Dependency DLLs go next to php.exe (must be on PATH at load time).
    $phpRoot = Split-Path $info.Exe -Parent
    Get-ChildItem $tempExtract -Filter "*.dll" |
        Where-Object { $_.Name -ne "php_$extName.dll" } |
        ForEach-Object {
            $dep = "$phpRoot\$($_.Name)"
            if (-not (Test-Path $dep)) {
                Copy-Item $_.FullName $dep -Force
                Unblock-PHPVMPath $dep
                Write-Dim "Dependency: $($_.Name) -> PHP root"
            }
        }

    Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Done. Enable with: phpvm ext enable $extName"

    Show-ExtRuntimeNotes $extName
}

# Post-install runtime advisories for extensions that need extra system components.
function Show-ExtRuntimeNotes ([string]$extName) {
    switch -Regex ($extName.ToLower()) {
        '^(sqlsrv|pdo_sqlsrv)$' {
            Write-Host ""
            Write-Dim "Note: sqlsrv / pdo_sqlsrv also requires the Microsoft ODBC Driver"
            Write-Dim "for SQL Server on this machine. Install (one-off, system-wide):"
            Write-Dim "  https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server"
            Write-Dim "Setup guide: https://learn.microsoft.com/sql/connect/php/step-1-configure-development-environment-for-php-development"
        }
    }
}

function Install-XDebug {
    $info     = Get-PHPBuildInfo
    $dllDest  = "$($info.ExtDir)\php_xdebug.dll"

    if (Test-Path $dllDest) { Write-Warn "XDebug already installed."; return }

    $phpShort   = $info.Short
    $vs         = $info.VS
    $ts         = $info.TS
    $archSuffix = if ($ts -eq "nts") { "nts-x86_64" } else { "x86_64" }

    Write-Step "Fetching XDebug for PHP $phpShort [$ts / $vs] from xdebug.org ..."

    try {
        $html    = Get-WebString "https://xdebug.org/files/"
        $pattern = "php_xdebug-([\d.]+)-$phpShort-$vs-$archSuffix\.dll"
        $hits    = [regex]::Matches($html, $pattern)

        if (-not $hits.Count) {
            $archSuffix = if ($ts -eq "ts") { "nts-x86_64" } else { "x86_64" }
            $pattern    = "php_xdebug-([\d.]+)-$phpShort-$vs-$archSuffix\.dll"
            $hits       = [regex]::Matches($html, $pattern)
        }

        if (-not $hits.Count) {
            Write-Err "No XDebug DLL found for PHP $phpShort / $vs."
            Write-Dim "Use the wizard: https://xdebug.org/wizard"
            return
        }

        $xdVer   = ($hits | ForEach-Object { $_.Groups[1].Value } | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
        $dllName = "php_xdebug-$xdVer-$phpShort-$vs-$archSuffix.dll"
        $url     = "https://xdebug.org/files/$dllName"
    } catch {
        Write-Err "Failed to reach xdebug.org: $_"
        Write-Dim "Manual: https://xdebug.org/wizard"
        return
    }

    Write-Step "Downloading XDebug $xdVer ..."
    $tempDll = "$env:TEMP\$dllName"
    Invoke-Download $url $tempDll

    if (-not $env:PHPVM_SKIP_HASH) {
        Write-Step "Verifying SHA-256 ..."
        $expected = Get-XDebugHash $url
        if ($expected) {
            $actual = (Get-FileHash -Path $tempDll -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Write-Err "SHA-256 mismatch! Aborting."
                Write-Dim "  expected: $expected"
                Write-Dim "  actual:   $actual"
                Remove-Item $tempDll -Force
                return
            }
            Write-Ok "SHA-256 verified."
        } else {
            Write-Warn "No SHA-256 published for $dllName; continuing unverified."
        }
    }

    Unblock-PHPVMPath $tempDll
    Copy-Item $tempDll $dllDest -Force
    Unblock-PHPVMPath $dllDest
    Remove-Item $tempDll -Force

    $iniPath = $info.IniPath
    if ($iniPath -and (Test-Path $iniPath)) {
        $existing = Get-Content $iniPath -Raw
        if ($existing -notmatch "zend_extension\s*=\s*xdebug") {
            $block = @"

[xdebug]
zend_extension=xdebug
xdebug.mode=debug
xdebug.start_with_request=yes
xdebug.client_host=127.0.0.1
xdebug.client_port=9003
"@
            Add-Content $iniPath $block
            Write-Ok "XDebug config added to php.ini"
        }
    }

    Write-Ok "XDebug $xdVer installed and enabled!"
    Write-Dim "VSCode: install 'PHP Debug' extension | listen on port 9003"
}

function Ext-Info ([string]$extName) {
    $info = Get-PHPBuildInfo
    Write-Host ""
    $out = & $info.Exe -r @"
if (extension_loaded('$extName')) {
    `$r = new ReflectionExtension('$extName');
    echo 'Name    : ' . `$r->getName() . PHP_EOL;
    `$version = `$r->getVersion();
    if (`$version -eq `$null) { `$version = 'n/a'; }
    echo 'Version : ' . `$version . PHP_EOL;
    `$classes = `$r->getClassNames();
    if (`$classes) echo 'Classes : ' . implode(', ', `$classes) . PHP_EOL;
} else {
    echo "Not loaded. Run: phpvm ext enable $extName" . PHP_EOL;
}
"@ 2>$null
    $out | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

function Ext-Laravel ([string]$preset = "full") {
    $info = Get-PHPBuildInfo

    # Shipped with PHP - only need enable in php.ini.
    $bundledMinimal = @(
        "openssl"       # HTTPS, encryption, queue
        "pdo"           # database abstraction
        "pdo_mysql"     # MySQL / MariaDB
        "pdo_sqlite"    # SQLite (testing)
        "mbstring"      # multibyte string, validation
        "tokenizer"     # Blade template parsing
        "xml"           # XML processing
        "ctype"         # character validation
        "fileinfo"      # MIME type detection (file upload)
        "bcmath"        # decimal precision (payments)
        "curl"          # HTTP client (Guzzle, APIs)
        "zip"           # compress/extract
        "sodium"        # encryption (Laravel Crypt)
    )

    $bundledFull = @(
        "intl"          # internationalisation, number/date formatting
        "gd"            # image manipulation (resize, thumbnail)
        "exif"          # read EXIF metadata from photos
        "opcache"       # bytecode cache - required in production
        "pdo_pgsql"     # PostgreSQL driver
        "pgsql"         # PostgreSQL native functions
        "sockets"       # Laravel Reverb / WebSocket / queue worker
    )

    # Need PECL download + enable.
    $peclFull = @(
        "redis"         # Redis cache, session, queue driver
    )

    $enableList  = $bundledMinimal
    $peclList    = @()

    if ($preset -ne "minimal") {
        $enableList += $bundledFull
        $peclList   += $peclFull
    }

    # -- Banner ------------------------------------------------
    $label = if ($preset -eq "minimal") { "minimal" } else { "full" }
    Write-Host ""
    Write-Host "  Laravel extension setup ($label) - PHP $($info.Version)" -ForegroundColor Cyan
    Write-Host "  -----------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    # -- Step 1: Enable bundled extensions --------------------
    Write-Host "  [1/2] Enabling bundled extensions ..." -ForegroundColor Yellow
    $extDir = $info.ExtDir

    # Snapshot once - Edit-IniExtension doesn't reload PHP.
    $loaded = (& $info.Exe -m 2>$null) | ForEach-Object { $_.Trim().ToLower() }

    foreach ($ext in $enableList) {
        $dllPath = "$extDir\php_$ext.dll"

        if (-not (Test-Path $dllPath)) {
            Write-Host "       skip  $ext  (DLL not found in this PHP build)" -ForegroundColor DarkGray
            continue
        }

        if ($loaded -contains $ext.ToLower()) {
            Write-Host ("       {0,-18} already ON" -f $ext) -ForegroundColor DarkGray
        } else {
            Edit-IniExtension $ext $true
        }
    }

    # -- Step 2: PECL extensions -------------------------------
    if ($peclList.Count -gt 0) {
        Write-Host ""
        Write-Host "  [2/2] Installing PECL extensions ..." -ForegroundColor Yellow
        foreach ($ext in $peclList) {
            $dllPath = "$extDir\php_$ext.dll"
            if (Test-Path $dllPath) {
                if ($loaded -contains $ext.ToLower()) {
                    Write-Host ("       {0,-18} already ON" -f $ext) -ForegroundColor DarkGray
                } else {
                    Write-Host "       $ext  (DLL exists, enabling ...)" -ForegroundColor Cyan
                    Edit-IniExtension $ext $true
                }
            } else {
                Install-PECLExt $ext
                Edit-IniExtension $ext $true
            }
        }
    }

    # -- Summary -----------------------------------------------
    Write-Host ""
    Write-Ok "Done! Restart your terminal then verify with: php -m"
    Write-Host ""

    if ($preset -eq "minimal") {
        Write-Dim "For Redis + GD + opcache + intl, run: phpvm ext laravel full"
    } else {
        Write-Dim "Optional extras:"
        Write-Dim "  phpvm ext install xdebug      # debugger"
        Write-Dim "  phpvm ext install imagick      # advanced image processing"
        Write-Dim "  phpvm ext enable pdo_pgsql     # if using PostgreSQL"
        Write-Dim "  phpvm composer                 # install Composer"
    }
    Write-Host ""
}

function Invoke-Ext ([string]$sub, [string]$name, [string]$ver = "") {
    switch ($sub.ToLower()) {
        { $_ -in "list", "ls" } { Ext-List }
        "loaded"                { Ext-Loaded }
        "enable"  { if ($name) { Edit-IniExtension $name $true  } else { Write-Err "Usage: phpvm ext enable <name>"   } }
        "disable" { if ($name) { Edit-IniExtension $name $false } else { Write-Err "Usage: phpvm ext disable <name>" } }
        "install" {
            if (-not $name) { Write-Err "Usage: phpvm ext install <name> [version]"; return }
            if ($name.ToLower() -eq "xdebug") { Install-XDebug }
            else { Install-PECLExt $name $ver }
        }
        "info"    { if ($name) { Ext-Info $name } else { Write-Err "Usage: phpvm ext info <name>" } }
        "laravel" { Ext-Laravel $name }
        default   { Show-ExtHelp }
    }
}

# ==============================================================================
#  HELP
# ==============================================================================

function Show-ExtHelp {
    Write-Host @"

  phpvm ext - Extension Manager
  ---------------------------------------------------------

  phpvm ext list                   Bundled extensions (ON/OFF)
  phpvm ext loaded                 Loaded extensions (php -m)
  phpvm ext enable  <name>         Enable a bundled extension
  phpvm ext disable <name>         Disable an extension
  phpvm ext install <name>         Install PECL extension
  phpvm ext install <name> <ver>   Install specific PECL version
  phpvm ext install xdebug         Install XDebug (xdebug.org)
  phpvm ext info    <name>         Extension details
  phpvm ext laravel                Enable all Laravel extensions (full)
  phpvm ext laravel minimal        Enable only required Laravel extensions
  phpvm ext laravel full           Enable required + recommended + Redis

  Common extensions:
    phpvm ext enable mbstring       phpvm ext enable curl
    phpvm ext enable pdo_mysql      phpvm ext enable zip
    phpvm ext install redis         phpvm ext install imagick
    phpvm ext install xdebug        phpvm ext install mongodb

"@ -ForegroundColor Cyan
}

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

function Show-Help {
    Write-Host @"

  phpvm $PHPVM_VERSION - PHP Version Manager for Windows
  ---------------------------------------------------------

  VERSION MANAGEMENT
    phpvm install   <version>      Download & install a PHP version
                                     --no-use     install without switching to it
                                     --no-cacert  skip CA bundle configuration
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php.exe
    phpvm ini                      Open active php.ini in Notepad
    phpvm cacert [status|update]   Manage the shared CA bundle (HTTPS/TLS)

  COMPOSER
    phpvm composer                 Install Composer for active PHP version

  AUTO-SWITCH (.phpvmrc)
    phpvm auto                     Switch to the version named in .phpvmrc
    phpvm hook install             Install the PowerShell prompt hook
    phpvm hook uninstall           Remove the prompt hook
    phpvm hook status              Check whether the hook is installed

  SELF UPDATE
    phpvm upgrade                  Upgrade phpvm to latest version
    phpvm version                  Show current phpvm version

  LARAVEL QUICK SETUP
    phpvm ext laravel              Enable all Laravel extensions (full)
    phpvm ext laravel minimal      Required extensions only
    phpvm ext laravel full         Required + recommended + Redis

  EXTENSION MANAGEMENT
    phpvm ext list                 Show all bundled extensions
    phpvm ext loaded               Show loaded extensions
    phpvm ext enable  <name>       Enable a bundled extension
    phpvm ext disable <name>       Disable an extension
    phpvm ext install <name>       Install from PECL / xdebug.org
    phpvm ext info    <name>       Extension details
    phpvm ext help                 Extension command reference

  EXAMPLES
    phpvm install 8.3.0
    phpvm install 8.1.29
    phpvm use 8.3.0
    phpvm ext enable mbstring
    phpvm ext enable pdo_mysql
    phpvm ext install redis
    phpvm ext install xdebug

  Home: $PHPVM_DIR

"@ -ForegroundColor Cyan
}

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


# -- Did-you-mean (unknown command handling) -----------------------------------
# Iterative Levenshtein distance (two-row, O(n) memory).
function Get-Levenshtein ([string]$a, [string]$b) {
    $la = $a.Length; $lb = $b.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    $row = 0..$lb
    for ($i = 1; $i -le $la; $i++) {
        $prev = $row[0]
        $row[0] = $i
        for ($j = 1; $j -le $lb; $j++) {
            $cur  = $row[$j]
            $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $del  = $row[$j] + 1
            $ins  = $row[$j - 1] + 1
            $sub  = $prev + $cost
            $row[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
            $prev = $cur
        }
    }
    return $row[$lb]
}

# Unknown command: suggest the nearest match instead of dumping the full help.
function Invoke-Unknown ([string]$cmd) {
    $cmds = @("install","use","list","ls","current","uninstall","remove",
              "which","ini","fix-ini","cacert","ext","composer","auto","hook",
              "upgrade","update","version","help")
    $best = ""; $bestd = 99
    foreach ($c in $cmds) {
        $d = Get-Levenshtein $cmd.ToLower() $c
        if ($d -lt $bestd) { $bestd = $d; $best = $c }
    }
    Write-Err "'$cmd' is not a phpvm command."
    if ($bestd -le 2) { Write-Dim "Did you mean '$best'?" }
    Write-Dim "Run 'phpvm help' to see all commands."
}

# Tests dot-source this file and set $env:PHPVM_NO_ENTRY=1 to skip the entry point.
if (-not $env:PHPVM_NO_ENTRY) {
    Initialize-PHPVM

    $skipUpdateFor = @("", "help", "--help", "version", "-v", "list", "ls", "current", "which", "ini", "auto", "hook")
    if ($Command.ToLower() -notin $skipUpdateFor) {
        Check-PHPVMUpdate
    }

    switch ($Command.ToLower()) {
        "install"                       { Invoke-Install   $SubOrVer $Arg2 }
        "use"                           { Invoke-Use       $SubOrVer }
        { $_ -in "list", "ls" }         { Invoke-List }
        "current"                       { Invoke-Current }
        { $_ -in "uninstall", "remove" }{ Invoke-Uninstall $SubOrVer }
        "which"                         { Invoke-Which }
        "ini"                           { Invoke-Ini }
        "fix-ini"                       { Invoke-FixIni }
        "cacert"                        { Invoke-Cacert  $SubOrVer }
        "ext"                           { Invoke-Ext $SubOrVer $Arg2 $Arg3 }
        "auto"                          { Invoke-Auto }
        "hook"                          { Invoke-Hook $SubOrVer }
        "composer"                      { Invoke-Composer }
        { $_ -in "upgrade", "update" }  { Invoke-Upgrade }
        { $_ -in "version", "-v" }      { Write-Ok "phpvm $PHPVM_VERSION" }
        { $_ -in "help", "--help" }     { Show-Help }
        ""                              { Show-Help }
        default                         { Invoke-Unknown $Command }
    }
}
