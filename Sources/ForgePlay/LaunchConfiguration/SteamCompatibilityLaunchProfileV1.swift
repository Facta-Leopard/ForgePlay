import CryptoKit
import Foundation

enum SteamCompatibilityLaunchProfileErrorV1: LocalizedError, Equatable, Sendable {
    case unsupportedContractVersion(Int)
    case unsupportedRecipeSchemaVersion(Int)
    case invalidRecipe(String)
    case identityMismatch(expected: String, actual: String)
    case invalidPreference(String)
    case invalidCanonicalPayload(String)
    case invalidManifestRootAuthorization(String)
    case attemptedAutomaticPolicyRemoval
    case unsupportedCapability(category: String, value: String)
    case invalidReceipt(String)
    case migrationRejected(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedContractVersion(let version):
            "지원하지 않는 Steam 호환성 프로필 계약 버전입니다: \(version)"
        case .unsupportedRecipeSchemaVersion(let version):
            "지원하지 않는 Steam 호환성 레시피 버전입니다: \(version)"
        case .invalidRecipe(let reason):
            "Steam 호환성 레시피가 올바르지 않습니다: \(reason)"
        case .identityMismatch(let expected, let actual):
            "Steam 호환성 프로필 식별자가 일치하지 않습니다: expected=\(expected), actual=\(actual)"
        case .invalidPreference(let reason):
            "Steam 호환성 실행 환경설정이 올바르지 않습니다: \(reason)"
        case .invalidCanonicalPayload(let reason):
            "저장된 Steam 호환성 실행 환경설정을 읽지 못했습니다: \(reason)"
        case .invalidManifestRootAuthorization(let reason):
            "선택한 Steam 매니페스트 루트 권한을 확인하지 못했습니다: \(reason)"
        case .attemptedAutomaticPolicyRemoval:
            "필수 자동 렌더러 제외 정책은 사용자 설정으로 제거할 수 없습니다."
        case .unsupportedCapability(let category, let value):
            "현재 런타임 제공자가 이 Steam 호환성 옵션을 지원하지 않습니다: \(category)=\(value)"
        case .invalidReceipt(let reason):
            "Steam 호환성 런타임 적용 영수증이 요청과 일치하지 않습니다: \(reason)"
        case .migrationRejected(let reason):
            "이전 Steam 호환성 스냅샷을 변환하지 못했습니다: \(reason)"
        }
    }
}

enum SteamCompatibilityLaunchProfileContractV1 {
    static let contractVersion = 1
    static let recipeSchemaVersion = 1
    static let preferenceSchemaVersion = 1
    static let requestSchemaVersion = 1
    static let capabilitySchemaVersion = 1
    static let processPolicySchemaVersion = 1
    static let runtimeReceiptSchemaVersion = 1
}

enum CompatibilityAutomaticProcessMatcherV1: String, Codable, Hashable, Sendable {
    case gameGuardFamilyASCIIComponentOrFinalStem
}

enum CompatibilityAutomaticProcessPolicyActionV1: String, Codable, Hashable, Sendable {
    case excludeRendererEnvironmentAndRendererDLLOverrides
}

struct CompatibilityAutomaticProcessPolicyRuleV1: Codable, Hashable, Sendable {
    fileprivate static let rendererExclusionGameGuardBuiltIn = Self(
        validatedSchemaVersion:
            SteamCompatibilityLaunchProfileContractV1.processPolicySchemaVersion,
        validatedRuleID: "renderer-exclusion-gameguard",
        matcher: .gameGuardFamilyASCIIComponentOrFinalStem,
        action: .excludeRendererEnvironmentAndRendererDLLOverrides
    )

    let schemaVersion: Int
    let ruleID: String
    let matcher: CompatibilityAutomaticProcessMatcherV1
    let action: CompatibilityAutomaticProcessPolicyActionV1

