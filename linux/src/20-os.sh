# ── Get current version ───────────────────────────────────────────────────────
_phpvm_current_version() {
    if [[ -L "$PHPVM_CURRENT" ]]; then
        basename "$(readlink "$PHPVM_CURRENT")"
    else
        echo ""
    fi
}

# ── Detect OS / package manager ───────────────────────────────────────────────
_phpvm_detect_os() {
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    elif command -v zypper  &>/dev/null; then echo "zypper"
    elif command -v brew    &>/dev/null; then echo "brew"
    else echo "unknown"
    fi
}

# ── CPU count ─────────────────────────────────────────────────────────────────
_phpvm_cpus() {
    nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2
}
