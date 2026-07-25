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
