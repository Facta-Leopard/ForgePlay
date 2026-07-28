import Foundation

enum LegalDocument: String, CaseIterable, Identifiable {
    case licenseNotice
    case privacy
    case support
    case thirdPartyNotices

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

        return bundle.url(forResource: resourceName, withExtension: "md", subdirectory: "Legal") ??
            bundle.url(forResource: resourceName, withExtension: "md")
    }
}
