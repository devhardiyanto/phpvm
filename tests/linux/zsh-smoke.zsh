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

check_status() {  # check_status <name> <expected-status> <actual-status>
    if [[ "$3" == "$2" ]]; then
        print "ok   - $1"
    else
        print "FAIL - $1 (expected status $2, got $3)"
        fail=1
    fi
}

tmp=$(mktemp -d)
export PHPVM_DIR="$tmp/phpvm"
export PHPVM_NO_UPDATE_CHECK=1
export PHPVM_NO_INIT=1
source ./linux/phpvm.sh
unset PHPVM_NO_INIT

print "-- sourcing --"
check_status "phpvm.sh sources cleanly under zsh" 0 $?

print "-- levenshtein (array indexing) --"
out=$(_phpvm_levenshtein kitten sitting 2>&1)
check "levenshtein kitten/sitting = 3" "3" "$out"
out=$(_phpvm_levenshtein '' abc 2>&1)
check "levenshtein ''/abc = 3" "3" "$out"
out=$(_phpvm_levenshtein same same 2>&1)
check "levenshtein same/same = 0" "0" "$out"

print "-- did-you-mean (command-list splitting) --"
out=$(phpvm instal 2>&1)
check "suggests install for 'instal'" "Did you mean 'install'" "$out"
out=$(phpvm doctro 2>&1)
check "suggests doctor for 'doctro'" "Did you mean 'doctor'" "$out"
out=$(phpvm zzzzzzzzzz 2>&1)
check "no suggestion for nonsense" "is not a phpvm command" "$out"

print "-- basic read-only commands --"
out=$(phpvm version 2>&1)
check "version prints the version" "phpvm" "$out"
out=$(phpvm list 2>&1)
check "list runs without error" "No PHP versions installed" "$out"
out=$(phpvm help 2>&1)
check "help runs" "PHP Version Manager" "$out"
out=$(phpvm current 2>&1)
check "current runs" "No PHP version" "$out"

print "-- .phpvmrc parsing --"
mkdir -p "$tmp/proj"
print "8.3" > "$tmp/proj/.phpvmrc"
out=$(cd "$tmp/proj" && _phpvm_read_rc "$tmp/proj/.phpvmrc" 2>&1)
check "reads a .phpvmrc version" "8.3" "$out"

print "-- older-patch hint --"
mkdir -p "$PHPVM_DIR/versions/8.5.1" "$PHPVM_DIR/versions/8.5.2" "$PHPVM_DIR/versions/8.5.8"
out=$(_phpvm_older_patch_hint 8.5.8 2>&1)
check "joins older patches with ', '" "8.5.1, 8.5.2" "$out"

rm -rf "$tmp"

print ""
if (( fail )); then
    print "zsh smoke: FAILED"
    exit 1
fi
print "zsh smoke: all checks passed"
exit 0