    init(
        schemaVersion: Int = SteamCompatibilityLaunchProfileContractV1.processPolicySchemaVersion,
        ruleID: String,
        matcher: CompatibilityAutomaticProcessMatcherV1,
        action: CompatibilityAutomaticProcessPolicyActionV1
    ) throws {
        guard schemaVersion == SteamCompatibilityLaunchProfileContractV1.processPolicySchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "process-policy-schema-version"
            )
        }
        guard SteamLaunchIdentifierValidation.isValid(ruleID, maximumUTF8Bytes: 128) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe("process-policy-rule-id")
        }
        self.init(
            validatedSchemaVersion: schemaVersion,
            validatedRuleID: ruleID,
            matcher: matcher,
            action: action
        )
    }

    private init(
        validatedSchemaVersion: Int,
        validatedRuleID: String,
        matcher: CompatibilityAutomaticProcessMatcherV1,
        action: CompatibilityAutomaticProcessPolicyActionV1
    ) {
        schemaVersion = validatedSchemaVersion
        ruleID = validatedRuleID
        self.matcher = matcher
        self.action = action
    }
}

struct CompatibilitySteamLaunchUserSelectionsV1: Hashable, Sendable {
    var graphicsBackend: SteamGraphicsBackendIdentifier
    var networkPolicy: SteamNetworkPolicyIdentifier
    var audioInputPolicy: SteamAudioInputPolicyIdentifier
    var synchronizationPolicy: SteamSynchronizationPolicyIdentifier
    var videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier
    var gameModeEnabled: Bool
    var heapZeroMemoryEnabled: Bool
    var fpsCursorPolicy: FPSCursorCapturePolicy
    var controllerPolicy: ControllerCompatibilityPolicy
    var keyboardMapping: KeyboardMappingPreference

    func validate() throws {
        _ = try SteamGraphicsBackendIdentifier.validated(graphicsBackend.rawValue)
        _ = try SteamNetworkPolicyIdentifier.validated(networkPolicy.rawValue)
        _ = try SteamAudioInputPolicyIdentifier.validated(audioInputPolicy.rawValue)
        _ = try SteamSynchronizationPolicyIdentifier.validated(synchronizationPolicy.rawValue)
        _ = try SteamVideoMemoryPolicyIdentifier.validated(videoMemoryPolicy.rawValue)
        _ = try KeyboardMappingPreference(
            preset: keyboardMapping.preset,
            customPermutation: keyboardMapping.customPermutation
        )
    }
}

struct CompatibilitySteamLaunchSupportedOptionsV1: Hashable, Sendable {
    let graphicsBackends: [SteamGraphicsBackendIdentifier]
    let networkPolicies: [SteamNetworkPolicyIdentifier]
    let audioInputPolicies: [SteamAudioInputPolicyIdentifier]
    let synchronizationPolicies: [SteamSynchronizationPolicyIdentifier]
    let videoMemoryPolicies: [SteamVideoMemoryPolicyIdentifier]
    let fpsCursorPolicies: [FPSCursorCapturePolicy]
    let controllerPolicies: [ControllerCompatibilityPolicy]
    let keyboardPresets: [KeyboardMappingPreset]
    let supportsCustomKeyboardPermutation: Bool

    func validate() throws {
        try validateUniqueNonempty(graphicsBackends, category: "graphics-backend")
        try validateUniqueNonempty(networkPolicies, category: "network-policy")
        try validateUniqueNonempty(audioInputPolicies, category: "audio-input-policy")
        try validateUniqueNonempty(synchronizationPolicies, category: "synchronization-policy")
        try validateUniqueNonempty(videoMemoryPolicies, category: "video-memory-policy")
        try validateUniqueNonempty(fpsCursorPolicies, category: "fps-cursor-policy")
        try validateUniqueNonempty(controllerPolicies, category: "controller-policy")
        try validateUniqueNonempty(keyboardPresets, category: "keyboard-preset")
        guard keyboardPresets.contains(.custom) == supportsCustomKeyboardPermutation else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "supported-custom-keyboard-permutation"
            )
        }
    }

    private func validateUniqueNonempty<Value: Hashable>(
        _ values: [Value],
        category: String
    ) throws {
        guard !values.isEmpty, Set(values).count == values.count else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "supported-\(category)-set"
            )
        }
    }
}

