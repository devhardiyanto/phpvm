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

PHPVM_VERSION="1.7.0"
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
            PATH=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$old" | paste -sd ':')
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
        PATH=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$old" | paste -sd ':')
    fi

    local new="$PHPVM_VERSIONS/$resolved/bin"
    export PATH="$new:$PATH"
    export PHPVM_AUTO_ACTIVE="$resolved"
    if [[ $silent -eq 0 ]]; then _ok "Auto-switched to PHP $resolved  (from $rc)"; fi
    return 0
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

phpvm_ext_laravel() {
    local preset="${1:-full}"
    case "$preset" in min|minimal) preset="minimal" ;; *) preset="full" ;; esac

    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version."; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local minimal=(openssl pdo pdo_mysql pdo_sqlite mbstring tokenizer xml ctype fileinfo bcmath curl zip sodium)
    local extra=(intl gd exif opcache pdo_pgsql pgsql sockets)
    local pecl=(redis)

    local enable_list=("${minimal[@]}")
    local pecl_list=()
    if [[ "$preset" != "minimal" ]]; then
        enable_list+=("${extra[@]}")
        pecl_list+=("${pecl[@]}")
    fi

    echo ""
    echo -e "  \033[36mLaravel extension setup ($preset) — PHP $cur\033[0m"
    echo -e "  \033[90m─────────────────────────────────────────────────\033[0m"
    echo ""

    local loaded
    loaded=$("$php_bin" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')

    local ext_dir
    ext_dir=$("$php_bin" -r "echo ini_get('extension_dir');" 2>/dev/null)

    echo -e "  \033[33m[1/2] Enabling bundled extensions ...\033[0m"
    for ext in "${enable_list[@]}"; do
        if echo "$loaded" | grep -qx "$ext"; then
            printf "       %-18s already ON\n" "$ext"
            continue
        fi
        # Built-in extensions (e.g. pdo, mbstring) have no .so file; try enable anyway.
        if [[ -n "$ext_dir" && ! -f "$ext_dir/$ext.so" && ! -f "$ext_dir/php_$ext.so" ]]; then
            # Check if it's a static built-in via php -m again (case-insensitive match above already failed)
            printf "       \033[90mskip  %-18s (not built into this PHP)\033[0m\n" "$ext"
            continue
        fi
        if phpvm_ext_enable "$ext" >/dev/null 2>&1; then
            _ok "Enabled: $ext"
        else
            _warn "Could not enable: $ext"
        fi
    done

    if [[ ${#pecl_list[@]} -gt 0 ]]; then
        echo ""
        echo -e "  \033[33m[2/2] PECL extensions ...\033[0m"
        for ext in "${pecl_list[@]}"; do
            if echo "$loaded" | grep -qx "$ext"; then
                printf "       %-18s already ON\n" "$ext"
                continue
            fi
            if [[ -f "$ext_dir/$ext.so" || -f "$ext_dir/php_$ext.so" ]]; then
                phpvm_ext_enable "$ext" >/dev/null 2>&1 && _ok "Enabled: $ext"
            else
                _step "Installing $ext via PECL ..."
                if phpvm_ext_install "$ext"; then
                    phpvm_ext_enable "$ext" >/dev/null 2>&1 && _ok "Enabled: $ext"
                fi
            fi
        done
    fi

    echo ""
    _ok "Done! Verify with: php -m"
    echo ""
    if [[ "$preset" == "minimal" ]]; then
        _dim "For Redis + GD + opcache + intl, run: phpvm ext laravel full"
    else
        _dim "Optional extras:"
        _dim "  phpvm ext install xdebug      # debugger"
        _dim "  phpvm ext install imagick     # advanced image processing"
        _dim "  phpvm composer                # install Composer"
    fi
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
        laravel)   phpvm_ext_laravel "$name" ;;
        help|*)    phpvm_ext_help ;;
    esac
}

# ==============================================================================
#  COMPOSER (one composer.phar per active PHP version)
# ==============================================================================
phpvm_composer() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local php_root="$PHPVM_VERSIONS/$cur"
    local php_bin="$php_root/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local phar="$php_root/bin/composer.phar"
    local shim="$php_root/bin/composer"

    if [[ -x "$shim" && -f "$phar" ]]; then
        _warn "Composer already installed at $shim"
        _dim "Run: composer --version"
        return 0
    fi

    # openssl is bundled on most distros' PHP-from-source builds; warn if missing.
    if ! "$php_bin" -r "exit(extension_loaded('openssl') ? 0 : 1);" 2>/dev/null; then
        _warn "openssl extension not loaded; Composer requires it."
        _dim "Enable it then retry: phpvm ext enable openssl"
    fi

    local installer_url="https://getcomposer.org/installer"
    local sig_url="https://composer.github.io/installer.sig"
    local tmp; tmp=$(mktemp -t composer-setup.XXXXXX.php) || { _err "mktemp failed."; return 1; }

    _step "Downloading Composer installer ..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$installer_url" -o "$tmp" || { _err "Download failed."; rm -f "$tmp"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp" "$installer_url" || { _err "Download failed."; rm -f "$tmp"; return 1; }
    else
        _err "curl or wget is required."; rm -f "$tmp"; return 1
    fi

    _step "Verifying installer integrity ..."
    local expected actual
    if command -v curl &>/dev/null; then
        expected=$(curl -fsSL "$sig_url" 2>/dev/null | tr -d '[:space:]')
    else
        expected=$(wget -qO- "$sig_url" 2>/dev/null | tr -d '[:space:]')
    fi
    actual=$("$php_bin" -r "echo hash_file('sha384', '$tmp');" 2>/dev/null)

    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        _err "Hash mismatch! Installer may be corrupt or tampered."
        rm -f "$tmp"
        return 1
    fi
    _ok "Hash verified."

    _step "Installing Composer ..."
    mkdir -p "$php_root/bin"
    (cd "$php_root/bin" && "$php_bin" "$tmp" --quiet --filename=composer.phar) || {
        _err "Composer installer failed."
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"

    [[ ! -f "$phar" ]] && { _err "composer.phar not created at $phar"; return 1; }

    # POSIX shim — works in bash/zsh/sh.
    cat > "$shim" <<EOF
#!/usr/bin/env sh
exec "$php_bin" "$phar" "\$@"
EOF
    chmod +x "$shim"

    _ok "Composer installed!"
    _ok "  phar : $phar"
    _ok "  shim : $shim"
    echo ""
    "$php_bin" "$phar" --version 2>/dev/null
    echo ""
    _dim "Note: composer is installed inside the PHP $cur bin dir."
    _dim "After 'phpvm use <other>', re-run 'phpvm composer' for that version."
}

# ==============================================================================
#  FIX-INI (sync extension_dir in active php.ini)
# ==============================================================================
phpvm_fix_ini() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local target_dir="$PHPVM_VERSIONS/$cur"
    local php_bin="$target_dir/bin/php"
    local ini="$target_dir/etc/php.ini"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }
    [[ ! -f "$ini"     ]] && { _err "php.ini not found: $ini"; return 1; }

    # Resolve the real extension_dir compiled into PHP.
    local ext_path
    ext_path=$("$php_bin" -r "echo PHP_EXTENSION_DIR;" 2>/dev/null)
    [[ -z "$ext_path" ]] && { _err "Could not resolve PHP_EXTENSION_DIR."; return 1; }

    if grep -qE '^\s*;?\s*extension_dir\s*=' "$ini"; then
        # In-place edit, escaping path for sed (/ in path).
        local esc
        esc=$(printf '%s' "$ext_path" | sed 's:[\\/&]:\\&:g')
        sed -i.bak -E "s|^[[:space:]]*;?[[:space:]]*extension_dir[[:space:]]*=.*$|extension_dir = \"$esc\"|" "$ini"
        rm -f "$ini.bak"
        _ok "Fixed extension_dir → $ext_path"
    else
        printf '\nextension_dir = "%s"\n' "$ext_path" >> "$ini"
        _ok "Added extension_dir → $ext_path"
    fi

    _dim "Verify: phpvm ext list"
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
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php binary
    phpvm ini                      Open active php.ini in \$EDITOR
    phpvm fix-ini                  Sync extension_dir in active php.ini
    phpvm deps                     Print dependency install command

  COMPOSER
    phpvm composer                 Install Composer for active PHP version

  LARAVEL QUICK SETUP
    phpvm ext laravel              Enable all Laravel extensions (full)
    phpvm ext laravel minimal      Required extensions only
    phpvm ext laravel full         Required + recommended + Redis

  AUTO-SWITCH (.phpvmrc)
    phpvm auto                     Switch to the version named in .phpvmrc
    phpvm hook enable              Enable auto-switching on cd (bash/zsh)
    phpvm hook disable             Disable the hook
    phpvm hook status              Check whether the hook is enabled

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
#  AUTO-SWITCH COMMANDS (phpvm auto, phpvm hook)
# ==============================================================================
phpvm_auto() {
    _phpvm_auto
}

phpvm_hook() {
    local sub="${1:-status}"
    local flag="$PHPVM_DIR/.auto-hook"
    case "$sub" in
        enable|install)
            mkdir -p "$PHPVM_DIR"
            touch "$flag"
            _ok "Hook enabled. Restart your shell, or run:"
            _dim "  source \"$PHPVM_DIR/phpvm.sh\""
            ;;
        disable|uninstall|remove)
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
        composer)              phpvm_composer ;;
        fix-ini)               phpvm_fix_ini ;;
        auto)                  phpvm_auto ;;
        hook)                  phpvm_hook      "$@" ;;
        upgrade|update)        phpvm_upgrade ;;
        version|-v)            _ok "phpvm $PHPVM_VERSION" ;;
        help|--help)           phpvm_help ;;
        *)                     phpvm_help ;;
    esac
}

# Tests / external sourcing can set PHPVM_NO_INIT=1 to skip the source-time
# side effects below (PATH manipulation + hook registration).
if [[ -z "${PHPVM_NO_INIT:-}" ]]; then
    # Auto-activate current version if set (on shell load)
    if [[ -L "$PHPVM_CURRENT" ]]; then
        _phpvm_use_path
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
