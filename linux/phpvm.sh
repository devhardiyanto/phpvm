#!/usr/bin/env bash
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

PHPVM_VERSION="1.4.3"
PHPVM_DIR="${PHPVM_DIR:-$HOME/.phpvm}"
PHPVM_VERSIONS="$PHPVM_DIR/versions"
PHPVM_CURRENT="$PHPVM_DIR/current"
PHPVM_CACHE="$PHPVM_DIR/cache"
PHPVM_LOG="$PHPVM_DIR/build.log"
PHPVM_UPDATE_URL="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
PHPVM_LAST_CHECK="$PHPVM_DIR/.last_update_check"
PHPVM_CHECK_INTERVAL=86400  # 24 hours

# ── Colors ────────────────────────────────────────────────────────────────────
_ok()   { echo -e "  \033[32m$*\033[0m"; }
_err()  { echo -e "  \033[31m[error] $*\033[0m" >&2; }
_step() { echo -e "  \033[36m> $*\033[0m"; }
_warn() { echo -e "  \033[33m[warn] $*\033[0m"; }
_dim()  { echo -e "  \033[90m$*\033[0m"; }

# ── Update checker (once per day, via version.txt) ───────────────────────────
_phpvm_check_update() {
    # Skip in CI or if explicitly disabled
    [[ -n "${CI:-}" || -n "${PHPVM_NO_UPDATE_CHECK:-}" ]] && return

    # Only check once per day
    if [[ -f "$PHPVM_LAST_CHECK" ]]; then
        local last_ts now elapsed
        last_ts=$(date -r "$PHPVM_LAST_CHECK" +%s 2>/dev/null || \
                  stat -c %Y "$PHPVM_LAST_CHECK" 2>/dev/null || echo 0)
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
    mkdir -p "$PHPVM_VERSIONS" "$PHPVM_CACHE"
}

# ── PATH management ───────────────────────────────────────────────────────────
# Sets $PHPVM_CURRENT/bin as the first entry in PATH
_phpvm_use_path() {
    local bin="$PHPVM_CURRENT/bin"
    # Remove any existing phpvm path entries
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$PHPVM_DIR" | paste -sd ':')
    export PATH="$bin:$PATH"
}

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

# ── Check build dependencies ──────────────────────────────────────────────────
_phpvm_check_deps() {
    local missing=()
    local tools=("gcc" "make" "autoconf" "bison" "re2c" "pkg-config")
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        _warn "Missing build tools: ${missing[*]}"
        _phpvm_print_dep_install
        return 1
    fi
    return 0
}

_phpvm_print_dep_install() {
    local pm
    pm=$(_phpvm_detect_os)
    echo ""
    _dim "Install build dependencies with:"
    case "$pm" in
        apt)
            _dim "  sudo apt-get install -y \\"
            _dim "    build-essential autoconf bison re2c pkg-config \\"
            _dim "    libxml2-dev libsqlite3-dev libssl-dev libcurl4-openssl-dev \\"
            _dim "    libonig-dev libzip-dev zlib1g-dev libreadline-dev \\"
            _dim "    libpng-dev libjpeg-dev libwebp-dev libfreetype6-dev \\"
            _dim "    libgmp-dev libmysqlclient-dev libpq-dev"
            ;;
        dnf|yum)
            _dim "  sudo $pm install -y \\"
            _dim "    gcc make autoconf bison re2c pkg-config \\"
            _dim "    libxml2-devel sqlite-devel openssl-devel libcurl-devel \\"
            _dim "    oniguruma-devel libzip-devel zlib-devel readline-devel \\"
            _dim "    libpng-devel libjpeg-devel libwebp-devel freetype-devel \\"
            _dim "    gmp-devel mysql-devel postgresql-devel"
            ;;
        pacman)
            _dim "  sudo pacman -S --needed \\"
            _dim "    base-devel autoconf bison re2c pkg-config \\"
            _dim "    libxml2 sqlite openssl curl oniguruma libzip \\"
            _dim "    libpng libjpeg libwebp freetype2 gmp mysql-libs postgresql-libs"
            ;;
        zypper)
            _dim "  sudo zypper install -y \\"
            _dim "    gcc make autoconf bison re2c pkg-config \\"
            _dim "    libxml2-devel sqlite3-devel libopenssl-devel libcurl-devel \\"
            _dim "    oniguruma-devel libzip-devel zlib-devel readline-devel"
            ;;
        *)
            _dim "  Please install: gcc make autoconf bison re2c pkg-config"
            _dim "  and dev libraries: libxml2, sqlite3, openssl, curl, oniguruma, libzip"
            ;;
    esac
    echo ""
}

# ── CPU count ─────────────────────────────────────────────────────────────────
_phpvm_cpus() {
    nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2
}

