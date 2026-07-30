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
    _phpvm_check_openssl_compat "$ver" || return 1

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

    # Verify after both paths: a poisoned cache would otherwise be trusted
    # forever, since a cached tarball never gets re-downloaded.
    _step "Verifying SHA-256 ..."
    _phpvm_verify_tarball "$cache_file" "$ver" || return 1

    # Extract
    local src_dir="$PHPVM_CACHE/php-$ver"
    _step "Extracting ..."
    [[ -d "$src_dir" ]] && rm -rf "$src_dir"
    tar -xzf "$cache_file" -C "$PHPVM_CACHE"

    # Configure
    mkdir -p "$target"

    # www-data doesn't exist on macOS; its stock web user is _www. Only affects
    # the default user baked into php-fpm.conf, not the CLI build.
    local fpm_user="www-data"
    [[ "$(uname -s)" == "Darwin" ]] && fpm_user="_www"

    # gettext is keg-only on Homebrew: libintl.h isn't on the default include
    # path, so --with-gettext needs the explicit prefix. Linux has it in glibc.
    local gettext_opt="--with-gettext"
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
        gettext_opt="--with-gettext=$(brew --prefix gettext)"
    fi

    # gmp is keg-only on Homebrew AND ships no pkg-config (.pc) file, so the
    # PKG_CONFIG_PATH prepend below can't find it — configure needs the explicit
    # prefix or it fails with "GNU MP Library version 4.2 or greater required".
    # Linux resolves --with-gmp from the system libgmp-dev, so leave it bare.
    local gmp_opt="--with-gmp"
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
        gmp_opt="--with-gmp=$(brew --prefix gmp)"
    fi

    # libiconv is keg-only on Homebrew and ships no pkg-config file, so the
    # PKG_CONFIG_PATH prepend below can't find it — configure needs the explicit
    # prefix or iconv support fails to detect. Linux resolves iconv from glibc,
    # so leave it bare.
    local iconv_opt="--with-iconv"
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
        iconv_opt="--with-iconv=$(brew --prefix libiconv)"
    fi

    local configure_opts=(
        "--prefix=$target"
        "--with-config-file-path=$target/etc"
        "--with-config-file-scan-dir=$target/etc/conf.d"
        "--enable-fpm"
        "--with-fpm-user=$fpm_user"
        "--with-fpm-group=$fpm_user"
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
        "$gettext_opt"
        "$gmp_opt"
        "$iconv_opt"
        "--with-pgsql"
        "--with-pdo-pgsql"
        "--with-onig"
        "--with-pear"
    )

    local cpus
    cpus=$(_phpvm_cpus)

    # One install owns the log. Every step below appends, so without this the
    # file accumulates across runs and _phpvm_show_build_error's `grep -m1`
    # reports the first error of an *earlier* build — exactly the wrong line
    # when someone is retrying the install they just watched fail.
    : > "$PHPVM_LOG"

    # The whole build runs in a subshell so the `cd` cannot escape: phpvm.sh is
    # sourced, so a bare cd here would strand the user's own shell in the build
    # directory — which is then deleted, leaving them in a dangling cwd.
    (
        cd "$src_dir" || { _err "Could not enter source directory: $src_dir"; exit 1; }

        # macOS: Homebrew ships openssl@3/curl/zlib/... as keg-only, so pkg-config
        # can't find them on the default path. Prepend their pkgconfig dirs so
        # --with-openssl et al. resolve. No-op on Linux.
        if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
            brew_prefix="$(brew --prefix)"
            for keg in openssl@3 curl zlib libzip icu4c oniguruma readline libxml2 sqlite; do
                [[ -d "$brew_prefix/opt/$keg/lib/pkgconfig" ]] && \
                    PKG_CONFIG_PATH="$brew_prefix/opt/$keg/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
            done
            export PKG_CONFIG_PATH
        fi

        # >> + 2>&1 (not &>>): macOS still ships bash 3.2, which can't parse &>>.
        ./buildconf --force >>"$PHPVM_LOG" 2>&1 || true  # needed only for git checkouts

        _phpvm_run_logged "Configuring" ./configure "${configure_opts[@]}" \
            || { _err "Configure failed. See log: $PHPVM_LOG"; exit 1; }

        _phpvm_run_logged "Building with $cpus cores" make -j"$cpus" \
            || { _err "Build failed. See log: $PHPVM_LOG"; exit 1; }

        _phpvm_run_logged "Installing" make install \
            || { _err "Install failed. See log: $PHPVM_LOG"; exit 1; }
    ) || {
        _phpvm_show_build_error
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
    # paste -d takes a *list* of delimiters and cycles through it, so ', ' would
    # join as "a,b c". Join on a comma, then space it out.
    _dim "Older patch of ${ver%.*} still installed: $(echo "$older" | paste -sd, - | sed 's/,/, /g')"
    _dim "Remove it with: phpvm uninstall $newest"
}
