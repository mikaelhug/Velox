//! Tiny DNS responder for the gateway (192.168.127.1:53).
//!
//! Answers Velox's internal names directly (host.docker.internal etc.) and
//! forwards everything else to the macOS system resolvers. The wire format is
//! simple enough that hand-rolling the codec avoids a heavy dependency tree.

use std::net::{Ipv4Addr, UdpSocket};
use std::time::Duration;

/// Resolve a query. Returns the raw DNS response to send back, or None if the
/// query is malformed / forwarding failed.
pub fn handle(query: &[u8], gateway_ip: u32, guest_ip: u32, upstreams: &[Ipv4Addr]) -> Option<Vec<u8>> {
    let (name, qend) = parse_question(query)?;
    let qtype = u16::from_be_bytes([*query.get(qend)?, *query.get(qend + 1)?]);

    // Internal names → answer locally.
    let internal: Option<u32> = match name.as_str() {
        "host.docker.internal" | "gateway.docker.internal" => Some(gateway_ip),
        "vm.docker.internal" => Some(guest_ip),
        _ => None,
    };
    if let Some(ip) = internal {
        let qsection_end = qend + 4; // qtype(2) + qclass(2)
        if query.len() < qsection_end {
            return None;
        }
        return Some(if qtype == 1 {
            build_a_response(query, qsection_end, ip)
        } else {
            build_empty_response(query, qsection_end)
        });
    }

    forward(query, upstreams)
}

/// Parse the QNAME of the first question. Returns (lowercased name, offset of the
/// byte after the name's terminating zero — i.e. the start of QTYPE).
pub fn parse_question(p: &[u8]) -> Option<(String, usize)> {
    if p.len() < 12 {
        return None;
    }
    let mut i = 12usize; // skip the 12-byte header
    let mut name = String::new();
    loop {
        let len = *p.get(i)? as usize;
        i += 1;
        if len == 0 {
            break;
        }
        if len & 0xC0 != 0 {
            return None; // compression pointers aren't valid in a question
        }
        let end = i.checked_add(len)?;
        if end > p.len() {
            return None;
        }
        if !name.is_empty() {
            name.push('.');
        }
        name.push_str(&String::from_utf8_lossy(&p[i..end]));
        i = end;
    }
    Some((name.to_ascii_lowercase(), i))
}

fn response_header(query: &[u8], ancount: u16) -> Vec<u8> {
    let mut r = Vec::with_capacity(query.len() + 16);
    r.extend_from_slice(&query[0..2]); // copy transaction id
    r.extend_from_slice(&[0x81, 0x80]); // QR=1, RD=1, RA=1, rcode=0
    r.extend_from_slice(&[0x00, 0x01]); // qdcount = 1
    r.extend_from_slice(&ancount.to_be_bytes());
    r.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // nscount=0, arcount=0
    r
}

fn build_a_response(query: &[u8], qsection_end: usize, ip: u32) -> Vec<u8> {
    let mut r = response_header(query, 1);
    r.extend_from_slice(&query[12..qsection_end]); // the question
    r.extend_from_slice(&[0xC0, 0x0C]); // name: pointer to offset 12
    r.extend_from_slice(&[0x00, 0x01]); // type A
    r.extend_from_slice(&[0x00, 0x01]); // class IN
    r.extend_from_slice(&[0x00, 0x00, 0x00, 0x1E]); // ttl 30s
    r.extend_from_slice(&[0x00, 0x04]); // rdlength 4
    r.extend_from_slice(&ip.to_be_bytes());
    r
}

fn build_empty_response(query: &[u8], qsection_end: usize) -> Vec<u8> {
    let mut r = response_header(query, 0);
    r.extend_from_slice(&query[12..qsection_end]);
    r
}

/// Forward the query verbatim to each upstream until one answers (short timeout).
/// The upstream's reply already carries the matching transaction id.
fn forward(query: &[u8], upstreams: &[Ipv4Addr]) -> Option<Vec<u8>> {
    for up in upstreams {
        let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else { continue };
        let _ = sock.set_read_timeout(Some(Duration::from_millis(2000)));
        if sock.send_to(query, (*up, 53)).is_err() {
            continue;
        }
        let mut buf = [0u8; 1500];
        if let Ok((n, _)) = sock.recv_from(&mut buf) {
            return Some(buf[..n].to_vec());
        }
    }
    None
}

/// Read the macOS system resolvers from /etc/resolv.conf (kept current by macOS),
/// falling back to a public resolver if none are found.
pub fn system_resolvers() -> Vec<Ipv4Addr> {
    let mut out = Vec::new();
    if let Ok(text) = std::fs::read_to_string("/etc/resolv.conf") {
        for line in text.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("nameserver ") {
                if let Ok(ip) = rest.trim().parse::<Ipv4Addr>() {
                    out.push(ip);
                }
            }
        }
    }
    if out.is_empty() {
        out.push(Ipv4Addr::new(1, 1, 1, 1));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal DNS query for `name` with QTYPE=A.
    fn query_for(name: &str, id: u16) -> Vec<u8> {
        let mut q = Vec::new();
        q.extend_from_slice(&id.to_be_bytes());
        q.extend_from_slice(&[0x01, 0x00]); // flags: RD
        q.extend_from_slice(&[0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // qd=1
        for label in name.split('.') {
            q.push(label.len() as u8);
            q.extend_from_slice(label.as_bytes());
        }
        q.push(0);
        q.extend_from_slice(&[0x00, 0x01]); // qtype A
        q.extend_from_slice(&[0x00, 0x01]); // qclass IN
        q
    }

    #[test]
    fn parses_qname() {
        let q = query_for("host.docker.internal", 0x1234);
        let (name, end) = parse_question(&q).unwrap();
        assert_eq!(name, "host.docker.internal");
        // qtype A immediately after the name terminator
        assert_eq!(u16::from_be_bytes([q[end], q[end + 1]]), 1);
    }

    #[test]
    fn answers_internal_a() {
        let q = query_for("host.docker.internal", 0xBEEF);
        let resp = handle(&q, 0xC0A8_7F01, 0xC0A8_7F02, &[]).unwrap();
        // id echoed, QR set, ancount == 1
        assert_eq!(&resp[0..2], &[0xBE, 0xEF]);
        assert_eq!(resp[2] & 0x80, 0x80);
        assert_eq!(u16::from_be_bytes([resp[6], resp[7]]), 1);
        // last 4 bytes are the A record (gateway 192.168.127.1)
        let n = resp.len();
        assert_eq!(&resp[n - 4..], &[192, 168, 127, 1]);
    }

    #[test]
    fn vm_name_resolves_to_guest() {
        let q = query_for("vm.docker.internal", 1);
        let resp = handle(&q, 0xC0A8_7F01, 0xC0A8_7F02, &[]).unwrap();
        let n = resp.len();
        assert_eq!(&resp[n - 4..], &[192, 168, 127, 2]);
    }
}
