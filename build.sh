#!/usr/bin/env bash
# ==============================================================================
#  Concatenate linux/src/*.sh into the shipped linux/phpvm.sh.
#
#  phpvm is distributed as a single file: linux/install.sh downloads
#  linux/phpvm.sh straight from the repo and `phpvm upgrade` replaces it in
#  place. Splitting the sources therefore has to collapse back into one file at
#  build time rather than at load time.
#
#  Modules concatenate in filename order, which is why they are numbered. In
#  bash only two things about that order are load-bearing: 00-header.sh defines
#  the constants everything else reads, and 99-entry.sh ends with the
#  source-time init block, which calls functions that must already be defined.
#  Function definition order in between is free — pick it for readability.
#
#  Usage:
#    bash ./build.sh            # write linux/phpvm.sh
#    bash ./build.sh --check    # compare only; non-zero exit on drift (CI gate)
# ==============================================================================
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
src_dir="$root/linux/src"
out_file="$root/linux/phpvm.sh"

check=0
case "${1:-}" in
    --check) check=1 ;;
    "")      ;;
    *)       echo "usage: build.sh [--check]" >&2; exit 2 ;;
esac

# LC_ALL=C so the glob sorts the same everywhere; the repo stores LF only.
modules=$(LC_ALL=C ls "$src_dir"/*.sh 2>/dev/null || true)
[[ -n "$modules" ]] || { echo "No modules found in $src_dir" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
    cat <<'BANNER'
#!/usr/bin/env bash
# ==============================================================================
#  GENERATED FILE - DO NOT EDIT
#  Built from linux/src/*.sh (concatenated in filename order).
#  Edit a module there, then run:  bash ./build.sh
#  CI fails the drift check if this file and the modules disagree.
# ==============================================================================
BANNER

    count=0
    while IFS= read -r m; do
        name=$(basename "$m")
        dashes=$(printf '%*s' $(( 74 - ${#name} > 1 ? 74 - ${#name} : 1 )) '' | tr ' ' '-')
        printf '\n# --- src/%s %s\n' "$name" "$dashes"
        # $(cat) drops trailing newlines - each module contributes exactly one
        # trailing blank line, no matter how it was saved.
        printf '%s\n' "$(cat "$m")"
        count=$(( count + 1 ))
    done <<< "$modules"
} > "$tmp"

module_count=$(printf '%s\n' "$modules" | wc -l | tr -d ' ')

if (( check )); then
    [[ -f "$out_file" ]] || { echo "Missing $out_file - run: bash ./build.sh" >&2; exit 1; }
    if diff -u "$out_file" "$tmp" > /dev/null; then
        echo "OK: linux/phpvm.sh matches linux/src/*.sh ($module_count modules)."
        exit 0
    fi
    echo "DRIFT: linux/phpvm.sh does not match linux/src/*.sh."
    echo "Rebuild with: bash ./build.sh"
    diff -u "$out_file" "$tmp" | head -40
    exit 1
fi

cp "$tmp" "$out_file"
chmod +x "$out_file"
echo "Built linux/phpvm.sh from $module_count modules ($(wc -l < "$out_file" | tr -d ' ') lines)."
