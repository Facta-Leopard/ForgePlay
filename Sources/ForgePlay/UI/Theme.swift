import SwiftUI

enum ForgePlayThemeMode: String, CaseIterable, Identifiable {
    case system
    case burntSienna
    case pumpkinSpice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "시스템 설정 따르기"
        case .burntSienna: "Burnt Sienna 라이트"
        case .pumpkinSpice: "Pumpkin Spice Season 다크"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .burntSienna: .light
        case .pumpkinSpice: .dark
        }
    }
}

struct ForgePlayPalette {
    var background: Color
    var sidebar: Color
    var surface: Color
    var surfaceElevated: Color
    var control: Color
    var primary: Color
    var onPrimary: Color
    var secondary: Color
    var accent: Color
    var success: Color
    var warning: Color
    var danger: Color
    var text: Color
    var secondaryText: Color
    var border: Color
    var separator: Color
}

enum ForgePlayTheme {
    static func palette(mode: ForgePlayThemeMode, colorScheme: ColorScheme) -> ForgePlayPalette {
        let resolved: ForgePlayThemeMode
        if mode == .system {
            resolved = colorScheme == .dark ? .pumpkinSpice : .burntSienna
        } else {
            resolved = mode
        }

        switch resolved {
        case .system:
            return palette(mode: .system, colorScheme: colorScheme)
        case .burntSienna:
            return ForgePlayPalette(
                background: Color(red: 0.955, green: 0.961, blue: 0.969),
                sidebar: Color(red: 0.925, green: 0.937, blue: 0.949),
                surface: Color(red: 0.995, green: 0.997, blue: 1.000),
                surfaceElevated: Color(red: 0.972, green: 0.978, blue: 0.984),
                control: Color(red: 0.938, green: 0.946, blue: 0.954),
                primary: Color(red: 0.84, green: 0.22, blue: 0.13),
                onPrimary: .white,
                secondary: Color(red: 0.05, green: 0.43, blue: 0.42),
                accent: Color(red: 0.18, green: 0.38, blue: 0.78),
                success: Color(red: 0.04, green: 0.47, blue: 0.31),
                warning: Color(red: 0.52, green: 0.27, blue: 0.01),
                danger: Color(red: 0.74, green: 0.16, blue: 0.17),
                text: Color(red: 0.105, green: 0.118, blue: 0.137),
                secondaryText: Color(red: 0.35, green: 0.38, blue: 0.43),
                border: Color(red: 0.79, green: 0.81, blue: 0.84),
                separator: Color(red: 0.84, green: 0.86, blue: 0.88)
            )
        case .pumpkinSpice:
            return ForgePlayPalette(
                background: Color(red: 0.080, green: 0.086, blue: 0.094),
                sidebar: Color(red: 0.102, green: 0.110, blue: 0.120),
                surface: Color(red: 0.128, green: 0.137, blue: 0.149),
                surfaceElevated: Color(red: 0.160, green: 0.171, blue: 0.184),
                control: Color(red: 0.183, green: 0.195, blue: 0.210),
                primary: Color(red: 1.00, green: 0.36, blue: 0.24),
                onPrimary: Color(red: 0.075, green: 0.050, blue: 0.040),
                secondary: Color(red: 0.28, green: 0.74, blue: 0.69),
                accent: Color(red: 0.38, green: 0.62, blue: 1.00),
                success: Color(red: 0.25, green: 0.76, blue: 0.52),
                warning: Color(red: 0.96, green: 0.67, blue: 0.24),
                danger: Color(red: 1.00, green: 0.46, blue: 0.44),
                text: Color(red: 0.95, green: 0.96, blue: 0.98),
                secondaryText: Color(red: 0.66, green: 0.69, blue: 0.74),
                border: Color(red: 0.265, green: 0.284, blue: 0.310),
                separator: Color(red: 0.225, green: 0.242, blue: 0.265)
            )
        }
    }
}

enum ForgePlayLayout {
    static let pageMaximumWidth: CGFloat = 1_180
    static let pageSpacing: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let panelCornerRadius: CGFloat = 7
    static let controlCornerRadius: CGFloat = 6
}

extension CheckStatus {
    func color(in palette: ForgePlayPalette) -> Color {
        switch self {
        case .ok: palette.success
        case .warning: palette.warning
        case .error: palette.danger
        case .unknown: palette.secondaryText
        }
    }
}

extension RiskLevel {
    func color(in palette: ForgePlayPalette) -> Color {
        switch self {
        case .low: palette.success
        case .medium: palette.warning
        case .high: palette.danger
        }
    }
}
