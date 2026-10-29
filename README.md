# Zapret for Forkop

Experimental OpenWrt application for creating Zapret 1 profiles and routing
selected traffic to them from Forkop. **Experimental**: installed and tested on one Cudy TR3000 router, including
LuCI apply, firewall reload and reboot. Wider deployment still requires careful
validation and a rollback plan.

Forkop chooses traffic and connects to a per-profile loopback SOCKS5 endpoint.
A Rust bridge relays TCP and UDP with profile-specific Linux socket marks; the
profile's nfqws instance processes marked packets. There is no second
sing-box instance.

The LuCI view edits profile names, slots and nfqws arguments and shows a SOCKS
outbound JSON with the required Forkop tag. Adding that JSON to a Forkop
connection section and choosing routing rules is currently manual. The
experimental procd manager validates nfqws arguments and nftables, checks
listener and queue ownership, starts instances and attempts rollback on
application errors. Details and limitations: [OpenWrt profiles](docs/openwrt-profiles.md).

## Current limitations

- The old forkop-zapret-bridge is retained on the test router as a rollback
  option. Do not run both services at once: their queues and marks overlap.
- Google DoH is hard-coded and domain resolution is IPv4 only. SOCKS UDP IPv6
  is not implemented. No unauthenticated listener may bind outside loopback.
- The tested router has a firewall include and sysupgrade keep list. Installer
  rollback is best effort and late service failures may need manual recovery.
  Readiness checks do not guarantee working traffic or prevent later crashes.
- A saved profile does not imply a running, healthy profile.

## Development

```sh
cargo test --offline
cargo clippy --offline --all-targets -- -D warnings
cargo build --offline
python3 tests/socks_smoke.py
sh tests/profile/test_prepare.sh
sh tests/profile/test_lifecycle.sh
sh tests/profile/test_preflight.sh
sh tests/profile/test_queue_module.sh
node tests/profile/test_luci.js
```

For cross-compilation, install the Rust `aarch64-unknown-linux-musl` target and
Zig, then run `scripts/build-openwrt.sh`. Set `ZIG` and `CARGO` when needed.

On the Cudy router, an isolated ARM64 Rust binary passed DoH and HTTPS tests.
YouTube and Discord HTTPS requests through the Rust bridge and the **existing**
nfqws queues returned HTTP 200 and incremented the respective nft counters.
A separately named test copy of the new service passed start, reload, invalid reload, stop, and a YouTube HTTPS test on the router. On the same router, profile Save & Apply, firewall reload and reboot were also checked with the new service. Discord voice and QUIC remain unverified on-device.

## GitHub Actions и релизы

При push и в pull request запускаются проверки Rust, SOCKS TCP/UDP, LuCI и
установщика; затем Actions собирает архив для OpenWrt AArch64 и SHA-256.
Архив доступен в артефактах запуска. При публикации тега вида `v0.1.0`,
совпадающего с версией в Cargo.toml, после успешных проверок создаётся GitHub
Release с архивом и файлом SHA256SUMS.

Это tar.gz с установщиком, а не пакет apk/ipk. Он рассчитан на OpenWrt AArch64;
`nfqws` Zapret 1 и файлы стратегий нужно установить отдельно. Приложение
остаётся экспериментальным: см. ограничения выше и INSTALL.md в архиве.
