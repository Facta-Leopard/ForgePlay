import CryptoKit
import Foundation

enum CompatibilityResolvedValueProvenanceV1: String, Codable, Hashable, Sendable {
    case recipe
    case savedPreference
    case oneLaunchOverride
    case automaticRequired
}

struct CompatibilityResolvedValueV1<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value
    let provenance: CompatibilityResolvedValueProvenanceV1
}

enum CompatibilityManifestRootAuthorizationErrorV1: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidBookmark(String)
    case staleBookmark
    case securityScopeDenied
    case selectedObjectIsNotDirectory
    case missingPinnedObjectIdentity(String)
    case providerOutputMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Steam 매니페스트 루트 권한 제공자가 아직 연결되지 않았습니다. 저장은 가능하지만 세션 준비는 차단됩니다."
        case .invalidBookmark(let reason):
            "선택한 Steam 매니페스트 루트 북마크가 올바르지 않습니다: \(reason)"
        case .staleBookmark:
            "선택한 Steam 매니페스트 루트 북마크가 오래되어 다시 선택해야 합니다."
        case .securityScopeDenied:
            "선택한 Steam 매니페스트 루트의 보안 범위 접근 권한을 열지 못했습니다."
        case .selectedObjectIsNotDirectory:
            "선택한 Steam 매니페스트 루트가 폴더가 아닙니다."
        case .missingPinnedObjectIdentity(let field):
            "선택한 Steam 매니페스트 루트의 고정 객체 식별자를 읽지 못했습니다: \(field)"
        case .providerOutputMismatch:
            "Steam 매니페스트 루트 권한 제공자의 결과가 선택한 북마크와 일치하지 않습니다."
        }
    }
}

struct CompatibilityUnresolvedManifestRootBookmarkV1: Hashable, Sendable {
    static let schemaVersion = 1

    let bookmarkSchemaVersion: Int
    let securityScopedBookmark: Data
    let bookmarkDigest: String

    init(securityScopedBookmark: Data) throws {
        guard !securityScopedBookmark.isEmpty,
              securityScopedBookmark.count <= 1_048_576 else {
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "bookmark-size"
            )
        }
        bookmarkSchemaVersion = Self.schemaVersion
        self.securityScopedBookmark = securityScopedBookmark
        bookmarkDigest = SteamLaunchIdentifierValidation.lowercaseSHA256(
            securityScopedBookmark
        )
        try validate()
    }

    func validate() throws {
        guard bookmarkSchemaVersion == Self.schemaVersion else {
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "schema-version"
            )
        }
        guard !securityScopedBookmark.isEmpty,
              securityScopedBookmark.count <= 1_048_576,
              bookmarkDigest == SteamLaunchIdentifierValidation.lowercaseSHA256(
                securityScopedBookmark
              ) else {
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "digest"
            )
        }
    }
}

struct CompatibilityManifestRootAuthorizationTokenV1: Hashable, Sendable {
    static let schemaVersion = 1
    private static let canonicalHeader = Data(
        "forgeplay-steam-compatibility-manifest-root-authorization-v1\n".utf8
    )

    let authorizationSchemaVersion: Int
    let providerID: String
    let securityScopedBookmark: Data
    let sourceBookmarkDigest: String
    let pinnedVolumeIdentifier: Data
    let pinnedFileIdentifier: Data
    let pinnedObjectIdentityDigest: String
    let authorizationDigest: String

    init(
        providerID: String,
        sourceBookmark: CompatibilityUnresolvedManifestRootBookmarkV1,
        pinnedVolumeIdentifier: Data,
        pinnedFileIdentifier: Data
    ) throws {
        try sourceBookmark.validate()
        guard SteamLaunchIdentifierValidation.isValid(providerID, maximumUTF8Bytes: 128) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                "provider-id"
            )
        }
        guard !pinnedVolumeIdentifier.isEmpty,
              !pinnedFileIdentifier.isEmpty,
              pinnedVolumeIdentifier.count <= 65_536,
              pinnedFileIdentifier.count <= 65_536 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                "pinned-object-identity"
            )
        }
        authorizationSchemaVersion = Self.schemaVersion
        self.providerID = providerID
        securityScopedBookmark = sourceBookmark.securityScopedBookmark
        sourceBookmarkDigest = sourceBookmark.bookmarkDigest
        self.pinnedVolumeIdentifier = pinnedVolumeIdentifier
        self.pinnedFileIdentifier = pinnedFileIdentifier
        pinnedObjectIdentityDigest = Self.makePinnedObjectIdentityDigest(
            volumeIdentifier: pinnedVolumeIdentifier,
            fileIdentifier: pinnedFileIdentifier
        )
        authorizationDigest = Self.makeAuthorizationDigest(
            providerID: providerID,
            sourceBookmarkDigest: sourceBookmark.bookmarkDigest,
            pinnedObjectIdentityDigest: pinnedObjectIdentityDigest
        )
        try validate(for: sourceBookmark)
    }

    func validate(
        for sourceBookmark: CompatibilityUnresolvedManifestRootBookmarkV1? = nil
    ) throws {
        guard authorizationSchemaVersion == Self.schemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                "schema-version"
            )
        }
        guard SteamLaunchIdentifierValidation.isValid(providerID, maximumUTF8Bytes: 128),
              !securityScopedBookmark.isEmpty,
              sourceBookmarkDigest == SteamLaunchIdentifierValidation.lowercaseSHA256(
                securityScopedBookmark
              ),
              !pinnedVolumeIdentifier.isEmpty,
              !pinnedFileIdentifier.isEmpty,
              pinnedVolumeIdentifier.count <= 65_536,
              pinnedFileIdentifier.count <= 65_536 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                "stored-provider-output"
            )
        }
        let expectedPinnedDigest = Self.makePinnedObjectIdentityDigest(
            volumeIdentifier: pinnedVolumeIdentifier,
            fileIdentifier: pinnedFileIdentifier
        )
        guard pinnedObjectIdentityDigest == expectedPinnedDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                "pinned-object-digest"
            )
        }
        let expectedAuthorizationDigest = Self.makeAuthorizationDigest(
            providerID: providerID,
            sourceBookmarkDigest: sourceBookmarkDigest,
            pinnedObjectIdentityDigest: pinnedObjectIdentityDigest
        )
        guard authorizationDigest == expectedAuthorizationDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                "authorization-digest"
            )
        }
        if let sourceBookmark {
            try sourceBookmark.validate()
            guard sourceBookmark.bookmarkDigest == sourceBookmarkDigest,
                  sourceBookmark.securityScopedBookmark == securityScopedBookmark else {
                throw CompatibilityManifestRootAuthorizationErrorV1.providerOutputMismatch
            }
        }
    }

    private static func makePinnedObjectIdentityDigest(
        volumeIdentifier: Data,
        fileIdentifier: Data
    ) -> String {
        var encoder = SteamCompatibilityCanonicalEncoderV1(
            header: Data("forgeplay-steam-compatibility-pinned-root-object-v1\n".utf8)
        )
        encoder.append(
            name: "volumeIdentifierDigest",
            value: SteamLaunchIdentifierValidation.lowercaseSHA256(volumeIdentifier)
        )
        encoder.append(
            name: "fileIdentifierDigest",
            value: SteamLaunchIdentifierValidation.lowercaseSHA256(fileIdentifier)
        )
        return SteamLaunchIdentifierValidation.lowercaseSHA256(encoder.data)
    }

    private static func makeAuthorizationDigest(
        providerID: String,
        sourceBookmarkDigest: String,
        pinnedObjectIdentityDigest: String
    ) -> String {
        var encoder = SteamCompatibilityCanonicalEncoderV1(header: canonicalHeader)
        encoder.append(name: "schemaVersion", value: String(schemaVersion))
        encoder.append(name: "providerID", value: providerID)
        encoder.append(name: "sourceBookmarkDigest", value: sourceBookmarkDigest)
        encoder.append(name: "pinnedObjectIdentityDigest", value: pinnedObjectIdentityDigest)
        return SteamLaunchIdentifierValidation.lowercaseSHA256(encoder.data)
    }
}

