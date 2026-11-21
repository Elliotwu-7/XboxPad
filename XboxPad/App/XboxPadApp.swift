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
        #endif
    }
}
