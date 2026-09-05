import Darwin
import CryptoKit
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

enum CheckStatus: String, Codable, CaseIterable, Sendable {
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

enum SystemCheckCategory: String, Hashable, Sendable {
    case appleSilicon
    case operatingSystem
    case storage
    case windowsRuntime
    case steamPrefix
    case unknown
}

struct SystemCheckResult: Identifiable, Hashable, Sendable {
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

enum SteamRendererCurrentReleasePolicy {
    static let selectableRawValues = [
        "d3dMetalNVIDIA",
        "dxmt",
        "d9vk"
    ]
    static let defaultRawValue = "d3dMetalNVIDIA"

    static func isUserSelectable(_ rawValue: String) -> Bool {
        selectableRawValues.contains(rawValue)
    }

    static func normalizedRawValue(_ rawValue: String) -> String {
        switch rawValue {
        case "d3dMetal", "vulkan", "dxvk":
            defaultRawValue
        default:
            rawValue
        }
    }

    static func supportsFrameGeneration(_ rawValue: String) -> Bool {
        rawValue == defaultRawValue
    }
}

enum SteamRendererPolicySelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dMetal
    case d3dMetalNVIDIA
    case dxmt
    case d9vk
    case vulkan

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .d3dMetal: "D3DMetal · 표준"
        case .d3dMetalNVIDIA: "D3DMetal - NVIDIA"
        case .dxmt: "DXMT"
        case .d9vk: "D9VK"
        case .vulkan: "DXVK"
        }
    }

    var detailKey: String {
        switch self {
        case .d3dMetal:
            "64비트 DirectX 11/12용 표준 장치 식별입니다. 다른 렌더러와 섞지 않습니다."
        case .d3dMetalNVIDIA:
            "64비트 DirectX 11/12용입니다. GPU 공급자를 NVIDIA로 보고하고 Apple MetalFX용 NGX 브리지 모듈을 준비합니다. 게임별 DLSS 지원은 보장하지 않습니다."
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
        case .d3dMetal, .d3dMetalNVIDIA:
            .d3dMetal
        case .dxmt:
            .dxmt
        case .d9vk:
            .d9vk
        case .vulkan:
            .vulkan
        }
    }

    var usesD3DMetalNVIDIACompatibility: Bool {
        self == .d3dMetalNVIDIA
    }

    var supportsD3DMetalFrameGeneration: Bool {
        SteamRendererCurrentReleasePolicy.supportsFrameGeneration(rawValue)
    }

    static var currentReleaseSelectableCases: [Self] {
        SteamRendererCurrentReleasePolicy.selectableRawValues.compactMap {
            Self(rawValue: $0)
        }
    }

    var isCurrentReleaseUserSelectable: Bool {
        SteamRendererCurrentReleasePolicy.isUserSelectable(rawValue)
    }

    var normalizedForCurrentRelease: Self {
        Self(
            rawValue: SteamRendererCurrentReleasePolicy.normalizedRawValue(rawValue)
        ) ?? .d3dMetalNVIDIA
    }

    static func persistedValue(_ rawValue: String?) -> SteamRendererPolicySelection {
        switch rawValue {
        case SteamRendererPolicySelection.d3dMetal.rawValue:
            .d3dMetal
        case SteamRendererPolicySelection.d3dMetalNVIDIA.rawValue:
            .d3dMetalNVIDIA
        case SteamRendererPolicySelection.dxmt.rawValue:
            .dxmt
        case SteamRendererPolicySelection.d9vk.rawValue:
            .d9vk
        case SteamRendererPolicySelection.vulkan.rawValue, "dxvk":
            .vulkan
        case "automatic", nil:
            .d3dMetalNVIDIA
        default:
            .d3dMetalNVIDIA
        }
    }
}

enum SteamNetworkCompatibilitySelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case wifiIdentity = "wifi-identity"
    case ethernetIdentity = "ethernet-identity"

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .standard: "표준 네트워크"
        case .wifiIdentity: "Wi-Fi 호환성"
        case .ethernetIdentity: "Ethernet 호환성"
        }
    }

    var detailKey: String {
        switch self {
        case .standard:
            "Wine의 네트워크 어댑터 표시를 변경하지 않습니다."
        case .wifiIdentity:
            "게임에 보이는 활성 네트워크 어댑터 종류를 Wi-Fi로 표시합니다. 실제 TCP·UDP 전송 방식은 바꾸지 않습니다."
        case .ethernetIdentity:
            "게임에 보이는 활성 네트워크 어댑터 종류를 Ethernet으로 표시합니다. 실제 TCP·UDP 전송 방식은 바꾸지 않습니다."
        }
    }
}

enum SteamAudioInputSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case enabled

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .disabled: "오디오 입력 끔"
        case .enabled: "오디오 입력 켬"
        }
    }

    var detailKey: String {
        switch self {
        case .disabled:
            "이번 Steam 세션에서 Wine의 마이크 입력 장치를 숨깁니다. 오디오 출력은 유지합니다."
        case .enabled:
            "이번 Steam 세션에서 Wine의 마이크 입력 장치를 노출합니다. macOS가 권한을 요청할 수 있습니다."
        }
    }
}

enum SteamWineChildPOSIXLocalePolicy: String, Hashable, Sendable {
    case inherited
    case englishUTF8FontFallback

    var localeIdentifier: String? {
        switch self {
        case .inherited:
            nil
        case .englishUTF8FontFallback:
            "en_US.UTF-8"
        }
    }
}

struct SteamPrelaunchCompatibilitySelection: Hashable, Sendable {
    let rendererSelection: SteamRendererPolicySelection
    let frameGenerationConfiguration: FrameGenerationConfiguration
    let networkSelection: SteamNetworkCompatibilitySelection
    let audioInputSelection: SteamAudioInputSelection
    let fpsCursorPolicy: FPSCursorCapturePolicy
    let controllerPolicy: ControllerCompatibilityPolicy
    let keyboardMapping: KeyboardMappingPreference
    let managedWineChildPolicy: SteamManagedWineChildCompatibilityPolicy?
    let wineChildPOSIXLocalePolicy: SteamWineChildPOSIXLocalePolicy

    init(
        rendererSelection: SteamRendererPolicySelection,
        frameGenerationConfiguration: FrameGenerationConfiguration = .off,
        networkSelection: SteamNetworkCompatibilitySelection,
        audioInputSelection: SteamAudioInputSelection,
        fpsCursorPolicy: FPSCursorCapturePolicy = .off,
        controllerPolicy: ControllerCompatibilityPolicy = .automatic,
        keyboardMapping: KeyboardMappingPreference = .systemDefault,
        managedWineChildPolicy: SteamManagedWineChildCompatibilityPolicy? = nil,
        wineChildPOSIXLocalePolicy: SteamWineChildPOSIXLocalePolicy = .inherited
    ) {
        self.rendererSelection = rendererSelection
        self.frameGenerationConfiguration = frameGenerationConfiguration
        self.networkSelection = networkSelection
        self.audioInputSelection = audioInputSelection
        self.fpsCursorPolicy = fpsCursorPolicy
        self.controllerPolicy = controllerPolicy
        self.keyboardMapping = keyboardMapping
        self.managedWineChildPolicy = managedWineChildPolicy
        self.wineChildPOSIXLocalePolicy = wineChildPOSIXLocalePolicy
    }

    var rendererPreference: SteamRendererPolicyPreference? {
        rendererSelection.forcedPreference
    }

    func withWineChildPOSIXLocalePolicy(
        _ policy: SteamWineChildPOSIXLocalePolicy
    ) -> Self {
        Self(
            rendererSelection: rendererSelection,
            frameGenerationConfiguration: frameGenerationConfiguration,
            networkSelection: networkSelection,
            audioInputSelection: audioInputSelection,
            fpsCursorPolicy: fpsCursorPolicy,
            controllerPolicy: controllerPolicy,
            keyboardMapping: keyboardMapping,
            managedWineChildPolicy: managedWineChildPolicy,
            wineChildPOSIXLocalePolicy: policy
        )
    }
}

