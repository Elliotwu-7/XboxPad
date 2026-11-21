import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let authService = XboxAuthService()
    let gamepadManager = GamepadManager()

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
    @Published var toastMessage: String?

    init() {
        let loaded = AppSettings.load()
        self.settings = loaded
        self.gamepadManager.settings = loaded
    }

    func bootstrap() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }

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
            await loadAllData(snapshot: snapshot)
        } catch {
            consoleError = error.localizedDescription
        }
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
            if thenStream {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                activeStreamTarget = .home(console)
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshConsoles()
            }
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
        }
        _ = await (consolesTask, cloudTask)
    }
}