# ==============================================================================
#  phpvm install <version>
# ==============================================================================
phpvm_install() {
    local ver="$1"
    [[ -z "$ver" ]] && { _err "Usage: phpvm install <version>  (e.g. phpvm install 8.3.0)"; return 1; }

    local target="$PHPVM_VERSIONS/$ver"

    if [[ -d "$target" ]]; then
        _warn "PHP $ver is already installed. Run: phpvm use $ver"
        return 0
    fi

    # Check deps before attempting download
    _phpvm_check_deps || return 1

    # Download source
    local tarball="php-$ver.tar.gz"
    local cache_file="$PHPVM_CACHE/$tarball"
    local url="https://www.php.net/distributions/$tarball"

    if [[ ! -f "$cache_file" ]]; then
        _step "Downloading PHP $ver from php.net ..."
        if command -v curl &>/dev/null; then
            curl -fL --progress-bar "$url" -o "$cache_file" || {
                _err "Download failed. Check version: https://www.php.net/releases/"
                rm -f "$cache_file"
                return 1
            }
        elif command -v wget &>/dev/null; then
            wget -q --show-progress "$url" -O "$cache_file" || {
                _err "Download failed. Check version: https://www.php.net/releases/"
                rm -f "$cache_file"
                return 1
            }
        else
            _err "curl or wget is required."
            return 1
        fi
    else
        _dim "Using cached: $cache_file"
    fi

    # Extract
    local src_dir="$PHPVM_CACHE/php-$ver"
    _step "Extracting ..."
    [[ -d "$src_dir" ]] && rm -rf "$src_dir"
    tar -xzf "$cache_file" -C "$PHPVM_CACHE"

    # Configure
    _step "Configuring (this may take a minute) ..."
    mkdir -p "$target"

    local configure_opts=(
        "--prefix=$target"
        "--with-config-file-path=$target/etc"
        "--with-config-file-scan-dir=$target/etc/conf.d"
        "--enable-fpm"
        "--with-fpm-user=www-data"
        "--with-fpm-group=www-data"
        "--enable-mbstring"
        "--enable-intl"
        "--enable-opcache"
        "--enable-pcntl"
        "--enable-bcmath"
        "--enable-sockets"
        "--enable-exif"
        "--with-openssl"
        "--with-curl"
        "--with-zlib"
        "--with-readline"
        "--with-zip"
        "--with-pdo-mysql=mysqlnd"
        "--with-pdo-sqlite"
        "--with-sqlite3"
        "--with-mysqli=mysqlnd"
        "--enable-gd"
        "--with-jpeg"
        "--with-webp"
        "--with-freetype"
        "--with-gettext"
        "--with-gmp"
        "--with-pgsql"
        "--with-pdo-pgsql"
        "--with-onig"
    )

    cd "$src_dir" || {
        _err "Could not enter source directory: $src_dir"
        rm -rf "$target"
        return 1
    }
    ./buildconf --force &>>"$PHPVM_LOG" 2>&1 || true  # needed only for git checkouts
    ./configure "${configure_opts[@]}" >> "$PHPVM_LOG" 2>&1 || {
        _err "Configure failed. See log: $PHPVM_LOG"
        rm -rf "$target"
        return 1
    }

    # Build
    local cpus
    cpus=$(_phpvm_cpus)
    _step "Building with $cpus cores (grab a coffee, this takes a few minutes) ..."
    make -j"$cpus" >> "$PHPVM_LOG" 2>&1 || {
        _err "Build failed. See log: $PHPVM_LOG"
        rm -rf "$target"
        return 1
    }

    # Install
    _step "Installing ..."
    make install >> "$PHPVM_LOG" 2>&1 || {
        _err "Install failed. See log: $PHPVM_LOG"
        rm -rf "$target"
        return 1
    }

    # Bootstrap php.ini
    local etc_dir="$target/etc"
    mkdir -p "$etc_dir/conf.d"
    if [[ ! -f "$etc_dir/php.ini" ]]; then
        local ini_src
        ini_src=$(find "$src_dir" -maxdepth 1 -name "php.ini-development" | head -1)
        [[ -f "$ini_src" ]] && cp "$ini_src" "$etc_dir/php.ini"
    fi

    # Cleanup build dir (keep cached tarball for faster reinstall)
    rm -rf "$src_dir"

    _ok "PHP $ver installed successfully."
    _dim "Activate with: phpvm use $ver"
}

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
    php --version 2>/dev/null | head -1
    _warn "To persist across sessions, ensure your shell rc sources phpvm."
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
        php --version 2>/dev/null
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

# ==============================================================================
#  EXT COMMANDS
# ==============================================================================