/// Host-authenticated, one-session policy carried to the bundled Wine process
/// router. The canonical game root and its current filesystem identity are
/// resolved while the selected Steam library security scope is open; the
/// per-launch lineage nonce prevents stale inherited state from being reused.
/// Digests carried to Wine are diagnostic correlation values, not authority.
struct SteamManagedWineChildCompatibilityPolicy: Hashable, Sendable {
    static let helldivers2SteamAppID = "553850"

    let steamAppID: String
    let canonicalGameRoot: URL
    let canonicalGameRootIdentityDigest: String
    let anchoredLibraryPathIdentity: CompatibilityAnchoredPathIdentityV1
    let manifestRootAuthorizationDigest: String
    let lineageNonce: UUID
    let heapZeroMemoryEnabled: Bool
    let excludesGameGuardRenderer: Bool

    init(
        steamAppID: String,
        canonicalGameRoot: URL,
        canonicalGameRootIdentityDigest: String,
        anchoredLibraryPathIdentity: CompatibilityAnchoredPathIdentityV1,
        manifestRootAuthorizationDigest: String,
        lineageNonce: UUID,
        heapZeroMemoryEnabled: Bool,
        excludesGameGuardRenderer: Bool
    ) throws {
        guard steamAppID == Self.helldivers2SteamAppID,
              canonicalGameRoot.isFileURL,
              canonicalGameRoot.path.hasPrefix("/"),
              canonicalGameRoot == canonicalGameRoot.standardizedFileURL,
              anchoredLibraryPathIdentity.entries.contains(where: {
                $0.path == canonicalGameRoot.path && $0.kind == .directory
              }),
              canonicalGameRootIdentityDigest.utf8.count == 64,
              manifestRootAuthorizationDigest.utf8.count == 64,
              [canonicalGameRootIdentityDigest, manifestRootAuthorizationDigest]
                .allSatisfy({ digest in
                    digest.utf8.allSatisfy {
                        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                    }
                }),
              lineageNonce.uuidString.lowercased() !=
                "00000000-0000-0000-0000-000000000000" else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "managed-wine-child-policy",
                value: "invalid-or-ambiguous-identity"
            )
        }
        self.steamAppID = steamAppID
        self.canonicalGameRoot = canonicalGameRoot
        self.canonicalGameRootIdentityDigest = canonicalGameRootIdentityDigest
        self.anchoredLibraryPathIdentity = anchoredLibraryPathIdentity
        self.manifestRootAuthorizationDigest = manifestRootAuthorizationDigest
        self.lineageNonce = lineageNonce
        self.heapZeroMemoryEnabled = heapZeroMemoryEnabled
        self.excludesGameGuardRenderer = excludesGameGuardRenderer
    }
}

struct StableRegularFileIdentityV1: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let contentSHA256: String
}

enum OwnerPrivateUnlinkedFileSnapshotErrorV1: Error, Sendable {
    case unsafeSource
    case sourceChanged
    case temporaryStorageFailure(Int32)
    case snapshotVerificationFailed
}

/// Copies a stable, single-link regular file into a private temporary
/// directory, fsyncs it, reopens it read-only, and removes every pathname.
/// The returned descriptor is therefore immutable to path-based writers and
/// is the only descriptor retained by this object.
final class OwnerPrivateUnlinkedFileSnapshotV1: @unchecked Sendable {
    private static let payloadName = "payload"

    let descriptor: Int32
    let sourceIdentity: StableRegularFileIdentityV1