protocol CompatibilityManifestRootAuthorizationProviderV1: Sendable {
    func resolveAndPinManifestRoot(
        bookmark: CompatibilityUnresolvedManifestRootBookmarkV1
    ) async throws -> CompatibilityManifestRootAuthorizationTokenV1
}

struct UnavailableCompatibilityManifestRootAuthorizationProviderV1:
    CompatibilityManifestRootAuthorizationProviderV1
{
    func resolveAndPinManifestRoot(
        bookmark: CompatibilityUnresolvedManifestRootBookmarkV1
    ) async throws -> CompatibilityManifestRootAuthorizationTokenV1 {
        try bookmark.validate()
        throw CompatibilityManifestRootAuthorizationErrorV1.unavailable
    }
}

struct SecurityScopedCompatibilityManifestRootAuthorizationProviderV1:
    CompatibilityManifestRootAuthorizationProviderV1
{
    private let providerID = "forgeplay.security-scoped-bookmark-root-v1"

    func resolveAndPinManifestRoot(
        bookmark: CompatibilityUnresolvedManifestRootBookmarkV1
    ) async throws -> CompatibilityManifestRootAuthorizationTokenV1 {
        try bookmark.validate()
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmark.securityScopedBookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "resolution"
            )
        }
        guard !isStale else {
            throw CompatibilityManifestRootAuthorizationErrorV1.staleBookmark
        }
        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw CompatibilityManifestRootAuthorizationErrorV1.securityScopeDenied
        }
        defer { resolvedURL.stopAccessingSecurityScopedResource() }

        let values = try resolvedURL.resourceValues(
            forKeys: [.isDirectoryKey, .volumeIdentifierKey, .fileResourceIdentifierKey]
        )
        guard values.isDirectory == true else {
            throw CompatibilityManifestRootAuthorizationErrorV1.selectedObjectIsNotDirectory
        }
        let volumeIdentifier = try archivedResourceIdentifier(
            values.volumeIdentifier,
            field: "volume"
        )
        let fileIdentifier = try archivedResourceIdentifier(
            values.fileResourceIdentifier,
            field: "file"
        )
        return try CompatibilityManifestRootAuthorizationTokenV1(
            providerID: providerID,
            sourceBookmark: bookmark,
            pinnedVolumeIdentifier: volumeIdentifier,
            pinnedFileIdentifier: fileIdentifier
        )
    }

    private func archivedResourceIdentifier(
        _ value: Any?,
        field: String
    ) throws -> Data {
        guard let value = value as? any NSSecureCoding else {
            throw CompatibilityManifestRootAuthorizationErrorV1.missingPinnedObjectIdentity(
                field
            )
        }
        do {
            return try NSKeyedArchiver.archivedData(
                withRootObject: value,
                requiringSecureCoding: true
            )
        } catch {
            throw CompatibilityManifestRootAuthorizationErrorV1.missingPinnedObjectIdentity(
                field
            )
        }
    }
}

enum CompatibilityManifestImageContainmentV1: Hashable, Sendable {
    case contained(rootAuthorizationDigest: String, relativePathComponents: [String])
    case unresolved
    case escapedRoot
}

enum CompatibilityAutomaticProcessMatcherEvaluatorV1 {
    private static let exactASCIIName = Array("GameGuard".utf8)

    static func matches(
        rule: CompatibilityAutomaticProcessPolicyRuleV1,
        rootAuthorization: CompatibilityManifestRootAuthorizationTokenV1,
        containment: CompatibilityManifestImageContainmentV1
    ) -> Bool {
        guard rule.schemaVersion == SteamCompatibilityLaunchProfileContractV1.processPolicySchemaVersion,
              rule.matcher == .gameGuardFamilyASCIIComponentOrFinalStem,
              rule.action == .excludeRendererEnvironmentAndRendererDLLOverrides,
              (try? rootAuthorization.validate()) != nil,
              case .contained(let authorizationDigest, let components) = containment,
              authorizationDigest == rootAuthorization.authorizationDigest,
              !components.isEmpty,
              components.allSatisfy(Self.isCompleteRelativePathComponent) else {
            return false
        }

        if components.contains(where: asciiCaseInsensitiveFamilyMatch) {
            return true
        }
        guard let finalComponent = components.last else { return false }
        return asciiCaseInsensitiveFamilyMatch(finalFileStem(of: finalComponent))
    }

    private static func isCompleteRelativePathComponent(_ component: String) -> Bool {
        !component.isEmpty &&
            component != "." &&
            component != ".." &&
            !component.contains("/") &&
            !component.contains("\\") &&
            !component.utf8.contains(0)
    }

    private static func finalFileStem(of component: String) -> String {
        guard let dot = component.lastIndex(of: "."),
              dot != component.startIndex,
              component.index(after: dot) != component.endIndex else {
            return component
        }
        return String(component[..<dot])
    }

