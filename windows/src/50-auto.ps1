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
