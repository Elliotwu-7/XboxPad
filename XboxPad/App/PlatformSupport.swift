import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
import UIKit
#elseif os(macOS)
import AppKit
import IOKit.pwr_mgt
#endif

/// Centralized cross-platform bridge so XboxPad runs natively on iPadOS, iPhone (iOS), and macOS
/// (Apple Silicon & Intel) while sharing 100% of its RustCore, Metal, MetalFX, and SwiftUI layers.
enum XboxPlatform {
    static var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static var deviceDisplayName: String {
        #if os(macOS)
        return "Mac"
        #else
        return isPhone ? "iPhone" : "iPad"
        #endif
    }

    @MainActor
    static var localDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    static func copyToClipboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #endif
    }

    static func readClipboard() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #endif
    }

    static func clearClipboard() {
        #if os(iOS)
        UIPasteboard.general.string = ""
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        #endif
    }

    @MainActor
    static var potentialEDRHeadroom: CGFloat {
        #if os(iOS)
        return UIScreen.main.potentialEDRHeadroom
        #elseif os(macOS)
        return NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        #endif
    }

    @MainActor
    static func openSystemControllerSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    #if os(macOS)
    @MainActor private static var sleepAssertionID: IOPMAssertionID = 0
    @MainActor private static var hasSleepAssertion: Bool = false
    #endif

    @MainActor
    static func setIdleSleepDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #elseif os(macOS)
        if disabled {
            guard !hasSleepAssertion else { return }
            let reason = "XboxPad active game stream" as CFString
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &sleepAssertionID
            )
            if rc == kIOReturnSuccess {
                hasSleepAssertion = true
            }
        } else if hasSleepAssertion {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
            hasSleepAssertion = false
        }
        #endif
    }

    /// On iPhone, automatically rotate into landscape when a game stream begins, and restore
    /// portrait/all orientations cleanly when exiting the stream.
    @MainActor
    static func setPreferredLandscapeForStreaming(_ landscape: Bool) {
        #if os(iOS)
        guard isPhone else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .allButUpsideDown
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(prefs) { _ in }
        #endif
    }

    #if os(macOS)
    @MainActor
    static func toggleWindowFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
    #endif

    /// Save a lossless PNG screenshot from the decoded CGImage:
    /// - iOS / iPadOS: writes directly to Photos library.
    /// - macOS: writes PNG directly to `~/Pictures/XboxPad/XboxPad-YYYYMMDD-HHmmss.png`.
    static func savePNGScreenshot(
        _ cgImage: CGImage,
        completion: @escaping @Sendable (Bool, String) -> Void
    ) {
        let w = cgImage.width
        let h = cgImage.height

        #if os(iOS)
        let image = UIImage(cgImage: cgImage)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "请在系统设置中允许 XboxPad 写入相册")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if success {
                    completion(true, "原画截屏已存入相册 (\(w)×\(h))")
                } else {
                    completion(false, "截屏保存失败：\(error?.localizedDescription ?? "未知错误")")
                }
            }
        }
        #elseif os(macOS)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let baseDir = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser
            let outDir = baseDir.appendingPathComponent("XboxPad", isDirectory: true)
            do {
                try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            } catch {
                completion(false, "无法创建截屏目录：\(error.localizedDescription)")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let filename = "XboxPad-\(formatter.string(from: Date())).png"
            let outURL = outDir.appendingPathComponent(filename)
            guard let dest = CGImageDestinationCreateWithURL(
                outURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                completion(false, "无法创建 PNG 截屏文件")
                return
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            if CGImageDestinationFinalize(dest) {
                completion(true, "原画截屏已存至 图片/XboxPad (\(w)×\(h))")
            } else {
                completion(false, "PNG 截屏写入失败")
            }
        }
        #endif
    }
}

extension View {
    @ViewBuilder
    func xboxNoAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func xboxInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func xboxHideSystemChrome() -> some View {
        #if os(iOS)
        self
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func xboxStreamPresentation<Item: Identifiable, StreamContent: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> StreamContent
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #elseif os(macOS)
        ZStack {
            self
                .opacity(item.wrappedValue == nil ? 1 : 0)
                .allowsHitTesting(item.wrappedValue == nil)
            if let active = item.wrappedValue {
                content(active)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        #endif
    }
}
