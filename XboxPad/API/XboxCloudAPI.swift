import Foundation

enum XboxCloudAPIError: LocalizedError {
    case httpError(Int, String)
    case emptyLibrary

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let detail):
            return "云游戏库请求失败 (HTTP \(status))：\(detail)"
        case .emptyLibrary:
            return "未获取到云游戏列表，请尝试在右上角切换「日本 / 韩国 / 美国」跨区节点后刷新。"
        }
    }
}

enum XboxCloudAPI {
    private struct V2TitleEntry {
        let titleId: String
        let productId: String
    }

    static func fetchCloudGames(
        baseUri: String,
        gsToken: String,
        preferredLanguage: String,
        market: String = "US",
        forwardedIP: String = ""
    ) async throws -> [CloudGame] {
        let trimmed = baseUri.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        async let allTitlesTask = fetchV2Titles(
            urlString: "\(trimmed)/v2/titles",
            gsToken: gsToken,
            forwardedIP: forwardedIP
        )
        async let recentTitlesTask = fetchV2Titles(
            urlString: "\(trimmed)/v2/titles/mru?mr=25",
            gsToken: gsToken,
            forwardedIP: forwardedIP
        )

        let (allResult, recentResult) = await (allTitlesTask, recentTitlesTask)
        let allEntries = allResult.entries
        let recentEntries = recentResult.entries
        let recentProductIds = Set(recentEntries.map(\.productId))

        var titleIdByProduct: [String: String] = [:]
        var orderedProductIds: [String] = []
        for entry in recentEntries + allEntries {
            if titleIdByProduct[entry.productId] == nil {
                titleIdByProduct[entry.productId] = entry.titleId
                orderedProductIds.append(entry.productId)
            }
        }

        // If /v2/titles returned empty (e.g. geo-edge hiccup), fall back to official public xCloud SIGL catalog
        let normalizedMarket = market.isEmpty ? "US" : market.uppercased()
        if orderedProductIds.isEmpty {
            let publicIds = await fetchPublicCloudProductIds(market: normalizedMarket)
            if !publicIds.isEmpty {
                orderedProductIds = publicIds
            } else if let err = allResult.error {
                throw err
            } else {
                throw XboxCloudAPIError.emptyLibrary
            }
        }

        let catalogLang = preferredLanguage.lowercased().contains("zh") ? "zh-TW" : "en-US"
        let chunks = stride(from: 0, to: orderedProductIds.count, by: 100).map {
            Array(orderedProductIds[$0..<min($0 + 100, orderedProductIds.count)])
        }

        var games: [CloudGame] = []
        await withTaskGroup(of: [CloudGame].self) { group in
            for chunk in chunks {
                group.addTask {
                    await fetchCatalogChunk(
                        productIds: chunk,
                        titleIdByProduct: titleIdByProduct,
                        recentProductIds: recentProductIds,
                        language: catalogLang,
                        market: normalizedMarket
                    )
                }
            }
            for await batch in group {
                games.append(contentsOf: batch)
            }
        }

        var seen = Set<String>()
        let unique = games.filter { seen.insert($0.productId).inserted }
        if unique.isEmpty {
            throw XboxCloudAPIError.emptyLibrary
        }
        return unique.sorted { lhs, rhs in
            if lhs.isRecent != rhs.isRecent {
                return lhs.isRecent
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func fetchV2Titles(
        urlString: String,
        gsToken: String,
        forwardedIP: String
    ) async -> (entries: [V2TitleEntry], error: Error?) {
        guard let url = URL(string: urlString) else { return ([], nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")
        if !forwardedIP.isEmpty {
            request.setValue(forwardedIP, forHTTPHeaderField: "X-Forwarded-For")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let preview = String((String(data: data, encoding: .utf8) ?? "").prefix(160))
                return ([], XboxCloudAPIError.httpError(status, preview))
            }
            let raw = try JSONSerialization.jsonObject(with: data)
            let list: [[String: Any]]
            if let arr = raw as? [[String: Any]] {
                list = arr
            } else if let dict = raw as? [String: Any], let results = dict["results"] as? [[String: Any]] {
                list = results
            } else {
                return ([], nil)
            }

            let entries: [V2TitleEntry] = list.compactMap { item in
                let titleId = (item["titleId"] as? String) ?? ""
                let details = item["details"] as? [String: Any]
                let productId = (details?["productId"] as? String) ?? (item["productId"] as? String) ?? ""
                guard !titleId.isEmpty, !productId.isEmpty else { return nil }
                return V2TitleEntry(titleId: titleId, productId: productId)
            }
            return (entries, nil)
        } catch {
            return ([], error)
        }
    }

    private static func fetchPublicCloudProductIds(market: String) async -> [String] {
        guard let url = URL(
            string: "https://catalog.gamepass.com/sigls/v2?id=29a81209-df6f-41fd-a528-2ae6b91f719c&language=en-us&market=\(market)"
        ) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0["id"] as? String }
    }

    private static func fetchCatalogChunk(
        productIds: [String],
        titleIdByProduct: [String: String],
        recentProductIds: Set<String>,
        language: String,
        market: String
    ) async -> [CloudGame] {
        guard !productIds.isEmpty,
              let url = URL(string: "https://catalog.gamepass.com/v3/products?market=\(market)&language=\(language)&hydration=RemoteLowJade0") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0", forHTTPHeaderField: "ms-cv")
        request.setValue("Xbox Cloud Gaming Web", forHTTPHeaderField: "calling-app-name")
        request.setValue("24.17.63", forHTTPHeaderField: "calling-app-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["Products": productIds])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = json["Products"] as? [String: [String: Any]] else {
            return []
        }

        var result: [CloudGame] = []
        for (productId, info) in products {
            let titleId = titleIdByProduct[productId]
                ?? (info["XCloudTitleId"] as? String)
                ?? (info["XboxTitleId"] as? String)
                ?? ""
            guard !titleId.isEmpty else { continue }
            let title = (info["ProductTitle"] as? String) ?? titleId
            let publisher = (info["PublisherName"] as? String) ?? ""

            let tileURL = normalizeImageURL((info["Image_Tile"] as? [String: Any])?["URL"] as? String)
            let posterURL = normalizeImageURL((info["Image_Poster"] as? [String: Any])?["URL"] as? String)

            result.append(CloudGame(
                productId: productId,
                titleId: titleId,
                title: title,
                publisher: publisher,
                tileImageURL: tileURL,
                posterImageURL: posterURL,
                isRecent: recentProductIds.contains(productId)
            ))
        }
        return result
    }

    private static func normalizeImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("//") {
            return URL(string: "https:\(raw)")
        }
        return URL(string: "https://\(raw)")
    }
}
