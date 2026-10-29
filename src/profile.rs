//! Deterministic per-profile allocations. Runtime integration is not implemented yet.
#[derive(Debug, PartialEq, Eq)]
pub struct Allocation {
    pub port: u16,
    pub queue: u16,
    pub mark: u32,
    pub conntrack_mark: u16,
}

pub fn allocation(slot: u8) -> Option<Allocation> {
    if slot == 0 || slot == 255 {
        return None;
    }
    Some(Allocation {
        port: 11079 + u16::from(slot),
        queue: 4399 + u16::from(slot),
        mark: 0x0800_5100 | u32::from(slot),
        conntrack_mark: 0x5100 | u16::from(slot),
    })
}

/// Reserved args are inserted by the manager; user values must not override them.
pub fn strategy_is_valid(strategy: &str) -> bool {
    !strategy.trim().is_empty()
        && !strategy.split_whitespace().any(|arg| {
            ["--qnum", "--dpi-desync-fwmark", "--dry-run"]
                .iter()
                .any(|opt| arg == *opt || arg.strip_prefix(opt).is_some_and(|s| s.starts_with('=')))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_existing_ports_and_marks() {
        assert_eq!(
            allocation(1),
            Some(Allocation {
                port: 11080,
                queue: 4400,
                mark: 0x0800_5101,
                conntrack_mark: 0x5101
            })
        );
        assert_eq!(allocation(2).unwrap().port, 11081);
        assert!(allocation(0).is_none());
        assert!(allocation(255).is_none());
    }

    #[test]
    fn cannot_override_manager_owned_options() {
        assert!(strategy_is_valid("--filter-tcp=443 --dpi-desync=fake"));
        assert!(!strategy_is_valid("--qnum=4401 --filter-tcp=443"));
        assert!(!strategy_is_valid(
            "--filter-tcp=443 --dpi-desync-fwmark 42"
        ));
        assert!(!strategy_is_valid(""));
    }
}