    /// Matches one complete path component or the complete final filename
    /// stem. Folding is deliberately ASCII-only; prefixes such as
    /// `GameGuardians` and `GameGuardBackup` are not members of this rule.
    private static func asciiCaseInsensitiveFamilyMatch(_ candidate: String) -> Bool {
        let bytes = Array(candidate.utf8)
        guard bytes.count == exactASCIIName.count else { return false }
        return zip(bytes, exactASCIIName).allSatisfy {
            candidateByte, expectedByte in
            asciiLowercased(candidateByte) == asciiLowercased(expectedByte)
        }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}

struct CompatibilitySteamLaunchRuntimeCapabilitiesV1: Hashable, Sendable {
    let schemaVersion: Int
    let supportedProfileContractVersions: Set<Int>
    let supportedRecipeSchemaVersions: Set<Int>
    let supportedGraphicsBackends: Set<SteamGraphicsBackendIdentifier>
    let supportedNetworkPolicies: Set<SteamNetworkPolicyIdentifier>
    let supportedAudioInputPolicies: Set<SteamAudioInputPolicyIdentifier>
    let supportedSynchronizationPolicies: Set<SteamSynchronizationPolicyIdentifier>
    let supportedVideoMemoryPolicies: Set<SteamVideoMemoryPolicyIdentifier>
    let supportsGameModeSelection: Bool
    let supportsHeapZeroMemorySelection: Bool
    let supportedFPSCursorPolicies: Set<FPSCursorCapturePolicy>
    let supportedControllerPolicies: Set<ControllerCompatibilityPolicy>
    let supportedKeyboardPresets: Set<KeyboardMappingPreset>
    let supportsCustomKeyboardPermutation: Bool
    let supportedProcessMatchers: Set<CompatibilityAutomaticProcessMatcherV1>
    let supportedProcessPolicyActions: Set<CompatibilityAutomaticProcessPolicyActionV1>

    init(
        schemaVersion: Int = SteamCompatibilityLaunchProfileContractV1.capabilitySchemaVersion,
        supportedProfileContractVersions: Set<Int>,
        supportedRecipeSchemaVersions: Set<Int>,
        supportedGraphicsBackends: Set<SteamGraphicsBackendIdentifier>,
        supportedNetworkPolicies: Set<SteamNetworkPolicyIdentifier>,
        supportedAudioInputPolicies: Set<SteamAudioInputPolicyIdentifier>,
        supportedSynchronizationPolicies: Set<SteamSynchronizationPolicyIdentifier>,
        supportedVideoMemoryPolicies: Set<SteamVideoMemoryPolicyIdentifier>,
        supportsGameModeSelection: Bool,
        supportsHeapZeroMemorySelection: Bool,
        supportedFPSCursorPolicies: Set<FPSCursorCapturePolicy>,
        supportedControllerPolicies: Set<ControllerCompatibilityPolicy>,
        supportedKeyboardPresets: Set<KeyboardMappingPreset>,
        supportsCustomKeyboardPermutation: Bool,
        supportedProcessMatchers: Set<CompatibilityAutomaticProcessMatcherV1>,
        supportedProcessPolicyActions: Set<CompatibilityAutomaticProcessPolicyActionV1>
    ) {
        self.schemaVersion = schemaVersion
        self.supportedProfileContractVersions = supportedProfileContractVersions
        self.supportedRecipeSchemaVersions = supportedRecipeSchemaVersions
        self.supportedGraphicsBackends = supportedGraphicsBackends
        self.supportedNetworkPolicies = supportedNetworkPolicies
        self.supportedAudioInputPolicies = supportedAudioInputPolicies
        self.supportedSynchronizationPolicies = supportedSynchronizationPolicies
        self.supportedVideoMemoryPolicies = supportedVideoMemoryPolicies
        self.supportsGameModeSelection = supportsGameModeSelection
        self.supportsHeapZeroMemorySelection = supportsHeapZeroMemorySelection
        self.supportedFPSCursorPolicies = supportedFPSCursorPolicies
        self.supportedControllerPolicies = supportedControllerPolicies
        self.supportedKeyboardPresets = supportedKeyboardPresets
        self.supportsCustomKeyboardPermutation = supportsCustomKeyboardPermutation
        self.supportedProcessMatchers = supportedProcessMatchers
        self.supportedProcessPolicyActions = supportedProcessPolicyActions
    }

    func validate() throws {
        guard schemaVersion == SteamCompatibilityLaunchProfileContractV1.capabilitySchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "capability-schema-version",
                value: String(schemaVersion)
            )
        }
    }

    static func supporting(
        recipe: SteamCompatibilityLaunchProfileRecipeV1
    ) -> CompatibilitySteamLaunchRuntimeCapabilitiesV1 {
        CompatibilitySteamLaunchRuntimeCapabilitiesV1(
            supportedProfileContractVersions: [recipe.contractVersion],
            supportedRecipeSchemaVersions: [recipe.schemaVersion],
            supportedGraphicsBackends: Set(recipe.supportedOptions.graphicsBackends),
            supportedNetworkPolicies: Set(recipe.supportedOptions.networkPolicies),
            supportedAudioInputPolicies: Set(recipe.supportedOptions.audioInputPolicies),
            supportedSynchronizationPolicies: Set(recipe.supportedOptions.synchronizationPolicies),
            supportedVideoMemoryPolicies: Set(recipe.supportedOptions.videoMemoryPolicies),
            supportsGameModeSelection: true,
            supportsHeapZeroMemorySelection: true,
            supportedFPSCursorPolicies: Set(recipe.supportedOptions.fpsCursorPolicies),
            supportedControllerPolicies: Set(recipe.supportedOptions.controllerPolicies),
            supportedKeyboardPresets: Set(recipe.supportedOptions.keyboardPresets),
            supportsCustomKeyboardPermutation: recipe.supportedOptions.supportsCustomKeyboardPermutation,
            supportedProcessMatchers: Set(recipe.automaticRequiredPolicies.map(\.matcher)),
            supportedProcessPolicyActions: Set(recipe.automaticRequiredPolicies.map(\.action))
        )
    }
}

struct CompatibilitySteamLaunchOneLaunchOverrideV1: Hashable, Sendable {
    let identity: SteamCompatibilityProfileIdentity
    var graphicsBackend: SteamGraphicsBackendIdentifier?
    var networkPolicy: SteamNetworkPolicyIdentifier?
    var audioInputPolicy: SteamAudioInputPolicyIdentifier?
    var synchronizationPolicy: SteamSynchronizationPolicyIdentifier?
    var videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier?
    var gameModeEnabled: Bool?
    var heapZeroMemoryEnabled: Bool?
    var fpsCursorPolicy: FPSCursorCapturePolicy?
    var controllerPolicy: ControllerCompatibilityPolicy?
    var keyboardMapping: KeyboardMappingPreference?
    var replacementAutomaticPolicyRuleIDs: Set<String>?

    init(identity: SteamCompatibilityProfileIdentity) {
        self.identity = identity
    }
}

