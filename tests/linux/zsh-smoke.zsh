#!/usr/bin/env zsh
# zsh compatibility smoke for linux/phpvm.sh.
#
# The bats suite runs under bash, so nothing else in this repo exercises zsh -
# yet phpvm.sh is documented as bash/zsh and registers a chpwd hook for zsh
# users. Anything that quietly depends on bash semantics (0-indexed arrays,
# word-splitting on unquoted parameters) only shows up here.
#
# Run from repo root:  zsh tests/linux/zsh-smoke.zsh

emulate -R zsh   # no bash/ksh compatibility crutches - test zsh as users get it

typeset -i fail=0

check() {  # check <name> <expected-substring> <actual>
    if [[ "$3" == *"$2"* ]]; then
        print "ok   - $1"
    else
        print "FAIL - $1"
        print "       expected to contain: $2"
        print "       actual: $3"
        fail=1
    fi
}

check_status() {  # check_status <name> <expected> <actual>
    if [[ "$3" == "$2" ]]; then
        print "ok   - $1"
    else
        print "FAIL - $1 (expected status $2, got $3)"
        fail=1
    fi
}

check_empty() {  # check_empty <name> <actual>
    if [[ -z "$2" ]]; then
        print "ok   - $1"
    else
        print "FAIL - $1"
        print "       expected no output, got: $2"
        fail=1
    fi
}

tmp=$(mktemp -d)
export PHPVM_DIR="$tmp/phpvm"
export PHPVM_NO_UPDATE_CHECK=1
export PHPVM_NO_INIT=1
if ! source ./linux/phpvm.sh; then
    print "FAIL - phpvm.sh could not be sourced under zsh"
    exit 1
fi
unset PHPVM_NO_INIT

print -r -- "-- levenshtein (array indexing) --"
out=$(_phpvm_levenshtein kitten sitting 2>&1)
check "levenshtein kitten/sitting = 3" "3" "$out"
out=$(_phpvm_levenshtein '' abc 2>&1)
check "levenshtein ''/abc = 3" "3" "$out"
out=$(_phpvm_levenshtein same same 2>&1)
check "levenshtein same/same = 0" "0" "$out"

print -r -- "-- did-you-mean (command-list splitting) --"
out=$(phpvm instal 2>&1)
check "suggests install for 'instal'" "Did you mean 'install'" "$out"
out=$(phpvm doctro 2>&1)
check "suggests doctor for 'doctro'" "Did you mean 'doctor'" "$out"
out=$(phpvm zzzzzzzzzz 2>&1)
check "no suggestion for nonsense" "is not a phpvm command" "$out"

print -r -- "-- basic read-only commands --"
out=$(phpvm version 2>&1)
check "version prints the version" "phpvm" "$out"
out=$(phpvm list 2>&1)
check "list runs without error" "No PHP versions installed" "$out"
out=$(phpvm help 2>&1)
check "help runs" "PHP Version Manager" "$out"
out=$(phpvm current 2>&1)
check "current runs" "No PHP version" "$out"

print -r -- "-- .phpvmrc parsing --"
mkdir -p "$tmp/proj"
print "8.3" > "$tmp/proj/.phpvmrc"
out=$(cd "$tmp/proj" && _phpvm_read_rc "$tmp/proj/.phpvmrc" 2>&1)
check "reads a .phpvmrc version" "8.3" "$out"

print -r -- "-- openssl guard (pattern and regex matching) --"
# The guard leans on [[ != OpenSSL* ]] globbing and [[ =~ ]] regex, both of
# which zsh parses on its own terms. bats only ever sees the bash reading.
# Probe first, while the real _phpvm_openssl_version is still in place.
openssl() { [[ "$1" == version ]] && print "LibreSSL 3.3.6" }
_phpvm_openssl_version >/dev/null 2>&1
check "libressl reports as unknown" "1" "$?"
unset -f openssl