struct CompatibilitySteamLaunchRecommendationsV1: Hashable, Sendable {
    let selections: CompatibilitySteamLaunchUserSelectionsV1

    var graphicsBackend: SteamGraphicsBackendIdentifier {
        selections.graphicsBackend
    }

    var gameModeEnabled: Bool {
        selections.gameModeEnabled
    }
}

enum CompatibilitySteamLaunchOptionKindV1:
    String, Codable, CaseIterable, Hashable, Sendable
{
    case gameMode
    case heapZeroMemory
    case automaticProcessPolicies
    case graphicsBackend
    case networkPolicy
    case audioInputPolicy
    case synchronizationPolicy
    case videoMemoryPolicy
    case fpsCursorPolicy
    case controllerPolicy
    case keyboardMapping
}

enum CompatibilitySteamLaunchOptionPlacementV1: String, Codable, Hashable, Sendable {
    case primary
    case advanced
    case readOnlySummary
}

struct CompatibilitySteamLaunchOptionDescriptorV1: Codable, Hashable, Sendable {
    let kind: CompatibilitySteamLaunchOptionKindV1
    let placement: CompatibilitySteamLaunchOptionPlacementV1

    var isUserSelectable: Bool {
        kind != .automaticProcessPolicies && placement != .readOnlySummary
    }
}

struct SteamCompatibilityLaunchProfileRecipeV1: Hashable, Sendable {
    let contractVersion: Int
    let schemaVersion: Int
    let identity: SteamCompatibilityProfileIdentity
    let displayName: String
    let initialSelections: CompatibilitySteamLaunchUserSelectionsV1
    let recommendations: CompatibilitySteamLaunchRecommendationsV1
    let supportedOptions: CompatibilitySteamLaunchSupportedOptionsV1
    let orderedOptionDescriptors: [CompatibilitySteamLaunchOptionDescriptorV1]
    let automaticRequiredPolicies: [CompatibilityAutomaticProcessPolicyRuleV1]

    init(
        contractVersion: Int = SteamCompatibilityLaunchProfileContractV1.contractVersion,
        schemaVersion: Int = SteamCompatibilityLaunchProfileContractV1.recipeSchemaVersion,
        identity: SteamCompatibilityProfileIdentity,
        displayName: String,
        initialSelections: CompatibilitySteamLaunchUserSelectionsV1,
        recommendations: CompatibilitySteamLaunchRecommendationsV1,
        supportedOptions: CompatibilitySteamLaunchSupportedOptionsV1,
        orderedOptionDescriptors: [CompatibilitySteamLaunchOptionDescriptorV1],
        automaticRequiredPolicies: [CompatibilityAutomaticProcessPolicyRuleV1]
    ) throws {
        self.init(
            validatedContractVersion: contractVersion,
            validatedSchemaVersion: schemaVersion,
            identity: identity,
            displayName: displayName,
            initialSelections: initialSelections,
            recommendations: recommendations,
            supportedOptions: supportedOptions,
            orderedOptionDescriptors: orderedOptionDescriptors,
            automaticRequiredPolicies: automaticRequiredPolicies
        )
        try validate()
    }

    private init(
        validatedContractVersion: Int,
        validatedSchemaVersion: Int,
        identity: SteamCompatibilityProfileIdentity,
        displayName: String,
        initialSelections: CompatibilitySteamLaunchUserSelectionsV1,
        recommendations: CompatibilitySteamLaunchRecommendationsV1,
        supportedOptions: CompatibilitySteamLaunchSupportedOptionsV1,
        orderedOptionDescriptors: [CompatibilitySteamLaunchOptionDescriptorV1],
        automaticRequiredPolicies: [CompatibilityAutomaticProcessPolicyRuleV1]
    ) {
        contractVersion = validatedContractVersion
        schemaVersion = validatedSchemaVersion
        self.identity = identity
        self.displayName = displayName
        self.initialSelections = initialSelections
        self.recommendations = recommendations
        self.supportedOptions = supportedOptions
        self.orderedOptionDescriptors = orderedOptionDescriptors
        self.automaticRequiredPolicies = automaticRequiredPolicies
    }

