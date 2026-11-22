import GameController
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Int = 0

    init() {
        #if os(iOS)
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
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if appState.isCheckingAuth {
                    splashView
                } else if !appState.isAuthenticated {
                    LoginView()
                } else {
                    TabView(selection: $selectedTab) {
                        HomeConsolesView(gamepadManager: appState.gamepadManager, isSelectedTab: selectedTab == 0)
                            .tabItem {
                                Label("主机串流", systemImage: "tv.and.hifispeaker.fill")
                            }
                            .tag(0)

                        CloudGamesView(isSelectedTab: selectedTab == 1)
                            .tabItem {
                                Label("云游戏", systemImage: "cloud.fill")
                            }
                            .tag(1)

                        SettingsView(gamepadManager: appState.gamepadManager)
                            .tabItem {
                                Label("设置与手柄", systemImage: "slider.horizontal.3")
                            }
                            .tag(2)
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
        .alert(
            "附近设备请求同步 Xbox 登录",
            isPresented: Binding(
                get: { appState.authSyncService.incomingRequest != nil },
                set: { shown in
                    if !shown {
                        appState.authSyncService.incomingRequest?.deny()
                    }
                }
            ),
            presenting: appState.authSyncService.incomingRequest
        ) { req in
            Button("允许同步") {
                req.approve()
                appState.showToast("已加密同步登录态至 \(req.requesterDeviceName)")
            }
            Button("拒绝", role: .cancel) {
                req.deny()
            }
        } message: { req in
            Text("「\(req.requesterDeviceName)」请求通过局域网端到端加密同步当前 Xbox 登录状态。\n核对码：\(req.verificationCode)")
        }
        .xboxStreamPresentation(item: $appState.activeStreamTarget) { target in
            StreamEventContainerView(
                lockPointer: appState.settings.keyboardMouseMode != .off
                    && appState.gamepadManager.telemetry.mouseConnected
                    && !appState.isStreamOverlayOpen
            ) {
                StreamPlayerView(
                    target: target,
                    authService: appState.authService,
                    gamepadManager: appState.gamepadManager,
                    settings: appState.settings,
                    onDismiss: {
                        appState.isStreamOverlayOpen = false
                        appState.activeStreamTarget = nil
                    }
                )
                .environmentObject(appState)
            }
            .ignoresSafeArea()
        }
        .onReceive(appState.gamepadManager.menuNavigationPublisher) { action in
            guard appState.isAuthenticated, appState.activeStreamTarget == nil else { return }
            switch action {
            case .prevTab:
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTab = (selectedTab + 2) % 3
                }
            case .nextTab:
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTab = (selectedTab + 1) % 3
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadOpenSettings)) { _ in
            guard appState.isAuthenticated, appState.activeStreamTarget == nil else { return }
            selectedTab = 2
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadCheckUpdates)) { _ in
            Task {
                await appState.updateChecker.checkForUpdates(silent: false)
                if let upd = appState.updateChecker.availableUpdate {
                    appState.showToast("发现新版本 v\(upd.version)，可在首页或设置一键下载")
                } else if !appState.updateChecker.lastStatusText.isEmpty {
                    appState.showToast(appState.updateChecker.lastStatusText)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadQuickLaunchConsole)) { _ in
            appState.quickLaunchFirstConsole()
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

#if os(iOS)
/// Real `GCEventViewController` container hosting the entire streaming UI with
/// `controllerUserInteractionEnabled = false`, matching OneCast / Moonlight so iOS/iPadOS
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
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
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
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    func updateRootView(_ rootView: Content) {
        hostingController.rootView = rootView
    }
}
#elseif os(macOS)
/// Native macOS `GCEventViewController` container with `controllerUserInteractionEnabled = false`
/// so controllers & Home button route directly to XboxPad without triggering macOS UI navigation.
private struct StreamEventContainerView<Content: View>: NSViewControllerRepresentable {
    let lockPointer: Bool
    let content: Content

    init(lockPointer: Bool = false, @ViewBuilder content: () -> Content) {
        self.lockPointer = lockPointer
        self.content = content()
    }

    func makeNSViewController(context: Context) -> StreamGCEventNSViewController<Content> {
        StreamGCEventNSViewController(rootView: content, lockPointer: lockPointer)
    }

    func updateNSViewController(_ nsViewController: StreamGCEventNSViewController<Content>, context: Context) {
        nsViewController.controllerUserInteractionEnabled = false
        nsViewController.setPointerLockAllowed(lockPointer)
        nsViewController.updateRootView(content)
    }
}

private final class StreamGCEventNSViewController<Content: View>: GCEventViewController {
    private let hostingController: NSHostingController<Content>
    private var keyEventMonitor: Any?
    private var mouseClickMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var shouldLockPointer: Bool
    private var isPointerLocked = false
    private var isCursorHidden = false

    init(rootView: Content, lockPointer: Bool) {
        self.hostingController = NSHostingController(rootView: rootView)
        self.shouldLockPointer = lockPointer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        applyPointerLock(false)
        removeEventMonitors()
        removeWindowObservers()
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false

        addChild(hostingController)
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.width, .height]
        view.addSubview(hostingController.view)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        controllerUserInteractionEnabled = false
        installEventMonitors()
        installWindowObservers()
        if shouldLockPointer, let win = view.window, win.isKeyWindow, win.attachedSheet == nil {
            applyPointerLock(true)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        applyPointerLock(false)
        removeEventMonitors()
        removeWindowObservers()
    }

    func setPointerLockAllowed(_ allowed: Bool) {
        shouldLockPointer = allowed
        if !allowed {
            applyPointerLock(false)
        } else if let win = view.window, win.isKeyWindow, NSApp.isActive, win.attachedSheet == nil {
            applyPointerLock(true)
        }
    }

    private func applyPointerLock(_ locked: Bool) {
        guard isPointerLocked != locked else { return }
        isPointerLocked = locked
        CGAssociateMouseAndMouseCursorPosition(locked ? 0 : 1)
        if locked && !isCursorHidden {
            NSCursor.hide()
            isCursorHidden = true
        } else if !locked && isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
    }

    /// Consume regular gameplay keystrokes in AppKit's responder chain so macOS never plays
    /// the unhandled-key system alert beep ("嘟嘟嘟") while GCKeyboard delivers raw keys to Xbox.
    /// Also manages true FPS mouse lock/unlock (click canvas to lock, Esc to release cursor + open bar).
    private func installEventMonitors() {
        if keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let win = self.view.window, win.isKeyWindow else {
                    return event
                }
                if event.modifierFlags.contains(.command) {
                    return event
                }
                if win.attachedSheet != nil || win.firstResponder is NSTextView {
                    return event
                }
                // Esc while pointer is locked releases cursor cleanly & opens top bar
                if event.type == .keyDown && event.keyCode == 53 && self.isPointerLocked {
                    self.applyPointerLock(false)
                    NotificationCenter.default.post(name: .xboxpadToggleOverlay, object: nil)
                    return nil
                }
                return nil
            }
        }

        if mouseClickMonitor == nil {
            mouseClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self,
                      self.shouldLockPointer,
                      !self.isPointerLocked,
                      let win = self.view.window,
                      event.window === win,
                      win.isKeyWindow,
                      win.attachedSheet == nil else {
                    return event
                }
                let locInView = self.view.convert(event.locationInWindow, from: nil)
                // Keep top 54pt zone clickable for opening the overlay bar without relocking
                let distFromTop = self.view.bounds.maxY - locInView.y
                if self.view.bounds.contains(locInView) && distFromTop > 54 {
                    self.applyPointerLock(true)
                }
                return event
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = mouseClickMonitor {
            NSEvent.removeMonitor(monitor)
            mouseClickMonitor = nil
        }
    }

    private func installWindowObservers() {
        removeWindowObservers()
        let nc = NotificationCenter.default
        let releaseNames: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
        ]
        for name in releaseNames {
            windowObservers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.applyPointerLock(false)
                }
            )
        }
    }

    private func removeWindowObservers() {
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowObservers.removeAll()
    }

    func updateRootView(_ rootView: Content) {
        hostingController.rootView = rootView
    }
}
#endif
