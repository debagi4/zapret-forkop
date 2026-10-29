#!/bin/sh
# Restore a specific install snapshot only when installed files have not changed.
set -eu
usage() { echo "Usage: sh rollback.sh [--root TEST_ROOT] BACKUP_DIRECTORY" >&2; exit 2; }
root=
if [ "${1:-}" = --root ]; then
    [ "$#" -eq 3 ] || usage
    case "$2" in /*) root="${2%/}";; *) usage;; esac
    [ -n "$root" ] && [ -d "$root" ] || usage
    shift 2
fi
[ "$#" -eq 1 ] || usage
[ "$(id -u)" = 0 ] || { echo "Root privileges required" >&2; exit 1; }
backup=$(CDPATH= cd -- "$1" && pwd -P)
base=$(CDPATH= cd -- "$root/root/zapret-forkop-backups" && pwd -P)
case "$backup" in "$base"/*) ;; *) echo "Backup is outside the installer backup directory" >&2; exit 1;; esac
[ -f "$backup/manifest" ] || { echo "Backup manifest missing" >&2; exit 1; }
if [ -z "$root" ]; then
    services=$(ubus call service list '{"name":"zapret-forkop"}' 2>/dev/null) || {
        echo "Cannot query procd; refusing changes" >&2; exit 1;
    }
    if printf '%s\n' "$services" | jsonfilter -e "@['zapret-forkop'].instances[*].running" 2>/dev/null | grep -qx true; then
        echo "Stop the new zapret-forkop service before rollback" >&2
        exit 1
    fi
fi
allowed() {
    case "$1" in
        /etc/config/firewall|/usr/sbin/zapret-forkop|/etc/init.d/zapret-forkop|\
        /usr/libexec/zapret-forkop-prepare|/usr/libexec/zapret-forkop-firewall|\
        /usr/share/luci/menu.d/luci-app-zapret-forkop.json|\
        /usr/share/rpcd/acl.d/luci-app-zapret-forkop.json|\
        /www/luci-static/resources/view/zapret-forkop/profiles.js|\
        /lib/upgrade/keep.d/zapret-forkop|/etc/config/zapret_forkop) return 0;;
        *) return 1;;
    esac
}
# Validate every path before changing any file.
while IFS=' ' read -r state path; do
    [ -n "$path" ] && allowed "$path" || { echo "Invalid backup manifest" >&2; exit 1; }
    case "$state" in present|absent) ;; *) echo "Invalid backup state" >&2; exit 1;; esac
    [ "$state" != present ] || [ -f "$backup/files$path" ] || {
        echo "Original snapshot is missing for $path" >&2; exit 1;
    }
    [ -f "$root$path" ] && [ ! -L "$root$path" ] && [ -f "$backup/installed$path" ] &&
        cmp -s "$backup/installed$path" "$root$path" || {
        echo "Refusing rollback: $path changed after installation; preserve your edits and restore manually" >&2
        exit 1
    }
done < "$backup/manifest"
while IFS=' ' read -r state path; do
    if [ "$state" = present ]; then
        tmpfile="$root$path.zf-rollback.$$"
        cp -p "$backup/files$path" "$tmpfile"
        mv -f "$tmpfile" "$root$path"
    else
        rm -f "$root$path"
    fi
done < "$backup/manifest"
echo "Restored files from $backup; no service or firewall reload was performed."
