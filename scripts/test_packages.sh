#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
PKG_DIR=""; USE_REPO=false; REPO_CHANNEL="testing"; EXPECTED_VERSION=""
OS_FAMILY=""
PORT=6666

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

usage() {
    echo "Usage: $0 [--pkg-dir=DIR | --repo [--repo-channel=CHANNEL]] [--version=X.Y.Z]"
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        --pkg-dir=*)      PKG_DIR="${arg#*=}" ;;
        --repo)           USE_REPO=true ;;
        --repo-channel=*) REPO_CHANNEL="${arg#*=}" ;;
        --version=*)      EXPECTED_VERSION="${arg#*=}" ;;
        --help)           usage 0 ;;
        *)                usage 1 ;;
    esac
done
[[ -n "$PKG_DIR" || "$USE_REPO" == true ]] || usage 1

if [[ -f /etc/debian_version ]]; then OS_FAMILY=deb; else OS_FAMILY=rpm; fi
pm() { if command -v dnf >/dev/null; then dnf "$@"; else yum "$@"; fi; }

resp() {
    local l1="" l2=""
    exec 3<>"/dev/tcp/127.0.0.1/${PORT}" || return 1
    printf '%s' "$1" >&3
    IFS= read -r -t 5 l1 <&3 || true
    l1="${l1%$'\r'}"
    if [[ "$l1" == '$'* && "$l1" != '$-1' ]]; then
        IFS= read -r -t 5 l2 <&3 || true
        l1="${l2%$'\r'}"
    fi
    exec 3>&-
    printf '%s' "$l1"
}

wait_ready() {
    for _ in $(seq 1 30); do
        [[ "$(resp $'*1\r\n$4\r\nPING\r\n')" == "+PONG" ]] && return 0
        sleep 1
    done
    return 1
}

install_packages() {
    section "Install"
    if [[ "$USE_REPO" == true ]]; then
        if [[ "$OS_FAMILY" == deb ]]; then
            apt-get update -qq && apt-get install -y -qq curl gnupg lsb-release >/dev/null
            curl -fsSLO https://repo.percona.com/apt/percona-release_latest.generic_all.deb
            apt-get install -y -qq ./percona-release_latest.generic_all.deb >/dev/null
            percona-release enable kvrocks "$REPO_CHANNEL"
            apt-get update -qq
            check "install from repo" apt-get install -y percona-kvrocks-server percona-kvrocks-tools
        else
            pm install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm >/dev/null
            percona-release enable kvrocks "$REPO_CHANNEL"
            check "install from repo" pm install -y percona-kvrocks-server percona-kvrocks-tools
        fi
    else
        if [[ "$OS_FAMILY" == deb ]]; then
            apt-get update -qq
            check "install from $PKG_DIR" apt-get install -y \
                "$PKG_DIR"/percona-kvrocks-server_*.deb "$PKG_DIR"/percona-kvrocks-tools_*.deb
        else
            check "install from $PKG_DIR" pm install -y \
                "$PKG_DIR"/percona-kvrocks-server-[0-9]*.rpm "$PKG_DIR"/percona-kvrocks-tools-[0-9]*.rpm
        fi
    fi
}

test_files() {
    section "Files"
    check "/usr/bin/kvrocks executable" test -x /usr/bin/kvrocks
    check "/usr/bin/kvrocks2redis executable" test -x /usr/bin/kvrocks2redis
    check "kvrocks user exists" getent passwd kvrocks
    check "config dir 770 root:kvrocks" test "$(stat -c '%a %U:%G' /etc/kvrocks)" = "770 root:kvrocks"
    check "config mode 660 root:kvrocks" test "$(stat -c '%a %U:%G' /etc/kvrocks/kvrocks.conf)" = "660 root:kvrocks"
    check "data dir 750 kvrocks:kvrocks" test "$(stat -c '%a %U:%G' /var/lib/kvrocks)" = "750 kvrocks:kvrocks"
    check "log dir 750 kvrocks:kvrocks" test "$(stat -c '%a %U:%G' /var/log/kvrocks)" = "750 kvrocks:kvrocks"
    check "config dir set to /var/lib/kvrocks" grep -qx 'dir /var/lib/kvrocks' /etc/kvrocks/kvrocks.conf
    check "SBOM spdx present" test -s /usr/share/percona-kvrocks/sbom/percona-kvrocks.spdx.json
    check "SBOM cdx present" test -s /usr/share/percona-kvrocks/sbom/percona-kvrocks.cdx.json
    check "binary built with TLS" bash -c "strings /usr/bin/kvrocks | grep -q tls-cert-file"
    if [[ -n "$EXPECTED_VERSION" ]]; then
        check "kvrocks --version reports $EXPECTED_VERSION" bash -c "/usr/bin/kvrocks --version | grep -q 'version $EXPECTED_VERSION'"
    else
        skip "version check (no --version)"
    fi
    check "kvrocks2redis prints usage" bash -c "/usr/bin/kvrocks2redis -h 2>&1 | grep -q 'sync kvrocks to redis'"
}

