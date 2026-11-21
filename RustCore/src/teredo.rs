use std::net::Ipv6Addr;

use crate::protocol::IceCandidate;

const DEFAULT_CANDIDATE_PORT: u16 = 9002;
const XBOX_GAME_PORT: u16 = 3074;

#[derive(Debug, Clone, PartialEq, Eq)]
struct TeredoInfo {
    server4: String,
    client4: String,
    udp_port: u16,
}

/// Parse an RFC 4380 Teredo IPv6 address (prefix 2001:0000::/32).
fn inspect_teredo(addr: Ipv6Addr) -> Option<TeredoInfo> {
    let seg = addr.segments();
    if seg[0] != 0x2001 || seg[1] != 0x0000 {
        return None;
    }

    let server_bytes = [
        (seg[2] >> 8) as u8,
        (seg[2] & 0xff) as u8,
        (seg[3] >> 8) as u8,
        (seg[3] & 0xff) as u8,
    ];
    let udp_port = seg[5] ^ 0xffff;
    let client_hi = seg[6] ^ 0xffff;
    let client_lo = seg[7] ^ 0xffff;
    let client_bytes = [
        (client_hi >> 8) as u8,
        (client_hi & 0xff) as u8,
        (client_lo >> 8) as u8,
        (client_lo & 0xff) as u8,
    ];

    Some(TeredoInfo {
        server4: format!(
            "{}.{}.{}.{}",
            server_bytes[0], server_bytes[1], server_bytes[2], server_bytes[3]
        ),
        client4: format!(
            "{}.{}.{}.{}",
            client_bytes[0], client_bytes[1], client_bytes[2], client_bytes[3]
        ),
        udp_port,
    })
}

/// Expand Teredo IPv6 ICE candidates returned by Xbox xHome into direct IPv4 host candidates
/// to significantly improve LAN / NAT direct connection reliability.
pub fn expand_teredo_candidates(
    exchange_candidates: Vec<IceCandidate>,
    prioritize_ipv6: bool,
) -> Vec<IceCandidate> {
    let mut expanded = Vec::with_capacity(exchange_candidates.len() * 2);

    for (source_index, source) in exchange_candidates.into_iter().enumerate() {
        let tokens: Vec<&str> = source.candidate.split_whitespace().collect();
        let mut generated: Vec<IceCandidate> = Vec::new();
        let mline_index = source.sdp_mline_index.parse::<u32>().unwrap_or(0);

        for (token_idx, token) in tokens.iter().enumerate() {
            let Ok(v6) = token.parse::<Ipv6Addr>() else {
                continue;
            };
            let Some(teredo) = inspect_teredo(v6) else {
                continue;
            };

            let candidate_port = tokens
                .get(token_idx + 1)
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or(DEFAULT_CANDIDATE_PORT);

            let foundation_base = source_index + 2;
            let mut push_host = |ip: &str, port: u16| {
                let foundation = foundation_base + generated.len();
                let priority = 2_122_260_223u32.saturating_sub(generated.len() as u32 * 10);
                let line = format!(
                    "a=candidate:{foundation} 1 UDP {priority} {ip} {port} typ host "
                );
                generated.push(IceCandidate::new(line, source.sdp_mid.clone(), mline_index));
            };

            push_host(&teredo.client4, teredo.udp_port);
            push_host(&teredo.server4, candidate_port);
            push_host(&teredo.client4, candidate_port);
            if candidate_port != XBOX_GAME_PORT {
                push_host(&teredo.server4, XBOX_GAME_PORT);
                push_host(&teredo.client4, XBOX_GAME_PORT);
            }
        }

        expanded.push(source);
        expanded.extend(generated);
    }

    if !prioritize_ipv6 {
        return expanded;
    }

    let (end_candidates, mut regular): (Vec<_>, Vec<_>) = expanded
        .into_iter()
        .partition(|c| c.is_end_of_candidates());

    regular.sort_by_key(|c| {
        let is_v6 = c
            .candidate
            .split_whitespace()
            .nth(4)
            .map(|ip| ip.contains(':'))
            .unwrap_or(false);
        if is_v6 { 0 } else { 1 }
    });
    regular.extend(end_candidates);
    regular
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_teredo_ipv6_and_expands_ipv4_candidates() {
        // 2001:0000:4136:e378:8000:63bf:3fff:fdd2
        // server4 = 65.54.227.120, udp_port = 0x63bf ^ 0xffff = 0x9c40 = 40000
        // client4 = 0x3fff ^ 0xffff = 0xc000 (192.0), 0xfdd2 ^ 0xffff = 0x022d (2.45) -> 192.0.2.45
        let candidate = IceCandidate::new(
            "a=candidate:1 1 UDP 2122260223 2001:0000:4136:e378:8000:63bf:3fff:fdd2 9002 typ host",
            "0",
            0,
        );
        let result = expand_teredo_candidates(vec![candidate], false);
        assert_eq!(result.len(), 6);
        assert!(result[1].candidate.contains("192.0.2.45 40000"));
        assert!(result[2].candidate.contains("65.54.227.120 9002"));
        assert!(result[3].candidate.contains("192.0.2.45 9002"));
        assert!(result[4].candidate.contains("65.54.227.120 3074"));
        assert!(result[5].candidate.contains("192.0.2.45 3074"));
    }

    #[test]
    fn prioritizes_ipv6_when_requested() {
        let v4 = IceCandidate::new(
            "a=candidate:1 1 UDP 100 192.168.1.50 9002 typ host",
            "0",
            0,
        );
        let v6 = IceCandidate::new(
            "a=candidate:2 1 UDP 100 fe80::1 9002 typ host",
            "0",
            0,
        );
        let ordered = expand_teredo_candidates(vec![v4, v6], true);
        assert!(ordered[0].candidate.contains("fe80::1"));
        assert!(ordered[1].candidate.contains("192.168.1.50"));
    }
}
