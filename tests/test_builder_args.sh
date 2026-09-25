#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
b="$here/../scripts/kvrocks_builder.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out="$(KVROCKS_BUILDER_DRY_RUN=1 bash "$b" --builddir="$tmp")"
grep -qx 'VERSION=2.17.0' <<<"$out"
grep -qx 'BRANCH=v2.17.0' <<<"$out"
grep -qx 'RELEASE=1' <<<"$out"
grep -qx 'REPO=https://github.com/apache/kvrocks.git' <<<"$out"

out="$(KVROCKS_BUILDER_DRY_RUN=1 bash "$b" --builddir="$tmp" --version=2.18.0 --branch=v2.18.0 \
      --release=3 --get_sources=1 --build_rpm --use_local_packaging_script)"
grep -qx 'VERSION=2.18.0' <<<"$out"
grep -qx 'RELEASE=3' <<<"$out"
grep -qx 'SOURCE=1' <<<"$out"
grep -qx 'RPM=1' <<<"$out"
grep -qx 'LOCAL_BUILD=1' <<<"$out"

if KVROCKS_BUILDER_DRY_RUN=1 bash "$b" --builddir="$tmp" --bogus 2>/dev/null; then
    echo "unknown flag must fail"; exit 1
fi
if (cd "$tmp" && KVROCKS_BUILDER_DRY_RUN=1 bash "$b" --builddir="$tmp" 2>/dev/null); then
    echo "builddir == cwd must fail"; exit 1
fi
if KVROCKS_BUILDER_DRY_RUN=1 bash "$b" 2>/dev/null; then
    echo "missing builddir must fail"; exit 1
fi
bash "$b" --help | grep -q -- '--build_src_deb'
