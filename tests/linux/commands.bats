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
#   FAKE_PHP_EXT_DIR      value returned for PHP_EXTENSION_DIR (the compiled-in dir)
#   FAKE_PHP_INI_EXT_DIR  value returned for ini_get('extension_dir'); defaults
#                         to FAKE_PHP_EXT_DIR, so the two agree unless a test
#                         deliberately drives them apart
#   FAKE_PHP_HASH         value returned for hash_file()
case "$1" in
    -m) printf '%s\n' ${FAKE_PHP_EXTS:-Core openssl} ;;
    -r)
        case "$2" in
            *PHP_EXTENSION_DIR*)            printf '%s' "${FAKE_PHP_EXT_DIR:-/dev/null/ext}" ;;
            *ini_get*extension_dir*)        printf '%s' "${FAKE_PHP_INI_EXT_DIR-${FAKE_PHP_EXT_DIR:-/dev/null/ext}}" ;;
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

# ---------- phpvm_ext_list / phpvm_ext_loaded ----------

# The row for one extension. Asserting on $output as a whole would let a glob
# like *redis*OFF* match "redis ... ON" on one line and the "0 OFF" summary on
# another, which is how a broken ON/OFF marker could slip through green.
# Colour codes butt straight up against the name ("\033[90mredis"), so strip
# them before matching or the leading word boundary never appears. printf for
# the escape rather than \x1b: BSD sed on the macOS runner does not read \x.
_ext_row() {
    printf '%s\n' "$output" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" \
        | grep -E "^[[:space:]]*$1[[:space:]]"
}

@test "ext list: errors when no active version" {
    eval "_phpvm_current_version() { echo ''; }"
    run phpvm_ext_list
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active PHP version"* ]]
}

@test "ext list: marks loaded extensions ON" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core curl mbstring"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    run phpvm_ext_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"curl"*"ON"* ]]
    [[ "$output" == *"mbstring"*"ON"* ]]
}

@test "ext list: marks an available-but-unloaded .so OFF" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core curl"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    touch "$FAKE_PHP_EXT_DIR/redis.so" "$FAKE_PHP_EXT_DIR/xdebug.so"
    run phpvm_ext_list
    [ "$status" -eq 0 ]
    [[ "$(_ext_row redis)"  == *OFF* ]]
    [[ "$(_ext_row xdebug)" == *OFF* ]]
    # Core and curl are the two loaded ones.
    [[ "$output" == *"2 ON, 2 OFF"* ]]
}

@test "ext list: an extension with a .so that is also loaded counts once, as ON" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core redis"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    touch "$FAKE_PHP_EXT_DIR/redis.so"
    run phpvm_ext_list
    [ "$status" -eq 0 ]
    [[ "$(_ext_row redis)" == *ON*  ]]
    [[ "$(_ext_row redis)" != *OFF* ]]
    [ "$(_ext_row redis | wc -l)" -eq 1 ]
    [[ "$output" == *"2 ON, 0 OFF"* ]]
}

@test "ext list: keeps statically compiled extensions that have no .so" {
    # The whole reason ON comes from `php -m` and not from the directory: pdo
    # and mbstring are built into the binary and own no file to find.
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core pdo mbstring"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    run phpvm_ext_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"pdo"* ]]
    [[ "$output" == *"mbstring"* ]]
    [[ "$output" == *"3 ON, 0 OFF"* ]]
}

@test "ext list: strips the php_ prefix some .so files carry" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    touch "$FAKE_PHP_EXT_DIR/php_imagick.so"
    run phpvm_ext_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"imagick"*"OFF"* ]]
    [[ "$output" != *"php_imagick"* ]]
}

@test "ext list: survives an extension_dir that does not exist" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core curl"
    export FAKE_PHP_EXT_DIR="$BATS_TEST_TMPDIR/nope"
    run phpvm_ext_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"curl"*"ON"* ]]
    [[ "$output" == *"2 ON, 0 OFF"* ]]
}

@test "ext loaded: shows php -m only, without the OFF entries" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core curl"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    touch "$FAKE_PHP_EXT_DIR/redis.so"
    run phpvm_ext_loaded
    [ "$status" -eq 0 ]
    [[ "$output" == *"curl"* ]]
    [[ "$output" != *"redis"* ]]
    [[ "$output" != *"OFF"* ]]
}

@test "dispatch: 'phpvm ext loaded' no longer routes to ext list" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXTS="Core curl"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    touch "$FAKE_PHP_EXT_DIR/redis.so"
    run phpvm ext loaded
    [ "$status" -eq 0 ]
    [[ "$output" != *"redis"* ]]
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

