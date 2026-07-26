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

rm -rf "$tmp"

print ""
if (( fail )); then
    print "zsh smoke: FAILED"
    exit 1
fi
print "zsh smoke: all checks passed"
exit 0
