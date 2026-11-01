#!/bin/sh
# Installs files only. It never starts, stops or enables either bridge.
set -eu
umask 077
# Backups stay private; installed directories must remain readable by services.
mkdir_public() { (umask 022 && mkdir -p "$1"); }

usage() { echo "Usage: sh install.sh [--root TEST_ROOT]" >&2; exit 2; }
root=
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --root ] || usage
    case "$2" in /*) root="${2%/}";; *) usage;; esac
    [ -n "$root" ] && [ -d "$root" ] || usage
fi
[ "$(id -u)" = 0 ] || { echo "Root privileges required" >&2; exit 1; }
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/root
binary="$src/usr/sbin/zapret-forkop"
[ -f "$binary" ] || { echo "Bundle has no Rust binary" >&2; exit 1; }
# ELF64, little endian, AArch64. Test-root mode still verifies the binary.
header=$(hexdump -n 20 -v -e '1/1 "%02x"' "$binary")
case "$header" in 7f454c46020101??????????????????????b700) ;; *)
    echo "Binary is not ELF64 little-endian AArch64" >&2; exit 1;; esac
if [ -z "$root" ]; then
    [ "$(uname -m)" = aarch64 ] || { echo "This bundle requires AArch64" >&2; exit 1; }
fi
for cmd in uci nft jsonfilter ubus hexdump; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
[ -x "$root/opt/zapret/nfq/nfqws" ] || { echo "Zapret nfqws is missing at /opt/zapret/nfq/nfqws" >&2; exit 1; }
[ -f "$root/etc/config/firewall" ] || { echo "OpenWrt firewall configuration not found" >&2; exit 1; }
[ -f "$root/lib/functions.sh" ] || { echo "OpenWrt functions missing" >&2; exit 1; }

# Refuse overwriting a running instance; existing old bridge is not touched.
if [ -z "$root" ]; then
    services=$(ubus call service list '{"name":"zapret-forkop"}' 2>/dev/null) || {
        echo "Cannot query procd; refusing changes" >&2; exit 1;
    }
    if printf '%s\n' "$services" | jsonfilter -e "@['zapret-forkop'].instances[*].running" 2>/dev/null | grep -qx true; then
        echo "Stop the new zapret-forkop service before updating its files" >&2
        exit 1
    fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zapret-install.XXXXXXXX") || exit 1
backup="$root/root/zapret-forkop-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$work/uci" "$backup/files"
manifest="$backup/manifest"
: > "$manifest"
done_install=0
firewall_installed=0
restore() {
    # Only restore targets recorded before modification.
    while IFS=' ' read -r state path; do
        [ -n "$path" ] || continue
        # Until our own atomic replacement, never revert somebody else's edit.
        [ "$path" != /etc/config/firewall ] || [ "$firewall_installed" = 1 ] || continue
        if [ "$state" = present ]; then
            mkdir_public "$(dirname "$root$path")"
            cp -p "$backup/files$path" "$root$path" || true
        else
            rm -f "$root$path"
        fi
    done < "$manifest"
}
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    [ -z "${tmpfile:-}" ] || rm -f "$tmpfile"
    if [ "$done_install" != 1 ]; then
        echo "Installation failed; restoring recorded files from $backup" >&2
        restore
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
backup_file() {
    path=$1
    dst="$root$path"
    if [ -L "$dst" ]; then echo "Refusing symlink destination: $path" >&2; return 1; fi
    if [ -e "$dst" ]; then
        [ -f "$dst" ] || { echo "Destination is not a file: $path" >&2; return 1; }
        mkdir -p "$(dirname "$backup/files$path")"
        cp -p "$dst" "$backup/files$path"
        printf 'present %s\n' "$path" >> "$manifest"
    else
        printf 'absent %s\n' "$path" >> "$manifest"
    fi
}
install_file() {
    path=$1
    mode=$2
    [ -f "$src$path" ] || { echo "Bundle is missing: $path" >&2; return 1; }
    backup_file "$path"
    dst="$root$path"
    mkdir_public "$(dirname "$dst")"
    tmpfile="$dst.zf-new.$$"
    cp "$src$path" "$tmpfile"
    chmod "$mode" "$tmpfile"
    mv -f "$tmpfile" "$dst"
    tmpfile=
}

# A private -t alone still reads /tmp/.uci/<package>.  Use a unique name.
package="zf_install_${work##*.}_$$"
mkdir -p "$work/config" "$work/overrides"
[ ! -e "/tmp/.uci/$package" ] || {
    echo "Temporary UCI package collision" >&2; exit 1;
}
cp -p "$root/etc/config/firewall" "$work/config/$package"
cp -p "$work/config/$package" "$work/original-firewall"
uci_get() {
    uci -c "$work/config" -C "$work/overrides" -t "$work/uci" -q get "$1"
}
if uci_get "$package.zapret_forkop" >/dev/null 2>&1; then
    [ "$(uci_get "$package.zapret_forkop")" = include ] &&
    [ "$(uci_get "$package.zapret_forkop.path" || true)" = /usr/libexec/zapret-forkop-firewall ] || {
        echo "firewall.zapret_forkop is already used by another configuration" >&2
        exit 1
    }
fi
backup_file /etc/config/firewall
cmp -s "$work/original-firewall" "$backup/files/etc/config/firewall" || {
    echo "Firewall configuration changed during preparation" >&2; exit 1;
}
install_file /usr/sbin/zapret-forkop 755
install_file /etc/init.d/zapret-forkop 755
install_file /usr/libexec/zapret-forkop-prepare 755
install_file /usr/libexec/zapret-forkop-firewall 755
install_file /usr/share/luci/menu.d/luci-app-zapret-forkop.json 644
install_file /usr/share/rpcd/acl.d/luci-app-zapret-forkop.json 644
install_file /www/luci-static/resources/view/zapret-forkop/profiles.js 644
install_file /lib/upgrade/keep.d/zapret-forkop 644
if [ ! -e "$root/etc/config/zapret_forkop" ]; then
    install_file /etc/config/zapret_forkop 600
else
    [ ! -L "$root/etc/config/zapret_forkop" ] && [ -f "$root/etc/config/zapret_forkop" ] || {
        echo "Unexpected /etc/config/zapret_forkop" >&2; exit 1;
    }
    # Existing profiles are not changed.
    backup_file /etc/config/zapret_forkop
fi

uci -c "$work/config" -C "$work/overrides" -t "$work/uci" batch <<UCI
set $package.zapret_forkop=include
set $package.zapret_forkop.type=script
set $package.zapret_forkop.path=/usr/libexec/zapret-forkop-firewall
set $package.zapret_forkop.fw4_compatible=1
set $package.zapret_forkop.enabled=1
commit $package
UCI
[ "$(uci_get "$package.zapret_forkop" || true)" = include ] &&
[ "$(uci_get "$package.zapret_forkop.path" || true)" = /usr/libexec/zapret-forkop-firewall ] || {
    echo "UCI did not produce the expected firewall include" >&2; exit 1;
}
# Do not overwrite a concurrent edit of the original saved configuration.
cmp -s "$backup/files/etc/config/firewall" "$root/etc/config/firewall" || {
    echo "Firewall configuration changed during installation" >&2; exit 1;
}
tmpfile="$root/etc/config/firewall.zf-new.$$"
cp -p "$root/etc/config/firewall" "$tmpfile"
cat "$work/config/$package" > "$tmpfile"
mv -f "$tmpfile" "$root/etc/config/firewall"
firewall_installed=1
tmpfile=

# A post-install snapshot prevents rollback from silently clobbering later edits.
while IFS=' ' read -r state path; do
    [ -n "$path" ] || continue
    [ -f "$root$path" ] && [ ! -L "$root$path" ] || {
        echo "Cannot snapshot installed file: $path" >&2; exit 1;
    }
    mkdir -p "$(dirname "$backup/installed$path")"
    cp -p "$root$path" "$backup/installed$path"
done < "$manifest"

done_install=1
echo "Files installed. Backup: $backup"
echo "Neither service was started, stopped, enabled or disabled."
echo "Firewall config saved; no firewall reload was performed."
echo "To show the LuCI page, run: /etc/init.d/rpcd reload; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache"
