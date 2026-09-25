#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
failed=0
for t in test_*.sh; do
    [[ -e "$t" ]] || continue
    if bash "$t"; then
        printf 'PASS %s\n' "$t"
    else
        printf 'FAIL %s\n' "$t"
        failed=1
    fi
done
exit "$failed"
