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
