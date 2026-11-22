import Foundation
import Network
import QuartzCore

struct NetworkRegionProbeResult: Identifiable, Sendable {
    let id: String
    let name: String
    let host: String
    let rttMs: Int?
}

struct NetworkDiagnosticReport: Sendable {
    let timestamp: Date
    let xboxAuthRttMs: Int?
    let publicMappedAddress: String?
    let natTypeDescription: String
    let isSymmetricNAT: Bool
    let regionProbes: [NetworkRegionProbeResult]
    let recommendedResolution: StreamResolution
    let recommendedBitrateMbps: Int
    let recommendedLatencyProfile: LatencyProfile
    let recommendationSummary: String
}

/// 1-click Network Doctor diagnosing Xbox API reachability, UDP STUN NAT type (Cone vs Symmetric),
/// and xCloud regional gateway RTTs so users can tune bitrate & latency with real data.
@MainActor
final class NetworkDiagnosticsService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var report: NetworkDiagnosticReport?

    func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        async let xboxPing = Self.probeHTTPS(urlString: "https://xhome.gssv-play-prod.xboxlive.com")
        async let stun1 = Self.probeSTUN(host: "stun.l.google.com", port: 19302)
        async let stun2 = Self.probeSTUN(host: "stun.cloudflare.com", port: 3478)

        let regions: [(id: String, name: String, host: String)] = [
            ("jp", "日本 (东京)", "jpe.core.gssv-play-prod.xboxlive.com"),
            ("kr", "韩国 (首尔)", "krc.core.gssv-play-prod.xboxlive.com"),
            ("usw", "美国西部", "wus2.core.gssv-play-prod.xboxlive.com"),
            ("uk", "英国 / 欧洲", "uks.core.gssv-play-prod.xboxlive.com"),
        ]

        var probes: [NetworkRegionProbeResult] = []
        await withTaskGroup(of: NetworkRegionProbeResult.self) { group in
            for r in regions {
                group.addTask {
                    let ms = await Self.probeTCP(host: r.host, port: 443)
                    return NetworkRegionProbeResult(id: r.id, name: r.name, host: r.host, rttMs: ms)
                }
            }
            for await item in group {
                probes.append(item)
            }
        }
        probes.sort { ($0.rttMs ?? 9999) < ($1.rttMs ?? 9999) }

        let authMs = await xboxPing
        let res1 = await stun1
        let res2 = await stun2

        let mappedAddr = res1?.address ?? res2?.address
        let natDesc: String
        let isSymmetric: Bool
        if let r1 = res1, let r2 = res2 {
            if r1.ip == r2.ip && r1.port == r2.port {
                natDesc = "圆锥型 NAT（打洞友好 · 外网 P2P 直连成功率高）"
                isSymmetric = false
            } else {
                natDesc = "对称型 NAT（端口随目标变化 · 外网串流建议开启中继节点）"
                isSymmetric = true
            }
        } else if res1 != nil || res2 != nil {
            natDesc = "UDP STUN 连通正常（公网映射可用）"
            isSymmetric = false
        } else {
            natDesc = "UDP STUN 受限（当前网络可能屏蔽 UDP，建议使用中继或检查防火墙）"
            isSymmetric = true
        }

        let bestRegionMs = probes.compactMap(\.rttMs).min() ?? 999
        let recRes: StreamResolution
        let recBitrate: Int
        let recLatency: LatencyProfile
        let summary: String

        if !isSymmetric && (authMs ?? 999) <= 120 {
            recRes = .p1080HQ
            recBitrate = 0 // 自动 40Mbps 满血
            recLatency = .low
            summary = "网络状态优秀：内网可满血 1440p HQ + 自动 40Mbps + 80ms 低延迟；外网直连打洞顺畅。"
        } else if isSymmetric && bestRegionMs <= 160 {
            recRes = .p1080
            recBitrate = 18
            recLatency = .balanced
            summary = "检测到对称 NAT：内网仍可满血直连；若外出通过中继串流，建议 1080p + 18Mbps 上限 + 130ms 均衡抗抖动。"
        } else {
            recRes = .p1080
            recBitrate = 12
            recLatency = .stable
            summary = "当前链路延迟偏高或 UDP 受限：建议将码率上限设为 12Mbps 并开启抗抖动优先以保证 60fps 稳定。"
        }

        report = NetworkDiagnosticReport(
            timestamp: Date(),
            xboxAuthRttMs: authMs,
            publicMappedAddress: mappedAddr,
            natTypeDescription: natDesc,
            isSymmetricNAT: isSymmetric,
            regionProbes: probes,
            recommendedResolution: recRes,
            recommendedBitrateMbps: recBitrate,
            recommendedLatencyProfile: recLatency,
            recommendationSummary: summary
        )
    }

    // MARK: - Probes

    private struct STUNMappedResult: Sendable {
        let ip: String
        let port: UInt16
        var address: String { "\(ip):\(port)" }
    }

    private static func probeHTTPS(urlString: String) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        let start = CACurrentMediaTime()
        do {
            _ = try await URLSession.shared.data(for: req)
            return max(Int(((CACurrentMediaTime() - start) * 1000.0).rounded()), 1)
        } catch {
            return nil
        }
    }

    private static func probeTCP(host: String, port: UInt16) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let start = CACurrentMediaTime()
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.elliot.xboxpad.diag.tcp")
            var finished = false
            let finish: (Int?) -> Void = { val in
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: val)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = max(Int(((CACurrentMediaTime() - start) * 1000.0).rounded()), 1)
                    finish(ms)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3.5) {
                finish(nil)
            }
        }
    }

    /// Sends an RFC 5389 STUN Binding Request over UDP and parses XOR-MAPPED-ADDRESS (0x0020)
    /// or MAPPED-ADDRESS (0x0001) to reveal public IP:port.
    private static func probeSTUN(host: String, port: UInt16) async -> STUNMappedResult? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            let queue = DispatchQueue(label: "com.elliot.xboxpad.diag.stun")
            var finished = false
            let finish: (STUNMappedResult?) -> Void = { val in
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: val)
            }

            // Build 20-byte RFC 5389 Binding Request
            var req = Data(count: 20)
            req[0] = 0x00; req[1] = 0x01 // Binding Request
            req[2] = 0x00; req[3] = 0x00 // Length = 0
            req[4] = 0x21; req[5] = 0x12; req[6] = 0xA4; req[7] = 0x42 // Magic Cookie
            for i in 8..<20 { req[i] = UInt8.random(in: 0...255) }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: req, completion: .contentProcessed { err in
                        if err != nil {
                            finish(nil)
                            return
                        }
                        conn.receiveMessage { data, _, _, _ in
                            guard let data else {
                                finish(nil)
                                return
                            }
                            finish(parseSTUNResponse(data))
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3.5) {
                finish(nil)
            }
        }
    }

    private static func parseSTUNResponse(_ data: Data) -> STUNMappedResult? {
        guard data.count >= 20 else { return nil }
        // Check Binding Success Response (0x0101)
        guard data[0] == 0x01, data[1] == 0x01 else { return nil }
        let magic: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        var offset = 20
        while offset + 4 <= data.count {
            let attrType = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            let attrLen = Int((UInt16(data[offset + 2]) << 8) | UInt16(data[offset + 3]))
            offset += 4
            guard offset + attrLen <= data.count else { break }

            if (attrType == 0x0020 || attrType == 0x0001), attrLen >= 8 {
                let family = data[offset + 1]
                if family == 0x01 { // IPv4
                    var pHi = data[offset + 2]
                    var pLo = data[offset + 3]
                    var ipBytes = [data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7]]
                    if attrType == 0x0020 {
                        pHi ^= magic[0]
                        pLo ^= magic[1]
                        for i in 0..<4 { ipBytes[i] ^= magic[i] }
                    }
                    let port = (UInt16(pHi) << 8) | UInt16(pLo)
                    let ip = ipBytes.map(String.init).joined(separator: ".")
                    return STUNMappedResult(ip: ip, port: port)
                }
            }
            let padded = (attrLen + 3) & ~3
            offset += padded
        }
        return nil
    }
}
