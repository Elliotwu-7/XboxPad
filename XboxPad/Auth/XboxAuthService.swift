import Foundation

enum XboxAuthError: LocalizedError {
    case missingUserToken
    case invalidResponse(String)
    case httpError(Int, String)
    case deviceCodeExpired
    case deviceCodeDenied
    case cancelled
    case missingTransferToken

    var errorDescription: String? {
        switch self {
        case .missingUserToken:
            return "未找到微软登录凭证，请重新登录。"
        case .invalidResponse(let detail):
            return "认证返回数据格式异常：\(detail)"
        case .httpError(let status, let detail):
            return "认证请求失败 (HTTP \(status))：\(detail)"
        case .deviceCodeExpired:
            return "设备登录码已过期，请重新获取。"
        case .deviceCodeDenied:
            return "登录授权已被取消。"
        case .cancelled:
            return "已取消登录。"
        case .missingTransferToken:
            return "获取 Xbox 串流连接授权令牌 (LPT) 失败。"
        }
    }
}

actor XboxAuthService {
    // Public Xbox MSAL Client ID used by official web/device-code flows (same as XStreaming/Greenlight)
    private let clientId = "1f907974-e22b-4810-a9de-d9647380c97e"
    private let scope = "xboxlive.signin openid profile offline_access"
    private let transferScope = "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"

    private let userTokenAccount = "oauth_user_token"
    private let snapshotAccount = "auth_session_snapshot"

    private let session: URLSession
    private var iCloudSyncEnabled: Bool
    private var cachedUserToken: OAuthUserToken?
    private var cachedXblUserToken: XstsTokenData?
    private var cachedGssvToken: XstsTokenData?
    private var cachedSnapshot: AuthSessionSnapshot?
    private var lastCloudAuthError: String?

    func getLastCloudAuthError() -> String? {
        lastCloudAuthError
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        let syncEnabled = AppSettings.load().iCloudKeychainSync
        self.iCloudSyncEnabled = syncEnabled
        self.cachedUserToken = KeychainStore.load(
            OAuthUserToken.self,
            account: userTokenAccount,
            preferSynchronizable: syncEnabled
        )
        self.cachedSnapshot = KeychainStore.load(
            AuthSessionSnapshot.self,
            account: snapshotAccount,
            preferSynchronizable: false
        )
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        iCloudSyncEnabled = enabled
        if cachedUserToken == nil {
            cachedUserToken = KeychainStore.load(
                OAuthUserToken.self,
                account: userTokenAccount,
                preferSynchronizable: enabled
            )
        }
        if let token = cachedUserToken {
            KeychainStore.save(token, account: userTokenAccount, synchronizable: enabled)
        }
    }

    func hasStoredLogin(forceReload: Bool = false) -> Bool {
        if !forceReload, cachedUserToken != nil { return true }
        cachedUserToken = KeychainStore.load(
            OAuthUserToken.self,
            account: userTokenAccount,
            preferSynchronizable: iCloudSyncEnabled
        )
        if forceReload {
            cachedSnapshot = KeychainStore.load(
                AuthSessionSnapshot.self,
                account: snapshotAccount,
                preferSynchronizable: false
            )
        }
        return cachedUserToken != nil
    }

    func logout() {
        cachedUserToken = nil
        cachedXblUserToken = nil
        cachedGssvToken = nil
        cachedSnapshot = nil
        KeychainStore.clearAll()
    }

    // MARK: - Step 1: OAuth2 Device Code Login

    func requestDeviceCode(forceRegionIP: String = "") async throws -> DeviceCodeInfo {
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!
        let form = formEncoded([
            "client_id": clientId,
            "scope": scope,
        ])
        let data = try await sendFormPost(url: url, body: form, forceRegionIP: forceRegionIP)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationUri = json["verification_uri"] as? String else {
            throw XboxAuthError.invalidResponse("missing device_code fields")
        }
        let expiresIn = (json["expires_in"] as? Int) ?? 900
        let interval = max((json["interval"] as? Int) ?? 5, 2)
        let message = (json["message"] as? String) ?? ""
        return DeviceCodeInfo(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            expiresIn: expiresIn,
            interval: interval,
            message: message
        )
    }

    func pollForDeviceCodeToken(
        info: DeviceCodeInfo,
        forceRegionIP: String = ""
    ) async throws -> OAuthUserToken {
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        let deadline = Date().addingTimeInterval(TimeInterval(info.expiresIn))
        var pollInterval = TimeInterval(max(info.interval, 2))

        while Date() < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if !forceRegionIP.isEmpty {
                request.setValue(forceRegionIP, forHTTPHeaderField: "X-Forwarded-For")
            }
            request.httpBody = formEncoded([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientId,
                "device_code": info.deviceCode,
            ])

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            if (200..<300).contains(status),
               let accessToken = json["access_token"] as? String,
               let refreshToken = json["refresh_token"] as? String {
                let expiresIn = (json["expires_in"] as? Int) ?? 3600
                let tokenScope = (json["scope"] as? String) ?? scope
                let userToken = OAuthUserToken(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    scope: tokenScope,
                    expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
                )
                saveUserToken(userToken)
                return userToken
            }

            if let errCode = json["error"] as? String {
                switch errCode {
                case "authorization_pending":
                    break
                case "slow_down":
                    pollInterval += 2
                case "expired_token":
                    throw XboxAuthError.deviceCodeExpired
                case "access_denied":
                    throw XboxAuthError.deviceCodeDenied
                default:
                    let desc = (json["error_description"] as? String) ?? errCode
                    throw XboxAuthError.httpError(status, desc)
                }
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        throw XboxAuthError.deviceCodeExpired
    }

    // MARK: - Step 2: Token Refresh & Streaming Credentials

    func getValidSessionSnapshot(
        forceRefresh: Bool = false,
        forceRegionIP: String = "",
        requireCloud: Bool = false
    ) async throws -> AuthSessionSnapshot {
        if !forceRefresh,
           let snapshot = cachedSnapshot,
           snapshot.xHomeToken.isValid,
           snapshot.webToken.isValid,
           (!requireCloud || (snapshot.xCloudToken?.isValid == true)) {
            return snapshot
        }

        let xblUser = try await authenticateXboxUser(forceRegionIP: forceRegionIP)
        async let webTask = authorizeXSTS(
            xblUserToken: xblUser.token,
            relyingParty: "http://xboxlive.com",
            forceRegionIP: forceRegionIP
        )
        async let gssvTask = authorizeXSTS(
            xblUserToken: xblUser.token,
            relyingParty: "http://gssv.xboxlive.com/",
            forceRegionIP: forceRegionIP
        )

        let (webToken, gssvToken) = try await (webTask, gssvTask)
        cachedGssvToken = gssvToken

        let xHomeToken = try await fetchStreamingToken(
            gssvToken: gssvToken.token,
            offering: "xhome",
            forceRegionIP: forceRegionIP
        )

        let xCloudToken = await fetchCloudTokenWithFallback(
            gssvToken: gssvToken.token,
            preferredRegionIP: forceRegionIP
        )

        let snapshot = AuthSessionSnapshot(
            xHomeToken: xHomeToken,
            xCloudToken: xCloudToken,
            webToken: webToken
        )
        cachedSnapshot = snapshot
        KeychainStore.save(snapshot, account: snapshotAccount)
        return snapshot
    }

    /// Fetches xCloud token (`xgpuweb`, then `xgpuwebf2p` fallback).
    /// When user leaves `preferredRegionIP` on Auto (`""`) in an unsupported market (e.g. CN/HK),
    /// automatically retries with Japan -> Korea -> US `X-Forwarded-For` without affecting `xHome`.
    private func fetchCloudTokenWithFallback(
        gssvToken: String,
        preferredRegionIP: String
    ) async -> StreamingTokenBundle? {
        lastCloudAuthError = nil
        let candidateIPs: [String] = preferredRegionIP.isEmpty
            ? ["", "133.130.100.1", "211.233.10.1", "4.2.2.2"]
            : [preferredRegionIP]

        var lastError: String?
        for offering in ["xgpuweb", "xgpuwebf2p"] {
            for ip in candidateIPs {
                do {
                    let bundle = try await fetchStreamingToken(
                        gssvToken: gssvToken,
                        offering: offering,
                        forceRegionIP: ip
                    )
                    if !bundle.regions.isEmpty || !bundle.gsToken.isEmpty {
                        lastCloudAuthError = nil
                        return bundle
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        lastCloudAuthError = lastError
        return nil
    }

    /// Fetch the MSAL transfer token (LPT) required by Xbox `/v5/sessions/.../connect`
    func fetchConnectTransferToken(forceRegionIP: String = "") async throws -> String {
        _ = try await getOrRefreshUserToken(forceRegionIP: forceRegionIP)
        guard let refreshToken = cachedUserToken?.refreshToken, !refreshToken.isEmpty else {
            throw XboxAuthError.missingUserToken
        }

        let url = URL(string: "https://login.live.com/oauth20_token.srf")!
        let form = formEncoded([
            "client_id": clientId,
            "scope": transferScope,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let data = try await sendFormPost(url: url, body: form, forceRegionIP: forceRegionIP)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lpt = json["access_token"] as? String,
              !lpt.isEmpty else {
            throw XboxAuthError.missingTransferToken
        }
        return lpt
    }

    // MARK: - Internal Token Exchange

    private func saveUserToken(_ token: OAuthUserToken) {
        cachedUserToken = token
        cachedXblUserToken = nil
        cachedGssvToken = nil
        cachedSnapshot = nil
        KeychainStore.save(token, account: userTokenAccount, synchronizable: iCloudSyncEnabled)
    }

    private func getOrRefreshUserToken(forceRegionIP: String) async throws -> String {
        if let token = cachedUserToken, token.isValid {
            return token.accessToken
        }
        return try await refreshUserToken(forceRegionIP: forceRegionIP).accessToken
    }

    private func refreshUserToken(forceRegionIP: String) async throws -> OAuthUserToken {
        guard let refreshToken = cachedUserToken?.refreshToken, !refreshToken.isEmpty else {
            throw XboxAuthError.missingUserToken
        }

        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        let form = formEncoded([
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scope,
        ])
        let data = try await sendFormPost(url: url, body: form, forceRegionIP: forceRegionIP)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw XboxAuthError.invalidResponse("refresh token response missing access_token")
        }
        let nextRefresh = (json["refresh_token"] as? String) ?? refreshToken
        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        let tokenScope = (json["scope"] as? String) ?? scope
        let refreshed = OAuthUserToken(
            accessToken: accessToken,
            refreshToken: nextRefresh,
            scope: tokenScope,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        cachedUserToken = refreshed
        KeychainStore.save(refreshed, account: userTokenAccount, synchronizable: iCloudSyncEnabled)
        return refreshed
    }

    private func authenticateXboxUser(forceRegionIP: String) async throws -> XstsTokenData {
        if let cached = cachedXblUserToken, cached.isValid {
            return cached
        }
        let accessToken = try await getOrRefreshUserToken(forceRegionIP: forceRegionIP)
        let url = URL(string: "https://user.auth.xboxlive.com/user/authenticate")!
        let payload: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "RpsTicket": "d=\(accessToken)",
                "SiteName": "user.auth.xboxlive.com",
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        ]
        let headers = [
            "x-xbl-contract-version": "1",
            "Cache-Control": "no-cache",
            "Origin": "https://www.xbox.com",
            "Referer": "https://www.xbox.com/",
        ]
        let data = try await sendJsonPost(url: url, payload: payload, extraHeaders: headers, forceRegionIP: forceRegionIP)
        let token = try parseXstsToken(data: data)
        cachedXblUserToken = token
        return token
    }

    private func authorizeXSTS(
        xblUserToken: String,
        relyingParty: String,
        forceRegionIP: String
    ) async throws -> XstsTokenData {
        let url = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
        let payload: [String: Any] = [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [xblUserToken],
            ],
            "RelyingParty": relyingParty,
            "TokenType": "JWT",
        ]
        let headers = [
            "x-xbl-contract-version": "1",
            "Cache-Control": "no-cache",
            "Origin": "https://www.xbox.com",
            "Referer": "https://www.xbox.com/",
            "Accept": "*/*",
            "ms-cv": "0",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        ]
        let data = try await sendJsonPost(url: url, payload: payload, extraHeaders: headers, forceRegionIP: forceRegionIP)
        return try parseXstsToken(data: data)
    }

    private func fetchStreamingToken(
        gssvToken: String,
        offering: String,
        forceRegionIP: String
    ) async throws -> StreamingTokenBundle {
        let url = URL(string: "https://\(offering).gssv-play-prod.xboxlive.com/v2/login/user")!
        let payload: [String: Any] = [
            "token": gssvToken,
            "offeringId": offering,
        ]
        let headers = [
            "Cache-Control": "no-store, must-revalidate, no-cache",
            "x-gssv-client": "XboxComBrowser",
        ]
        let data = try await sendJsonPost(url: url, payload: payload, extraHeaders: headers, forceRegionIP: forceRegionIP)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gsToken = json["gsToken"] as? String else {
            throw XboxAuthError.invalidResponse("missing gsToken for \(offering)")
        }

        let market = (json["market"] as? String) ?? "US"
        let duration = (json["durationInSeconds"] as? Int) ?? 14400
        var regions: [StreamingRegion] = []
        if let settings = json["offeringSettings"] as? [String: Any],
           let rawRegions = settings["regions"] as? [[String: Any]] {
            for item in rawRegions {
                guard let name = item["name"] as? String,
                      let baseUri = item["baseUri"] as? String else { continue }
                let isDefault = (item["isDefault"] as? Bool) ?? false
                regions.append(StreamingRegion(name: name, baseUri: baseUri, isDefault: isDefault))
            }
        }

        return StreamingTokenBundle(
            gsToken: gsToken,
            market: market,
            durationInSeconds: duration,
            createdAt: Date(),
            regions: regions,
            offering: offering,
            resolvedRegionIP: forceRegionIP.isEmpty ? nil : forceRegionIP
        )
    }

    // MARK: - HTTP & Parsing Helpers

    private func parseXstsToken(data: Data) throws -> XstsTokenData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["Token"] as? String else {
            throw XboxAuthError.invalidResponse("missing XSTS Token")
        }
        var uhs = ""
        var xid: String?
        if let claims = json["DisplayClaims"] as? [String: Any],
           let xui = claims["xui"] as? [[String: Any]],
           let first = xui.first {
            uhs = (first["uhs"] as? String) ?? ""
            xid = first["xid"] as? String
        }
        var notAfter: Date?
        if let notAfterStr = json["NotAfter"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            notAfter = fmt.date(from: notAfterStr) ?? ISO8601DateFormatter().date(from: notAfterStr)
        }
        return XstsTokenData(token: token, uhs: uhs, xid: xid, notAfter: notAfter)
    }

    private func sendFormPost(url: URL, body: Data, forceRegionIP: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        if !forceRegionIP.isEmpty {
            request.setValue(forceRegionIP, forHTTPHeaderField: "X-Forwarded-For")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validateHttp(response: response, data: data)
        return data
    }

    private func sendJsonPost(
        url: URL,
        payload: [String: Any],
        extraHeaders: [String: String],
        forceRegionIP: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if !forceRegionIP.isEmpty {
            request.setValue(forceRegionIP, forHTTPHeaderField: "X-Forwarded-For")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try validateHttp(response: response, data: data)
        return data
    }

    private func validateHttp(response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw XboxAuthError.httpError(status, String(text.prefix(240)))
        }
    }

    private func formEncoded(_ pairs: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }
}
