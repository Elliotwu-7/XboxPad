import Foundation

enum XboxHomeAPI {
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

        return results.compactMap { item in
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
