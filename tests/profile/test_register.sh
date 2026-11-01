#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sed '/^\. \/lib\/functions\/procd.sh$/d' "$root/openwrt/root/etc/init.d/zapret-forkop" > "$tmp/init"
. "$tmp/init"
initscript=/etc/init.d/zapret-forkop

# Record the procd calls made while registering an instance set.
for fn in procd_open_service procd_close_service procd_open_instance procd_close_instance \
    procd_set_param procd_open_trigger procd_close_trigger procd_add_reload_trigger; do
    eval "$fn() { printf '%s\n' \"$fn \$*\" >> \"\$tmp/calls\"; }"
done
mkdir "$tmp/stage"
echo '1 11080 4400 134238465 20737' > "$tmp/stage/manifest"
register_stage "$tmp/stage"

grep -qx 'procd_add_reload_trigger zapret_forkop' "$tmp/calls"
grep -qx 'procd_set_param limits nofile=4096 4096' "$tmp/calls"
# Triggers must be part of the description replaced by "procd_close_service set".
[ "$(grep -n 'procd_add_reload_trigger' "$tmp/calls" | cut -d: -f1)" -lt \
  "$(grep -n 'procd_close_service set' "$tmp/calls" | cut -d: -f1)" ]
[ "$(tail -n 1 "$tmp/calls")" = 'procd_close_service set' ]
echo 'procd registration tests passed'