    init(
        copyingSourceDescriptor sourceDescriptor: Int32,
        maximumByteCount: Int64
    ) throws {
        let created = try Self.createSnapshot(
            copyingSourceDescriptor: sourceDescriptor,
            maximumByteCount: maximumByteCount
        )
        descriptor = created.descriptor
        sourceIdentity = created.sourceIdentity
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func stableIdentity(
        descriptor: Int32,
        maximumByteCount: Int64
    ) throws -> StableRegularFileIdentityV1 {
        try readStableIdentity(
            descriptor: descriptor,
            maximumByteCount: maximumByteCount,
            expectedLinkCount: 1,
            consume: nil
        )
    }

    private static func createSnapshot(
        copyingSourceDescriptor sourceDescriptor: Int32,
        maximumByteCount: Int64
    ) throws -> (
        descriptor: Int32,
        sourceIdentity: StableRegularFileIdentityV1
    ) {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL.path
        var template = Array(
            (temporaryRoot + "/.forgeplay-file-snapshot.XXXXXX")
                .utf8CString
        )
        let directoryWasCreated = template.withUnsafeMutableBufferPointer {
            buffer in
            Darwin.mkdtemp(buffer.baseAddress) != nil
        }
        guard directoryWasCreated else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .temporaryStorageFailure(errno)
        }
        let directoryPath = template.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        var directoryDescriptor: Int32 = -1
        var writableDescriptor: Int32 = -1
        var readOnlyDescriptor: Int32 = -1
        var payloadExists = false
        var directoryRemoved = false
        var succeeded = false
        defer {
            if writableDescriptor >= 0 {
                Darwin.close(writableDescriptor)
            }
            if !succeeded, readOnlyDescriptor >= 0 {
                Darwin.close(readOnlyDescriptor)
            }
            if payloadExists, directoryDescriptor >= 0 {
                _ = Darwin.unlinkat(
                    directoryDescriptor,
                    payloadName,
                    0
                )
            }
            if directoryDescriptor >= 0 {
                Darwin.close(directoryDescriptor)
            }
            if !directoryRemoved {
                _ = Darwin.rmdir(directoryPath)
            }
        }

        var pathStatus = stat()
        guard Darwin.lstat(directoryPath, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              pathStatus.st_uid == geteuid(),
              (pathStatus.st_mode & mode_t(0o777)) ==
                (S_IRUSR | S_IWUSR | S_IXUSR) else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }
        directoryDescriptor = Darwin.open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        var directoryStatus = stat()
        guard directoryDescriptor >= 0,
              fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_dev == pathStatus.st_dev,
              directoryStatus.st_ino == pathStatus.st_ino,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == geteuid() else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }

