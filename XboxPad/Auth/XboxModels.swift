import Foundation

// MARK: - Auth & Token Models

struct OAuthUserToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let scope: String
    let expiresAt: Date

    var isValid: Bool {
        expiresAt.timeIntervalSinceNow > 60
    }
}

struct XstsTokenData: Codable, Equatable {
    let token: String
    let uhs: String
    let xid: String?
    let notAfter: Date?

    var isValid: Bool {
        guard let notAfter else { return true }
        return notAfter.timeIntervalSinceNow > 60
    }

    var xblAuthHeader: String {
        "XBL3.0 x=\(uhs);\(token)"
    }
}

struct StreamingRegion: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let baseUri: String
    let isDefault: Bool
}

struct StreamingTokenBundle: Codable, Equatable {
    let gsToken: String
    let market: String
    let durationInSeconds: Int
    let createdAt: Date
    let regions: [StreamingRegion]
    let offering: String
    let resolvedRegionIP: String?

    init(
        gsToken: String,
        market: String,
        durationInSeconds: Int,
        createdAt: Date,
        regions: [StreamingRegion],
        offering: String,
        resolvedRegionIP: String? = nil
    ) {
        self.gsToken = gsToken
        self.market = market
        self.durationInSeconds = durationInSeconds
        self.createdAt = createdAt
        self.regions = regions
        self.offering = offering
        self.resolvedRegionIP = resolvedRegionIP
    }

    var expiresAt: Date {
        createdAt.addingTimeInterval(TimeInterval(durationInSeconds))
    }

    var isValid: Bool {
        expiresAt.timeIntervalSinceNow > 90
    }

    func resolvedBaseUri(preferredRegionName: String) -> String {
        if !preferredRegionName.isEmpty,
           let match = regions.first(where: { $0.name == preferredRegionName }) {
            return match.baseUri
        }
        if let defaultRegion = regions.first(where: { $0.isDefault }) {
            return defaultRegion.baseUri
        }
        return regions.first?.baseUri ?? ""
    }
}

struct DeviceCodeInfo: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    let message: String
}

struct AuthSessionSnapshot: Codable, Equatable {
    let xHomeToken: StreamingTokenBundle
    let xCloudToken: StreamingTokenBundle?
    let webToken: XstsTokenData
}

// MARK: - Console & Cloud Game Models

struct XboxConsole: Codable, Identifiable, Hashable {
    var id: String { serverId }
    let serverId: String
    let deviceName: String
    let consoleType: String
    let powerState: String
    let outOfHomeWarning: Bool?

    var isOnline: Bool {
        powerState.caseInsensitiveCompare("On") == .orderedSame
    }

    var isStandby: Bool {
        powerState.caseInsensitiveCompare("ConnectedStandby") == .orderedSame
    }

    var powerDisplayText: String {
        if isOnline { return "已开机" }
        if isStandby { return "待机可唤醒" }
        return powerState.isEmpty ? "离线" : powerState
    }

    var friendlyConsoleType: String {
        switch consoleType {
        case "XboxSeriesX": return "Xbox Series X"
        case "XboxSeriesS": return "Xbox Series S"
        case "XboxOneX": return "Xbox One X"
        case "XboxOneS": return "Xbox One S"
        case "XboxOne": return "Xbox One"
        default: return consoleType.isEmpty ? "Xbox 主机" : consoleType
        }
    }
}

struct CloudGame: Codable, Identifiable, Hashable {
    var id: String { productId }
    let productId: String
    let titleId: String
    let title: String
    let publisher: String
    let tileImageURL: URL?
    let posterImageURL: URL?
    let isRecent: Bool
}

enum StreamTarget: Identifiable, Hashable {
    case home(XboxConsole)
    case cloud(CloudGame)

    var id: String {
        switch self {
        case .home(let console): return "home:\(console.serverId)"
        case .cloud(let game): return "cloud:\(game.titleId)"
        }
    }

    var displayTitle: String {
        switch self {
        case .home(let console): return console.deviceName
        case .cloud(let game): return game.title
        }
    }

    var sessionId: String {
        switch self {
        case .home(let console): return console.serverId
        case .cloud(let game): return game.titleId
        }
    }

    var streamType: String {
        switch self {
        case .home: return "home"
        case .cloud: return "cloud"
        }
    }

    var isHome: Bool {
        if case .home = self { return true }
        return false
    }
}

