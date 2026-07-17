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

PHPVM_VERSION="1.11.0"
PHPVM_DIR="${PHPVM_DIR:-$HOME/.phpvm}"
PHPVM_VERSIONS="$PHPVM_DIR/versions"
PHPVM_CURRENT="$PHPVM_DIR/current"
PHPVM_BIN="$PHPVM_DIR/bin"          # global shims (composer) — always on PATH
PHPVM_CACHE="$PHPVM_DIR/cache"
PHPVM_LOG="$PHPVM_DIR/build.log"
PHPVM_UPDATE_URL="https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
PHPVM_LAST_CHECK="$PHPVM_DIR/.last_update_check"
PHPVM_CHECK_INTERVAL=86400  # 24 hours

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

# ── Update checker (once per day, via version.txt) ───────────────────────────
_phpvm_check_update() {
    # Skip in CI or if explicitly disabled
    [[ -n "${CI:-}" || -n "${PHPVM_NO_UPDATE_CHECK:-}" ]] && return

    # Only check once per day
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
            _dim "    libgmp-dev libsodium-dev libmysqlclient-dev libpq-dev"
            ;;
        dnf|yum)
            _dim "  sudo $pm install -y \\"
            _dim "    gcc make autoconf bison re2c pkg-config \\"
            _dim "    libxml2-devel sqlite-devel openssl-devel libcurl-devel \\"
            _dim "    oniguruma-devel libzip-devel zlib-devel readline-devel \\"
            _dim "    libpng-devel libjpeg-devel libwebp-devel freetype-devel \\"
            _dim "    gmp-devel libsodium-devel mysql-devel postgresql-devel"
            ;;
        pacman)
            _dim "  sudo pacman -S --needed \\"
            _dim "    base-devel autoconf bison re2c pkg-config \\"
            _dim "    libxml2 sqlite openssl curl oniguruma libzip \\"
            _dim "    libpng libjpeg libwebp freetype2 gmp libsodium mysql-libs postgresql-libs"
            ;;
        zypper)
            _dim "  sudo zypper install -y \\"
            _dim "    gcc make autoconf bison re2c pkg-config \\"
            _dim "    libxml2-devel sqlite3-devel libopenssl-devel libcurl-devel \\"
            _dim "    oniguruma-devel libzip-devel zlib-devel readline-devel \\"
            _dim "    libsodium-devel"
            ;;
        brew)
            _dim "  brew install \\"
            _dim "    autoconf bison re2c pkg-config \\"
            _dim "    openssl@3 libxml2 sqlite curl oniguruma libzip zlib readline \\"
            _dim "    libpng jpeg webp freetype gmp libsodium gettext"
            _dim "  (Xcode Command Line Tools required: xcode-select --install)"
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

# Run a long build step with its output appended to $PHPVM_LOG, showing a live
# spinner + elapsed time so a multi-minute `make` never looks hung.
#   _phpvm_run_logged "Building with 8 cores" make -j8
# The spinner is drawn on stderr and only when stderr is a terminal, so CI and
# the bats suite see exactly the output they saw before. Returns the real exit
# code of the command.
_phpvm_run_logged() {
    local label="$1"; shift

    if [[ ! -t 2 ]]; then
        _step "$label ..."
        "$@" >> "$PHPVM_LOG" 2>&1
        return $?
    fi

    # phpvm.sh is sourced into an interactive shell, where job control is on and
    # would print "[3] 2015" / "[3] + done ..." around our background build.
    # Turn the monitor off for the duration and put it back exactly as we found it.
    local had_monitor=0
    case "$-" in *m*) had_monitor=1; set +m ;; esac

    "$@" >> "$PHPVM_LOG" 2>&1 &
    local pid=$!

    # Ctrl+C must take the build down with us, not orphan it.
    trap 'kill "$pid" 2>/dev/null; printf "\r\033[K" >&2; [[ $had_monitor -eq 1 ]] && set -m; trap - INT; return 130' INT

    # Plain ASCII frames + explicit index: ${var:i++:1} is a bashism that bites
    # in zsh, and Unicode braille spinners mangle on older terminals.
    local frames="|/-\\"
    local i=0 start=$SECONDS elapsed frame
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - start))
        frame=${frames:$i:1}
        i=$(( (i + 1) % 4 ))
        printf '\r\033[36m  %s %s ... %dm%02ds\033[0m' \
            "$frame" "$label" $((elapsed / 60)) $((elapsed % 60)) >&2
        sleep 0.5
    done

    wait "$pid"
    local rc=$?
    trap - INT
    [[ $had_monitor -eq 1 ]] && set -m
    printf '\r\033[K' >&2

    elapsed=$((SECONDS - start))
    if [[ $rc -eq 0 ]]; then
        _step "$label ... done in $((elapsed / 60))m$((elapsed % 60))s"
    fi
    return $rc
}

