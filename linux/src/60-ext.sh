# ==============================================================================
#  EXT COMMANDS
# ==============================================================================

# Everything PHP could load, with its current state - the Windows `ext list`
# shape. The ON side has to come from `php -m` rather than from a directory
# listing, because extensions compiled into the binary (pdo, mbstring, ...) have
# no .so to find; the OFF side is the .so files nothing has switched on yet.
phpvm_ext_list() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local loaded
    loaded=$("$php_bin" -m 2>/dev/null | grep -v '^\[' | grep -v '^[[:space:]]*$' \
        | tr '[:upper:]' '[:lower:]' | sort -u)

    local ext_dir available=""
    ext_dir=$("$php_bin" -r "echo ini_get('extension_dir');" 2>/dev/null)
    if [[ -n "$ext_dir" && -d "$ext_dir" ]]; then
        available=$(find "$ext_dir" -maxdepth 1 -name '*.so' 2>/dev/null \
            | while read -r so; do
                so=$(basename "$so" .so)
                printf '%s\n' "${so#php_}"
              done | tr '[:upper:]' '[:lower:]' | sort -u)
    fi

    echo ""
    echo -e "  \033[36mPHP $cur — extensions:\033[0m"
    echo ""

    local on=0 off=0 name
    while read -r name; do
        [[ -z "$name" ]] && continue
        if printf '%s\n' "$loaded" | grep -qx -- "$name"; then
            printf "    \033[32m%-20s ON\033[0m\n" "$name"
            on=$((on+1))
        else
            printf "    \033[90m%-20s OFF   (.so available)\033[0m\n" "$name"
            off=$((off+1))
        fi
    done <<< "$(printf '%s\n%s\n' "$loaded" "$available" | grep -v '^[[:space:]]*$' | sort -u)"

    echo ""
    _dim "$on ON, $off OFF. Enable: phpvm ext enable <name>"
    echo ""
}

# `php -m` verbatim - what the runtime actually has loaded, nothing inferred.
phpvm_ext_loaded() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    echo ""
    echo -e "  \033[36mPHP $cur — loaded extensions:\033[0m"
    "$php_bin" -m 2>/dev/null | grep -v '^\[' | grep -v '^[[:space:]]*$' | sort | while read -r ext; do
        echo -e "    \033[32m$ext\033[0m"
    done
    echo ""
}

phpvm_ext_install() {
    local name="$1"
    [[ -z "$name" ]] && { _err "Usage: phpvm ext install <name> [version]"; return 1; }

    command -v pecl &>/dev/null || {
        _err "pecl not found. It should be installed with PHP."
        _dim "Try: phpvm use <version> first."
        return 1
    }

    _phpvm_ext_preflight "$name" || return 1

    local ver="${2:-}"
    if [[ -n "$ver" ]]; then
        _step "Installing $name-$ver via PECL ..."
        pecl install "$name-$ver" || {
            _err "Failed to install $name-$ver via PECL."
            _phpvm_ext_runtime_notes "$name"
            return 1
        }
    else
        _step "Installing $name via PECL ..."
        pecl install "$name" || {
            _err "Failed to install $name via PECL."
            _phpvm_ext_runtime_notes "$name"
            return 1
        }
    fi

    _ok "Done. Enable with: phpvm ext enable $name"
    _phpvm_ext_runtime_notes "$name"
}

# Build-time prerequisites for specific extensions. Warn early instead of
# letting `pecl install` fail mid-build with cryptic compiler errors.
_phpvm_ext_preflight() {
    local name="$1"
    case "$name" in
        sqlsrv|pdo_sqlsrv)
            # unixODBC headers (sql.h / sqlext.h) are required to compile sqlsrv.
            if command -v odbc_config &>/dev/null; then return 0; fi
            local inc
            for inc in /usr/include/sql.h /usr/local/include/sql.h \
                       /opt/homebrew/include/sql.h /opt/homebrew/opt/unixodbc/include/sql.h \
                       /usr/local/opt/unixodbc/include/sql.h; do
                [[ -f "$inc" ]] && return 0
            done
            _warn "unixODBC development headers not found — required to build $name."
            local pm
            pm=$(_phpvm_detect_os)
            case "$pm" in
                apt)    _dim "Install: sudo apt-get install -y unixodbc-dev" ;;
                dnf)    _dim "Install: sudo dnf install -y unixODBC-devel" ;;
                yum)    _dim "Install: sudo yum install -y unixODBC-devel" ;;
                pacman) _dim "Install: sudo pacman -S --needed unixodbc" ;;
                zypper) _dim "Install: sudo zypper install -y unixODBC-devel" ;;
                brew)   _dim "Install: brew install unixodbc" ;;
                *)      _dim "Install unixODBC development headers via your package manager." ;;
            esac
            _dim "Then retry: phpvm ext install $name"
            return 1
            ;;
    esac
    return 0
}

