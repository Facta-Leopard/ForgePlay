import Darwin
import Foundation
import GameController

enum ControllerCompatibilityMacState: String, Codable, Hashable, Sendable {
    case noControllerDetected
    case controllerDetected
}

struct ControllerCompatibilityPreflightSnapshot: Hashable, Sendable {
    let checkedAt: Date
    let macState: ControllerCompatibilityMacState
    let connectedControllerCount: Int
    let extendedGamepadCount: Int
    let productCategories: [String]

    var requiresRuntimeVisibilityVerification: Bool {
        macState == .controllerDetected
    }
}

struct WineXInputBridgeCapability: Hashable, Sendable {
    /// The Steam client compatibility profile owns macOS IOHID passthrough:
    /// DisableHidraw=0 keeps IOHID enabled, while DisableInput=1 together with
    /// Enable SDL=0 prefers raw Generic Desktop gamepads in the bundled
    /// runtime. This session installs no separate XInput bridge; Wine-child
    /// enumeration remains explicitly unverified real-device QA evidence.
    let isStaticRouteAvailable: Bool
    let routeDigest: String?
    let moduleNames: [String]
}

enum ControllerCompatibilityApplicationDisposition: String, Hashable, Sendable {
    case automaticWineIOHIDPassthroughNoMutation
}

struct ControllerCompatibilityApplicationReceipt: Hashable, Sendable {
    let policy: ControllerCompatibilityPolicy
    let disposition: ControllerCompatibilityApplicationDisposition
    let macDiscoveryCount: Int
    let uniqueMacDeviceCount: Int
    let acceptedLogicalDeviceCount: Int
    let xinputSlotOverflowCount: Int
    let duplicateReferenceCount: Int
    let staticBridgeCapability: WineXInputBridgeCapability
    let boundLauncherProcessIdentifier: pid_t?
    let staticRouteContinuityDigest: String?
    let requiresChildDeviceEnumeration: Bool
    let actualChildEnumerationVerified: Bool
    let restored: Bool

    /// Kept as the compatibility-facing property name. Automatic mode owns no
    /// controller resource. The shared Steam profile owns the winebus registry
    /// policy while Wine's IOHID route remains authoritative whether or not
    /// macOS currently sees a device.
    var isStaticPreparationVerified: Bool {
        policy == .automatic &&
            disposition == .automaticWineIOHIDPassthroughNoMutation &&
            macDiscoveryCount >= 0 &&
            uniqueMacDeviceCount >= 0 &&
            acceptedLogicalDeviceCount == 0 &&
            xinputSlotOverflowCount == 0 &&
            duplicateReferenceCount >= 0 &&
            !staticBridgeCapability.isStaticRouteAvailable &&
            staticBridgeCapability.routeDigest == nil &&
            staticBridgeCapability.moduleNames.isEmpty &&
            boundLauncherProcessIdentifier == nil &&
            staticRouteContinuityDigest == nil &&
            !requiresChildDeviceEnumeration &&
            !actualChildEnumerationVerified &&
            !restored
    }

    var isResourceFreeNoMutation: Bool {
        isStaticPreparationVerified
    }
}

enum ControllerCompatibilityBridgeError: LocalizedError, Equatable, Sendable {
    case unsupportedPolicy(ControllerCompatibilityPolicy)
    case xinputRouteUnavailable
    case xinputRouteChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedPolicy(let policy):
            "선택한 컨트롤러 정책에는 관리되는 Wine 자식 입력 관찰 경계가 없습니다: \(policy.rawValue)"
        case .xinputRouteUnavailable:
            "Wine 자식의 실제 XInput 열거·라우팅을 관찰할 수 없습니다."
        case .xinputRouteChanged:
            "Steam 실행 중 Wine XInput 관찰 경계가 변경되었습니다."
        }
    }
}

struct ControllerCompatibilityInventory: Hashable, Sendable {
    let macDiscoveryCount: Int
    let uniqueMacDeviceCount: Int
    let duplicateReferenceCount: Int

    init(
        macDiscoveryCount: Int,
        uniqueMacDeviceCount: Int,
        duplicateReferenceCount: Int = 0
    ) {
        self.macDiscoveryCount = max(macDiscoveryCount, 0)
        self.uniqueMacDeviceCount = max(uniqueMacDeviceCount, 0)
        self.duplicateReferenceCount = max(duplicateReferenceCount, 0)
    }

    @MainActor
    static func current() -> Self {
        let controllers = GCController.controllers()
        var identities = Set<ObjectIdentifier>()
        var duplicates = 0
        for controller in controllers {
            if !identities.insert(ObjectIdentifier(controller)).inserted {
                duplicates += 1
            }
        }
        return Self(
            macDiscoveryCount: controllers.count,
            uniqueMacDeviceCount: identities.count,
            duplicateReferenceCount: duplicates
        )
    }
}

@MainActor
final class SteamControllerCompatibilitySession {
    typealias InventoryProvider = @MainActor () -> ControllerCompatibilityInventory

    private let policy: ControllerCompatibilityPolicy
    private let inventoryProvider: InventoryProvider
    private var isBoundToValidLaunch = false
    private(set) var isRestored = false

