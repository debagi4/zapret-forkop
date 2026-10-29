use crate::{connect, socks::Target};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{Arc, Weak},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, Semaphore};
use tokio::time::Instant;

#[derive(Clone)]
pub struct Resolver {
    cache: Arc<Mutex<HashMap<String, (Ipv4Addr, Instant)>>>,
    in_flight: Arc<Semaphore>,
    lookups: Arc<Mutex<HashMap<String, Weak<Mutex<()>>>>>,
}

impl Default for Resolver {
    fn default() -> Self {
        Self {
            cache: Arc::new(Mutex::new(HashMap::new())),
            in_flight: Arc::new(Semaphore::new(32)),
            lookups: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid DNS response")
}
fn query(name: &str) -> io::Result<Vec<u8>> {
    let mut b = vec![0x5a, 0x50, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    let name = name.trim_end_matches('.');
    if name.is_empty() || name.len() > 253 {
        return Err(invalid());
    }
    for part in name.split('.') {
        if part.is_empty() || part.len() > 63 || !part.is_ascii() {
            return Err(invalid());
        }
        b.push(part.len() as u8);
        b.extend(part.as_bytes());
    }
    b.extend([0, 0, 1, 0, 1]);
    Ok(b)
}
fn skip_name(b: &[u8], mut p: usize) -> io::Result<usize> {
    loop {
        let n = *b.get(p).ok_or_else(invalid)?;
        p += 1;
        if n == 0 {
            return Ok(p);
        }
        if n & 0xc0 == 0xc0 {
            let second = *b.get(p).ok_or_else(invalid)?;
            let pointer = (usize::from(n & 0x3f) << 8) | usize::from(second);
            // A compression pointer must refer to an earlier DNS name.
            if pointer >= p - 1 {
                return Err(invalid());
            }
            return Ok(p + 1);
        }
        if n & 0xc0 != 0 || n > 63 || p + n as usize > b.len() {
            return Err(invalid());
        }
        p += n as usize;
    }
}
fn answer(b: &[u8]) -> io::Result<(Ipv4Addr, u32)> {
    if b.len() < 12
        || b[0..2] != [0x5a, 0x50]
        || b[2] & 0x80 == 0
        || b[2] & 0x7a != 0
        || b[3] & 15 != 0
    {
        return Err(invalid());
    }
    let q = u16::from_be_bytes([b[4], b[5]]);
    if q != 1 {
        return Err(invalid());
    }
    let a = u16::from_be_bytes([b[6], b[7]]);
    let mut p = 12;
    for _ in 0..q {
        p = skip_name(b, p)?;
        p = p.checked_add(4).ok_or_else(invalid)?;
        if p > b.len() || b[p - 4..p] != [0, 1, 0, 1] {
            return Err(invalid());
        }
    }
    let mut min_ttl = 300u32;
    for _ in 0..a {
        p = skip_name(b, p)?;
        if p + 10 > b.len() {
            return Err(invalid());
        }
        let typ = u16::from_be_bytes([b[p], b[p + 1]]);
        let class = u16::from_be_bytes([b[p + 2], b[p + 3]]);
        let n = u16::from_be_bytes([b[p + 8], b[p + 9]]) as usize;
        p += 10;
        if p + n > b.len() {
            return Err(invalid());
        }
        let ttl = u32::from_be_bytes(b[p - 6..p - 2].try_into().map_err(|_| invalid())?);
        if class == 1 && typ == 5 {
            min_ttl = min_ttl.min(ttl);
        }
        if typ == 1 && class == 1 && n == 4 {
            return Ok((
                Ipv4Addr::new(b[p], b[p + 1], b[p + 2], b[p + 3]),
                min_ttl.min(ttl),
            ));
        }
        p += n;
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "DNS has no IPv4 answer",
    ))
}
async fn doh(name: &str, mark: u32) -> io::Result<(Ipv4Addr, u32)> {
    let body = query(name)?;
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let cfg = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let connector = tokio_rustls::TlsConnector::from(Arc::new(cfg));
    let tcp = connect("8.8.8.8:443".parse().unwrap(), mark).await?;
    let server = rustls::pki_types::ServerName::try_from("dns.google")
        .unwrap()
        .to_owned();
    let mut tls = connector.connect(server, tcp).await?;
    let header=format!("POST /dns-query HTTP/1.1\r\nHost: dns.google\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len());
    tls.write_all(header.as_bytes()).await?;
    tls.write_all(&body).await?;
    let mut data = Vec::new();
    match tls.take(65536).read_to_end(&mut data).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {}
        Err(e) => return Err(e),
    }
    let pos = data
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(invalid)?;
    let head = std::str::from_utf8(&data[..pos]).map_err(|_| invalid())?;
    if !head.starts_with("HTTP/1.1 200 ")
        || head
            .to_ascii_lowercase()
            .contains("transfer-encoding: chunked")
    {
        return Err(invalid());
    }
    let content_length = head
        .lines()
        .find_map(|line| {
            line.split_once(':')
                .filter(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        })
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .ok_or_else(invalid)?;
    let body = &data[pos + 4..];
    if body.len() != content_length {
        return Err(invalid());
    }
    answer(body)
}
impl Resolver {
    async fn lookup_cached(&self, name: &str) -> Option<Ipv4Addr> {
        let mut cache = self.cache.lock().await;
        if let Some(&(address, expiry)) = cache.get(name) {
            if expiry > Instant::now() {
                return Some(address);
            }
            cache.remove(name);
        }
        None
    }

    pub async fn resolve(&self, target: &Target, mark: u32) -> io::Result<SocketAddr> {
        match target {
            Target::Ip(a) => Ok(*a),
            Target::Domain(name, port) => {
                if let Ok(ip) = name.parse::<IpAddr>() {
                    return Ok(SocketAddr::new(ip, *port));
                }
                let name = name.to_ascii_lowercase();
                if let Some(ip) = self.lookup_cached(&name).await {
                    return Ok(SocketAddr::new(ip.into(), *port));
                }
                // A per-name lock combines a burst of datagrams into one DoH query.
                // Weak references prevent an unbounded map of idle names.
                let gate = {
                    let mut gates = self.lookups.lock().await;
                    if gates.len() >= 1024 {
                        gates.retain(|_, value| value.strong_count() != 0);
                    }
                    if let Some(gate) = gates.get(&name).and_then(Weak::upgrade) {
                        gate
                    } else {
                        let gate = Arc::new(Mutex::new(()));
                        if gates.len() < 1024 {
                            gates.insert(name.clone(), Arc::downgrade(&gate));
                        }
                        gate
                    }
                };
                let lookup = async {
                    let _gate = gate.lock().await;
                    if let Some(ip) = self.lookup_cached(&name).await {
                        return Ok::<Ipv4Addr, io::Error>(ip);
                    }
                    let _permit = self
                        .in_flight
                        .acquire()
                        .await
                        .map_err(|_| io::Error::other("DNS service stopped"))?;
                    let (ip, ttl) = doh(&name, mark).await?;
                    if ttl > 0 {
                        let mut cache = self.cache.lock().await;
                        if cache.len() >= 1024 {
                            let now = Instant::now();
                            cache.retain(|_, (_, expiry)| *expiry > now);
                            if cache.len() >= 1024 {
                                cache.clear();
                            }
                        }
                        cache.insert(name, (ip, Instant::now() + Duration::from_secs(ttl.into())));
                    }
                    Ok(ip)
                };
                let ip = tokio::time::timeout(Duration::from_secs(10), lookup)
                    .await
                    .map_err(|_| {
                        io::Error::new(io::ErrorKind::TimedOut, "DNS over HTTPS timeout")
                    })??;
                Ok(SocketAddr::new(ip.into(), *port))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_bad_names() {
        assert!(query("a..b").is_err());
        assert!(query("").is_err());
    }
    #[test]
    fn parses_compressed_answer() {
        let mut b = query("example.com").unwrap();
        b[2] = 0x81;
        b[3] = 0x80;
        b[7] = 1;
        b.extend([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]);
        assert_eq!(answer(&b).unwrap(), (Ipv4Addr::new(1, 2, 3, 4), 60));
        assert!(answer(&b[..b.len() - 1]).is_err());
        let mut truncated = b.clone();
        truncated[2] |= 2;
        assert!(answer(&truncated).is_err());
        let mut wrong_type = b.clone();
        let qtype = query("example.com").unwrap().len() - 4;
        wrong_type[qtype + 1] = 28;
        assert!(answer(&wrong_type).is_err());
        let mut bad_pointer = b;
        let n = bad_pointer.len();
        bad_pointer[n - 16] = 0xff;
        bad_pointer[n - 15] = 0xff;
        assert!(answer(&bad_pointer).is_err());
    }
    #[test]
    fn caps_and_preserves_answer_ttl() {
        let mut b = query("example.com").unwrap();
        b[2] = 0x81;
        b[3] = 0x80;
        b[7] = 1;
        b.extend([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0xff, 0xff, 0, 4, 1, 2, 3, 4]);
        assert_eq!(answer(&b).unwrap().1, 300);
        let n = b.len();
        b[n - 10..n - 6].fill(0);
        assert_eq!(answer(&b).unwrap().1, 0);
    }
}
