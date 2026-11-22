import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct AppUpdateInfo: Equatable, Sendable {
    let version: String
    let buildVersion: String
    let changelog: String
    let releaseDate: String
    let macDownloadURL: URL
    let sideStoreURL: URL
}

/// Checks `https://xbox.lynkco.site/source.json` for newer XboxPad releases.
/// Especially useful for macOS `.dmg` installs (where SideStore OTA does not apply),
/// and also available manually on iPad/iPhone.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let sourceURL = URL(string: "https://xbox.lynkco.site/source.json")!
    static let macDmgLatestURL = URL(string: "https://xbox.lynkco.site/XboxPad-macOS-latest.dmg")!
    static let websiteURL = URL(string: "https://xbox.lynkco.site")!

    @Published private(set) var isChecking = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var availableUpdate: AppUpdateInfo?
    @Published private(set) var lastStatusText: String = ""

    private struct SourceManifest: Decodable {
        struct AppEntry: Decodable {
            struct VersionEntry: Decodable {
                let version: String
                let buildVersion: String?
                let date: String?
                let localizedDescription: String?
            }
            let version: String
            let versionDate: String?
            let versionDescription: String?
            let versions: [VersionEntry]?
        }
        let apps: [AppEntry]
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        if !silent {
            lastStatusText = "正在检查最新版本..."
        }
        defer { isChecking = false }

        do {
            var req = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if !silent { lastStatusText = "检查更新失败（服务器无响应）" }
                return
            }
            let manifest = try JSONDecoder().decode(SourceManifest.self, from: data)
            guard let app = manifest.apps.first else {
                if !silent { lastStatusText = "未找到版本清单" }
                return
            }

            let remoteVer = app.version
            let remoteBuild = app.versions?.first?.buildVersion ?? ""
            let localVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
            let localBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

            if Self.isRemoteNewer(remoteVer: remoteVer, remoteBuild: remoteBuild, localVer: localVer, localBuild: localBuild) {
                let info = AppUpdateInfo(
                    version: remoteVer,
                    buildVersion: remoteBuild,
                    changelog: app.versionDescription ?? app.versions?.first?.localizedDescription ?? "包含画质、操控与稳定性优化。",
                    releaseDate: app.versionDate ?? app.versions?.first?.date ?? "",
                    macDownloadURL: Self.macDmgLatestURL,
                    sideStoreURL: URL(string: "sidestore://source?url=https://xbox.lynkco.site/source.json") ?? Self.websiteURL
                )
                availableUpdate = info
                lastStatusText = "发现新版本 v\(remoteVer)\(remoteBuild.isEmpty ? "" : " (Build \(remoteBuild))")"
            } else {
                availableUpdate = nil
                if !silent {
                    lastStatusText = "已是最新版本 (v\(localVer))"
                }
            }
        } catch {
            if !silent {
                lastStatusText = "检查更新失败：\(error.localizedDescription)"
            }
        }
    }

    func openUpdateDownload() {
        #if os(macOS)
        Task { await downloadAndOpenMacUpdate() }
        #elseif os(iOS)
        let url = availableUpdate?.sideStoreURL ?? Self.websiteURL
        UIApplication.shared.open(url)
        #endif
    }

    #if os(macOS)
    /// Downloads the latest macOS DMG directly inside XboxPad into ~/Downloads with live progress
    /// and immediately opens/mounts it in Finder so upgrading is truly 1-click.
    func downloadAndOpenMacUpdate() async {
        guard !isDownloadingUpdate else { return }
        let targetURL = availableUpdate?.macDownloadURL ?? Self.macDmgLatestURL
        let verSuffix = availableUpdate?.version ?? "latest"
        isDownloadingUpdate = true
        downloadProgress = 0.02
        lastStatusText = "正在应用内下载 XboxPad-\(verSuffix)-macOS.dmg..."
        defer { isDownloadingUpdate = false }

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(from: targetURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                NSWorkspace.shared.open(targetURL)
                lastStatusText = "已转为浏览器下载更新包"
                return
            }
            let expected = max(response.expectedContentLength, 1)
            let fm = FileManager.default
            let downloadsDir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            let destURL = downloadsDir.appendingPathComponent("XboxPad-\(verSuffix)-macOS.dmg")
            try? fm.removeItem(at: destURL)
            fm.createFile(atPath: destURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destURL)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(128 * 1024)
            var received: Int64 = 0
            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 128 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 1 {
                        downloadProgress = min(Double(received) / Double(expected), 0.99)
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            downloadProgress = 1.0
            lastStatusText = "更新包已下载至「下载」文件夹，正在自动打开安装镜像..."
            NSWorkspace.shared.open(destURL)
        } catch {
            lastStatusText = "应用内下载失败，已改用浏览器下载"
            NSWorkspace.shared.open(targetURL)
        }
    }
    #endif

    private static func isRemoteNewer(remoteVer: String, remoteBuild: String, localVer: String, localBuild: String) -> Bool {
        let rParts = remoteVer.split(separator: ".").compactMap { Int($0) }
        let lParts = localVer.split(separator: ".").compactMap { Int($0) }
        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let rv = i < rParts.count ? rParts[i] : 0
            let lv = i < lParts.count ? lParts[i] : 0
            if rv != lv { return rv > lv }
        }
        if let rb = Int(remoteBuild), let lb = Int(localBuild), rb != lb {
            return rb > lb
        }
        return false
    }
}
