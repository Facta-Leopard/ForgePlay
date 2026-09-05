import SwiftUI

private enum DeveloperAppsTab: String, CaseIterable, Identifiable {
    case appCatalog
    case inDevelopment

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .appCatalog: "앱 카탈로그"
        case .inDevelopment: "개발 중"
        }
    }

    var systemImage: String {
        switch self {
        case .appCatalog: "rectangle.3.group"
        case .inDevelopment: "hammer.fill"
        }
    }
}

struct DeveloperAppsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: DeveloperAppsTab = .appCatalog
    @State private var selectedPlatform: DeveloperAppPlatform = .mac
    @State private var searchText = ""

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var platformListings: [DeveloperAppListing] {
        DeveloperAppCatalog.listings(for: selectedPlatform)
    }

    private var visibleListings: [DeveloperAppListing] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return platformListings }

        return platformListings.filter { listing in
            listing.name.localizedCaseInsensitiveContains(query) ||
                appState.localized(listing.summaryKey).localizedCaseInsensitiveContains(query) ||
                appState.localized(listing.kind.titleKey).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ForgePageScaffold(
            "제작자의 다른 앱",
            subtitle: "출시된 앱과 곧 출시될 프로젝트, 개발 중인 프로젝트를 살펴보세요.",
            systemImage: "square.grid.3x3.square"
        ) {
            SectionHelpButton(section: .developerApps)
        } content: {
            tabPicker

            switch selectedTab {
            case .appCatalog:
                appCatalogContent
            case .inDevelopment:
                inDevelopmentGrid
            }
        }
    }

    private var tabPicker: some View {
        Picker(appState.localized("제작자의 다른 앱 보기"), selection: $selectedTab) {
            ForEach(DeveloperAppsTab.allCases) { tab in
                Label(appState.localized(tab.titleKey), systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityLabel(appState.localized("제작자의 다른 앱 보기"))
        .onChange(of: selectedTab) { _, _ in
            searchText = ""
        }
    }

    @ViewBuilder
    private var appCatalogContent: some View {
        upcomingProjectsSection
        catalogControls

        if platformListings.isEmpty {
            emptyPlatformCard
        } else if visibleListings.isEmpty {
            emptySearchCard
        } else {
            appGrid
        }
    }

    private var upcomingProjectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(appState.localized("출시 예정"), systemImage: "calendar.badge.clock")
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.text)

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 340, maximum: 520),
                        spacing: ForgePlayLayout.sectionSpacing,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: ForgePlayLayout.sectionSpacing
            ) {
                ForEach(DeveloperAppCatalog.upcomingListings) { listing in
                    DeveloperUpcomingProjectCard(listing: listing)
                }
            }
        }
    }

    private var inDevelopmentGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 220, maximum: 320),
                    spacing: ForgePlayLayout.sectionSpacing,
                    alignment: .top
                )
            ],
            alignment: .leading,
            spacing: ForgePlayLayout.sectionSpacing
        ) {
            ForEach(DeveloperAppCatalog.inDevelopmentListings) { listing in
                DeveloperInDevelopmentProjectTile(listing: listing)
            }
        }
    }

    private var catalogControls: some View {
        ForgeCard("앱 카탈로그", systemImage: "rectangle.3.group") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    platformPicker
                    Spacer(minLength: 20)
                    searchField
                }
                VStack(alignment: .leading, spacing: 12) {
                    platformPicker
                    searchField
                }
            }

            Text(appState.localizedFormat("%d개의 앱", visibleListings.count))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .contentTransition(.numericText())
        }
    }

    private var platformPicker: some View {
        Picker(appState.localized("플랫폼"), selection: $selectedPlatform) {
            ForEach(DeveloperAppPlatform.allCases) { platform in
                Label(
                    appState.localized(platform.titleKey),
                    systemImage: platform.systemImage
                )
                .tag(platform)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 320, idealWidth: 440, maxWidth: 520)
        .accessibilityLabel(appState.localized("플랫폼"))
        .onChange(of: selectedPlatform) { _, _ in
            searchText = ""
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            TextField(appState.localized("앱 이름 검색"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(appState.localized("검색 지우기"))
                .accessibilityLabel(appState.localized("검색 지우기"))
            }
        }
        .padding(.horizontal, 11)
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 340, minHeight: 36)
        .background(palette.control)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.controlCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.controlCornerRadius,
                style: .continuous
            )
            .stroke(palette.border, lineWidth: 1)
        }
    }

    private var appGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 340, maximum: 520),
                    spacing: ForgePlayLayout.sectionSpacing,
                    alignment: .top
                )
            ],
            alignment: .leading,
            spacing: ForgePlayLayout.sectionSpacing
        ) {
            ForEach(visibleListings) { listing in
                DeveloperAppCard(listing: listing)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: visibleListings.map(\.id))
    }

    private var emptyPlatformCard: some View {
        emptyStateCard(
            title: "이 플랫폼에 등록된 앱이 아직 없습니다.",
            detail: "새 앱 링크가 추가되면 이곳에 표시됩니다.",
            systemImage: selectedPlatform.systemImage
        )
    }

    private var emptySearchCard: some View {
        emptyStateCard(
            title: "검색 결과가 없습니다.",
            detail: "다른 검색어를 입력하거나 플랫폼을 바꿔 보세요.",
            systemImage: "magnifyingglass"
        )
    }

    private func emptyStateCard(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        ForgeCard {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .accessibilityHidden(true)
                Text(appState.localized(title))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                Text(appState.localized(detail))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

private struct DeveloperUpcomingProjectCard: View {
    var listing: DeveloperProjectListing
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        ForgeCard {
            HStack(alignment: .top, spacing: 14) {
                DeveloperProjectArtwork(
                    name: listing.name,
                    artworkAssetName: listing.artworkAssetName,
                    size: 74
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(listing.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)

                    DeveloperAppBadge(
                        title: appState.localized("조만간 출시 예정"),
                        systemImage: "clock.fill",
                        foregroundColor: palette.primary,
                        backgroundColor: palette.primary.opacity(0.10)
                    )

                    if let summaryKey = listing.summaryKey {
                        Text(appState.localized(summaryKey))
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct DeveloperInDevelopmentProjectTile: View {
    var listing: DeveloperProjectListing
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        ForgeCard {
            VStack(spacing: 14) {
                DeveloperProjectArtwork(
                    name: listing.name,
                    artworkAssetName: listing.artworkAssetName,
                    size: 96
                )
                Text(listing.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, minHeight: 154)
        }
    }
}

private struct DeveloperAppCard: View {
    var listing: DeveloperAppListing
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var supportedLanguagesText: String {
        listing.supportedLanguages
            .map { appState.localized($0.titleKey) }
            .joined(separator: " · ")
    }

    var body: some View {
        ForgeCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 14) {
                    DeveloperAppArtwork(
                        name: listing.name,
                        artworkURL: listing.artworkURL
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text(listing.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(palette.text)
                            .textSelection(.enabled)

                        HStack(spacing: 6) {
                            DeveloperAppBadge(
                                title: appState.localized(listing.platform.titleKey),
                                systemImage: listing.platform.systemImage,
                                foregroundColor: palette.primary,
                                backgroundColor: palette.primary.opacity(0.10)
                            )

                            if listing.kind == .game {
                                DeveloperAppBadge(
                                    title: appState.localized(listing.kind.titleKey),
                                    systemImage: listing.kind.systemImage,
                                    foregroundColor: palette.warning,
                                    backgroundColor: palette.warning.opacity(0.12)
                                )
                            }
                        }

                        ForEach(listing.compatibilities) { compatibility in
                            DeveloperAppBadge(
                                title: appState.localized(compatibility.titleKey),
                                systemImage: compatibility.systemImage,
                                foregroundColor: palette.secondary,
                                backgroundColor: palette.secondary.opacity(0.12)
                            )
                            .help(appState.localized(compatibility.detailKey))
                        }
                    }

                    Spacer(minLength: 0)
                }

                Text(appState.localized(listing.summaryKey))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text(appState.localized("지원 언어"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(supportedLanguagesText)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ThemedActionButton(
                    title: "App Store에서 보기",
                    systemImage: "arrow.up.right.square",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.openExternalURL(listing.appStoreURL)
                }
            }
        }
    }
}

private struct DeveloperAppBadge: View {
    var title: String
    var systemImage: String
    var foregroundColor: Color
    var backgroundColor: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .clipShape(Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DeveloperAppArtwork: View {
    var name: String
    var artworkURL: URL?
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        AsyncImage(url: artworkURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
            switch phase {
            case .empty:
                ZStack {
                    placeholder
                    ProgressView()
                        .controlSize(.small)
                }
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case .failure:
                placeholder
            @unknown default:
                placeholder
            }
        }
        .frame(width: 74, height: 74)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .accessibilityLabel(appState.localizedFormat("%@ 앱 아이콘", name))
    }

    private var placeholder: some View {
        Image(systemName: "app.fill")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeveloperProjectArtwork: View {
    var name: String
    var artworkAssetName: String
    var size: CGFloat
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        Image(artworkAssetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .background(palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            }
            .accessibilityLabel(appState.localizedFormat("%@ 앱 아이콘", name))
    }
}
