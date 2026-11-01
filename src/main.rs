mod resolver;
mod socks;
use std::{
    env, io,
    net::{Ipv4Addr, SocketAddr, SocketAddrV4},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    sync::{mpsc, OwnedSemaphorePermit, Semaphore},
};

#[derive(Clone)]
struct Config {
    mark: u32,
    dns_mark: u32,
    resolver: resolver::Resolver,
    udp_pending: Arc<Semaphore>,
    udp_sessions: Arc<Semaphore>,
}

/// Peers closing or resetting a relayed connection is normal; logging every
/// occurrence would flood the small logd ring buffer.
fn is_routine(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::UnexpectedEof
    )
}

fn marked_socket(
    domain: socket2::Domain,
    kind: socket2::Type,
    protocol: socket2::Protocol,
    mark: u32,
) -> io::Result<socket2::Socket> {
    let socket = socket2::Socket::new(domain, kind, Some(protocol))?;
    #[cfg(target_os = "linux")]
    {
        use std::os::fd::AsRawFd;
        let rc = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_MARK,
                (&mark as *const u32).cast(),
                std::mem::size_of::<u32>() as libc::socklen_t,
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = mark;
    }
    socket.set_nonblocking(true)?;
    Ok(socket)
}

async fn connect(addr: SocketAddr, mark: u32) -> io::Result<TcpStream> {
    let socket = marked_socket(
        socket2::Domain::for_address(addr),
        socket2::Type::STREAM,
        socket2::Protocol::TCP,
        mark,
    )?;
    // Bound the lifetime of unacknowledged data or FINs without timing out
    // healthy idle connections. This also releases their paired SOCKS sockets.
    #[cfg(target_os = "linux")]
    socket.set_tcp_user_timeout(Some(Duration::from_secs(30)))?;
    match socket.connect(&addr.into()) {
        Ok(()) => {}
        Err(e)
            if e.kind() == io::ErrorKind::WouldBlock
                || e.raw_os_error() == Some(libc::EINPROGRESS) => {}
        Err(e) => return Err(e),
    }
    let stream = TcpStream::from_std(socket.into())?;
    stream.writable().await?;
    if let Some(err) = stream.take_error()? {
        return Err(err);
    }
    Ok(stream)
}

async fn handshake(client: &mut TcpStream) -> io::Result<Option<(u8, socks::Target)>> {
    let mut hello = [0; 2];
    client.read_exact(&mut hello).await?;
    if hello[0] != 5 || hello[1] == 0 {
        return Err(io::Error::other("invalid SOCKS greeting"));
    }
    let mut methods = vec![0; hello[1] as usize];
    client.read_exact(&mut methods).await?;
    if !methods.contains(&0) {
        client.write_all(&[5, 255]).await?;
        return Ok(None);
    }
    client.write_all(&[5, 0]).await?;
    let mut head = [0; 4];
    client.read_exact(&mut head).await?;
    if head[0] != 5 || head[2] != 0 {
        return Err(io::Error::other("invalid SOCKS request"));
    }
    let target = match socks::read_address(client, head[3]).await {
        Ok(target) => target,
        Err(e) => {
            client
                .write_all(&socks::reply(8, "0.0.0.0:0".parse().unwrap()))
                .await?;
            return Err(e);
        }
    };
    Ok(Some((head[1], target)))
}

async fn serve(mut client: TcpStream, cfg: Arc<Config>) -> io::Result<()> {
    let peer = client.peer_addr()?;
    let target = tokio::time::timeout(Duration::from_secs(10), handshake(&mut client))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "SOCKS handshake timeout"))??;
    let Some((command, target)) = target else {
        return Ok(());
    };
    match command {
        1 => {
            let addr = match cfg.resolver.resolve(&target, cfg.dns_mark).await {
                Ok(addr) => addr,
                Err(e) => {
                    client
                        .write_all(&socks::reply(4, "0.0.0.0:0".parse().unwrap()))
                        .await?;
                    return Err(e);
                }
            };
            match tokio::time::timeout(Duration::from_secs(10), connect(addr, cfg.mark)).await {
                Ok(Ok(mut remote)) => {
                    client
                        .write_all(&socks::reply(0, remote.local_addr()?))
                        .await?;
                    tokio::io::copy_bidirectional(&mut client, &mut remote).await?;
                }
                result => {
                    client
                        .write_all(&socks::reply(5, "0.0.0.0:0".parse().unwrap()))
                        .await?;
                    return Err(match result {
                        Ok(Err(e)) => e,
                        Err(_) => {
                            io::Error::new(io::ErrorKind::TimedOut, "outbound connection timeout")
                        }
                        Ok(Ok(_)) => unreachable!(),
                    });
                }
            }
        }
        3 => {
            let requested = match target {
                socks::Target::Ip(addr) if addr.ip().is_unspecified() || addr.ip() == peer.ip() => {
                    addr
                }
                _ => {
                    client
                        .write_all(&socks::reply(2, "0.0.0.0:0".parse().unwrap()))
                        .await?;
                    return Ok(());
                }
            };
            // Bounds per-association buffers and descriptors independently of TCP clients.
            let Ok(_session) = cfg.udp_sessions.clone().try_acquire_owned() else {
                client
                    .write_all(&socks::reply(1, "0.0.0.0:0".parse().unwrap()))
                    .await?;
                return Ok(());
            };
            let relay = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await?;
            client
                .write_all(&socks::reply(0, relay.local_addr()?))
                .await?;
            udp_relay(client, peer, requested.port(), relay, cfg).await?;
        }
        _ => {
            client
                .write_all(&socks::reply(7, "0.0.0.0:0".parse().unwrap()))
                .await?;
        }
    }
    Ok(())
}

