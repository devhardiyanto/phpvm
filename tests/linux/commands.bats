#!/usr/bin/env bats
# Tests for Sprint 5 Linux commands: composer, fix-ini, ext laravel.
# Run from repo root: bats tests/linux/

setup() {
    export PHPVM_DIR="$BATS_TEST_TMPDIR/phpvm"
    export PHPVM_VERSIONS="$PHPVM_DIR/versions"
    export PHPVM_CURRENT="$PHPVM_DIR/current"
    export PHPVM_NO_INIT=1
    export PHPVM_NO_UPDATE_CHECK=1
    mkdir -p "$PHPVM_VERSIONS"

    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../linux/phpvm.sh"
}

# Stand up a fake PHP install at $PHPVM_VERSIONS/$1 with a fake php binary
# whose behavior is driven by env vars the test sets. Stubs
# _phpvm_current_version directly so the suite works on Windows Git Bash
# (where `ln -s` produces a copy rather than a real symlink).
_fake_php_install() {
    local ver="$1"
    local root="$PHPVM_VERSIONS/$ver"
    mkdir -p "$root/bin" "$root/etc" "$root/lib/php/extensions"
    eval "_phpvm_current_version() { echo '$ver'; }"

    # The fake php binary supports: -m (extensions list), -r (one-liner),
    # -v, --version, and the composer-setup --quiet flow.
    cat > "$root/bin/php" <<'PHPEOF'
#!/usr/bin/env bash
# Test double for php. Behavior controlled via env:
#   FAKE_PHP_EXTS         space-separated extension names for -m
#   FAKE_PHP_EXT_DIR      value returned for ini_get('extension_dir') / PHP_EXTENSION_DIR
#   FAKE_PHP_HASH         value returned for hash_file()
case "$1" in
    -m) printf '%s\n' ${FAKE_PHP_EXTS:-Core openssl} ;;
    -r)
        case "$2" in
            *PHP_EXTENSION_DIR*)            printf '%s' "${FAKE_PHP_EXT_DIR:-/dev/null/ext}" ;;
            *ini_get*extension_dir*)        printf '%s' "${FAKE_PHP_EXT_DIR:-/dev/null/ext}" ;;
            *hash_file*)                    printf '%s' "${FAKE_PHP_HASH:-deadbeef}" ;;
            *extension_loaded*openssl*)
                case " ${FAKE_PHP_EXTS:-openssl} " in *" openssl "*) exit 0 ;; *) exit 1 ;; esac ;;
            *extension_loaded*)             exit 1 ;;
            *)                              ;;
        esac ;;
    -v|--version) echo "PHP fake" ;;
    *)
        # composer installer invocation: php /tmp/setup.php --quiet --filename=composer.phar
        # Just create a stub composer.phar in CWD.
        if [[ -n "${FAKE_COMPOSER_OK:-}" ]]; then
            echo '#!/usr/bin/env php' > composer.phar
        fi
        ;;
esac
PHPEOF
    chmod +x "$root/bin/php"

    # Default etc/php.ini for fix-ini tests
    printf ';extension_dir = "/old/path"\n' > "$root/etc/php.ini"
}

# ---------- phpvm_composer ----------

@test "composer: errors when no active version" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm_composer
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "composer: no-op when shim + phar already present" {
    _fake_php_install 8.3.0
    local bin="$PHPVM_VERSIONS/8.3.0/bin"
    touch "$bin/composer.phar"
    cat > "$bin/composer" <<'EOF'
#!/usr/bin/env sh
EOF
    chmod +x "$bin/composer"
    run phpvm_composer
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

# ---------- phpvm_fix_ini ----------

@test "fix-ini: errors when no active version" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm_fix_ini
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "fix-ini: rewrites commented extension_dir line" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions/no-debug-non-zts-20230831"
    run phpvm_fix_ini
    [ "$status" -eq 0 ]
    [[ "$output" == *"Fixed extension_dir"* ]]
    grep -q "^extension_dir = \"$FAKE_PHP_EXT_DIR\"" "$PHPVM_VERSIONS/8.3.0/etc/php.ini"
}

