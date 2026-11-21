import AVKit
import SwiftUI
import UIKit

/// Manages external displays (USB-C / HDMI / AirPlay Extended Display) and detects AirPlay Screen Mirroring.
/// When a stream is active and `fullscreenEnabled` is true on a dedicated external screen,
/// the H.264/Metal/HDR renderer attaches directly to the external 16:9 display (zero black bars!)
/// while the iPad screen becomes a clean control dashboard with an optional OLED power-save dimmer.
@MainActor
final class ExternalDisplayManager: ObservableObject {
    static let shared = ExternalDisplayManager()

    @Published private(set) var hasExternalScene: Bool = false
    @Published private(set) var isScreenMirrored: Bool = false
    @Published private(set) var externalResolutionText: String = ""
    @Published private(set) var externalRefreshHz: Int = 60
    @Published private(set) var externalEDRHeadroom: CGFloat = 1.0

    @Published var isExternalOutputEnabled: Bool = true {
        didSet {
            syncExternalWindowVisibility()
        }
    }

    @Published private(set) var activeRenderer: H264StreamRenderer?
    @Published private(set) var activeHDRMode: VideoHDRToneMode = .off
    @Published private(set) var activeStreamTitle: String = ""

    /// True when the video renderer is currently routed to the dedicated external TV/monitor.
    var isRenderingExternally: Bool {
        hasExternalScene && isExternalOutputEnabled && activeRenderer != nil
    }

    private weak var externalWindow: UIWindow?
    private weak var externalScreen: UIScreen?
    private var screenObservers: [NSObjectProtocol] = []

    private init() {
        observeScreens()
        refreshScreenState()
    }

    func bindStream(
        renderer: H264StreamRenderer,
        title: String,
        hdrToneMode: VideoHDRToneMode,
        fullscreenEnabled: Bool
    ) {
        activeRenderer = renderer
        activeStreamTitle = title
        activeHDRMode = hdrToneMode
        isExternalOutputEnabled = fullscreenEnabled
        refreshScreenState()
        syncExternalWindowVisibility()
    }

    func updateStreamHDR(_ mode: VideoHDRToneMode) {
        activeHDRMode = mode
    }

    func unbindStream(renderer: H264StreamRenderer) {
        guard activeRenderer === renderer else { return }
        activeRenderer = nil
        activeStreamTitle = ""
        syncExternalWindowVisibility()
    }

    func registerExternalWindow(_ window: UIWindow, screen: UIScreen) {
        externalWindow = window
        externalScreen = screen
        hasExternalScene = true
        updateScreenMetrics(screen)
        syncExternalWindowVisibility()
    }

    func unregisterExternalWindow(_ window: UIWindow) {
        if externalWindow === window {
            externalWindow = nil
            externalScreen = nil
        }
        hasExternalScene = false
        refreshScreenState()
    }

    private func updateScreenMetrics(_ screen: UIScreen) {
        let px = screen.nativeBounds.size
        let w = Int(max(px.width, px.height))
        let h = Int(min(px.width, px.height))
        externalResolutionText = "\(w)×\(h)"
        externalRefreshHz = max(screen.maximumFramesPerSecond, 60)
        externalEDRHeadroom = screen.potentialEDRHeadroom
    }

    private func syncExternalWindowVisibility() {
        externalWindow?.isHidden = !hasExternalScene
    }

    private func observeScreens() {
        let nc = NotificationCenter.default
        screenObservers.append(
            nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshScreenState() }
            }
        )
        screenObservers.append(
            nc.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshScreenState() }
            }
        )
        screenObservers.append(
            nc.addObserver(forName: UIScreen.modeDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshScreenState() }
            }
        )
    }

    func refreshScreenState() {
        let screens = UIScreen.screens
        if let ext = externalScreen {
            updateScreenMetrics(ext)
            isScreenMirrored = (ext.mirrored != nil)
        } else if screens.count > 1, let secondary = screens.first(where: { $0 != UIScreen.main }) {
            updateScreenMetrics(secondary)
            isScreenMirrored = (secondary.mirrored != nil) || !hasExternalScene
        } else {
            isScreenMirrored = false
            if !hasExternalScene {
                externalResolutionText = ""
                externalRefreshHz = 60
                externalEDRHeadroom = 1.0
            }
        }
    }
}

/// Official iPadOS `UIWindowSceneSessionRoleExternalDisplayNonInteractive` delegate.
/// Automatically powers USB-C / HDMI / AirPlay Extended displays at native full-screen 16:9.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let win = UIWindow(windowScene: windowScene)
        win.backgroundColor = .black
        let rootVC = UIHostingController(rootView: ExternalDisplayRootView())
        rootVC.view.backgroundColor = .black
        win.rootViewController = rootVC
        win.isHidden = false
        self.window = win
        ExternalDisplayManager.shared.registerExternalWindow(win, screen: windowScene.screen)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let win = window {
            ExternalDisplayManager.shared.unregisterExternalWindow(win)
        }
        window = nil
    }
}

private struct ExternalDisplayRootView: View {
    @ObservedObject private var manager = ExternalDisplayManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if manager.isRenderingExternally, let renderer = manager.activeRenderer {
                // Native 16:9 external display output: fills 16:9 TV/Monitor completely with zero distortion
                VideoDecoderView(
                    renderer: renderer,
                    aspectMode: .fit,
                    hdrToneMode: manager.activeHDRMode
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "xbox.logo")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(XboxTheme.emeraldBright)
                    Text("XboxPad 外接屏投屏已就绪")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(
                        manager.activeRenderer != nil
                            ? "当前为本机显示模式，可在 iPad 顶栏「投屏」中一键切回外接屏全屏"
                            : "在 iPad 上开始主机或云游戏串流后，画面将自动在此屏幕全屏输出"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                }
                .padding(32)
            }
        }
    }
}

/// Native Apple AirPlay route picker (Apple TV / AirPlay TV / HomePod / Bluetooth Audio).
struct AirPlayRoutePickerView: UIViewRepresentable {
    var tintColor: UIColor = .white
    var activeTintColor: UIColor = UIColor(red: 0.14, green: 0.86, blue: 0.45, alpha: 1.0)

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
