#!/usr/bin/env bats
# SHA-256 verification of the PHP source tarball: digest lookup against
# php.net's release JSON, local hashing, and the verify decision itself.
# Run from repo root: bats tests/linux/

setup() {
    export PHPVM_DIR="$BATS_TEST_TMPDIR/phpvm"
    export PHPVM_VERSIONS="$PHPVM_DIR/versions"
    export PHPVM_CURRENT="$PHPVM_DIR/current"
    export PHPVM_CACHE="$PHPVM_DIR/cache"
    export PHPVM_NO_INIT=1
    export PHPVM_NO_UPDATE_CHECK=1
    unset PHPVM_SKIP_HASH
    mkdir -p "$PHPVM_VERSIONS" "$PHPVM_CACHE"

    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../linux/phpvm.sh"
}

GZ_SUM=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BZ2_SUM=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
XZ_SUM=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

# A php.net release payload shaped like the real one: one "source" array with a
# sibling entry per archive format, all three carrying their own sha256.
_stub_release_json() {
    local ver="$1"
    local body="{\"date\":\"1 Jan 2024\",\"source\":[\
{\"filename\":\"php-$ver.tar.gz\",\"name\":\"PHP $ver (tar.gz)\",\"sha256\":\"$GZ_SUM\"},\
{\"filename\":\"php-$ver.tar.bz2\",\"name\":\"PHP $ver (tar.bz2)\",\"sha256\":\"$BZ2_SUM\"},\
{\"filename\":\"php-$ver.tar.xz\",\"name\":\"PHP $ver (tar.xz)\",\"sha256\":\"$XZ_SUM\"}],\
\"museum\":false}"
    # A function satisfies `command -v curl`, so the lookup takes the same
    # branch it would on a host that really has curl.
    eval "curl() { printf '%s' '$body'; }"
}

# ── digest lookup ─────────────────────────────────────────────────────────────

@test "php_sha256: picks the tar.gz digest, not its bz2/xz siblings" {
    _stub_release_json 8.3.0
    run _phpvm_php_sha256 8.3.0
    [ "$status" -eq 0 ]
    [ "$output" = "$GZ_SUM" ]
}

@test "php_sha256: fails when php.net answers with nothing" {
    eval "curl() { printf ''; }"
    run _phpvm_php_sha256 8.3.0
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "php_sha256: fails when the payload carries no sha256 at all" {
    eval "curl() { printf '%s' '{\"source\":[{\"filename\":\"php-8.3.0.tar.gz\"}]}'; }"
    run _phpvm_php_sha256 8.3.0
    [ "$status" -eq 1 ]
}

@test "php_sha256: does not hand back a digest belonging to another version" {
    # php.net answering for the wrong release must not silently satisfy us.
    _stub_release_json 8.3.0
    run _phpvm_php_sha256 8.2.0
    [ "$status" -eq 1 ]
}

# ── local hashing ─────────────────────────────────────────────────────────────

@test "sha256_file: digests a file with whatever tool the host has" {
    printf 'phpvm' > "$BATS_TEST_TMPDIR/f"
    run _phpvm_sha256_file "$BATS_TEST_TMPDIR/f"
    [ "$status" -eq 0 ]
    # Same string, same digest, whichever of the three tools answered.
    [ "${#output}" -eq 64 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

# ── the verify decision ───────────────────────────────────────────────────────

_stub_digests() {   # expected, actual
    eval "_phpvm_php_sha256() { echo '$1'; }"
    eval "_phpvm_sha256_file() { echo '$2'; }"
}

@test "verify: passes and keeps the file when digests agree" {
    printf 'tarball' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    _stub_digests "$GZ_SUM" "$GZ_SUM"
    run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"SHA-256 verified"* ]]
    [ -f "$PHPVM_CACHE/php-8.3.0.tar.gz" ]
}

@test "verify: fails and deletes the file when digests disagree" {
    printf 'tampered' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    _stub_digests "$GZ_SUM" "$BZ2_SUM"
    run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [ "$status" -eq 1 ]
    [[ "$output" == *"SHA-256 mismatch"* ]]
    # Left in place it would be reused forever - a cached tarball is never
    # re-downloaded.
    [ ! -f "$PHPVM_CACHE/php-8.3.0.tar.gz" ]
}

@test "verify: mismatch prints both digests so the user can see which is which" {
    printf 'tampered' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    _stub_digests "$GZ_SUM" "$BZ2_SUM"
    run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [[ "$output" == *"$GZ_SUM"* ]]
    [[ "$output" == *"$BZ2_SUM"* ]]
}

@test "verify: PHPVM_SKIP_HASH skips the check and leaves the file alone" {
    printf 'tampered' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    _stub_digests "$GZ_SUM" "$BZ2_SUM"
    PHPVM_SKIP_HASH=1 run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping SHA-256 verification"* ]]
    [ -f "$PHPVM_CACHE/php-8.3.0.tar.gz" ]
}

@test "verify: warns but proceeds when php.net publishes no digest" {
    printf 'tarball' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    eval "_phpvm_php_sha256() { return 1; }"
    run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"No published SHA-256"* ]]
    [ -f "$PHPVM_CACHE/php-8.3.0.tar.gz" ]
}

@test "verify: warns but proceeds when the host has no hashing tool" {
    printf 'tarball' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    eval "_phpvm_php_sha256() { echo '$GZ_SUM'; }"
    eval "_phpvm_sha256_file() { return 1; }"
    run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping verification"* ]]
    [ -f "$PHPVM_CACHE/php-8.3.0.tar.gz" ]
}

@test "verify: an empty digest from php.net is treated as no digest, not a mismatch" {
    printf 'tarball' > "$PHPVM_CACHE/php-8.3.0.tar.gz"
    eval "_phpvm_php_sha256() { echo ''; }"
    run _phpvm_verify_tarball "$PHPVM_CACHE/php-8.3.0.tar.gz" 8.3.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"No published SHA-256"* ]]
    [ -f "$PHPVM_CACHE/php-8.3.0.tar.gz" ]
}
