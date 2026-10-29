#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin" "$tmp/runtime"
cat > "$tmp/functions" <<'FUNCTIONS'
config_load() { [ "$1" = zapret_forkop ]; }
config_foreach() { "$1" first; "$1" second; }
config_get_bool() { config_get "$@"; }
config_get() {
    case "$2:$3" in
        first:enabled|second:enabled) value=1;;
        first:slot) value=1;;
        second:slot) value="${TEST_SECOND_SLOT:-2}";;
        *:name) value=example;;
        first:strategy) value="${TEST_FIRST_STRATEGY:---filter-tcp=443 --dpi-desync=fake}";;
        second:strategy) value='--filter-udp=443 --dpi-desync=fake';;
        *) value=;;
    esac
    export "TEST_VALUE=$value"
    eval "$1=\$TEST_VALUE"
}
FUNCTIONS
cat > "$tmp/bin/nfqws" <<'NFQWS'
#!/bin/sh
f=${1#@}
grep -qx -- '--dry-run' "$f" || exit 1
! grep -q -- '--reject-by-test' "$f"
NFQWS
cat > "$tmp/bin/nft" <<'NFT'
#!/bin/sh
case "$1" in
  list) exit 1;;
  -c) [ "$2" = -f ] && grep -q 'table inet zapret_forkop' "$3";;
  *) echo 'unexpected live nft operation' >&2; exit 1;;
esac
NFT
chmod +x "$tmp/bin/"*
export ZAPRET_FORKOP_FUNCTIONS="$tmp/functions"
export ZAPRET_FORKOP_NFQWS="$tmp/bin/nfqws"
export ZAPRET_FORKOP_NFT="$tmp/bin/nft"
export ZAPRET_FORKOP_TMP_ROOT="$tmp/runtime"
prepare="$root/openwrt/root/usr/libexec/zapret-forkop-prepare"
candidate=$("$prepare")
[ -d "$candidate" ]
grep -qx '1 11080 4400 134238465 20737' "$candidate/manifest"
grep -qx '2 11081 4401 134238466 20738' "$candidate/manifest"
grep -qx -- '--qnum=4400' "$candidate/1.args"
grep -q 'meta mark 0x08005101' "$candidate/rules.nft"
grep -q 'queue num 4401 bypass' "$candidate/rules.nft"
rm -rf "$candidate"

reject() {
    if "$prepare" > "$tmp/out" 2> "$tmp/error"; then
        echo 'unexpected accepted profile' >&2
        exit 1
    fi
    [ -z "$(ls -A "$tmp/runtime")" ] || { echo 'failed candidate leaked' >&2; exit 1; }
}
TEST_SECOND_SLOT=1; export TEST_SECOND_SLOT; reject
unset TEST_SECOND_SLOT
TEST_SECOND_SLOT=01; export TEST_SECOND_SLOT; reject
unset TEST_SECOND_SLOT
TEST_FIRST_STRATEGY='--filter-tcp=443 --qnum=1'; export TEST_FIRST_STRATEGY; reject
TEST_FIRST_STRATEGY='--filter-tcp=443 @/tmp/options'; export TEST_FIRST_STRATEGY; reject
TEST_FIRST_STRATEGY='--filter-tcp=443 --reject-by-test'; export TEST_FIRST_STRATEGY; reject
TEST_FIRST_STRATEGY='--filter-tcp=443 --daemon'; export TEST_FIRST_STRATEGY; reject
echo 'profile preparation tests passed'
