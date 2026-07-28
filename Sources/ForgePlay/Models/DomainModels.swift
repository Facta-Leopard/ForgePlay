import Foundation

struct PairedTerm: Hashable, Identifiable {
    let beginner: String
    let technical: String
    let description: String

    var id: String { "\(beginner)-\(technical)" }
    var displayName: String { "\(beginner)(\(technical))" }

    static let gameEngine = PairedTerm(
        beginner: "ForgePlay Runtime",
        technical: "Renderer",
        description: "Windows용 Steam과 Steam 안에서 실행할 게임에 적용할 포함 런타임과 그래픽 변환 정책입니다."
    )
    static let executionEnvironment = PairedTerm(
        beginner: "Steam 프리픽스",
        technical: "Windows 환경",
        description: "Windows용 Steam이 C 드라이브처럼 사용하는 전용 실행 공간입니다."
    )
    static let requiredComponent = PairedTerm(
        beginner: "필수 구성요소",
        technical: "Runtime",
        description: "게임이 실행될 때 필요한 Microsoft, DirectX, 오디오, 물리 엔진 구성요소입니다."
    )
    static let problemRecord = PairedTerm(
        beginner: "문제 분석 기록",
        technical: "Log",
        description: "실패 원인을 찾기 위해 저장하는 실행 기록입니다."
    )
    static let automaticAnalysis = PairedTerm(
        beginner: "자동 문제 분석",
        technical: "Rule Engine",
        description: "자주 발생하는 오류 패턴을 로컬에서 빠르게 분석합니다."
    )
    static let aiDiagnostics = PairedTerm(
        beginner: "AI 문제 진단(베타)",
        technical: "Apple Foundation Models",
        description: "사용자가 켠 경우에만 문제 기록을 로컬 온디바이스 AI로 보조 분석합니다."
    )
}

enum AIDiagnosticProviderConfiguration {
    static let identifier = "AppleFoundationModels"
    static let displayName = "Apple Foundation Models"
    static let processingLocationKey = "이 Mac의 Apple Intelligence 온디바이스 모델"
}

enum DiagnosticRecordSource: String, Codable, CaseIterable {
    case ruleEngine
    case appleFoundationModels

    init?(storageValue: String) {
        let normalized = storageValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        switch normalized {
        case "ruleengine", "rule":
            self = .ruleEngine
        case "applefoundationmodels", "foundationmodels", "llm", "ai":
            self = .appleFoundationModels
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .ruleEngine: "로컬 자동 문제 분석(Rule Engine)"
        case .appleFoundationModels: "AI 문제 진단(베타) · Apple Foundation Models"
        }
    }
}

enum CheckStatus: String, Codable, CaseIterable {
    case ok
    case warning
    case error
    case unknown

    var label: String {
        switch self {
        case .ok: "정상"
        case .warning: "확인 필요"
        case .error: "문제 있음"
        case .unknown: "알 수 없음"
        }
    }
}

enum SystemCheckCategory: String, Hashable {
    case appleSilicon
    case operatingSystem
    case storage
    case windowsRuntime
    case steamPrefix
    case unknown
}

struct SystemCheckResult: Identifiable, Hashable {
    let id = UUID()
    var category: SystemCheckCategory = .unknown
    var title: String
    var detail: String
    var status: CheckStatus
    var technicalDetail: String?
}

enum SystemCheckReadinessPhase: Equatable {
    case unverified
    case blocked
    case readyWithWarnings
    case ready
}

struct SystemCheckSummary: Equatable {
    var phase: SystemCheckReadinessPhase
    var blockingResults: [SystemCheckResult]
    var warningResults: [SystemCheckResult]

    init(results: [SystemCheckResult]) {
        blockingResults = results.filter { $0.status == .error }
        warningResults = results.filter { $0.status == .warning }
        if results.isEmpty {
            phase = .unverified
        } else if !blockingResults.isEmpty {
            phase = .blocked
        } else if !warningResults.isEmpty {
            phase = .readyWithWarnings
        } else {
            phase = .ready
        }
    }

