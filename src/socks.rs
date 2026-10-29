use std::{
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
};
use tokio::io::{AsyncRead, AsyncReadExt};

#[derive(Debug, Clone)]
pub enum Target {
    Ip(SocketAddr),
    Domain(String, u16),
}

fn bad() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid SOCKS address")
}
pub async fn read_address<R: AsyncRead + Unpin>(r: &mut R, typ: u8) -> io::Result<Target> {
    let addr = match typ {
        1 => {
            let mut b = [0; 4];
            r.read_exact(&mut b).await?;
            IpAddr::V4(b.into())
        }
        4 => {
            let mut b = [0; 16];
            r.read_exact(&mut b).await?;
            IpAddr::V6(b.into())
        }
        3 => {
            let n = r.read_u8().await? as usize;
            if n == 0 {
                return Err(bad());
            }
            let mut b = vec![0; n];
            r.read_exact(&mut b).await?;
            let name = String::from_utf8(b).map_err(|_| bad())?;
            let port = r.read_u16().await?;
            return Ok(Target::Domain(name, port));
        }
        _ => return Err(bad()),
    };
    Ok(Target::Ip(SocketAddr::new(addr, r.read_u16().await?)))
}
pub fn reply(code: u8, addr: SocketAddr) -> Vec<u8> {
    let mut v = vec![5, code, 0];
    append_address(&mut v, addr);
    v
}
fn append_address(v: &mut Vec<u8>, addr: SocketAddr) {
    match addr.ip() {
        IpAddr::V4(a) => {
            v.push(1);
            v.extend(a.octets());
        }
        IpAddr::V6(a) => {
            v.push(4);
            v.extend(a.octets());
        }
    }
    v.extend(addr.port().to_be_bytes());
}
pub fn udp_header(addr: SocketAddr) -> Vec<u8> {
    let mut v = vec![0, 0, 0];
    append_address(&mut v, addr);
    v
}
pub fn parse_udp(b: &[u8]) -> io::Result<(Target, usize)> {
    if b.len() < 4 || b[..3] != [0, 0, 0] {
        return Err(bad());
    }
    let (target, end) = match b[3] {
        1 if b.len() >= 10 => (
            Target::Ip(SocketAddr::new(
                Ipv4Addr::new(b[4], b[5], b[6], b[7]).into(),
                u16::from_be_bytes([b[8], b[9]]),
            )),
            10,
        ),
        4 if b.len() >= 22 => {
            let ip: [u8; 16] = b[4..20].try_into().map_err(|_| bad())?;
            (
                Target::Ip(SocketAddr::new(
                    Ipv6Addr::from(ip).into(),
                    u16::from_be_bytes([b[20], b[21]]),
                )),
                22,
            )
        }
        3 if b.len() >= 5 => {
            let n = b[4] as usize;
            if n == 0 || b.len() < 7 + n {
                return Err(bad());
            }
            let name = std::str::from_utf8(&b[5..5 + n])
                .map_err(|_| bad())?
                .to_owned();
            (
                Target::Domain(name, u16::from_be_bytes([b[5 + n], b[6 + n]])),
                7 + n,
            )
        }
        _ => return Err(bad()),
    };
    Ok((target, end))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn udp_ipv4_and_fragments() {
        let addr: SocketAddr = "8.8.8.8:53".parse().unwrap();
        let mut p = udp_header(addr);
        p.extend([1, 2, 3]);
        assert!(matches!(parse_udp(&p), Ok((Target::Ip(a),10)) if a==addr));
        p[2] = 1;
        assert!(parse_udp(&p).is_err());
    }
    #[test]
    fn udp_domain_and_truncated() {
        let b = [0, 0, 0, 3, 3, b'f', b'o', b'o', 0, 80, 42];
        assert!(matches!(parse_udp(&b),Ok((Target::Domain(n,80),10)) if n=="foo"));
        assert!(parse_udp(&b[..7]).is_err());
    }
}
