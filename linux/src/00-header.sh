# ==============================================================================
#  phpvm — PHP Version Manager for Linux
#  Installs PHP from source (php.net). Manages per-version installs.
#  Repo: https://github.com/devhardiyanto/phpvm
#
#  Usage:
#    source ~/.phpvm/phpvm.sh    (add to ~/.bashrc or ~/.zshrc)
#    phpvm install 8.3.0
#    phpvm use 8.3.0
# ==============================================================================

PHPVM_VERSION="1.15.0"
PHPVM_DIR="${PHPVM_DIR:-$HOME/.phpvm}"
PHPVM_VERSIONS="$PHPVM_DIR/versions"
PHPVM_CURRENT="$PHPVM_DIR/current"
PHPVM_BIN="$PHPVM_DIR/bin"          # global shims (composer) — always on PATH
PHPVM_CACHE="$PHPVM_DIR/cache"
PHPVM_LOG="$PHPVM_DIR/build.log"
PHPVM_UPDATE_URL="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
PHPVM_LAST_CHECK="$PHPVM_DIR/.last_update_check"
PHPVM_CHECK_INTERVAL=3600  # 1 hour