    /// Automatic IOHID passthrough owns no runtime resource and must not be
    /// used to create a synthetic state delta.
    var requiresLifecycleRetention: Bool { false }

    init(
        runtimeExecutable _: URL,
        policy: ControllerCompatibilityPolicy,
        fileManager _: FileManager = .default,
        inventory: ControllerCompatibilityInventory? = nil,
        inventoryProvider: InventoryProvider? = nil
    ) throws {
        let resolvedProvider: InventoryProvider
        if let inventoryProvider {
            resolvedProvider = inventoryProvider
        } else if let inventory {
            resolvedProvider = { inventory }
        } else {
            resolvedProvider = { .current() }
        }
        let resolvedInventory = resolvedProvider()
        try Self.requireSupported(
            policy: policy,
            inventory: resolvedInventory
        )
        self.policy = policy
        self.inventoryProvider = resolvedProvider
    }

    static func requireSupported(
        policy: ControllerCompatibilityPolicy,
        inventory: ControllerCompatibilityInventory
    ) throws {
        guard policy == .automatic else {
            throw ControllerCompatibilityBridgeError.unsupportedPolicy(policy)
        }
        // Host inventory is diagnostic context only. The bundled Wine runtime
        // already owns IOHID passthrough, so device presence must not turn an
        // otherwise mutation-free automatic launch into a fail-closed bridge
        // request that ForgePlay neither installs nor controls.
        _ = inventory
    }

    func revalidateBeforeSpawn() throws {
        guard !isRestored else {
            throw ControllerCompatibilityBridgeError.xinputRouteUnavailable
        }
        _ = try currentInventory()
    }

    func bindManagedWineTransport(processIdentifier: pid_t) throws {
        guard !isRestored, processIdentifier > 0 else {
            throw ControllerCompatibilityBridgeError.xinputRouteUnavailable
        }
        _ = try currentInventory()
        // The surrounding launch boundary supplied a valid process, but the
        // controller session neither binds nor mutates it. Wine's IOHID route
        // remains the runtime owner and the receipt contains no PID evidence.
        isBoundToValidLaunch = true
    }

    func applicationReceipt() throws -> ControllerCompatibilityApplicationReceipt {
        guard isBoundToValidLaunch, !isRestored else {
            throw ControllerCompatibilityBridgeError.xinputRouteUnavailable
        }
        return try resourceFreeDetachedHandoffReceipt()
    }

    /// Automatic IOHID passthrough owns no child resource and performs no
    /// mutation. A successful detached helper handoff can therefore retain an
    /// honest static receipt without pretending that the already-exited helper
    /// PID is a live managed transport.
    func resourceFreeDetachedHandoffReceipt() throws ->
        ControllerCompatibilityApplicationReceipt {
        guard !isRestored else {
            throw ControllerCompatibilityBridgeError.xinputRouteUnavailable
        }
        let inventory = try currentInventory()
        let receipt = ControllerCompatibilityApplicationReceipt(
            policy: policy,
            disposition: .automaticWineIOHIDPassthroughNoMutation,
            macDiscoveryCount: inventory.macDiscoveryCount,
            uniqueMacDeviceCount: inventory.uniqueMacDeviceCount,
            acceptedLogicalDeviceCount: 0,
            xinputSlotOverflowCount: 0,
            duplicateReferenceCount: inventory.duplicateReferenceCount,
            staticBridgeCapability: WineXInputBridgeCapability(
                isStaticRouteAvailable: false,
                routeDigest: nil,
                moduleNames: []
            ),
            boundLauncherProcessIdentifier: nil,
            staticRouteContinuityDigest: nil,
            requiresChildDeviceEnumeration: false,
            actualChildEnumerationVerified: false,
            restored: false
        )
        guard receipt.isResourceFreeNoMutation else {
            throw ControllerCompatibilityBridgeError.xinputRouteUnavailable
        }
        return receipt
    }

    private func currentInventory() throws -> ControllerCompatibilityInventory {
        let current = inventoryProvider()
        try Self.requireSupported(policy: policy, inventory: current)
        return current
    }

    func restore() {
        guard !isRestored else { return }
        isBoundToValidLaunch = false
        isRestored = true
    }

    deinit {
        MainActor.assumeIsolated {
            restore()
        }
    }
}

@MainActor
struct ControllerCompatibilityPreflightService {
    private static let maximumReportedCategories = 8
    private static let maximumCategoryCharacters = 80

    func inspectConnectedControllers(
        checkedAt: Date = Date()
    ) -> ControllerCompatibilityPreflightSnapshot {
        let controllers = GCController.controllers()
        let categories = Array(
            Set(controllers.compactMap { controller in
                Self.normalizedProductCategory(controller.productCategory)
            })
        )
            .sorted()
            .prefix(Self.maximumReportedCategories)

        return ControllerCompatibilityPreflightSnapshot(
            checkedAt: checkedAt,
            macState: controllers.isEmpty ? .noControllerDetected : .controllerDetected,
            connectedControllerCount: controllers.count,
            extendedGamepadCount: controllers.filter { $0.extendedGamepad != nil }.count,
            productCategories: Array(categories)
        )
    }

    private static func normalizedProductCategory(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return String(trimmed.prefix(maximumCategoryCharacters))
    }
}