struct ResolvedCompatibilitySteamLaunchSnapshotV1: Hashable, Sendable {
    let graphicsBackend: CompatibilityResolvedValueV1<SteamGraphicsBackendIdentifier>
    let networkPolicy: CompatibilityResolvedValueV1<SteamNetworkPolicyIdentifier>
    let audioInputPolicy: CompatibilityResolvedValueV1<SteamAudioInputPolicyIdentifier>
    let synchronizationPolicy: CompatibilityResolvedValueV1<SteamSynchronizationPolicyIdentifier>
    let videoMemoryPolicy: CompatibilityResolvedValueV1<SteamVideoMemoryPolicyIdentifier>
    let gameModeEnabled: CompatibilityResolvedValueV1<Bool>
    let heapZeroMemoryEnabled: CompatibilityResolvedValueV1<Bool>
    let fpsCursorPolicy: CompatibilityResolvedValueV1<FPSCursorCapturePolicy>
    let controllerPolicy: CompatibilityResolvedValueV1<ControllerCompatibilityPolicy>
    let keyboardMapping: CompatibilityResolvedValueV1<KeyboardMappingPreference>
    let automaticRequiredPolicies: [
        CompatibilityResolvedValueV1<CompatibilityAutomaticProcessPolicyRuleV1>
    ]
}

struct ResolvedCompatibilityLaunchRequestV1: Hashable, Sendable {
    static let canonicalHeader = Data("forgeplay-steam-compatibility-request-v1\n".utf8)

    let schemaVersion: Int
    let profileContractVersion: Int
    let recipeSchemaVersion: Int
    let identity: SteamCompatibilityProfileIdentity
    let manifestRootAuthorization: CompatibilityManifestRootAuthorizationTokenV1
    let snapshot: ResolvedCompatibilitySteamLaunchSnapshotV1
    let transactionID: UUID
    let canonicalPayload: Data
    let canonicalDigest: String

    init(
        profileContractVersion: Int,
        recipeSchemaVersion: Int,
        identity: SteamCompatibilityProfileIdentity,
        manifestRootAuthorization: CompatibilityManifestRootAuthorizationTokenV1,
        snapshot: ResolvedCompatibilitySteamLaunchSnapshotV1,
        transactionID: UUID
    ) throws {
        schemaVersion = SteamCompatibilityLaunchProfileContractV1.requestSchemaVersion
        self.profileContractVersion = profileContractVersion
        self.recipeSchemaVersion = recipeSchemaVersion
        self.identity = identity
        self.manifestRootAuthorization = manifestRootAuthorization
        self.snapshot = snapshot
        self.transactionID = transactionID
        let payload = try Self.makeCanonicalPayload(
            schemaVersion: schemaVersion,
            profileContractVersion: profileContractVersion,
            recipeSchemaVersion: recipeSchemaVersion,
            identity: identity,
            manifestRootAuthorization: manifestRootAuthorization,
            snapshot: snapshot,
            transactionID: transactionID
        )
        canonicalPayload = payload
        canonicalDigest = SteamLaunchIdentifierValidation.lowercaseSHA256(payload)
        try validate()
    }

    func validate() throws {
        guard schemaVersion == SteamCompatibilityLaunchProfileContractV1.requestSchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "request-schema-version"
            )
        }
        try manifestRootAuthorization.validate()
        guard transactionID.uuidString.lowercased() != "00000000-0000-0000-0000-000000000000" else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "transaction-id"
            )
        }
        let expected = try Self.makeCanonicalPayload(
            schemaVersion: schemaVersion,
            profileContractVersion: profileContractVersion,
            recipeSchemaVersion: recipeSchemaVersion,
            identity: identity,
            manifestRootAuthorization: manifestRootAuthorization,
            snapshot: snapshot,
            transactionID: transactionID
        )
        guard expected == canonicalPayload,
              canonicalDigest == SteamLaunchIdentifierValidation.lowercaseSHA256(expected) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "request-digest"
            )
        }
    }

    private static func makeCanonicalPayload(
        schemaVersion: Int,
        profileContractVersion: Int,
        recipeSchemaVersion: Int,
        identity: SteamCompatibilityProfileIdentity,
        manifestRootAuthorization: CompatibilityManifestRootAuthorizationTokenV1,
        snapshot: ResolvedCompatibilitySteamLaunchSnapshotV1,
        transactionID: UUID
    ) throws -> Data {
        try manifestRootAuthorization.validate()
        var encoder = SteamCompatibilityCanonicalEncoderV1(header: canonicalHeader)
        encoder.append(name: "schemaVersion", value: String(schemaVersion))
        encoder.append(name: "profileContractVersion", value: String(profileContractVersion))
        encoder.append(name: "recipeSchemaVersion", value: String(recipeSchemaVersion))
        encoder.append(name: "steamAppID", value: identity.steamAppID)
        encoder.append(name: "profileID", value: identity.profileID)
        encoder.append(name: "recipeRevision", value: identity.recipeRevision)
        encoder.append(name: "configurationIdentity", value: identity.deterministicRecordID)
        encoder.append(
            name: "manifestAuthorizationSchemaVersion",
            value: String(manifestRootAuthorization.authorizationSchemaVersion)
        )
        encoder.append(
            name: "manifestAuthorizationProviderID",
            value: manifestRootAuthorization.providerID
        )
        encoder.append(
            name: "manifestSourceBookmarkDigest",
            value: manifestRootAuthorization.sourceBookmarkDigest
        )
        encoder.append(
            name: "manifestAuthorizationDigest",
            value: manifestRootAuthorization.authorizationDigest
        )
        encoder.append(
            name: "manifestPinnedObjectIdentityDigest",
            value: manifestRootAuthorization.pinnedObjectIdentityDigest
        )
        append(snapshot.graphicsBackend, name: "graphicsBackend", rawValue: \.rawValue, to: &encoder)
        append(snapshot.networkPolicy, name: "networkPolicy", rawValue: \.rawValue, to: &encoder)
        append(snapshot.audioInputPolicy, name: "audioInputPolicy", rawValue: \.rawValue, to: &encoder)
        append(snapshot.synchronizationPolicy, name: "synchronizationPolicy", rawValue: \.rawValue, to: &encoder)
        append(snapshot.videoMemoryPolicy, name: "videoMemoryPolicy", rawValue: \.rawValue, to: &encoder)
        append(snapshot.gameModeEnabled, name: "gameModeEnabled", rawValue: { $0 ? "1" : "0" }, to: &encoder)
        append(snapshot.heapZeroMemoryEnabled, name: "heapZeroMemoryEnabled", rawValue: { $0 ? "1" : "0" }, to: &encoder)
        append(snapshot.fpsCursorPolicy, name: "fpsCursorPolicy", rawValue: \.rawValue, to: &encoder)
        append(snapshot.controllerPolicy, name: "controllerPolicy", rawValue: \.rawValue, to: &encoder)

        let keyboard = snapshot.keyboardMapping.value
        let custom = keyboard.customPermutation
        encoder.append(name: "keyboardPreset", value: keyboard.preset.rawValue)
        encoder.append(name: "keyboardMappingProvenance", value: snapshot.keyboardMapping.provenance.rawValue)
        encoder.append(name: "hasCustomPermutation", value: custom == nil ? "0" : "1")
        encoder.append(name: "customCommandRole", value: custom?.command.rawValue ?? "-")
        encoder.append(name: "customOptionRole", value: custom?.option.rawValue ?? "-")
        encoder.append(name: "customControlRole", value: custom?.control.rawValue ?? "-")

        encoder.append(
            name: "automaticPolicyCount",
            value: String(snapshot.automaticRequiredPolicies.count)
        )
        for (index, resolvedRule) in snapshot.automaticRequiredPolicies.enumerated() {
            let prefix = "automaticPolicy\(index)"
            encoder.append(name: "\(prefix)SchemaVersion", value: String(resolvedRule.value.schemaVersion))
            encoder.append(name: "\(prefix)RuleID", value: resolvedRule.value.ruleID)
            encoder.append(name: "\(prefix)Matcher", value: resolvedRule.value.matcher.rawValue)
            encoder.append(name: "\(prefix)Action", value: resolvedRule.value.action.rawValue)
            encoder.append(name: "\(prefix)Provenance", value: resolvedRule.provenance.rawValue)
        }
        encoder.append(name: "transactionID", value: transactionID.uuidString.lowercased())
        return encoder.data
    }

    private static func append<Value: Hashable & Sendable>(
        _ resolved: CompatibilityResolvedValueV1<Value>,
        name: String,
        rawValue: (Value) -> String,
        to encoder: inout SteamCompatibilityCanonicalEncoderV1
    ) {
        encoder.append(name: name, value: rawValue(resolved.value))
        encoder.append(name: "\(name)Provenance", value: resolved.provenance.rawValue)
    }
}

