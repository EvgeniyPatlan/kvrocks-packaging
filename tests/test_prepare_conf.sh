#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
script="$here/../common/prepare-conf.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sh "$script" "$here/fixtures/kvrocks.conf" "$tmp/out.conf"

for line in 'dir /var/lib/kvrocks' 'log-dir /var/log/kvrocks' 'supervised systemd' \
            'daemonize no' 'bind 127.0.0.1' 'port 6666'; do
    grep -qx "$line" "$tmp/out.conf" || { echo "missing: $line"; exit 1; }
done
if grep -q '^dir /tmp/kvrocks' "$tmp/out.conf"; then
    echo "upstream dir left in place"; exit 1
fi
if grep -q '^pidfile' "$tmp/out.conf"; then
    echo "pidfile must stay commented out"; exit 1
fi

sed '/^dir \/tmp\/kvrocks$/d' "$here/fixtures/kvrocks.conf" > "$tmp/mutated.conf"
if sh "$script" "$tmp/mutated.conf" "$tmp/out2.conf" 2>"$tmp/err"; then
    echo "mutated input must fail"; exit 1
fi
grep -q 'dir /tmp/kvrocks' "$tmp/err" || { echo "error must name the missing line"; exit 1; }

sed 's/^# pidfile /pidfile /' "$here/fixtures/kvrocks.conf" > "$tmp/mutated_pidfile.conf"
if sh "$script" "$tmp/mutated_pidfile.conf" "$tmp/out3.conf" 2>"$tmp/err_pidfile"; then
    echo "uncommented pidfile must fail"; exit 1
fi
grep -q '# pidfile /var/run/kvrocks.pid' "$tmp/err_pidfile" || { echo "error must name the pidfile line"; exit 1; }
