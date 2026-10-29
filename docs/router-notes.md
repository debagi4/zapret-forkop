# Existing router integration (reference; do not install over it)

Current separate service: /etc/init.d/forkop-zapret-bridge.
Config and original strategies: /etc/forkop-zapret-bridge/.
Loopback ports 11080 and 11081, nfqws queues 4400 and 4401.
Marks 0x08005101 and 0x08005102, nfqws injected-packet mark 0x40000000.
The separate table inet forkop_zapret_bridge hooks output, postrouting and prerouting.
Do not mutate this running service or its table while developing. Validate a migration and rollback first.