enum SteamCompatibilityLaunchResolverV1 {
    static func resolveDraft(
        recipe: SteamCompatibilityLaunchProfileRecipeV1,
        savedPreference: CompatibilitySteamLaunchPreferenceEnvelopeV1?,
        oneLaunchOverride: CompatibilitySteamLaunchOneLaunchOverrideV1? = nil
    ) throws -> ResolvedCompatibilitySteamLaunchSnapshotV1 {
        try recipe.validate()

        var graphicsBackend = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.graphicsBackend,
            provenance: .recipe
        )
        var networkPolicy = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.networkPolicy,
            provenance: .recipe
        )
        var audioInputPolicy = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.audioInputPolicy,
            provenance: .recipe
        )
        var synchronizationPolicy = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.synchronizationPolicy,
            provenance: .recipe
        )
        var videoMemoryPolicy = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.videoMemoryPolicy,
            provenance: .recipe
        )
        var gameModeEnabled = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.gameModeEnabled,
            provenance: .recipe
        )
        var heapZeroMemoryEnabled = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.heapZeroMemoryEnabled,
            provenance: .recipe
        )
        var fpsCursorPolicy = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.fpsCursorPolicy,
            provenance: .recipe
        )
        var controllerPolicy = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.controllerPolicy,
            provenance: .recipe
        )
        var keyboardMapping = CompatibilityResolvedValueV1(
            value: recipe.initialSelections.keyboardMapping,
            provenance: .recipe
        )

        if let savedPreference {
            try savedPreference.validate()
            try requireIdentity(savedPreference.payload.identity, matches: recipe.identity)
            let selections = savedPreference.payload.selections
            graphicsBackend = .init(value: selections.graphicsBackend, provenance: .savedPreference)
            networkPolicy = .init(value: selections.networkPolicy, provenance: .savedPreference)
            audioInputPolicy = .init(value: selections.audioInputPolicy, provenance: .savedPreference)
            synchronizationPolicy = .init(value: selections.synchronizationPolicy, provenance: .savedPreference)
            videoMemoryPolicy = .init(value: selections.videoMemoryPolicy, provenance: .savedPreference)
            gameModeEnabled = .init(value: selections.gameModeEnabled, provenance: .savedPreference)
            heapZeroMemoryEnabled = .init(value: selections.heapZeroMemoryEnabled, provenance: .savedPreference)
            fpsCursorPolicy = .init(value: selections.fpsCursorPolicy, provenance: .savedPreference)
            controllerPolicy = .init(value: selections.controllerPolicy, provenance: .savedPreference)
            keyboardMapping = .init(value: selections.keyboardMapping, provenance: .savedPreference)
        }

        if let oneLaunchOverride {
            try requireIdentity(oneLaunchOverride.identity, matches: recipe.identity)
            let requiredRuleIDs = Set(recipe.automaticRequiredPolicies.map(\.ruleID))
            if let replacement = oneLaunchOverride.replacementAutomaticPolicyRuleIDs,
               replacement != requiredRuleIDs {
                throw SteamCompatibilityLaunchProfileErrorV1.attemptedAutomaticPolicyRemoval
            }
            if let value = oneLaunchOverride.graphicsBackend {
                graphicsBackend = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.networkPolicy {
                networkPolicy = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.audioInputPolicy {
                audioInputPolicy = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.synchronizationPolicy {
                synchronizationPolicy = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.videoMemoryPolicy {
                videoMemoryPolicy = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.gameModeEnabled {
                gameModeEnabled = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.heapZeroMemoryEnabled {
                heapZeroMemoryEnabled = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.fpsCursorPolicy {
                fpsCursorPolicy = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.controllerPolicy {
                controllerPolicy = .init(value: value, provenance: .oneLaunchOverride)
            }
            if let value = oneLaunchOverride.keyboardMapping {
                keyboardMapping = .init(value: value, provenance: .oneLaunchOverride)
            }
        }

        let resolved = ResolvedCompatibilitySteamLaunchSnapshotV1(
            graphicsBackend: graphicsBackend,
            networkPolicy: networkPolicy,
            audioInputPolicy: audioInputPolicy,
            synchronizationPolicy: synchronizationPolicy,
            videoMemoryPolicy: videoMemoryPolicy,
            gameModeEnabled: gameModeEnabled,
            heapZeroMemoryEnabled: heapZeroMemoryEnabled,
            fpsCursorPolicy: fpsCursorPolicy,
            controllerPolicy: controllerPolicy,
            keyboardMapping: keyboardMapping,
            automaticRequiredPolicies: recipe.automaticRequiredPolicies.map {
                CompatibilityResolvedValueV1(value: $0, provenance: .automaticRequired)
            }
        )
        try validateRecipeSupport(resolved, recipe: recipe)
        return resolved
    }

    static func resolve(
        recipe: SteamCompatibilityLaunchProfileRecipeV1,
        manifestRootAuthorization: CompatibilityManifestRootAuthorizationTokenV1,
        savedPreference: CompatibilitySteamLaunchPreferenceEnvelopeV1?,
        oneLaunchOverride: CompatibilitySteamLaunchOneLaunchOverrideV1? = nil,
        capabilities: CompatibilitySteamLaunchRuntimeCapabilitiesV1,
        transactionID: UUID
    ) throws -> ResolvedCompatibilityLaunchRequestV1 {
        try recipe.validate()
        try manifestRootAuthorization.validate()
        try capabilities.validate()
        guard capabilities.supportedProfileContractVersions.contains(recipe.contractVersion) else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "profile-contract-version",
                value: String(recipe.contractVersion)
            )
        }
        guard capabilities.supportedRecipeSchemaVersions.contains(recipe.schemaVersion) else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "recipe-schema-version",
                value: String(recipe.schemaVersion)
            )
        }
        let snapshot = try resolveDraft(
            recipe: recipe,
            savedPreference: savedPreference,
            oneLaunchOverride: oneLaunchOverride
        )

        try requireCapability(snapshot.graphicsBackend.value, in: capabilities.supportedGraphicsBackends, category: "graphics-backend", rawValue: snapshot.graphicsBackend.value.rawValue)
        try requireCapability(snapshot.networkPolicy.value, in: capabilities.supportedNetworkPolicies, category: "network-policy", rawValue: snapshot.networkPolicy.value.rawValue)
        try requireCapability(snapshot.audioInputPolicy.value, in: capabilities.supportedAudioInputPolicies, category: "audio-input-policy", rawValue: snapshot.audioInputPolicy.value.rawValue)
        try requireCapability(snapshot.synchronizationPolicy.value, in: capabilities.supportedSynchronizationPolicies, category: "synchronization-policy", rawValue: snapshot.synchronizationPolicy.value.rawValue)
        try requireCapability(snapshot.videoMemoryPolicy.value, in: capabilities.supportedVideoMemoryPolicies, category: "video-memory-policy", rawValue: snapshot.videoMemoryPolicy.value.rawValue)
        guard capabilities.supportsGameModeSelection else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "game-mode",
                value: snapshot.gameModeEnabled.value ? "1" : "0"
            )
        }
        guard capabilities.supportsHeapZeroMemorySelection else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "heap-zero-memory",
                value: snapshot.heapZeroMemoryEnabled.value ? "1" : "0"
            )
        }
        try requireCapability(snapshot.fpsCursorPolicy.value, in: capabilities.supportedFPSCursorPolicies, category: "fps-cursor-policy", rawValue: snapshot.fpsCursorPolicy.value.rawValue)
        try requireCapability(snapshot.controllerPolicy.value, in: capabilities.supportedControllerPolicies, category: "controller-policy", rawValue: snapshot.controllerPolicy.value.rawValue)
        try requireCapability(snapshot.keyboardMapping.value.preset, in: capabilities.supportedKeyboardPresets, category: "keyboard-preset", rawValue: snapshot.keyboardMapping.value.preset.rawValue)
        if snapshot.keyboardMapping.value.customPermutation != nil,
           !capabilities.supportsCustomKeyboardPermutation {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "custom-keyboard-permutation",
                value: "custom"
            )
        }

        for resolvedRule in snapshot.automaticRequiredPolicies {
            let rule = resolvedRule.value
            guard capabilities.supportedProcessMatchers.contains(rule.matcher) else {
                throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                    category: "process-policy-matcher",
                    value: rule.matcher.rawValue
                )
            }
            guard capabilities.supportedProcessPolicyActions.contains(rule.action) else {
                throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                    category: "process-policy-action",
                    value: rule.action.rawValue
                )
            }
        }

        return try ResolvedCompatibilityLaunchRequestV1(
            profileContractVersion: recipe.contractVersion,
            recipeSchemaVersion: recipe.schemaVersion,
            identity: recipe.identity,
            manifestRootAuthorization: manifestRootAuthorization,
            snapshot: snapshot,
            transactionID: transactionID
        )
    }

    private static func validateRecipeSupport(
        _ snapshot: ResolvedCompatibilitySteamLaunchSnapshotV1,
        recipe: SteamCompatibilityLaunchProfileRecipeV1
    ) throws {
        try requireRecipeSupport(snapshot.graphicsBackend.value, in: recipe.supportedOptions.graphicsBackends, category: "recipe.graphics-backend")
        try requireRecipeSupport(snapshot.networkPolicy.value, in: recipe.supportedOptions.networkPolicies, category: "recipe.network-policy")
        try requireRecipeSupport(snapshot.audioInputPolicy.value, in: recipe.supportedOptions.audioInputPolicies, category: "recipe.audio-input-policy")
        try requireRecipeSupport(snapshot.synchronizationPolicy.value, in: recipe.supportedOptions.synchronizationPolicies, category: "recipe.synchronization-policy")
        try requireRecipeSupport(snapshot.videoMemoryPolicy.value, in: recipe.supportedOptions.videoMemoryPolicies, category: "recipe.video-memory-policy")
        try requireRecipeSupport(snapshot.fpsCursorPolicy.value, in: recipe.supportedOptions.fpsCursorPolicies, category: "recipe.fps-cursor-policy")
        try requireRecipeSupport(snapshot.controllerPolicy.value, in: recipe.supportedOptions.controllerPolicies, category: "recipe.controller-policy")
        try requireRecipeSupport(snapshot.keyboardMapping.value.preset, in: recipe.supportedOptions.keyboardPresets, category: "recipe.keyboard-preset")
        if snapshot.keyboardMapping.value.customPermutation != nil,
           !recipe.supportedOptions.supportsCustomKeyboardPermutation {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "recipe.custom-keyboard-permutation",
                value: "custom"
            )
        }
    }

    private static func requireIdentity(
        _ actual: SteamCompatibilityProfileIdentity,
        matches expected: SteamCompatibilityProfileIdentity
    ) throws {
        guard actual == expected else {
            throw SteamCompatibilityLaunchProfileErrorV1.identityMismatch(
                expected: expected.deterministicRecordID,
                actual: actual.deterministicRecordID
            )
        }
    }

    private static func requireRecipeSupport<Value: Hashable>(
        _ value: Value,
        in values: [Value],
        category: String
    ) throws {
        guard values.contains(value) else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: category,
                value: String(describing: value)
            )
        }
    }

    private static func requireCapability<Value: Hashable>(
        _ value: Value,
        in values: Set<Value>,
        category: String,
        rawValue: String
    ) throws {
        guard values.contains(value) else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: category,
                value: rawValue
            )
        }
    }
}

