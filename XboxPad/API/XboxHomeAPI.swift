import Darwin
import Foundation
import os

enum XboxHomeAPI {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "home-api")
    private static let deviceInfoHeader: String = {
        let obj: [String: Any] = [
            "appInfo": [
                "env": [
                    "clientAppId": "www.xbox.com",
                    "clientAppType": "browser",
                    "clientAppVersion": "26.1.97",
                    "clientSdkVersion": "10.3.7",
                    "httpEnvironment": "prod",
                    "sdkInstallId": "",
                ],
            ],
            "dev": [
                "hw": [
                    "make": "Microsoft",
                    "model": "unknown",
                    "sdktype": "web",
                ],
                "os": [
                    "name": "windows",
                    "ver": "22631.2715",
                    "platform": "desktop",
                ],
                "displayInfo": [
                    "dimensions": [
                        "widthInPixels": 1920,
                        "heightInPixels": 1080,
                    ],
                    "pixelDensity": [
                        "dpiX": 1,
                        "dpiY": 1,
                    ],
                ],
                "browser": [
                    "browserName": "chrome",
                    "browserVersion": "130.0",
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }()

    static func fetchConsoles(baseUri: String, gsToken: String) async throws -> [XboxConsole] {
        let trimmed = baseUri.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/v6/servers/home?mr=50") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceInfoHeader, forHTTPHeaderField: "X-MS-Device-Info")
        request.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw XboxAuthError.httpError(status, String(text.prefix(200)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        let consoles: [XboxConsole] = results.compactMap { item in
            guard let serverId = item["serverId"] as? String, !serverId.isEmpty else {
                return nil
            }
            let deviceName = (item["deviceName"] as? String) ?? "Xbox"
            let consoleType = (item["consoleType"] as? String) ?? ""
            let powerState = (item["powerState"] as? String) ?? "Unknown"
            let outOfHome = item["outOfHomeWarning"] as? Bool
            return XboxConsole(
                serverId: serverId,
                deviceName: deviceName,
                consoleType: consoleType,
                powerState: powerState,
                outOfHomeWarning: outOfHome
            )
        }
        for c in consoles {
            logger.info("console discovered name=\(c.deviceName, privacy: .public) type=\(c.consoleType, privacy: .public) powerState=\(c.powerState, privacy: .public)")
        }
        return consoles
    }

    /// Sends native Xbox SmartGlass Power-On (`0xDD02`) UDP packets on port 5050 over the local LAN
    /// (both `255.255.255.255` and every active IPv4 subnet broadcast such as `192.168.x.255`).
    /// Works even when Microsoft's cloud WNS push service fails (`ErrorCallingWNS / WaitingForServerToRegister`).
    static func sendLocalSmartGlassWakeUp(liveId: String) {
        let cleaned = liveId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleaned.isEmpty, let idBytes = cleaned.data(using: .ascii), idBytes.count <= 64 else {
            return
        }

        // Xbox SmartGlass Power-On packet format (UDP 5050):
        // Payload: 0x00 + uint8(len) + ASCII(LiveID) + 0x00
        // Header:  0xDD 0x02 + uint16_be(payloadLen) + 0x00 0x00
        var payload = Data()
        payload.append(0x00)
        payload.append(UInt8(idBytes.count))
        payload.append(idBytes)
        payload.append(0x00)

        let payloadLen = UInt16(payload.count)
        var packet = Data()
        packet.append(0xDD)
        packet.append(0x02)
        packet.append(UInt8((payloadLen >> 8) & 0xFF))
        packet.append(UInt8(payloadLen & 0xFF))
        packet.append(0x00)
        packet.append(0x00)
        packet.append(payload)

        DispatchQueue.global(qos: .userInitiated).async {
            let targets = activeBroadcastAddresses()
            let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else {
                logger.error("local SmartGlass wake failed: socket() error")
                return
            }
            defer { Darwin.close(sock) }

            var broadcastEnable: Int32 = 1
            _ = Darwin.setsockopt(
                sock,
                SOL_SOCKET,
                SO_BROADCAST,
                &broadcastEnable,
                socklen_t(MemoryLayout<Int32>.size)
            )

            logger.info(
                "local SmartGlass UDP 5050 wake burst targets=\(targets.joined(separator: ","), privacy: .public) liveIdLen=\(idBytes.count, privacy: .public)"
            )

            for attempt in 0..<5 {
                for ipStr in targets {
                    var addr = sockaddr_in()
                    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = UInt16(5050).bigEndian
                    if Darwin.inet_pton(AF_INET, ipStr, &addr.sin_addr) == 1 {
                        packet.withUnsafeBytes { rawBuf in
                            guard let base = rawBuf.baseAddress else { return }
                            withUnsafePointer(to: &addr) { addrPtr in
                                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                    _ = Darwin.sendto(
                                        sock,
                                        base,
                                        packet.count,
                                        0,
                                        sa,
                                        socklen_t(MemoryLayout<sockaddr_in>.size)
                                    )
                                }
                            }
                        }
                    }
                }
                if attempt < 4 {
                    Thread.sleep(forTimeInterval: 0.18)
                }
            }
        }
    }

    private static func activeBroadcastAddresses() -> [String] {
        var result: [String] = ["255.255.255.255"]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return result
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let hasBroadcast = (flags & IFF_BROADCAST) != 0
            if isUp && !isLoopback && hasBroadcast,
               let dst = current.pointee.ifa_dstaddr,
               dst.pointee.sa_family == sa_family_t(AF_INET) {
                var sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if !ip.isEmpty && !result.contains(ip) {
                        result.append(ip)
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }

    static func sendPowerCommand(
        consoleId: String,
        wakeUp: Bool,
        webToken: XstsTokenData
    ) async throws {
        guard let url = URL(string: "https://xccs.xboxlive.com/commands") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(webToken.xblAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("RemoteManagement", forHTTPHeaderField: "skillplatform")
        request.setValue("4", forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("XboxApp", forHTTPHeaderField: "x-xbl-client-name")
        request.setValue("UWA", forHTTPHeaderField: "x-xbl-client-type")
        request.setValue("39.39.22001.0", forHTTPHeaderField: "x-xbl-client-version")

        let payload: [String: Any] = [
            "destination": "Xbox",
            "type": "Power",
            "command": wakeUp ? "WakeUp" : "TurnOff",
            "sessionId": UUID().uuidString,
            "sourceId": "com.microsoft.smartglass",
            "parameters": [] as [Any],
            "linkedXboxId": consoleId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw XboxAuthError.httpError(status, String(text.prefix(180)))
        }
    }

    static func fetchGamertag(webToken: XstsTokenData) async -> String? {
        guard let xid = webToken.xid, !xid.isEmpty,
              let url = URL(string: "https://profile.xboxlive.com/users/xuid(\(xid))/profile/settings?settings=Gamertag") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(webToken.xblAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "x-xbl-contract-version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let users = json["profileUsers"] as? [[String: Any]],
              let settings = users.first?["settings"] as? [[String: Any]] else {
            return nil
        }
        return settings.first(where: { ($0["id"] as? String) == "Gamertag" })?["value"] as? String
    }
}
