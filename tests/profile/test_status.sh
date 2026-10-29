#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sed '/^\. \/lib\/functions\/procd.sh$/d' "$root/openwrt/root/etc/init.d/zapret-forkop" > "$tmp/init"

# Model rc.common's EXTRA_COMMANDS dispatch without USE_PROCD; its standard
# procd wrappers would override transactional start/reload.
. "$tmp/init"
case " $EXTRA_COMMANDS " in *" running "*) ;; *) echo 'running unavailable to rc.common' >&2; exit 1;; esac
case " $EXTRA_COMMANDS " in *" status "*) ;; *) echo 'status unavailable to rc.common' >&2; exit 1;; esac
[ -z "${USE_PROCD:-}" ] || { echo 'USE_PROCD would replace lifecycle handlers' >&2; exit 1; }

procd_running() {
    [ "$1" = zapret-forkop ] && [ "$2" = "${EXPECTED_INSTANCE:-*}" ] && [ "${PROCESS_RUNNING:-1}" = 1 ]
}
_procd_status() {
    [ "$1" = zapret-forkop ] && [ "$2" = "${EXPECTED_INSTANCE:-}" ] || return 99
    echo "${EXPECTED_STATUS:-running}"
    return "${STATUS_EXIT:-0}"
}

[ -z "$(running)" ] || { echo 'running must be silent' >&2; exit 1; }
EXPECTED_INSTANCE=socks_1; export EXPECTED_INSTANCE
running socks_1
PROCESS_RUNNING=0; export PROCESS_RUNNING
if running socks_1; then echo 'stopped instance reported running' >&2; exit 1; fi
unset EXPECTED_INSTANCE PROCESS_RUNNING

[ "$(status)" = running ]
EXPECTED_INSTANCE=nfqws_1 EXPECTED_STATUS='not running' STATUS_EXIT=5
export EXPECTED_INSTANCE EXPECTED_STATUS STATUS_EXIT
set +e
output=$(status nfqws_1)
rc=$?
set -e
[ "$output" = 'not running' ] && [ "$rc" -eq 5 ]
echo 'service running and status tests passed'