# Resolve a partial version to the highest published patch on php.net.
#   "8"   -> latest 8.x   (e.g. 8.5.7)
#   "8.3" -> latest 8.3.x (e.g. 8.3.31)
# A full "x.y.z" passes through untouched. Echoes the resolved version on
# success; non-zero exit if nothing matched or the network was unreachable.
_phpvm_resolve_remote() {
    local req="$1"
    [[ "$req" =~ ^[0-9]+$ || "$req" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "$req"; return 0; }

    local major="${req%%.*}"
    local api="https://www.php.net/releases/index.php?json&max=100&version=$major"
    local json
    if command -v curl &>/dev/null; then
        json=$(curl -fsSL --max-time 10 "$api" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        json=$(wget -qO- --timeout=10 "$api" 2>/dev/null)
    fi
    [[ -z "$json" ]] && return 1

    # Top-level JSON keys are "x.y.z" version strings; keep the ones whose
    # prefix matches the request (the (\.|$) guard stops 8.3 matching 8.30.x).
    local match
    match=$(printf '%s\n' "$json" \
        | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' \
        | tr -d '"' \
        | grep -E "^${req//./\\.}(\.|$)" \
        | sort -V | tail -1)
    [[ -n "$match" ]] || return 1
    echo "$match"
}

# ==============================================================================
#  phpvm install <version>
# ==============================================================================
phpvm_install() {
    local ver="" no_use=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-use) no_use=1 ;;
            -*)       _err "Unknown option: $1. Usage: phpvm install <version> [--no-use]"; return 1 ;;
            *)        [[ -z "$ver" ]] && ver="$1" ;;
        esac
        shift
    done
    [[ -z "$ver" ]] && { _err "Usage: phpvm install <version> [--no-use]  (e.g. phpvm install 8.3.0)"; return 1; }

    # Partial version: "8" -> latest 8.x, "8.3" -> latest 8.3.x.
    if [[ "$ver" =~ ^[0-9]+$ || "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
        _step "Resolving latest patch for PHP $ver ..."
        local resolved
        if resolved=$(_phpvm_resolve_remote "$ver") && [[ -n "$resolved" ]]; then
            _ok "Latest PHP $ver -> $resolved"
            ver="$resolved"
        else
            _err "Could not resolve a release for PHP $ver."
            _dim "Browse available versions: https://www.php.net/releases/"
            return 1
        fi
    fi

    # Reject non-versions up front; otherwise they only fail later as a confusing
    # "Download failed" from php.net.
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _err "Invalid version '$ver'. Usage: phpvm install <version>  (e.g. phpvm install 8.3.0)"
        [[ "$ver" == "composer" ]] && _dim "Did you mean: phpvm composer"
        return 1
    fi

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
        "--with-sodium"
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
        "--with-pear"
    )

    local cpus
    cpus=$(_phpvm_cpus)

    # The whole build runs in a subshell so the `cd` cannot escape: phpvm.sh is
    # sourced, so a bare cd here would strand the user's own shell in the build
    # directory — which is then deleted, leaving them in a dangling cwd.
    (
        cd "$src_dir" || { _err "Could not enter source directory: $src_dir"; exit 1; }

        # >> + 2>&1 (not &>>): macOS still ships bash 3.2, which can't parse &>>.
        ./buildconf --force >>"$PHPVM_LOG" 2>&1 || true  # needed only for git checkouts

        _phpvm_run_logged "Configuring" ./configure "${configure_opts[@]}" \
            || { _err "Configure failed. See log: $PHPVM_LOG"; exit 1; }

        _phpvm_run_logged "Building with $cpus cores" make -j"$cpus" \
            || { _err "Build failed. See log: $PHPVM_LOG"; exit 1; }

        _phpvm_run_logged "Installing" make install \
            || { _err "Install failed. See log: $PHPVM_LOG"; exit 1; }
    ) || {
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

    # Activate the freshly built version right away, unless opted out.
    if [[ $no_use -eq 1 ]]; then
        _dim "Not switching (--no-use). Run: phpvm use $ver"
    else
        phpvm_use "$ver"
    fi

    _phpvm_older_patch_hint "$ver"
}

# `phpvm install 8` resolves to the newest patch and installs it alongside any
# older patch of the same line. Point that out rather than removing it: another
# project may still pin the old patch in .phpvmrc.
_phpvm_older_patches() {
    local ver="$1"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    [[ -d "$PHPVM_VERSIONS" ]] || return 0

    local line="${ver%.*}" name
    find "$PHPVM_VERSIONS" -mindepth 1 -maxdepth 1 -type d -name "$line.*" 2>/dev/null \
        | while read -r d; do
            name=$(basename "$d")
            [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            [[ "$name" == "$ver" ]] && continue
            # Keep only patches strictly below $ver.
            [[ "$(printf '%s\n%s' "$name" "$ver" | sort -V | head -1)" == "$name" ]] && echo "$name"
        done | sort -V
}

_phpvm_older_patch_hint() {
    local ver="$1" older newest
    older=$(_phpvm_older_patches "$ver")
    [[ -z "$older" ]] && return 0

    newest=$(echo "$older" | tail -1)
    _dim "Older patch of ${ver%.*} still installed: $(echo "$older" | paste -sd ', ' -)"
    _dim "Remove it with: phpvm uninstall $newest"
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
    php --version 2>/dev/null | head -1 | sed 's/^/  /'
    # Only nudge if phpvm isn't wired into a shell rc yet — otherwise this is
    # already persistent and the warning is just noise on every `use`.
    _phpvm_in_rc || _warn "To persist across sessions, add to your shell rc: source \"$PHPVM_DIR/phpvm.sh\""
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
        php --version 2>/dev/null | sed 's/^/  /'
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

    _phpvm_ext_preflight "$name" || return 1

    local ver="${2:-}"
    if [[ -n "$ver" ]]; then
        _step "Installing $name-$ver via PECL ..."
        pecl install "$name-$ver" || {
            _err "Failed to install $name-$ver via PECL."
            _phpvm_ext_runtime_notes "$name"
            return 1
        }
    else
        _step "Installing $name via PECL ..."
        pecl install "$name" || {
            _err "Failed to install $name via PECL."
            _phpvm_ext_runtime_notes "$name"
            return 1
        }
    fi

    _ok "Done. Enable with: phpvm ext enable $name"
    _phpvm_ext_runtime_notes "$name"
}

# Build-time prerequisites for specific extensions. Warn early instead of
# letting `pecl install` fail mid-build with cryptic compiler errors.
_phpvm_ext_preflight() {
    local name="$1"
    case "$name" in
        sqlsrv|pdo_sqlsrv)
            # unixODBC headers (sql.h / sqlext.h) are required to compile sqlsrv.
            if command -v odbc_config &>/dev/null; then return 0; fi
            local inc
            for inc in /usr/include/sql.h /usr/local/include/sql.h \
                       /opt/homebrew/include/sql.h /opt/homebrew/opt/unixodbc/include/sql.h \
                       /usr/local/opt/unixodbc/include/sql.h; do
                [[ -f "$inc" ]] && return 0
            done
            _warn "unixODBC development headers not found — required to build $name."
            local pm
            pm=$(_phpvm_detect_os)
            case "$pm" in
                apt)    _dim "Install: sudo apt-get install -y unixodbc-dev" ;;
                dnf)    _dim "Install: sudo dnf install -y unixODBC-devel" ;;
                yum)    _dim "Install: sudo yum install -y unixODBC-devel" ;;
                pacman) _dim "Install: sudo pacman -S --needed unixodbc" ;;
                zypper) _dim "Install: sudo zypper install -y unixODBC-devel" ;;
                brew)   _dim "Install: brew install unixodbc" ;;
                *)      _dim "Install unixODBC development headers via your package manager." ;;
            esac
            _dim "Then retry: phpvm ext install $name"
            return 1
            ;;
    esac
    return 0
}