    fileprivate static let helldivers2BuiltIn: Self = {
        let initialSelections = CompatibilitySteamLaunchUserSelectionsV1(
            graphicsBackend: .d3dMetal,
            networkPolicy: .standard,
            audioInputPolicy: .disabled,
            synchronizationPolicy: .automatic,
            videoMemoryPolicy: .automatic,
            gameModeEnabled: true,
            heapZeroMemoryEnabled: true,
            fpsCursorPolicy: .off,
            controllerPolicy: .automatic,
            keyboardMapping: .systemDefault
        )
        return Self(
            validatedContractVersion:
                SteamCompatibilityLaunchProfileContractV1.contractVersion,
            validatedSchemaVersion:
                SteamCompatibilityLaunchProfileContractV1.recipeSchemaVersion,
            identity: .helldivers2BuiltIn,
            displayName: "HELLDIVERS 2",
            initialSelections: initialSelections,
            recommendations: CompatibilitySteamLaunchRecommendationsV1(
                selections: initialSelections
            ),
            supportedOptions: CompatibilitySteamLaunchSupportedOptionsV1(
                graphicsBackends: [
                    .d3dMetal,
                    .d3dMetalNVIDIA,
                    .dxmt,
                    .d9vk,
                    .dxvk
                ],
                networkPolicies: [.standard, .wifiIdentity, .ethernetIdentity],
                audioInputPolicies: [.disabled, .enabled],
                synchronizationPolicies: [.automatic],
                videoMemoryPolicies: [.automatic, .gb2, .gb4, .gb8, .gb12, .gb16],
                fpsCursorPolicies: [.off],
                controllerPolicies: [.automatic],
                keyboardPresets: [.systemDefault],
                supportsCustomKeyboardPermutation: false
            ),
            orderedOptionDescriptors: CompatibilitySteamLaunchOptionKindV1.allCases.map {
                CompatibilitySteamLaunchOptionDescriptorV1(
                    kind: $0,
                    placement: helldivers2Placement(for: $0)
                )
            },
            automaticRequiredPolicies: [.rendererExclusionGameGuardBuiltIn]
        )
    }()

    private static func helldivers2Placement(
        for kind: CompatibilitySteamLaunchOptionKindV1
    ) -> CompatibilitySteamLaunchOptionPlacementV1 {
        switch kind {
        case .gameMode, .heapZeroMemory, .automaticProcessPolicies:
            .primary
        case .graphicsBackend,
             .networkPolicy,
             .audioInputPolicy,
             .synchronizationPolicy,
             .videoMemoryPolicy,
             .fpsCursorPolicy,
             .controllerPolicy,
             .keyboardMapping:
            .advanced
        }
    }

