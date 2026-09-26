#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
vl="$here/../scripts/vendor-licenses.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkzip() {
    local zip="$1"; shift
    python3 - "$zip" "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for member in sys.argv[2:]:
        z.writestr(member, "" if member.endswith("/") else f"text of {member}\n")
EOF
}

src="$tmp/src"
mkdir -p "$src/deps" "$src/licenses"
echo "upstream fmt" > "$src/licenses/LICENSE-fmt.txt"
echo "upstream hat-trie" > "$src/licenses/LICENSE-hat-trie.txt"
mkzip "$src/deps/fmt-12.2.0.zip" fmt-12.2.0/LICENSE fmt-12.2.0/src/format.cc
mkzip "$src/deps/trie-v0.7.1.zip" hat-trie-0.7.1/LICENSE
mkzip "$src/deps/jemalloc-5.3.1.zip" jemalloc-5.3.1/COPYING jemalloc-5.3.1/doc/LICENSE.old
mkzip "$src/deps/rocksdb-v11.8.1.zip" rocksdb-11.8.1/COPYING rocksdb-11.8.1/LICENSE.Apache \
    rocksdb-11.8.1/LICENSE.leveldb rocksdb-11.8.1/LICENSES/
mkzip "$src/deps/gtest-v1.18.0.zip" googletest-1.18.0/README.md

bash "$vl" "$src"

got="$(find "$src/licenses" -type f -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"
want="LICENSE-fmt.txt LICENSE-hat-trie.txt LICENSE-jemalloc.txt LICENSE-rocksdb-COPYING.txt LICENSE-rocksdb-LICENSE.Apache.txt LICENSE-rocksdb-LICENSE.leveldb.txt "
[[ "$got" == "$want" ]] || { echo "got: $got"; echo "want: $want"; exit 1; }
grep -qx 'upstream fmt' "$src/licenses/LICENSE-fmt.txt"
grep -qx 'text of jemalloc-5.3.1/COPYING' "$src/licenses/LICENSE-jemalloc.txt"
grep -qx 'text of rocksdb-11.8.1/LICENSE.leveldb' "$src/licenses/LICENSE-rocksdb-LICENSE.leveldb.txt"

mkzip "$src/deps/nolicense-v1.zip" nolicense-1/README.md
if bash "$vl" "$src" 2>/dev/null; then
    echo "dep without a license file must fail"; exit 1
fi

mkdir -p "$tmp/empty/deps" "$tmp/empty/licenses"
if bash "$vl" "$tmp/empty" 2>/dev/null; then
    echo "empty deps directory must fail"; exit 1
fi
if bash "$vl" "$tmp/missing" 2>/dev/null; then
    echo "missing source directory must fail"; exit 1
fi
