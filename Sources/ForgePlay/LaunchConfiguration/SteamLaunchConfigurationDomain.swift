import CryptoKit
import Foundation

enum SteamLaunchConfigurationError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidIdentity(String)
    case invalidOptionIdentifier(category: String, value: String)
    case invalidKeyboardMapping(String)
    case invalidCanonicalPayload(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "지원하지 않는 Steam 실행 구성 버전입니다: \(version)"
        case .invalidIdentity(let reason):
            "Steam 실행 구성 식별자가 올바르지 않습니다: \(reason)"
        case .invalidOptionIdentifier(let category, let value):
            "Steam 실행 옵션 식별자가 올바르지 않습니다: \(category)=\(value)"
        case .invalidKeyboardMapping(let reason):
            "키보드 매핑 구성이 올바르지 않습니다: \(reason)"
        case .invalidCanonicalPayload(let reason):
            "저장된 Steam 실행 구성을 읽지 못했습니다: \(reason)"
        }
    }
}

enum SteamLaunchMode: String, Codable, CaseIterable, Hashable, Sendable {
    case standard
    case compatibility
}

enum SteamLaunchIdentifierValidation {
    static func isValid(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumUTF8Bytes else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }

    static func isValidSteamAppID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 20).contains(bytes.count),
              let first = bytes.first,
              first >= 49,
              first <= 57 else {
            return false
        }
        return bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    static func lowercaseSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidLowercaseSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

struct SteamCompatibilityProfileIdentity: Codable, Hashable, Sendable {
    static let helldivers2BuiltIn = Self(
        validatedSteamAppID: "553850",
        validatedProfileID: "forgeplay.helldivers2.compatibility",
        validatedRecipeRevision: "v1"
    )

    let steamAppID: String
    let profileID: String
    let recipeRevision: String

    init(steamAppID: String, profileID: String, recipeRevision: String) throws {
        guard SteamLaunchIdentifierValidation.isValidSteamAppID(steamAppID) else {
            throw SteamLaunchConfigurationError.invalidIdentity("steam-app-id")
        }
        guard SteamLaunchIdentifierValidation.isValid(profileID, maximumUTF8Bytes: 128) else {
            throw SteamLaunchConfigurationError.invalidIdentity("profile-id")
        }
        guard SteamLaunchIdentifierValidation.isValid(recipeRevision, maximumUTF8Bytes: 128) else {
            throw SteamLaunchConfigurationError.invalidIdentity("recipe-revision")
        }
        self.init(
            validatedSteamAppID: steamAppID,
            validatedProfileID: profileID,
            validatedRecipeRevision: recipeRevision
        )
    }

    private init(
        validatedSteamAppID: String,
        validatedProfileID: String,
        validatedRecipeRevision: String
    ) {
        steamAppID = validatedSteamAppID
        profileID = validatedProfileID
        recipeRevision = validatedRecipeRevision
    }

    var deterministicRecordID: String {
        var projection = Data(profileID.utf8)
        projection.append(0)
        projection.append(contentsOf: recipeRevision.utf8)
        return "compatibility-\(steamAppID)-\(SteamLaunchIdentifierValidation.lowercaseSHA256(projection))"
    }

    private enum CodingKeys: String, CodingKey {
        case steamAppID
        case profileID
        case recipeRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            steamAppID: container.decode(String.self, forKey: .steamAppID),
            profileID: container.decode(String.self, forKey: .profileID),
            recipeRevision: container.decode(String.self, forKey: .recipeRevision)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steamAppID, forKey: .steamAppID)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(recipeRevision, forKey: .recipeRevision)
    }
}

enum SteamLaunchConfigurationIdentity: Codable, Hashable, Sendable {
    case standard
    case compatibility(SteamCompatibilityProfileIdentity)

    private enum CodingKeys: String, CodingKey {
        case mode
        case steamAppID
        case profileID
        case recipeRevision
    }

    var mode: SteamLaunchMode {
        switch self {
        case .standard: .standard
        case .compatibility: .compatibility
        }
    }

    var configurationIdentity: String {
        switch self {
        case .standard:
            "standard-default"
        case .compatibility(let profile):
            profile.deterministicRecordID
        }
    }