    func validate() throws {
        guard contractVersion == SteamCompatibilityLaunchProfileContractV1.contractVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedContractVersion(
                contractVersion
            )
        }
        guard schemaVersion == SteamCompatibilityLaunchProfileContractV1.recipeSchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedRecipeSchemaVersion(
                schemaVersion
            )
        }
        _ = try SteamCompatibilityProfileIdentity(
            steamAppID: identity.steamAppID,
            profileID: identity.profileID,
            recipeRevision: identity.recipeRevision
        )
        guard !displayName.isEmpty, displayName.utf8.count <= 128 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe("display-name")
        }
        try initialSelections.validate()
        try recommendations.selections.validate()
        guard initialSelections == recommendations.selections else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "initial-recommendation-mismatch"
            )
        }
        try supportedOptions.validate()
        try requireSupported(initialSelections.graphicsBackend, in: supportedOptions.graphicsBackends, category: "initial-graphics-backend")
        try requireSupported(initialSelections.networkPolicy, in: supportedOptions.networkPolicies, category: "initial-network-policy")
        try requireSupported(initialSelections.audioInputPolicy, in: supportedOptions.audioInputPolicies, category: "initial-audio-input-policy")
        try requireSupported(initialSelections.synchronizationPolicy, in: supportedOptions.synchronizationPolicies, category: "initial-synchronization-policy")
        try requireSupported(initialSelections.videoMemoryPolicy, in: supportedOptions.videoMemoryPolicies, category: "initial-video-memory-policy")
        try requireSupported(initialSelections.fpsCursorPolicy, in: supportedOptions.fpsCursorPolicies, category: "initial-fps-cursor-policy")
        try requireSupported(initialSelections.controllerPolicy, in: supportedOptions.controllerPolicies, category: "initial-controller-policy")
        try requireSupported(initialSelections.keyboardMapping.preset, in: supportedOptions.keyboardPresets, category: "initial-keyboard-preset")
        if initialSelections.keyboardMapping.customPermutation != nil,
           !supportedOptions.supportsCustomKeyboardPermutation {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "initial-custom-keyboard-permutation"
            )
        }
        try requireSupported(
            recommendations.graphicsBackend,
            in: supportedOptions.graphicsBackends,
            category: "recommended-graphics-backend"
        )
        try requireSupported(recommendations.selections.networkPolicy, in: supportedOptions.networkPolicies, category: "recommended-network-policy")
        try requireSupported(recommendations.selections.audioInputPolicy, in: supportedOptions.audioInputPolicies, category: "recommended-audio-input-policy")
        try requireSupported(recommendations.selections.synchronizationPolicy, in: supportedOptions.synchronizationPolicies, category: "recommended-synchronization-policy")
        try requireSupported(recommendations.selections.videoMemoryPolicy, in: supportedOptions.videoMemoryPolicies, category: "recommended-video-memory-policy")
        try requireSupported(recommendations.selections.fpsCursorPolicy, in: supportedOptions.fpsCursorPolicies, category: "recommended-fps-cursor-policy")
        try requireSupported(recommendations.selections.controllerPolicy, in: supportedOptions.controllerPolicies, category: "recommended-controller-policy")
        try requireSupported(recommendations.selections.keyboardMapping.preset, in: supportedOptions.keyboardPresets, category: "recommended-keyboard-preset")
        guard !orderedOptionDescriptors.isEmpty,
              orderedOptionDescriptors.count == CompatibilitySteamLaunchOptionKindV1.allCases.count,
              Set(orderedOptionDescriptors.map(\.kind)) == Set(CompatibilitySteamLaunchOptionKindV1.allCases),
              orderedOptionDescriptors.first?.kind == .gameMode,
              orderedOptionDescriptors.first(where: { $0.kind == .automaticProcessPolicies })?.isUserSelectable == false else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "ordered-option-descriptors"
            )
        }
        guard automaticRequiredPolicies.count == 1,
              let rule = automaticRequiredPolicies.first,
              rule.matcher == .gameGuardFamilyASCIIComponentOrFinalStem,
              rule.action == .excludeRendererEnvironmentAndRendererDLLOverrides else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "automatic-required-renderer-exclusion"
            )
        }
        guard Set(automaticRequiredPolicies.map(\.ruleID)).count == automaticRequiredPolicies.count else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(
                "duplicate-automatic-policy-rule"
            )
        }
    }

    private func requireSupported<Value: Hashable>(
        _ value: Value,
        in values: [Value],
        category: String
    ) throws {
        guard values.contains(value) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidRecipe(category)
        }
    }
}

enum SteamCompatibilityLaunchProfileCatalogV1 {
    static let helldivers2 = SteamCompatibilityLaunchProfileRecipeV1.helldivers2BuiltIn

    static let recipes = [helldivers2]

    static func recipe(
        matching identity: SteamCompatibilityProfileIdentity
    ) -> SteamCompatibilityLaunchProfileRecipeV1? {
        recipes.first { $0.identity == identity }
    }
}