struct CompatibilityRuntimeComponentMutationEvidenceV1: Hashable, Sendable {
    let componentID: String
    let beforeDigest: String
    let afterDigest: String
    let readbackDigest: String

    var didMutate: Bool {
        beforeDigest != afterDigest && afterDigest == readbackDigest
    }

    func validate() throws {
        guard SteamLaunchIdentifierValidation.isValid(
            componentID,
            maximumUTF8Bytes: 64
        ), [beforeDigest, afterDigest, readbackDigest].allSatisfy({
            SteamLaunchIdentifierValidation.isValidLowercaseSHA256($0)
        }), afterDigest == readbackDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "component-mutation-evidence"
            )
        }
    }
}

struct CompatibilityRuntimeApplicationEvidenceV1: Hashable, Sendable {
    static let expectedMutationComponentIDs: Set<String> = [
        "controller",
        "fonts",
        "input",
        "persistent-prefix",
        "renderer",
        "synchronization"
    ]

    let appliedRequestDigest: String?
    let capturedBaselineDigest: String?
    let appliedStateDigest: String?
    let providerReadbackDigest: String?
    let componentMutationEvidence:
        [CompatibilityRuntimeComponentMutationEvidenceV1]
    var observedMutationCount: Int {
        componentMutationEvidence.filter(\.didMutate).count
    }
    let restoredBaselineDigest: String?

