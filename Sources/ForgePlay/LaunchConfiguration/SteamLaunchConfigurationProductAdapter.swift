import Foundation

struct SteamLaunchConfigurationProductSelection: Hashable, Sendable {
    let rendererPolicySelection: SteamRendererPolicySelection
    let networkSelection: SteamNetworkCompatibilitySelection
    let audioInputSelection: SteamAudioInputSelection
    let synchronizationSelection: WineSynchronizationSelection
    let videoMemorySelection: SteamVideoMemorySelection
    let gameModePolicy: SteamGameModeLaunchPolicy
    let fpsCursorPolicy: FPSCursorCapturePolicy
    let controllerPolicy: ControllerCompatibilityPolicy
    let keyboardMapping: KeyboardMappingPreference
}

enum SteamLaunchConfigurationProductAdapterError: LocalizedError, Equatable {
    case unsupportedMode(SteamLaunchMode)
    case unsupportedOption(category: String, value: String)
    case standardIdentityMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMode(let mode):
            "이 Steam 실행 구성 모드는 표준 Steam 실행에서 지원되지 않습니다: \(mode.rawValue)"
        case .unsupportedOption(let category, let value):
            "이 Steam 실행 구성 옵션은 현재 지원되지 않습니다: \(category)=\(value)"
        case .standardIdentityMismatch(let identity):
            "표준 Steam 실행 구성 식별자가 일치하지 않습니다: \(identity)"
        }
    }
}

