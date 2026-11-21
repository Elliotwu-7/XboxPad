import SwiftUI

struct CloudGamesView: View {
    @EnvironmentObject var appState: AppState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegularLayout: Bool { hSizeClass == .regular }
    #else
    private var isRegularLayout: Bool { true }
    #endif
    @State private var searchText = ""
    @State private var filterRecentOnly = false

    private var columns: [GridItem] {
        if isRegularLayout {
            return [GridItem(.adaptive(minimum: 185, maximum: 230), spacing: 16)]
        }
        return [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]
    }

    private var recentCount: Int {
        appState.cloudGames.filter(\.isRecent).count
    }

    private var filteredGames: [CloudGame] {
        appState.cloudGames.filter { game in
            if filterRecentOnly && !game.isRecent {
                return false
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            return game.title.localizedCaseInsensitiveContains(q)
                || game.publisher.localizedCaseInsensitiveContains(q)
        }
    }

    private var activeRegionLabel: String {
        if !appState.settings.selectedCloudRegion.isEmpty {
            return appState.settings.selectedCloudRegion
        }
        if let preset = CloudRegionPreset.presets.first(where: { $0.ip == appState.settings.forceRegionIP }),
           !preset.ip.isEmpty {
            return preset.name
        }
        return "自动节点"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                XboxAmbientBackground(intensity: 0.9)

                VStack(spacing: 0) {
                    filterToolbar

                    if appState.isLoadingCloudGames && appState.cloudGames.isEmpty {
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(XboxTheme.emerald)
                            Text("正在拉取 Xbox Cloud Gaming 游戏库...")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = appState.cloudError, appState.cloudGames.isEmpty {
                        cloudErrorState(err)
                    } else if filteredGames.isEmpty {
                        emptySearchState
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(filteredGames) { game in
                                    gameCard(game)
                                }
                            }
                            .padding(.horizontal, isRegularLayout ? 24 : 16)
                            .padding(.top, 8)
                            .padding(.bottom, 28)
                        }
                        .refreshable {
                            await appState.refreshCloudGames()
                        }
                    }
                }
            }
            .navigationTitle("xCloud 云游戏")
            .searchable(text: $searchText, prompt: "搜索游戏名称或发行商")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await appState.refreshCloudGames() }
                    } label: {
                        if appState.isLoadingCloudGames {
                            ProgressView()
                                .tint(XboxTheme.emerald)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            filterPill(
                title: "全部游戏",
                count: appState.cloudGames.count,
                selected: !filterRecentOnly
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { filterRecentOnly = false }
            }

            filterPill(
                title: "最近游玩",
                count: recentCount,
                selected: filterRecentOnly
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { filterRecentOnly = true }
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(CloudRegionPreset.presets) { preset in
                    Button {
                        appState.settings.forceRegionIP = preset.ip
                        appState.settings.selectedCloudRegion = ""
                        Task { await appState.refreshCloudGames(forceRefresh: true) }
                    } label: {
                        if appState.settings.forceRegionIP == preset.ip {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(XboxTheme.info)
                    Text(activeRegionLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.8))
            }
        }
        .padding(.horizontal, isRegularLayout ? 24 : 16)
        .padding(.vertical, 10)
    }

    private func filterPill(title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selected ? Color.black.opacity(0.25) : Color.white.opacity(0.10), in: Capsule())
            }
            .foregroundStyle(selected ? .white : .secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(selected ? AnyShapeStyle(XboxTheme.primaryGradient) : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(
                Capsule()
                    .stroke(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func gameCard(_ game: CloudGame) -> some View {
        Button {
            appState.activeStreamTarget = .cloud(game)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: game.tileImageURL ?? game.posterImageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholderCover
                        default:
                            placeholderCover.overlay(
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(XboxTheme.emerald)
                            )
                        }
                    }
                    .frame(height: 152)
                    .frame(maxWidth: .infinity)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, .clear, Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    if game.isRecent {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 9))
                            Text("最近")
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(XboxTheme.primaryGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                        .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 36, alignment: .topLeading)

                    HStack {
                        Text(game.publisher.isEmpty ? "Xbox Cloud Gaming" : game.publisher)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(XboxTheme.emeraldBright.opacity(0.85))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .xboxCard(cornerRadius: 16)
        }
        .buttonStyle(CloudCardButtonStyle())
    }

    private func cloudErrorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            XboxIconBadge(systemName: "cloud.slash.fill", color: XboxTheme.warning, size: 56)
            Text("云游戏暂不可用")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button {
                    appState.settings.forceRegionIP = "133.130.100.1"
                    appState.settings.selectedCloudRegion = ""
                    Task { await appState.refreshCloudGames(forceRefresh: true) }
                } label: {
                    Label("切日本节点重试", systemImage: "globe.asia.australia.fill")
                }
                .buttonStyle(XboxPrimaryButtonStyle(compact: true))

                Button("刷新重试") {
                    Task { await appState.refreshCloudGames(forceRefresh: true) }
                }
                .buttonStyle(XboxSecondaryButtonStyle(compact: true))
            }
            .padding(.top, 4)
        }
        .padding(28)
        .xboxCard(cornerRadius: 20, fill: XboxTheme.surfaceMuted)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySearchState: some View {
        VStack(spacing: 12) {
            XboxIconBadge(systemName: "magnifyingglass", color: .secondary, size: 50)
            Text(filterRecentOnly ? "暂无最近游玩记录" : "未找到匹配的云游戏")
                .font(.headline)
                .foregroundStyle(.white)
            Text(filterRecentOnly ? "开始任意云游戏后，会在这里快速显示。" : "换个关键词试试，或切换到「全部游戏」查看完整列表。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderCover: some View {
        LinearGradient(
            colors: [XboxTheme.surfaceElevated, XboxTheme.surfaceMuted],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.18))
        )
    }
}

private struct CloudCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