// MARK: - Settings & Telemetry Models

enum StreamResolution: Int, CaseIterable, Identifiable, Codable {
    case p720 = 720
    case p1080 = 1080
    case p1080HQ = 1081

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .p720: return "720p (省带宽)"
        case .p1080: return "1080p 标准"
        case .p1080HQ: return "2K 1440p / 1080p HQ 最高码率 (推荐)"
        }
    }
}

enum VideoSharpeningLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case light
    case medium
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭（原始柔化画面）"
        case .light: return "轻度 CAS 锐化（推荐 · 自然通透）"
        case .medium: return "中度 CAS 锐化（清晰细节）"
        case .strong: return "强力 CAS 锐化（极致锐利）"
        }
    }

    var intensity: Float {
        switch self {
        case .off: return 0.0
        case .light: return 0.38
        case .medium: return 0.65
        case .strong: return 0.92
        }
    }
}

enum VideoHDRToneMode: String, CaseIterable, Identifiable, Codable {
    case off
    case natural
    case vivid
    case cinema

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭（原始 Rec.709 SDR）"
        case .natural: return "HDR 自然（温柔 EDR 提亮 · 耐看不刺眼）"
        case .vivid: return "HDR 鲜艳（Auto-HDR 广色域 · 游戏通透）"
        case .cinema: return "HDR 影院（高对比 · XDR/OLED 峰值光影）"
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return "HDR 关"
        case .natural: return "HDR 自然"
        case .vivid: return "HDR 鲜艳"
        case .cinema: return "HDR 影院"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VideoHDRToneMode(rawValue: raw) ?? .off
    }
}

enum LatencyProfile: Int, CaseIterable, Identifiable, Codable {
    case ultraLow = 50
    case low = 80
    case balanced = 130
    case stable = 200

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .ultraLow: return "极限低延迟 (50ms 缓冲上限 · 需千兆有线)"
        case .low: return "低延迟 (80ms · 局域网推荐)"
        case .balanced: return "均衡 (130ms · 复杂 Wi-Fi)"
        case .stable: return "抗抖动优先 (200ms · 外网/云游戏)"
        }
    }
}

enum VideoAspectMode: String, CaseIterable, Identifiable, Codable {
    case fit
    case stretch
    case fill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "原始 16:9（无裁剪无变形）"
        case .stretch: return "全屏拉伸（完整 HUD · 无黑边）"
        case .fill: return "等比铺满（裁左右无黑边）"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VideoAspectMode(rawValue: raw) ?? .fit
    }
}

enum VideoFramePacingMode: String, CaseIterable, Identifiable, Codable {
    case auto
    case smooth
    case immediate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "智能防抖（推荐 · 自动对抗 Wi-Fi / 通用控制波动）"
        case .smooth: return "丝滑优先（强制 60Hz 恒定平滑 · 专治非 149 信道/热点）"
        case .immediate: return "极速零缓冲（零排队延迟 · 需有线或 149 信道）"
        }
    }
}

struct CloudRegionPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let ip: String

    static let presets: [CloudRegionPreset] = [
        CloudRegionPreset(id: "auto", name: "自动（按当前网络）", ip: ""),
        CloudRegionPreset(id: "jp", name: "日本 (东京)", ip: "133.130.100.1"),
        CloudRegionPreset(id: "kr", name: "韩国 (首尔)", ip: "211.233.10.1"),
        CloudRegionPreset(id: "us-west", name: "美国西部", ip: "4.2.2.2"),
        CloudRegionPreset(id: "uk", name: "英国", ip: "185.15.58.1"),
        CloudRegionPreset(id: "au", name: "澳大利亚", ip: "1.1.1.1"),
    ]
}

enum NetworkStackMode: Int, CaseIterable, Identifiable, Codable {
    case auto = 0
    case ipv4Only = 1
    case ipv6Only = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动优选（IPv4 + IPv6 推荐）"
        case .ipv4Only: return "仅 IPv4（自建打洞 / 中继）"
        case .ipv6Only: return "仅 IPv6（直连调优）"
        }
    }
}

enum StickResponseCurve: String, CaseIterable, Identifiable, Codable {
    case linear
    case precision
    case snappy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "线性（1:1 原始手感）"
        case .precision: return "精准微调（中心更细腻 · FPS 推荐）"
        case .snappy: return "快速响应（小幅度即可大转向）"
        }
    }

    var exponent: Float {
        switch self {
        case .linear: return 1.0
        case .precision: return 1.55
        case .snappy: return 0.72
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StickResponseCurve(rawValue: raw) ?? .linear
    }
}

