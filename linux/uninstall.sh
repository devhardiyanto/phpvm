#!/usr/bin/env bash
# ==============================================================================
#  uninstall.sh — remove phpvm from Linux (reverses install.sh)
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/devhardiyanto/phpvm/main/linux/uninstall.sh | bash -s -- --yes
#    bash uninstall.sh                 # interactive confirm, removes everything
#    bash uninstall.sh --keep-versions # remove phpvm but keep built PHP versions
#    bash uninstall.sh --yes           # no prompt (for pipes / automation)
#
#  Removes: ~/.phpvm and the "# phpvm" source block from your shell rc files.
#  Does NOT touch anything else on your system.
# ==============================================================================

set -e

PHPVM_DIR="${PHPVM_DIR:-$HOME/.phpvm}"

_ok()   { printf '  \033[32m%s\033[0m\n'         "$*"; }
_step() { printf '  \033[36m> %s\033[0m\n'       "$*"; }
_warn() { printf '  \033[33m[warn] %s\033[0m\n'  "$*"; }
_err()  { printf '  \033[31m[error] %s\033[0m\n' "$*" >&2; }
_dim()  { printf '  \033[90m%s\033[0m\n'         "$*"; }

assume_yes=0
keep_versions=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)         assume_yes=1 ;;
        --keep-versions)  keep_versions=1 ;;
        -h|--help)
            echo ""
            echo "  phpvm uninstaller"
            echo "    --yes, -y          Skip the confirmation prompt"
            echo "    --keep-versions    Remove phpvm but keep built PHP versions"
            echo "    --help, -h         Show this help"
            echo ""
            exit 0
            ;;
        *) _warn "Ignoring unknown option: $arg" ;;
    esac
done

echo ""
echo -e "  \033[36mphpvm uninstaller\033[0m"
echo -e "  \033[90m──────────────────────────────────────────────────────\033[0m"
echo ""

if [[ ! -d "$PHPVM_DIR" ]]; then
    _warn "phpvm not found at $PHPVM_DIR — nothing to remove."
fi

# What's about to happen.
if [[ $keep_versions -eq 1 ]]; then
    _dim "Will remove phpvm but KEEP built PHP versions in:"
    _dim "  $PHPVM_DIR/versions"
else
    _dim "Will remove EVERYTHING under: $PHPVM_DIR"
    _dim "(including all built PHP versions; pass --keep-versions to retain them)"
fi
_dim "Will strip the '# phpvm' source line from your shell rc files."
echo ""

# Confirm unless --yes. When piped (curl | bash) stdin is the script, so read
# from the controlling terminal instead.
if [[ $assume_yes -eq 0 ]]; then
    reply=""
    if [[ -r /dev/tty ]]; then
        printf "  Proceed? [y/N] " > /dev/tty
        read -r reply < /dev/tty
    else
        _err "No terminal to confirm on. Re-run with --yes to proceed non-interactively."
        exit 1
    fi
    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) echo "  Aborted. Nothing was changed."; exit 0 ;;
    esac
fi

# 1. Remove the source block from shell rc files.
_phpvm_strip_rc() {
    local rc_file="$1"
    [[ -f "$rc_file" ]] || return 0
    grep -Fq "$PHPVM_DIR/phpvm.sh" "$rc_file" || return 0

    local tmp
    tmp=$(mktemp) || { _warn "mktemp failed; skipping $rc_file"; return 0; }
    # Drop any line that sources our phpvm.sh, plus a "# phpvm" marker line
    # immediately preceding such a source line.
    awk -v marker="$PHPVM_DIR/phpvm.sh" '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                cur = lines[i]
                nxt = (i < NR) ? lines[i + 1] : ""
                if (cur == "# phpvm" && index(nxt, marker) > 0) continue
                if (index(cur, marker) > 0) continue
                print cur
            }
        }
    ' "$rc_file" > "$tmp"
    cat "$tmp" > "$rc_file"
    rm -f "$tmp"
    _ok "Cleaned $rc_file"
}

_step "Cleaning shell rc files ..."
_phpvm_strip_rc "$HOME/.bashrc"
_phpvm_strip_rc "$HOME/.zshrc"
_phpvm_strip_rc "$HOME/.profile"
_phpvm_strip_rc "$HOME/.bash_profile"

# 2. Remove the phpvm directory.
if [[ -d "$PHPVM_DIR" ]]; then
    if [[ $keep_versions -eq 1 && -d "$PHPVM_DIR/versions" ]]; then
        _step "Removing phpvm (keeping built versions) ..."
        # Move versions aside, nuke the rest, move versions back.
        find "$PHPVM_DIR" -mindepth 1 -maxdepth 1 ! -name versions -exec rm -rf {} +
        _ok "Removed phpvm. Kept: $PHPVM_DIR/versions"
        _dim "Delete it later with: rm -rf \"$PHPVM_DIR\""
    else
        _step "Removing $PHPVM_DIR ..."
        rm -rf "$PHPVM_DIR"
        _ok "Removed $PHPVM_DIR"
    fi
fi

echo ""
_ok "phpvm uninstalled."
_dim "The 'phpvm' function lingers in this shell session — restart your"
_dim "terminal (or open a new one) to clear it completely."
echo ""
