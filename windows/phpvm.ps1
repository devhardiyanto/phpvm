# ==============================================================================
#  phpvm.ps1 — PHP Version Manager for Windows
#  Compatible with: CMD (via phpvm.cmd shim) and PowerShell
#  Repo: https://github.com/devhardiyanto/phpvm
# ==============================================================================

param(
    [Parameter(Position = 0)] [string]$Command  = "",
    [Parameter(Position = 1)] [string]$SubOrVer = "",
    [Parameter(Position = 2)] [string]$Arg2     = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ─────────────────────────────────────────────────────────────────
$PHPVM_VERSION = "1.4.1"
$PHPVM_DIR     = if ($env:PHPVM_DIR) { $env:PHPVM_DIR } else { "$env:USERPROFILE\.phpvm" }
$VERSIONS_DIR  = "$PHPVM_DIR\versions"
$CURRENT_LINK  = "$PHPVM_DIR\current"
$PHPVM_BIN     = "$PHPVM_DIR\bin"

# ── Update checker (once per day, via version.txt) ───────────────────────────
$PHPVM_UPDATE_URL   = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
$PHPVM_LAST_CHECK   = "$PHPVM_DIR\.last_update_check"
$PHPVM_CHECK_INTERVAL = 86400  # 24 hours in seconds

function Check-PHPVMUpdate {
    # Skip if no internet or in CI environments
    if ($env:CI -or $env:PHPVM_NO_UPDATE_CHECK) { return }

    # Only check once per day
    if (Test-Path $PHPVM_LAST_CHECK) {
        $lastCheck = (Get-Item $PHPVM_LAST_CHECK).LastWriteTime
        $elapsed   = (Get-Date) - $lastCheck
        if ($elapsed.TotalSeconds -lt $PHPVM_CHECK_INTERVAL) { return }
    }

    # Update timestamp first (avoid hammering if fetch is slow)
    [System.IO.File]::WriteAllText($PHPVM_LAST_CHECK, (Get-Date).ToString())

    try {
        $ProgressPreference = "SilentlyContinue"
        $latest = (Invoke-WebRequest -Uri $PHPVM_UPDATE_URL -UseBasicParsing -TimeoutSec 3).Content.Trim()

        if ([string]::IsNullOrEmpty($latest)) { return }

        # Compare semantic versions
        $current = [version]$PHPVM_VERSION
        $remote  = [version]$latest

        if ($remote -gt $current) {
            Write-Host ""
            Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor Yellow
            Write-Host "  │  phpvm update available: $PHPVM_VERSION → $latest" -ForegroundColor Yellow
            Write-Host "  │  Get it: https://github.com/devhardiyanto/phpvm  │" -ForegroundColor Yellow
            Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor Yellow
            Write-Host ""
        }
    } catch {
        # Silently ignore — no internet, timeout, etc.
    }
}


function Write-Ok   ($m) { Write-Host "  $m" -ForegroundColor Green  }
function Write-Err  ($m) { Write-Host "  [error] $m" -ForegroundColor Red    }
function Write-Step ($m) { Write-Host "  > $m" -ForegroundColor Cyan   }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Dim  ($m) { Write-Host "  $m" -ForegroundColor DarkGray }

# ── Init ──────────────────────────────────────────────────────────────────────
function Initialize-PHPVM {
    # Force TLS 1.2 — GitHub blocks older TLS versions
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($d in @($PHPVM_DIR, $VERSIONS_DIR, $PHPVM_BIN)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

# ── PHP build metadata ────────────────────────────────────────────────────────
# Helper: run php -r and strip any Warning/Notice lines from output
function Invoke-PHP ([string]$exe, [string]$code) {
    $out = & $exe -r $code 2>$null
    # Filter out lines that are PHP warnings/notices bleeding into stdout
    $clean = $out | Where-Object { $_ -notmatch "^(PHP )?(Warning|Notice|Deprecated|Fatal|Parse)" }
    return ($clean -join "").Trim()
}

function Get-PHPBuildInfo ([string]$phpExe = "") {
    if (-not $phpExe) {
        if (Test-Path "$CURRENT_LINK\php.exe") { $phpExe = "$CURRENT_LINK\php.exe" }
        else { throw "No active PHP version. Run: phpvm use <version>" }
    }

    # php -i also leaks warnings to stdout on some Windows builds — filter them too
    $raw  = (& $phpExe -i 2>$null) | Where-Object { $_ -notmatch "^(PHP )?(Warning|Notice|Deprecated)" }

    $version = Invoke-PHP $phpExe "echo PHP_VERSION;"
    # Extra safety: extract only the semver part in case anything leaked through
    if ($version -match '(\d+\.\d+\.\d+)') { $version = $Matches[1] }
    $short = $version -replace '^(\d+\.\d+)\..*', '$1'

    $tsLine = ($raw | Select-String "Thread Safety" | Select-Object -First 1).ToString()
    $isTS   = $tsLine -match "enabled"

    $compLine = ($raw | Select-String "Compiler" | Select-Object -First 1).ToString()
    $vs = switch -Regex ($compLine) {
        "MSVC17|VS17" { "vs17"; break }
        "MSVC16|VS16" { "vs16"; break }
        "MSVC15|VS15" { "vs15"; break }
        default        { Get-VSVersion $version }  # fallback: derive from version number
    }

    # ExtDir: always derive from PHP exe location — don't trust php.ini
    # which may still point to a system PHP (e.g. C:\php\ext)
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


# ── Resolve PHP download URL ──────────────────────────────────────────────────
# VS version mapping (based on windows.php.net actual filenames):
#   PHP 7.x        → vc15
#   PHP 8.0 - 8.3  → vs16
#   PHP 8.4+       → vs17
function Get-VSVersion ([string]$ver) {
    $major = [int]($ver -split '\.')[0]
    $minor = [int]($ver -split '\.')[1]
    if ($major -eq 7)                          { return "vc15" }
    if ($major -eq 8 -and $minor -le 3)        { return "vs16" }
    if ($major -eq 8 -and $minor -ge 4)        { return "vs17" }
    return "vs17"  # default for future versions
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
            $req.Method = "HEAD"
            $res = $req.GetResponse()
            $res.Close()
            return $url
        } catch { }
    }
    return $null
}

# ── Junction helpers ──────────────────────────────────────────────────────────
function Get-CurrentVersion {
    if (-not (Test-Path $CURRENT_LINK)) { return $null }
    $item = Get-Item $CURRENT_LINK -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        return Split-Path $item.Target -Leaf
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

# ── Download helper ───────────────────────────────────────────────────────────
function Invoke-Download ([string]$url, [string]$dest) {
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

function Test-URLExists ([string]$url) {
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Method = "HEAD"
        $res = $req.GetResponse()
        $res.Close()
        return $true
    } catch { return $false }
}

# ==============================================================================
#  CORE COMMANDS
# ==============================================================================

function Invoke-Install ([string]$ver) {
    if (-not $ver) { Write-Err "Usage: phpvm install <version>  (e.g. phpvm install 8.3.0)"; return }

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

    Write-Step "Extracting ..."
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Expand-Archive -Path $tempFile -DestinationPath $targetDir -Force
    Remove-Item $tempFile -Force

    # Bootstrap php.ini from template
    if (-not (Test-Path "$targetDir\php.ini")) {
        $src = @("$targetDir\php.ini-development", "$targetDir\php.ini-production") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($src) { Copy-Item $src "$targetDir\php.ini" }
    }

    # Fix extension_dir in php.ini to point to THIS version's ext folder
    $ini = "$targetDir\php.ini"
    if (Test-Path $ini) {
        $content = Get-Content $ini -Raw
        # Replace commented or wrong extension_dir with correct absolute path
        $extPath = "$targetDir\ext"
        $content = $content -replace '(?m)^;?\s*extension_dir\s*=.*$', "extension_dir = `"$extPath`""
        $content | Set-Content $ini -NoNewline
    }

    Write-Ok "PHP $ver installed successfully."
    Write-Dim "Activate with: phpvm use $ver"
}

function Invoke-Use ([string]$ver) {
    if (-not $ver) { Write-Err "Usage: phpvm use <version>"; return }

    $targetDir = "$VERSIONS_DIR\$ver"
    if (-not (Test-Path $targetDir)) {
        Write-Err "PHP $ver is not installed. Run: phpvm install $ver"
        return
    }

    Remove-Junction $CURRENT_LINK
    cmd /c mklink /J `"$CURRENT_LINK`" `"$targetDir`" | Out-Null

    # Persist CURRENT_LINK in user PATH (idempotent)
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User") ?? ""
    $parts    = $userPath -split ";" | Where-Object { $_ -and $_ -ne $CURRENT_LINK }
    $newPath  = (@($CURRENT_LINK) + $parts -join ";") -replace ";{2,}", ";"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

    # Update current session immediately
    if ($env:PATH -notlike "*$CURRENT_LINK*") { $env:PATH = "$CURRENT_LINK;$env:PATH" }

    Write-Ok "Now using PHP $ver"
    try { & "$CURRENT_LINK\php.exe" --version 2>$null } catch {}
    Write-Warn "Restart your terminal if 'php -v' still shows the previous version."
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
        try { & "$CURRENT_LINK\php.exe" --version 2>$null } catch {}
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
    Write-Host "  ─────────────────────────────"
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
    Write-Host "  Loaded extensions — PHP $($info.Version):" -ForegroundColor Cyan
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

    # Match: optional semicolons, then extension=name or extension=php_name.dll
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
        $html = (Invoke-WebRequest -Uri "https://windows.php.net/downloads/pecl/releases/$extName/" -UseBasicParsing).Content
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

    Write-Step "Extracting ..."
    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

    $dll = Get-ChildItem $tempExtract -Filter "php_$extName.dll" -Recurse | Select-Object -First 1
    if (-not $dll) { Write-Err "php_$extName.dll not found in archive."; return }

    Copy-Item $dll.FullName $dllDest -Force
    Write-Ok "Installed: php_$extName.dll"

    # Copy dependency DLLs to PHP root
    $phpRoot = Split-Path $info.Exe -Parent
    Get-ChildItem $tempExtract -Filter "*.dll" |
        Where-Object { $_.Name -ne "php_$extName.dll" } |
        ForEach-Object {
            $dep = "$phpRoot\$($_.Name)"
            if (-not (Test-Path $dep)) {
                Copy-Item $_.FullName $dep -Force
                Write-Dim "Dependency: $($_.Name) -> PHP root"
            }
        }

    Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Done. Enable with: phpvm ext enable $extName"
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
        $html    = (Invoke-WebRequest -Uri "https://xdebug.org/files/" -UseBasicParsing).Content
        $pattern = "php_xdebug-([\d.]+)-$phpShort-$vs-$archSuffix\.dll"
        $matches = [regex]::Matches($html, $pattern)

        if (-not $matches.Count) {
            $archSuffix = if ($ts -eq "ts") { "nts-x86_64" } else { "x86_64" }
            $pattern    = "php_xdebug-([\d.]+)-$phpShort-$vs-$archSuffix\.dll"
            $matches    = [regex]::Matches($html, $pattern)
        }

        if (-not $matches.Count) {
            Write-Err "No XDebug DLL found for PHP $phpShort / $vs."
            Write-Dim "Use the wizard: https://xdebug.org/wizard"
            return
        }

        $xdVer   = ($matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
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
    Copy-Item $tempDll $dllDest -Force
    Remove-Item $tempDll -Force

    # Append xdebug block to php.ini if not already present
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

    # Extensions bundled with PHP (just need enable in php.ini)
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
        "opcache"       # bytecode cache — required in production
        "pdo_pgsql"     # PostgreSQL driver
        "pgsql"         # PostgreSQL native functions
        "sockets"       # Laravel Reverb / WebSocket / queue worker
    )

    # PECL extensions (need download + enable)
    $peclFull = @(
        "redis"         # Redis cache, session, queue driver
    )

    $enableList  = $bundledMinimal
    $peclList    = @()

    if ($preset -ne "minimal") {
        $enableList += $bundledFull
        $peclList   += $peclFull
    }

    # ── Banner ────────────────────────────────────────────────
    $label = if ($preset -eq "minimal") { "minimal" } else { "full" }
    Write-Host ""
    Write-Host "  Laravel extension setup ($label) — PHP $($info.Version)" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    # ── Step 1: Enable bundled extensions ────────────────────
    Write-Host "  [1/2] Enabling bundled extensions ..." -ForegroundColor Yellow
    $extDir = $info.ExtDir

    foreach ($ext in $enableList) {
        $dllPath = "$extDir\php_$ext.dll"

        # Skip if DLL doesn't exist (e.g. pdo_pgsql not shipped in some builds)
        if (-not (Test-Path $dllPath)) {
            Write-Host "       skip  $ext  (DLL not found in this PHP build)" -ForegroundColor DarkGray
            continue
        }

        $loaded = (& $info.Exe -m 2>$null) | ForEach-Object { $_.Trim().ToLower() }
        if ($loaded -contains $ext.ToLower()) {
            Write-Host ("       {0,-18} already ON" -f $ext) -ForegroundColor DarkGray
        } else {
            Edit-IniExtension $ext $true
        }
    }

    # ── Step 2: PECL extensions ───────────────────────────────
    if ($peclList.Count -gt 0) {
        Write-Host ""
        Write-Host "  [2/2] Installing PECL extensions ..." -ForegroundColor Yellow
        foreach ($ext in $peclList) {
            $dllPath = "$extDir\php_$ext.dll"
            if (Test-Path $dllPath) {
                $loaded = (& $info.Exe -m 2>$null) | ForEach-Object { $_.Trim().ToLower() }
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

    # ── Summary ───────────────────────────────────────────────
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

function Invoke-Ext ([string]$sub, [string]$name) {
    switch ($sub.ToLower()) {
        { $_ -in "list", "ls" } { Ext-List }
        "loaded"                { Ext-Loaded }
        "enable"  { if ($name) { Edit-IniExtension $name $true  } else { Write-Err "Usage: phpvm ext enable <name>"   } }
        "disable" { if ($name) { Edit-IniExtension $name $false } else { Write-Err "Usage: phpvm ext disable <name>" } }
        "install" {
            if (-not $name) { Write-Err "Usage: phpvm ext install <name> [version]"; return }
            if ($name.ToLower() -eq "xdebug") { Install-XDebug }
            else { Install-PECLExt $name $Arg2 }
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

  phpvm ext — Extension Manager
  ─────────────────────────────────────────────────────────

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
    # 1. Ensure openssl is enabled (required for https)
    $info = Get-PHPBuildInfo
    $loaded = (& $info.Exe -m 2>$null) | ForEach-Object { $_.Trim().ToLower() }
    if ($loaded -notcontains "openssl") {
        Write-Step "Enabling openssl extension (required for Composer) ..."
        Edit-IniExtension "openssl" $true
        Write-Warn "openssl enabled. If Composer install fails, restart terminal first then re-run 'phpvm composer'."
    }

    # 2. Determine install location — PHP version dir so each version has its own composer
    $phpRoot    = Split-Path $info.Exe -Parent
    $composerPhar = "$phpRoot\composer.phar"
    $composerBat  = "$phpRoot\composer.bat"

    if (Test-Path $composerBat) {
        Write-Warn "Composer already installed at $composerBat"
        Write-Dim "Run: composer --version"
        return
    }

    # 3. Download installer and verify hash
    $installerUrl  = "https://getcomposer.org/installer"
    $installerFile = "$env:TEMP\composer-setup.php"
    $sigUrl        = "https://composer.github.io/installer.sig"

    Write-Step "Downloading Composer installer ..."
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerFile -UseBasicParsing
        $expectedHash = (Invoke-WebRequest -Uri $sigUrl -UseBasicParsing).Content.Trim()
    } catch {
        Write-Err "Download failed: $_"
        return
    }

    # 4. Verify SHA-384 hash
    Write-Step "Verifying installer integrity ..."
    $actualHash = (& $info.Exe -r "echo hash_file('sha384', '$($installerFile -replace '\\','\\\\')');")
    if ($actualHash -ne $expectedHash) {
        Write-Err "Hash mismatch! Installer may be corrupt or tampered."
        Remove-Item $installerFile -Force
        return
    }
    Write-Ok "Hash verified."

    # 5. Run installer — outputs composer.phar to current dir, move to PHP root
    Write-Step "Installing Composer ..."
    Push-Location $phpRoot
    & $info.Exe $installerFile --quiet
    Pop-Location

    if (-not (Test-Path $composerPhar)) {
        Write-Err "composer.phar not created. Check PHP error output above."
        Remove-Item $installerFile -Force
        return
    }

    Remove-Item $installerFile -Force

    # 6. Create composer.bat shim so 'composer' works globally from CMD + PS
    $bat = @"
@echo off
php "%~dp0composer.phar" %*
"@
    $bat | Set-Content $composerBat -Encoding ASCII
    Write-Ok "Composer installed!"
    Write-Ok "  phar : $composerPhar"
    Write-Ok "  shim : $composerBat"
    Write-Host ""
    & $info.Exe "$phpRoot\composer.phar" --version
    Write-Host ""
    Write-Dim "Note: composer.bat is inside the PHP version folder."
    Write-Dim "If you switch PHP version, run 'phpvm composer' again for that version."
}

function Show-Help {
    Write-Host @"

  phpvm $PHPVM_VERSION — PHP Version Manager for Windows
  ─────────────────────────────────────────────────────────

  VERSION MANAGEMENT
    phpvm install   <version>      Download & install a PHP version
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php.exe
    phpvm ini                      Open active php.ini in Notepad

  COMPOSER
    phpvm composer                 Install Composer for active PHP version

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

    # Also ensure extension_dir line exists if it was missing entirely
    if ($content -notmatch 'extension_dir\s*=') {
        Add-Content $ini "`nextension_dir = `"$extPath`""
        Write-Ok "Added extension_dir -> $extPath"
    }

    Write-Dim "Verify: phpvm ext list"
}


function Invoke-Upgrade {
    $scriptUrl  = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/windows/phpvm.ps1"
    $versionUrl = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
    $scriptDest = "$PHPVM_DIR\phpvm.ps1"

    Write-Step "Checking latest version ..."
    try {
        $ProgressPreference = "SilentlyContinue"
        $latest = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -TimeoutSec 5).Content.Trim()
    } catch {
        Write-Err "Could not reach GitHub. Check your connection."
        return
    }

    if ([version]$latest -le [version]$PHPVM_VERSION) {
        Write-Ok "Already up to date. (phpvm $PHPVM_VERSION)"
        return
    }

    Write-Step "Upgrading phpvm $PHPVM_VERSION → $latest ..."

    # Backup current script
    $backup = "$PHPVM_DIR\phpvm.ps1.bak"
    Copy-Item $scriptDest $backup -Force
    Write-Dim "Backup saved: $backup"

    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptDest -UseBasicParsing
        Unblock-File $scriptDest
        Write-Ok "phpvm upgraded to $latest!"
        Write-Dim "Restart your terminal to use the new version."
    } catch {
        # Rollback on failure
        Write-Err "Upgrade failed: $_"
        Copy-Item $backup $scriptDest -Force
        Write-Warn "Rolled back to previous version."
    }
}


Initialize-PHPVM
Check-PHPVMUpdate

switch ($Command.ToLower()) {
    "install"                       { Invoke-Install   $SubOrVer }
    "use"                           { Invoke-Use       $SubOrVer }
    { $_ -in "list", "ls" }         { Invoke-List }
    "current"                       { Invoke-Current }
    { $_ -in "uninstall", "remove" }{ Invoke-Uninstall $SubOrVer }
    "which"                         { Invoke-Which }
    "ini"                           { Invoke-Ini }
    "fix-ini"                       { Invoke-FixIni }
    "ext"                           { Invoke-Ext $SubOrVer $Arg2 }
    "composer"                      { Invoke-Composer }
    { $_ -in "upgrade", "update" }  { Invoke-Upgrade }
    { $_ -in "version", "-v" }      { Write-Ok "phpvm $PHPVM_VERSION" }
    { $_ -in "help", "--help" }     { Show-Help }
    default                         { Show-Help }
}
