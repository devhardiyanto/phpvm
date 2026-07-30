# Resolve a partial version to the highest published patch on php.net.
#   "8"   -> latest 8.x   (e.g. 8.5.7)
#   "8.3" -> latest 8.3.x (e.g. 8.3.31)
# A full "x.y.z" passes through untouched. Echoes the resolved version on
# success; non-zero exit if nothing matched or the network was unreachable.
_phpvm_resolve_remote() {
    local req="$1"
    [[ "$req" =~ ^[0-9]+$ || "$req" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "$req"; return 0; }

    local major="${req%%.*}"
    local api="https://www.php.net/releases/index.php?json&max=100&version=$major"
    local json
    if command -v curl &>/dev/null; then
        json=$(curl -fsSL --max-time 10 "$api" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        json=$(wget -qO- --timeout=10 "$api" 2>/dev/null)
    fi
    [[ -z "$json" ]] && return 1

    # Top-level JSON keys are "x.y.z" version strings; keep the ones whose
    # prefix matches the request (the (\.|$) guard stops 8.3 matching 8.30.x).
    local match
    match=$(printf '%s\n' "$json" \
        | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' \
        | tr -d '"' \
        | grep -E "^${req//./\\.}(\.|$)" \
        | sort -V | tail -1)
    [[ -n "$match" ]] || return 1
    echo "$match"
}

# Expected SHA-256 for php-<ver>.tar.gz, straight from php.net's release JSON.
# The per-version endpoint returns a "source" array whose entries each carry a
# filename and its sha256; splitting on "{" puts one entry per line so the digest
# next to the .tar.gz filename is the one we pick (never the .xz/.bz2 sibling).
_phpvm_php_sha256() {
    local ver="$1"
    local api="https://www.php.net/releases/index.php?json&version=$ver"
    local json
    if command -v curl &>/dev/null; then
        json=$(curl -fsSL --max-time 10 "$api" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        json=$(wget -qO- --timeout=10 "$api" 2>/dev/null)
    fi
    [[ -z "$json" ]] && return 1

    local sum
    sum=$(printf '%s' "$json" \
        | tr '{' '\n' \
        | grep -F "\"php-$ver.tar.gz\"" \
        | grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' \
        | grep -oE '[0-9a-f]{64}' \
        | head -1)
    [[ -n "$sum" ]] || return 1
    echo "$sum"
}

# Digest a file with whatever the host has. PHP itself is not an option here the
# way it is for the composer/wp-cli phars - this runs *before* any PHP exists.
_phpvm_sha256_file() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

# Verify a downloaded (or cached) tarball. Mismatch is fatal and takes the file
# with it; an unavailable digest or a host with no hashing tool degrades to a
# warning, matching the Windows fallback so an offline mirror or an EOL release
# that php.net no longer lists cannot brick an otherwise valid install.
_phpvm_verify_tarball() {
    local file="$1" ver="$2"

    if [[ -n "${PHPVM_SKIP_HASH:-}" ]]; then
        _dim "Skipping SHA-256 verification (PHPVM_SKIP_HASH is set)."
        return 0
    fi

    local expected
    if ! expected=$(_phpvm_php_sha256 "$ver") || [[ -z "$expected" ]]; then
        _warn "No published SHA-256 for PHP $ver - skipping verification."
        return 0
    fi

    local actual
    if ! actual=$(_phpvm_sha256_file "$file") || [[ -z "$actual" ]]; then
        _warn "No sha256sum/shasum/openssl found - skipping verification."
        return 0
    fi

    if [[ "$actual" != "$expected" ]]; then
        _err "SHA-256 mismatch for $(basename "$file")!"
        _dim "expected: $expected"
        _dim "actual:   $actual"
        _dim "Removing the file. Re-run to download it again."
        rm -f "$file"
        return 1
    fi

    _ok "SHA-256 verified."
    return 0
}
