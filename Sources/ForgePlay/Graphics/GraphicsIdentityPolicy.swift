import Foundation

/// The single product-owned projection for the NVIDIA compatibility identity
/// exposed to routed D3DMetal game children. Wine consumes this exact tuple in
/// its owning SetupAPI/Display Class/DirectX registry writer; ForgePlay does not
/// mutate a prefix registry before launch.
enum GraphicsIdentityPolicy {
    struct NVIDIAIdentity: Hashable, Sendable {
        let profileIdentifier: String
        let vendorID: String
        let deviceID: String
        let deviceName: String
        let userModeDriverVersion: String
        let displayDriverVersion: String

        var childEnvironment: [String: String] {
            [
                EnvironmentKey.profile: profileIdentifier,
                EnvironmentKey.vendorID: vendorID,
                EnvironmentKey.deviceID: deviceID,
                EnvironmentKey.deviceName: deviceName,
                EnvironmentKey.userModeDriverVersion: userModeDriverVersion,
                EnvironmentKey.displayDriverVersion: displayDriverVersion
            ]
        }
    }

    enum EnvironmentKey {
        static let profile = "FORGEPLAY_NVIDIA_IDENTITY_PROFILE"
        static let vendorID = "FORGEPLAY_NVIDIA_IDENTITY_VENDOR_ID"
        static let deviceID = "FORGEPLAY_NVIDIA_IDENTITY_DEVICE_ID"
        static let deviceName = "FORGEPLAY_NVIDIA_IDENTITY_DEVICE_NAME"
        static let userModeDriverVersion =
            "FORGEPLAY_NVIDIA_IDENTITY_DRIVER_VERSION"
        static let displayDriverVersion =
            "FORGEPLAY_NVIDIA_IDENTITY_DISPLAY_DRIVER_VERSION"

        static let all = [
            profile,
            vendorID,
            deviceID,
            deviceName,
            userModeDriverVersion,
            displayDriverVersion
        ]
    }

    static let nvidiaRTX4090Driver56109 = NVIDIAIdentity(
        profileIdentifier: "rtx-4090-driver-561.09-v2",
        vendorID: "0x10de",
        deviceID: "0x2684",
        deviceName: "NVIDIA GeForce RTX 4090",
        userModeDriverVersion: "561.09",
        displayDriverVersion: "32.0.15.6109"
    )
}
