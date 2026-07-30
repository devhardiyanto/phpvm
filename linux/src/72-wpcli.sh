# ==============================================================================
#  WP-CLI (one global wp that follows the active PHP version)
# ==============================================================================
phpvm_wp_cli() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local phar="$PHPVM_DIR/wp-cli.phar"
    local shim="$PHPVM_BIN/wp"

    if [[ -x "$shim" && -f "$phar" ]]; then
        _warn "WP-CLI already installed at $shim"
        _dim "It follows your active PHP version automatically."
        _dim "Run: wp --version"
        return 0
    fi

    local phar_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
    local hash_url="$phar_url.sha512"

    _step "Downloading WP-CLI ..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$phar_url" -o "$phar" || { _err "Download failed."; rm -f "$phar"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$phar" "$phar_url" || { _err "Download failed."; rm -f "$phar"; return 1; }
    else
        _err "curl or wget is required."; return 1
    fi

    _step "Verifying SHA-512 ..."
    local expected actual
    if command -v curl &>/dev/null; then
        expected=$(curl -fsSL "$hash_url" 2>/dev/null | awk '{print $1}')
    else
        expected=$(wget -qO- "$hash_url" 2>/dev/null | awk '{print $1}')
    fi
    # Hash through PHP itself (always present) — no sha512sum/shasum coreutils
    # split between GNU and BSD/macOS.
    actual=$("$php_bin" -r "echo hash_file('sha512', '$phar');" 2>/dev/null)

    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        _err "SHA-512 mismatch! Phar may be corrupt or tampered."
        rm -f "$phar"
        return 1
    fi
    _ok "SHA-512 verified."

    mkdir -p "$PHPVM_BIN"
    cat > "$shim" <<EOF
#!/usr/bin/env sh
exec "$PHPVM_CURRENT/bin/php" "$phar" "\$@"
EOF
    chmod +x "$shim"

    _ok "WP-CLI installed (global)!"
    _ok "  phar : $phar"
    _ok "  shim : $shim"
    echo ""
    "$php_bin" "$phar" --version 2>/dev/null | sed 's/^/  /'
    echo ""
    _dim "WP-CLI follows your active PHP version — no need to re-run after 'phpvm use'."
}