_phpvm_openssl_version() { print 3.0.2 }
out=$(_phpvm_check_openssl_compat 7.3.33 2>&1)
check "openssl 3 blocks PHP 7.3" "cannot be built against OpenSSL 3.0.2" "$out"
_phpvm_check_openssl_compat 8.1.0 >/dev/null 2>&1
check "openssl 3 allows PHP 8.1" "0" "$?"
_phpvm_openssl_version() { print unknown }
_phpvm_check_openssl_compat 7.3.33 >/dev/null 2>&1
check "non-numeric openssl major fails open" "0" "$?"

print -r -- "-- older-patch hint --"
mkdir -p "$PHPVM_DIR/versions/8.5.1" "$PHPVM_DIR/versions/8.5.2" "$PHPVM_DIR/versions/8.5.8"
out=$(_phpvm_older_patch_hint 8.5.8 2>&1)
check "joins older patches with ', '" "8.5.1, 8.5.2" "$out"

print -r -- "-- build preflight (OpenSSL guard) --"
# Pin the probe so the result doesn't depend on whatever the runner has.
_phpvm_openssl_version() { print "3.0.2" }

out=$(_phpvm_check_openssl_compat 7.3.33 2>&1); st=$?
check "blocks PHP 7.3 on OpenSSL 3" "cannot be built against OpenSSL 3.0.2" "$out"
check_status "blocks with a non-zero status" 1 $st
check "names the remedy" "phpvm install 8.1" "$out"
check "names the bypass" "PHPVM_SKIP_OPENSSL_CHECK=1" "$out"

_phpvm_check_openssl_compat 8.3.10 >/dev/null 2>&1
check_status "allows PHP 8.3 on OpenSSL 3" 0 $?

_phpvm_openssl_version() { return 1 }
_phpvm_check_openssl_compat 7.3.33 >/dev/null 2>&1
check_status "fails open when OpenSSL cannot be probed" 0 $?

_phpvm_openssl_version() { print "3.0.2" }
PHPVM_SKIP_OPENSSL_CHECK=1 _phpvm_check_openssl_compat 7.3.33 >/dev/null 2>&1
check_status "honours PHPVM_SKIP_OPENSSL_CHECK" 0 $?

print -r -- "-- build-log error surfacing --"
export PHPVM_LOG="$tmp/build.log"
print "ext/openssl/openssl.c:1491:58: error: RSA_SSLV23_PADDING undeclared" > "$PHPVM_LOG"
out=$(_phpvm_show_build_error 2>&1)
check "surfaces the first compiler error" "RSA_SSLV23_PADDING" "$out"

print "configure: error: libxml-2.0 not met" > "$PHPVM_LOG"
out=$(_phpvm_show_build_error 2>&1)
check "surfaces a configure error" "libxml-2.0" "$out"

print "all good" > "$PHPVM_LOG"
out=$(_phpvm_show_build_error 2>&1)
check_empty "stays quiet when the log holds no error" "$out"

print -r -- "-- tarball verification --"
tarball="$tmp/php-8.3.0.tar.gz"
print "payload" > "$tarball"
_phpvm_php_sha256()  { print "aaaa" }
_phpvm_sha256_file() { print "aaaa" }
out=$(_phpvm_verify_tarball "$tarball" 8.3.0 2>&1); st=$?
check "accepts a matching digest" "SHA-256 verified" "$out"
check_status "accepts with status 0" 0 $st

_phpvm_sha256_file() { print "bbbb" }
out=$(_phpvm_verify_tarball "$tarball" 8.3.0 2>&1); st=$?
check "rejects a mismatching digest" "SHA-256 mismatch" "$out"
check_status "rejects with a non-zero status" 1 $st
if [[ -f "$tarball" ]]; then
    print "FAIL - deletes the tarball on mismatch"
    fail=1
else
    print "ok   - deletes the tarball on mismatch"
fi