enum GyroAimMode: String, CaseIterable, Identifiable, Codable {
    case off
    case onLeftTrigger
    case alwaysOn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .onLeftTrigger: return "按住 LT 开镜激活（推荐）"
        case .alwaysOn: return "始终开启体感瞄准"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GyroAimMode(rawValue: raw) ?? .off
    }
}

enum KeyboardMouseMode: String, CaseIterable, Identifiable, Codable {
    case off
    case gamepadEmulation
    case nativeKM

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭键鼠"
        case .gamepadEmulation: return "键鼠模拟手柄（全游戏通用 · 推荐）"
        case .nativeKM: return "原生 Xbox 键鼠直通（仅云游戏支持）"
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return "键鼠关"
        case .gamepadEmulation: return "键鼠模拟"
        case .nativeKM: return "原生键鼠"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KeyboardMouseMode(rawValue: raw) ?? .gamepadEmulation
    }
}

struct ControllerDeviceInfo: Identifiable, Equatable {
    let id: String
    let playerIndex: Int // 0..3 -> P1..P4
    let modelName: String
    let shortModelName: String
    let vendorRawName: String
    let categoryIcon: String
    let supportsHandleRumble: Bool
    let supportsTriggerRumble: Bool
    let supportsGyro: Bool
    let batteryPercent: Int?
    let isCharging: Bool
}

struct LatencySample: Identifiable, Equatable {
    let id: Int
    let rttMs: Double
    let pipeMs: Double
}

