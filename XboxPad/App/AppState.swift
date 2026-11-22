import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let authService = XboxAuthService()
    let gamepadManager = GamepadManager()
    let authSyncService = AuthSyncService()
    let updateChecker = AppUpdateChecker()
    let networkDiagnostics = NetworkDiagnosticsService()

    @Published var settings: AppSettings {
        didSet {
            settings.save()
            gamepadManager.settings = settings
            if settings.iCloudKeychainSync != oldValue.iCloudKeychainSync {
                let enabled = settings.iCloudKeychainSync
                Task {
                    await authService.setICloudSyncEnabled(enabled)
                }
                showToast(enabled ? "已开启 iCloud 钥匙串同步登录态" : "已切换为仅本机保存登录态")
            }
        }
    }

    @Published var isCheckingAuth = true
    @Published var isAuthenticated = false
    @Published var gamertag: String = ""

    @Published var consoles: [XboxConsole] = []
    @Published var isLoadingConsoles = false
    @Published var consoleError: String?

    @Published var cloudGames: [CloudGame] = []
    @Published var isLoadingCloudGames = false
    @Published var cloudError: String?

    @Published var homeRegions: [StreamingRegion] = []
    @Published var cloudRegions: [StreamingRegion] = []

    @Published var activeStreamTarget: StreamTarget?
    @Published var isStreamOverlayOpen = false
    @Published var toastMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let loaded = AppSettings.load()
        self.settings = loaded
        self.gamepadManager.settings = loaded
        self.authSyncService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.updateChecker.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.networkDiagnostics.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func bootstrap() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }

        #if os(macOS)
        Task { [weak self] in
            await self?.updateChecker.checkForUpdates(silent: true)
        }
        #endif

        let hasLogin = await authService.hasStoredLogin(forceReload: true)
        guard hasLogin else {
            isAuthenticated = false
            return
        }

        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: false,
                forceRegionIP: settings.forceRegionIP
            )
            applyAuthSnapshot(snapshot)
            isAuthenticated = true
            startNearbyAuthSyncAdvertiser()
            await loadAllData(snapshot: snapshot)
        } catch {
            // Keep login state if only transient network failed, otherwise let user re-login
            if case XboxAuthError.missingUserToken = error {
                isAuthenticated = false
            } else {
                consoleError = "自动恢复登录失败：\(error.localizedDescription)"
                isAuthenticated = false
            }
        }
    }

    func restoreFromICloudKeychain() async -> Bool {
        let found = await authService.hasStoredLogin(forceReload: true)
        guard found else { return false }
        await bootstrap()
        return isAuthenticated
    }

    func completeLogin() async {
        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: true,
                forceRegionIP: settings.forceRegionIP
            )
            applyAuthSnapshot(snapshot)
            isAuthenticated = true
            startNearbyAuthSyncAdvertiser()
            await loadAllData(snapshot: snapshot)
        } catch {
            consoleError = error.localizedDescription
        }
    }

    func startNearbyAuthSyncAdvertiser() {
        guard isAuthenticated else {
            authSyncService.stopAdvertising()
            return
        }
        let devName = XboxPlatform.localDeviceName
        let gt = gamertag
        authSyncService.startAdvertising(deviceName: devName, gamertag: gt) { [weak self] in
            guard let self else { return nil }
            guard let token = await self.authService.exportUserToken() else { return nil }
            let s = await MainActor.run { self.settings }
            let tag = await MainActor.run { self.gamertag }
            return ExportableAuthPayload(
                userToken: token,
                gamertag: tag.isEmpty ? nil : tag,
                customIceUrl: s.customIceUrl.isEmpty ? nil : s.customIceUrl,
                customIceUser: s.customIceUser.isEmpty ? nil : s.customIceUser,
                customIcePass: s.customIcePass.isEmpty ? nil : s.customIcePass
            )
        }
    }

    func exportAuthToUniversalClipboard() async {
        guard let token = await authService.exportUserToken() else {
            showToast("当前没有可导出的登录凭证")
            return
        }
        let payload = ExportableAuthPayload(
            userToken: token,
            gamertag: gamertag.isEmpty ? nil : gamertag,
            customIceUrl: settings.customIceUrl.isEmpty ? nil : settings.customIceUrl,
            customIceUser: settings.customIceUser.isEmpty ? nil : settings.customIceUser,
            customIcePass: settings.customIcePass.isEmpty ? nil : settings.customIcePass
        )
        guard let encoded = AuthSyncService.encodeTransferString(payload) else {
            showToast("登录凭证编码失败")
            return
        }
        XboxPlatform.copyToClipboard(encoded)
        showToast("已复制到通用剪贴板，切到 Mac/iPhone 点「从剪贴板导入登录」即可")
    }

    func importAuthPayload(_ payload: ExportableAuthPayload) async -> String? {
        if let ice = payload.customIceUrl, !ice.isEmpty, settings.customIceUrl.isEmpty {
            settings.customIceUrl = ice
            settings.customIceUser = payload.customIceUser ?? ""
            settings.customIcePass = payload.customIcePass ?? ""
        }
        await authService.importUserToken(payload.userToken)
        await completeLogin()
        if isAuthenticated {
            showToast("已成功同步 Xbox 登录态")
            return nil
        }
        return consoleError ?? "同步的登录凭证已过期，请重新授权。"
    }

    func importAuthFromUniversalClipboard() async -> String? {
        guard let text = XboxPlatform.readClipboard(), !text.isEmpty else {
            return "剪贴板为空。请先在已登录设备的「设置 → 账号」点击「复制登录凭证」。"
        }
        guard let payload = AuthSyncService.decodeTransferString(text) else {
            return "剪贴板中未检测到 XboxPad 登录凭证。请先在已登录设备点击「复制登录凭证」。"
        }
        XboxPlatform.clearClipboard()
        return await importAuthPayload(payload)
    }

    func refreshAllAfterRegionChange() async {
        guard isAuthenticated else { return }
        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: true,
                forceRegionIP: settings.forceRegionIP
            )
            applyAuthSnapshot(snapshot)
            await loadAllData(snapshot: snapshot)
            showToast("已刷新 Xbox 区域凭证")
        } catch {
            showToast("刷新凭证失败：\(error.localizedDescription)")
        }
    }

    func refreshConsoles() async {
        isLoadingConsoles = true
        consoleError = nil
        defer { isLoadingConsoles = false }

        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: false,
                forceRegionIP: settings.forceRegionIP
            )
            applyAuthSnapshot(snapshot)
            let baseUri = snapshot.xHomeToken.resolvedBaseUri(preferredRegionName: settings.selectedHomeRegion)
            consoles = try await XboxHomeAPI.fetchConsoles(baseUri: baseUri, gsToken: snapshot.xHomeToken.gsToken)
        } catch {
            consoleError = error.localizedDescription
        }
    }

    func refreshCloudGames(forceRefresh: Bool = false) async {
        isLoadingCloudGames = true
        cloudError = nil
        defer { isLoadingCloudGames = false }

        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: forceRefresh,
                forceRegionIP: settings.forceRegionIP,
                requireCloud: true
            )
            applyAuthSnapshot(snapshot)
            guard let cloudToken = snapshot.xCloudToken else {
                cloudGames = []
                let detail = await authService.getLastCloudAuthError()
                if let detail, !detail.isEmpty {
                    cloudError = "未获取到 xCloud 云游戏凭证（\(detail)）。请切换日本/韩国/美国节点，或确认账号已开通 XGPU / 代理已开启。"
                } else {
                    cloudError = "当前地区或账号未获取到 xCloud 云游戏权限，请在右上角切换「日本 / 韩国 / 美国」跨区节点后重试。"
                }
                return
            }
            let baseUri = cloudToken.resolvedBaseUri(preferredRegionName: settings.selectedCloudRegion)
            let effectiveIP = cloudToken.resolvedRegionIP ?? settings.forceRegionIP
            cloudGames = try await XboxCloudAPI.fetchCloudGames(
                baseUri: baseUri,
                gsToken: cloudToken.gsToken,
                preferredLanguage: settings.preferredLanguage,
                market: cloudToken.market,
                forwardedIP: effectiveIP
            )
        } catch {
            cloudError = error.localizedDescription
        }
    }

    func wakeConsole(_ console: XboxConsole, thenStream: Bool) async {
        if thenStream {
            // Immediately launch stream (Xbox /v5/sessions/home/play natively wakes ConnectedStandby consoles)
            // while firing XCCS WakeUp best-effort in parallel so xccs errors never block streaming.
            activeStreamTarget = .home(console)
            Task {
                if let snapshot = try? await authService.getValidSessionSnapshot(
                    forceRefresh: false,
                    forceRegionIP: settings.forceRegionIP
                ) {
                    try? await XboxHomeAPI.sendPowerCommand(
                        consoleId: console.serverId,
                        wakeUp: true,
                        webToken: snapshot.webToken
                    )
                }
            }
            return
        }

        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: false,
                forceRegionIP: settings.forceRegionIP
            )
            try await XboxHomeAPI.sendPowerCommand(
                consoleId: console.serverId,
                wakeUp: true,
                webToken: snapshot.webToken
            )
            showToast("已向 \(console.deviceName) 发送唤醒指令")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshConsoles()
        } catch {
            showToast("唤醒失败：\(error.localizedDescription)")
        }
    }

    func powerOffConsole(_ console: XboxConsole) async {
        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: false,
                forceRegionIP: settings.forceRegionIP
            )
            try await XboxHomeAPI.sendPowerCommand(
                consoleId: console.serverId,
                wakeUp: false,
                webToken: snapshot.webToken
            )
            showToast("已向 \(console.deviceName) 发送关机指令")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshConsoles()
        } catch {
            showToast("关机失败：\(error.localizedDescription)")
        }
    }

    func logout() async {
        activeStreamTarget = nil
        authSyncService.stopAdvertising()
        await authService.logout()
        isAuthenticated = false
        gamertag = ""
        consoles = []
        cloudGames = []
        homeRegions = []
        cloudRegions = []
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    func isFavoriteCloudGame(_ titleId: String) -> Bool {
        settings.favoriteCloudTitleIds.contains(titleId)
    }

    func toggleFavoriteCloudGame(_ titleId: String) {
        if let idx = settings.favoriteCloudTitleIds.firstIndex(of: titleId) {
            settings.favoriteCloudTitleIds.remove(at: idx)
        } else {
            settings.favoriteCloudTitleIds.insert(titleId, at: 0)
        }
    }

    func isRecentCloudGame(_ game: CloudGame) -> Bool {
        game.isRecent || settings.recentCloudTitleIds.contains(game.id)
    }

    func launchCloudGame(_ game: CloudGame) {
        var recents = settings.recentCloudTitleIds
        recents.removeAll { $0 == game.id }
        recents.insert(game.id, at: 0)
        if recents.count > 24 {
            recents = Array(recents.prefix(24))
        }
        settings.recentCloudTitleIds = recents
        activeStreamTarget = .cloud(game)
    }

    func applyControlProfile(_ preset: ControlProfilePreset) {
        settings.controlProfile = preset
        switch preset {
        case .standard:
            settings.leftStickDeadzone = 0.05
            settings.rightStickDeadzone = 0.05
            settings.stickResponseCurve = .linear
            settings.triggerDeadzone = 0.02
            settings.gamepadButtonMap.swapTriggersAndBumpers = false
            settings.crosshairEnabled = false
        case .fps:
            settings.leftStickDeadzone = 0.04
            settings.rightStickDeadzone = 0.03
            settings.stickResponseCurve = .precision
            settings.triggerDeadzone = 0.01
            settings.gamepadButtonMap.paddle1 = .a
            settings.gamepadButtonMap.paddle2 = .b
            settings.gamepadButtonMap.paddle3 = .x
            settings.gamepadButtonMap.paddle4 = .y
            settings.shadowLift = max(settings.shadowLift, 0.14)
            settings.crosshairEnabled = true
        case .racing:
            settings.leftStickDeadzone = 0.03
            settings.rightStickDeadzone = 0.06
            settings.stickResponseCurve = .linear
            settings.triggerDeadzone = 0.01
            settings.triggerRumbleStrength = 1.25
            settings.crosshairEnabled = false
        case .souls:
            settings.leftStickDeadzone = 0.05
            settings.rightStickDeadzone = 0.05
            settings.stickResponseCurve = .snappy
            settings.gamepadButtonMap.paddle1 = .b
            settings.gamepadButtonMap.paddle2 = .a
            settings.crosshairEnabled = false
        case .custom:
            break
        }
        showToast("已切换操控预设：\(preset.label)")
    }

    func quickLaunchFirstConsole() {
        guard isAuthenticated, activeStreamTarget == nil else { return }
        Task {
            if consoles.isEmpty {
                await refreshConsoles()
            }
            guard let target = consoles.first(where: \.isOnline) ?? consoles.first else {
                showToast("未找到可用 Xbox 主机")
                return
            }
            if target.isStandby {
                await wakeConsole(target, thenStream: true)
            } else {
                activeStreamTarget = .home(target)
            }
        }
    }

    private func applyAuthSnapshot(_ snapshot: AuthSessionSnapshot) {
        homeRegions = snapshot.xHomeToken.regions
        cloudRegions = snapshot.xCloudToken?.regions ?? []
    }

    private func loadAllData(snapshot: AuthSessionSnapshot) async {
        async let tagTask = XboxHomeAPI.fetchGamertag(webToken: snapshot.webToken)
        async let consolesTask: Void = refreshConsoles()
        async let cloudTask: Void = refreshCloudGames()
        let tag = await tagTask
        if let tag, !tag.isEmpty {
            gamertag = tag
            startNearbyAuthSyncAdvertiser()
        }
        _ = await (consolesTask, cloudTask)
    }
}
