import CryptoKit
import Foundation
import Network
import os

struct ExportableAuthPayload: Codable, Sendable {
    let userToken: OAuthUserToken
    let gamertag: String?
    let customIceUrl: String?
    let customIceUser: String?
    let customIcePass: String?
}

struct NearbySyncPeer: Identifiable, Hashable, Sendable {
    let id: String
    let deviceName: String
    let gamertag: String
    let endpoint: NWEndpoint

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: NearbySyncPeer, rhs: NearbySyncPeer) -> Bool {
        lhs.id == rhs.id && lhs.deviceName == rhs.deviceName && lhs.gamertag == rhs.gamertag
    }
}

struct IncomingSyncRequest: Identifiable {
    let id = UUID()
    let requesterDeviceName: String
    let verificationCode: String
    let approve: () -> Void
    let deny: () -> Void
}

/// Zero-entitlement cross-device login sync across iPad, iPhone, and macOS:
/// 1. Bonjour LAN discovery (`_xboxpad-sync._tcp`) with ephemeral ECDH (P256) + HKDF-SHA256 + AES-GCM
///    end-to-end encryption and explicit 6-digit confirmation on the logged-in device.
/// 2. Apple Universal Clipboard export/import (`xboxpad-sync:v1:<base64>`) when devices are on different networks.
@MainActor
final class AuthSyncService: ObservableObject {
    static let bonjourServiceType = "_xboxpad-sync._tcp"
    static let clipboardPrefix = "xboxpad-sync:v1:"
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "authsync")

    @Published private(set) var isAdvertising = false
    @Published private(set) var isBrowsing = false
    @Published private(set) var discoveredPeers: [NearbySyncPeer] = []
    @Published var incomingRequest: IncomingSyncRequest?
    @Published var activeVerificationCode: String?
    @Published var activePeerName: String?

    private let netQueue = DispatchQueue(label: "com.elliot.xboxpad.authsync.net", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var payloadProvider: (() async -> ExportableAuthPayload?)?

    deinit {
        listener?.cancel()
        browser?.cancel()
    }

    // MARK: - Universal Clipboard Codec

    static func encodeTransferString(_ payload: ExportableAuthPayload) -> String? {
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        return clipboardPrefix + json.base64EncodedString()
    }

    static func decodeTransferString(_ raw: String) -> ExportableAuthPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(clipboardPrefix) else { return nil }
        let b64 = String(trimmed.dropFirst(clipboardPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(ExportableAuthPayload.self, from: data)
    }

    // MARK: - Advertiser (Logged-In Device)

    func startAdvertising(
        deviceName: String,
        gamertag: String,
        payloadProvider: @escaping () async -> ExportableAuthPayload?
    ) {
        stopAdvertising()
        self.payloadProvider = payloadProvider

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let newListener = try NWListener(using: params)

            let cleanName = String(deviceName.prefix(40))
            let cleanGT = String(gamertag.prefix(32))
            var txt = NWTXTRecord()
            txt["name"] = cleanName
            txt["gt"] = cleanGT
            let serviceName = "\(cleanName)-\(UUID().uuidString.prefix(4))"
            newListener.service = NWListener.Service(
                name: serviceName,
                type: Self.bonjourServiceType,
                txtRecord: txt
            )

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isAdvertising = true
                        Self.logger.info("auth sync advertising ready")
                    case .failed(let err):
                        self.isAdvertising = false
                        Self.logger.error("auth sync listener failed: \(err.localizedDescription, privacy: .public)")
                    case .cancelled:
                        self.isAdvertising = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] conn in
                self?.handleIncomingConnection(conn)
            }

            newListener.start(queue: netQueue)
            self.listener = newListener
        } catch {
            Self.logger.error("auth sync listener creation failed: \(error.localizedDescription, privacy: .public)")
            isAdvertising = false
        }
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
        incomingRequest = nil
        payloadProvider = nil
    }

    private nonisolated func handleIncomingConnection(_ conn: NWConnection) {
        conn.start(queue: netQueue)
        receiveJSONPacket(on: conn) { [weak self] result in
            guard let self else {
                conn.cancel()
                return
            }
            switch result {
            case .failure:
                conn.cancel()
            case .success(let data):
                guard let req = try? JSONDecoder().decode(WireHello.self, from: data),
                      req.type == "hello",
                      let peerPubData = Data(base64Encoded: req.pubKey),
                      let peerPubKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: peerPubData) else {
                    conn.cancel()
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else {
                        conn.cancel()
                        return
                    }
                    // Reject if another confirmation is already pending
                    if self.incomingRequest != nil {
                        self.sendWirePacket(WireResponse(type: "deny", pubKey: nil, box: nil), on: conn)
                        return
                    }

                    let code = req.code
                    let requesterName = req.deviceName.isEmpty ? "附近的 Apple 设备" : req.deviceName

                    self.incomingRequest = IncomingSyncRequest(
                        requesterDeviceName: requesterName,
                        verificationCode: code,
                        approve: { [weak self] in
                            guard let self else {
                                conn.cancel()
                                return
                            }
                            self.incomingRequest = nil
                            Task {
                                guard let payload = await self.payloadProvider?(),
                                      let plaintext = try? JSONEncoder().encode(payload) else {
                                    self.sendWirePacket(WireResponse(type: "deny", pubKey: nil, box: nil), on: conn)
                                    return
                                }
                                do {
                                    let myPriv = P256.KeyAgreement.PrivateKey()
                                    let shared = try myPriv.sharedSecretFromKeyAgreement(with: peerPubKey)
                                    let symKey = shared.hkdfDerivedSymmetricKey(
                                        using: SHA256.self,
                                        salt: Data(code.utf8),
                                        sharedInfo: Data("xboxpad-auth-sync-v1".utf8),
                                        outputByteCount: 32
                                    )
                                    let sealed = try AES.GCM.seal(plaintext, using: symKey)
                                    guard let combined = sealed.combined else {
                                        self.sendWirePacket(WireResponse(type: "deny", pubKey: nil, box: nil), on: conn)
                                        return
                                    }
                                    let resp = WireResponse(
                                        type: "grant",
                                        pubKey: myPriv.publicKey.rawRepresentation.base64EncodedString(),
                                        box: combined.base64EncodedString()
                                    )
                                    self.sendWirePacket(resp, on: conn)
                                } catch {
                                    self.sendWirePacket(WireResponse(type: "deny", pubKey: nil, box: nil), on: conn)
                                }
                            }
                        },
                        deny: { [weak self] in
                            self?.incomingRequest = nil
                            self?.sendWirePacket(WireResponse(type: "deny", pubKey: nil, box: nil), on: conn)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Browser (Unauthenticated Device on LoginView)

    func startBrowsing() {
        stopBrowsing()
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.bonjourServiceType, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                case .failed, .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers: [NearbySyncPeer] = results.compactMap { res in
                guard case let .service(name, _, _, _) = res.endpoint else { return nil }
                var deviceName = name
                var gamertag = ""
                if case let .bonjour(txt) = res.metadata {
                    if let n = txt["name"], !n.isEmpty { deviceName = n }
                    if let g = txt["gt"], !g.isEmpty { gamertag = g }
                }
                return NearbySyncPeer(
                    id: name,
                    deviceName: deviceName,
                    gamertag: gamertag,
                    endpoint: res.endpoint
                )
            }
            .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }

            Task { @MainActor [weak self] in
                self?.discoveredPeers = peers
            }
        }

        newBrowser.start(queue: netQueue)
        self.browser = newBrowser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredPeers = []
    }

    func requestSync(from peer: NearbySyncPeer) async throws -> ExportableAuthPayload {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        activeVerificationCode = code
        activePeerName = peer.deviceName
        defer {
            activeVerificationCode = nil
            activePeerName = nil
        }

        let myPriv = P256.KeyAgreement.PrivateKey()
        let hello = WireHello(
            type: "hello",
            deviceName: XboxPlatform.localDeviceName,
            pubKey: myPriv.publicKey.rawRepresentation.base64EncodedString(),
            code: code
        )
        let helloData = try JSONEncoder().encode(hello)

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: peer.endpoint, using: params)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotGate()
            let finish: @Sendable (Result<ExportableAuthPayload, Error>) -> Void = { result in
                guard gate.tryAcquire() else { return }
                conn.cancel()
                continuation.resume(with: result)
            }

            netQueue.asyncAfter(deadline: .now() + 45.0) {
                finish(.failure(AuthSyncError.timedOut))
            }

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    finish(.failure(AuthSyncError.cancelled))
                    return
                }
                switch state {
                case .ready:
                    var framed = Data()
                    var lenBE = UInt32(helloData.count).bigEndian
                    framed.append(Data(bytes: &lenBE, count: 4))
                    framed.append(helloData)
                    conn.send(content: framed, completion: .contentProcessed { sendErr in
                        if let sendErr {
                            finish(.failure(sendErr))
                            return
                        }
                        self.receiveJSONPacket(on: conn) { recvRes in
                            switch recvRes {
                            case .failure(let err):
                                finish(.failure(err))
                            case .success(let respData):
                                do {
                                    let resp = try JSONDecoder().decode(WireResponse.self, from: respData)
                                    guard resp.type == "grant",
                                          let pubB64 = resp.pubKey,
                                          let boxB64 = resp.box,
                                          let peerPubData = Data(base64Encoded: pubB64),
                                          let boxData = Data(base64Encoded: boxB64) else {
                                        finish(.failure(AuthSyncError.denied))
                                        return
                                    }
                                    let peerPub = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPubData)
                                    let shared = try myPriv.sharedSecretFromKeyAgreement(with: peerPub)
                                    let symKey = shared.hkdfDerivedSymmetricKey(
                                        using: SHA256.self,
                                        salt: Data(code.utf8),
                                        sharedInfo: Data("xboxpad-auth-sync-v1".utf8),
                                        outputByteCount: 32
                                    )
                                    let sealed = try AES.GCM.SealedBox(combined: boxData)
                                    let plaintext = try AES.GCM.open(sealed, using: symKey)
                                    let payload = try JSONDecoder().decode(ExportableAuthPayload.self, from: plaintext)
                                    finish(.success(payload))
                                } catch {
                                    finish(.failure(AuthSyncError.decryptFailed))
                                }
                            }
                        }
                    })
                case .failed(let err):
                    finish(.failure(err))
                case .cancelled:
                    finish(.failure(AuthSyncError.cancelled))
                default:
                    break
                }
            }

            conn.start(queue: netQueue)
        }
    }

    // MARK: - Framed TCP JSON Helpers (4-byte Big-Endian Length + UTF-8 JSON)

    private nonisolated func sendWirePacket<T: Encodable>(_ obj: T, on conn: NWConnection) {
        guard let payload = try? JSONEncoder().encode(obj) else {
            conn.cancel()
            return
        }
        var framed = Data()
        var lenBE = UInt32(payload.count).bigEndian
        framed.append(Data(bytes: &lenBE, count: 4))
        framed.append(payload)
        conn.send(content: framed, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private nonisolated func receiveJSONPacket(
        on conn: NWConnection,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, err in
            if let err {
                completion(.failure(err))
                return
            }
            guard let header, header.count == 4 else {
                completion(.failure(AuthSyncError.invalidPacket))
                return
            }
            let len = header.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self).bigEndian
            }
            guard len > 0, len <= 262_144 else {
                completion(.failure(AuthSyncError.invalidPacket))
                return
            }
            let bodyLen = Int(len)
            conn.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { body, _, _, bodyErr in
                if let bodyErr {
                    completion(.failure(bodyErr))
                    return
                }
                guard let body, body.count == bodyLen else {
                    completion(.failure(AuthSyncError.invalidPacket))
                    return
                }
                completion(.success(body))
            }
        }
    }
}

private struct WireHello: Codable {
    let type: String
    let deviceName: String
    let pubKey: String
    let code: String
}

private struct WireResponse: Codable {
    let type: String
    let pubKey: String?
    let box: String?
}

private final class OneShotGate: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var acquired = false

    func tryAcquire() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if acquired { return false }
        acquired = true
        return true
    }
}

enum AuthSyncError: LocalizedError {
    case denied
    case timedOut
    case cancelled
    case invalidPacket
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .denied: return "对方设备已拒绝同步请求。"
        case .timedOut: return "等待对方设备确认超时，请重试。"
        case .cancelled: return "同步已取消。"
        case .invalidPacket: return "局域网同步数据包格式异常。"
        case .decryptFailed: return "端到端加密校验失败，请重试。"
        }
    }
}