struct CompatibilitySteamLaunchPreferencePayloadV1: Hashable, Sendable {
    static let canonicalHeader = Data("forgeplay-steam-compatibility-preference-v1\n".utf8)
    private static let canonicalFieldNames = [
        "schemaVersion",
        "steamAppID",
        "profileID",
        "recipeRevision",
        "graphicsBackend",
        "networkPolicy",
        "audioInputPolicy",
        "synchronizationPolicy",
        "videoMemoryPolicy",
        "gameModeEnabled",
        "heapZeroMemoryEnabled",
        "fpsCursorPolicy",
        "controllerPolicy",
        "keyboardPreset",
        "hasCustomPermutation",
        "customCommandRole",
        "customOptionRole",
        "customControlRole"
    ]

    let schemaVersion: Int
    let identity: SteamCompatibilityProfileIdentity
    let selections: CompatibilitySteamLaunchUserSelectionsV1

    init(
        schemaVersion: Int = SteamCompatibilityLaunchProfileContractV1.preferenceSchemaVersion,
        identity: SteamCompatibilityProfileIdentity,
        selections: CompatibilitySteamLaunchUserSelectionsV1
    ) throws {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.selections = selections
        try validate()
    }

    func validate() throws {
        guard schemaVersion == SteamCompatibilityLaunchProfileContractV1.preferenceSchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference("schema-version")
        }
        _ = try SteamCompatibilityProfileIdentity(
            steamAppID: identity.steamAppID,
            profileID: identity.profileID,
            recipeRevision: identity.recipeRevision
        )
        try selections.validate()
    }

    func canonicalPayload() throws -> Data {
        try validate()
        let custom = selections.keyboardMapping.customPermutation
        let values = [
            String(schemaVersion),
            identity.steamAppID,
            identity.profileID,
            identity.recipeRevision,
            selections.graphicsBackend.rawValue,
            selections.networkPolicy.rawValue,
            selections.audioInputPolicy.rawValue,
            selections.synchronizationPolicy.rawValue,
            selections.videoMemoryPolicy.rawValue,
            selections.gameModeEnabled ? "1" : "0",
            selections.heapZeroMemoryEnabled ? "1" : "0",
            selections.fpsCursorPolicy.rawValue,
            selections.controllerPolicy.rawValue,
            selections.keyboardMapping.preset.rawValue,
            custom == nil ? "0" : "1",
            custom?.command.rawValue ?? "-",
            custom?.option.rawValue ?? "-",
            custom?.control.rawValue ?? "-"
        ]
        var encoder = SteamCompatibilityCanonicalEncoderV1(header: Self.canonicalHeader)
        for (name, value) in zip(Self.canonicalFieldNames, values) {
            encoder.append(name: name, value: value)
        }
        return encoder.data
    }

    var canonicalDigest: String {
        get throws {
            SteamLaunchIdentifierValidation.lowercaseSHA256(try canonicalPayload())
        }
    }

    init(canonicalPayload data: Data) throws {
        var parser = SteamCompatibilityCanonicalParserV1(data: data)
        try parser.consume(Self.canonicalHeader, reason: "header")
        var values: [String] = []
        values.reserveCapacity(Self.canonicalFieldNames.count)
        for name in Self.canonicalFieldNames {
            values.append(try parser.readField(named: name))
        }
        try parser.requireEnd()

        guard values[0] == String(SteamCompatibilityLaunchProfileContractV1.preferenceSchemaVersion) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "schema-version"
            )
        }
        let identity = try SteamCompatibilityProfileIdentity(
            steamAppID: values[1],
            profileID: values[2],
            recipeRevision: values[3]
        )
        let gameModeEnabled = try Self.decodeBoolean(values[9], field: "game-mode-enabled")
        let heapZeroMemoryEnabled = try Self.decodeBoolean(
            values[10],
            field: "heap-zero-memory-enabled"
        )
        guard let fpsCursorPolicy = FPSCursorCapturePolicy(rawValue: values[11]) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "fps-cursor-policy"
            )
        }
        guard let controllerPolicy = ControllerCompatibilityPolicy(rawValue: values[12]) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "controller-policy"
            )
        }
        guard let keyboardPreset = KeyboardMappingPreset(rawValue: values[13]) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "keyboard-preset"
            )
        }
        let customPermutation: ModifierKeyPermutation?
        switch values[14] {
        case "0":
            guard values[15] == "-", values[16] == "-", values[17] == "-" else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                    "unexpected-custom-permutation"
                )
            }
            customPermutation = nil
        case "1":
            guard let command = WindowsModifierRole(rawValue: values[15]),
                  let option = WindowsModifierRole(rawValue: values[16]),
                  let control = WindowsModifierRole(rawValue: values[17]) else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                    "custom-permutation-role"
                )
            }
            customPermutation = try ModifierKeyPermutation(
                command: command,
                option: option,
                control: control
            )
        default:
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "custom-permutation-presence"
            )
        }

        try self.init(
            identity: identity,
            selections: CompatibilitySteamLaunchUserSelectionsV1(
                graphicsBackend: SteamGraphicsBackendIdentifier.validated(values[4]),
                networkPolicy: SteamNetworkPolicyIdentifier.validated(values[5]),
                audioInputPolicy: SteamAudioInputPolicyIdentifier.validated(values[6]),
                synchronizationPolicy: SteamSynchronizationPolicyIdentifier.validated(values[7]),
                videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier.validated(values[8]),
                gameModeEnabled: gameModeEnabled,
                heapZeroMemoryEnabled: heapZeroMemoryEnabled,
                fpsCursorPolicy: fpsCursorPolicy,
                controllerPolicy: controllerPolicy,
                keyboardMapping: KeyboardMappingPreference(
                    preset: keyboardPreset,
                    customPermutation: customPermutation
                )
            )
        )
        guard try canonicalPayload() == data else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "noncanonical-reencoding"
            )
        }
    }

    private static func decodeBoolean(_ value: String, field: String) throws -> Bool {
        switch value {
        case "1": true
        case "0": false
        default:
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(field)
        }
    }
}

