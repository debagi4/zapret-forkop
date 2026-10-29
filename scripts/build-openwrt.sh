#!/bin/sh
# Cross-build a static ARM64 musl binary on a host with Rust, its musl target and Zig.
set -eu
: "${ZIG:=zig}"
: "${CARGO:=cargo}"
if ! command -v "$ZIG" >/dev/null 2>&1; then echo "Zig is required (set ZIG to its path)" >&2; exit 1; fi
if ! command -v "$CARGO" >/dev/null 2>&1; then echo "Cargo is required (set CARGO to its path)" >&2; exit 1; fi
export ZIG
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat > "$tmp/cc" <<'WRAPPER'
#!/bin/bash
args=()
for arg in "$@"; do
    case "$arg" in
        --target=aarch64-unknown-linux-musl) ;;
        *) args+=("$arg") ;;
    esac
done
exec "$ZIG" cc -target aarch64-linux-musl "${args[@]}"
WRAPPER
cat > "$tmp/ar" <<'WRAPPER'
#!/bin/sh
exec "$ZIG" ar "$@"
WRAPPER
chmod +x "$tmp/cc" "$tmp/ar"
export CC_aarch64_unknown_linux_musl="$tmp/cc"
export AR_aarch64_unknown_linux_musl="$tmp/ar"
if [ -n "${ZAPRET_LINKER:-}" ]; then
    command -v "$ZAPRET_LINKER" >/dev/null 2>&1 || { echo "Linker not found: $ZAPRET_LINKER" >&2; exit 1; }
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$ZAPRET_LINKER"
    export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C link-self-contained=yes"
else
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$tmp/cc"
    export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C link-self-contained=no"
fi
"$CARGO" build --release --locked --target aarch64-unknown-linux-musl
