import AppIntents
import Foundation

/// Native Apple Shortcuts / Siri / Spotlight integration (iOS 16+ & macOS 14+, zero extra entitlements).
@available(iOS 16.0, macOS 14.0, *)
struct LaunchXboxConsoleIntent: AppIntent {
    static var title: LocalizedStringResource = "启动 Xbox 主机串流"
    static var description = IntentDescription("立即打开 XboxPad 并自动唤醒或连接第一台可用 Xbox 主机。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .xboxpadQuickLaunchConsole, object: nil)
        return .result()
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct XboxPadShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LaunchXboxConsoleIntent(),
            phrases: [
                "用 \(.applicationName) 串流 Xbox",
                "打开 \(.applicationName) 连接主机",
                "Start Xbox stream in \(.applicationName)",
            ],
            shortTitle: "一键串流 Xbox",
            systemImageName: "xbox.logo"
        )
    }
}