test_service() {
    section "Service"
    local get=$'*2\r\n$3\r\nGET\r\n$7\r\npkgtest\r\n'
    check "enable unit" systemctl enable kvrocks
    check "service starts" systemctl start kvrocks
    check "service active" systemctl is-active kvrocks
    check "runs as kvrocks" test "$(ps -o user= -C kvrocks | head -1)" = kvrocks
    check "PING answers PONG" wait_ready
    check "SET" test "$(resp $'*3\r\n$3\r\nSET\r\n$7\r\npkgtest\r\n$5\r\nvalue\r\n')" = "+OK"
    check "GET" test "$(resp "$get")" = "value"
    check "CONFIG REWRITE works" test "$(resp $'*2\r\n$6\r\nCONFIG\r\n$7\r\nREWRITE\r\n')" = "+OK"
    check "rewritten config not world-accessible" bash -c "test -f /etc/kvrocks/kvrocks.conf && test -z \"\$(find /etc/kvrocks/kvrocks.conf -perm /o=rwx)\""
    check "restart" systemctl restart kvrocks
    check "ready after restart" wait_ready
    check "data survives restart" test "$(resp "$get")" = "value"
    check "log file written" bash -c "ls /var/log/kvrocks/ | grep -q kvrocks"
}

test_state_dir_recreated() {
    section "State dir recreated"
    systemctl stop kvrocks
    rm -rf /var/lib/kvrocks
    check "start with missing data dir" systemctl start kvrocks
    check "ready with recreated data dir" wait_ready
    check "data dir recreated" test -d /var/lib/kvrocks
}

test_config_preserved_on_reinstall() {
    section "Config preserved on reinstall"
    [[ -n "$PKG_DIR" ]] || { skip "only with --pkg-dir"; return; }
    systemctl is-active --quiet kvrocks || { systemctl start kvrocks && wait_ready; }
    echo "# pkgtest-marker" >> /etc/kvrocks/kvrocks.conf
    if [[ "$OS_FAMILY" == deb ]]; then
        apt-get install -y --reinstall "$PKG_DIR"/percona-kvrocks-server_*.deb >/dev/null 2>&1
    else
        pm reinstall -y "$PKG_DIR"/percona-kvrocks-server-[0-9]*.rpm >/dev/null 2>&1
    fi
    check "local edit kept" grep -q 'pkgtest-marker' /etc/kvrocks/kvrocks.conf
    check "service still active after reinstall" systemctl is-active kvrocks
}

test_removal() {
    section "Removal"
    systemctl stop kvrocks
    if [[ "$OS_FAMILY" == deb ]]; then
        check "purge packages" apt-get purge -y percona-kvrocks-server percona-kvrocks-tools
        check "data dir removed on purge" test ! -e /var/lib/kvrocks
        check "log dir removed on purge" test ! -e /var/log/kvrocks
        check "config removed on purge" test ! -e /etc/kvrocks/kvrocks.conf
    else
        check "erase packages" pm remove -y percona-kvrocks-server percona-kvrocks-tools
        check "data dir kept on erase" test -d /var/lib/kvrocks
        check "log dir kept on erase" test -d /var/log/kvrocks
    fi
    check "binary removed" test ! -e /usr/bin/kvrocks
    check "tools binary removed" test ! -e /usr/bin/kvrocks2redis
    check "unit removed" bash -c "! systemctl cat kvrocks >/dev/null 2>&1"
}

install_packages
test_files
test_service
test_state_dir_recreated
test_config_preserved_on_reinstall
test_removal

printf '\nPASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