phpvm_ext_list() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    echo ""
    echo -e "  \033[36mPHP $cur — loaded extensions:\033[0m"
    php -m 2>/dev/null | grep -v '^\[' | sort | while read -r ext; do
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

    local ver="${2:-}"
    if [[ -n "$ver" ]]; then
        _step "Installing $name-$ver via PECL ..."
        pecl install "$name-$ver" || {
            _err "Failed to install $name-$ver via PECL."
            return 1
        }
    else
        _step "Installing $name via PECL ..."
        pecl install "$name" || {
            _err "Failed to install $name via PECL."
            return 1
        }
    fi

    _ok "Done. Enable with: phpvm ext enable $name"
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

phpvm_ext() {
    local sub="${1:-help}"
    local name="${2:-}"
    local ver="${3:-}"

    case "$sub" in
        list|ls)   phpvm_ext_list ;;
        loaded)    phpvm_ext_list ;;
        install)   phpvm_ext_install "$name" "$ver" ;;
        enable)    phpvm_ext_enable  "$name" ;;
        disable)   phpvm_ext_disable "$name" ;;
        info)      phpvm_ext_info    "$name" ;;
        help|*)    phpvm_ext_help ;;
    esac
}

# ==============================================================================
#  HELP
# ==============================================================================

phpvm_ext_help() {
    cat <<EOF

  phpvm ext — Extension Manager (Linux)
  ─────────────────────────────────────────────────────────

  phpvm ext list                   Show loaded extensions
  phpvm ext enable  <name>         Enable via conf.d ini drop-in
  phpvm ext disable <name>         Disable extension
  phpvm ext install <name>         Install via PECL
  phpvm ext install <name> <ver>   Install specific version via PECL
  phpvm ext info    <name>         Extension details

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
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php binary
    phpvm ini                      Open active php.ini in \$EDITOR
    phpvm deps                     Print dependency install command

  SELF UPDATE
    phpvm upgrade                  Upgrade phpvm to latest version
    phpvm version                  Show current phpvm version

  EXTENSION MANAGEMENT
    phpvm ext list                 Show loaded extensions
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

  Install dir:  $PHPVM_DIR
  Build log:    $PHPVM_LOG

EOF
}

# ==============================================================================
#  SELF UPDATE
# ==============================================================================
phpvm_upgrade() {
    local script_url="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/linux/phpvm.sh"
    local version_url="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
    local script_dest="$PHPVM_DIR/phpvm.sh"
    local backup="$PHPVM_DIR/phpvm.sh.bak"

    _step "Checking latest version ..."

    local latest
    if command -v curl &>/dev/null; then
        latest=$(curl -fsSL --max-time 5 "$version_url" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget &>/dev/null; then
        latest=$(wget -qO- --timeout=5 "$version_url" 2>/dev/null | tr -d '[:space:]')
    else
        _err "curl or wget is required."
        return 1
    fi

    if [[ -z "$latest" ]]; then
        _err "Could not reach GitHub. Check your connection."
        return 1
    fi

    # Compare versions
    local newer
    newer=$(printf '%s\n%s' "$PHPVM_VERSION" "$latest" | sort -V | tail -1)
    if [[ "$newer" == "$PHPVM_VERSION" && "$latest" == "$PHPVM_VERSION" ]]; then
        _ok "Already up to date. (phpvm $PHPVM_VERSION)"
        return 0
    fi

    _step "Upgrading phpvm $PHPVM_VERSION → $latest ..."

    # Backup
    cp "$script_dest" "$backup"
    _dim "Backup saved: $backup"

    # Download new version
    local tmp="$PHPVM_DIR/phpvm.sh.tmp"
    if command -v curl &>/dev/null; then
        curl -fsSL "$script_url" -o "$tmp" || { _err "Download failed."; return 1; }
    else
        wget -qO "$tmp" "$script_url" || { _err "Download failed."; return 1; }
    fi

    # Verify it looks like a valid phpvm script
    if ! grep -q "PHPVM_VERSION" "$tmp"; then
        _err "Downloaded file seems invalid. Rolling back."
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$script_dest"
    chmod +x "$script_dest"

    _ok "phpvm upgraded to $latest!"
    _dim "Run: source ~/.bashrc  (or restart terminal)"
    _dim "Backup of old version: $backup"
}

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
        ini)                   phpvm_ini ;;
        deps)                  phpvm_deps ;;
        ext)                   phpvm_ext       "$@" ;;
        upgrade|update)        phpvm_upgrade ;;
        version|-v)            _ok "phpvm $PHPVM_VERSION" ;;
        help|--help)           phpvm_help ;;
        *)                     phpvm_help ;;
    esac
}

# Auto-activate current version if set (on shell load)
if [[ -L "$PHPVM_CURRENT" ]]; then
    _phpvm_use_path
fi
