# ── Colors ────────────────────────────────────────────────────────────────────
# printf (not echo -e): the message is passed through %s so backslashes in the
# text — e.g. the trailing `\` of a multi-line shell command — stay literal and
# never merge with the trailing \033[0m reset. echo -e merged them, leaking
# `\033[0m` into the output on some shells.
_ok()   { printf '  \033[32m%s\033[0m\n'         "$*"; }
_err()  { printf '  \033[31m[error] %s\033[0m\n' "$*" >&2; }
_step() { printf '  \033[36m> %s\033[0m\n'       "$*"; }
_warn() { printf '  \033[33m[warn] %s\033[0m\n'  "$*"; }
_dim()  { printf '  \033[90m%s\033[0m\n'         "$*"; }

# ── Update checker (hourly, via version.txt) ─────────────────────────────────
_phpvm_check_update() {
    # Skip in CI or if explicitly disabled
    [[ -n "${CI:-}" || -n "${PHPVM_NO_UPDATE_CHECK:-}" ]] && return

    # Only check once per interval
    if [[ -f "$PHPVM_LAST_CHECK" ]]; then
        local last_ts now elapsed
        # GNU stat (-c) on Linux, BSD stat (-f) on macOS.
        last_ts=$(stat -c %Y "$PHPVM_LAST_CHECK" 2>/dev/null || \
                  stat -f %m "$PHPVM_LAST_CHECK" 2>/dev/null || echo 0)
        now=$(date +%s)
        elapsed=$(( now - last_ts ))
        [[ $elapsed -lt $PHPVM_CHECK_INTERVAL ]] && return
    fi

    # Update timestamp first
    touch "$PHPVM_LAST_CHECK" 2>/dev/null || return

    # Fetch latest version (3s timeout, silent)
    local latest
    if command -v curl &>/dev/null; then
        latest=$(curl -fsSL --max-time 3 "$PHPVM_UPDATE_URL" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget &>/dev/null; then
        latest=$(wget -qO- --timeout=3 "$PHPVM_UPDATE_URL" 2>/dev/null | tr -d '[:space:]')
    else
        return
    fi

    [[ -z "$latest" ]] && return

    # Compare versions (sort -V = version sort)
    local newer
    newer=$(printf '%s\n%s' "$PHPVM_VERSION" "$latest" | sort -V | tail -1)
    if [[ "$newer" == "$latest" && "$latest" != "$PHPVM_VERSION" ]]; then
        echo ""
        echo -e "  \033[33m┌─────────────────────────────────────────────────────┐\033[0m"
        echo -e "  \033[33m│  phpvm update available: $PHPVM_VERSION → $latest              \033[0m"
        echo -e "  \033[33m│  Run: curl -fsSL .../linux/install.sh | bash         │\033[0m"
        echo -e "  \033[33m└─────────────────────────────────────────────────────┘\033[0m"
        echo ""
    fi
}


_phpvm_init() {
    mkdir -p "$PHPVM_VERSIONS" "$PHPVM_CACHE" "$PHPVM_BIN"
}

# ── PATH management ───────────────────────────────────────────────────────────
# Order: $PHPVM_BIN (global shims like composer) before $PHPVM_CURRENT/bin so a
# global composer always wins over any stale per-version shim; both ahead of the
# rest of PATH. `php`, `pecl`, etc. still resolve from the active version's bin.
_phpvm_use_path() {
    local bin="$PHPVM_CURRENT/bin"
    # Remove any existing phpvm path entries
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$PHPVM_DIR" | paste -sd ':' -)
    export PATH="$PHPVM_BIN:$bin:$PATH"
}

# Ensure $PHPVM_BIN is on PATH even when no version is active yet, so the global
# `composer` shim is reachable (and gives a clean error) regardless.
_phpvm_ensure_bin_path() {
    case ":$PATH:" in
        *":$PHPVM_BIN:"*) ;;
        *) export PATH="$PHPVM_BIN:$PATH" ;;
    esac
}