    var compatibilityProfile: SteamCompatibilityProfileIdentity? {
        guard case .compatibility(let profile) = self else { return nil }
        return profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(SteamLaunchMode.self, forKey: .mode)
        switch mode {
        case .standard:
            guard !container.contains(.steamAppID),
                  !container.contains(.profileID),
                  !container.contains(.recipeRevision) else {
                throw SteamLaunchConfigurationError.invalidIdentity("standard-has-profile")
            }
            self = .standard
        case .compatibility:
            self = try .compatibility(
                SteamCompatibilityProfileIdentity(
                    steamAppID: container.decode(String.self, forKey: .steamAppID),
                    profileID: container.decode(String.self, forKey: .profileID),
                    recipeRevision: container.decode(String.self, forKey: .recipeRevision)
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        if case .compatibility(let profile) = self {
            try container.encode(profile.steamAppID, forKey: .steamAppID)
            try container.encode(profile.profileID, forKey: .profileID)
            try container.encode(profile.recipeRevision, forKey: .recipeRevision)
        }
    }
}

protocol SteamLaunchOptionIdentifierProtocol:
    RawRepresentable, Codable, Hashable, Sendable where RawValue == String
{
    static var categoryName: String { get }
    init?(rawValue: String)
}

extension SteamLaunchOptionIdentifierProtocol {
    static func validated(_ value: String) throws -> Self {
        guard let identifier = Self(rawValue: value) else {
            throw SteamLaunchConfigurationError.invalidOptionIdentifier(
                category: categoryName,
                value: value
            )
        }
        return identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try Self.validated(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SteamGraphicsBackendIdentifier: SteamLaunchOptionIdentifierProtocol {
    static let categoryName = "graphics-backend"
    static let d3dMetal = Self(validatedRawValue: "d3dMetal")
    static let d3dMetalNVIDIA = Self(validatedRawValue: "d3dMetalNVIDIA")
    static let dxmt = Self(validatedRawValue: "dxmt")
    static let d9vk = Self(validatedRawValue: "d9vk")
    static let dxvk = Self(validatedRawValue: "dxvk")

    let rawValue: String

    init?(rawValue: String) {
        guard SteamLaunchIdentifierValidation.isValid(rawValue, maximumUTF8Bytes: 64) else {
            return nil
        }
        self.init(validatedRawValue: rawValue)
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }
}

struct SteamNetworkPolicyIdentifier: SteamLaunchOptionIdentifierProtocol {
    static let categoryName = "network-policy"
    static let standard = Self(validatedRawValue: "standard")
    static let wifiIdentity = Self(validatedRawValue: "wifi-identity")
    static let ethernetIdentity = Self(validatedRawValue: "ethernet-identity")

    let rawValue: String

    init?(rawValue: String) {
        guard SteamLaunchIdentifierValidation.isValid(rawValue, maximumUTF8Bytes: 64) else {
            return nil
        }
        self.init(validatedRawValue: rawValue)
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }
}

struct SteamAudioInputPolicyIdentifier: SteamLaunchOptionIdentifierProtocol {
    static let categoryName = "audio-input-policy"
    static let disabled = Self(validatedRawValue: "disabled")
    static let enabled = Self(validatedRawValue: "enabled")

    let rawValue: String

    init?(rawValue: String) {
        guard SteamLaunchIdentifierValidation.isValid(rawValue, maximumUTF8Bytes: 64) else {
            return nil
        }
        self.init(validatedRawValue: rawValue)
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }
}

struct SteamSynchronizationPolicyIdentifier: SteamLaunchOptionIdentifierProtocol {
    static let categoryName = "synchronization-policy"
    static let automatic = Self(validatedRawValue: "automatic")

    let rawValue: String

    init?(rawValue: String) {
        guard SteamLaunchIdentifierValidation.isValid(rawValue, maximumUTF8Bytes: 64) else {
            return nil
        }
        self.init(validatedRawValue: rawValue)
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }
}

struct SteamVideoMemoryPolicyIdentifier: SteamLaunchOptionIdentifierProtocol {
    static let categoryName = "video-memory-policy"
    static let automatic = Self(validatedRawValue: "automatic")
    static let gb2 = Self(validatedRawValue: "gb2")
    static let gb4 = Self(validatedRawValue: "gb4")
    static let gb8 = Self(validatedRawValue: "gb8")
    static let gb12 = Self(validatedRawValue: "gb12")
    static let gb16 = Self(validatedRawValue: "gb16")

    let rawValue: String

    init?(rawValue: String) {
        guard SteamLaunchIdentifierValidation.isValid(rawValue, maximumUTF8Bytes: 64) else {
            return nil
        }
        self.init(validatedRawValue: rawValue)
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }
}

enum FPSCursorCapturePolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case fpsRelativeCaptureBeta
}

enum ControllerCompatibilityPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case macOSSyntheticHID
    case forgePlayCompatibilityBridgeBeta
}

enum HostModifierKey: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case control
}

enum WindowsModifierRole: String, Codable, CaseIterable, Hashable, Sendable {
    case control
    case alt
    case windows
}

struct ModifierKeyPermutation: Codable, Hashable, Sendable {
    let command: WindowsModifierRole
    let option: WindowsModifierRole
    let control: WindowsModifierRole

    init(
        command: WindowsModifierRole,
        option: WindowsModifierRole,
        control: WindowsModifierRole
    ) throws {
        guard Set([command, option, control]).count == WindowsModifierRole.allCases.count else {
            throw SteamLaunchConfigurationError.invalidKeyboardMapping("modifier-role-not-bijective")
        }
        self.command = command
        self.option = option
        self.control = control
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case option
        case control
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            command: container.decode(WindowsModifierRole.self, forKey: .command),
            option: container.decode(WindowsModifierRole.self, forKey: .option),
            control: container.decode(WindowsModifierRole.self, forKey: .control)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(option, forKey: .option)
        try container.encode(control, forKey: .control)
    }
}

enum KeyboardMappingPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case systemDefault
    case windowsFriendly
    case macOSFriendly
    case custom
}

struct KeyboardMappingPreference: Codable, Hashable, Sendable {
    let preset: KeyboardMappingPreset
    let customPermutation: ModifierKeyPermutation?

    init(
        preset: KeyboardMappingPreset,
        customPermutation: ModifierKeyPermutation? = nil
    ) throws {
        switch (preset, customPermutation) {
        case (.custom, .some),
             (.systemDefault, .none),
             (.windowsFriendly, .none),
             (.macOSFriendly, .none):
            break
        case (.custom, .none):
            throw SteamLaunchConfigurationError.invalidKeyboardMapping("custom-permutation-missing")
        case (_, .some):
            throw SteamLaunchConfigurationError.invalidKeyboardMapping("unexpected-custom-permutation")
        }
        self.init(
            validatedPreset: preset,
            validatedCustomPermutation: customPermutation
        )
    }

    private init(
        validatedPreset: KeyboardMappingPreset,
        validatedCustomPermutation: ModifierKeyPermutation?
    ) {
        preset = validatedPreset
        customPermutation = validatedCustomPermutation
    }

    static let windowsFriendly = Self(
        validatedPreset: .windowsFriendly,
        validatedCustomPermutation: nil
    )

    static let systemDefault = Self(
        validatedPreset: .systemDefault,
        validatedCustomPermutation: nil
    )

    private enum CodingKeys: String, CodingKey {
        case preset
        case customPermutation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            preset: container.decode(KeyboardMappingPreset.self, forKey: .preset),
            customPermutation: container.decodeIfPresent(
                ModifierKeyPermutation.self,
                forKey: .customPermutation
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encodeIfPresent(customPermutation, forKey: .customPermutation)
    }
}

struct SteamLaunchConfigurationSnapshot: Hashable, Sendable {
    static let currentSchemaVersion = 1
    private static let canonicalHeader = Data("forgeplay-steam-launch-configuration-v1\n".utf8)
    private static let canonicalFieldNames = [
        "schemaVersion",
        "mode",
        "configurationIdentity",
        "steamAppID",
        "profileID",
        "recipeRevision",
        "graphicsBackend",
        "networkPolicy",
        "audioInputPolicy",
        "synchronizationPolicy",
        "videoMemoryPolicy",
        "gameModeEnabled",
        "fpsCursorPolicy",
        "controllerPolicy",
        "keyboardPreset",
        "hasCustomPermutation",
        "customCommandRole",
        "customOptionRole",
        "customControlRole"
    ]

    let schemaVersion: Int
    let identity: SteamLaunchConfigurationIdentity
    let graphicsBackend: SteamGraphicsBackendIdentifier
    let networkPolicy: SteamNetworkPolicyIdentifier
    let audioInputPolicy: SteamAudioInputPolicyIdentifier
    let synchronizationPolicy: SteamSynchronizationPolicyIdentifier
    let videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier
    let gameModeEnabled: Bool
    let fpsCursorPolicy: FPSCursorCapturePolicy
    let controllerPolicy: ControllerCompatibilityPolicy
    let keyboardMapping: KeyboardMappingPreference

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        identity: SteamLaunchConfigurationIdentity,
        graphicsBackend: SteamGraphicsBackendIdentifier = .d3dMetal,
        networkPolicy: SteamNetworkPolicyIdentifier = .standard,
        audioInputPolicy: SteamAudioInputPolicyIdentifier = .disabled,
        synchronizationPolicy: SteamSynchronizationPolicyIdentifier = .automatic,
        videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier = .automatic,
        gameModeEnabled: Bool = true,
        fpsCursorPolicy: FPSCursorCapturePolicy = .off,
        controllerPolicy: ControllerCompatibilityPolicy = .automatic,
        keyboardMapping: KeyboardMappingPreference = .systemDefault
    ) throws {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.graphicsBackend = graphicsBackend
        self.networkPolicy = networkPolicy
        self.audioInputPolicy = audioInputPolicy
        self.synchronizationPolicy = synchronizationPolicy
        self.videoMemoryPolicy = videoMemoryPolicy
        self.gameModeEnabled = gameModeEnabled
        self.fpsCursorPolicy = fpsCursorPolicy
        self.controllerPolicy = controllerPolicy
        self.keyboardMapping = keyboardMapping
        try validate()
    }

    static let standardDefault = Self(standardDefaults: ())

    private init(standardDefaults: Void) {
        schemaVersion = Self.currentSchemaVersion
        identity = .standard
        graphicsBackend = .d3dMetal
        networkPolicy = .standard
        audioInputPolicy = .disabled
        synchronizationPolicy = .automatic
        videoMemoryPolicy = .automatic
        gameModeEnabled = true
        fpsCursorPolicy = .off
        controllerPolicy = .automatic
        keyboardMapping = .systemDefault
    }

    static func compatibilityDefault(
        steamAppID: String,
        profileID: String,
        recipeRevision: String
    ) throws -> Self {
        try Self(
            identity: .compatibility(
                SteamCompatibilityProfileIdentity(
                    steamAppID: steamAppID,
                    profileID: profileID,
                    recipeRevision: recipeRevision
                )
            )
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SteamLaunchConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        _ = try SteamGraphicsBackendIdentifier.validated(graphicsBackend.rawValue)
        _ = try SteamNetworkPolicyIdentifier.validated(networkPolicy.rawValue)
        _ = try SteamAudioInputPolicyIdentifier.validated(audioInputPolicy.rawValue)
        _ = try SteamSynchronizationPolicyIdentifier.validated(synchronizationPolicy.rawValue)
        _ = try SteamVideoMemoryPolicyIdentifier.validated(videoMemoryPolicy.rawValue)
        _ = try KeyboardMappingPreference(
            preset: keyboardMapping.preset,
            customPermutation: keyboardMapping.customPermutation
        )
        switch identity {
        case .standard:
            break
        case .compatibility(let profile):
            _ = try SteamCompatibilityProfileIdentity(
                steamAppID: profile.steamAppID,
                profileID: profile.profileID,
                recipeRevision: profile.recipeRevision
            )
        }
    }

    func canonicalPayload() throws -> Data {
        try validate()
        let profile = identity.compatibilityProfile
        let custom = keyboardMapping.customPermutation
        let values = [
            String(schemaVersion),
            identity.mode.rawValue,
            identity.configurationIdentity,
            profile?.steamAppID ?? "",
            profile?.profileID ?? "",
            profile?.recipeRevision ?? "",
            graphicsBackend.rawValue,
            networkPolicy.rawValue,
            audioInputPolicy.rawValue,
            synchronizationPolicy.rawValue,
            videoMemoryPolicy.rawValue,
            gameModeEnabled ? "1" : "0",
            fpsCursorPolicy.rawValue,
            controllerPolicy.rawValue,
            keyboardMapping.preset.rawValue,
            custom == nil ? "0" : "1",
            custom?.command.rawValue ?? "-",
            custom?.option.rawValue ?? "-",
            custom?.control.rawValue ?? "-"
        ]
        var payload = Self.canonicalHeader
        for (name, value) in zip(Self.canonicalFieldNames, values) {
            payload.append(contentsOf: "\(name)=\(value.utf8.count):".utf8)
            payload.append(contentsOf: value.utf8)
            payload.append(10)
        }
        return payload
    }

    var canonicalDigest: String {
        get throws {
            SteamLaunchIdentifierValidation.lowercaseSHA256(try canonicalPayload())
        }
    }

    init(canonicalPayload data: Data) throws {
        var parser = SteamLaunchCanonicalPayloadParser(data: data)
        try parser.consume(Self.canonicalHeader, reason: "header")
        var values: [String] = []
        values.reserveCapacity(Self.canonicalFieldNames.count)
        for fieldName in Self.canonicalFieldNames {
            values.append(try parser.readField(named: fieldName))
        }
        try parser.requireEnd()

        guard values[0] == String(Self.currentSchemaVersion) else {
            if let version = Int(values[0]) {
                throw SteamLaunchConfigurationError.unsupportedSchemaVersion(version)
            }
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("schema-version")
        }
        guard let mode = SteamLaunchMode(rawValue: values[1]) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("mode")
        }
        let identity: SteamLaunchConfigurationIdentity
        switch mode {
        case .standard:
            guard values[3].isEmpty, values[4].isEmpty, values[5].isEmpty else {
                throw SteamLaunchConfigurationError.invalidIdentity("standard-has-profile")
            }
            identity = .standard
        case .compatibility:
            identity = try .compatibility(
                SteamCompatibilityProfileIdentity(
                    steamAppID: values[3],
                    profileID: values[4],
                    recipeRevision: values[5]
                )
            )
        }
        guard values[2] == identity.configurationIdentity else {
            throw SteamLaunchConfigurationError.invalidIdentity("configuration-identity-mismatch")
        }
        guard let fpsCursorPolicy = FPSCursorCapturePolicy(rawValue: values[12]) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("fps-cursor-policy")
        }
        guard let controllerPolicy = ControllerCompatibilityPolicy(rawValue: values[13]) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("controller-policy")
        }
        guard let keyboardPreset = KeyboardMappingPreset(rawValue: values[14]) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("keyboard-preset")
        }
        let customPermutation: ModifierKeyPermutation?
        switch values[15] {
        case "0":
            guard values[16] == "-", values[17] == "-", values[18] == "-" else {
                throw SteamLaunchConfigurationError.invalidCanonicalPayload("unexpected-custom-mapping")
            }
            customPermutation = nil
        case "1":
            guard let command = WindowsModifierRole(rawValue: values[16]),
                  let option = WindowsModifierRole(rawValue: values[17]),
                  let control = WindowsModifierRole(rawValue: values[18]) else {
                throw SteamLaunchConfigurationError.invalidCanonicalPayload("custom-mapping-role")
            }
            customPermutation = try ModifierKeyPermutation(
                command: command,
                option: option,
                control: control
            )
        default:
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("custom-mapping-presence")
        }
        let gameModeEnabled: Bool
        switch values[11] {
        case "1": gameModeEnabled = true
        case "0": gameModeEnabled = false
        default:
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("game-mode-enabled")
        }