        writableDescriptor = Darwin.openat(
            directoryDescriptor,
            payloadName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard writableDescriptor >= 0 else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .temporaryStorageFailure(errno)
        }
        payloadExists = true
        guard Darwin.fchmod(
                writableDescriptor,
                mode_t(S_IRUSR | S_IWUSR)
              ) == 0 else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .temporaryStorageFailure(errno)
        }
        var writableStatus = stat()
        guard fstat(writableDescriptor, &writableStatus) == 0,
              (writableStatus.st_mode & S_IFMT) == S_IFREG,
              writableStatus.st_uid == geteuid(),
              writableStatus.st_nlink == 1,
              (writableStatus.st_mode & mode_t(0o777)) ==
                (S_IRUSR | S_IWUSR) else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }

        let sourceIdentity = try readStableIdentity(
            descriptor: sourceDescriptor,
            maximumByteCount: maximumByteCount,
            expectedLinkCount: 1
        ) { data, offset in
            var written = 0
            while written < data.count {
                let count = data.withUnsafeBytes { bytes in
                    Darwin.pwrite(
                        writableDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        data.count - written,
                        off_t(offset + Int64(written))
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                        .temporaryStorageFailure(errno)
                }
                written += count
            }
        }
        guard Darwin.fsync(writableDescriptor) == 0,
              fstat(writableDescriptor, &writableStatus) == 0,
              writableStatus.st_size == sourceIdentity.byteCount else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .temporaryStorageFailure(errno)
        }

        let descriptorToClose = writableDescriptor
        writableDescriptor = -1
        guard Darwin.close(descriptorToClose) == 0 else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .temporaryStorageFailure(errno)
        }

        readOnlyDescriptor = Darwin.openat(
            directoryDescriptor,
            payloadName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        var readOnlyStatus = stat()
        guard readOnlyDescriptor >= 0,
              fstat(readOnlyDescriptor, &readOnlyStatus) == 0,
              (Darwin.fcntl(readOnlyDescriptor, F_GETFL, 0) & O_ACCMODE) ==
                O_RDONLY,
              (readOnlyStatus.st_mode & S_IFMT) == S_IFREG,
              readOnlyStatus.st_uid == geteuid(),
              readOnlyStatus.st_nlink == 1,
              readOnlyStatus.st_dev == writableStatus.st_dev,
              readOnlyStatus.st_ino == writableStatus.st_ino,
              readOnlyStatus.st_size == sourceIdentity.byteCount else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }
        guard Darwin.unlinkat(
                directoryDescriptor,
                payloadName,
                0
              ) == 0 else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }
        payloadExists = false
        guard fstat(readOnlyDescriptor, &readOnlyStatus) == 0,
              readOnlyStatus.st_nlink == 0 else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }
        let snapshotIdentity = try readStableIdentity(
            descriptor: readOnlyDescriptor,
            maximumByteCount: maximumByteCount,
            expectedLinkCount: 0,
            consume: nil
        )
        guard snapshotIdentity.byteCount == sourceIdentity.byteCount,
              snapshotIdentity.contentSHA256 ==
                sourceIdentity.contentSHA256,
              Darwin.rmdir(directoryPath) == 0 else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1
                .snapshotVerificationFailed
        }
        directoryRemoved = true
        succeeded = true
        return (readOnlyDescriptor, sourceIdentity)
    }

    private static func readStableIdentity(
        descriptor: Int32,
        maximumByteCount: Int64,
        expectedLinkCount: Int64,
        consume: ((Data, Int64) throws -> Void)?
    ) throws -> StableRegularFileIdentityV1 {
        var initialStatus = stat()
        guard maximumByteCount >= 0,
              fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              Int64(initialStatus.st_nlink) == expectedLinkCount,
              initialStatus.st_size >= 0,
              Int64(initialStatus.st_size) <= maximumByteCount else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1.unsafeSource
        }

        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < Int64(initialStatus.st_size) {
            let requested = min(
                buffer.count,
                Int(Int64(initialStatus.st_size) - offset)
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw OwnerPrivateUnlinkedFileSnapshotErrorV1.sourceChanged
            }
            let data = Data(buffer.prefix(count))
            try consume?(data, offset)
            hasher.update(data: data)
            offset += Int64(count)
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_nlink == initialStatus.st_nlink,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec ==
                initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec ==
                initialStatus.st_mtimespec.tv_nsec,
              finalStatus.st_ctimespec.tv_sec ==
                initialStatus.st_ctimespec.tv_sec,
              finalStatus.st_ctimespec.tv_nsec ==
                initialStatus.st_ctimespec.tv_nsec else {
            throw OwnerPrivateUnlinkedFileSnapshotErrorV1.sourceChanged
        }
        return StableRegularFileIdentityV1(
            device: UInt64(finalStatus.st_dev),
            inode: UInt64(finalStatus.st_ino),
            byteCount: Int64(finalStatus.st_size),
            modificationSeconds: Int64(finalStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(finalStatus.st_mtimespec.tv_nsec),
            changeSeconds: Int64(finalStatus.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(finalStatus.st_ctimespec.tv_nsec),
            contentSHA256: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }
}

final class CompatibilityAnchoredPathCapabilityLeaseV1:
    @unchecked Sendable,
    Hashable {
    private struct RetainedEntry {
        let identity: CompatibilityAnchoredPathIdentityV1.Entry
        let liveDescriptor: Int32
        let regularFileIdentity: StableRegularFileIdentityV1?
        let regularFileSnapshot: OwnerPrivateUnlinkedFileSnapshotV1?

        var spawnDescriptor: Int32 {
            regularFileSnapshot?.descriptor ?? liveDescriptor
        }
    }

    private let retainedEntries: [RetainedEntry]

    init(
        entries: [CompatibilityAnchoredPathIdentityV1.Entry],
        descriptors: [Int32]
    ) throws {
        guard !entries.isEmpty,
              entries.count == descriptors.count,
              Set(entries.map(\.path)).count == entries.count else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "anchored-library-capability-shape"
            )
        }
        var retained: [RetainedEntry] = []
        do {
            for (entry, descriptor) in zip(entries, descriptors) {
                let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "anchored-library-capability-duplicate"
                    )
                }
                let regularFileIdentity: StableRegularFileIdentityV1?
                let regularFileSnapshot:
                    OwnerPrivateUnlinkedFileSnapshotV1?
                do {
                    if entry.kind == .regularFile {
                        let snapshot = try
                            OwnerPrivateUnlinkedFileSnapshotV1(
                                copyingSourceDescriptor: duplicate,
                                maximumByteCount: 512 * 1024 * 1024
                            )
                        regularFileIdentity = snapshot.sourceIdentity
                        regularFileSnapshot = snapshot
                    } else {
                        regularFileIdentity = nil
                        regularFileSnapshot = nil
                    }
                } catch {
                    Darwin.close(duplicate)
                    throw SteamCompatibilityLaunchProfileErrorV1
                        .invalidReceipt(
                            "anchored-library-capability-snapshot"
                        )
                }
                retained.append(
                    RetainedEntry(
                        identity: entry,
                        liveDescriptor: duplicate,
                        regularFileIdentity: regularFileIdentity,
                        regularFileSnapshot: regularFileSnapshot
                    )
                )
            }
            retainedEntries = retained
            try revalidate()
        } catch {
            retained.forEach { Darwin.close($0.liveDescriptor) }
            throw error
        }
    }

    deinit {
        retainedEntries.forEach { Darwin.close($0.liveDescriptor) }
    }

    static func == (
        lhs: CompatibilityAnchoredPathCapabilityLeaseV1,
        rhs: CompatibilityAnchoredPathCapabilityLeaseV1
    ) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func revalidate() throws {
        for retained in retainedEntries {
            var status = stat()
            let expectedType: mode_t = retained.identity.kind == .directory
                ? mode_t(S_IFDIR)
                : mode_t(S_IFREG)
            guard fstat(retained.liveDescriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == expectedType,
                  retained.identity.kind == .directory || status.st_nlink == 1,
                  UInt64(status.st_dev) == retained.identity.device,
                  UInt64(status.st_ino) == retained.identity.inode else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "anchored-library-capability-replaced"
                )
            }
            if let expected = retained.regularFileIdentity,
               (try? OwnerPrivateUnlinkedFileSnapshotV1.stableIdentity(
                    descriptor: retained.liveDescriptor,
                    maximumByteCount: 512 * 1024 * 1024
               )) != expected {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "anchored-library-capability-content-changed"
                )
            }
        }
    }

    func installSpawnCapabilities(
        fileActions: inout posix_spawn_file_actions_t?,
        environment: inout [String: String],
        startingAt firstDescriptor: Int32
    ) throws -> Int32 {
        try revalidate()
        guard let highestSourceDescriptor = retainedEntries
            .map(\.spawnDescriptor)
            .max(),
              highestSourceDescriptor < Int32.max else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "anchored-library-capability-descriptor-range"
            )
        }
        var target = max(firstDescriptor, highestSourceDescriptor + 1)
        var projection: [String] = []
        for retained in retainedEntries {
            let result = posix_spawn_file_actions_adddup2(
                &fileActions,
                retained.spawnDescriptor,
                target
            )
            guard result == 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "anchored-library-capability-spawn"
                )
            }
            let encodedPath = Data(retained.identity.path.utf8)
                .base64EncodedString()
            projection.append(
                "\(target):\(retained.identity.kind.rawValue):\(encodedPath)"
            )
            target += 1
        }
        environment["FORGEPLAY_BOUND_LIBRARY_OBJECT_FDS_V1"] =
            projection.joined(separator: "|")
        return target
    }
}