print "payload" > "$tarball"
out=$(PHPVM_SKIP_HASH=1 _phpvm_verify_tarball "$tarball" 8.3.0 2>&1); st=$?
check "honours PHPVM_SKIP_HASH" "Skipping SHA-256 verification" "$out"
check_status "skips with status 0" 0 $st

_phpvm_php_sha256() { return 1 }
out=$(_phpvm_verify_tarball "$tarball" 8.3.0 2>&1); st=$?
check "degrades to a warning with no published digest" "No published SHA-256" "$out"
check_status "degrades without failing the install" 0 $st

# The real lookup parses JSON with a pipeline; make sure that pipeline behaves
# under zsh rather than only under bash.
curl() { print -n '{"source":[{"filename":"php-8.3.0.tar.gz","sha256":"'${(l:64::a:)}'"},{"filename":"php-8.3.0.tar.xz","sha256":"'${(l:64::b:)}'"}]}' }
unfunction _phpvm_php_sha256 2>/dev/null
# Re-source to get the real implementation back. NO_INIT so this does not
# re-run the source-time PATH and hook side effects mid-suite.
PHPVM_NO_INIT=1 . ./linux/phpvm.sh >/dev/null 2>&1
out=$(_phpvm_php_sha256 8.3.0 2>&1)
check "picks the tar.gz digest out of the release JSON" "aaaa" "$out"
if [[ "$out" == *bbbb* ]]; then
    print "FAIL - must not return the tar.xz digest"
    fail=1
else
    print "ok   - does not return the tar.xz digest"
fi
unfunction curl

print -r -- "-- ext list ON/OFF --"
export PHPVM_VERSIONS="$PHPVM_DIR/versions"
extdir="$PHPVM_VERSIONS/8.3.0/lib/php/extensions"
mkdir -p "$PHPVM_VERSIONS/8.3.0/bin" "$extdir"
cat > "$PHPVM_VERSIONS/8.3.0/bin/php" <<'PHPEOF'
#!/usr/bin/env bash
case "$1" in
    -m) printf '%s\n' Core curl ;;
    -r) printf '%s' "$FAKE_EXT_DIR" ;;
esac
PHPEOF
chmod +x "$PHPVM_VERSIONS/8.3.0/bin/php"
export FAKE_EXT_DIR="$extdir"
touch "$extdir/redis.so"
_phpvm_current_version() { print "8.3.0" }

out=$(phpvm_ext_list 2>&1)
check "marks a loaded extension ON" "curl" "$out"
check "marks an unloaded .so OFF" "OFF" "$out"
# The counters live in a `while read` loop fed by a here-string. Were that a
# pipeline, zsh would run it in a subshell and both totals would come back 0.
check "counters survive the read loop" "2 ON, 1 OFF" "$out"

out=$(phpvm_ext_loaded 2>&1)
check "ext loaded lists php -m" "curl" "$out"
if [[ "$out" == *redis* ]]; then
    print "FAIL - ext loaded must not show unloaded .so files"
    fail=1
else
    print "ok   - ext loaded omits unloaded .so files"
fi

print -r -- "-- doctor PATH scan --"
# `for d in $PATH` does not split on colons in zsh; the scan has to tr-split.
mkdir -p "$tmp/usrbin"
print '#!/usr/bin/env bash' > "$tmp/usrbin/php"
chmod +x "$tmp/usrbin/php"
export PHPVM_BIN="$PHPVM_DIR/bin"
export PHPVM_CURRENT="$PHPVM_DIR/current"
out=$(PATH="$PHPVM_VERSIONS/8.3.0/bin:$tmp/usrbin:$PATH" phpvm_doctor 2>&1)
check "finds the phpvm php first" "resolves to phpvm" "$out"
check "still names the second php behind it" "Another PHP on PATH" "$out"

rm -rf "$tmp"

print ""
if (( fail )); then
    print "zsh smoke: FAILED"
    exit 1
fi
print "zsh smoke: all checks passed"
exit 0
