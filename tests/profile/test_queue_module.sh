#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sed '/^\. \/lib\/functions\/procd.sh$/d' "$root/openwrt/root/etc/init.d/zapret-forkop" > "$tmp/init"
. "$tmp/init"
queue_file="$tmp/nfnetlink_queue"

# A loaded module should not invoke modprobe.
touch "$queue_file"
modprobe() { echo unexpected > "$tmp/calls"; return 1; }
ensure_queue_support "$queue_file"
[ ! -e "$tmp/calls" ]

# A cold start loads the module and then verifies the proc entry.
rm "$queue_file"
modprobe() { [ "$1" = nfnetlink_queue ]; touch "$queue_file"; }
ensure_queue_support "$queue_file"
[ -r "$queue_file" ]

# A missing module or missing ownership data must fail closed.
rm "$queue_file"
modprobe() { return 1; }
if ensure_queue_support "$queue_file" 2>/dev/null; then echo 'missing module accepted' >&2; exit 1; fi
modprobe() { return 0; }
if ensure_queue_support "$queue_file" 2>/dev/null; then echo 'missing proc file accepted' >&2; exit 1; fi
echo 'NFQUEUE cold-start tests passed'
