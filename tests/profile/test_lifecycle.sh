#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
# Load service functions with OpenWrt procd import replaced by test doubles.
sed '/^\. \/lib\/functions\/procd.sh$/d' "$root/openwrt/root/etc/init.d/zapret-forkop" > "$tmp/init"
. "$tmp/init"
RUNTIME="$tmp/runtime"
BRIDGE="$tmp/bridge"
NFT="$tmp/nft"
PREPARE="$tmp/prepare"
SERVICE=zapret-forkop
mkdir -p "$RUNTIME"
touch "$BRIDGE"
chmod +x "$BRIDGE"
cat > "$PREPARE" <<'PREPARE'
#!/bin/sh
[ "${TEST_PREPARE_FAIL:-0}" != 1 ] || exit 1
candidate=$(mktemp -d "$RUNTIME/candidate.XXXXXXXX")
echo '1 11080 4400 134238465 20737' > "$candidate/manifest"
echo table > "$candidate/rules.nft"
printf '%s\n' "$candidate"
PREPARE
cat > "$NFT" <<'NFT'
#!/bin/sh
case "$1:$2:$3" in
    list:table:inet) [ "$4" != forkop_zapret_bridge ] || [ "${TEST_OLD_BRIDGE:-0}" = 1 ];;
    -f:-:*) cat >/dev/null; [ "${TEST_NFT_FAIL:-0}" != 1 ];;
    delete:table:inet) exit 0;;
    *) exit 1;;
esac
NFT
chmod +x "$PREPARE" "$NFT"
export RUNTIME
check_conntrack_accounting() { return 0; }
ensure_queue_support() { [ "${TEST_QUEUE_MODULE_FAIL:-0}" != 1 ]; }
check_stage() { [ "${TEST_PREFLIGHT_FAIL:-0}" != 1 ]; }
wait_for_stage() { [ "${TEST_READY_FAIL:-0}" != 1 ]; }
register_stage() { printf '%s\n' "$1" >> "$tmp/register.log"; }
procd_kill() { printf '%s\n' kill >> "$tmp/register.log"; }
# BSD mv does not support -T; emulate replacing the symlink for this isolated test.
mv() { rm -f "$3"; command mv "$2" "$3"; }

start_locked >/dev/null
old=$(readlink "$RUNTIME/current")
[ -d "$old" ]
[ "$(wc -l < "$tmp/register.log" | tr -d ' ')" = 1 ]

TEST_PREPARE_FAIL=1; export TEST_PREPARE_FAIL
if start_locked >/dev/null 2>&1; then echo 'invalid config accepted' >&2; exit 1; fi
unset TEST_PREPARE_FAIL
[ "$(readlink "$RUNTIME/current")" = "$old" ]
[ "$(wc -l < "$tmp/register.log" | tr -d ' ')" = 1 ]

TEST_OLD_BRIDGE=1; export TEST_OLD_BRIDGE
if start_locked >/dev/null 2>&1; then echo 'old bridge conflict accepted' >&2; exit 1; fi
unset TEST_OLD_BRIDGE
[ "$(readlink "$RUNTIME/current")" = "$old" ]
[ "$(wc -l < "$tmp/register.log" | tr -d ' ')" = 1 ]

TEST_QUEUE_MODULE_FAIL=1; export TEST_QUEUE_MODULE_FAIL
if start_locked >/dev/null 2>&1; then echo 'unavailable NFQUEUE accepted' >&2; exit 1; fi
unset TEST_QUEUE_MODULE_FAIL
[ "$(readlink "$RUNTIME/current")" = "$old" ]
[ "$(wc -l < "$tmp/register.log" | tr -d ' ')" = 1 ]

TEST_PREFLIGHT_FAIL=1; export TEST_PREFLIGHT_FAIL
if start_locked >/dev/null 2>&1; then echo 'conflicting allocation accepted' >&2; exit 1; fi
unset TEST_PREFLIGHT_FAIL
[ "$(readlink "$RUNTIME/current")" = "$old" ]
[ "$(wc -l < "$tmp/register.log" | tr -d ' ')" = 1 ]

TEST_READY_FAIL=1; export TEST_READY_FAIL
if start_locked >/dev/null 2>&1; then echo 'unready process accepted' >&2; exit 1; fi
unset TEST_READY_FAIL
[ "$(readlink "$RUNTIME/current")" = "$old" ]
[ "$(tail -n 1 "$tmp/register.log")" = "$old" ]

TEST_NFT_FAIL=1; export TEST_NFT_FAIL
if start_locked >/dev/null 2>&1; then echo 'nft failure accepted' >&2; exit 1; fi
unset TEST_NFT_FAIL
[ "$(readlink "$RUNTIME/current")" = "$old" ]
[ "$(tail -n 1 "$tmp/register.log")" = "$old" ]

# Failed attempts left candidates behind; a successful start keeps only its own.
[ "$(ls -d "$RUNTIME"/candidate.* | wc -l | tr -d ' ')" -gt 1 ]
start_locked >/dev/null
current=$(readlink "$RUNTIME/current")
[ "$(ls -d "$RUNTIME"/candidate.*)" = "$current" ]

lock() { :; }
stop
[ ! -e "$RUNTIME/current" ]
[ -z "$(ls -A "$RUNTIME")" ]
echo 'service lifecycle rollback tests passed'
