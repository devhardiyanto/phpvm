#!/usr/bin/env bats
# Pester equivalent for the Linux .phpvmrc auto-switch logic.
# Run from repo root: bats tests/linux/

setup() {
    export PHPVM_DIR="$BATS_TEST_TMPDIR/phpvm"
    export PHPVM_VERSIONS="$PHPVM_DIR/versions"
    export PHPVM_NO_INIT=1
    export PHPVM_NO_UPDATE_CHECK=1
    mkdir -p "$PHPVM_VERSIONS"

    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../linux/phpvm.sh"
}

teardown() {
    unset PHPVM_AUTO_ACTIVE
}

# ---------- _phpvm_find_rc ----------

@test "find_rc: returns 1 when no .phpvmrc is in the chain" {
    mkdir -p "$BATS_TEST_TMPDIR/a/b/c"
    run _phpvm_find_rc "$BATS_TEST_TMPDIR/a/b/c"
    [ "$status" -eq 1 ]
}

@test "find_rc: finds .phpvmrc in current dir" {
    mkdir -p "$BATS_TEST_TMPDIR/p1"
    echo "8.3.0" > "$BATS_TEST_TMPDIR/p1/.phpvmrc"
    run _phpvm_find_rc "$BATS_TEST_TMPDIR/p1"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/p1/.phpvmrc" ]
}

@test "find_rc: walks up to find .phpvmrc in a parent" {
    mkdir -p "$BATS_TEST_TMPDIR/proj/src/api"
    echo "7.4" > "$BATS_TEST_TMPDIR/proj/.phpvmrc"
    run _phpvm_find_rc "$BATS_TEST_TMPDIR/proj/src/api"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/proj/.phpvmrc" ]
}

@test "find_rc: innermost .phpvmrc wins" {
    mkdir -p "$BATS_TEST_TMPDIR/ws/sub/src"
    echo "8.3" > "$BATS_TEST_TMPDIR/ws/.phpvmrc"
    echo "7.4" > "$BATS_TEST_TMPDIR/ws/sub/.phpvmrc"
    run _phpvm_find_rc "$BATS_TEST_TMPDIR/ws/sub/src"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/ws/sub/.phpvmrc" ]
}

# ---------- _phpvm_read_rc ----------

@test "read_rc: plain version" {
    echo "8.3.0" > "$BATS_TEST_TMPDIR/rc"
    run _phpvm_read_rc "$BATS_TEST_TMPDIR/rc"
    [ "$status" -eq 0 ]
    [ "$output" = "8.3.0" ]
}

@test "read_rc: trims whitespace" {
    printf "   8.3.0   \n" > "$BATS_TEST_TMPDIR/rc"
    run _phpvm_read_rc "$BATS_TEST_TMPDIR/rc"
    [ "$output" = "8.3.0" ]
}

@test "read_rc: skips comment-only lines" {
    cat > "$BATS_TEST_TMPDIR/rc" <<EOF
# project: api
# php 8.3 required
8.3.0
EOF
    run _phpvm_read_rc "$BATS_TEST_TMPDIR/rc"
    [ "$output" = "8.3.0" ]
}

@test "read_rc: strips inline #-comment" {
    echo "8.3.0  # locked for deploy" > "$BATS_TEST_TMPDIR/rc"
    run _phpvm_read_rc "$BATS_TEST_TMPDIR/rc"
    [ "$output" = "8.3.0" ]
}

@test "read_rc: strips leading v" {
    echo "v8.3.0" > "$BATS_TEST_TMPDIR/rc"
    run _phpvm_read_rc "$BATS_TEST_TMPDIR/rc"
    [ "$output" = "8.3.0" ]
}

@test "read_rc: empty / comments-only returns 1" {
    printf "# comment\n\n" > "$BATS_TEST_TMPDIR/rc"
    run _phpvm_read_rc "$BATS_TEST_TMPDIR/rc"
    [ "$status" -eq 1 ]
}

# ---------- _phpvm_resolve_rc ----------

_install_fake() {
    local v="$1"
    mkdir -p "$PHPVM_VERSIONS/$v/bin"
    echo '#!/bin/sh' > "$PHPVM_VERSIONS/$v/bin/php"
    chmod +x "$PHPVM_VERSIONS/$v/bin/php"
}

