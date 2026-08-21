import Foundation

enum DeveloperAppPlatform: String, CaseIterable, Identifiable, Sendable {
    case mac
    case iPad
    case iPhone

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .mac: "Mac"
        case .iPad: "iPad"
        case .iPhone: "iPhone"
        }
    }

    var systemImage: String {
        switch self {
        case .mac: "macbook"
        case .iPad: "ipad"
        case .iPhone: "iphone"
        }
    }
}

enum DeveloperAppLanguage: String, Hashable, Sendable {
    case english
    case korean
    case spanish
    case german
    case japanese
    case simplifiedChinese
    case traditionalChinese
    case french
    case vietnamese
    case thai

    var titleKey: String {
        switch self {
        case .english: "English"
        case .korean: "한국어"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .french: "Français"
        case .vietnamese: "Tiếng Việt"
        case .thai: "ไทย"
        }
    }
}

enum DeveloperAppKind: String, Hashable, Sendable {
    case app
    case game

    var titleKey: String {
        switch self {
        case .app: "앱"
        case .game: "게임 앱"
        }
    }

    var systemImage: String {
        switch self {
        case .app: "app.fill"
        case .game: "gamecontroller.fill"
        }
    }
}

enum DeveloperAppCompatibility: String, Identifiable, Hashable, Sendable {
    case appleSiliconMac

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .appleSiliconMac: "Mac 호환: Apple Silicon 전용"
        }
    }

    var detailKey: String {
        switch self {
        case .appleSiliconMac:
            "Mac에서는 Apple Silicon 모델의 iPad 앱 호환 모드로 실행됩니다."
        }
    }

    var systemImage: String {
        switch self {
        case .appleSiliconMac: "apple.logo"
        }
    }
}

struct DeveloperAppListing: Identifiable, Hashable, Sendable {
    let appStoreID: String?
    let appStoreSlug: String?
    let name: String
    let platform: DeveloperAppPlatform
    let kind: DeveloperAppKind
    let summaryKey: String
    let supportedLanguages: [DeveloperAppLanguage]
    let compatibilities: [DeveloperAppCompatibility]
    let artworkURL: URL?
    let artworkAssetName: String?
    let homepageURL: URL?

    init(
        appStoreID: String?,
        appStoreSlug: String?,
        name: String,
        platform: DeveloperAppPlatform,
        kind: DeveloperAppKind,
        summaryKey: String,
        supportedLanguages: [DeveloperAppLanguage],
        compatibilities: [DeveloperAppCompatibility],
        artworkURL: URL?,
        artworkAssetName: String? = nil,
        homepageURL: URL? = nil
    ) {
        self.appStoreID = appStoreID
        self.appStoreSlug = appStoreSlug
        self.name = name
        self.platform = platform
        self.kind = kind
        self.summaryKey = summaryKey
        self.supportedLanguages = supportedLanguages
        self.compatibilities = compatibilities
        self.artworkURL = artworkURL
        self.artworkAssetName = artworkAssetName
        self.homepageURL = homepageURL
    }

    var id: String {
        "\(platform.rawValue)-\(appStoreID ?? name)"
    }

    var appStoreURL: URL? {
        guard let appStoreID, let appStoreSlug else { return nil }
        return ExternalLinkPolicy.appStoreProductURL(
            slug: appStoreSlug,
            appID: appStoreID
        )
    }
}

struct DeveloperProjectListing: Identifiable, Hashable, Sendable {
    let name: String
    let platform: DeveloperAppPlatform
    let artworkAssetName: String
    let summaryKey: String?

    var id: String { name }
}