# Post-install advisories for extensions that need extra system components.
_phpvm_ext_runtime_notes() {
    local name="$1"
    case "$name" in
        sqlsrv|pdo_sqlsrv)
            echo ""
            _dim "Note: $name also requires the Microsoft ODBC Driver for SQL Server"
            _dim "to actually connect at runtime. Install (one-off, system-wide):"
            _dim "  https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server"
            _dim "Setup guide: https://learn.microsoft.com/sql/connect/php/step-1-configure-development-environment-for-php-development"
            ;;
    esac
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
#  COMPOSER (one global composer that follows the active PHP version)
# ==============================================================================
phpvm_composer() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local phar="$PHPVM_DIR/composer.phar"
    local shim="$PHPVM_BIN/composer"

    if [[ -x "$shim" && -f "$phar" ]]; then
        _warn "Composer already installed at $shim"
        _dim "It follows your active PHP version automatically."
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
    mkdir -p "$PHPVM_BIN"
    (cd "$PHPVM_DIR" && "$php_bin" "$tmp" --quiet --filename=composer.phar) || {
        _err "Composer installer failed."
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"

    [[ ! -f "$phar" ]] && { _err "composer.phar not created at $phar"; return 1; }

    # POSIX shim — execs the *current* PHP, so composer tracks `phpvm use`
    # without reinstalling. Works in bash/zsh/sh.
    cat > "$shim" <<EOF
#!/usr/bin/env sh
exec "$PHPVM_CURRENT/bin/php" "$phar" "\$@"
EOF
    chmod +x "$shim"

    _ok "Composer installed (global)!"
    _ok "  phar : $phar"
    _ok "  shim : $shim"
    echo ""
    "$php_bin" "$phar" --version 2>/dev/null | sed 's/^/  /'
    echo ""
    _dim "Composer follows your active PHP version — no need to re-run after 'phpvm use'."
}