enum NintendoButtonLayoutMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto = "auto"
    case alwaysSwap = "swap"
    case xboxNative = "native"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动（Switch 手柄自动互换）"
        case .alwaysSwap: return "始终互换 A↔B / X↔Y"
        case .xboxNative: return "保持原样（不互换）"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var resolution: StreamResolution = .p1080HQ
    var latencyProfile: LatencyProfile = .low
    var aspectMode: VideoAspectMode = .fit
    var sharpeningLevel: VideoSharpeningLevel = .light
    var hdrToneMode: VideoHDRToneMode = .off
    var debandingEnabled: Bool = true
    var metalFXUpscaling: Bool = true
    var thermalProtectionEnabled: Bool = true
    var externalDisplayFullscreen: Bool = true
    var framePacingMode: VideoFramePacingMode = .auto
    var frameInterpolation120Hz: Bool = false
    var stereoAudio: Bool = true
    var networkMode: NetworkStackMode = .auto
    var autoReconnect: Bool = true
    var preferredLanguage: String = "zh-CN"
    var forceRegionIP: String = ""
    var selectedHomeRegion: String = ""
    var selectedCloudRegion: String = ""
    var rumbleEnabled: Bool = true
    var handleRumbleStrength: Double = 1.0
    var triggerRumbleStrength: Double = 1.0
    var fallbackTriggerToHandles: Bool = true
    var stickDeadzone: Double = 0.05
    var leftStickDeadzone: Double = 0.05
    var rightStickDeadzone: Double = 0.05
    var stickResponseCurve: StickResponseCurve = .linear
    var triggerDeadzone: Double = 0.02
    var gyroAimMode: GyroAimMode = .off
    var gyroSensitivity: Double = 1.0
    var gyroInvertY: Bool = false
    var keyboardMouseMode: KeyboardMouseMode = .gamepadEmulation
    var mouseSensitivity: Double = 1.0
    var virtualGamepadOpacity: Double = 0.58
    var nintendoButtonLayout: NintendoButtonLayoutMode = .auto
    var micEchoCancellation: Bool = true
    var shadowLift: Double = 0.0
    var videoBrightness: Double = 0.0
    var videoContrast: Double = 1.0
    var videoSaturation: Double = 1.0
    var macLock16x9Window: Bool = false
    var favoriteCloudTitleIds: [String] = []
    var recentCloudTitleIds: [String] = []
    var menuComboEnabled: Bool = true
    var mapShareToNexus: Bool = true
    var showPerformanceHUD: Bool = true
    var showVirtualControlsWhenNoGamepad: Bool = true
    var useBuiltInRelay: Bool = true
    var iCloudKeychainSync: Bool = true
    var customIceUrl: String = ""
    var customIceUser: String = ""
    var customIcePass: String = ""

    private static let storageKey = "xboxpad.settings.v1"

    enum CodingKeys: String, CodingKey {
        case resolution, latencyProfile, aspectMode, sharpeningLevel, hdrToneMode
        case debandingEnabled, metalFXUpscaling, thermalProtectionEnabled, externalDisplayFullscreen
        case framePacingMode, frameInterpolation120Hz, stereoAudio, networkMode
        case autoReconnect, preferredLanguage, forceRegionIP, selectedHomeRegion, selectedCloudRegion
        case rumbleEnabled, handleRumbleStrength, triggerRumbleStrength, fallbackTriggerToHandles
        case stickDeadzone, leftStickDeadzone, rightStickDeadzone, stickResponseCurve, triggerDeadzone
        case gyroAimMode, gyroSensitivity, gyroInvertY, keyboardMouseMode, mouseSensitivity, virtualGamepadOpacity
        case nintendoButtonLayout, micEchoCancellation, shadowLift, videoBrightness, videoContrast, videoSaturation
        case macLock16x9Window, favoriteCloudTitleIds, recentCloudTitleIds
        case menuComboEnabled, mapShareToNexus, showPerformanceHUD, showVirtualControlsWhenNoGamepad
        case useBuiltInRelay, iCloudKeychainSync, customIceUrl, customIceUser, customIcePass
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? .p1080HQ
        latencyProfile = try c.decodeIfPresent(LatencyProfile.self, forKey: .latencyProfile) ?? .low
        aspectMode = try c.decodeIfPresent(VideoAspectMode.self, forKey: .aspectMode) ?? .fit
        sharpeningLevel = try c.decodeIfPresent(VideoSharpeningLevel.self, forKey: .sharpeningLevel) ?? .light
        hdrToneMode = try c.decodeIfPresent(VideoHDRToneMode.self, forKey: .hdrToneMode) ?? .off
        debandingEnabled = try c.decodeIfPresent(Bool.self, forKey: .debandingEnabled) ?? true
        metalFXUpscaling = try c.decodeIfPresent(Bool.self, forKey: .metalFXUpscaling) ?? true
        thermalProtectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .thermalProtectionEnabled) ?? true
        externalDisplayFullscreen = try c.decodeIfPresent(Bool.self, forKey: .externalDisplayFullscreen) ?? true
        framePacingMode = try c.decodeIfPresent(VideoFramePacingMode.self, forKey: .framePacingMode) ?? .auto
        frameInterpolation120Hz = try c.decodeIfPresent(Bool.self, forKey: .frameInterpolation120Hz) ?? false
        stereoAudio = try c.decodeIfPresent(Bool.self, forKey: .stereoAudio) ?? true
        networkMode = try c.decodeIfPresent(NetworkStackMode.self, forKey: .networkMode) ?? .auto
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        preferredLanguage = try c.decodeIfPresent(String.self, forKey: .preferredLanguage) ?? "zh-CN"
        forceRegionIP = try c.decodeIfPresent(String.self, forKey: .forceRegionIP) ?? ""
        selectedHomeRegion = try c.decodeIfPresent(String.self, forKey: .selectedHomeRegion) ?? ""
        selectedCloudRegion = try c.decodeIfPresent(String.self, forKey: .selectedCloudRegion) ?? ""
        rumbleEnabled = try c.decodeIfPresent(Bool.self, forKey: .rumbleEnabled) ?? true
        handleRumbleStrength = try c.decodeIfPresent(Double.self, forKey: .handleRumbleStrength) ?? 1.0
        triggerRumbleStrength = try c.decodeIfPresent(Double.self, forKey: .triggerRumbleStrength) ?? 1.0
        fallbackTriggerToHandles = try c.decodeIfPresent(Bool.self, forKey: .fallbackTriggerToHandles) ?? true
        let legacyDZ = try c.decodeIfPresent(Double.self, forKey: .stickDeadzone) ?? 0.05
        stickDeadzone = legacyDZ
        leftStickDeadzone = try c.decodeIfPresent(Double.self, forKey: .leftStickDeadzone) ?? legacyDZ
        rightStickDeadzone = try c.decodeIfPresent(Double.self, forKey: .rightStickDeadzone) ?? legacyDZ
        stickResponseCurve = try c.decodeIfPresent(StickResponseCurve.self, forKey: .stickResponseCurve) ?? .linear
        triggerDeadzone = try c.decodeIfPresent(Double.self, forKey: .triggerDeadzone) ?? 0.02
        gyroAimMode = try c.decodeIfPresent(GyroAimMode.self, forKey: .gyroAimMode) ?? .off
        gyroSensitivity = try c.decodeIfPresent(Double.self, forKey: .gyroSensitivity) ?? 1.0
        gyroInvertY = try c.decodeIfPresent(Bool.self, forKey: .gyroInvertY) ?? false
        keyboardMouseMode = try c.decodeIfPresent(KeyboardMouseMode.self, forKey: .keyboardMouseMode) ?? .gamepadEmulation
        mouseSensitivity = try c.decodeIfPresent(Double.self, forKey: .mouseSensitivity) ?? 1.0
        virtualGamepadOpacity = try c.decodeIfPresent(Double.self, forKey: .virtualGamepadOpacity) ?? 0.58
        nintendoButtonLayout = try c.decodeIfPresent(NintendoButtonLayoutMode.self, forKey: .nintendoButtonLayout) ?? .auto
        micEchoCancellation = try c.decodeIfPresent(Bool.self, forKey: .micEchoCancellation) ?? true
        shadowLift = try c.decodeIfPresent(Double.self, forKey: .shadowLift) ?? 0.0
        videoBrightness = try c.decodeIfPresent(Double.self, forKey: .videoBrightness) ?? 0.0
        videoContrast = try c.decodeIfPresent(Double.self, forKey: .videoContrast) ?? 1.0
        videoSaturation = try c.decodeIfPresent(Double.self, forKey: .videoSaturation) ?? 1.0
        macLock16x9Window = try c.decodeIfPresent(Bool.self, forKey: .macLock16x9Window) ?? false
        favoriteCloudTitleIds = try c.decodeIfPresent([String].self, forKey: .favoriteCloudTitleIds) ?? []
        recentCloudTitleIds = try c.decodeIfPresent([String].self, forKey: .recentCloudTitleIds) ?? []
        menuComboEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuComboEnabled) ?? true
        mapShareToNexus = try c.decodeIfPresent(Bool.self, forKey: .mapShareToNexus) ?? true
        showPerformanceHUD = try c.decodeIfPresent(Bool.self, forKey: .showPerformanceHUD) ?? true
        showVirtualControlsWhenNoGamepad = try c.decodeIfPresent(Bool.self, forKey: .showVirtualControlsWhenNoGamepad) ?? true
        useBuiltInRelay = try c.decodeIfPresent(Bool.self, forKey: .useBuiltInRelay) ?? true
        iCloudKeychainSync = try c.decodeIfPresent(Bool.self, forKey: .iCloudKeychainSync) ?? true
        customIceUrl = try c.decodeIfPresent(String.self, forKey: .customIceUrl) ?? ""
        customIceUser = try c.decodeIfPresent(String.self, forKey: .customIceUser) ?? ""
        customIcePass = try c.decodeIfPresent(String.self, forKey: .customIcePass) ?? ""
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

struct LiveStreamStats: Equatable {
    var rttMs: Double = -1
    var jitterMs: Double = -1
    var fps: Double = -1
    var bitrateMbps: Double = -1
    var packetLossPct: Double = -1
    var framesDropped: UInt64 = 0
    var framesReceived: UInt64 = 0
    var decodeMs: Double = -1
    var audioBufferMs: Double = -1
    /// 0 = unknown, 1 = LAN direct, 2 = NAT P2P direct, 3 = TURN relay
    var routeKind: UInt8 = 0

    var routeBadgeText: String {
        switch routeKind {
        case 1: return "LAN直连"
        case 2: return "P2P直连"
        case 3: return "中继TURN"
        default: return "检测中"
        }
    }
}

struct GamepadTelemetry: Equatable {
    var connected: Bool = false
    var name: String = "未连接手柄"
    var modelName: String = "未连接手柄"
    var supportsHandleRumble: Bool = false
    var supportsTriggerRumble: Bool = false
    var controllers: [ControllerDeviceInfo] = []
    var selectedSlotIndex: Int = 0
    var keyboardConnected: Bool = false
    var mouseConnected: Bool = false
    var keyboardName: String = ""
    var mouseName: String = ""
    var activeButtons: [String] = []
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
}
