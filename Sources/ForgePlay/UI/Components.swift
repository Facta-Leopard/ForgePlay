import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum ForgePanelEmphasis {
    case standard
    case accent
    case subdued
}

struct ForgePageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    let actions: Actions
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                titleBlock(palette: palette)
                Spacer(minLength: 24)
                actions
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock(palette: palette)
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private func titleBlock(palette: ForgePlayPalette) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 38, height: 38)
                .background(palette.primary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized(title))
                    .font(.title.weight(.bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(appState.localized(subtitle))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                }
            }
        }
    }
}

extension ForgePageHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

struct ForgePageScaffold<HeaderActions: View, Content: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    let headerActions: HeaderActions
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.headerActions = headerActions()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ForgePlayLayout.pageSpacing) {
                ForgePageHeader(
                    title,
                    subtitle: subtitle,
                    systemImage: systemImage
                ) {
                    headerActions
                }
                content
            }
            .frame(maxWidth: ForgePlayLayout.pageMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension ForgePageScaffold where HeaderActions == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            subtitle: subtitle,
            systemImage: systemImage,
            headerActions: { EmptyView() },
            content: content
        )
    }
}

struct ForgeSection<Actions: View, Content: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    let actions: Actions
    let content: Content
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    sectionTitle(palette: palette)
                    Spacer(minLength: 20)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(palette: palette)
                    actions
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func sectionTitle(palette: ForgePlayPalette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localized(title))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(appState.localized(subtitle))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension ForgeSection where Actions == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            subtitle: subtitle,
            systemImage: systemImage,
            actions: { EmptyView() },
            content: content
        )
    }
}

struct ForgeWorkflowActionPanel<Actions: View>: View {
    var eyebrow: String
    var title: String
    var detail: String
    var status: CheckStatus
    var systemImage: String
    let actions: Actions
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    init(
        eyebrow: String,
        title: String,
        detail: String,
        status: CheckStatus,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.status = status
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                leadingContent(palette: palette)
                Spacer(minLength: 24)
                actions
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 16) {
                leadingContent(palette: palette)
                actions
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous)
                .stroke(status.color(in: palette).opacity(0.38), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(status.color(in: palette))
                .frame(width: 3)
                .padding(.vertical, 8)
        }
    }

    private func leadingContent(palette: ForgePlayPalette) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(status.color(in: palette))
                .frame(width: 38, height: 38)
                .background(status.color(in: palette).opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized(eyebrow))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color(in: palette))
                Text(appState.localized(title))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appState.localized(detail))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680, alignment: .leading)
            }
        }
    }
}

struct ForgeStatusSummaryItem: View {
    var title: String
    var value: String
    var status: CheckStatus
    var systemImage: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status.color(in: palette))
                .frame(width: 30, height: 30)
                .background(status.color(in: palette).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localized(title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct ForgeCard<Content: View>: View {
    let title: String?
    let systemImage: String?
    let emphasis: ForgePanelEmphasis
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        emphasis: ForgePanelEmphasis = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.emphasis = emphasis
        self.content = content()
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(emphasis == .accent ? palette.primary : palette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                emphasis == .accent
                                    ? palette.primary.opacity(0.10)
                                    : palette.control
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: ForgePlayLayout.controlCornerRadius,
                                    style: .continuous
                                )
                            )
                    }
                    Text(appState.localized(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer()
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(palette: palette))
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.panelCornerRadius,
                style: .continuous
            )
            .stroke(
                emphasis == .accent ? palette.primary.opacity(0.34) : palette.border,
                lineWidth: 1
            )
        )
        .overlay(alignment: .leading) {
            if emphasis == .accent {
                Rectangle()
                    .fill(palette.primary)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
    }

    private func panelBackground(palette: ForgePlayPalette) -> Color {
        switch emphasis {
        case .standard:
            palette.surface
        case .accent:
            palette.surface
        case .subdued:
            palette.surfaceElevated
        }
    }
}

