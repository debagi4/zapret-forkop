#!/bin/sh
# Package already cross-compiled ARM64 binary and OpenWrt integration files.
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /path/to/aarch64-musl-binary /path/to/bundle.tar.gz" >&2
    exit 2
fi
binary=$1
output=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project=$(CDPATH= cd -- "$script_dir/.." && pwd)
[ -f "$binary" ] || { echo "Binary not found: $binary" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cp -R "$project/openwrt/root" "$tmp/root"
mkdir -p "$tmp/root/usr/sbin" "$tmp/root/www"
cp -R "$project/openwrt/htdocs/luci-static" "$tmp/root/www/"
cp "$binary" "$tmp/root/usr/sbin/zapret-forkop"
cp "$project/openwrt/install.sh" "$tmp/install.sh"
cp "$project/openwrt/rollback.sh" "$tmp/rollback.sh"
cp "$project/LICENSE" "$tmp/LICENSE"
cp "$project/docs/install-and-rollback.md" "$tmp/INSTALL.md"
chmod 755 "$tmp/install.sh" "$tmp/rollback.sh" "$tmp/root/usr/sbin/zapret-forkop" \
    "$tmp/root/etc/init.d/zapret-forkop" "$tmp/root/usr/libexec/zapret-forkop-prepare" \
    "$tmp/root/usr/libexec/zapret-forkop-firewall"
tar -C "$tmp" -czf "$output" install.sh rollback.sh LICENSE INSTALL.md root
echo "Created $output"