    var allowsSetupProgress: Bool {
        phase == .ready || phase == .readyWithWarnings
    }

    var displayStatus: CheckStatus {
        switch phase {
        case .unverified: .unknown
        case .blocked: .error
        case .readyWithWarnings: .warning
        case .ready: .ok
        }
    }
}

enum PrefixMode: Codable, Hashable, Identifiable, CaseIterable, RawRepresentable {
    case steamShared
    case legacy(String)

    static var allCases: [PrefixMode] { [.steamShared] }

    init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized == "steamShared" {
            self = .steamShared
        } else {
            self = .legacy(normalized)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let mode = PrefixMode(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Prefix mode must not be empty"
            )
        }
        self = mode
    }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .steamShared: "steamShared"
        case .legacy(let rawValue): rawValue
        }
    }

    var beginnerName: String {
        switch self {
        case .steamShared: "Steam 프리픽스"
        case .legacy: "이전 프리픽스 기록"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum WindowsCompatibilityVersion: String, Codable, CaseIterable {
    case windows10 = "win10"

    var label: String {
        switch self {
        case .windows10: "Windows 10 64-bit"
        }
    }
}

enum SteamRendererPolicyPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dMetal
    case dxmt
    case d9vk
    case vulkan

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .d3dMetal: "D3DMetal · DirectX 11/12"
        case .dxmt: "DXMT · DirectX 10/11"
        case .d9vk: "D9VK · DirectX 9"
        case .vulkan: "DXVK · DirectX 9/10/11"
        }
    }

    var detailKey: String {
        switch self {
        case .d3dMetal:
            "64비트 DirectX 11/12 게임에 D3DMetal 하나만 적용합니다."
        case .dxmt:
            "DirectX 10/11 게임에 DXMT 하나만 적용합니다."
        case .d9vk:
            "DirectX 9 게임에 D9VK 하나만 적용합니다."
        case .vulkan:
            "DirectX 9/10/11 게임에 DXVK 하나만 적용합니다. Vulkan/MoltenVK 경로를 사용합니다."
        }
    }
}

enum SteamRendererPolicySelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dMetal
    case dxmt
    case d9vk
    case vulkan

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .d3dMetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .d9vk: "D9VK"
        case .vulkan: "DXVK"
        }
    }

    var detailKey: String {
        switch self {
        case .d3dMetal:
            "64비트 DirectX 11/12용입니다. 다른 렌더러와 섞지 않습니다."
        case .dxmt:
            "DirectX 10/11용입니다. D3DMetal이나 D9VK를 함께 넣지 않습니다."
        case .d9vk:
            "DirectX 9 전용입니다. 다른 Direct3D 변환기를 함께 넣지 않습니다."
        case .vulkan:
            "DirectX 9/10/11용 DXVK입니다. Vulkan/MoltenVK 경로만 사용합니다."
        }
    }

    var forcedPreference: SteamRendererPolicyPreference? {
        switch self {
        case .d3dMetal:
            .d3dMetal
        case .dxmt:
            .dxmt
        case .d9vk:
            .d9vk
        case .vulkan:
            .vulkan
        }
    }

    static func persistedValue(_ rawValue: String?) -> SteamRendererPolicySelection {
        switch rawValue {
        case SteamRendererPolicySelection.d3dMetal.rawValue:
            .d3dMetal
        case SteamRendererPolicySelection.dxmt.rawValue:
            .dxmt
        case SteamRendererPolicySelection.d9vk.rawValue:
            .d9vk
        case SteamRendererPolicySelection.vulkan.rawValue, "dxvk":
            .vulkan
        case "automatic", nil:
            .d3dMetal
        default:
            .d3dMetal
        }
    }
}

