# OpenWrt profile manager (experimental)

This is development code, not a migration guide. Do not install or enable this
service alongside the existing `forkop-zapret-bridge`: it uses the same queue
numbers and socket marks. The service refuses to start if the old bridge's
`inet forkop_zapret_bridge` table exists.

## Data flow

LuCI stores profiles under UCI `zapret_forkop`. Each enabled `profile` has
`name`, `slot` (1–254), and `strategy`. Slot 1 maps to port 11080, queue
4400, socket mark 0x08005101 and connection mark 0x5101; each next slot adds 1.
Profile strategy text consists of whitespace-separated `--option` and
`--option=value` tokens. Quoting, backslash escapes, standalone paths and
nested config files are not supported. The manager supplies `--qnum` and
`--dpi-desync-fwmark`; it rejects options that take over process lifecycle or
queue management. The nfqws binary and required fake packet files must already
be installed.

`zapret-forkop-prepare` writes an isolated candidate in tmpfs. It runs the
actual nfqws `--dry-run` for each profile and `nft -c` for the generated
rules before touching current service state. The init script independently
checks that Linux conntrack accounting is enabled, refuses the old bridge
table, loads nfnetlink_queue on cold start when necessary, and checks TCP listener
and NFQUEUE ownership. The service fails closed if the module or ownership
information is unavailable. Current procd instances
are allowed to retain their own allocations. The manager registers per-profile
SOCKS and nfqws instances through procd and checks that each process is running
and owns the expected listener or NFQUEUE in two successive checks. It then
applies only its own `inet zapret_forkop` table in a single nft transaction.

The LuCI page presents a SOCKS outbound JSON for each saved profile. A user
must add it to a Forkop connection section and choose the desired domains and
devices there. Forkop is not modified automatically.

Every instance set is registered together with a `zapret_forkop` config
reload trigger, so a saved UCI change (for example LuCI Save & Apply) reloads
the running service. A stopped service has no trigger and stays stopped. Ordinary `start`, `reload` and `restart` validate a candidate
before registering it. `stop` deletes only this application's table. On
registration, readiness or nft transaction failure the service attempts to restore the
last registered instance set; nft failure leaves the old nft table untouched.
The active candidate stays in tmpfs for procd respawns; older candidates are
removed after a successful switch and all of them on `stop`.

A firewall include may call `/usr/libexec/zapret-forkop-firewall` to restore
the current table following a firewall reload. The helper is a no-op when the
service is stopped and uses an nft transaction. `install.sh` adds this
include as `firewall.zapret_forkop` but does not reload the firewall.

## Validation and known limitations

- Candidate validation and unit tests do **not** guarantee a strategy works
  against an ISP's DPI or that a process survives after two readiness checks.
  This checks process/listener/queue ownership, not end-to-end traffic. A
  process may fail later; queue bypass then permits traffic without DPI
  modification. There is no automatic rollback on a later crash or failed
  user-level traffic.
- An attempt to restore a previous procd instance set may itself fail, and is
  currently best effort. The service does not coordinate a rollback with
  Forkop configuration. Do not use this as a zero-downtime transaction.
- Existing Unix socket marks and low 16 conntrack-mark bits are assumed free
  except for the old bridge. The service does not discover all unrelated
  rules or other processes using the same queues. Review the full firewall
  and process state before any migration.
- Process readiness and preflight ownership code have mocked local tests, and
  the ownership check has been exercised read-only against existing router
  processes. On one Cudy TR3000, LuCI Save & Apply, firewall reload and reboot
  were checked with the new service (see README). The UCI reload trigger was
  added afterwards and still needs a device check; respawn after crashes and
  concurrent settings changes are not device-tested. Allocation checks are
  subject to races with unrelated services.
- The SOCKS listener has no authentication and must bind only to loopback.
  A saved profile must not be mistaken for an applied or healthy profile.
- Back up configurations and existing strategy files before migration. Use
  the previous bridge as the rollback path until real TCP, UDP, DNS, HTTPS,
  YouTube, Discord voice and reboot testing is complete.

## Isolated router test

A temporary adapted service with a separate procd name, nft table, port and queue
passed start, reload, invalid reload and stop on the Cudy router. YouTube HTTPS
returned 200 and the isolated queue counter increased; an invalid strategy was
rejected without removing the previous test configuration. The existing bridge
was not restarted. The test resources were removed. This does not validate the
unmodified production installation, firewall reload, LuCI apply, reboot or UDP.
