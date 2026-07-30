# Run a long build step with its output appended to $PHPVM_LOG, showing a live
# spinner + elapsed time so a multi-minute `make` never looks hung.
#   _phpvm_run_logged "Building with 8 cores" make -j8
# The spinner is drawn on stderr and only when stderr is a terminal, so CI and
# the bats suite see exactly the output they saw before. Returns the real exit
# code of the command.
_phpvm_run_logged() {
    local label="$1"; shift

    if [[ ! -t 2 ]]; then
        _step "$label ..."
        "$@" >> "$PHPVM_LOG" 2>&1
        return $?
    fi

    # phpvm.sh is sourced into an interactive shell, where job control is on and
    # would print "[3] 2015" / "[3] + done ..." around our background build.
    # Turn the monitor off for the duration and put it back exactly as we found it.
    local had_monitor=0
    case "$-" in *m*) had_monitor=1; set +m ;; esac

    "$@" >> "$PHPVM_LOG" 2>&1 &
    local pid=$!

    # Ctrl+C must take the build down with us, not orphan it.
    trap 'kill "$pid" 2>/dev/null; printf "\r\033[K" >&2; [[ $had_monitor -eq 1 ]] && set -m; trap - INT; return 130' INT

    # Plain ASCII frames + explicit index: ${var:i++:1} is a bashism that bites
    # in zsh, and Unicode braille spinners mangle on older terminals.
    local frames="|/-\\"
    local i=0 start=$SECONDS elapsed frame
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - start))
        frame=${frames:$i:1}
        i=$(( (i + 1) % 4 ))
        printf '\r\033[36m  %s %s ... %dm%02ds\033[0m' \
            "$frame" "$label" $((elapsed / 60)) $((elapsed % 60)) >&2
        sleep 0.5
    done

    wait "$pid"
    local rc=$?
    trap - INT
    [[ $had_monitor -eq 1 ]] && set -m
    printf '\r\033[K' >&2

    elapsed=$((SECONDS - start))
    if [[ $rc -eq 0 ]]; then
        _step "$label ... done in $((elapsed / 60))m$((elapsed % 60))s"
    fi
    return $rc
}

# A failed build leaves thousands of lines of compiler noise in $PHPVM_LOG, and
# the line that explains it is buried near the middle — "See log" alone makes
# the user page through it. Pull out the first hard error instead.
_phpvm_show_build_error() {
    [[ -f "$PHPVM_LOG" ]] || return 0

    local first
    # configure's own failure is the more useful line when both are present.
    first=$(grep -m1 -E '^configure: error:' "$PHPVM_LOG" 2>/dev/null)
    [[ -z "$first" ]] && first=$(grep -m1 -E '(^|[[:space:]])(fatal )?error:' "$PHPVM_LOG" 2>/dev/null)
    [[ -z "$first" ]] && return 0

    _err "First error in the log:"
    _dim "  ${first}"
}
