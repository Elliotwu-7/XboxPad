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
        NSWorkspace.shared.open(availableUpdate?.macDownloadURL ?? Self.macDmgLatestURL)
        #elseif os(iOS)
        let url = availableUpdate?.sideStoreURL ?? Self.websiteURL
        UIApplication.shared.open(url)
        #endif
    }

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
