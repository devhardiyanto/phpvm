# ==============================================================================
#  phpvm use <version>
# ==============================================================================
phpvm_use() {
    local ver="$1"
    [[ -z "$ver" ]] && { _err "Usage: phpvm use <version>"; return 1; }

    local target="$PHPVM_VERSIONS/$ver"
    if [[ ! -d "$target" ]]; then
        _err "PHP $ver is not installed. Run: phpvm install $ver"
        return 1
    fi
    if [[ ! -x "$target/bin/php" ]]; then
        _err "Invalid PHP $ver install: missing executable $target/bin/php"
        return 1
    fi

    # Update symlink
    ln -sfn "$target" "$PHPVM_CURRENT"

    # Update PATH in current shell
    _phpvm_use_path

    _ok "Now using PHP $ver"
    php --version 2>/dev/null | head -1 | sed 's/^/  /'
    # Only nudge if phpvm isn't wired into a shell rc yet — otherwise this is
    # already persistent and the warning is just noise on every `use`.
    _phpvm_in_rc || _warn "To persist across sessions, add to your shell rc: source \"$PHPVM_DIR/phpvm.sh\""
}

# ==============================================================================
#  phpvm list
# ==============================================================================
phpvm_list() {
    echo ""
    if [[ ! -d "$PHPVM_VERSIONS" ]] || [[ -z "$(ls -A "$PHPVM_VERSIONS" 2>/dev/null)" ]]; then
        _dim "No PHP versions installed."
        echo ""
        return 0
    fi

    local current
    current=$(_phpvm_current_version)

    echo -e "  \033[36mInstalled versions:\033[0m"
    for dir in "$PHPVM_VERSIONS"/*/; do
        local v
        v=$(basename "$dir")
        if [[ "$v" == "$current" ]]; then
            echo -e "    \033[32m-> $v  (active)\033[0m"
        else
            echo -e "    \033[90m   $v\033[0m"
        fi
    done
    echo ""
}

# ==============================================================================
#  phpvm current
# ==============================================================================
phpvm_current() {
    local cur
    cur=$(_phpvm_current_version)
    if [[ -n "$cur" ]]; then
        echo ""
        echo -e "  \033[32mActive: $cur\033[0m"
        php --version 2>/dev/null | sed 's/^/  /'
        echo ""
    else
        _warn "No PHP version active. Run: phpvm use <version>"
    fi
}

# ==============================================================================
#  phpvm uninstall <version>
# ==============================================================================
phpvm_uninstall() {
    local ver="$1"
    [[ -z "$ver" ]] && { _err "Usage: phpvm uninstall <version>"; return 1; }

    local target="$PHPVM_VERSIONS/$ver"
    [[ ! -d "$target" ]] && { _err "PHP $ver is not installed."; return 1; }

    local current
    current=$(_phpvm_current_version)
    if [[ "$current" == "$ver" ]]; then
        _err "Cannot uninstall the active version. Switch first: phpvm use <other>"
        return 1
    fi

    rm -rf "$target"
    _ok "PHP $ver removed."
}

# ==============================================================================
#  phpvm which
# ==============================================================================
phpvm_which() {
    if command -v php &>/dev/null; then
        _ok "$(command -v php)"
    else
        _warn "php not in PATH"
    fi
}

# ==============================================================================
#  phpvm ini
# ==============================================================================
phpvm_ini() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local ini="$PHPVM_VERSIONS/$cur/etc/php.ini"
    if [[ -f "$ini" ]]; then
        _step "Opening $ini"
        "${EDITOR:-nano}" "$ini"
    else
        _err "php.ini not found: $ini"
    fi
}

# ==============================================================================
#  phpvm deps  — print dependency install command for current OS
# ==============================================================================
phpvm_deps() {
    _phpvm_print_dep_install
}