enum DeveloperAppCatalog {
    // These local assets are first-party AppIcon sources from:
    // - ForgePlay/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png
    // - MajorDex/App/Assets.xcassets/AppIcon.appiconset/MajorDexAppIcon-512.png
    // - GameAppEditor/Apps/ForgeEditorApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512x512@1x.png
    // - HareWatch/HareWatchMacApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png
    // - WarrenNet/WarrenNet-macOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png
    // - Hazel&Peanut/Trenchline/Resources/Assets.xcassets/AppIconPeanut.appiconset/AppIconPeanut-Dark.png
    // - GrayLine/GrayLine/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Light-1024.png
    // - Leporis Ascendant/Sources/LeporisAscendant/Resources/AppAssets.xcassets/AppIcon.appiconset/AppIcon-1024.png
    // The 1024px sources are reduced to 512px for the catalog bundle.
    // Keeping them bundled avoids external image or unreleased product URLs.
    static let inDevelopmentListings: [DeveloperProjectListing] = [
        DeveloperProjectListing(
            name: "MajorDex",
            platform: .mac,
            artworkAssetName: "DeveloperAppMajorDex",
            summaryKey: "선택한 프로젝트를 실행하지 않고 읽기 전용으로 분석해 구조와 실행 흐름을 시각적으로 살펴볼 수 있는 macOS 앱입니다."
        ),
        DeveloperProjectListing(
            name: "ForgeKit",
            platform: .mac,
            artworkAssetName: "DeveloperAppForgeKit",
            summaryKey: "Apple 플랫폼 전용 게임 엔진으로, Apple Intelligence 기반 AI를 활용해 2D·3D 게임을 제작할 수 있습니다."
        ),
        DeveloperProjectListing(
            name: "HareWatch",
            platform: .mac,
            artworkAssetName: "DeveloperAppHareWatch",
            summaryKey: "유틸리티"
        ),
        DeveloperProjectListing(
            name: "WarrenNet",
            platform: .mac,
            artworkAssetName: "DeveloperAppWarrenNet",
            summaryKey: "유틸리티"
        ),
        DeveloperProjectListing(
            name: "Hazel&Peanut",
            platform: .iPhone,
            artworkAssetName: "DeveloperAppHazelAndPeanut",
            summaryKey: "게임"
        ),
        DeveloperProjectListing(
            name: "GrayLine",
            platform: .iPhone,
            artworkAssetName: "DeveloperAppGrayLine",
            summaryKey: "게임"
        ),
        DeveloperProjectListing(
            name: "Leporis Ascendant",
            platform: .iPad,
            artworkAssetName: "DeveloperAppLeporisAscendant",
            summaryKey: "게임"
        )
    ]