struct CompatibilitySteamLaunchPreferenceEnvelopeV1: Hashable, Sendable {
    let payload: CompatibilitySteamLaunchPreferencePayloadV1
    let payloadDigest: String
    let generation: Int64
    let persistenceRevision: UUID
    let createdAt: Date
    let updatedAt: Date

    init(
        payload: CompatibilitySteamLaunchPreferencePayloadV1,
        payloadDigest: String,
        generation: Int64,
        persistenceRevision: UUID,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        self.payload = payload
        self.payloadDigest = payloadDigest
        self.generation = generation
        self.persistenceRevision = persistenceRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    func validate() throws {
        try payload.validate()
        guard payloadDigest == (try payload.canonicalDigest) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference("digest-mismatch")
        }
        guard generation >= 1 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference("generation")
        }
        guard persistenceRevision.uuidString.lowercased() !=
                "00000000-0000-0000-0000-000000000000" else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "persistence-revision"
            )
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference("timestamps")
        }
    }

    var sourceVersion: CompatibilitySteamLaunchPreferenceSourceVersionV1 {
        CompatibilitySteamLaunchPreferenceSourceVersionV1(
            validatedPayloadDigest: payloadDigest,
            generation: generation,
            persistenceRevision: persistenceRevision
        )
    }
}

struct CompatibilitySteamLaunchPreferenceSourceVersionV1: Hashable, Sendable {
    let payloadDigest: String
    let generation: Int64
    let persistenceRevision: UUID