# ==============================================================================
#  WP-CLI (one global wp that follows the active PHP version)
# ==============================================================================
phpvm_wp_cli() {
    local cur
    cur=$(_phpvm_current_version)
    [[ -z "$cur" ]] && { _err "No active PHP version. Run: phpvm use <version>"; return 1; }

    local php_bin="$PHPVM_VERSIONS/$cur/bin/php"
    [[ ! -x "$php_bin" ]] && { _err "php binary not found: $php_bin"; return 1; }

    local phar="$PHPVM_DIR/wp-cli.phar"
    local shim="$PHPVM_BIN/wp"

    if [[ -x "$shim" && -f "$phar" ]]; then
        _warn "WP-CLI already installed at $shim"
        _dim "It follows your active PHP version automatically."
        _dim "Run: wp --version"
        return 0
    fi

    local phar_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
    local hash_url="$phar_url.sha512"

    _step "Downloading WP-CLI ..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$phar_url" -o "$phar" || { _err "Download failed."; rm -f "$phar"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$phar" "$phar_url" || { _err "Download failed."; rm -f "$phar"; return 1; }
    else
        _err "curl or wget is required."; return 1
    fi

    _step "Verifying SHA-512 ..."
    local expected actual
    if command -v curl &>/dev/null; then
        expected=$(curl -fsSL "$hash_url" 2>/dev/null | awk '{print $1}')
    else
        expected=$(wget -qO- "$hash_url" 2>/dev/null | awk '{print $1}')
    fi
    # Hash through PHP itself (always present) — no sha512sum/shasum coreutils
    # split between GNU and BSD/macOS.
    actual=$("$php_bin" -r "echo hash_file('sha512', '$phar');" 2>/dev/null)

    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        _err "SHA-512 mismatch! Phar may be corrupt or tampered."
        rm -f "$phar"
        return 1
    fi
    _ok "SHA-512 verified."

    mkdir -p "$PHPVM_BIN"
    cat > "$shim" <<EOF
#!/usr/bin/env sh
exec "$PHPVM_CURRENT/bin/php" "$phar" "\$@"
EOF
    chmod +x "$shim"

    _ok "WP-CLI installed (global)!"
    _ok "  phar : $phar"
    _ok "  shim : $shim"
    echo ""
    "$php_bin" "$phar" --version 2>/dev/null | sed 's/^/  /'
    echo ""
    _dim "WP-CLI follows your active PHP version — no need to re-run after 'phpvm use'."
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
                                     --no-use  install without switching to it
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php binary
    phpvm ini                      Open active php.ini in \$EDITOR
    phpvm fix-ini                  Sync extension_dir in active php.ini
    phpvm deps                     Print dependency install command

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

  Home:      $PHPVM_DIR
  Build log: $PHPVM_LOG

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
    local -a row
    for (( j = 0; j <= lb; j++ )); do row[j]=$j; done
    for (( i = 1; i <= la; i++ )); do
        prev=${row[0]}
        row[0]=$i
        for (( j = 1; j <= lb; j++ )); do
            cur=${row[j]}
            if [[ "${a:i-1:1}" == "${b:j-1:1}" ]]; then cost=0; else cost=1; fi
            del=$(( row[j] + 1 )); ins=$(( row[j-1] + 1 )); sub=$(( prev + cost ))
            min=$del
            (( ins < min )) && min=$ins
            (( sub < min )) && min=$sub
            row[j]=$min
            prev=$cur
        done
    done
    echo "${row[lb]}"
}

# Canonical command list (includes aliases) for suggestions.
_PHPVM_COMMANDS="install use list ls current uninstall remove which ini deps ext composer wp-cli fix-ini auto hook upgrade update version help"

# Unknown command: suggest the nearest match instead of dumping the full help.
_phpvm_unknown() {
    local cmd="$1"
    local best="" bestd=99 c d
    for c in $_PHPVM_COMMANDS; do
        d=$(_phpvm_levenshtein "$cmd" "$c")
        (( d < bestd )) && { bestd=$d; best=$c; }
    done
    _err "'$cmd' is not a phpvm command."
    (( bestd <= 2 )) && _dim "Did you mean '$best'?"
    _dim "Run 'phpvm help' to see all commands."
    return 1
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
