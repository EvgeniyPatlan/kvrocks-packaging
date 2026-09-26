#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
gen="$here/../scripts/gen-sbom.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/src/cmake" "$tmp/src/deps"
cp "$here"/fixtures/cmake/*.cmake "$tmp/src/cmake/"
touch "$tmp/src/deps/rocksdb-v11.8.1.zip" "$tmp/src/deps/gtest-v1.17.0.zip" "$tmp/src/deps/fast_float-v8.2.7.zip"

python3 "$gen" --src "$tmp/src" --name percona-kvrocks --version 2.17.0 --out "$tmp/out"

python3 - "$tmp/out" <<'EOF'
import json, re, sys
out = sys.argv[1]
spdx = json.load(open(f"{out}/percona-kvrocks.spdx.json"))
cdx = json.load(open(f"{out}/percona-kvrocks.cdx.json"))
assert spdx["spdxVersion"] == "SPDX-2.3", spdx["spdxVersion"]
assert cdx["specVersion"] == "1.5", cdx["specVersion"]
names = {p["name"] for p in spdx["packages"]}
assert names == {"percona-kvrocks", "rocksdb", "fast_float"}, names
for p in spdx["packages"]:
    assert re.fullmatch(r"SPDXRef-[A-Za-z0-9.-]+", p["SPDXID"]), p["SPDXID"]
for r in spdx["relationships"]:
    for k in ("spdxElementId", "relatedSpdxElement"):
        assert re.fullmatch(r"SPDXRef-[A-Za-z0-9.-]+", r[k]), r[k]
rocks = [c for c in cdx["components"] if c["name"] == "rocksdb"][0]
assert rocks["version"] == "v11.8.1", rocks
assert rocks["purl"] == "pkg:github/facebook/rocksdb@v11.8.1", rocks
assert rocks["hashes"][0] == {"alg": "MD5", "content": "e28ce50253c2f30fa789fee7b2381c63"}, rocks
assert cdx["metadata"]["component"]["version"] == "2.17.0"
EOF

touch "$tmp/src/deps/unknown-v1.zip"
if python3 "$gen" --src "$tmp/src" --name percona-kvrocks --version 2.17.0 --out "$tmp/out2" 2>/dev/null; then
    echo "undeclared archive must fail"; exit 1
fi

# Test: empty directory (no cmake/ dir)
if python3 "$gen" --src "$tmp/empty" --name percona-kvrocks --version 2.17.0 --out "$tmp/out3" 2>/dev/null; then
    echo "empty directory must fail"; exit 1
fi

# Test: cmake/ present but deps/ empty
mkdir -p "$tmp/src-empty-deps/cmake" "$tmp/src-empty-deps/deps"
cp "$here"/fixtures/cmake/*.cmake "$tmp/src-empty-deps/cmake/"
if python3 "$gen" --src "$tmp/src-empty-deps" --name percona-kvrocks --version 2.17.0 --out "$tmp/out4" 2>/dev/null; then
    echo "empty deps directory must fail"; exit 1
fi
