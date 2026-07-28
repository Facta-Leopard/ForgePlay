import SwiftUI

struct HallOfSupportersView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var plaquePalette: SupporterPlaquePalette {
        SupporterPlaquePalette(colorScheme: colorScheme)
    }

    var body: some View {
        ForgePageScaffold(
            "후원자 명예의 전당",
            systemImage: "building.columns.fill"
        ) {
            SupporterPlaque(
                names: SupporterRecognitionCatalog.names,
                palette: plaquePalette
            )
        }
    }
}

private struct SupporterPlaque: View {
    let names: [String]
    let palette: SupporterPlaquePalette
    @Environment(AppState.self) private var appState

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 28)
    ]

    var body: some View {
        ZStack {
            plaqueBody
            engravedBorder
            mountingStuds

            VStack(spacing: 28) {
                Text(appState.localized("후원자 명예의 전당"))
                    .font(.system(size: 27, weight: .heavy, design: .serif))
                    .tracking(2.4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.engraving)
                    .shadow(color: palette.highlight, radius: 0, x: 0, y: 1)
                    .textSelection(.enabled)

                plaqueRule

                if !names.isEmpty {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(names, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 19, weight: .semibold, design: .serif))
                                .tracking(0.5)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(palette.engraving)
                                .shadow(color: palette.highlight, radius: 0, x: 0, y: 1)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, 58)
            .padding(.vertical, 54)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
        }
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var plaqueBody: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        palette.topEdge,
                        palette.center,
                        palette.bottomEdge
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [palette.highlight, palette.shadow],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 3
                    )
            }
            .shadow(color: palette.dropShadow, radius: 18, x: 0, y: 10)
    }

    private var engravedBorder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(palette.recessedBorder, lineWidth: 1.5)
            .padding(18)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(palette.highlight.opacity(0.65), lineWidth: 1)
                    .padding(19.5)
            }
            .allowsHitTesting(false)
    }

    private var mountingStuds: some View {
        VStack {
            HStack {
                mountingStud
                Spacer()
                mountingStud
            }
            Spacer()
            HStack {
                mountingStud
                Spacer()
                mountingStud
            }
        }
        .padding(28)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var mountingStud: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [palette.highlight, palette.stud, palette.shadow],
                    center: .topLeading,
                    startRadius: 1,
                    endRadius: 9
                )
            )
            .frame(width: 15, height: 15)
            .overlay {
                Circle()
                    .stroke(palette.shadow.opacity(0.75), lineWidth: 1)
            }
    }

    private var plaqueRule: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        palette.shadow.opacity(0.75),
                        palette.highlight,
                        palette.shadow.opacity(0.75)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(maxWidth: 520, minHeight: 2, maxHeight: 2)
            .accessibilityHidden(true)
    }
}

private struct SupporterPlaquePalette {
    let topEdge: Color
    let center: Color
    let bottomEdge: Color
    let engraving: Color
    let highlight: Color
    let shadow: Color
    let stud: Color
    let recessedBorder: Color
    let dropShadow: Color

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            topEdge = Color(red: 0.54, green: 0.38, blue: 0.18)
            center = Color(red: 0.40, green: 0.25, blue: 0.10)
            bottomEdge = Color(red: 0.25, green: 0.14, blue: 0.05)
            engraving = Color(red: 0.13, green: 0.07, blue: 0.025)
            highlight = Color(red: 0.88, green: 0.68, blue: 0.34)
            shadow = Color(red: 0.12, green: 0.055, blue: 0.015)
            stud = Color(red: 0.48, green: 0.31, blue: 0.13)
            recessedBorder = Color(red: 0.20, green: 0.105, blue: 0.035)
            dropShadow = .black.opacity(0.48)
        } else {
            topEdge = Color(red: 0.84, green: 0.67, blue: 0.36)
            center = Color(red: 0.68, green: 0.48, blue: 0.22)
            bottomEdge = Color(red: 0.48, green: 0.29, blue: 0.105)
            engraving = Color(red: 0.20, green: 0.105, blue: 0.035)
            highlight = Color(red: 0.97, green: 0.82, blue: 0.52)
            shadow = Color(red: 0.26, green: 0.13, blue: 0.035)
            stud = Color(red: 0.64, green: 0.43, blue: 0.18)
            recessedBorder = Color(red: 0.34, green: 0.18, blue: 0.055)
            dropShadow = .black.opacity(0.24)
        }
    }
}
