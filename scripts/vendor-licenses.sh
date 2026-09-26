#!/usr/bin/env bash
# Usage: vendor-licenses.sh SRC_DIR
# Copies the top-level license files of every vendored archive in SRC_DIR/deps
# that upstream does not already cover in SRC_DIR/licenses/LICENSE-<name>.txt.
set -euo pipefail

die() { echo "vendor-licenses: $*" >&2; exit 1; }

src="${1:-}"
[[ -n "$src" ]] || die "usage: $0 SRC_DIR"
[[ -d "$src/deps" ]] || die "$src/deps is not a directory"
[[ -d "$src/licenses" ]] || die "$src/licenses is not a directory"

readonly TEST_ONLY=" gtest "
declare -A upstream_name=(
    [luajit]=LuaJIT [rangev3]=range-v3 [span]=span-lite [trie]=hat-trie [zlib]=zlib-ng
)

shopt -s nullglob
zips=("$src"/deps/*.zip)
(( ${#zips[@]} )) || die "no .zip archives in $src/deps"

for zip in "${zips[@]}"; do
    dep="$(basename "$zip")"
    dep="${dep%%-*}"
    [[ "$TEST_ONLY" != *" $dep "* ]] || continue
    [[ ! -f "$src/licenses/LICENSE-${upstream_name[$dep]:-$dep}.txt" ]] || continue

    mapfile -t members < <(unzip -Z1 "$zip" | grep -E '^[^/]+/(LICEN[CS]E|COPYING|COPYRIGHT)[^/]*$' || true)
    (( ${#members[@]} )) || die "no license file for $dep in $(basename "$zip")"
    for m in "${members[@]}"; do
        if (( ${#members[@]} == 1 )); then
            out="LICENSE-${dep}.txt"
        else
            base="${m#*/}"
            out="LICENSE-${dep}-${base%.txt}.txt"
        fi
        unzip -p "$zip" "$m" > "$src/licenses/$out"
        [[ -s "$src/licenses/$out" ]] || die "$m in $(basename "$zip") is empty"
    done
done
