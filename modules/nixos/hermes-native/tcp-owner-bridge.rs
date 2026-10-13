// Per-connection bridge from a root-held loopback socket to a backend TCP
// listener the OWNER runs. systemd hands the accepted connection over as
// fd 0/1 (Accept=yes, StandardInput=socket). This process runs as the
// owner. argv[1] is a port base; the backend port is base + euid.
//
// The threat: the backend port belongs to whoever binds it first. When the
// owner's daemon is down, any other local user may bind it and receive the
// owner's traffic (the desktop token, or forged inbound chat). netfilter
// can gate connect(2) by uid but never bind(2). So the bridge connects,
// then reads /proc/net/tcp and checks that the socket which ACCEPTED this
// connection belongs to the owner's uid. Only then does it forward a
// single byte. TCP loopback has no SO_PEERCRED; the procfs table is the
// kernel's own record of the peer socket's owner, and the check happens on
// the established connection, so there is no window between check and use.

use std::io;
use std::net::{Ipv4Addr, Shutdown, SocketAddrV4, TcpStream};
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use std::process::exit;

extern "C" {
    fn geteuid() -> u32;
}

/// uid of the ESTABLISHED socket whose local end is `local` and whose
/// remote end is `remote`, from /proc/net/tcp. None when absent.
fn peer_uid(local: SocketAddrV4, remote: SocketAddrV4) -> Option<u32> {
    let table = std::fs::read_to_string("/proc/net/tcp").ok()?;
    let want_local = hex_addr(local);
    let want_remote = hex_addr(remote);
    for line in table.lines().skip(1) {
        let f: Vec<&str> = line.split_whitespace().collect();
        // sl local rem st tx:rx tr:when retrnsmt uid timeout inode ...
        if f.len() < 8 {
            continue;
        }
        if f[1] == want_local && f[2] == want_remote && f[3] == "01" {
            return f[7].parse().ok();
        }
    }
    None
}

/// procfs renders IPv4 as little-endian hex octets and the port as
/// big-endian hex: 127.0.0.1:9118 is 0100007F:239E.
fn hex_addr(a: SocketAddrV4) -> String {
    let o = a.ip().octets();
    format!(
        "{:02X}{:02X}{:02X}{:02X}:{:04X}",
        o[3], o[2], o[1], o[0],
        a.port()
    )
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: hermes-tcp-owner-bridge <port-base>");
        exit(2);
    }
    let base: u32 = match args[1].parse() {
        Ok(b) => b,
        Err(_) => {
            eprintln!("bad port base: {}", args[1]);
            exit(2);
        }
    };
    // SAFETY: geteuid never fails.
    let uid = unsafe { geteuid() };
    let port = base + uid;
    if port > u16::MAX as u32 {
        eprintln!("uid {} puts the backend port past 65535", uid);
        exit(2);
    }
    let backend = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port as u16);

    let target = match TcpStream::connect(backend) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("backend {} is down: {}", backend, e);
            exit(1);
        }
    };
    let ours = match target.local_addr() {
        Ok(std::net::SocketAddr::V4(a)) => a,
        _ => {
            eprintln!("backend connection is not IPv4");
            exit(1);
        }
    };
    match peer_uid(backend, ours) {
        Some(owner) if owner == uid => {}
        Some(owner) => {
            eprintln!(
                "refusing: backend {} is owned by uid {}, expected {}",
                backend, owner, uid
            );
            exit(1);
        }
        None => {
            eprintln!("refusing: backend {} not found in /proc/net/tcp", backend);
            exit(1);
        }
    }

    // SAFETY: fd 0 is the accepted SOCK_STREAM connection. StandardInput=
    // socket makes fd 1 the same socket. We take ownership of fd 0 once,
    // here, and never touch fd 0/1 again. UnixStream serves purely for
    // Read/Write/shutdown, which are family-agnostic on a stream socket.
    let client = unsafe { UnixStream::from_raw_fd(0) };

    let (mut c_r, mut c_w) = match client.try_clone() {
        Ok(c) => (client, c),
        Err(e) => {
            eprintln!("dup client: {}", e);
            exit(1);
        }
    };
    let (mut t_r, mut t_w) = match target.try_clone() {
        Ok(t) => (target, t),
        Err(e) => {
            eprintln!("dup backend: {}", e);
            exit(1);
        }
    };

    let client_to_backend = std::thread::spawn(move || {
        let _ = io::copy(&mut c_r, &mut t_w);
        let _ = t_w.shutdown(Shutdown::Write);
    });
    let _ = io::copy(&mut t_r, &mut c_w);
    let _ = c_w.shutdown(Shutdown::Write);
    let _ = client_to_backend.join();
}