        try self.init(
            identity: identity,
            graphicsBackend: SteamGraphicsBackendIdentifier.validated(values[6]),
            networkPolicy: SteamNetworkPolicyIdentifier.validated(values[7]),
            audioInputPolicy: SteamAudioInputPolicyIdentifier.validated(values[8]),
            synchronizationPolicy: SteamSynchronizationPolicyIdentifier.validated(values[9]),
            videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier.validated(values[10]),
            gameModeEnabled: gameModeEnabled,
            fpsCursorPolicy: fpsCursorPolicy,
            controllerPolicy: controllerPolicy,
            keyboardMapping: KeyboardMappingPreference(
                preset: keyboardPreset,
                customPermutation: customPermutation
            )
        )
        guard try canonicalPayload() == data else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("noncanonical-reencoding")
        }
    }
}

private struct SteamLaunchCanonicalPayloadParser {
    let data: Data
    var offset = 0

    mutating func consume(_ expected: Data, reason: String) throws {
        guard offset <= data.count,
              expected.count <= data.count - offset,
              data[offset ..< offset + expected.count].elementsEqual(expected) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload(reason)
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
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("length-\(name)")
        }
        let lengthBytes = data[lengthStart ..< offset]
        guard lengthBytes.count == 1 || lengthBytes.first != 48,
              let lengthText = String(data: lengthBytes, encoding: .utf8),
              let length = Int(lengthText) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("nonminimal-length-\(name)")
        }
        offset += 1
        guard length >= 0, length <= data.count - offset else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("out-of-bounds-\(name)")
        }
        let valueBytes = data[offset ..< offset + length]
        guard let value = String(data: valueBytes, encoding: .utf8) else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("utf8-\(name)")
        }
        offset += length
        guard offset < data.count, data[offset] == 10 else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("newline-\(name)")
        }
        offset += 1
        return value
    }

    func requireEnd() throws {
        guard offset == data.count else {
            throw SteamLaunchConfigurationError.invalidCanonicalPayload("trailing-bytes")
        }
    }
}