# Post-install advisories for extensions that need extra system components.
_phpvm_ext_runtime_notes() {
    local name="$1"
    case "$name" in
        sqlsrv|pdo_sqlsrv)
            echo ""
            _dim "Note: $name also requires the Microsoft ODBC Driver for SQL Server"
            _dim "to actually connect at runtime. Install (one-off, system-wide):"
            _dim "  https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server"
            _dim "Setup guide: https://learn.microsoft.com/sql/connect/php/step-1-configure-development-environment-for-php-development"
            ;;
    esac
}

phpvm_ext_enable() {
    local name="$1"
    [[ -z "$name" ]] && { _err "Usage: phpvm ext enable <name>"; return 1; }

    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "Invalid PHP $cur install: missing executable $php_bin"; return 1; }

    local conf_dir="$PHPVM_VERSIONS/$cur/etc/conf.d"
    local ini_file="$conf_dir/$name.ini"

    mkdir -p "$conf_dir"

    if "$php_bin" -r "exit(extension_loaded('$name') ? 0 : 1);" 2>/dev/null; then
        _warn "$name is already loaded."
        return 0
    fi

    local ext_dir ext_path=""
    ext_dir=$("$php_bin" -r "echo ini_get('extension_dir');" 2>/dev/null)
    for candidate in "$ext_dir/$name.so" "$ext_dir/php_$name.so"; do
        if [[ -f "$candidate" ]]; then
            ext_path="$candidate"
            break
        fi
    done

    if [[ -z "$ext_path" ]]; then
        _err "Extension not found in PHP extension_dir: $name"
        _dim "Install it first: phpvm ext install $name"
        return 1
    fi

    if [[ -f "$ini_file" ]]; then
        _warn "$name.ini already exists in conf.d."
        return 0
    fi

    # Determine if zend_extension (xdebug, opcache) or regular extension
    local prefix="extension"
    case "$name" in xdebug|opcache|ioncube_loader) prefix="zend_extension" ;; esac

    echo "$prefix=$name" > "$ini_file"
    _ok "Enabled: $name  ($ini_file)"
    _dim "Verify: php -m | grep $name"
}

phpvm_ext_disable() {
    local name="$1"
    [[ -z "$name" ]] && { _err "Usage: phpvm ext disable <name>"; return 1; }

    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local conf_dir="$PHPVM_VERSIONS/$cur/etc/conf.d"
    local ini_file="$conf_dir/$name.ini"

    if [[ -f "$ini_file" ]]; then
        rm -f "$ini_file"
        _ok "Disabled: $name  (removed $ini_file)"
    else
        # Try editing main php.ini
        local main_ini="$PHPVM_VERSIONS/$cur/etc/php.ini"
        if [[ -f "$main_ini" ]]; then
            sed -i "s/^\(extension\|zend_extension\)=$name/;\1=$name/" "$main_ini"
            sed -i "s/^\(extension\|zend_extension\)=php_$name\.so/;\1=php_$name.so/" "$main_ini"
            _ok "Disabled: $name  (commented in php.ini)"
        else
            _warn "$name not found in conf.d or php.ini."
        fi
    fi
}

phpvm_ext_info() {
    local name="$1"
    [[ -z "$name" ]] && { _err "Usage: phpvm ext info <name>"; return 1; }

    echo ""
    php -r "
if (extension_loaded('$name')) {
    \$r = new ReflectionExtension('$name');
    echo 'Name    : ' . \$r->getName() . PHP_EOL;
    echo 'Version : ' . (\$r->getVersion() ?? 'n/a') . PHP_EOL;
    \$c = \$r->getClassNames();
    if (\$c) echo 'Classes : ' . implode(', ', \$c) . PHP_EOL;
} else {
    echo 'Not loaded. Run: phpvm ext enable $name' . PHP_EOL;
}
" 2>/dev/null | while read -r line; do echo "  $line"; done
    echo ""
}

