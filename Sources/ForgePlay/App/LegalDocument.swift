import Foundation

enum LegalDocument: String, CaseIterable, Identifiable {
    case licenseNotice
    case privacy
    case support
    case thirdPartyNotices
    case notoSansOFL
    case notoSansCJKOFL
    case nanumGothicOFL

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .licenseNotice:
            "ForgePlayLicenseNotice.md"
        case .privacy:
            "ForgePlayPrivacy.md"
        case .support:
            "ForgePlaySupport.md"
        case .thirdPartyNotices:
            "ForgePlayThirdPartyNotices.md"
        case .notoSansOFL:
            "NotoSans-OFL.txt"
        case .notoSansCJKOFL:
            "NotoSansCJK-OFL.txt"
        case .nanumGothicOFL:
            "OFL.txt"
        }
    }

    var sourceRelativePath: String? {
        switch self {
        case .licenseNotice:
            nil
        case .privacy, .support, .thirdPartyNotices:
            "Resources/Legal/\(fileName)"
        case .notoSansOFL, .notoSansCJKOFL:
            "Resources/Fonts/ForgePlayNotoV1/\(fileName)"
        case .nanumGothicOFL:
            "Resources/Runners/ForgePlayRuntime/Legal/NanumGothic/\(fileName)"
        }
    }

    var resourceName: String {
        (fileName as NSString).deletingPathExtension
    }

    var titleKey: String {
        switch self {
        case .licenseNotice:
            "라이선스 안내 열기"
        case .privacy:
            "개인정보 고지 열기"
        case .support:
            "지원 안내 열기"
        case .thirdPartyNotices:
            "외부 구성요소 고지 열기"
        case .notoSansOFL:
            "Noto Sans OFL 1.1"
        case .notoSansCJKOFL:
            "Noto Sans CJK OFL 1.1"
        case .nanumGothicOFL:
            "Nanum Gothic OFL 1.1"
        }
    }

    var systemImage: String {
        switch self {
        case .licenseNotice:
            "checkmark.seal"
        case .privacy:
            "hand.raised"
        case .support:
            "questionmark.circle"
        case .thirdPartyNotices:
            "doc.text.magnifyingglass"
        case .notoSansOFL, .notoSansCJKOFL, .nanumGothicOFL:
            "text.document"
        }
    }

    func bundledURL(
        language: ForgePlayLanguageMode,
        in bundle: Bundle = .main
    ) -> URL? {
        if self == .licenseNotice,
           let localizationDirectory = language.localizationDirectory,
           let localizationURL = bundle.url(
               forResource: localizationDirectory,
               withExtension: "lproj"
           ),
           let localizationBundle = Bundle(url: localizationURL),
           let localizedURL = localizationBundle.url(
               forResource: resourceName,
               withExtension: "md"
           ) {
            return localizedURL
        }

        switch self {
        case .notoSansOFL, .notoSansCJKOFL:
            return bundle.url(
                forResource: resourceName,
                withExtension: "txt",
                subdirectory: "Fonts/ForgePlayNotoV1"
            )
        case .nanumGothicOFL:
            return bundle.url(
                forResource: resourceName,
                withExtension: "txt",
                subdirectory: "Runners/ForgePlayRuntime/Legal/NanumGothic"
            )
        default:
            break
        }

        return bundle.url(forResource: resourceName, withExtension: "md", subdirectory: "Legal") ??
            bundle.url(forResource: resourceName, withExtension: "md")
    }
}