struct CompatibilityAnchoredPathIdentityV1: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case directory
        case regularFile
    }

    struct Entry: Hashable, Sendable {
        let path: String
        let kind: Kind
        let device: UInt64
        let inode: UInt64
    }

    let entries: [Entry]
    private let capabilityLease: CompatibilityAnchoredPathCapabilityLeaseV1?

    init(
        entries: [Entry],
        capabilityLease: CompatibilityAnchoredPathCapabilityLeaseV1? = nil
    ) {
        self.entries = entries
        self.capabilityLease = capabilityLease
    }

    func revalidate() throws {
        guard !entries.isEmpty,
              Set(entries.map(\.path)).count == entries.count else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "anchored-library-identity-shape"
            )
        }
        for entry in entries {
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
                (entry.kind == .directory ? O_DIRECTORY : 0)
            let descriptor = Darwin.open(entry.path, flags)
            guard descriptor >= 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "anchored-library-path-replaced"
                )
            }
            defer { Darwin.close(descriptor) }
            var status = stat()
            let expectedType: mode_t = entry.kind == .directory
                ? mode_t(S_IFDIR)
                : mode_t(S_IFREG)
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == expectedType,
                  entry.kind == .directory || status.st_nlink == 1,
                  UInt64(status.st_dev) == entry.device,
                  UInt64(status.st_ino) == entry.inode else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "anchored-library-object-replaced"
                )
            }
        }
        try capabilityLease?.revalidate()
    }

    func installSpawnCapabilities(
        fileActions: inout posix_spawn_file_actions_t?,
        environment: inout [String: String],
        startingAt firstDescriptor: Int32
    ) throws -> Int32 {
        guard let capabilityLease else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "anchored-library-capability-missing"
            )
        }
        return try capabilityLease.installSpawnCapabilities(
            fileActions: &fileActions,
            environment: &environment,
            startingAt: firstDescriptor
        )
    }
}