phpvm_ext_laravel() {
    local preset="${1:-full}"
    case "$preset" in min|minimal) preset="minimal" ;; *) preset="full" ;; esac

    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local minimal=(openssl pdo pdo_mysql pdo_sqlite mbstring tokenizer xml ctype fileinfo bcmath curl zip sodium)
    local extra=(intl gd exif opcache pdo_pgsql pgsql sockets)
    local pecl=(redis)

    local enable_list=("${minimal[@]}")
    local pecl_list=()
    if [[ "$preset" != "minimal" ]]; then
        enable_list+=("${extra[@]}")
        pecl_list+=("${pecl[@]}")
    fi

    echo ""
    echo -e "  \033[36mLaravel extension setup ($preset) — PHP $cur\033[0m"
    echo -e "  \033[90m─────────────────────────────────────────────────\033[0m"
    echo ""

    local loaded
    loaded=$("$php_bin" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')

    local ext_dir
    ext_dir=$("$php_bin" -r "echo ini_get('extension_dir');" 2>/dev/null)

    echo -e "  \033[33m[1/2] Enabling bundled extensions ...\033[0m"
    for ext in "${enable_list[@]}"; do
        if echo "$loaded" | grep -qx "$ext"; then
            printf "       %-18s already ON\n" "$ext"
            continue
        fi
        # Built-in extensions (e.g. pdo, mbstring) have no .so file; try enable anyway.
        if [[ -n "$ext_dir" && ! -f "$ext_dir/$ext.so" && ! -f "$ext_dir/php_$ext.so" ]]; then
            # Check if it's a static built-in via php -m again (case-insensitive match above already failed)
            printf "       \033[90mskip  %-18s (not built into this PHP)\033[0m\n" "$ext"
            continue
        fi
        if phpvm_ext_enable "$ext" >/dev/null 2>&1; then
            _ok "Enabled: $ext"
        else
            _warn "Could not enable: $ext"
        fi
    done

    if [[ ${#pecl_list[@]} -gt 0 ]]; then
        echo ""
        echo -e "  \033[33m[2/2] PECL extensions ...\033[0m"
        for ext in "${pecl_list[@]}"; do
            if echo "$loaded" | grep -qx "$ext"; then
                printf "       %-18s already ON\n" "$ext"
                continue
            fi
            if [[ -f "$ext_dir/$ext.so" || -f "$ext_dir/php_$ext.so" ]]; then
                phpvm_ext_enable "$ext" >/dev/null 2>&1 && _ok "Enabled: $ext"
            else
                _step "Installing $ext via PECL ..."
                if phpvm_ext_install "$ext"; then
                    phpvm_ext_enable "$ext" >/dev/null 2>&1 && _ok "Enabled: $ext"
                fi
            fi
        done
    fi

    echo ""
    _ok "Done! Verify with: php -m"
    echo ""
    if [[ "$preset" == "minimal" ]]; then
        _dim "For Redis + GD + opcache + intl, run: phpvm ext laravel full"
    else
        _dim "Optional extras:"
        _dim "  phpvm ext install xdebug      # debugger"
        _dim "  phpvm ext install imagick     # advanced image processing"
        _dim "  phpvm composer                # install Composer"
    fi
    echo ""
}

phpvm_ext() {
    local sub="${1:-help}"
    local name="${2:-}"
    local ver="${3:-}"

    case "$sub" in
        list|ls)   phpvm_ext_list ;;
        loaded)    phpvm_ext_loaded ;;
        install)   phpvm_ext_install "$name" "$ver" ;;
        enable)    phpvm_ext_enable  "$name" ;;
        disable)   phpvm_ext_disable "$name" ;;
        info)      phpvm_ext_info    "$name" ;;
        laravel)   phpvm_ext_laravel "$name" ;;
        help|*)    phpvm_ext_help ;;
    esac
}