enum SteamLaunchConfigurationProductAdapter {
    static func standardSnapshot(
        selection: SteamLaunchConfigurationProductSelection,
        preserving base: SteamLaunchConfigurationSnapshot? = nil
    ) throws -> SteamLaunchConfigurationSnapshot {
        if let base {
            try validateStandardIdentity(of: base)
        }

        return try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: try graphicsBackend(for: selection.rendererPolicySelection),
            networkPolicy: try networkPolicy(for: selection.networkSelection),
            audioInputPolicy: audioInputPolicy(for: selection.audioInputSelection),
            synchronizationPolicy: synchronizationPolicy(
                for: selection.synchronizationSelection
            ),
            videoMemoryPolicy: try videoMemoryPolicy(for: selection.videoMemorySelection),
            gameModeEnabled: gameModeEnabled(for: selection.gameModePolicy),
            fpsCursorPolicy: selection.fpsCursorPolicy,
            controllerPolicy: selection.controllerPolicy,
            keyboardMapping: selection.keyboardMapping
        )
    }

    static func productSelection(
        from snapshot: SteamLaunchConfigurationSnapshot
    ) throws -> SteamLaunchConfigurationProductSelection {
        try snapshot.validate()
        try validateStandardIdentity(of: snapshot)

        return SteamLaunchConfigurationProductSelection(
            rendererPolicySelection: try rendererSelection(
                for: snapshot.graphicsBackend
            ),
            networkSelection: try networkSelection(for: snapshot.networkPolicy),
            audioInputSelection: try audioInputSelection(for: snapshot.audioInputPolicy),
            synchronizationSelection: try synchronizationSelection(
                for: snapshot.synchronizationPolicy
            ),
            videoMemorySelection: try videoMemorySelection(for: snapshot.videoMemoryPolicy),
            gameModePolicy: gameModePolicy(for: snapshot.gameModeEnabled),
            fpsCursorPolicy: snapshot.fpsCursorPolicy,
            controllerPolicy: snapshot.controllerPolicy,
            keyboardMapping: snapshot.keyboardMapping
        )
    }

    static func resolvedJournal(
        for snapshot: SteamLaunchConfigurationSnapshot,
        transactionID: UUID
    ) throws -> SteamLaunchConfigurationTransactionJournal {
        _ = try productSelection(from: snapshot)
        let digest = try snapshot.canonicalDigest
        var journal = try SteamLaunchConfigurationTransactionJournal(
            transactionID: transactionID,
            requestedDigest: digest
        )
        try journal.resolve(resolvedDigest: digest)
        return journal
    }

    private static func validateStandardIdentity(
        of snapshot: SteamLaunchConfigurationSnapshot
    ) throws {
        guard snapshot.identity.mode == .standard else {
            throw SteamLaunchConfigurationProductAdapterError.unsupportedMode(
                snapshot.identity.mode
            )
        }
        let expectedIdentity = SteamLaunchConfigurationIdentity.standard.configurationIdentity
        guard snapshot.identity.configurationIdentity == expectedIdentity else {
            throw SteamLaunchConfigurationProductAdapterError.standardIdentityMismatch(
                snapshot.identity.configurationIdentity
            )
        }
    }

    private static func graphicsBackend(
        for selection: SteamRendererPolicySelection
    ) throws -> SteamGraphicsBackendIdentifier {
        switch selection {
        case .d3dMetal:
            return .d3dMetal
        case .d3dMetalNVIDIA:
            guard let identifier = SteamGraphicsBackendIdentifier(
                rawValue: "d3dMetalNVIDIA"
            ) else {
                throw unsupportedOption(
                    category: SteamGraphicsBackendIdentifier.categoryName,
                    value: "d3dMetalNVIDIA"
                )
            }
            return identifier
        case .dxmt:
            return .dxmt
        case .d9vk:
            return .d9vk
        case .vulkan:
            return .dxvk
        }
    }

    private static func rendererSelection(
        for identifier: SteamGraphicsBackendIdentifier
    ) throws -> SteamRendererPolicySelection {
        switch identifier.rawValue {
        case SteamGraphicsBackendIdentifier.d3dMetal.rawValue:
            .d3dMetal
        case "d3dMetalNVIDIA":
            .d3dMetalNVIDIA
        case SteamGraphicsBackendIdentifier.dxmt.rawValue:
            .dxmt
        case SteamGraphicsBackendIdentifier.d9vk.rawValue:
            .d9vk
        case SteamGraphicsBackendIdentifier.dxvk.rawValue:
            .vulkan
        default:
            throw unsupportedOption(
                category: SteamGraphicsBackendIdentifier.categoryName,
                value: identifier.rawValue
            )
        }
    }

    private static func networkPolicy(
        for selection: SteamNetworkCompatibilitySelection
    ) throws -> SteamNetworkPolicyIdentifier {
        switch selection {
        case .standard:
            return .standard
        case .wifiIdentity:
            guard let identifier = SteamNetworkPolicyIdentifier(rawValue: "wifi-identity") else {
                throw unsupportedOption(
                    category: SteamNetworkPolicyIdentifier.categoryName,
                    value: "wifi-identity"
                )
            }
            return identifier
        case .ethernetIdentity:
            guard let identifier = SteamNetworkPolicyIdentifier(
                rawValue: "ethernet-identity"
            ) else {
                throw unsupportedOption(
                    category: SteamNetworkPolicyIdentifier.categoryName,
                    value: "ethernet-identity"
                )
            }
            return identifier
        }
    }

    private static func networkSelection(
        for identifier: SteamNetworkPolicyIdentifier
    ) throws -> SteamNetworkCompatibilitySelection {
        switch identifier.rawValue {
        case "standard":
            .standard
        case "wifi-identity":
            .wifiIdentity
        case "ethernet-identity":
            .ethernetIdentity
        default:
            throw unsupportedOption(
                category: SteamNetworkPolicyIdentifier.categoryName,
                value: identifier.rawValue
            )
        }
    }

    private static func audioInputPolicy(
        for selection: SteamAudioInputSelection
    ) -> SteamAudioInputPolicyIdentifier {
        switch selection {
        case .disabled:
            .disabled
        case .enabled:
            .enabled
        }
    }

    private static func audioInputSelection(
        for identifier: SteamAudioInputPolicyIdentifier
    ) throws -> SteamAudioInputSelection {
        switch identifier.rawValue {
        case "disabled":
            .disabled
        case "enabled":
            .enabled
        default:
            throw unsupportedOption(
                category: SteamAudioInputPolicyIdentifier.categoryName,
                value: identifier.rawValue
            )
        }
    }

    private static func synchronizationPolicy(
        for selection: WineSynchronizationSelection
    ) -> SteamSynchronizationPolicyIdentifier {
        switch selection {
        case .automatic:
            .automatic
        }
    }

    private static func synchronizationSelection(
        for identifier: SteamSynchronizationPolicyIdentifier
    ) throws -> WineSynchronizationSelection {
        switch identifier.rawValue {
        case "automatic":
            .automatic
        default:
            throw unsupportedOption(
                category: SteamSynchronizationPolicyIdentifier.categoryName,
                value: identifier.rawValue
            )
        }
    }

    private static func videoMemoryPolicy(
        for selection: SteamVideoMemorySelection
    ) throws -> SteamVideoMemoryPolicyIdentifier {
        let rawValue: String
        switch selection {
        case .automatic:
            return .automatic
        case .gb2:
            rawValue = "gb2"
        case .gb4:
            rawValue = "gb4"
        case .gb8:
            rawValue = "gb8"
        case .gb12:
            rawValue = "gb12"
        case .gb16:
            rawValue = "gb16"
        }
        guard let identifier = SteamVideoMemoryPolicyIdentifier(rawValue: rawValue) else {
            throw unsupportedOption(
                category: SteamVideoMemoryPolicyIdentifier.categoryName,
                value: rawValue
            )
        }
        return identifier
    }

    private static func videoMemorySelection(
        for identifier: SteamVideoMemoryPolicyIdentifier
    ) throws -> SteamVideoMemorySelection {
        switch identifier.rawValue {
        case "automatic":
            .automatic
        case "gb2":
            .gb2
        case "gb4":
            .gb4
        case "gb8":
            .gb8
        case "gb12":
            .gb12
        case "gb16":
            .gb16
        default:
            throw unsupportedOption(
                category: SteamVideoMemoryPolicyIdentifier.categoryName,
                value: identifier.rawValue
            )
        }
    }

    private static func gameModeEnabled(
        for policy: SteamGameModeLaunchPolicy
    ) -> Bool {
        switch policy {
        case .standard:
            false
        case .experimentalRequiredHost:
            true
        }
    }

    private static func gameModePolicy(
        for isEnabled: Bool
    ) -> SteamGameModeLaunchPolicy {
        if isEnabled {
            return .experimentalRequiredHost
        }
        return .standard
    }

    private static func unsupportedOption(
        category: String,
        value: String
    ) -> SteamLaunchConfigurationProductAdapterError {
        .unsupportedOption(category: category, value: value)
    }

}
