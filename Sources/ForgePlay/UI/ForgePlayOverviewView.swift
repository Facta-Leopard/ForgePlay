import Foundation
import SwiftUI

struct ForgePlayWhyStoryBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case quote
        case bullet
        case reference(number: Int)
    }

    let id: Int
    let kind: Kind
    let text: String
}

struct ForgePlayWhyStoryDocument: Equatable {
    let sourceMarkdown: String
    let blocks: [ForgePlayWhyStoryBlock]

    init(markdown: String) {
        sourceMarkdown = markdown
        blocks = Self.parse(markdown)
    }

    private static func parse(_ markdown: String) -> [ForgePlayWhyStoryBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var footnoteNumbers: [String: Int] = [:]
        for rawLine in lines {
            guard let definition = footnoteDefinition(in: rawLine) else {
                continue
            }
            if footnoteNumbers[definition.identifier] == nil {
                footnoteNumbers[definition.identifier] = footnoteNumbers.count + 1
            }
        }

        var blocks: [ForgePlayWhyStoryBlock] = []
        var paragraphLines: [String] = []

        func append(_ kind: ForgePlayWhyStoryBlock.Kind, _ text: String) {
            blocks.append(
                ForgePlayWhyStoryBlock(
                    id: blocks.count,
                    kind: kind,
                    text: text
                )
            )
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: " "))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                append(
                    .heading(level: 3),
                    replacingFootnoteMarkers(
                        in: String(line.dropFirst(4)),
                        numbers: footnoteNumbers
                    )
                )
            } else if line.hasPrefix("## ") {
                flushParagraph()
                append(
                    .heading(level: 2),
                    replacingFootnoteMarkers(
                        in: String(line.dropFirst(3)),
                        numbers: footnoteNumbers
                    )
                )
            } else if line.hasPrefix("> ") {
                flushParagraph()
                append(
                    .quote,
                    replacingFootnoteMarkers(
                        in: String(line.dropFirst(2)),
                        numbers: footnoteNumbers
                    )
                )
            } else if line.hasPrefix("- ") {
                flushParagraph()
                append(
                    .bullet,
                    replacingFootnoteMarkers(
                        in: String(line.dropFirst(2)),
                        numbers: footnoteNumbers
                    )
                )
            } else if let definition = footnoteDefinition(in: line),
                      let number = footnoteNumbers[definition.identifier] {
                flushParagraph()
                append(.reference(number: number), definition.content)
            } else {
                paragraphLines.append(
                    replacingFootnoteMarkers(
                        in: line,
                        numbers: footnoteNumbers
                    )
                )
            }
        }

        flushParagraph()
        return blocks
    }

    private static func footnoteDefinition(
        in line: String
    ) -> (identifier: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[^"),
              let delimiter = trimmed.range(of: "]:") else {
            return nil
        }
        let identifierStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let identifier = String(trimmed[identifierStart..<delimiter.lowerBound])
        guard !identifier.isEmpty else { return nil }
        let content = trimmed[delimiter.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        return (identifier, content)
    }

    private static func replacingFootnoteMarkers(
        in text: String,
        numbers: [String: Int]
    ) -> String {
        numbers.reduce(into: text) { result, entry in
            result = result.replacingOccurrences(
                of: "[^\(entry.key)]",
                with: superscript(entry.value)
            )
        }
    }

    private static func superscript(_ number: Int) -> String {
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"
        ]
        return String(String(number).map { digits[$0] ?? $0 })
    }
}

enum ForgePlayWhyStoryResource {
    static let subdirectory = "why-story"
    static let supportedResourceNames: Set<String> = [
        "de", "en", "es", "fr", "ja", "ko", "zh-Hans", "zh-Hant"
    ]

    static func resourceName(
        for language: ForgePlayLanguageMode,
        resolveSystemLanguage: () -> ForgePlayLanguageMode = {
            ForgePlaySystemLanguageResolver.resolvedLanguageMode()
        }
    ) -> String {
        let resolvedLanguage = language == .system
            ? resolveSystemLanguage()
            : language
        guard let identifier = resolvedLanguage.localeIdentifier,
              supportedResourceNames.contains(identifier) else {
            return "en"
        }
        return identifier
    }

    static func load(
        language: ForgePlayLanguageMode,
        bundle: Bundle = .main
    ) throws -> ForgePlayWhyStoryDocument {
        let name = resourceName(for: language)
        guard let url = bundle.url(
            forResource: name,
            withExtension: "md",
            subdirectory: subdirectory
        ) else {
            throw ForgePlayWhyStoryResourceError.resourceMissing(name)
        }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ForgePlayWhyStoryResourceError.resourceEmpty(name)
        }
        return ForgePlayWhyStoryDocument(markdown: markdown)
    }
}

enum ForgePlayWhyStoryResourceError: Error, Equatable {
    case resourceMissing(String)
    case resourceEmpty(String)
}