@test "unknown: suggests doctor for a doctor typo" {
    run phpvm doctro
    [ "$status" -ne 0 ]
    [[ "$output" == *"Did you mean 'doctor'?"* ]]
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

@test "older_patch_hint: separates several patches with a comma and a space" {
    # paste -d cycles its delimiter list, so ', ' used to join as "a,b c".
    mkdir -p "$PHPVM_VERSIONS"/{8.5.1,8.5.2,8.5.6,8.5.8}
    run _phpvm_older_patch_hint 8.5.8
    [ "$status" -eq 0 ]
    [[ "$output" == *"8.5.1, 8.5.2, 8.5.6"* ]]
    [[ "$output" != *"8.5.2 8.5.6"* ]]
}

# These checks assert on how many PHPs are visible, and CI images ship a distro
# php of their own - so where a test needs to own the answer it hands doctor a
# PATH containing nothing but phpvm. That works because the scan only needs `-x`
# on each candidate, never to run one, and no external tool to split PATH.

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
    [[ "$output" == *"extension_dir matches active build"* ]]
    [[ "$output" == *"openssl extension loaded"* ]]
}

@test "doctor: flags an extension_dir left pointing at another version" {
    _fake_php_install 8.3.0
    mkdir -p "$PHPVM_VERSIONS/8.2.0/lib/php/extensions"
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    # The stale dir exists, so the old `-d` check would have called this healthy.
    export FAKE_PHP_INI_EXT_DIR="$PHPVM_VERSIONS/8.2.0/lib/php/extensions"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"extension_dir mismatch"* ]]
    [[ "$output" == *"phpvm fix-ini"* ]]
}

@test "doctor: warns when extension_dir is unset in php.ini" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    export FAKE_PHP_INI_EXT_DIR=""
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"No extension_dir set"* ]]
}

@test "doctor: reads the active version's php, not whatever PATH resolves" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    # A foreign php earlier on PATH that would report a bogus extension_dir if
    # doctor trusted PATH instead of the version it says is active.
    mkdir -p "$BATS_TEST_TMPDIR/usrbin"
    cat > "$BATS_TEST_TMPDIR/usrbin/php" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -m) echo "Core" ;;
    -r) printf '%s' "/wrong/ext/dir" ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/usrbin/php"
    export PATH="$BATS_TEST_TMPDIR/usrbin:$PATH"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"extension_dir matches active build"* ]]
    [[ "$output" != *"/wrong/ext/dir"* ]]
}

# ---------- phpvm_doctor: PATH shadowing ----------

@test "doctor: names a second php further down PATH" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    mkdir -p "$BATS_TEST_TMPDIR/usrbin"
    printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/usrbin/php"
    chmod +x "$BATS_TEST_TMPDIR/usrbin/php"
    # phpvm wins the lookup, but the distro php is still sitting behind it.
    export PATH="$PHPVM_VERSIONS/8.3.0/bin:$BATS_TEST_TMPDIR/usrbin"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolves to phpvm"* ]]
    [[ "$output" == *"Another PHP on PATH"* ]]
    [[ "$output" == *"usrbin/php"* ]]
}

@test "doctor: stays quiet when phpvm is the only php on PATH" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    export PATH="$PHPVM_VERSIONS/8.3.0/bin"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolves to phpvm"* ]]
    [[ "$output" != *"Another PHP on PATH"* ]]
}

@test "doctor: does not report the winner twice as a shadowing php" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    mkdir -p "$BATS_TEST_TMPDIR/usrbin"
    printf '#!/usr/bin/env bash\n' > "$BATS_TEST_TMPDIR/usrbin/php"
    chmod +x "$BATS_TEST_TMPDIR/usrbin/php"
    # Non-phpvm php first: it is the winner *and* the only foreign entry, so it
    # must be reported once as the resolution problem, not again as a shadow.
    export PATH="$BATS_TEST_TMPDIR/usrbin:$PHPVM_VERSIONS/8.3.0/bin"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolves to a non-phpvm install"* ]]
    [[ "$output" != *"Another PHP on PATH"* ]]
}

# ---------- phpvm_doctor: host OpenSSL ----------

@test "doctor: warns that OpenSSL 3 rules out building PHP 8.0 and older" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    eval "_phpvm_openssl_version() { echo '3.0.2'; }"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenSSL 3.0.2"* ]]
    [[ "$output" == *"8.0 and older cannot be built"* ]]
}

@test "doctor: calls OpenSSL 1.1 fully buildable" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    eval "_phpvm_openssl_version() { echo '1.1.1'; }"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenSSL 1.1.1"* ]]
    [[ "$output" == *"all supported PHP versions buildable"* ]]
}

@test "doctor: does not count an undetectable OpenSSL as a warning" {
    _fake_php_install 8.3.0
    export FAKE_PHP_EXT_DIR="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
    eval "_phpvm_openssl_version() { return 1; }"
    run phpvm_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"build compatibility unknown"* ]]
    # Reported as a plain note, never as a [warn] the user is asked to fix.
    [[ "$output" != *"cannot be built"* ]]
}