async fn udp_relay(
    mut control: TcpStream,
    peer: SocketAddr,
    requested_port: u16,
    relay: UdpSocket,
    cfg: Arc<Config>,
) -> io::Result<()> {
    let sock = marked_socket(
        socket2::Domain::IPV4,
        socket2::Type::DGRAM,
        socket2::Protocol::UDP,
        cfg.mark,
    )?;
    sock.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0).into())?;
    let remote = UdpSocket::from_std(sock.into())?;
    // Both directions share one buffer: sockets are read only after readiness,
    // so no receive future borrows it across the select.
    let mut buf = vec![0; 65535];
    let mut client_addr = None;
    let mut control_byte = [0u8; 1];
    let mut permitted = std::collections::HashSet::new();
    // Keep slow lookups from blocking other datagrams and closing the control connection.
    let (resolved_tx, mut resolved_rx) = mpsc::channel::<(
        SocketAddr,
        Vec<u8>,
        OwnedSemaphorePermit,
        OwnedSemaphorePermit,
    )>(128);
    let pending = Arc::new(Semaphore::new(128));
    loop {
        tokio::select! {
            r = control.read(&mut control_byte) => { if r? == 0 { return Ok(()); } }
            r = relay.readable() => {
                r?;
                let (n, addr) = match relay.try_recv_from(&mut buf) {
                    Ok(v) => v,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                    Err(e) => return Err(e),
                };
                if addr.ip() != peer.ip() || (requested_port != 0 && addr.port() != requested_port) || client_addr.is_some_and(|v| v != addr) { continue; }
                let Ok((target, offset)) = socks::parse_udp(&buf[..n]) else { continue };
                client_addr = Some(addr);
                if let socks::Target::Ip(dest) = target {
                    if !dest.is_ipv4() || (permitted.len() >= 1024 && !permitted.contains(&dest)) { continue; }
                    permitted.insert(dest);
                    if let Err(e) = remote.send_to(&buf[offset..n], dest).await { eprintln!("SOCKS UDP send: {e}"); }
                    continue;
                }
                let Ok(permit) = pending.clone().try_acquire_owned() else { continue };
                let Ok(global_permit) = cfg.udp_pending.clone().try_acquire_owned() else { continue };
                let payload = buf[offset..n].to_vec();
                let sender = resolved_tx.clone();
                let config = cfg.clone();
                tokio::spawn(async move {
                    if let Ok(dest) = config.resolver.resolve(&target, config.dns_mark).await {
                        if dest.is_ipv4() { let _ = sender.send((dest, payload, permit, global_permit)).await; }
                    }
                });
            }
            Some((dest, payload, _permit, _global_permit)) = resolved_rx.recv() => {
                if permitted.len() >= 1024 && !permitted.contains(&dest) { continue; }
                permitted.insert(dest);
                if let Err(e) = remote.send_to(&payload, dest).await { eprintln!("SOCKS UDP send: {e}"); }
            }
            r = remote.readable() => {
                r?;
                let (n, source) = match remote.try_recv_from(&mut buf) {
                    Ok(v) => v,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                    Err(e) => return Err(e),
                };
                if !permitted.contains(&source) { continue; }
                if let Some(to) = client_addr {
                    let mut packet = socks::udp_header(source);
                    packet.extend_from_slice(&buf[..n]); relay.send_to(&packet, to).await?;
                }
            }
        }
    }
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: zapret-forkop PORT MARK (e.g. 11080 0x08005101)");
        std::process::exit(2);
    }
    let port: u16 = args[1]
        .parse()
        .map_err(|_| io::Error::other("invalid port"))?;
    if port == 0 {
        return Err(io::Error::other("port must not be 0"));
    }
    let mark = u32::from_str_radix(args[2].trim_start_matches("0x"), 16)
        .map_err(|_| io::Error::other("invalid hex mark"))?;
    let cfg = Arc::new(Config {
        mark,
        dns_mark: 0x08000000,
        resolver: resolver::Resolver::default(),
        udp_pending: Arc::new(Semaphore::new(256)),
        udp_sessions: Arc::new(Semaphore::new(256)),
    });
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await?;
    eprintln!("SOCKS listening on 127.0.0.1:{port} mark={mark:#x}");
    let clients = Arc::new(Semaphore::new(512));
    loop {
        // Accept errors such as EMFILE are transient; exiting would let procd
        // give up on the instance after a few respawns.
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                eprintln!("SOCKS accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let Ok(permit) = clients.clone().try_acquire_owned() else {
            continue;
        };
        let c = cfg.clone();
        tokio::spawn(async move {
            let _permit = permit;
            match serve(stream, c).await {
                Err(e) if !is_routine(&e) => eprintln!("SOCKS: {e}"),
                _ => {}
            }
        });
    }
}
