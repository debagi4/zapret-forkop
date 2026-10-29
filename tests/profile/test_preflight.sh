#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sed '/^\. \/lib\/functions\/procd.sh$/d' "$root/openwrt/root/etc/init.d/zapret-forkop" > "$tmp/init"
. "$tmp/init"
mkdir "$tmp/stage"
echo '1 11080 4400 134238465 20737' > "$tmp/stage/manifest"
service_pid() {
    case "$1" in socks_1) echo 111;; nfqws_1) echo 222;; *) return 1;; esac
}
port_owners() { printf '%s' "${TEST_OWNERS:-}"; }
queue_portid() { printf '%s' "${TEST_QUEUE:-}"; }
netlink_owned_by() { [ "$1" = 222 ] && [ "$2" = 222 ]; }
procd_running() { [ "${TEST_PROCESS_RUNNING:-1}" = 1 ]; }

check_stage "$tmp/stage" preflight
if check_stage "$tmp/stage" ready; then echo 'empty service accepted as ready' >&2; exit 1; fi
TEST_OWNERS='111/bridge'; export TEST_OWNERS
TEST_QUEUE=222; export TEST_QUEUE
check_stage "$tmp/stage" preflight
check_stage "$tmp/stage" ready
TEST_OWNERS='333/other'; export TEST_OWNERS
if check_stage "$tmp/stage" preflight 2>/dev/null; then echo 'foreign port accepted' >&2; exit 1; fi
TEST_OWNERS='111/bridge'; export TEST_OWNERS
TEST_QUEUE=333; export TEST_QUEUE
if check_stage "$tmp/stage" preflight 2>/dev/null; then echo 'foreign queue accepted' >&2; exit 1; fi
TEST_QUEUE=222; export TEST_QUEUE
TEST_PROCESS_RUNNING=0; export TEST_PROCESS_RUNNING
if check_stage "$tmp/stage" ready; then echo 'stopped process accepted' >&2; exit 1; fi
echo 'port and queue preflight tests passed'
