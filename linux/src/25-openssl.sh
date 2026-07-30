# Version of the OpenSSL that ./configure will actually resolve. pkg-config is
# what configure consults, so ask it first; the `openssl` CLI is a fallback and
# can disagree with the installed headers. Echoes "3.0.2"; non-zero if unknown.
_phpvm_openssl_version() {
    # LibreSSL and BoringSSL answer `openssl version` and ship an openssl.pc of
    # their own, but their 3.x still defines RSA_SSLV23_PADDING — the premise of
    # the guard below. Their numbering says nothing about it, so report the host
    # as unknown rather than block a build that would have succeeded.
    local banner=""
    command -v openssl &>/dev/null && banner=$(openssl version 2>/dev/null)
    [[ -n "$banner" && "$banner" != OpenSSL* ]] && return 1

    local v=""
    command -v pkg-config &>/dev/null && v=$(pkg-config --modversion openssl 2>/dev/null)
    [[ -z "$v" && -n "$banner" ]] && v=$(echo "$banner" | awk '{print $2}')
    # Strip a letter suffix: OpenSSL 1.1.1w -> 1.1.1
    v="${v%%[a-zA-Z]*}"
    [[ -n "$v" ]] || return 1
    echo "$v"
}

# PHP's ext/openssl references RSA_SSLV23_PADDING, which OpenSSL removed in
# 3.0. php-src only stopped using it in 8.1, so anything older dies partway
# through `make` with a wall of C errors. That is knowable up front, so refuse
# before spending ten minutes compiling.
#   https://github.com/php/php-src/issues/9503
# Escape hatch: PHPVM_SKIP_OPENSSL_CHECK=1 for setups where pkg-config resolves
# an OpenSSL 1.1 that this probe can't see.
_phpvm_check_openssl_compat() {
    local ver="$1"
    [[ -n "${PHPVM_SKIP_OPENSSL_CHECK:-}" ]] && return 0

    local major="${ver%%.*}" minor
    minor=$(echo "$ver" | cut -d. -f2)
    # PHP 8.1+ builds fine against OpenSSL 3.
    (( major > 8 )) && return 0
    (( major == 8 && minor >= 1 )) && return 0

    local ssl ssl_major
    ssl=$(_phpvm_openssl_version) || return 0   # can't tell -> don't block
    ssl_major="${ssl%%.*}"
    # A non-numeric major is something this probe doesn't model; `-lt` would
    # error and fall through to blocking, so fail open here too.
    [[ "$ssl_major" =~ ^[0-9]+$ ]] || return 0
    (( ssl_major < 3 )) && return 0

    _err "PHP $ver cannot be built against OpenSSL $ssl."
    _dim "OpenSSL 3.0 removed RSA_SSLV23_PADDING; PHP's openssl extension only"
    _dim "stopped using it in 8.1, so the build would fail in ext/openssl."
    echo ""
    _dim "Options:"
    _dim "  - Install a supported line:   phpvm install 8.1   (or newer)"
    _dim "  - Keep OpenSSL 1.1 as what pkg-config resolves, then re-run with:"
    _dim "      PHPVM_SKIP_OPENSSL_CHECK=1 phpvm install $ver"
    return 1
}

# ── Check build dependencies ──────────────────────────────────────────────────