    init(
        appliedRequestDigest: String? = nil,
        capturedBaselineDigest: String? = nil,
        appliedStateDigest: String? = nil,
        providerReadbackDigest: String? = nil,
        componentMutationEvidence:
            [CompatibilityRuntimeComponentMutationEvidenceV1] = [],
        restoredBaselineDigest: String? = nil
    ) throws {
        self.appliedRequestDigest = appliedRequestDigest
        self.capturedBaselineDigest = capturedBaselineDigest
        self.appliedStateDigest = appliedStateDigest
        self.providerReadbackDigest = providerReadbackDigest
        self.componentMutationEvidence = componentMutationEvidence
        self.restoredBaselineDigest = restoredBaselineDigest
        try validate()
    }

    func validate() throws {
        for digest in [
            appliedRequestDigest,
            capturedBaselineDigest,
            appliedStateDigest,
            providerReadbackDigest,
            restoredBaselineDigest
        ].compactMap({ $0 }) {
            guard SteamLaunchIdentifierValidation.isValidLowercaseSHA256(digest) else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt("evidence-digest")
            }
        }
        let hasPreparationEvidence = appliedStateDigest != nil ||
            providerReadbackDigest != nil || !componentMutationEvidence.isEmpty
        if hasPreparationEvidence {
            guard appliedRequestDigest != nil,
                  let capturedBaselineDigest,
                  let appliedStateDigest,
                  let providerReadbackDigest,
                  observedMutationCount > 0,
                  appliedStateDigest != capturedBaselineDigest,
                  providerReadbackDigest != capturedBaselineDigest,
                  providerReadbackDigest != appliedStateDigest else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "successful-preparation-evidence-required"
                )
            }
            let componentIDs = componentMutationEvidence.map(\.componentID)
            guard Set(componentIDs) == Self.expectedMutationComponentIDs,
                  componentIDs.count == Self.expectedMutationComponentIDs.count,
                  componentIDs == componentIDs.sorted() else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "component-mutation-closure"
                )
            }
            try componentMutationEvidence.forEach { try $0.validate() }
        }
        guard appliedRequestDigest == nil || capturedBaselineDigest != nil else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "applied-without-captured"
            )
        }
        guard restoredBaselineDigest == nil ||
            (appliedRequestDigest != nil &&
                restoredBaselineDigest == capturedBaselineDigest) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "restored-baseline"
            )
        }
    }
}

struct CompatibilityLaunchApplicationReceiptV1: Hashable, Sendable {
    let schemaVersion: Int
    let providerID: String
    let receiptID: String
    let requestDigest: String
    let transactionID: UUID
    let evidence: CompatibilityRuntimeApplicationEvidenceV1

    init(
        schemaVersion: Int = SteamCompatibilityLaunchProfileContractV1.runtimeReceiptSchemaVersion,
        providerID: String,
        receiptID: String,
        requestDigest: String,
        transactionID: UUID,
        evidence: CompatibilityRuntimeApplicationEvidenceV1
    ) throws {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.receiptID = receiptID
        self.requestDigest = requestDigest
        self.transactionID = transactionID
        self.evidence = evidence
        try validate()
    }

    func validate() throws {
        guard schemaVersion == SteamCompatibilityLaunchProfileContractV1.runtimeReceiptSchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt("schema-version")
        }
        guard SteamLaunchIdentifierValidation.isValid(providerID, maximumUTF8Bytes: 128),
              SteamLaunchIdentifierValidation.isValid(receiptID, maximumUTF8Bytes: 128),
              SteamLaunchIdentifierValidation.isValidLowercaseSHA256(requestDigest),
              transactionID.uuidString.lowercased() != "00000000-0000-0000-0000-000000000000" else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt("identity")
        }
        try evidence.validate()
        guard let applied = evidence.appliedRequestDigest,
              evidence.capturedBaselineDigest != nil,
              evidence.appliedStateDigest != nil,
              evidence.providerReadbackDigest != nil,
              !evidence.componentMutationEvidence.isEmpty,
              applied == requestDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "applied-request-digest"
            )
        }
    }

    func validate(for request: ResolvedCompatibilityLaunchRequestV1) throws {
        try validate()
        try request.validate()
        guard requestDigest == request.canonicalDigest,
              transactionID == request.transactionID else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "request-binding"
            )
        }
    }
}

struct CompatibilityLaunchRecordProjectionV1: Hashable, Sendable {
    let identity: SteamCompatibilityProfileIdentity
    let resolvedRequestDigest: String
    let transactionID: UUID
    let providerReceiptID: String?
    let appliedRequestDigest: String?
    let capturedBaselineDigest: String?
    let restoredBaselineDigest: String?

    init(
        request: ResolvedCompatibilityLaunchRequestV1,
        receipt: CompatibilityLaunchApplicationReceiptV1?
    ) throws {
        try request.validate()
        if let receipt {
            try receipt.validate(for: request)
        }
        identity = request.identity
        resolvedRequestDigest = request.canonicalDigest
        transactionID = request.transactionID
        providerReceiptID = receipt?.receiptID
        appliedRequestDigest = receipt?.evidence.appliedRequestDigest
        capturedBaselineDigest = receipt?.evidence.capturedBaselineDigest
        restoredBaselineDigest = receipt?.evidence.restoredBaselineDigest
    }
}