enum WineSynchronizationSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let legacyValue = try container.decode(String.self)
        guard ["automatic", "msync", "esync"].contains(legacyValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Wine synchronization selection: \(legacyValue)"
            )
        }
        self = .automatic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.automatic.rawValue)
    }

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .automatic: "자동"
        }
    }

    var detailKey: String {
        switch self {
        case .automatic:
            "ForgePlay가 검증한 표준 Wine server 동기화를 사용합니다."
        }
    }
}

enum SteamVideoMemorySelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case gb2
    case gb4
    case gb8
    case gb12
    case gb16

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .automatic: "자동"
        case .gb2: "2 GB"
        case .gb4: "4 GB"
        case .gb8: "8 GB"
        case .gb12: "12 GB"
        case .gb16: "16 GB"
        }
    }

    var manualSizeMB: Int? {
        switch self {
        case .automatic: nil
        case .gb2: 2_048
        case .gb4: 4_096
        case .gb8: 8_192
        case .gb12: 12_288
        case .gb16: 16_384
        }
    }

    func resolvedSizeMB(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        manualSizeMB ?? Self.automaticSizeMB(physicalMemoryBytes: physicalMemoryBytes)
    }

    static func automaticSizeMB(physicalMemoryBytes: UInt64) -> Int {
        let physicalMemoryMB = Int(physicalMemoryBytes / 1_048_576)
        let halfMemoryMB = physicalMemoryMB / 2
        let alignedMemoryMB = (halfMemoryMB / 512) * 512
        return min(16_384, max(2_048, alignedMemoryMB))
    }
}

enum PrefixIdentifier {
    static let steamShared = "prefix-steam-shared"
}

enum RuntimeId: String, Codable, CaseIterable, Identifiable {
    case vcrun2022
    case vcrun2019
    case vcrun2017
    case vcrun2015
    case vcrun2013
    case vcrun2012
    case vcrun2010
    case d3dx9
    case xinput
    case dotnet48
    case dotnet40
    case openal
    case xna40
    case physx

    var id: String { rawValue }

    var beginnerName: String {
        switch self {
        case .vcrun2022, .vcrun2019, .vcrun2017, .vcrun2015, .vcrun2013, .vcrun2012, .vcrun2010:
            "Microsoft Visual C++ 구성요소"
        case .d3dx9, .xinput:
            "DirectX 게임 구성요소"
        case .dotnet48, .dotnet40:
            "Microsoft .NET 구성요소"
        case .openal:
            "OpenAL 오디오 구성요소"
        case .xna40:
            "XNA 게임 구성요소"
        case .physx:
            "PhysX 물리 엔진 구성요소"
        }
    }

    var technicalName: String { rawValue }

    var riskLevel: RiskLevel {
        switch self {
        case .dotnet48, .dotnet40, .physx:
            .medium
        default:
            .low
        }
    }
}

enum RuntimeInstallationStatus: String, Codable, CaseIterable {
    case notInstalled
    case installed
    case failed

    var label: String {
        switch self {
        case .notInstalled: "미설치"
        case .installed: "설치됨"
        case .failed: "설치 실패"
        }
    }
}

enum CompatibilitySupportStatus: String, Codable, CaseIterable {
    case playable
    case partial
    case unsupported
    case unknown

    var label: String { rawValue }

    var displayStatus: CheckStatus {
        switch self {
        case .playable, .partial:
            .ok
        case .unsupported:
            .error
        case .unknown:
            .unknown
        }
    }
}

enum RiskLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .low: "낮음"
        case .medium: "주의"
        case .high: "높음"
        }
    }
}

enum DiagnosticCategory: String, Codable, CaseIterable {
    case missingRuntime
    case directXIssue
    case dotnetIssue
    case graphicsIssue
    case steamIssue
    case runtimeDependency
    case prefixCorruption
    case antiCheat
    case kernelDependency
    case unsupported
    case wineDiagnostic
    case unknown

