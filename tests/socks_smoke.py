#!/usr/bin/env python3
"""Local TCP and UDP SOCKS5 end-to-end smoke test; requires target/debug/zapret-forkop."""
import os
import socket
import struct
import subprocess
import threading
import time

def recv_exact(s, count):
    data = b""
    while len(data) < count:
        chunk = s.recv(count - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        data += chunk
    return data

def handshake(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    s.sendall(b"\x05\x01\x00")
    assert recv_exact(s, 2) == b"\x05\x00"
    return s

def bound_socket(kind):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    s.settimeout(3)
    return s

tcp_server = bound_socket(socket.SOCK_STREAM)
tcp_server.listen()
udp_server = bound_socket(socket.SOCK_DGRAM)
proxy_port_socket = bound_socket(socket.SOCK_STREAM)
proxy_port = proxy_port_socket.getsockname()[1]
proxy_port_socket.close()
process = subprocess.Popen([os.environ.get("ZAPRET_FORKOP_BINARY", "target/debug/zapret-forkop"), str(proxy_port), "08005101"], stderr=subprocess.PIPE)

def tcp_echo():
    conn, _ = tcp_server.accept()
    with conn:
        conn.sendall(conn.recv(1024))

def udp_echo():
    data, addr = udp_server.recvfrom(1024)
    udp_server.sendto(data, addr)

try:
    for i in range(40):
        try:
            c = handshake(proxy_port)
            break
        except OSError:
            time.sleep(0.05)
    else:
        raise RuntimeError("proxy did not start")
    threading.Thread(target=tcp_echo, daemon=True).start()
    port = tcp_server.getsockname()[1]
    c.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", port))
    assert recv_exact(c, 2) == b"\x05\x00"
    recv_exact(c, 8)
    c.sendall(b"hello tcp")
    assert recv_exact(c, 9) == b"hello tcp"
    c.close()

    threading.Thread(target=udp_echo, daemon=True).start()
    udp = bound_socket(socket.SOCK_DGRAM)
    udp_port = udp.getsockname()[1]
    ctrl = handshake(proxy_port)
    ctrl.sendall(b"\x05\x03\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", udp_port))
    reply = recv_exact(ctrl, 10)
    assert reply[:4] == b"\x05\x00\x00\x01"
    relay = (socket.inet_ntoa(reply[4:8]), struct.unpack("!H", reply[8:10])[0])
    port = udp_server.getsockname()[1]
    header = b"\x00\x00\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", port)
    attacker = bound_socket(socket.SOCK_DGRAM)
    attacker.sendto(header + b"spoofed udp", relay)
    attacker.close()
    udp.sendto(header + b"hello udp", relay)
    packet, _ = udp.recvfrom(1024)
    assert packet == header + b"hello udp", packet
    udp.close()
    ctrl.close()
    unsupported = handshake(proxy_port)
    unsupported.sendall(b"\x05\x02\x00\x01\x7f\x00\x00\x01\x00\x50")
    assert recv_exact(unsupported, 10)[:2] == b"\x05\x07"
    unsupported.close()
    print("SOCKS TCP CONNECT, UDP ASSOCIATE, source restriction, and unsupported command passed")
finally:
    process.terminate()
    process.wait(timeout=3)
    tcp_server.close()
    udp_server.close()
