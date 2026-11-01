#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
binary="${1:-/tmp/zapret-cross-target/aarch64-unknown-linux-musl/release/zapret-forkop}"
[ -f "$binary" ] || { echo "provide an AArch64 test binary" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/root/etc/config" "$tmp/root/lib" "$tmp/root/opt/zapret/nfq"
echo '# original firewall' > "$tmp/root/etc/config/firewall"
: > "$tmp/root/lib/functions.sh"
echo '#!/bin/sh' > "$tmp/root/opt/zapret/nfq/nfqws"
chmod +x "$tmp/root/opt/zapret/nfq/nfqws"
for c in nft ubus jsonfilter; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
printf '#!/bin/sh\necho 0\n' > "$tmp/bin/id"
cat > "$tmp/bin/uci" <<'MOCK'
#!/bin/sh
if [ "$1" = -c ]; then config=$2; shift 2; fi
if [ "$1" = -C ]; then shift 2; fi
if [ "$1" = -t ]; then shift 2; fi
[ "$1" != -q ] || shift
case "$1" in
    get)
        package=${2%%.*}
        case "$2" in
            *.zapret_forkop)
                [ "${UCI_COLLISION:-0}" = 1 ] && { echo rule; exit 0; }
                grep -q '^# mock-section' "$config/$package" && { echo include; exit 0; }
                exit 1 ;;
            *.zapret_forkop.path)
                grep -q '^# mock-section' "$config/$package" && { echo /usr/libexec/zapret-forkop-firewall; exit 0; }
                exit 1 ;;
            *) exit 1 ;;
        esac
        ;;
    batch)
        input=$(cat)
        package=$(printf '%s\n' "$input" | sed -n 's/^commit //p')
        echo '# mock-section' >> "$config/$package"
        [ "${UCI_RACE:-0}" != 1 ] || echo '# concurrent change' >> "$UCI_TARGET_FIREWALL"
        [ "${UCI_FAIL:-0}" != 1 ]
        ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/id" "$tmp/bin/uci"
PATH="$tmp/bin:$PATH"
export PATH
"$project/scripts/package-openwrt.sh" "$binary" "$tmp/bundle.tar.gz" >/dev/null
mkdir "$tmp/bundle"
tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/bundle"

# Success preserves preexisting profiles, captures firewall backup, and installs keep list.
printf 'existing profiles\n' > "$tmp/root/etc/config/zapret_forkop"
sh "$tmp/bundle/install.sh" --root "$tmp/root" > "$tmp/result"
[ "$(cat "$tmp/root/etc/config/zapret_forkop")" = 'existing profiles' ]
[ -x "$tmp/root/usr/sbin/zapret-forkop" ]
[ -f "$tmp/root/lib/upgrade/keep.d/zapret-forkop" ]
grep -q "Neither service was started" "$tmp/result"
# The installer's private umask must not hide new web directories from LuCI.
for dir in www www/luci-static/resources/view/zapret-forkop usr/share/rpcd/acl.d; do
    [ "$(ls -ld "$tmp/root/$dir" | cut -c1-10)" = drwxr-xr-x ] || { echo "unexpected mode: $dir" >&2; exit 1; }
done
backup=$(sed -n 's/^Files installed. Backup: //p' "$tmp/result")
grep -q '# original firewall' "$backup/files/etc/config/firewall"
grep -q '# mock-section' "$tmp/root/etc/config/firewall"

# Failed UCI commit restores old firewall and application binary, profiles remain.
printf 'previous-binary' > "$tmp/root/usr/sbin/zapret-forkop"
cp "$tmp/root/etc/config/firewall" "$tmp/firewall-before"
if UCI_FAIL=1 sh "$tmp/bundle/install.sh" --root "$tmp/root" > /dev/null 2>&1; then
    echo "failed UCI transaction unexpectedly succeeded" >&2; exit 1
fi
cmp "$tmp/firewall-before" "$tmp/root/etc/config/firewall"
[ "$(cat "$tmp/root/usr/sbin/zapret-forkop")" = previous-binary ]
[ "$(cat "$tmp/root/etc/config/zapret_forkop")" = 'existing profiles' ]

# Foreign UCI section must not be changed.
if UCI_COLLISION=1 sh "$tmp/bundle/install.sh" --root "$tmp/root" > /dev/null 2>&1; then
    echo "foreign firewall section unexpectedly accepted" >&2; exit 1
fi
cmp "$tmp/firewall-before" "$tmp/root/etc/config/firewall"
[ "$(cat "$tmp/root/usr/sbin/zapret-forkop")" = previous-binary ]

# Concurrent edits made after the snapshot must not be overwritten on failure.
if UCI_RACE=1 UCI_TARGET_FIREWALL="$tmp/root/etc/config/firewall" \
    sh "$tmp/bundle/install.sh" --root "$tmp/root" > /dev/null 2>&1; then
    echo "concurrent firewall modification unexpectedly accepted" >&2; exit 1
fi
grep -q '# concurrent change' "$tmp/root/etc/config/firewall"
[ "$(cat "$tmp/root/usr/sbin/zapret-forkop")" = previous-binary ]
cp "$tmp/firewall-before" "$tmp/root/etc/config/firewall"

# A rollback refuses to overwrite edits made after installation.
printf 'later edit\n' >> "$tmp/root/etc/config/zapret_forkop"
if sh "$tmp/bundle/rollback.sh" --root "$tmp/root" "$backup" > /dev/null 2>&1; then
    echo "rollback unexpectedly accepted a modified profile" >&2; exit 1
fi
[ -e "$tmp/root/usr/sbin/zapret-forkop" ]

# Restoring the post-install snapshot allows explicit rollback to the original files.
cp "$backup/installed/etc/config/zapret_forkop" "$tmp/root/etc/config/zapret_forkop"
cp "$backup/installed/usr/sbin/zapret-forkop" "$tmp/root/usr/sbin/zapret-forkop"
cp "$backup/installed/etc/config/firewall" "$tmp/root/etc/config/firewall"
sh "$tmp/bundle/rollback.sh" --root "$tmp/root" "$backup" > /dev/null
[ ! -e "$tmp/root/usr/sbin/zapret-forkop" ]
[ "$(cat "$tmp/root/etc/config/zapret_forkop")" = 'existing profiles' ]
[ "$(cat "$tmp/root/etc/config/firewall")" = '# original firewall' ]
echo "installer and rollback tests passed"