    static let listings: [DeveloperAppListing] = [
        DeveloperAppListing(
            appStoreID: nil,
            appStoreSlug: nil,
            name: "ForgePlay",
            platform: .mac,
            kind: .app,
            summaryKey: "세계최초, Apple Silicon Mac에서 Windows 게임을 맥 네이티브 게임모드로 실행하는 앱입니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .french
            ],
            compatibilities: [],
            artworkURL: nil,
            artworkAssetName: "DeveloperAppForgePlay",
            homepageURL: ExternalLinkPolicy.forgePlayHomepageURL
        ),
        DeveloperAppListing(
            appStoreID: "6782226580",
            appStoreSlug: "hopdisk",
            name: "HopDisk",
            platform: .mac,
            kind: .app,
            summaryKey: "Mac 저장공간의 실제 사용량을 분석하고 정리할 항목을 안전하게 검토합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/42/17/50/421750e3-1def-d17c-eff1-7d3fbf65a0d5/AppIcon-0-0-85-220-0-5-0-2x.png/512x512bb.png"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6785348274",
            appStoreSlug: "bunmixer",
            name: "BunMixer",
            platform: .mac,
            kind: .app,
            summaryKey: "시스템 음량은 그대로 두고 지원되는 앱의 재생 음량을 앱별로 조절합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/5f/74/53/5f745372-3e1d-51ea-9d6a-3252aabc9b6c/AppIcon-0-0-85-220-0-0-5-0-2x.png/512x512bb.png"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6781878576",
            appStoreSlug: "latchcast",
            name: "LatchCast",
            platform: .mac,
            kind: .app,
            summaryKey: "선택한 앱 창과 관련 오디오를 로컬 동영상 파일로 녹화합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/a7/89/8d/a7898d78-fe9d-637b-0162-f2eff1676750/AppIcon-0-0-85-220-0-5-0-2x.png/512x512bb.png"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6763971665",
            appStoreSlug: "lorabit",
            name: "LoRAbit",
            platform: .mac,
            kind: .app,
            summaryKey: "데이터 준비부터 MLX LoRA 학습과 결과 내보내기까지 로컬에서 관리합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/9d/69/ac/9d69ac0b-54dd-298f-e762-a66d0d18cdd8/AppIcon-0-0-85-220-0-5-0-2x.png/512x512bb.png"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6765845295",
            appStoreSlug: "kanindex",
            name: "KaninDex",
            platform: .mac,
            kind: .app,
            summaryKey: "AI가 만든 코드의 구조, 관계, 실행 흐름과 위험 지점을 이해하기 쉽게 분석합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/c4/e1/64/c4e1647a-8da0-1cd1-a311-37296a3cf46a/AppIcon-0-0-85-220-0-0-5-0-2x.png/512x512bb.png"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6763970447",
            appStoreSlug: "bunniki",
            name: "Bunniki",
            platform: .iPad,
            kind: .app,
            summaryKey: "선택한 문서와 소스 폴더를 구조화된 Markdown 위키로 정리하고 탐색·질문·번역합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .french
            ],
            compatibilities: [.appleSiliconMac],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/03/fb/6d/03fb6dba-c889-8dd3-29c0-9708a69e239d/AppIcon-0-0-1x_U007emarketing-0-6-0-85-220.png/512x512bb.jpg"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6761378169",
            appStoreSlug: "openbooklm",
            name: "OpenBookLM",
            platform: .iPad,
            kind: .app,
            summaryKey: "Obsidian Vault나 문서 폴더를 연결해 검색, 질문, 읽기와 번역을 한곳에서 처리합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .french
            ],
            compatibilities: [.appleSiliconMac],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/be/2f/65/be2f6528-50af-133d-9a59-a44495d92a99/AppIcon-0-0-1x_U007emarketing-0-6-0-85-220.png/512x512bb.jpg"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6764760496",
            appStoreSlug: "seolapin",
            name: "Seolapin",
            platform: .iPad,
            kind: .app,
            summaryKey: "한국의 HWP/HWPX 문서를 열고 이해·번역·간단한 텍스트 편집과 내보내기를 지원합니다.",
            supportedLanguages: [
                .english,
                .korean,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .vietnamese,
                .thai,
                .spanish,
                .french,
                .german
            ],
            compatibilities: [.appleSiliconMac],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/c9/ac/3c/c9ac3cdc-f3ee-eab1-aca9-c4ff692e73c2/AppIcon-0-0-1x_U007epad-0-1-85-220.png/512x512bb.jpg"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6770305364",
            appStoreSlug: "brambletread",
            name: "BRAMBLETREAD",
            platform: .iPhone,
            kind: .game,
            summaryKey: "마나 동력 이동 요새를 지휘해 참호선을 돌파하고, 모스 부호 타건·청취 훈련도 즐기는 액션 게임입니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/e6/15/8b/e6158b88-91d0-5355-fc57-0c9bcd099a20/AppIcon-0-0-1x_U007ephone-0-1-85-220.png/512x512bb.jpg"
            )
        ),
        DeveloperAppListing(
            appStoreID: "6767978392",
            appStoreSlug: "moonwhisk-vale",
            name: "Moonwhisk Vale",
            platform: .iPhone,
            kind: .game,
            summaryKey: "탄종·재장전·포병 지원을 판단하며 마나 수정 포대로 해안의 공습을 막는 액션 방어 게임입니다.",
            supportedLanguages: [
                .english,
                .korean,
                .spanish,
                .german,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .french
            ],
            compatibilities: [],
            artworkURL: URL(
                string: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/00/88/d8/0088d82d-ce8d-8cc4-e022-9c454c46619e/AppIcon-0-0-1x_U007emarketing-0-8-0-85-220.png/512x512bb.jpg"
            )
        )
    ]

    static func listings(for platform: DeveloperAppPlatform) -> [DeveloperAppListing] {
        listings.filter { $0.platform == platform }
    }

    static func inDevelopmentListings(
        for platform: DeveloperAppPlatform
    ) -> [DeveloperProjectListing] {
        inDevelopmentListings.filter { $0.platform == platform }
    }
}