@test "resolve_rc: full installed semver passes through" {
    _install_fake 8.3.0
    run _phpvm_resolve_rc 8.3.0
    [ "$status" -eq 0 ]
    [ "$output" = "8.3.0" ]
}

@test "resolve_rc: partial picks highest installed patch" {
    _install_fake 8.3.0
    _install_fake 8.3.29
    _install_fake 8.3.10
    run _phpvm_resolve_rc 8.3
    [ "$status" -eq 0 ]
    [ "$output" = "8.3.29" ]
}

@test "resolve_rc: returns 1 when nothing matches" {
    _install_fake 8.3.29
    run _phpvm_resolve_rc 5.6
    [ "$status" -eq 1 ]
}

@test "resolve_rc: full semver not installed returns 1" {
    _install_fake 8.3.29
    run _phpvm_resolve_rc 8.3.99
    [ "$status" -eq 1 ]
}

# ---------- _phpvm_auto ----------

@test "auto: prepends resolved version dir to PATH" {
    _install_fake 8.3.29
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    echo "8.3" > "$BATS_TEST_TMPDIR/proj/.phpvmrc"

    cd "$BATS_TEST_TMPDIR/proj"
    _phpvm_auto -s
    [ "$PHPVM_AUTO_ACTIVE" = "8.3.29" ]
    case ":$PATH:" in
        :"$PHPVM_VERSIONS/8.3.29/bin":*) ;;
        *) printf 'PATH does not start with expected dir: %s\n' "$PATH" >&2; return 1 ;;
    esac
}

@test "auto: second call is a no-op when active matches" {
    _install_fake 7.4.33
    mkdir -p "$BATS_TEST_TMPDIR/proj"
    echo "7.4.33" > "$BATS_TEST_TMPDIR/proj/.phpvmrc"

    cd "$BATS_TEST_TMPDIR/proj"
    _phpvm_auto -s
    local before="$PATH"
    _phpvm_auto -s
    [ "$PATH" = "$before" ]
}

@test "auto: removes previous prepend when switching projects" {
    _install_fake 7.4.33
    _install_fake 8.3.0
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    echo "7.4.33" > "$BATS_TEST_TMPDIR/a/.phpvmrc"
    echo "8.3.0"  > "$BATS_TEST_TMPDIR/b/.phpvmrc"

    cd "$BATS_TEST_TMPDIR/a"; _phpvm_auto -s
    cd "$BATS_TEST_TMPDIR/b"; _phpvm_auto -s

    [ "$PHPVM_AUTO_ACTIVE" = "8.3.0" ]
    case ":$PATH:" in
        *":$PHPVM_VERSIONS/7.4.33/bin:"*) printf 'old 7.4.33 still on PATH\n' >&2; return 1 ;;
    esac
    case ":$PATH:" in
        :"$PHPVM_VERSIONS/8.3.0/bin":*) ;;
        *) printf 'PATH does not start with 8.3.0 dir: %s\n' "$PATH" >&2; return 1 ;;
    esac
}

@test "auto: clears prepend when no .phpvmrc upstream" {
    _install_fake 8.3.0
    mkdir -p "$BATS_TEST_TMPDIR/proj" "$BATS_TEST_TMPDIR/orphan"
    echo "8.3.0" > "$BATS_TEST_TMPDIR/proj/.phpvmrc"

    cd "$BATS_TEST_TMPDIR/proj"; _phpvm_auto -s
    cd "$BATS_TEST_TMPDIR/orphan"; _phpvm_auto -s

    [ -z "${PHPVM_AUTO_ACTIVE:-}" ]
    case ":$PATH:" in
        *":$PHPVM_VERSIONS/8.3.0/bin:"*) printf 'old prepend still on PATH\n' >&2; return 1 ;;
    esac
}

# ---------- phpvm hook ----------

@test "hook: enable creates the flag file" {
    run phpvm_hook enable
    [ "$status" -eq 0 ]
    [ -f "$PHPVM_DIR/.auto-hook" ]
}

@test "hook: disable removes the flag file" {
    touch "$PHPVM_DIR/.auto-hook"
    run phpvm_hook disable
    [ "$status" -eq 0 ]
    [ ! -f "$PHPVM_DIR/.auto-hook" ]
}

@test "hook: status reports correctly" {
    run phpvm_hook status
    [[ "$output" == *"disabled"* ]]
    touch "$PHPVM_DIR/.auto-hook"
    run phpvm_hook status
    [[ "$output" == *"enabled"* ]]
}