enum CompatibilityCompletionRendezvousError: LocalizedError, Equatable, Sendable {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Steam 호환성 세션 기준 상태 복원이 제한 시간 안에 완료되지 않았습니다. 복원 소유권은 유지됩니다."
        }
    }
}

/// Coalesces automatic, user-requested, and application-termination completion
/// callers onto one provider-owned operation. A timed-out or cancelled waiter
/// never clears the in-flight operation; a later caller can join the same task
/// and consume its verified result without starting a second restoration.
@MainActor
final class CompatibilityCompletionRendezvous<Value: Sendable> {
    struct Attempt: Sendable {
        fileprivate let id: UUID
        fileprivate let task: Task<Value, Error>
    }

    private final class WaitGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var isResolved = false

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let shouldResumeCancellation = lock.withLock { () -> Bool in
                if isResolved {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if shouldResumeCancellation {
                continuation.resume(throwing: CancellationError())
            }
        }

        func resolve(_ result: Result<Value, Error>) {
            let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
                guard !isResolved else { return nil }
                isResolved = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private var activeAttempt: Attempt?

    var hasActiveAttempt: Bool {
        activeAttempt != nil
    }

    func startOrJoin(
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) -> (attempt: Attempt, didStart: Bool) {
        if let activeAttempt {
            return (activeAttempt, false)
        }
        let attempt = Attempt(
            id: UUID(),
            task: Task { @MainActor in
                try await operation()
            }
        )
        activeAttempt = attempt
        return (attempt, true)
    }

    func wait(
        for attempt: Attempt,
        timeoutNanoseconds: UInt64
    ) async throws -> Value {
        guard timeoutNanoseconds > 0 else {
            throw CompatibilityCompletionRendezvousError.timedOut
        }
        let gate = WaitGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task {
                    gate.resolve(await attempt.task.result)
                }
                Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    gate.resolve(
                        .failure(CompatibilityCompletionRendezvousError.timedOut)
                    )
                }
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }

    /// Clears only the exact operation observed by the caller. Callers must not
    /// invoke this after a waiter timeout or cancellation because the shared
    /// operation can still be mutating the retained prefix.
    @discardableResult
    func finish(_ attempt: Attempt) -> Bool {
        guard activeAttempt?.id == attempt.id else { return false }
        activeAttempt = nil
        return true
    }
}

@MainActor
protocol CompatibilityLaunchRuntimeProviderV1: Sendable {
    func capabilities() async throws -> CompatibilitySteamLaunchRuntimeCapabilitiesV1
    func prepareSteamSession(
        request: ResolvedCompatibilityLaunchRequestV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1
    func completeSteamSession(
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1
    func completeSteamSessionForApplicationTermination(
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1
}

enum CompatibilityLaunchRuntimeProviderUnavailableErrorV1: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        "Steam 호환성 실행 런타임 제공자가 아직 연결되지 않았습니다. 환경설정은 저장할 수 있지만 Steam 세션 준비는 시작되지 않았습니다."
    }
}

struct UnavailableCompatibilityLaunchRuntimeProviderV1: CompatibilityLaunchRuntimeProviderV1 {
    func capabilities() async throws -> CompatibilitySteamLaunchRuntimeCapabilitiesV1 {
        throw CompatibilityLaunchRuntimeProviderUnavailableErrorV1.unavailable
    }

    func prepareSteamSession(
        request: ResolvedCompatibilityLaunchRequestV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        _ = request
        throw CompatibilityLaunchRuntimeProviderUnavailableErrorV1.unavailable
    }

    func completeSteamSession(
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        _ = receipt
        throw CompatibilityLaunchRuntimeProviderUnavailableErrorV1.unavailable
    }

    func completeSteamSessionForApplicationTermination(
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        _ = receipt
        throw CompatibilityLaunchRuntimeProviderUnavailableErrorV1.unavailable
    }
}

@MainActor
struct SteamCompatibilityLaunchCoordinatorV1: Sendable {
    private let manifestRootAuthorizationProvider:
        any CompatibilityManifestRootAuthorizationProviderV1
    private let runtimeProvider: any CompatibilityLaunchRuntimeProviderV1

    init(
        manifestRootAuthorizationProvider:
            any CompatibilityManifestRootAuthorizationProviderV1,
        runtimeProvider: any CompatibilityLaunchRuntimeProviderV1
    ) {
        self.manifestRootAuthorizationProvider = manifestRootAuthorizationProvider
        self.runtimeProvider = runtimeProvider
    }

    func prepareSteamSession(
        recipe: SteamCompatibilityLaunchProfileRecipeV1,
        unresolvedManifestRootBookmark: CompatibilityUnresolvedManifestRootBookmarkV1,
        savedPreference: CompatibilitySteamLaunchPreferenceEnvelopeV1?,
        oneLaunchOverride: CompatibilitySteamLaunchOneLaunchOverrideV1? = nil,
        transactionID: UUID = UUID()
    ) async throws -> CompatibilitySteamLaunchPreparationV1 {
        try unresolvedManifestRootBookmark.validate()
        let manifestRootAuthorization = try await manifestRootAuthorizationProvider
            .resolveAndPinManifestRoot(bookmark: unresolvedManifestRootBookmark)
        try manifestRootAuthorization.validate(for: unresolvedManifestRootBookmark)
        let capabilities = try await runtimeProvider.capabilities()
        let request = try SteamCompatibilityLaunchResolverV1.resolve(
            recipe: recipe,
            manifestRootAuthorization: manifestRootAuthorization,
            savedPreference: savedPreference,
            oneLaunchOverride: oneLaunchOverride,
            capabilities: capabilities,
            transactionID: transactionID
        )
        let receipt = try await runtimeProvider.prepareSteamSession(request: request)
        try receipt.validate(for: request)
        return try CompatibilitySteamLaunchPreparationV1(
            request: request,
            receipt: receipt
        )
    }
}

struct CompatibilitySteamLaunchPreparationV1: Hashable, Sendable {
    let request: ResolvedCompatibilityLaunchRequestV1
    let receipt: CompatibilityLaunchApplicationReceiptV1
    let launchRecordProjection: CompatibilityLaunchRecordProjectionV1

    init(
        request: ResolvedCompatibilityLaunchRequestV1,
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) throws {
        try receipt.validate(for: request)
        self.request = request
        self.receipt = receipt
        launchRecordProjection = try CompatibilityLaunchRecordProjectionV1(
            request: request,
            receipt: receipt
        )
    }
}