    init(
        payloadDigest: String,
        generation: Int64,
        persistenceRevision: UUID
    ) throws {
        guard SteamLaunchIdentifierValidation.isValidLowercaseSHA256(payloadDigest) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "source-version-digest"
            )
        }
        guard generation >= 1 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "source-version-generation"
            )
        }
        guard persistenceRevision.uuidString.lowercased() !=
                "00000000-0000-0000-0000-000000000000" else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "source-version-revision"
            )
        }
        self.payloadDigest = payloadDigest
        self.generation = generation
        self.persistenceRevision = persistenceRevision
    }

    fileprivate init(
        validatedPayloadDigest: String,
        generation: Int64,
        persistenceRevision: UUID
    ) {
        precondition(SteamLaunchIdentifierValidation.isValidLowercaseSHA256(validatedPayloadDigest))
        precondition(generation >= 1)
        precondition(
            persistenceRevision.uuidString.lowercased() !=
                "00000000-0000-0000-0000-000000000000"
        )
        payloadDigest = validatedPayloadDigest
        self.generation = generation
        self.persistenceRevision = persistenceRevision
    }
}

enum SteamCompatibilitySnapshotV1MigrationAdapter {
    static func preference(
        from snapshot: SteamLaunchConfigurationSnapshot,
        recipe: SteamCompatibilityLaunchProfileRecipeV1
    ) throws -> CompatibilitySteamLaunchPreferencePayloadV1 {
        try snapshot.validate()
        try recipe.validate()
        guard case .compatibility(let snapshotIdentity) = snapshot.identity else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "standard-source"
            )
        }
        guard snapshotIdentity == recipe.identity else {
            throw SteamCompatibilityLaunchProfileErrorV1.identityMismatch(
                expected: recipe.identity.deterministicRecordID,
                actual: snapshotIdentity.deterministicRecordID
            )
        }
        return try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: snapshotIdentity,
            selections: CompatibilitySteamLaunchUserSelectionsV1(
                graphicsBackend: snapshot.graphicsBackend,
                networkPolicy: snapshot.networkPolicy,
                audioInputPolicy: snapshot.audioInputPolicy,
                synchronizationPolicy: snapshot.synchronizationPolicy,
                videoMemoryPolicy: snapshot.videoMemoryPolicy,
                gameModeEnabled: snapshot.gameModeEnabled,
                heapZeroMemoryEnabled: recipe.initialSelections.heapZeroMemoryEnabled,
                fpsCursorPolicy: snapshot.fpsCursorPolicy,
                controllerPolicy: snapshot.controllerPolicy,
                keyboardMapping: snapshot.keyboardMapping
            )
        )
    }
}

struct SteamCompatibilityCanonicalEncoderV1 {
    private(set) var data: Data

    init(header: Data) {
        data = header
    }

    mutating func append(name: String, value: String) {
        data.append(contentsOf: "\(name)=\(value.utf8.count):".utf8)
        data.append(contentsOf: value.utf8)
        data.append(10)
    }
}

private struct SteamCompatibilityCanonicalParserV1 {
    let data: Data
    var offset = 0

    mutating func consume(_ expected: Data, reason: String) throws {
        guard offset <= data.count,
              expected.count <= data.count - offset,
              data[offset ..< offset + expected.count].elementsEqual(expected) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(reason)
        }
        offset += expected.count
    }

    mutating func readField(named name: String) throws -> String {
        try consume(Data("\(name)=".utf8), reason: "field-\(name)")
        let lengthStart = offset
        while offset < data.count, data[offset] >= 48, data[offset] <= 57 {
            offset += 1
        }
        guard offset > lengthStart, offset < data.count, data[offset] == 58 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "length-\(name)"
            )
        }
        let lengthBytes = data[lengthStart ..< offset]
        guard lengthBytes.count == 1 || lengthBytes.first != 48,
              let lengthText = String(data: lengthBytes, encoding: .utf8),
              let length = Int(lengthText) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "nonminimal-length-\(name)"
            )
        }
        offset += 1
        guard length >= 0, length <= data.count - offset else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "out-of-bounds-\(name)"
            )
        }
        let valueBytes = data[offset ..< offset + length]
        guard let value = String(data: valueBytes, encoding: .utf8) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "utf8-\(name)"
            )
        }
        offset += length
        guard offset < data.count, data[offset] == 10 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "newline-\(name)"
            )
        }
        offset += 1
        return value
    }

    func requireEnd() throws {
        guard offset == data.count else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload(
                "trailing-bytes"
            )
        }
    }
}
