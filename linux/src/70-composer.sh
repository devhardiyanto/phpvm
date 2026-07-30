# ==============================================================================
#  COMPOSER (one global composer that follows the active PHP version)
# ==============================================================================
phpvm_composer() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local phar="$PHPVM_DIR/composer.phar"
    local shim="$PHPVM_BIN/composer"

    if [[ -x "$shim" && -f "$phar" ]]; then
        _warn "Composer already installed at $shim"
        _dim "It follows your active PHP version automatically."
        _dim "Run: composer --version"
        return 0
    fi

    # openssl is bundled on most distros' PHP-from-source builds; warn if missing.
    if ! "$php_bin" -r "exit(extension_loaded('openssl') ? 0 : 1);" 2>/dev/null; then
        _warn "openssl extension not loaded; Composer requires it."
        _dim "Enable it then retry: phpvm ext enable openssl"
    fi

    local installer_url="https://getcomposer.org/installer"
    local sig_url="https://composer.github.io/installer.sig"
    local tmp; tmp=$(mktemp -t composer-setup.XXXXXX.php) || { _err "mktemp failed."; return 1; }

    _step "Downloading Composer installer ..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$installer_url" -o "$tmp" || { _err "Download failed."; rm -f "$tmp"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp" "$installer_url" || { _err "Download failed."; rm -f "$tmp"; return 1; }
    else
        _err "curl or wget is required."; rm -f "$tmp"; return 1
    fi

    _step "Verifying installer integrity ..."
    local expected actual
    if command -v curl &>/dev/null; then
        expected=$(curl -fsSL "$sig_url" 2>/dev/null | tr -d '[:space:]')
    else
        expected=$(wget -qO- "$sig_url" 2>/dev/null | tr -d '[:space:]')
    fi
    actual=$("$php_bin" -r "echo hash_file('sha384', '$tmp');" 2>/dev/null)

    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        _err "Hash mismatch! Installer may be corrupt or tampered."
        rm -f "$tmp"
        return 1
    fi
    _ok "Hash verified."

    _step "Installing Composer ..."
    mkdir -p "$PHPVM_BIN"
    (cd "$PHPVM_DIR" && "$php_bin" "$tmp" --quiet --filename=composer.phar) || {
        _err "Composer installer failed."
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"

    [[ ! -f "$phar" ]] && { _err "composer.phar not created at $phar"; return 1; }

    # POSIX shim — execs the *current* PHP, so composer tracks `phpvm use`
    # without reinstalling. Works in bash/zsh/sh.
    cat > "$shim" <<EOF
#!/usr/bin/env sh
exec "$PHPVM_CURRENT/bin/php" "$phar" "\$@"
EOF
    chmod +x "$shim"

    _ok "Composer installed (global)!"
    _ok "  phar : $phar"
    _ok "  shim : $shim"
    echo ""
    "$php_bin" "$phar" --version 2>/dev/null | sed 's/^/  /'
    echo ""
    _dim "Composer follows your active PHP version — no need to re-run after 'phpvm use'."
}
