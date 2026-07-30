# ==============================================================================
#  ENTRY POINT
# ==============================================================================
phpvm() {
    _phpvm_init
    _phpvm_check_update

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        install)               phpvm_install   "$@" ;;
        use)                   phpvm_use       "$@" ;;
        list|ls)               phpvm_list ;;
        current)               phpvm_current ;;
        uninstall|remove)      phpvm_uninstall "$@" ;;
        which)                 phpvm_which ;;
        doctor)                phpvm_doctor ;;
        ini)                   phpvm_ini ;;
        deps)                  phpvm_deps ;;
        ext)                   phpvm_ext       "$@" ;;
        composer)              phpvm_composer ;;
        wp-cli)                phpvm_wp_cli ;;
        fix-ini)               phpvm_fix_ini ;;
        auto)                  phpvm_auto ;;
        hook)                  phpvm_hook      "$@" ;;
        upgrade|update)        phpvm_upgrade ;;
        version|-v)            _ok "phpvm $PHPVM_VERSION" ;;
        help|--help)           phpvm_help ;;
        *)                     _phpvm_unknown "$cmd" ;;
    esac
}

# Tests / external sourcing can set PHPVM_NO_INIT=1 to skip the source-time
# side effects below (PATH manipulation + hook registration).
if [[ -z "${PHPVM_NO_INIT:-}" ]]; then
    # Auto-activate current version if set (on shell load); otherwise still make
    # sure the global shim dir is on PATH.
    if [[ -L "$PHPVM_CURRENT" ]]; then
        _phpvm_use_path
    else
        _phpvm_ensure_bin_path
    fi

    # Register .phpvmrc auto-switch hook if user opted in.
    if [[ -f "$PHPVM_DIR/.auto-hook" ]]; then
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            autoload -U add-zsh-hook 2>/dev/null && add-zsh-hook chpwd _phpvm_auto >/dev/null 2>&1
        elif [[ -n "${BASH_VERSION:-}" ]]; then
            case "${PROMPT_COMMAND:-}" in
                *_phpvm_auto*) ;;
                *) PROMPT_COMMAND="_phpvm_auto -s${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
            esac
        fi
        _phpvm_auto -s
    fi
fi