    var beginnerTitle: String {
        switch self {
        case .missingRuntime: "필수 구성요소가 부족합니다"
        case .directXIssue: "오래된 DirectX 구성요소가 필요합니다"
        case .dotnetIssue: ".NET 구성요소 문제가 의심됩니다"
        case .graphicsIssue: "그래픽 실행 문제가 의심됩니다"
        case .steamIssue: "Steam 상태 확인이 필요합니다"
        case .runtimeDependency: "ForgePlay Runtime 의존성 문제가 있습니다"
        case .prefixCorruption: "Steam 프리픽스가 손상되었을 수 있습니다"
        case .antiCheat: "안티치트 때문에 실행이 어려울 수 있습니다"
        case .kernelDependency: "Windows 커널 드라이버가 필요해 지원이 어렵습니다"
        case .unsupported: "현재 지원 가능성이 낮습니다"
        case .wineDiagnostic: "호환 런타임 로그입니다"
        case .unknown: "원인을 더 확인해야 합니다"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let persistedValue = try container.decode(String.self)
        if persistedValue == "runnerDependency" {
            self = .runtimeDependency
            return
        }
        guard let value = Self(rawValue: persistedValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported diagnostic category: \(persistedValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum RecommendedActionType: String, Codable, CaseIterable {
    case installRuntime
    case setWindowsVersion
    case setDLLOverride
    case addLaunchOption
    case importAppleSupplementalRenderer
    case markUnsupported
    case askUserToUpdateRuntime
    case askUserToUpdateMacOS
    case noAction

    var beginnerLabel: String {
        switch self {
        case .installRuntime: "필수 구성요소 설치"
        case .setWindowsVersion: "Windows 설정 변경"
        case .setDLLOverride: "실행 파일 사용 방식 변경"
        case .addLaunchOption: "게임 실행 옵션 추가"
        case .importAppleSupplementalRenderer: "Apple 보조 렌더러 가져오기"
        case .markUnsupported: "지원 낮음으로 표시"
        case .askUserToUpdateRuntime: "ForgePlay Runtime 업데이트 안내"
        case .askUserToUpdateMacOS: "macOS 업데이트 안내"
        case .noAction: "조치 없음"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let persistedValue = try container.decode(String.self)
        switch persistedValue {
        case "repairGPTKRunner":
            self = .askUserToUpdateRuntime
        case "askUserToUpdateGPTK":
            self = .importAppleSupplementalRenderer
        default:
            guard let value = Self(rawValue: persistedValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported recommended action: \(persistedValue)"
                )
            }
            self = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct RecommendedAction: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: RecommendedActionType
    var runtime: RuntimeId?
    var windowsVersion: String?
    var dll: String?
    var override: String?
    var launchOption: String?
    var requiresUserConfirmation: Bool
    var riskLevel: RiskLevel
    var reason: String
}

struct DiagnosticResult: Codable, Hashable, Identifiable {
    var id = UUID()
    var category: DiagnosticCategory
    var confidence: Double
    var userMessage: String
    var userMessageFormatArguments: [String]?
    var technicalSummary: String
    var riskLevel: RiskLevel
    var recommendedActions: [RecommendedAction]
    var createdAt: Date = Date()
}

struct SteamGame: Hashable, Identifiable, Codable {
    var id: String { steamAppId }
    var steamAppId: String
    var name: String
    var installDir: String
    var libraryPath: String
    var manifestPath: String
    var sizeOnDisk: Int64
    var lastUpdated: Date?
}

struct RuntimeDefinition: Identifiable, Hashable {
    var id: RuntimeId
    var officialURL: URL?
    var officialSourceName: String
    var beginnerDescription: String
    var downloadFileHints: [String]
    var installerHints: [String]
    var extractableArchiveHints: [String] = []
    var preparationNotes: [String] = []

    var installerHintSummary: String {
        installerHints.joined(separator: ", ")
    }

    var downloadHintSummary: String {
        downloadFileHints.joined(separator: ", ")
    }

    var extractableArchiveHintSummary: String {
        extractableArchiveHints.joined(separator: ", ")
    }

    var selectableFileSummary: String {
        (installerHints + extractableArchiveHints).joined(separator: ", ")
    }
}