struct StatusBadge: View {
    var label: String
    var status: CheckStatus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: statusSymbolName)
                .padding(.top, 1)
            Text(appState.localized(label))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status == .unknown ? palette.secondaryText : status.color(in: palette))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color(in: palette).opacity(0.12))
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.controlCornerRadius,
                style: .continuous
            )
        )
    }

    private var statusSymbolName: String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .unknown: "minus.circle.fill"
        }
    }
}

struct RiskBadge: View {
    var risk: RiskLevel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Text(appState.localized(risk.label))
            .font(.caption.weight(.semibold))
            .foregroundStyle(risk.color(in: palette))
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(risk.color(in: palette).opacity(0.13))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ForgePlayLayout.controlCornerRadius,
                    style: .continuous
                )
            )
    }
}

struct AdaptiveFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = resolvedWidth(proposal: proposal, subviews: subviews)
        let rows = measuredRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + row.height + (total > 0 ? verticalSpacing : 0)
        }
        let contentWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: min(contentWidth, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = measuredRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func resolvedWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite, width > 0 {
            return width
        }
        let measured = subviews.map { $0.sizeThatFits(.unspecified).width }
        let contentWidth = measured.reduce(CGFloat.zero, +) + CGFloat(max(0, measured.count - 1)) * horizontalSpacing
        return max(contentWidth, 1)
    }

    private func measuredRows(maxWidth: CGFloat, subviews: Subviews) -> [AdaptiveFlowRow] {
        var rows: [AdaptiveFlowRow] = []
        var currentItems: [AdaptiveFlowItem] = []
        var currentWidth = CGFloat.zero
        var currentHeight = CGFloat.zero

        for index in subviews.indices {
            let proposedWidth = max(maxWidth, 1)
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let itemWidth = min(size.width, proposedWidth)
            let itemSize = CGSize(width: itemWidth, height: size.height)
            let spacing = currentItems.isEmpty ? CGFloat.zero : horizontalSpacing
            let nextWidth = currentWidth + spacing + itemSize.width

            if !currentItems.isEmpty && nextWidth > maxWidth {
                rows.append(AdaptiveFlowRow(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            let rowSpacing = currentItems.isEmpty ? CGFloat.zero : horizontalSpacing
            currentItems.append(AdaptiveFlowItem(index: index, size: itemSize))
            currentWidth += rowSpacing + itemSize.width
            currentHeight = max(currentHeight, itemSize.height)
        }

        if !currentItems.isEmpty {
            rows.append(AdaptiveFlowRow(items: currentItems, width: currentWidth, height: currentHeight))
        }

        return rows
    }
}

private struct AdaptiveFlowRow {
    var items: [AdaptiveFlowItem]
    var width: CGFloat
    var height: CGFloat
}

private struct AdaptiveFlowItem {
    var index: Int
    var size: CGSize
}

private struct ActionButtonLabel: View {
    var title: String
    var systemImage: String
    var font: Font
    var imageWidth: CGFloat = 18
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: imageWidth, alignment: .center)
                .layoutPriority(1)
            Text(appState.localized(title))
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ActionButtonSurfaceModifier: ViewModifier {
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var minimumHeight: CGFloat
    var foregroundColor: Color
    var backgroundColor: Color
    var borderColor: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ForgePlayLayout.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                if let borderColor {
                    RoundedRectangle(
                        cornerRadius: ForgePlayLayout.controlCornerRadius,
                        style: .continuous
                    )
                        .stroke(borderColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
    }
}

struct ForgeActionButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat
    var liftsOnHover: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(
        cornerRadius: CGFloat = ForgePlayLayout.controlCornerRadius,
        liftsOnHover: Bool = true
    ) {
        self.cornerRadius = cornerRadius
        self.liftsOnHover = liftsOnHover
    }

    func makeBody(configuration: Configuration) -> some View {
        let showsHover = isEnabled && isHovering && !configuration.isPressed

        configuration.label
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : (showsHover ? 0.055 : 0)))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(showsHover ? 0.16 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .shadow(
                color: Color.black.opacity(showsHover && liftsOnHover ? 0.12 : 0),
                radius: showsHover && liftsOnHover ? 4 : 0,
                y: showsHover && liftsOnHover ? 2 : 0
            )
            .onHover { isHovering = $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: isHovering
            )
    }
}

struct AdaptiveDetailText: View {
    var text: String
    var font: Font = .caption
    var color: Color
    var isTextSelectionEnabled = true

    var body: some View {
        AdaptiveValueText(
            text: text,
            font: font,
            color: color,
            isTextSelectionEnabled: isTextSelectionEnabled,
            localizesText: true
        )
    }
}

struct AdaptiveValueText: View {
    var text: String
    var font: Font = .caption
    var color: Color
    var isTextSelectionEnabled = true
    var localizesText = false
    @Environment(AppState.self) private var appState

    var body: some View {
        let displayText = localizesText ? appState.localized(text) : text
        let detail = Text(displayText)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)

        if isTextSelectionEnabled {
            detail.textSelection(.enabled)
        } else {
            detail
        }
    }
}

