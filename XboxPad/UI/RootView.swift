import GameController
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var appState: AppState

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.055, green: 0.07, blue: 0.09, alpha: 0.96)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if appState.isCheckingAuth {
                    splashView
                } else if !appState.isAuthenticated {
                    LoginView()
                } else {
                    TabView {
                        HomeConsolesView(gamepadManager: appState.gamepadManager)
                            .tabItem {
                                Label("主机串流", systemImage: "tv.and.hifispeaker.fill")
                            }

                        CloudGamesView()
                            .tabItem {
                                Label("云游戏", systemImage: "cloud.fill")
                            }

                        SettingsView(gamepadManager: appState.gamepadManager)
                            .tabItem {
                                Label("设置与手柄", systemImage: "slider.horizontal.3")
                            }
                    }
                    .tint(XboxTheme.emerald)
                }
            }

            if let toast = appState.toastMessage {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(XboxTheme.emeraldBright)
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(XboxTheme.emerald.opacity(0.38), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
                .padding(.bottom, 68)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: appState.toastMessage)
        .fullScreenCover(item: $appState.activeStreamTarget) { target in
            StreamEventContainerView(
                lockPointer: appState.settings.keyboardMouseMode != .off && appState.gamepadManager.telemetry.mouseConnected
            ) {
                StreamPlayerView(
                    target: target,
                    authService: appState.authService,
                    gamepadManager: appState.gamepadManager,
                    settings: appState.settings,
                    onDismiss: {
                        appState.activeStreamTarget = nil
                    }
                )
                .environmentObject(appState)
            }
            .ignoresSafeArea()
        }
    }

    private var splashView: some View {
        ZStack {
            XboxAmbientBackground(intensity: 1.2)
            VStack(spacing: 20) {
                XboxBrandEmblem(size: 84)
                VStack(spacing: 6) {
                    Text("XboxPad")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(XboxTheme.emerald)
                        Text("正在恢复 Xbox 登录状态...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Real `GCEventViewController` container hosting the entire streaming UI with
/// `controllerUserInteractionEnabled = false`, matching OneCast / Moonlight so iPadOS
/// routes raw controller inputs (including overridden Home/Guide presses) directly to XboxPad.
private struct StreamEventContainerView<Content: View>: UIViewControllerRepresentable {
    let lockPointer: Bool
    let content: Content

    init(lockPointer: Bool = false, @ViewBuilder content: () -> Content) {
        self.lockPointer = lockPointer
        self.content = content()
    }

    func makeUIViewController(context: Context) -> StreamGCEventViewController<Content> {
        StreamGCEventViewController(rootView: content, lockPointer: lockPointer)
    }

    func updateUIViewController(_ uiViewController: StreamGCEventViewController<Content>, context: Context) {
        uiViewController.controllerUserInteractionEnabled = false
        uiViewController.setPointerLocked(lockPointer)
        uiViewController.updateRootView(content)
    }
}

private final class StreamGCEventViewController<Content: View>: GCEventViewController {
    private let hostingController: UIHostingController<Content>
    private var shouldLockPointer: Bool

    init(rootView: Content, lockPointer: Bool) {
        self.hostingController = UIHostingController(rootView: rootView)
        self.shouldLockPointer = lockPointer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersPointerLocked: Bool { shouldLockPointer }

    func setPointerLocked(_ locked: Bool) {
        guard shouldLockPointer != locked else { return }
        shouldLockPointer = locked
        setNeedsUpdateOfPrefersPointerLocked()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        controllerUserInteractionEnabled = false

        addChild(hostingController)
        hostingController.view.backgroundColor = .black
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controllerUserInteractionEnabled = false
    }

    func updateRootView(_ rootView: Content) {
        hostingController.rootView = rootView
    }
}