@test "fix-ini: appends extension_dir when missing" {
    _fake_php_install 8.3.0
    : > "$PHPVM_VERSIONS/8.3.0/etc/php.ini"   # empty ini
    export FAKE_PHP_EXT_DIR="/opt/ext"
    run phpvm_fix_ini
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added extension_dir"* ]]
    grep -q '^extension_dir = "/opt/ext"' "$PHPVM_VERSIONS/8.3.0/etc/php.ini"
}

@test "fix-ini: errors when php.ini missing" {
    _fake_php_install 8.3.0
    rm -f "$PHPVM_VERSIONS/8.3.0/etc/php.ini"
    run phpvm_fix_ini
    [ "$status" -ne 0 ]
    [[ "$output" == *"php.ini not found"* ]]
}

# ---------- phpvm_ext_laravel ----------

@test "ext laravel: errors when no active version" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm_ext_laravel
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "ext laravel: minimal preset reports already-loaded extensions" {
    _fake_php_install 8.3.0
    # All minimal extensions report as loaded → no enable attempts.
    export FAKE_PHP_EXTS="openssl pdo pdo_mysql pdo_sqlite mbstring tokenizer xml ctype fileinfo bcmath curl zip sodium"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions/no-debug-non-zts-20230831"
    mkdir -p "$FAKE_PHP_EXT_DIR"
    run phpvm_ext_laravel minimal
    [ "$status" -eq 0 ]
    [[ "$output" == *"minimal"* ]]
    [[ "$output" == *"already ON"* ]]
    [[ "$output" == *"Done"* ]]
}

@test "ext laravel: full preset banner + Redis hint" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core openssl"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions/no-debug-non-zts-20230831"
    mkdir -p "$FAKE_PHP_EXT_DIR"
    run phpvm_ext_laravel full
    [ "$status" -eq 0 ]
    [[ "$output" == *"full"* ]]
    [[ "$output" == *"PECL extensions"* ]]
}

@test "ext laravel: defaults to full when no preset arg" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions/no-debug-non-zts-20230831"
    mkdir -p "$FAKE_PHP_EXT_DIR"
    run phpvm_ext_laravel
    [ "$status" -eq 0 ]
    [[ "$output" == *"(full)"* ]]
}

# ---------- dispatch ----------

@test "dispatch: 'phpvm composer' routes to phpvm_composer" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm composer
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "dispatch: 'phpvm fix-ini' routes to phpvm_fix_ini" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm fix-ini
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "dispatch: 'phpvm ext laravel' routes to phpvm_ext_laravel" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm ext laravel
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

# ---------- did-you-mean ----------

@test "levenshtein: known distances" {
    [ "$(_phpvm_levenshtein kitten sitting)" -eq 3 ]
    [ "$(_phpvm_levenshtein install install)" -eq 0 ]
    [ "$(_phpvm_levenshtein intsall install)" -eq 2 ]
    [ "$(_phpvm_levenshtein '' list)" -eq 4 ]
}

@test "unknown: suggests nearest command for a close typo" {
    run phpvm intsall
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a phpvm command"* ]]
    [[ "$output" == *"Did you mean 'install'?"* ]]
}

@test "unknown: no suggestion when nothing is close" {
    run phpvm zzzzzz
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a phpvm command"* ]]
    [[ "$output" != *"Did you mean"* ]]
}

# ---------- partial version resolution ----------

@test "resolve: full x.y.z passes through without network" {
    run _phpvm_resolve_remote 8.3.10
    [ "$status" -eq 0 ]
    [ "$output" = "8.3.10" ]
}

@test "resolve: major.minor picks highest patch (stubbed curl)" {
    curl() { printf '%s' '{"8.3.31":{},"8.3.9":{},"8.4.22":{}}'; }
    run _phpvm_resolve_remote 8.3
    [ "$status" -eq 0 ]
    [ "$output" = "8.3.31" ]
}

@test "resolve: bare major picks highest overall (stubbed curl)" {
    curl() { printf '%s' '{"8.5.7":{},"8.4.22":{},"8.3.31":{}}'; }
    run _phpvm_resolve_remote 8
    [ "$status" -eq 0 ]
    [ "$output" = "8.5.7" ]
}

@test "resolve: 8.3 does not match 8.30.x (stubbed curl)" {
    curl() { printf '%s' '{"8.3.5":{},"8.30.1":{}}'; }
    run _phpvm_resolve_remote 8.3
    [ "$status" -eq 0 ]
    [ "$output" = "8.3.5" ]
}
