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