struct AdaptivePathText: View {
    var path: String
    var font: Font = .caption
    var color: Color
    var isTextSelectionEnabled = false

    private var breakablePath: String {
        path
            .replacingOccurrences(of: "/", with: "/\u{200B}")
            .replacingOccurrences(of: "-", with: "-\u{200B}")
            .replacingOccurrences(of: "_", with: "_\u{200B}")
    }

    var body: some View {
        let detail = Text(breakablePath)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)

        if isTextSelectionEnabled {
            detail.textSelection(.enabled)
        } else {
            detail
        }
    }
}

struct SteamLaunchRecordStatusPanel: View {
    var record: LaunchRecord?
    var showsEmptyState = true
    var onConfirmSurface: ((LaunchRecord, SteamUISurface) -> Void)?
    var onMarkBlackScreen: ((LaunchRecord) -> Void)?
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Group {
            if let record {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            StatusBadge(label: statusLabel(for: record), status: status(for: record))
                            launchTime(record, palette: palette)
                            Spacer(minLength: 8)
                            exitCodeText(record, palette: palette)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            StatusBadge(label: statusLabel(for: record), status: status(for: record))
                            launchTime(record, palette: palette)
                            exitCodeText(record, palette: palette)
                        }
                    }

                    Text(detailText(for: record))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let logPath = preferredLogPath(for: record) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .padding(.top, 1)
                            AdaptivePathText(
                                path: logPath,
                                font: .caption,
                                color: palette.secondaryText,
                                isTextSelectionEnabled: true
                            )
                        }
                    }

                    if allowsFailureActions(for: record) {
                        ResponsiveActionRow {
                            if let logPath = preferredLogPath(for: record) {
                                ThemedActionButton(
                                    title: "로그 보기",
                                    systemImage: "doc.text.magnifyingglass",
                                    prominence: .secondary,
                                    controlSize: .small
                                ) {
                                    appState.revealInFinder(URL(fileURLWithPath: logPath))
                                }
                            }
                            ThemedActionButton(
                                title: "문제 진단 열기",
                                systemImage: "stethoscope",
                                prominence: .secondary,
                                controlSize: .small
                            ) {
                                appState.selectedSection = .diagnostics
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                    }

                    if allowsManualVerification(for: record),
                       onConfirmSurface != nil || onMarkBlackScreen != nil {
                        ResponsiveActionRow {
                            if let onConfirmSurface {
                                Menu {
                                    Button {
                                        onConfirmSurface(record, .signIn)
                                    } label: {
                                        Label(appState.localized("로그인 화면 확인"), systemImage: "person.crop.circle")
                                    }
                                    Button {
                                        onConfirmSurface(record, .steamGuard)
                                    } label: {
                                        Label(appState.localized("Steam Guard 확인"), systemImage: "checkmark.shield")
                                    }
                                    Button {
                                        onConfirmSurface(record, .library)
                                    } label: {
                                        Label(appState.localized("라이브러리 확인"), systemImage: "books.vertical")
                                    }
                                } label: {
                                    Label(appState.localized("화면 상태 기록"), systemImage: "checkmark.rectangle")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            if let onMarkBlackScreen {
                                ThemedActionButton(
                                    title: "검은 화면 기록",
                                    systemImage: "rectangle.slash",
                                    prominence: .secondary,
                                    controlSize: .small
                                ) {
                                    onMarkBlackScreen(record)
                                }
                            }
                        }
                        .frame(maxWidth: 360, alignment: .leading)
                    }
                }
                .padding(10)
                .background(palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
            } else if showsEmptyState {
                Text(appState.localized("아직 Windows용 Steam 실행 기록이 없습니다."))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func launchTime(_ record: LaunchRecord, palette: ForgePlayPalette) -> some View {
        HStack(spacing: 4) {
            Text(appState.localized("시작"))
            Text(record.startedAt, style: .time)
        }
        .font(.caption)
        .foregroundStyle(palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func exitCodeText(_ record: LaunchRecord, palette: ForgePlayPalette) -> some View {
        if let exitCode = record.exitCode {
            Text(appState.localizedFormat("종료 코드: %d", Int(exitCode)))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLabel(for record: LaunchRecord) -> String {
        if record.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
            return "Steam 업데이트 중"
        }
        if record.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode,
           record.steamUIVerificationState == .launchedButUnverified {
            return "Steam 명령 전달됨 · 수동 확인 필요"
        }
        return switch record.steamUIVerificationState {
        case .notRun:
            "Steam 실행 중"
        case .launchedButUnverified:
            "Steam 프로세스 시작됨"
        case .rendered:
            switch record.steamUISurface {
            case .some(.signIn):
                "Steam 로그인 화면 확인됨"
            case .some(.steamGuard):
                "Steam Guard 화면 확인됨"
            case .some(.library):
                "Steam 라이브러리 확인됨"
            case .some(.unknown), .none:
                "Steam 화면 확인됨"
            }
        case .blackScreenSuspected:
            "Steam 검은 화면 의심"
        case .failed:
            "Steam 실행 실패"
        }
    }

    private func status(for record: LaunchRecord) -> CheckStatus {
        if record.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
            return .warning
        }
        return switch record.steamUIVerificationState {
        case .rendered:
            record.steamUISurface == .library ? .ok : .warning
        case .blackScreenSuspected, .failed:
            .error
        case .notRun:
            .unknown
        case .launchedButUnverified:
            .warning
        }
    }

    private func detailText(for record: LaunchRecord) -> String {
        if record.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
            return appState.localized("Steam 클라이언트 업데이트가 진행 중입니다. 업데이트가 끝나면 Steam 창이 자동으로 열립니다.")
        }
        if record.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode,
           record.steamUIVerificationState == .launchedButUnverified {
            return appState.localized("Windows용 Steam 실행 명령은 전달됐지만 실제 프로세스 실행 증거를 확인하지 못했습니다. Steam 창을 직접 확인해야 하며, 검은 화면이면 성공으로 보지 않습니다.")
        }
        return switch record.steamUIVerificationState {
        case .notRun:
            appState.localized("Steam을 시작하고 있습니다.")
        case .launchedButUnverified:
            appState.localized("최근 Windows용 Steam 실행에서 프로세스 시작은 확인됐지만 화면 렌더링은 확인되지 않았습니다.")
        case .rendered:
            switch record.steamUISurface {
            case .some(.signIn):
                appState.localized("Windows용 Steam 로그인 화면이 확인됐습니다. Steam에서 로그인을 완료한 뒤 라이브러리 화면을 기록하세요.")
            case .some(.steamGuard):
                appState.localized("Steam Guard 화면이 확인됐습니다. 인증을 완료한 뒤 라이브러리 화면을 기록하세요.")
            case .some(.library):
                appState.localized("Windows용 Steam 라이브러리 화면이 확인된 실행 기록입니다.")
            case .some(.unknown), .none:
                appState.localized("Windows용 Steam 화면이 확인된 실행 기록입니다.")
            }
        case .blackScreenSuspected:
            appState.localized("최근 Steam 실행에서 검은 화면 또는 Steam WebHelper 렌더링 실패가 감지됐습니다. 로그와 문제 진단을 확인하세요.")
        case .failed:
            appState.localized("Windows용 Steam 실행이 UI 확인 전에 실패했습니다. 로그와 문제 진단을 확인하세요.")
        }
    }

    private func preferredLogPath(for record: LaunchRecord) -> String? {
        record.diagnosticLogPath ?? record.stderrPath ?? record.stdoutPath
    }

    private func allowsManualVerification(for record: LaunchRecord) -> Bool {
        switch record.steamUIVerificationState {
        case .launchedButUnverified:
            true
        case .rendered:
            record.steamUISurface != .library
        case .notRun, .blackScreenSuspected, .failed:
            false
        }
    }

    private func allowsFailureActions(for record: LaunchRecord) -> Bool {
        switch record.steamUIVerificationState {
        case .blackScreenSuspected, .failed:
            true
        case .notRun, .launchedButUnverified, .rendered:
            false
        }
    }
}

struct RemediationStepsView: View {
    var steps: [String]
    var font: Font = .caption
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1).")
                        .font(font.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 18, alignment: .trailing)
                    Text(appState.localized(step))
                        .font(font)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct RuntimeDependencyWorkflowCard: View {
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \RuntimeRecord.runtime) private var runtimes: [RuntimeRecord]

    private var installedCount: Int {
        runtimes.filter { $0.status == "installed" }.count
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReason: String? {
        canRunBundledWindowsRuntime
            ? nil
            : appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgeCard(PairedTerm.requiredComponent.displayName, systemImage: "puzzlepiece.extension") {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        runtimeStatusBadge
                        runtimeDescriptionText(palette: palette)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        runtimeStatusBadge
                        runtimeDescriptionText(palette: palette)
                    }
                }
                Text(appState.localized("ForgePlay는 Microsoft/NVIDIA/OpenAL 설치 파일을 앱에 포함하거나 서버에서 내려받지 않습니다. 공식 페이지를 열어주고, 사용자가 받은 설치 파일을 선택하면 Steam 프리픽스에 설치합니다."))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !installedRuntimeRecords.isEmpty {
                    AdaptiveFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach(installedRuntimeRecords, id: \.id) { runtime in
                            StatusBadge(label: runtimeTitle(for: runtime), status: .ok)
                        }
                    }
                }

                ResponsiveActionRow {
                    ThemedActionButton(
                        title: "필수 구성요소 설치 도구",
                        systemImage: "square.and.arrow.down",
                        prominence: .primary,
                        isDisabled: !canRunBundledWindowsRuntime
                    ) {
                        if let sheetPresenter {
                            sheetPresenter(.chooseRuntimeInstallerCatalog)
                        } else {
                            appState.presentedSheet = .chooseRuntimeInstallerCatalog
                        }
                    }

                    ThemedActionButton(
                        title: "문제 진단 열기",
                        systemImage: "stethoscope",
                        prominence: .secondary
                    ) {
                        appState.selectedSection = .diagnostics
                    }
                }
                .frame(maxWidth: 430)

                if let bundledRuntimeUnavailableReason {
                    Text(bundledRuntimeUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var runtimeStatusBadge: some View {
        StatusBadge(
            label: installedCount == 0 ? "필요할 때 설치" : appState.localizedFormat("%d개 설치 기록", installedCount),
            status: installedCount == 0 ? .unknown : .ok
        )
    }

    private var installedRuntimeRecords: [RuntimeRecord] {
        runtimes.filter { $0.status == "installed" }
    }

    private func runtimeTitle(for runtime: RuntimeRecord) -> String {
        guard let runtimeId = RuntimeId(rawValue: runtime.runtime) else {
            return appState.localizedFormat("알 수 없는 Runtime: %@", runtime.runtime)
        }
        return runtimeId.localizedTitle(appState: appState)
    }

    private func runtimeDescriptionText(palette: ForgePlayPalette) -> some View {
        Text(appState.localized("VC++, DirectX, .NET, OpenAL, XNA, PhysX 같은 Windows 필수 구성요소는 게임별로 필요할 때만 설치합니다."))
            .font(.callout)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TermLabel: View {
    var term: PairedTerm
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 3) {
            Text(appState.localized(term.displayName))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localized(term.description))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PrimaryActionButton: View {
    var title: String
    var systemImage: String
    var isDisabled = false
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Button(action: action) {
            ActionButtonLabel(
                title: title,
                systemImage: systemImage,
                font: .callout.weight(.semibold)
            )
            .frame(maxWidth: .infinity)
            .modifier(
                ActionButtonSurfaceModifier(
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    minimumHeight: 44,
                    foregroundColor: palette.onPrimary,
                    backgroundColor: palette.primary
                )
            )
        }
        .buttonStyle(ForgeActionButtonStyle())
        .opacity(isDisabled ? 0.64 : 1)
        .disabled(isDisabled)
    }
}

struct SecondaryActionButton: View {
    var title: String
    var systemImage: String
    var isDisabled = false
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Button(action: action) {
            ActionButtonLabel(
                title: title,
                systemImage: systemImage,
                font: .callout.weight(.semibold)
            )
            .frame(maxWidth: .infinity)
            .modifier(
                ActionButtonSurfaceModifier(
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    minimumHeight: 44,
                    foregroundColor: palette.text,
                    backgroundColor: palette.surfaceElevated,
                    borderColor: palette.border
                )
            )
        }
        .buttonStyle(ForgeActionButtonStyle())
        .opacity(isDisabled ? 0.64 : 1)
        .disabled(isDisabled)
    }
}

struct ThemedActionButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    var title: String
    var systemImage: String
    var prominence: Prominence
    var isDisabled = false
    var controlSize: ControlSize = .large
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Button(action: action) {
            ActionButtonLabel(
                title: title,
                systemImage: systemImage,
                font: controlSize == .small ? .subheadline.weight(.semibold) : .callout.weight(.semibold),
                imageWidth: controlSize == .small ? 15 : 18
            )
            .frame(maxWidth: .infinity)
            .modifier(
                ActionButtonSurfaceModifier(
                    horizontalPadding: controlSize == .small ? 10 : 14,
                    verticalPadding: controlSize == .small ? 7 : 10,
                    minimumHeight: 44,
                    foregroundColor: prominence == .primary ? palette.onPrimary : palette.text,
                    backgroundColor: prominence == .primary ? palette.primary : palette.surfaceElevated,
                    borderColor: prominence == .primary ? palette.primary.opacity(0.55) : palette.border
                )
            )
        }
        .buttonStyle(ForgeActionButtonStyle())
        .opacity(isDisabled ? 0.64 : 1)
        .disabled(isDisabled)
        .tint(palette.primary)
    }
}

struct ResponsiveActionRow<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 10
    let content: Content

    init(
        alignment: HorizontalAlignment = .leading,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                content
            }
            VStack(alignment: alignment, spacing: spacing) {
                content
            }
        }
    }
}

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var fillsAvailableHeight = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        let content = VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 58, height: 58)
                .background(palette.primary.opacity(0.10))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ForgePlayLayout.panelCornerRadius,
                        style: .continuous
                    )
                )
            Text(appState.localized(title))
                .font(.headline)
                .foregroundStyle(palette.text)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localized(message))
                .font(.callout)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }

        if fillsAvailableHeight {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else {
            content
                .frame(maxWidth: .infinity)
                .padding(32)
        }
    }
}

@MainActor
enum OpenPanelPresenter {
    static func chooseDirectory(
        title: String,
        message: String? = nil,
        prompt: String,
        initialDirectory: URL? = nil,
        canCreateDirectories: Bool = true
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = initialDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreateDirectories
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFileOrDirectory(title: String, message: String? = nil, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(
        title: String,
        message: String? = nil,
        prompt: String,
        allowedExtensions: [String]? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let allowedExtensions {
            let contentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
            if !contentTypes.isEmpty {
                panel.allowedContentTypes = contentTypes
            }
            panel.allowsOtherFileTypes = false
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
