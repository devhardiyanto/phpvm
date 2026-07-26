#!/usr/bin/env bats
# Build preflight: the OpenSSL 3 vs PHP < 8.1 guard and the build-log error
# surfacing. Older-patch hint formatting lives in commands.bats.
# Run from repo root: bats tests/linux/

setup() {
    export PHPVM_DIR="$BATS_TEST_TMPDIR/phpvm"
    export PHPVM_VERSIONS="$PHPVM_DIR/versions"
    export PHPVM_CURRENT="$PHPVM_DIR/current"
    export PHPVM_LOG="$BATS_TEST_TMPDIR/build.log"
    export PHPVM_NO_INIT=1
    export PHPVM_NO_UPDATE_CHECK=1
    unset PHPVM_SKIP_OPENSSL_CHECK
    mkdir -p "$PHPVM_VERSIONS"

    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../linux/phpvm.sh"
}

# Pin the detected OpenSSL version so the result doesn't depend on the host.
_stub_openssl() {
    eval "_phpvm_openssl_version() { echo '$1'; }"
}

# Pin what `openssl version` reports, to exercise the probe itself. A function
# satisfies `command -v openssl`, so the probe takes the same path it would on
# a host that really ships this binary.
_stub_openssl_cli() {
    eval "openssl() { [ \"\$1\" = version ] && echo '$1'; }"
}

# ── OpenSSL compatibility guard ───────────────────────────────────────────────

@test "openssl 3 blocks PHP 7.3" {
    _stub_openssl 3.0.2
    run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be built against OpenSSL 3.0.2"* ]]
}

@test "openssl 3 blocks PHP 7.4 and 8.0" {
    _stub_openssl 3.2.1
    run _phpvm_check_openssl_compat 7.4.33
    [ "$status" -eq 1 ]
    run _phpvm_check_openssl_compat 8.0.30
    [ "$status" -eq 1 ]
}

@test "openssl 3 allows PHP 8.1 and newer" {
    _stub_openssl 3.0.2
    run _phpvm_check_openssl_compat 8.1.0
    [ "$status" -eq 0 ]
    run _phpvm_check_openssl_compat 8.3.10
    [ "$status" -eq 0 ]
    run _phpvm_check_openssl_compat 9.0.0
    [ "$status" -eq 0 ]
}

@test "openssl 1.1 allows old PHP" {
    _stub_openssl 1.1.1
    run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 0 ]
}

@test "undetectable openssl does not block the build" {
    eval "_phpvm_openssl_version() { return 1; }"
    run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 0 ]
}

@test "PHPVM_SKIP_OPENSSL_CHECK overrides the guard" {
    _stub_openssl 3.0.2
    PHPVM_SKIP_OPENSSL_CHECK=1 run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 0 ]
}

@test "the block message names the remedy" {
    _stub_openssl 3.0.2
    run _phpvm_check_openssl_compat 7.3.33
    [[ "$output" == *"phpvm install 8.1"* ]]
    [[ "$output" == *"PHPVM_SKIP_OPENSSL_CHECK=1"* ]]
}

@test "a non-numeric openssl major does not block the build" {
    _stub_openssl "unknown"
    run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 0 ]
}

@test "libressl reports as unknown rather than blocking" {
    _stub_openssl_cli "LibreSSL 3.3.6"
    run _phpvm_openssl_version
    [ "$status" -eq 1 ]
    # LibreSSL 3.x still defines RSA_SSLV23_PADDING, so PHP 7.3 must build.
    run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 0 ]
}

@test "boringssl reports as unknown rather than blocking" {
    _stub_openssl_cli "BoringSSL 3.0.0"
    run _phpvm_check_openssl_compat 7.3.33
    [ "$status" -eq 0 ]
}

@test "a genuine OpenSSL banner still yields a version" {
    _stub_openssl_cli "OpenSSL 3.0.13 30 Jan 2024"
    run _phpvm_openssl_version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

@test "openssl version probe strips a letter suffix" {
    # Only meaningful when the host actually has one of the probes.
    if ! command -v pkg-config &>/dev/null && ! command -v openssl &>/dev/null; then
        skip "no pkg-config or openssl on this host"
    fi
    run _phpvm_openssl_version
    if [ "$status" -eq 0 ]; then
        [[ "$output" =~ ^[0-9]+(\.[0-9]+)*$ ]]
    fi
}

# ── Build log error surfacing ────────────────────────────────────────────────

@test "surfaces the first compiler error from the log" {
    cat > "$PHPVM_LOG" <<'LOG'
checking for gcc... yes
gcc -c foo.c -o foo.o
ext/openssl/openssl.c:1491:58: error: 'RSA_SSLV23_PADDING' undeclared
make: *** [Makefile:736: ext/openssl/openssl.lo] Error 1
LOG
    run _phpvm_show_build_error
    [[ "$output" == *"First error in the log"* ]]
    [[ "$output" == *"RSA_SSLV23_PADDING"* ]]
}

@test "prefers a configure error over later compiler noise" {
    cat > "$PHPVM_LOG" <<'LOG'
checking for libxml... no
configure: error: Package requirements (libxml-2.0) were not met
something.c:1:1: error: later noise
LOG
    run _phpvm_show_build_error
    [[ "$output" == *"libxml-2.0"* ]]
    [[ "$output" != *"later noise"* ]]
}

@test "stays quiet when the log holds no error" {
    printf 'all good\nbuild complete\n' > "$PHPVM_LOG"
    run _phpvm_show_build_error
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stays quiet when there is no log at all" {
    rm -f "$PHPVM_LOG"
    run _phpvm_show_build_error
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Every build step appends, so one install must start the log from empty or
# `grep -m1` above surfaces the first error of a *previous* run. Driving a real
# install here would mean a compiler and ten minutes, so assert the ordering in
# phpvm_install's own body instead.
@test "install truncates the build log before anything appends to it" {
    local src="$BATS_TEST_DIRNAME/../../linux/phpvm.sh"
    local body trunc append
    body=$(awk '/^phpvm_install\(\)/{f=1} f{print} f&&/^}$/{exit}' "$src")

    trunc=$(printf '%s\n' "$body" | grep -n ': > "\$PHPVM_LOG"' | head -1 | cut -d: -f1)
    append=$(printf '%s\n' "$body" | grep -n '>>"\?\$PHPVM_LOG"\?' | head -1 | cut -d: -f1)

    [ -n "$trunc" ]
    [ -n "$append" ]
    [ "$trunc" -lt "$append" ]
}
