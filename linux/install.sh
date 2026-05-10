#!/usr/bin/env bash
# ==============================================================================
#  install.sh — phpvm installer for Linux
#  Usage: curl -fsSL https://raw.githubusercontent.com/devhardiyanto/phpvm/main/install.sh | bash
# ==============================================================================

set -e

PHPVM_VERSION="1.0.0"
PHPVM_DIR="${PHPVM_DIR:-$HOME/.phpvm}"
PHPVM_REPO="https://raw.githubusercontent.com/devhardiyanto/phpvm/main"

_ok()   { echo -e "  \033[32m$*\033[0m"; }
_step() { echo -e "  \033[36m> $*\033[0m"; }
_warn() { echo -e "  \033[33m[warn] $*\033[0m"; }
_err()  { echo -e "  \033[31m[error] $*\033[0m" >&2; }

echo ""
echo -e "  \033[36mphpvm $PHPVM_VERSION — PHP Version Manager for Linux\033[0m"
echo -e "  \033[90m──────────────────────────────────────────────────────\033[0m"
echo ""

# 1. Create directory
_step "Creating $PHPVM_DIR ..."
mkdir -p "$PHPVM_DIR/versions" "$PHPVM_DIR/cache"

# 2. Download phpvm.sh
_step "Downloading phpvm.sh ..."
if command -v curl &>/dev/null; then
    curl -fsSL "$PHPVM_REPO/linux/phpvm.sh" -o "$PHPVM_DIR/phpvm.sh"
elif command -v wget &>/dev/null; then
    wget -qO "$PHPVM_DIR/phpvm.sh" "$PHPVM_REPO/linux/phpvm.sh"
else
    _err "curl or wget is required."
    exit 1
fi
chmod +x "$PHPVM_DIR/phpvm.sh"
_ok "Downloaded -> $PHPVM_DIR/phpvm.sh"

# 3. Add source line to shell rc files
_phpvm_add_to_rc() {
    local rc_file="$1"
    local source_line="# phpvm"$'\n'"[ -f \"\$HOME/.phpvm/phpvm.sh\" ] && source \"\$HOME/.phpvm/phpvm.sh\""

    if [[ -f "$rc_file" ]] && grep -q "phpvm" "$rc_file"; then
        _warn "phpvm already in $rc_file, skipping."
    elif [[ -f "$rc_file" ]] || [[ "$rc_file" == "$HOME/.bashrc" ]]; then
        echo "" >> "$rc_file"
        echo "$source_line" >> "$rc_file"
        _ok "Added source line -> $rc_file"
    fi
}

_step "Configuring shell ..."
_phpvm_add_to_rc "$HOME/.bashrc"
[[ -f "$HOME/.zshrc" ]]    && _phpvm_add_to_rc "$HOME/.zshrc"
[[ -f "$HOME/.profile" ]]  && _phpvm_add_to_rc "$HOME/.profile"

echo ""
echo -e "  \033[32m✓ phpvm installed!\033[0m"
echo ""
echo -e "  \033[36mNext steps:\033[0m"
echo "    1. Reload your shell:  source ~/.bashrc"
echo "    2. Install deps:       phpvm deps"
echo "    3. Install PHP:        phpvm install 8.3.0"
echo "    4. Switch version:     phpvm use 8.3.0"
echo ""