enum WineSynchronizationSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let legacyValue = try container.decode(String.self)
        guard legacyValue == Self.automatic.rawValue else {
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

enum RuntimeId: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum RiskLevel: String, Codable, CaseIterable, Sendable {
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

enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
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

enum RecommendedActionType: String, Codable, CaseIterable, Sendable {
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

struct RecommendedAction: Codable, Hashable, Identifiable, Sendable {
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

struct DiagnosticResult: Codable, Hashable, Identifiable, Sendable {
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

enum DiagnosticPresentationLimits {
    static let diagnosticRecords = 50
    static let launchRecords = 50
    static let supportIncidentLaunchOptions = 20
    static let concurrentDecodes = 4

    static var diagnosticQueryFetchLimit: Int { diagnosticRecords + 1 }
    static var launchQueryFetchLimit: Int { launchRecords + 1 }
}

struct DiagnosticPresentationWindow<Element> {
    let values: [Element]
    let isTruncated: Bool

    init(_ fetchedValues: [Element], limit: Int) {
        let boundedLimit = max(0, limit)
        values = Array(fetchedValues.prefix(boundedLimit))
        isTruncated = fetchedValues.count > boundedLimit
    }
}

struct DiagnosticEvidenceAssociation: Hashable, Sendable {
    var gameID: String?
    var launchRecordID: String?
}

struct DiagnosticAIRequestEnvelope<Preview> {
    let preview: Preview
    let evidenceAssociation: DiagnosticEvidenceAssociation
}

struct DiagnosticExactTaskTokenGate: Sendable {
    private(set) var activeToken: UUID?

    var isActive: Bool { activeToken != nil }

    mutating func beginIfIdle() -> UUID? {
        guard activeToken == nil else { return nil }
        let token = UUID()
        activeToken = token
        return token
    }

    mutating func beginReplacingCurrent() -> UUID {
        let token = UUID()
        activeToken = token
        return token
    }

    func owns(_ token: UUID) -> Bool {
        activeToken == token
    }

    @discardableResult
    mutating func release(_ token: UUID) -> Bool {
        guard owns(token) else { return false }
        activeToken = nil
        return true
    }

    mutating func invalidate() {
        activeToken = nil
    }
}

struct SteamGame: Hashable, Identifiable, Codable, Sendable {
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
