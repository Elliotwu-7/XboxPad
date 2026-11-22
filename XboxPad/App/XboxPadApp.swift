import SwiftUI

@main
struct XboxPadApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .task {
                    await appState.bootstrap()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    NotificationCenter.default.post(name: .xboxpadCheckUpdates, object: nil)
                }
            }
            CommandMenu("串流") {
                Button("切换原生全屏") {
                    NotificationCenter.default.post(name: .xboxpadToggleFullscreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("呼出 / 收起顶部控制栏") {
                    NotificationCenter.default.post(name: .xboxpadToggleOverlay, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Button("设置与手柄") {
                    NotificationCenter.default.post(name: .xboxpadOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("原画截屏") {
                    NotificationCenter.default.post(name: .xboxpadCaptureScreenshot, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("开始 / 停止录屏") {
                    NotificationCenter.default.post(name: .xboxpadToggleRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("保存精彩回放 (过去 30 秒)") {
                    NotificationCenter.default.post(name: .xboxpadSaveReplay, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("开启 / 关闭麦克风") {
                    NotificationCenter.default.post(name: .xboxpadToggleMic, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Toggle("锁定 16:9 串流窗口比例", isOn: $appState.settings.macLock16x9Window)
                    .keyboardShortcut("9", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}
