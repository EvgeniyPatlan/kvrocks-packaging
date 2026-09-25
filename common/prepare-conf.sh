#!/bin/sh
set -eu

in="$1"
out="$2"
cp "$in" "$out"

replace() {
    if ! grep -qx "$1" "$out"; then
        echo "prepare-conf: line '$1' not found in $in" >&2
        exit 1
    fi
    sed -i "s|^$1\$|$2|" "$out"
}

require() {
    if ! grep -qx "$1" "$out"; then
        echo "prepare-conf: line '$1' not found in $in" >&2
        exit 1
    fi
}

replace 'dir /tmp/kvrocks' 'dir /var/lib/kvrocks'
replace '# log-dir /tmp/kvrocks,stdout' 'log-dir /var/log/kvrocks'
replace 'supervised no' 'supervised systemd'
require 'daemonize no'
require 'bind 127.0.0.1'
require 'port 6666'
require '# pidfile /var/run/kvrocks.pid'
