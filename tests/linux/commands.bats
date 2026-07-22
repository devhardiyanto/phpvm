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

@test "composer: no-op when global shim + phar already present" {
    _fake_php_install 8.3.0
    mkdir -p "$PHPVM_BIN"
    touch "$PHPVM_DIR/composer.phar"
    cat > "$PHPVM_BIN/composer" <<'EOF'
#!/usr/bin/env sh
EOF
    chmod +x "$PHPVM_BIN/composer"
    run phpvm_composer
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

# ---------- phpvm_wp_cli ----------

# Shell-function stub for curl: serves a fake phar for the download and
# $FAKE_WP_SHA for the .sha512 URL. `command -v curl` resolves functions too.
_stub_curl() {
    curl() {
        if [[ "$*" == *".sha512"* ]]; then
            printf '%s  wp-cli.phar\n' "$FAKE_WP_SHA"
            return 0
        fi
        local out="" prev=""
        for a in "$@"; do
            [[ "$prev" == "-o" ]] && out="$a"
            prev="$a"
        done
        [[ -n "$out" ]] && echo "fake phar" > "$out"
        return 0
    }
}

@test "wp-cli: errors when no active version" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm_wp_cli
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "wp-cli: no-op when global shim + phar already present" {
    _fake_php_install 8.3.0
    mkdir -p "$PHPVM_BIN"
    touch "$PHPVM_DIR/wp-cli.phar"
    cat > "$PHPVM_BIN/wp" <<'EOF'
#!/usr/bin/env sh
EOF
    chmod +x "$PHPVM_BIN/wp"
    run phpvm_wp_cli
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "wp-cli: downloads phar, verifies hash, writes wp shim" {
    _fake_php_install 8.3.0
    _stub_curl
    export FAKE_WP_SHA="cafe123"
    export FAKE_PHP_HASH="cafe123"
    run phpvm_wp_cli
    [ "$status" -eq 0 ]
    [[ "$output" == *"WP-CLI installed"* ]]
    [ -f "$PHPVM_DIR/wp-cli.phar" ]
    [ -x "$PHPVM_BIN/wp" ]
    grep -q "wp-cli.phar" "$PHPVM_BIN/wp"
}

@test "wp-cli: removes phar and writes no shim on hash mismatch" {
    _fake_php_install 8.3.0
    _stub_curl
    export FAKE_WP_SHA="cafe123"
    export FAKE_PHP_HASH="deadbeef"
    run phpvm_wp_cli
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA-512 mismatch"* ]]
    [ ! -f "$PHPVM_DIR/wp-cli.phar" ]
    [ ! -f "$PHPVM_BIN/wp" ]
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

@test "dispatch: 'phpvm wp-cli' routes to phpvm_wp_cli" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm wp-cli
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

# ---------- phpvm_install version guard ----------

@test "install: rejects a non-version argument before touching the network" {
    run phpvm_install composer
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid version 'composer'"* ]]
    [[ "$output" == *"Did you mean: phpvm composer"* ]]
}

@test "install: rejects a malformed version" {
    run phpvm_install 8.3.x
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid version"* ]]
}

@test "install: full x.y.z passes the guard (already-installed path)" {
    _fake_php_install 8.3.0
    run phpvm_install 8.3.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

# ---------- _phpvm_run_logged ----------

@test "run_logged: returns the command's exit code" {
    export PHPVM_LOG="$BATS_TEST_TMPDIR/build.log"
    run _phpvm_run_logged "Failing" false
    [ "$status" -ne 0 ]
    run _phpvm_run_logged "Passing" true
    [ "$status" -eq 0 ]
}

@test "run_logged: appends command output to the build log, not stdout" {
    export PHPVM_LOG="$BATS_TEST_TMPDIR/build.log"
    : > "$PHPVM_LOG"
    run _phpvm_run_logged "Echoing" echo "secret-build-noise"
    [ "$status" -eq 0 ]
    [[ "$output" != *"secret-build-noise"* ]]
    grep -q "secret-build-noise" "$PHPVM_LOG"
}

@test "run_logged: prints the label when stderr is not a tty (no spinner)" {
    export PHPVM_LOG="$BATS_TEST_TMPDIR/build.log"
    run _phpvm_run_logged "Configuring" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Configuring"* ]]
    # The spinner frames must never reach a non-tty stream.
    [[ "$output" != *$'\r'* ]]
}

# ---------- phpvm install --no-use ----------

@test "install --no-use: flag is stripped, version still parsed (flag last)" {
    run phpvm_install 8.3.x --no-use
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid version '8.3.x'"* ]]
}

@test "install --no-use: flag is stripped, version still parsed (flag first)" {
    run phpvm_install --no-use 8.3.x
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid version '8.3.x'"* ]]
}

@test "install --no-use: rejects an unknown option" {
    run phpvm_install 8.3.0 --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option: --bogus"* ]]
}

@test "install: bare --no-use without a version still errors on usage" {
    run phpvm_install --no-use
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: phpvm install"* ]]
}

# ---------- older-patch hint ----------

@test "older_patches: lists only lower patches of the same minor line" {
    mkdir -p "$PHPVM_VERSIONS"/{8.5.6,8.5.8,8.5.10,8.3.31,7.4.33}
    run _phpvm_older_patches 8.5.8
    [ "$status" -eq 0 ]
    [ "$output" = "8.5.6" ]
}

@test "older_patches: sorts numerically, not lexically" {
    mkdir -p "$PHPVM_VERSIONS"/{8.5.2,8.5.10,8.5.11}
    run _phpvm_older_patches 8.5.11
    [ "$status" -eq 0 ]
    [ "$output" = "8.5.2
8.5.10" ]
}

@test "older_patches: does not treat 8.50.x as part of the 8.5 line" {
    mkdir -p "$PHPVM_VERSIONS"/{8.50.1,8.5.9}
    run _phpvm_older_patches 8.5.9
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "older_patches: silent when it is the only patch of its line" {
    mkdir -p "$PHPVM_VERSIONS"/{8.5.8,8.3.31}
    run _phpvm_older_patches 8.5.8
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "older_patch_hint: names the version to uninstall" {
    mkdir -p "$PHPVM_VERSIONS"/{8.5.6,8.5.8}
    run _phpvm_older_patch_hint 8.5.8
    [ "$status" -eq 0 ]
    [[ "$output" == *"Older patch of 8.5 still installed: 8.5.6"* ]]
    [[ "$output" == *"phpvm uninstall 8.5.6"* ]]
}

# ---------- phpvm_doctor ----------

@test "doctor: warns when no active version" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"environment health check"* ]]
    [[ "$output" == *"No active PHP version"* ]]
    [[ "$output" == *"warning(s)"* ]]
}

@test "doctor: reports active version, ext_dir and openssl" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    export FAKE_PHP_EXTS="Core openssl"
    export PATH="$PHPVM_VERSIONS/8.3.0/bin:$PATH"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Active PHP version: 8.3.0"* ]]
    [[ "$output" == *"extension_dir present"* ]]
    [[ "$output" == *"openssl extension loaded"* ]]
}
