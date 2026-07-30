# ── Auto-switch (.phpvmrc) ────────────────────────────────────────────────────
# Walk from $1 (default $PWD) up to / looking for .phpvmrc.
# shellcheck disable=SC2120  # optional arg with PWD default - tests pass an arg.
_phpvm_find_rc() {
    local dir="${1:-$PWD}"
    while [[ -n "$dir" ]]; do
        if [[ -f "$dir/.phpvmrc" ]]; then
            echo "$dir/.phpvmrc"
            return 0
        fi
        [[ "$dir" == "/" ]] && return 1
        dir=$(dirname "$dir")
    done
    return 1
}

# First non-comment, non-empty line; strip inline #-comments and a leading `v`.
_phpvm_read_rc() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -n "$line" ]]; then
            echo "${line#v}"
            return 0
        fi
    done < "$file"
    return 1
}

# Map an rc version onto an installed version dir. Full semver passes through
# if installed; major.minor picks the highest installed patch.
_phpvm_resolve_rc() {
    local requested="$1"
    [[ -z "$requested" ]] && return 1
    if [[ -d "$PHPVM_VERSIONS/$requested/bin" ]]; then
        echo "$requested"
        return 0
    fi
    if [[ "$requested" =~ ^[0-9]+\.[0-9]+$ ]]; then
        local match
        match=$(find "$PHPVM_VERSIONS" -mindepth 1 -maxdepth 1 -type d -name "${requested}.*" 2>/dev/null \
                | while read -r d; do [[ -x "$d/bin/php" ]] && basename "$d"; done \
                | sort -V | tail -1)
        if [[ -n "$match" ]]; then
            echo "$match"
            return 0
        fi
    fi
    return 1
}

# Apply .phpvmrc to current shell. Session-only PATH change; tracked via
# $PHPVM_AUTO_ACTIVE so repeat calls no-op and leaving a project cleans up.
# Flags: -s / --silent for hook usage.
_phpvm_auto() {
    local silent=0
    [[ "$1" == "-s" || "$1" == "--silent" ]] && silent=1

    local rc resolved requested
    if ! rc=$(_phpvm_find_rc); then
        if [[ -n "${PHPVM_AUTO_ACTIVE:-}" ]]; then
            local old="$PHPVM_VERSIONS/$PHPVM_AUTO_ACTIVE/bin"
            PATH=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$old" | paste -sd ':' -)
            export PATH
            unset PHPVM_AUTO_ACTIVE
            [[ $silent -eq 0 ]] && _dim "Cleared auto PHP (no .phpvmrc upstream)."
        fi
        return 0
    fi

    if ! requested=$(_phpvm_read_rc "$rc"); then
        [[ $silent -eq 0 ]] && _warn "$rc is empty or comment-only."
        return 0
    fi

    if ! resolved=$(_phpvm_resolve_rc "$requested"); then
        [[ $silent -eq 0 ]] && {
            _warn "PHP $requested (from $rc) is not installed."
            _dim  "Run: phpvm install $requested"
        }
        return 0
    fi

    [[ "${PHPVM_AUTO_ACTIVE:-}" == "$resolved" ]] && return 0

    if [[ -n "${PHPVM_AUTO_ACTIVE:-}" ]]; then
        local old="$PHPVM_VERSIONS/$PHPVM_AUTO_ACTIVE/bin"
        PATH=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$old" | paste -sd ':' -)
    fi

    local new="$PHPVM_VERSIONS/$resolved/bin"
    export PATH="$new:$PATH"
    export PHPVM_AUTO_ACTIVE="$resolved"
    if [[ $silent -eq 0 ]]; then _ok "Auto-switched to PHP $resolved  (from $rc)"; fi
    return 0
}

# ── Is phpvm sourced from a shell rc? ─────────────────────────────────────────
# True if any login rc already sources phpvm.sh, meaning `use` will persist
# across sessions and the "add to your rc" warning would just be noise.
_phpvm_in_rc() {
    local f
    for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        [[ -f "$f" ]] && grep -Fq "$PHPVM_DIR/phpvm.sh" "$f" && return 0
    done
    return 1
}

# ==============================================================================
#  AUTO-SWITCH COMMANDS (phpvm auto, phpvm hook)
# ==============================================================================
phpvm_auto() {
    _phpvm_auto
}

phpvm_hook() {
    local sub="${1:-status}"
    local flag="$PHPVM_DIR/.auto-hook"
    case "$sub" in
        enable)
            mkdir -p "$PHPVM_DIR"
            touch "$flag"
            _ok "Hook enabled. Restart your shell, or run:"
            _dim "  source \"$PHPVM_DIR/phpvm.sh\""
            ;;
        disable)
            if [[ -f "$flag" ]]; then
                rm -f "$flag"
                _ok "Hook disabled. Restart your shell to fully unregister."
            else
                _warn "Hook is not enabled."
            fi
            ;;
        status)
            if [[ -f "$flag" ]]; then
                _ok "Hook is enabled ($flag)"
            else
                _dim "Hook is disabled. Run: phpvm hook enable"
            fi
            ;;
        *)
            echo ""
            echo "  phpvm hook - manage the shell auto-switch hook"
            echo "    phpvm hook enable     Enable .phpvmrc auto-switching on cd"
            echo "    phpvm hook disable    Disable the hook"
            echo "    phpvm hook status     Check whether the hook is enabled"
            echo ""
            ;;
    esac
}
