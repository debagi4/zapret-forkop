# Experimental OpenWrt bundle

This documents the build and file installation; it does not authorize migration
or enable/start services. The current standalone bridge continues to own its
ports, queues and nft table. Do not enable or start the new service alongside it.

## Build and package

Build the ARM64 musl binary, then create a bundle:

```sh
scripts/build-openwrt.sh
scripts/package-openwrt.sh \
  target/aarch64-unknown-linux-musl/release/zapret-forkop \
  /tmp/zapret-forkop-openwrt.tar.gz
```

For a custom target directory, provide the resulting binary path instead. The
archive contains `install.sh`, `rollback.sh`, and `root/`. Transfer the
archive through a trusted channel; it is not signed.

## File installation

Extract the bundle on the router, inspect its contents, and run its
`install.sh` as root. The installer:

- checks that the binary is an AArch64 ELF, checks OpenWrt dependencies, and
  refuses to overwrite an unrelated firewall section;
- refuses to update the application while its own procd instances are running;
- records existing files and firewall configuration under a mode-0700
  `/root/zapret-forkop-backups/TIMESTAMP-PID` directory before changes;
- copies the application, leaves existing profile configuration untouched,
  and saves a `firewall.zapret_forkop` script include by editing a uniquely
  named temporary UCI copy, preserving separately staged firewall changes;
- installs a sysupgrade keep list containing the application files and profiles.

After installation, run `/etc/init.d/rpcd reload` and remove
`/tmp/luci-indexcache*` and `/tmp/luci-modulecache` so LuCI picks up the new
ACL and menu entry; the installer prints this hint but does not do it itself.

It does **not** start, stop, enable or disable either service and does not
reload firewall or Forkop. Existing /opt/zapret binaries, fake packet files,
and the old bridge must be backed up separately. This bundle doesn't install
Zapret or its kernel modules. Backups under /root are not automatically copied
off the router and are not included in this keep list. Download a copy through
a trusted channel if it must survive a factory reset.

The post-install backup directory is sensitive: firewall and profiles may
contain network settings. Do not publish it.

## Rollback

Keep the extracted bundle and note the backup path printed by `install.sh`.
Before rollback, stop the new service if it is running. Invoke
`sh rollback.sh /root/zapret-forkop-backups/TIMESTAMP-PID`.

Rollback checks the backup manifest and compares each installed file with its
post-install snapshot **before changing anything**. If any file, including
profiles or firewall configuration, has changed since installation, it refuses
to overwrite later edits. In that case preserve current files and merge the
relevant settings manually. UCI staged changes are separate from saved files
and must also be checked before manually restoring firewall settings.

The installer compares the saved firewall before replacement; this detects
intervening writes but cannot fully lock out unrelated writers.

A successful rollback restores the recorded original files and firewall config
or removes files created by this installer. It does not restart services,
reload the firewall, alter boot symlinks, or switch Forkop routes. Restoring
files is not itself a full routing rollback; start and validate the old bridge
and reload firewall/Forkop as appropriate for your device. Rollback is
best-effort if the filesystem fails mid-restore; keep an external backup.

Do not enable the new service, update the old one, or modify live routing until
the new install, LuCI apply, firewall reload, device traffic, rollback and boot
sequence have been verified on the target OpenWrt version.
