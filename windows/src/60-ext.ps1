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
        if ($existing -notmatch "(?m)^\s*zend_extension\s*=\s*xdebug") {
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
    echo 'Version : ' . (`$r->getVersion() ?? 'n/a') . PHP_EOL;
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
