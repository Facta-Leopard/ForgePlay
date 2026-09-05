import Foundation

enum FrameGenerationConfigurationError:
    LocalizedError, Equatable, Sendable, ForgePlayTechnicalDescribingError
{
    case unavailableTargetFrameRate(Int)
    case frameCheckRequiresFrameGeneration
    case d3dMetalNVIDIARendererRequired

    var errorDescription: String? {
        switch self {
        case .unavailableTargetFrameRate(let framesPerSecond):
            "현재 Release에서는 프레임 생성 목표 \(framesPerSecond) FPS를 선택할 수 없습니다."
        case .frameCheckRequiresFrameGeneration:
            "Frame Check는 프레임 생성을 켠 실행에서만 사용할 수 있습니다."
        case .d3dMetalNVIDIARendererRequired:
            "Frame Generation (베타)은 현재 D3DMetal - NVIDIA에서만 켤 수 있습니다."
        }
    }

    var forgePlayTechnicalDescription: String {
        "FrameGenerationConfigurationError \(String(describing: self))"
    }
}

enum FrameGenerationTargetFrameRate: Int, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case fps120 = 120
    case fps144 = 144
    case fps240 = 240

    var id: Int { rawValue }

    var isSelectableInCurrentRelease: Bool {
        FrameGenerationPolicy.selectableTargetFrameRates.contains(self)
    }

}

enum FrameGenerationPolicy {
    static let visibleTargetFrameRates = FrameGenerationTargetFrameRate.allCases
    static let selectableTargetFrameRates: Set<FrameGenerationTargetFrameRate> = [.fps120]
}

struct FrameGenerationConfiguration: Codable, Hashable, Sendable {
    static let off = Self(
        isEnabled: false,
        targetFrameRate: .fps120,
        isFrameCheckEnabled: false
    )

    var isEnabled: Bool
    var targetFrameRate: FrameGenerationTargetFrameRate
    var isFrameCheckEnabled: Bool

    init(
        isEnabled: Bool = false,
        targetFrameRate: FrameGenerationTargetFrameRate = .fps120,
        isFrameCheckEnabled: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.targetFrameRate = targetFrameRate
        self.isFrameCheckEnabled = isFrameCheckEnabled
    }

    func validate(isSupportedRenderer: Bool) throws {
        guard isEnabled || !isFrameCheckEnabled else {
            throw FrameGenerationConfigurationError.frameCheckRequiresFrameGeneration
        }
        guard !isEnabled || targetFrameRate.isSelectableInCurrentRelease else {
            throw FrameGenerationConfigurationError.unavailableTargetFrameRate(
                targetFrameRate.rawValue
            )
        }
        guard !isEnabled || isSupportedRenderer else {
            throw FrameGenerationConfigurationError
                .d3dMetalNVIDIARendererRequired
        }
    }

    mutating func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        if !enabled {
            isFrameCheckEnabled = false
        } else {
            if !wasEnabled {
                // Frame Check is the default companion for a newly enabled
                // Frame Generation draft. Restored enabled configurations are
                // assigned directly, so an explicitly saved OFF value remains
                // untouched when the launch view restores it.
                isFrameCheckEnabled = true
            }
            if !targetFrameRate.isSelectableInCurrentRelease {
                // A dormant future target must never become a launch-blocking
                // trap after an app downgrade. Enabling chooses today's
                // supported target.
                targetFrameRate = .fps120
            }
        }
    }
}

enum FrameGenerationEnvironmentContract {
    static let enabledKey = "FORGEPLAY_D3DMETAL_FRAME_GENERATION"
    static let targetFrameRateKey = "FORGEPLAY_D3DMETAL_FRAME_GENERATION_TARGET_HZ"
    static let frameCheckEnabledKey = "FORGEPLAY_D3DMETAL_FRAME_CHECK"
    static let proxyPathKey = "FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY"
    static let observationFileKey =
        "FORGEPLAY_D3DMETAL_FRAME_GENERATION_OBSERVATION_FILE"
}
