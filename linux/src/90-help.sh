# ==============================================================================
#  HELP
# ==============================================================================

phpvm_ext_help() {
    cat <<EOF

  phpvm ext — Extension Manager (Linux)
  ─────────────────────────────────────────────────────────

  phpvm ext list                   Available extensions (ON/OFF)
  phpvm ext loaded                 Loaded extensions (php -m)
  phpvm ext enable  <name>         Enable via conf.d ini drop-in
  phpvm ext disable <name>         Disable extension
  phpvm ext install <name>         Install via PECL
  phpvm ext install <name> <ver>   Install specific version via PECL
  phpvm ext info    <name>         Extension details
  phpvm ext laravel                Enable all Laravel extensions (full)
  phpvm ext laravel minimal        Enable required Laravel extensions only
  phpvm ext laravel full           Enable required + recommended + Redis

  Examples:
    phpvm ext install redis
    phpvm ext install xdebug
    phpvm ext install imagick 3.7.0
    phpvm ext enable  opcache
    phpvm ext disable xdebug
    phpvm ext info    redis

EOF
}

phpvm_help() {
    cat <<EOF

  phpvm $PHPVM_VERSION — PHP Version Manager for Linux
  ─────────────────────────────────────────────────────────

  VERSION MANAGEMENT
    phpvm install   <version>      Build & install a PHP version
                                     --no-use  install without switching to it
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php binary
    phpvm ini                      Open active php.ini in \$EDITOR
    phpvm fix-ini                  Sync extension_dir in active php.ini
    phpvm deps                     Print dependency install command
    phpvm doctor                   Diagnose PATH, extension_dir, openssl, toolchain

  COMPOSER / WP-CLI
    phpvm composer                 Install Composer for active PHP version
    phpvm wp-cli                   Install WP-CLI (global 'wp' command)

  AUTO-SWITCH (.phpvmrc)
    phpvm auto                     Switch to the version named in .phpvmrc
    phpvm hook enable              Enable auto-switching on cd (bash/zsh)
    phpvm hook disable             Disable the hook
    phpvm hook status              Check whether the hook is enabled

  SELF UPDATE
    phpvm upgrade                  Upgrade phpvm to latest version
    phpvm version                  Show current phpvm version

  LARAVEL QUICK SETUP
    phpvm ext laravel              Enable all Laravel extensions (full)
    phpvm ext laravel minimal      Required extensions only
    phpvm ext laravel full         Required + recommended + Redis

  EXTENSION MANAGEMENT
    phpvm ext list                 Available extensions (ON/OFF)
    phpvm ext loaded               Loaded extensions (php -m)
    phpvm ext enable  <name>       Enable extension (conf.d drop-in)
    phpvm ext disable <name>       Disable extension
    phpvm ext install <name>       Install via PECL
    phpvm ext info    <name>       Extension details
    phpvm ext help                 Full ext reference

  EXAMPLES
    phpvm install 8.3.0
    phpvm use 8.3.0
    phpvm ext install redis
    phpvm ext install xdebug
    phpvm ext enable opcache

  Home:      $PHPVM_DIR
  Build log: $PHPVM_LOG

EOF
}

# ==============================================================================
#  DID-YOU-MEAN (unknown command handling)
# ==============================================================================
# Iterative Levenshtein distance between $1 and $2 (two-row, O(n) memory).
_phpvm_levenshtein() {
    local a="$1" b="$2"
    local la=${#a} lb=${#b}
    (( la == 0 )) && { echo "$lb"; return; }
    (( lb == 0 )) && { echo "$la"; return; }
    local i j cost prev cur del ins sub min
    # Indices are shifted by one so the array starts at 1: zsh arrays are
    # 1-based and reject row[0] outright ("assignment to invalid subscript
    # range"), while bash simply leaves index 0 unused.
    local -a row
    for (( j = 0; j <= lb; j++ )); do row[j+1]=$j; done
    for (( i = 1; i <= la; i++ )); do
        prev=${row[1]}
        row[1]=$i
        for (( j = 1; j <= lb; j++ )); do
            cur=${row[j+1]}
            # ${a:i-1:1} makes zsh read ":i" as a history modifier
            # ("unrecognized modifier"). Spell the offset arithmetic out.
            if [[ "${a:$((i-1)):1}" == "${b:$((j-1)):1}" ]]; then cost=0; else cost=1; fi
            del=$(( row[j+1] + 1 )); ins=$(( row[j] + 1 )); sub=$(( prev + cost ))
            min=$del
            (( ins < min )) && min=$ins
            (( sub < min )) && min=$sub
            row[j+1]=$min
            prev=$cur
        done
    done
    echo "${row[lb+1]}"
}

# Canonical command list (includes aliases) for suggestions.
# An array, not a space-separated string: zsh does not word-split unquoted
# parameters, so `for c in $_PHPVM_COMMANDS` handed the whole list over as a
# single candidate and every typo was answered with the entire list.
_PHPVM_COMMANDS=(install use list ls current uninstall remove which doctor ini
                 deps ext composer wp-cli fix-ini auto hook upgrade update
                 version help)

# Unknown command: suggest the nearest match instead of dumping the full help.
_phpvm_unknown() {
    local cmd="$1"
    local best="" bestd=99 c d
    for c in "${_PHPVM_COMMANDS[@]}"; do
        d=$(_phpvm_levenshtein "$cmd" "$c")
        (( d < bestd )) && { bestd=$d; best=$c; }
    done
    _err "'$cmd' is not a phpvm command."
    (( bestd <= 2 )) && _dim "Did you mean '$best'?"
    _dim "Run 'phpvm help' to see all commands."
    return 1
}