struct ForgePlayOverviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var storyDocument: ForgePlayWhyStoryDocument?
    @State private var storyLoadFailed = false

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(
            mode: appState.themeMode,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        ForgePageScaffold(
            "만든 이유",
            subtitle: "ForgePlay를 만든 이유와 공개된 제작자 노트 전문을 앱 언어로 읽습니다.",
            systemImage: "book.closed.fill"
        ) {
            SectionHelpButton(section: .learnAboutForgePlay)
        } content: {
            ForgeSection(
                "제작자 노트 전문",
                subtitle: "앱에 포함된 전문을 현재 표시 언어로 읽습니다. 인터넷 연결이나 홈페이지 로딩이 필요하지 않습니다.",
                systemImage: "text.book.closed"
            ) {
                if let storyDocument {
                    ForgePlayWhyStoryReader(
                        document: storyDocument,
                        palette: palette
                    )
                } else if storyLoadFailed {
                    Label(
                        appState.localized(
                            "앱에 포함된 제작자 노트 전문을 읽지 못했습니다."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(palette.warning)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }

            ForgeCard("GitHub에서 응원하기", systemImage: "heart.circle.fill") {
                Text(appState.localized(
                    "GitHub 저장소 상단의 Star로 ForgePlay에 좋아요를 표시하거나 GitHub Sponsors에서 개발과 호환성 테스트를 후원할 수 있습니다."
                ))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ForgePlayLayout.sectionSpacing) {
                        communityActionCard(
                            title: "⭐ 좋아요",
                            detail: "ForgePlay GitHub 저장소를 열고 상단의 Star 버튼을 누릅니다.",
                            url: ExternalLinkPolicy.forgePlayRepositoryStarURL
                        )
                        communityActionCard(
                            title: "💗 후원하기",
                            detail: "GitHub Sponsors 페이지에서 ForgePlay 개발을 후원합니다.",
                            url: ExternalLinkPolicy.forgePlaySponsorsURL
                        )
                    }
                    VStack(spacing: ForgePlayLayout.sectionSpacing) {
                        communityActionCard(
                            title: "⭐ 좋아요",
                            detail: "ForgePlay GitHub 저장소를 열고 상단의 Star 버튼을 누릅니다.",
                            url: ExternalLinkPolicy.forgePlayRepositoryStarURL
                        )
                        communityActionCard(
                            title: "💗 후원하기",
                            detail: "GitHub Sponsors 페이지에서 ForgePlay 개발을 후원합니다.",
                            url: ExternalLinkPolicy.forgePlaySponsorsURL
                        )
                    }
                }
            }

            ForgeSection(
                "공식 정보",
                subtitle: "필요한 정보의 역할에 맞는 공식 페이지를 선택하세요.",
                systemImage: "safari"
            ) {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 300, maximum: 520),
                            spacing: ForgePlayLayout.sectionSpacing,
                            alignment: .top
                        )
                    ],
                    alignment: .leading,
                    spacing: ForgePlayLayout.sectionSpacing
                ) {
                    destinationCard(
                        title: "ForgePlay 홈페이지",
                        detail: "ForgePlay가 어떤 앱인지, 주요 기능과 시작 방법을 한눈에 살펴봅니다.",
                        buttonTitle: "홈페이지 열기",
                        systemImage: "house.fill",
                        url: ExternalLinkPolicy.forgePlayHomepageURL
                    )
                    destinationCard(
                        title: "공지사항",
                        detail: "새로운 기능, 운영 안내와 중요한 변경 사항을 확인합니다.",
                        buttonTitle: "공지사항 열기",
                        systemImage: "megaphone.fill",
                        url: ExternalLinkPolicy.forgePlayAnnouncementsURL
                    )
                    destinationCard(
                        title: "GitHub 저장소",
                        detail: "ForgePlay의 공개 소스, 문서, 이슈와 개발 이력을 살펴봅니다.",
                        buttonTitle: "GitHub 저장소 열기",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        url: ExternalLinkPolicy.forgePlayRepositoryURL
                    )
                    destinationCard(
                        title: "릴리스",
                        detail: "배포된 ForgePlay 버전, 릴리스 설명과 다운로드 항목을 확인합니다.",
                        buttonTitle: "릴리스 열기",
                        systemImage: "shippingbox.fill",
                        url: ExternalLinkPolicy.forgePlayReleasesURL
                    )
                }
            }
        }
        .task(id: appState.effectiveLanguageMode) {
            do {
                storyDocument = try ForgePlayWhyStoryResource.load(
                    language: appState.effectiveLanguageMode
                )
                storyLoadFailed = false
            } catch {
                storyDocument = nil
                storyLoadFailed = true
            }
        }
    }

    private func communityActionCard(
        title: String,
        detail: String,
        url: URL?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.localized(title))
                .font(.headline)
                .foregroundStyle(palette.text)
            Text(appState.localized(detail))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            SecondaryActionButton(
                title: title,
                systemImage: "arrow.up.right.square",
                isDisabled: url == nil
            ) {
                appState.openExternalURL(url)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(palette.control.opacity(0.58))
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

    private func destinationCard(
        title: String,
        detail: String,
        buttonTitle: String,
        systemImage: String,
        url: URL?
    ) -> some View {
        ForgeCard(title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 14) {
                Text(appState.localized(detail))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                SecondaryActionButton(
                    title: buttonTitle,
                    systemImage: "arrow.up.right.square",
                    isDisabled: url == nil
                ) {
                    appState.openExternalURL(url)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
    }
}

private struct ForgePlayWhyStoryReader: View {
    let document: ForgePlayWhyStoryDocument
    let palette: ForgePlayPalette

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.panelCornerRadius,
                style: .continuous
            )
            .stroke(palette.border, lineWidth: 1)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func blockView(_ block: ForgePlayWhyStoryBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            inlineText(block.text)
                .font(level == 2 ? .title2.bold() : .title3.weight(.semibold))
                .foregroundStyle(palette.text)
                .padding(.top, level == 2 ? 0 : 18)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            inlineText(block.text)
                .font(.body)
                .foregroundStyle(palette.text)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(palette.primary.opacity(0.72))
                    .frame(width: 4)
                inlineText(block.text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(palette.text)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                    .font(.body.weight(.bold))
                    .foregroundStyle(palette.primary)
                inlineText(block.text)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case .reference(let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.primary)
                    .frame(minWidth: 20, alignment: .trailing)
                inlineText(block.text)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlineText(_ source: String) -> Text {
        let plainLinks = source.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        let attributed = try? AttributedString(
            markdown: plainLinks,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        return Text(attributed ?? AttributedString(plainLinks))
    }
}
