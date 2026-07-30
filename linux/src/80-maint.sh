# ==============================================================================
#  phpvm doctor  — read-only health check (never mutates state)
# ==============================================================================
phpvm_doctor() {
    echo ""
    echo -e "  \033[36mphpvm doctor — environment health check\033[0m"
    echo -e "  \033[36m─────────────────────────────────────────────────────────\033[0m"

    local ok=0 warn=0
    _dok()  { printf '  \033[32m[ok]   %s\033[0m\n' "$*"; ok=$((ok+1)); }
    _dwarn(){ printf '  \033[33m[warn] %s\033[0m\n' "$*"; warn=$((warn+1)); }

    # 1. Active version + symlink health.
    local cur
    cur=$(_phpvm_current_version)
    if [[ -n "$cur" ]]; then
        _dok "Active PHP version: $cur"
    else
        _dwarn "No active PHP version. Run: phpvm use <version>"
    fi

    # 2. PATH: whichever php resolves first is what runs - but a second PHP
    #    further down PATH still matters, because it is what comes back the
    #    moment phpvm's bin drops off (a distro upgrade rewriting the rc, a
    #    shell that never sourced phpvm.sh). `command -v` only ever reports the
    #    winner, so walk PATH ourselves.
    #
    #    Split with parameter expansion rather than tr/awk: this is the check
    #    that tells you PATH is broken, so it must not itself depend on finding
    #    coreutils there. It also sidesteps zsh, where `for d in $PATH` does not
    #    split on colons at all.
    local php_paths="" rest="$PATH" d
    while [[ -n "$rest" ]]; do
        d="${rest%%:*}"
        if [[ "$d" == "$rest" ]]; then rest=""; else rest="${rest#*:}"; fi
        [[ -n "$d" && -x "$d/php" ]] || continue
        case ":$php_paths:" in *":$d/php:"*) continue ;; esac   # PATH may repeat
        php_paths="${php_paths:+$php_paths:}$d/php"
    done

    if [[ -z "$php_paths" ]]; then
        _dwarn "No 'php' on PATH. Run: phpvm use <version> (and source phpvm.sh in your rc)."
    else
        local first="${php_paths%%:*}"
        case "$first" in
            "$PHPVM_CURRENT"/*|"$PHPVM_BIN"/*|"$PHPVM_VERSIONS"/*)
                _dok "'php' resolves to phpvm: $first" ;;
            *)
                _dwarn "'php' resolves to a non-phpvm install: $first"
                _dim "Ensure $PHPVM_DIR is sourced in your shell rc, then open a new shell." ;;
        esac

        local other="" p
        rest="$php_paths"
        while [[ -n "$rest" ]]; do
            p="${rest%%:*}"
            if [[ "$p" == "$rest" ]]; then rest=""; else rest="${rest#*:}"; fi
            case "$p" in
                # `:` rather than an empty body - bash 3.2 on macOS is fussy
                # about case arms, which is what broke the first cut of this.
                "$PHPVM_CURRENT"/*|"$PHPVM_BIN"/*|"$PHPVM_VERSIONS"/*) : ;;
                *) other="$p"; break ;;
            esac
        done
        if [[ -n "$other" && "$other" != "$first" ]]; then
            _dwarn "Another PHP on PATH: $other"
            _dim "It shadows phpvm whenever phpvm's bin is not first. Remove it or reorder PATH."
        fi
    fi

    # 3. extension_dir must match what the active build was compiled with.
    #    Checking the directory merely exists passes an ini left pointing at a
    #    different version - the exact case fix-ini exists to repair. Go through
    #    the version's own binary, not PATH: check 2 may have just told us PATH
    #    resolves somewhere else entirely.
    if [[ -n "$cur" ]]; then
        local doc_php="$PHPVM_VERSIONS/$cur/bin/php"
        if [[ ! -x "$doc_php" ]]; then
            _dwarn "php binary missing for active version: $doc_php"
        else
            local ext_dir built_dir
            ext_dir=$("$doc_php" -r "echo ini_get('extension_dir');" 2>/dev/null)
            built_dir=$("$doc_php" -r "echo PHP_EXTENSION_DIR;" 2>/dev/null)
            if [[ -z "$ext_dir" ]]; then
                _dwarn "No extension_dir set in the active php.ini."
                _dim "Fix with: phpvm fix-ini"
            elif [[ "${ext_dir%/}" != "${built_dir%/}" ]]; then
                _dwarn "extension_dir mismatch: '$ext_dir' != '$built_dir'"
                _dim "Fix with: phpvm fix-ini"
            elif [[ ! -d "$ext_dir" ]]; then
                _dwarn "extension_dir does not exist: $ext_dir"
                _dim "Fix with: phpvm fix-ini"
            else
                _dok "extension_dir matches active build."
            fi
        fi
    fi

    # 4. OpenSSL in PHP (HTTPS for composer / ext downloads).
    if [[ -n "$cur" ]] && php -m 2>/dev/null | grep -qi '^openssl$'; then
        _dok "openssl extension loaded (HTTPS OK)."
    elif [[ -n "$cur" ]]; then
        _dwarn "openssl not loaded — composer/HTTPS may fail."
        _dim "Enable with: phpvm ext enable openssl"
    fi

    # 5. Build toolchain (needed for future installs — build from source).
    local missing=()
    local t
    for t in gcc make autoconf bison re2c pkg-config; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        _dok "Build toolchain present (install/build ready)."
    else
        _dwarn "Missing build tools: ${missing[*]}"
        _dim "See: phpvm deps"
    fi

    # 6. Host OpenSSL vs what is still buildable here. `install` already refuses
    #    PHP <8.1 on OpenSSL 3 (_phpvm_check_openssl_compat), but only once you
    #    have waited for a download - doctor should say it upfront.
    local host_ssl
    if host_ssl=$(_phpvm_openssl_version) && [[ -n "$host_ssl" ]]; then
        local ssl_major="${host_ssl%%.*}"
        if [[ "$ssl_major" =~ ^[0-9]+$ ]] && (( ssl_major >= 3 )); then
            _dwarn "OpenSSL $host_ssl - PHP 8.0 and older cannot be built on this host."
            _dim "Installed versions keep working; only new builds below 8.1 are refused."
        else
            _dok "OpenSSL $host_ssl (all supported PHP versions buildable)."
        fi
    else
        _dim "  OpenSSL version could not be determined - build compatibility unknown."
    fi

    echo ""
    if [[ $warn -eq 0 ]]; then
        _ok "All checks passed ($ok ok)."
    else
        _warn "$warn warning(s), $ok ok. See fixes above."
    fi
    echo ""

    unset -f _dok _dwarn 2>/dev/null
}

# ==============================================================================
#  FIX-INI (sync extension_dir in active php.ini)
# ==============================================================================
phpvm_fix_ini() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local target_dir="$PHPVM_VERSIONS/$cur"
    local php_bin="$target_dir/bin/php"
    local ini="$target_dir/etc/php.ini"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }
    [[ ! -f "$ini"     ]] && { _err "php.ini not found: $ini"; return 1; }

    # Resolve the real extension_dir compiled into PHP.
    local ext_path
    ext_path=$("$php_bin" -r "echo PHP_EXTENSION_DIR;" 2>/dev/null)
    [[ -z "$ext_path" ]] && { _err "Could not resolve PHP_EXTENSION_DIR."; return 1; }

    if grep -qE '^\s*;?\s*extension_dir\s*=' "$ini"; then
        # In-place edit, escaping path for sed (/ in path).
        local esc
        esc=$(printf '%s' "$ext_path" | sed 's:[\\/&]:\\&:g')
        sed -i.bak -E "s|^[[:space:]]*;?[[:space:]]*extension_dir[[:space:]]*=.*$|extension_dir = \"$esc\"|" "$ini"
        rm -f "$ini.bak"
        _ok "Fixed extension_dir → $ext_path"
    else
        printf '\nextension_dir = "%s"\n' "$ext_path" >> "$ini"
        _ok "Added extension_dir → $ext_path"
    fi

    _dim "Verify: phpvm ext list"
}

# ==============================================================================
#  SELF UPDATE
# ==============================================================================
phpvm_upgrade() {
    local script_url="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/linux/phpvm.sh"
    local version_url="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
    local script_dest="$PHPVM_DIR/phpvm.sh"
    local backup="$PHPVM_DIR/phpvm.sh.bak"

    _step "Checking latest version ..."

    local latest
    if command -v curl &>/dev/null; then
        latest=$(curl -fsSL --max-time 5 "$version_url" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget &>/dev/null; then
        latest=$(wget -qO- --timeout=5 "$version_url" 2>/dev/null | tr -d '[:space:]')
    else
        _err "curl or wget is required."
        return 1
    fi

    if [[ -z "$latest" ]]; then
        _err "Could not reach GitHub. Check your connection."
        return 1
    fi

    # Compare versions
    local newer
    newer=$(printf '%s\n%s' "$PHPVM_VERSION" "$latest" | sort -V | tail -1)
    if [[ "$newer" == "$PHPVM_VERSION" && "$latest" == "$PHPVM_VERSION" ]]; then
        _ok "Already up to date. (phpvm $PHPVM_VERSION)"
        return 0
    fi

    _step "Upgrading phpvm $PHPVM_VERSION → $latest ..."

    # Backup
    cp "$script_dest" "$backup"
    _dim "Backup saved: $backup"

    # Download new version
    local tmp="$PHPVM_DIR/phpvm.sh.tmp"
    if command -v curl &>/dev/null; then
        curl -fsSL "$script_url" -o "$tmp" || { _err "Download failed."; return 1; }
    else
        wget -qO "$tmp" "$script_url" || { _err "Download failed."; return 1; }
    fi

    # Verify it looks like a valid phpvm script
    if ! grep -q "PHPVM_VERSION" "$tmp"; then
        _err "Downloaded file seems invalid. Rolling back."
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$script_dest"
    chmod +x "$script_dest"

    _ok "phpvm upgraded to $latest!"
    _dim "Run: source ~/.bashrc  (or restart terminal)"
    _dim "Backup of old version: $backup"
}
