// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import Darwin
import CryptoKit
import Foundation
import Observation

struct ProcessRunResult: Sendable, Hashable {
    var actionName: String
    var executable: URL
    var arguments: [String]
    var startedAt: Date
    var endedAt: Date
    var exitCode: Int32
    /// `false` for failures that occurred before an operating-system process
    /// produced an exit status. `exitCode` remains non-optional for source
    /// compatibility, but must not be persisted or presented as a real process
    /// status in that case.
    var hasProcessExitCode: Bool = true
    /// ForgePlay's own operation/verification result. This is intentionally
    /// separate from `exitCode`: values such as Steam evidence gate 74 are not
    /// operating-system process exit statuses.
    var forgePlayStatusCode: Int32? = nil
    var stdoutLog: URL
    var stderrLog: URL
    var diagnosticLog: URL? = nil
    var didTimeOut: Bool
    var waitedForExit: Bool = true
    var outcome: ProcessRunOutcome = .unknown
    var terminationSignal: Int32? = nil
    var rawWaitStatus: Int32? = nil
    var steamUIVerificationState: SteamUIVerificationState? = nil
    var steamUISurface: SteamUISurface? = nil
    var processIdentifier: Int32? = nil
    var processObservationLog: URL? = nil
    var steamUIStartupRecoveryAttemptCount: Int = 0
    var steamUIStartupRecoveryReason: String? = nil
    var runEvidenceLog: URL? = nil
    /// Structured sidecars for additional commands that are part of this
    /// operation (for example a Wine shutdown barrier or a prior retry).
    var relatedRunEvidenceLogs: [URL] = []
    var evidenceCaptureWarning: String? = nil
    var diagnosticCaptureWarning: String? = nil
    /// A localization key for a bounded warning that should be shown alongside
    /// an otherwise successful process launch. Technical diagnostics remain in
    /// `diagnosticCaptureWarning` and the structured process evidence.
    var userFacingWarningLocalizationKey: String? = nil
    /// A pointer-only protection request can be safely omitted when the
    /// short-lived ForgePlay detach helper has already exited and no stable
    /// managed process-group binding is available. Event-tap protections never
    /// use this degradation path.
    var inputProtectionDegradedForDetachedHandoff: Bool = false
    /// The authoritative postcondition for a multi-process operation. Wine
    /// prefix shutdown uses this to preserve a failed/timed-out signal attempt
    /// while still reporting success when cleanup plus the wineserver exit
    /// barrier prove that the prefix is no longer active.
    var postconditionSatisfied: Bool? = nil
    /// Parent-composed projection of the exact sanitized environment assigned
    /// to a successfully spawned managed Wine transport. This is launch input
    /// evidence; it does not claim that the Windows child observed or applied
    /// any value.
    var managedWineLaunchEnvironmentProjection:
        ManagedWineLaunchEnvironmentProjection? = nil
    /// Parent-owned policy snapshot used to construct the child environment
    /// and to verify the parent projection. This is not child observation.
    var managedWineRosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1? = nil
    /// Environment independently read from the live operating-system child
    /// process after spawn. Unlike the parent projection, this is child-side
    /// observation and is unavailable for an already-exited process.
    var managedWineChildSynchronizationReadback:
        ManagedWineChildSynchronizationReadback? = nil
    var inputCompatibilityReceipt:
        SteamInputCompatibilityApplicationReceipt? = nil
    var controllerCompatibilityReceipt:
        ControllerCompatibilityApplicationReceipt? = nil
    var windowsFontProvisioningReceipt:
        WindowsFontProvisioningApplicationReceipt? = nil
    var rendererRouteApplicationReceipt:
        SteamRendererRouteApplicationReceipt? = nil
}

struct ManagedWineChildSynchronizationReadback: Sendable, Hashable {
    let processIdentifier: Int32
    let selection: WineSynchronizationSelection
    let backend: WineSynchronizationBackend
}

struct ManagedWineLaunchEnvironmentProjection: Sendable, Hashable {
    let transport: String
    let rosettaAdvertiseAVX: String?
    let policyVersion: String?
    let hostAuthorization: String?
    let steamAppID: String?
    let canonicalGameRoot: String?
    /// Diagnostic correlation only. Authorization is owned by the host's
    /// canonical object check and current per-launch lineage.
    let canonicalGameRootIdentityTelemetryDigest: String?
    let manifestRootAuthorizationTelemetryDigest: String?
    let lineageNonce: String?
    let heapZeroMemoryRequested: String?
    let gameGuardRendererExclusionRequested: String?
    let rendererSelection: String?
    let networkSelection: String?
    let audioInputSelection: String?
    let synchronizationSelection: String?
    let synchronizationBackend: String?
}

struct ManagedWineRosettaAVXPolicyV1: Sendable, Hashable {
    static let hostOverrideKey = "FORGEPLAY_ROSETTA_ADVERTISE_AVX"
    static let childEnvironmentKey = "ROSETTA_ADVERTISE_AVX"

    enum Advertisement: String, Sendable, Hashable {
        case enabled
        case disabled
    }

    let advertisement: Advertisement

    /// Trusted ForgePlay disposition for managed Wine control and recovery
    /// commands. Ambient launch overrides are admission inputs, not cleanup
    /// dependencies.
    static let managedDefault = Self(advertisement: .enabled)

    var childEnvironmentValue: String? {
        advertisement == .enabled ? "1" : nil
    }

    static func snapshot(
        hostOverride: String? = ProcessInfo.processInfo.environment[
            ManagedWineRosettaAVXPolicyV1.hostOverrideKey
        ]
    ) throws -> Self {
        switch hostOverride {
        case nil, "1":
            Self(advertisement: .enabled)
        case "0":
            Self(advertisement: .disabled)
        case .some(let value):
            throw SafeProcessRunnerError.invalidRosettaAVXHostOverride(value)
        }
    }

    func apply(to environment: inout [String: String]) {
        if let childEnvironmentValue {
            environment[Self.childEnvironmentKey] = childEnvironmentValue
        } else {
            environment.removeValue(forKey: Self.childEnvironmentKey)
        }
    }
}

enum ManagedProcessSignalOwnershipSource: String, Sendable, Hashable {
    case trackedFoundationProcess
    case trackedDescriptorBoundProcess
    case managedWineJournal
    case gameModeHostJournal
}

/// A PID number is never a signal capability by itself. Every cleanup target
/// carries the exact kernel start identity and executable object observed at
/// collection. Journal, Foundation, and Game Mode targets must retain both
/// identities.
/// A descriptor-bound target additionally retains the unreaped WNOWAIT leader;
/// for that source an exec transition preserves ownership only while the exact
/// start identity brackets a readable current executable observation.
struct ManagedProcessSignalTarget: Sendable, Hashable {
    let processID: pid_t
    let processStartedAtUnixMicroseconds: UInt64
    let executableURL: URL
    let source: ManagedProcessSignalOwnershipSource
}

/// Exact live identity returned to launch-lifecycle observers. A Darwin PID is
/// never sufficient on its own because the numeric value can be reused between
/// the system snapshot and the managed-journal readback. The executable is the
/// exact current object that passed the managed Runtime allowlist check for the
/// same PID and kernel start identity.
struct ManagedWineLaunchProcessIdentity: Sendable, Hashable {
    let processID: Int32
    let processStartedAtUnixMicroseconds: UInt64
    let executableURL: URL
}

enum ManagedSignalCapabilityMergeDecision: Sendable, Hashable {
    case keepExisting
    case replaceExisting
    case obstruct
}

enum ManagedWineReadbackFailureIdentityDisposition: Sendable, Hashable {
    case candidateExited
    case candidateWasReused(observedStartTimeUnixMicroseconds: UInt64)
    case failClosed
}

/// Result of the descriptor-bound leader's `waitid(..., WNOWAIT)` observer.
/// Only `terminalStateObserved` proves that the exact retained leader exited;
/// an observation error is deliberately indeterminate and must never grant
/// journal-validation or signaling authority.
enum DescriptorBoundRootWaitObservation: Sendable, Equatable {
    case awaitingTerminalState
    case terminalStateObserved
    case failed(Int32)

    var successfullyObservedTerminalState: Bool {
        if case .terminalStateObserved = self { return true }
        return false
    }

    var errorCode: Int32? {
        guard case .failed(let errorCode) = self else { return nil }
        return errorCode
    }
}

struct CommandSpec: Sendable, Hashable {
    var actionName: String
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var runtimeCompatibility: [String: String] = [:]
    var workingDirectory: URL?
    var stdoutLog: URL
    var stderrLog: URL
    var timeout: TimeInterval?
    var waitsForExit: Bool = true
    var startupValidationInterval: TimeInterval = 0
    var processObservationLog: URL? = nil
    /// Path-free, bounded records written before the child starts so the child
    /// inherits a log offset after these records and cannot overwrite them.
    var preparationDiagnosticMarkers: [String] = []
    var preparationDiagnosticWarning: String? = nil
    var userFacingWarningLocalizationKey: String? = nil
    /// Captured after runtime-manifest validation and rechecked immediately
    /// before process creation.
    var runtimeLaunchObjectIdentity: RuntimeLaunchObjectIdentity? = nil
    /// The exact logical executable for which the retained launch identity was
    /// captured. Runtime validation is rooted at the canonical Wine launcher,
    /// but command construction may select a sibling executable such as
    /// `wineserver`; descriptor-bound spawn must follow that final selection.
    var runtimeLaunchObjectIdentityExecutable: URL? = nil
    /// Selected Steam-library root, steamapps, ACF, common, and game-root
    /// identities retained by the provider and rechecked at the last host
    /// boundary before process creation.
    var anchoredLibraryPathIdentity:
        CompatibilityAnchoredPathIdentityV1? = nil
    /// Exact user-selected utility bytes retained before launch preparation.
    /// The child receives a descriptor path, while its working directory stays
    /// at the original utility directory for auxiliary-file access.
    var windowsUtilityExecutableIdentity:
        WindowsUtilityExecutableLaunchIdentity? = nil
    /// One launch-scoped host-policy snapshot. Both the child environment and
    /// parent-side expected projection consume this exact value.
    var managedWineRosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1? = nil
    /// Host-owned durable ownership for a managed Wine launch. This is kept out
    /// of the child environment; Wine receives only the bounded append journal
    /// path and correlation fields required to report exact Darwin identities.
    var managedWineLaunchSession: ManagedWineProcessLaunchSession? = nil
}

final class WindowsUtilityExecutableLaunchIdentity:
    @unchecked Sendable,
    Hashable {
    private static let maximumByteCount: Int64 = 512 * 1024 * 1024
    private static let minimumChildDescriptor: Int32 = 200
    private static let maximumChildDescriptor: Int32 = 4_096
    static let environmentKey =
        "FORGEPLAY_BOUND_WINDOWS_UTILITY_EXECUTABLE_FD_V1"

    let executable: URL
    let originalWindowsCommandPath: String
    private let liveDescriptor: Int32
    private let snapshot: OwnerPrivateUnlinkedFileSnapshotV1
    private let expectedIdentity: StableRegularFileIdentityV1

    init(
        executable: URL,
        originalWindowsCommandPath: String
    ) throws {
        let normalized = executable.standardizedFileURL
        let liveDescriptor = Darwin.open(
            normalized.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard liveDescriptor >= 0 else {
            throw SafeProcessRunnerError.unsafeActionInput(normalized)
        }
        let snapshot: OwnerPrivateUnlinkedFileSnapshotV1
        do {
            snapshot = try OwnerPrivateUnlinkedFileSnapshotV1(
                copyingSourceDescriptor: liveDescriptor,
                maximumByteCount: Self.maximumByteCount
            )
        } catch {
            Darwin.close(liveDescriptor)
            throw SafeProcessRunnerError.metadataReadFailed(
                normalized,
                "could not create an immutable executable snapshot"
            )
        }
        self.executable = normalized
        self.originalWindowsCommandPath = originalWindowsCommandPath
        self.liveDescriptor = liveDescriptor
        self.snapshot = snapshot
        self.expectedIdentity = snapshot.sourceIdentity
    }

    deinit {
        Darwin.close(liveDescriptor)
    }

    static func == (
        lhs: WindowsUtilityExecutableLaunchIdentity,
        rhs: WindowsUtilityExecutableLaunchIdentity
    ) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func revalidate() throws {
        guard (try? OwnerPrivateUnlinkedFileSnapshotV1.stableIdentity(
            descriptor: liveDescriptor,
            maximumByteCount: Self.maximumByteCount
        )) == expectedIdentity else {
            throw SafeProcessRunnerError.unsafeActionInput(executable)
        }

        let currentDescriptor = Darwin.open(
            executable.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw SafeProcessRunnerError.unsafeActionInput(executable)
        }
        defer { Darwin.close(currentDescriptor) }
        guard (try? OwnerPrivateUnlinkedFileSnapshotV1.stableIdentity(
            descriptor: currentDescriptor,
            maximumByteCount: Self.maximumByteCount
        )) == expectedIdentity else {
            throw SafeProcessRunnerError.unsafeActionInput(executable)
        }
    }

    func installSpawnCapability(
        fileActions: inout posix_spawn_file_actions_t?,
        environment: inout [String: String],
        arguments: [String]
    ) throws -> [String] {
        try revalidate()
        let usedDescriptors = try Self.projectedChildDescriptors(
            environment: environment
        ) + [snapshot.descriptor]
        let nextDescriptor = max(
            Self.minimumChildDescriptor,
            (usedDescriptors.max() ?? (Self.minimumChildDescriptor - 1)) + 1
        )
        guard nextDescriptor <= Self.maximumChildDescriptor else {
            throw SafeProcessRunnerError.metadataReadFailed(
                executable,
                "utility capability descriptor range is exhausted"
            )
        }
        var descriptorLimit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &descriptorLimit) == 0,
              UInt64(nextDescriptor) < UInt64(descriptorLimit.rlim_cur) else {
            throw SafeProcessRunnerError.metadataReadFailed(
                executable,
                "utility capability descriptor exceeds the process limit"
            )
        }
        let actionResult = posix_spawn_file_actions_adddup2(
            &fileActions,
            snapshot.descriptor,
            nextDescriptor
        )
        guard actionResult == 0 else {
            throw SafeProcessRunnerError.metadataReadFailed(
                executable,
                String(cString: strerror(actionResult))
            )
        }
        environment[Self.environmentKey] = String(nextDescriptor)
        let boundWindowsPath = "Z:\\dev\\fd\\\(nextDescriptor)"
        let matchingIndices = arguments.indices.filter {
            arguments[$0] == originalWindowsCommandPath
        }
        guard matchingIndices.count == 1,
              let matchingIndex = matchingIndices.first else {
            throw SafeProcessRunnerError.unsafeCommandArgument(
                "windowsUtilityExecutable"
            )
        }
        var boundArguments = arguments
        boundArguments[matchingIndex] = boundWindowsPath
        try revalidate()
        return boundArguments
    }

    private static func projectedChildDescriptors(
        environment: [String: String]
    ) throws -> [Int32] {
        var descriptors: [Int32] = []
        for key in [
            "FORGEPLAY_BOUND_EXECUTABLE_FD",
            "FORGEPLAY_BOUND_RUNTIME_ROOT_FD"
        ] {
            guard let value = environment[key] else { continue }
            guard let descriptor = Int32(value), descriptor >= 0 else {
                throw SafeProcessRunnerError.unsafeCommandArgument(
                    "windowsUtilityDescriptorProjection"
                )
            }
            descriptors.append(descriptor)
        }
        for key in [
            "FORGEPLAY_BOUND_RUNTIME_OBJECT_FDS",
            "FORGEPLAY_BOUND_LIBRARY_OBJECT_FDS_V1"
        ] {
            guard let value = environment[key], !value.isEmpty else {
                continue
            }
            for row in value.split(separator: "|", omittingEmptySubsequences: false) {
                guard let first = row.split(
                    separator: ":",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).first,
                let descriptor = Int32(first), descriptor >= 0 else {
                    throw SafeProcessRunnerError.unsafeCommandArgument(
                        "windowsUtilityDescriptorProjection"
                    )
                }
                descriptors.append(descriptor)
            }
        }
        return descriptors
    }

}

private struct RunnerSearchPaths {
    var dynamicLibraries: [String]
    var frameworks: [String]
    var d3dMetalFrameworkExecutables: [String]
    var wineDLLs: [String]
    var vulkanICDs: [String]
}

/// Host-owned rules for Windows helper processes that must share the Steam
/// prefix but must not inherit a game's renderer. Rules are exact,
/// case-insensitive path suffixes; the Wine runtime performs the match before
/// it creates the child environment.
enum SteamBaseRuntimeCompatibilityHelperContract {
    nonisolated static let environmentKey =
        "FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1"

    /// Blue Archive's NGS service installer is a 32-bit helper even though it
    /// lives below the game's x86_64 plug-in directory. D3DMetal has no
    /// 32-bit renderer payload, so only these three NGS helper entry points use
    /// the base Wine environment. The game and every other descendant retain
    /// the selected renderer policy.
    nonisolated static let blueArchivePathSuffixes = [
        "\\steamapps\\common\\BlueArchive\\BlueArchive_Data\\Plugins\\x86_64\\grap\\NGService.exe",
        "\\steamapps\\common\\BlueArchive\\BlueArchive_Data\\Plugins\\x86_64\\grap\\NGService_Install.bat",
        "\\steamapps\\common\\BlueArchive\\BlueArchive_Data\\Plugins\\x86_64\\grap\\NGService_Uninstall.bat"
    ]

    nonisolated static var encodedRules: String {
        blueArchivePathSuffixes.joined(separator: ";")
    }
}

enum Helldivers2ManagedWineChildPolicyContract {
    nonisolated static let policyVersionKey =
        "FORGEPLAY_HELLDIVERS2_PROCESS_POLICY_VERSION"
    nonisolated static let steamAppIDKey =
        "FORGEPLAY_HELLDIVERS2_STEAM_APP_ID"
    nonisolated static let hostAuthorizationKey =
        "FORGEPLAY_HELLDIVERS2_HOST_AUTHORIZATION"
    nonisolated static let canonicalRootKey =
        "FORGEPLAY_HELLDIVERS2_CANONICAL_ROOT"
    nonisolated static let canonicalRootIdentityTelemetryDigestKey =
        "FORGEPLAY_HELLDIVERS2_ROOT_IDENTITY_TELEMETRY_SHA256"
    nonisolated static let manifestRootAuthorizationTelemetryDigestKey =
        "FORGEPLAY_HELLDIVERS2_MANIFEST_AUTHORIZATION_TELEMETRY_SHA256"
    nonisolated static let lineageNonceKey =
        "FORGEPLAY_HELLDIVERS2_LINEAGE_NONCE"
    nonisolated static let heapZeroMemoryRequestedKey =
        "FORGEPLAY_HELLDIVERS2_HEAP_ZERO_MEMORY_REQUESTED"
    nonisolated static let gameGuardRendererExclusionRequestedKey =
        "FORGEPLAY_HELLDIVERS2_GAMEGUARD_RENDERER_EXCLUSION_REQUESTED"
    nonisolated static let policyVersion = "1"
    nonisolated static let hostAuthorization =
        "canonical-root-current-lineage-v1"
}

enum WineSynchronizationBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case server

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let legacyValue = try container.decode(String.self)
        guard legacyValue == Self.server.rawValue else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Wine synchronization backend: \(legacyValue)"
            )
        }
        self = .server
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.server.rawValue)
    }
}

/// Records every Wine prefix touched by this ForgePlay process. The registry is
/// deliberately independent of the actor so the synchronous application-
/// termination planner can include prefixes used before a storage-root change.
struct ManagedWineProcessLaunchSession: Hashable, Sendable {
    let prefixURL: URL
    let runIdentifier: String
    let evidenceURL: URL
    let descriptorURL: URL?
    let runtimeRootURL: URL
    let runtimeFingerprint: String
    let prefixScope: String
    let registeredAt: Date

    init(
        prefixURL: URL,
        runIdentifier: String,
        evidenceURL: URL,
        descriptorURL: URL? = nil,
        runtimeRootURL: URL,
        runtimeFingerprint: String,
        prefixScope: String,
        registeredAt: Date
    ) {
        self.prefixURL = prefixURL
        self.runIdentifier = runIdentifier
        self.evidenceURL = evidenceURL
        self.descriptorURL = descriptorURL
        self.runtimeRootURL = runtimeRootURL
        self.runtimeFingerprint = runtimeFingerprint
        self.prefixScope = prefixScope
        self.registeredAt = registeredAt
    }
}

struct ManagedWineTrustedPrefixIdentity: Codable, Hashable, Sendable {
    let deviceIdentifier: String
    let inodeIdentifier: String
    let ownerUserIdentifier: UInt32

    enum CodingKeys: String, CodingKey {
        case deviceIdentifier = "device_identifier"
        case inodeIdentifier = "inode_identifier"
        case ownerUserIdentifier = "owner_user_identifier"
    }
}

struct ManagedWineActiveSessionDescriptor: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let producer = "forgeplay-host"

    let schemaVersion: Int
    let producer: String
    let runIdentifier: String
    let evidenceFileName: String
    let prefixScope: String
    let prefixIdentity: ManagedWineTrustedPrefixIdentity
    let runtimeFingerprint: String
    let runtimeRootScope: String
    let ownerProcessIdentifier: Int32
    let ownerProcessStartedAtUnixMicroseconds: UInt64
    let registeredAtUnixMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case producer
        case runIdentifier = "run_identifier"
        case evidenceFileName = "evidence_file_name"
        case prefixScope = "prefix_scope"
        case prefixIdentity = "prefix_identity"
        case runtimeFingerprint = "runtime_fingerprint"
        case runtimeRootScope = "runtime_root_scope"
        case ownerProcessIdentifier = "owner_process_identifier"
        case ownerProcessStartedAtUnixMicroseconds =
            "owner_process_started_at_unix_microseconds"
        case registeredAtUnixMilliseconds =
            "registered_at_unix_milliseconds"
    }

    var registeredAt: Date {
        Date(
            timeIntervalSince1970:
                TimeInterval(registeredAtUnixMilliseconds) / 1_000
        )
    }
}

private struct ManagedWineProcessEvidenceScopeProbe: Decodable {
    let schemaVersion: Int
    let producer: String
    let eventCode: String
    let runIdentifier: String
    let prefixScope: String
    let runtimeFingerprint: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case producer
        case eventCode = "event_code"
        case runIdentifier = "run_identifier"
        case prefixScope = "prefix_scope"
        case runtimeFingerprint = "runtime_fingerprint"
    }
}

private struct ManagedWineLegacyProcessEvidenceIdentityProbe: Decodable {
    let role: String
    let darwinPID: Int32
    let processStartedAtUnixMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case role
        case darwinPID = "darwin_pid"
        case processStartedAtUnixMicroseconds =
            "process_started_at_unix_microseconds"
    }
}

final class ManagedWineSessionRegistry: @unchecked Sendable {
    private static let maximumDirectoryEntryCount = 4_096
    private static let maximumDescriptorCount = 1_024
    private let lock = NSLock()
    private var prefixesByPath: [String: URL] = [:]
    private var launchSessionsByPrefixPath:
        [String: [String: ManagedWineProcessLaunchSession]] = [:]

    func record(_ prefix: URL) {
        let normalized = prefix.standardizedFileURL
        lock.withLock {
            prefixesByPath[normalized.path] = normalized
        }
    }

    var prefixURLs: [URL] {
        lock.withLock {
            prefixesByPath.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        }
    }

    func record(_ launchSession: ManagedWineProcessLaunchSession) {
        record([launchSession])
    }

    private func record(
        _ launchSessions: [ManagedWineProcessLaunchSession]
    ) {
        lock.withLock {
            for launchSession in launchSessions {
                let prefix = launchSession.prefixURL.standardizedFileURL
                prefixesByPath[prefix.path] = prefix
                var sessions = launchSessionsByPrefixPath[prefix.path] ?? [:]
                sessions[launchSession.runIdentifier] = launchSession
                launchSessionsByPrefixPath[prefix.path] = sessions
            }
        }
    }

    func launchSessions(for prefix: URL) -> [ManagedWineProcessLaunchSession] {
        let prefixPath = prefix.standardizedFileURL.path
        return lock.withLock {
            guard let sessions = launchSessionsByPrefixPath[prefixPath] else {
                return []
            }
            return sessions.values.sorted { $0.registeredAt < $1.registeredAt }
        }
    }

    func completeSessions(
        for prefix: URL
    ) -> [ManagedWineProcessLaunchSession] {
        let prefixPath = prefix.standardizedFileURL.path
        return lock.withLock {
            prefixesByPath.removeValue(forKey: prefixPath)
            guard let sessions = launchSessionsByPrefixPath.removeValue(
                forKey: prefixPath
            ) else {
                return []
            }
            return sessions.values.sorted {
                $0.registeredAt < $1.registeredAt
            }
        }
    }

    func removeLaunchSession(
        for prefix: URL,
        runIdentifier: String
    ) {
        let prefixPath = prefix.standardizedFileURL.path
        lock.withLock {
            guard var sessions = launchSessionsByPrefixPath[prefixPath] else {
                return
            }
            sessions.removeValue(forKey: runIdentifier)
            if sessions.isEmpty {
                launchSessionsByPrefixPath.removeValue(forKey: prefixPath)
                prefixesByPath.removeValue(forKey: prefixPath)
            } else {
                launchSessionsByPrefixPath[prefixPath] = sessions
            }
        }
    }

    /// Reconstructs launch ownership after an app restart from host-written
    /// descriptors only. Every accepted descriptor is bound to the selected
    /// prefix object and current curated Runtime root/fingerprint. A descriptor
    /// whose exact owner is still alive belongs to another app process and is
    /// rejected without registering any signal target.
    @discardableResult
    func hydrate(
        from directory: URL,
        trustedAncestor: URL,
        for prefix: URL,
        runtimeRootURL: URL,
        runtimeFingerprint: String,
        observedAt: Date = Date(),
        fileManager: FileManager = .default,
        validating validateSession: (
            ManagedWineProcessLaunchSession
        ) throws -> Void
    ) throws -> [ManagedWineProcessLaunchSession] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let normalizedDirectory = directory.standardizedFileURL
        let normalizedTrustedAncestor = trustedAncestor.standardizedFileURL
        let normalizedPrefix = prefix.standardizedFileURL
        let normalizedRuntimeRoot = runtimeRootURL.standardizedFileURL
        let expectedPrefixScope = ManagedWineProcessJournal.prefixScope(
            for: normalizedPrefix
        )
        let expectedPrefixIdentity = try ManagedWineProcessJournal
            .trustedPrefixIdentity(for: normalizedPrefix)
        let expectedRuntimeRootScope = ManagedWineProcessJournal
            .runtimeRootScope(for: normalizedRuntimeRoot)
        guard ManagedWineProcessJournal.isLowercaseSHA256(runtimeFingerprint) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalizedDirectory,
                "the selected Runtime fingerprint is invalid"
            )
        }

        var directoryStatus = stat()
        guard lstat(normalizedDirectory.path, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              (directoryStatus.st_mode & mode_t(0o077)) == 0,
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: normalizedTrustedAncestor,
                to: normalizedDirectory,
                fileManager: fileManager
              ) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalizedDirectory,
                "the managed Wine session directory is not owner-private"
            )
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: normalizedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalizedDirectory,
                "the managed Wine session directory could not be enumerated"
            )
        }

        var entryCount = 0
        var descriptorCount = 0
        var hydrated: [ManagedWineProcessLaunchSession] = []
        var descriptorRunIdentifiers = Set<String>()
        var evidenceURLsByRunIdentifier: [String: URL] = [:]
        let currentProcessIdentifier = Darwin.getpid()
        let currentProcessStartedAt = ManagedWineProcessJournal
            .processStartTimeUnixMicroseconds(for: currentProcessIdentifier)

        while let next = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= Self.maximumDirectoryEntryCount else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    normalizedDirectory,
                    "the managed Wine session scan exceeded its bounded entry count"
                )
            }
            if next.pathExtension == "jsonl",
               let runIdentifier = UUID(
                uuidString: next.deletingPathExtension().lastPathComponent
               )?.uuidString.lowercased(),
               next.lastPathComponent ==
                ManagedWineProcessJournal.evidenceFileName(
                    runIdentifier: runIdentifier
                ) {
                evidenceURLsByRunIdentifier[runIdentifier] =
                    next.standardizedFileURL
                continue
            }
            guard next.lastPathComponent.hasSuffix(
                ManagedWineProcessJournal.activeSessionDescriptorSuffix
            ) else {
                continue
            }
            descriptorCount += 1
            guard descriptorCount <= Self.maximumDescriptorCount else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    normalizedDirectory,
                    "the managed Wine session scan exceeded its bounded descriptor count"
                )
            }

            let descriptor = try ManagedWineProcessJournal
                .readActiveSessionDescriptor(at: next)
            guard descriptor.schemaVersion ==
                    ManagedWineActiveSessionDescriptor.currentSchemaVersion,
                  descriptor.producer ==
                    ManagedWineActiveSessionDescriptor.producer,
                  let normalizedRunIdentifier = UUID(
                    uuidString: descriptor.runIdentifier
                  )?.uuidString.lowercased(),
                  normalizedRunIdentifier == descriptor.runIdentifier,
                  next.lastPathComponent ==
                    ManagedWineProcessJournal.activeSessionDescriptorFileName(
                        runIdentifier: normalizedRunIdentifier
                    ),
                  descriptor.evidenceFileName ==
                    ManagedWineProcessJournal.evidenceFileName(
                        runIdentifier: normalizedRunIdentifier
                    ),
                  ManagedWineProcessJournal.isLowercaseSHA256(
                    descriptor.prefixScope
                  ),
                  ManagedWineProcessJournal.isLowercaseSHA256(
                    descriptor.runtimeFingerprint
                  ),
                  ManagedWineProcessJournal.isLowercaseSHA256(
                    descriptor.runtimeRootScope
                  ),
                  descriptor.ownerProcessIdentifier > 1,
                  descriptor.ownerProcessStartedAtUnixMicroseconds > 0,
                  descriptor.registeredAtUnixMilliseconds > 946_684_800_000,
                  descriptor.registeredAt <=
                    observedAt.addingTimeInterval(5) else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    next,
                    "the managed Wine active-session descriptor is invalid"
                )
            }
            descriptorRunIdentifiers.insert(normalizedRunIdentifier)

            // A valid descriptor for another prefix is not ownership for the
            // requested cleanup. Invalid descriptors are rejected above so an
            // attacker cannot hide ambiguity behind a foreign scope value.
            guard descriptor.prefixScope == expectedPrefixScope else { continue }
            guard descriptor.prefixIdentity == expectedPrefixIdentity,
                  descriptor.runtimeFingerprint == runtimeFingerprint,
                  descriptor.runtimeRootScope == expectedRuntimeRootScope else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    next,
                    "the active session does not match the selected prefix and Runtime identity"
                )
            }

            switch ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(
                    for: pid_t(descriptor.ownerProcessIdentifier)
                ) {
            case .live(let liveOwnerStartedAt):
                if liveOwnerStartedAt ==
                    descriptor.ownerProcessStartedAtUnixMicroseconds {
                    let isCurrentOwner = descriptor.ownerProcessIdentifier ==
                        currentProcessIdentifier &&
                        currentProcessStartedAt == liveOwnerStartedAt
                    guard isCurrentOwner else {
                        throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                            next,
                            "the active session is still owned by another live ForgePlay process"
                        )
                    }
                }
                // A different start identity proves PID reuse and therefore
                // proves that the descriptor's original owner has exited.
            case .exited:
                break
            case .unavailable:
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    next,
                    "the active-session owner death identity could not be verified"
                )
            }

            let evidenceURL = normalizedDirectory.appending(
                path: descriptor.evidenceFileName,
                directoryHint: .notDirectory
            )
            hydrated.append(ManagedWineProcessLaunchSession(
                prefixURL: normalizedPrefix,
                runIdentifier: normalizedRunIdentifier,
                evidenceURL: evidenceURL,
                descriptorURL: next.standardizedFileURL,
                runtimeRootURL: normalizedRuntimeRoot,
                runtimeFingerprint: runtimeFingerprint,
                prefixScope: expectedPrefixScope,
                registeredAt: descriptor.registeredAt
            ))
        }
        if let enumerationError {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalizedDirectory,
                "the managed Wine session scan failed: " +
                    forgePlayTechnicalErrorSummary(enumerationError)
            )
        }

        // A pre-descriptor ForgePlay build can leave a process journal behind
        // after its app owner exits. It is safe to ignore only recorded PID
        // identities that are now dead or have been reused. A still-live or
        // unreadable matching identity has no exact app owner, so fail closed
        // without adopting or signalling any of its PIDs.
        for (runIdentifier, evidenceURL) in evidenceURLsByRunIdentifier
        where !descriptorRunIdentifiers.contains(runIdentifier) {
            guard let data = try ManagedWineProcessJournal
                .readOwnerPrivateBoundedFile(
                    at: evidenceURL,
                    maximumBytes: ManagedWineProcessJournal
                        .maximumProcessEvidenceBytes,
                    purpose: "legacy managed Wine process"
                ),
                !data.isEmpty else {
                continue
            }
            let decoder = JSONDecoder()
            var containsUnownedLiveOrAmbiguousProcess = false
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard line.count <= 2_048,
                      let scope = try? decoder.decode(
                        ManagedWineProcessEvidenceScopeProbe.self,
                        from: Data(line)
                      ),
                      scope.schemaVersion == 1,
                      scope.producer == "forgeplay-wine-runtime",
                      scope.eventCode == "darwin_process_started",
                      scope.runIdentifier.lowercased() == runIdentifier,
                      scope.prefixScope == expectedPrefixScope,
                      scope.runtimeFingerprint == runtimeFingerprint else {
                    continue
                }
                guard let identity = try? decoder.decode(
                        ManagedWineLegacyProcessEvidenceIdentityProbe.self,
                        from: Data(line)
                      ),
                      ["wine-loader", "wineserver"].contains(identity.role),
                      identity.darwinPID > 1,
                      identity.processStartedAtUnixMicroseconds > 0 else {
                    containsUnownedLiveOrAmbiguousProcess = true
                    break
                }
                let recordedStart = UInt64(
                    identity.processStartedAtUnixMicroseconds
                )
                switch ManagedWineProcessJournal
                    .resolveProcessIdentityAcrossExitBoundary(
                        for: pid_t(identity.darwinPID)
                    ) {
                case .live(let liveStart):
                    if liveStart == recordedStart {
                        containsUnownedLiveOrAmbiguousProcess = true
                        break
                    }
                    continue
                case .exited:
                    continue
                case .unavailable:
                    containsUnownedLiveOrAmbiguousProcess = true
                    break
                }
            }
            guard !containsUnownedLiveOrAmbiguousProcess else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    evidenceURL,
                    "a live or ambiguous managed Wine journal predates exact owner-session descriptors"
                )
            }
        }

        // Validate every evidence PID/start/executable identity before making
        // any hydrated session visible to cleanup. One ambiguous session keeps
        // the entire scan fail-closed and yields no partial signal target set.
        for session in hydrated {
            try validateSession(session)
        }
        record(hydrated)
        return hydrated.sorted { $0.registeredAt < $1.registeredAt }
    }
}

enum ManagedWineProcessJournal {
    enum ProcessLivenessProbe: Equatable {
        case present
        case missing
        case unavailable
    }

    enum ProcessIdentityResolution: Equatable {
        case live(startedAtUnixMicroseconds: UInt64)
        case exited
        case unavailable
    }

    static let activeSessionDescriptorSuffix = ".session.json"
    private static let maximumActiveSessionDescriptorBytes: Int64 = 16 * 1024
    static let maximumProcessEvidenceBytes: Int64 = 4 * 1024 * 1024
    static let evidenceFileKey =
        "FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE"
    static let runIdentifierKey =
        "FORGEPLAY_MANAGED_WINE_PROCESS_RUN_ID"
    static let prefixScopeKey =
        "FORGEPLAY_MANAGED_WINE_PREFIX_SCOPE"
    static let runtimeFingerprintKey =
        "FORGEPLAY_MANAGED_WINE_RUNTIME_FINGERPRINT"
    static let applicationOwnerProcessIdentifierKey =
        "FORGEPLAY_MANAGED_APPLICATION_OWNER_PID"
    static let applicationOwnerStartTimeKey =
        "FORGEPLAY_MANAGED_APPLICATION_OWNER_START_US"
    static let evidenceDirectoryName = "ManagedWineProcessEvidence"

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func evidenceFileName(runIdentifier: String) -> String {
        "\(runIdentifier.lowercased()).jsonl"
    }

    static func activeSessionDescriptorFileName(
        runIdentifier: String
    ) -> String {
        "\(runIdentifier.lowercased())\(activeSessionDescriptorSuffix)"
    }

    static func activeSessionDescriptorURL(
        runIdentifier: String,
        evidenceDirectory: URL
    ) -> URL {
        evidenceDirectory.appending(
            path: activeSessionDescriptorFileName(
                runIdentifier: runIdentifier
            ),
            directoryHint: .notDirectory
        ).standardizedFileURL
    }

    static func prefixScope(for prefix: URL) -> String {
        let normalizedPath = prefix.standardizedFileURL.path
        let input = Data(
            ("forgeplay-managed-wine-prefix-v1\n" + normalizedPath)
                .utf8
        )
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func runtimeRootScope(for runtimeRoot: URL) -> String {
        let canonicalRoot = runtimeRoot.standardizedFileURL
            .resolvingSymlinksInPath().path
        let input = Data(
            ("forgeplay-managed-wine-runtime-root-v1\n" + canonicalRoot).utf8
        )
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func trustedPrefixIdentity(
        for prefix: URL
    ) throws -> ManagedWineTrustedPrefixIdentity {
        let normalized = prefix.standardizedFileURL
        var status = stat()
        guard lstat(normalized.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "the selected Wine prefix is not a stable directory object"
            )
        }
        return ManagedWineTrustedPrefixIdentity(
            deviceIdentifier: String(status.st_dev),
            inodeIdentifier: String(status.st_ino),
            ownerUserIdentifier: status.st_uid
        )
    }

    static func processStartTimeUnixMicroseconds(
        for pid: pid_t
    ) -> UInt64? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copiedSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                expectedSize
            )
        }
        guard copiedSize == expectedSize else { return nil }
        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        guard microseconds < 1_000_000,
              seconds <= (UInt64.max - microseconds) / 1_000_000 else {
            return nil
        }
        return seconds * 1_000_000 + microseconds
    }

    /// macOS has a short interval between process death and final reap where
    /// `proc_pidinfo` no longer publishes a start identity while `kill(pid, 0)`
    /// still reports the PID as present. Treat neither observation as proof of
    /// ownership. Re-probe that transition for a small, bounded period; a PID
    /// that remains unreadable still fails closed, and a reused PID returns its
    /// new start identity so callers can exclude it without signalling it.
    static func resolveProcessIdentityAcrossExitBoundary(
        for pid: pid_t
    ) -> ProcessIdentityResolution {
        resolveProcessIdentityAcrossExitBoundary(
            for: pid,
            retryCount: 4,
            retryInterval: 0.025,
            startTimeProvider: {
                processStartTimeUnixMicroseconds(for: $0)
            },
            livenessProvider: { processLiveness(for: $0) },
            wait: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    static func resolveProcessIdentityAcrossExitBoundary(
        for pid: pid_t,
        retryCount: Int,
        retryInterval: TimeInterval,
        startTimeProvider: (pid_t) -> UInt64?,
        livenessProvider: (pid_t) -> ProcessLivenessProbe,
        wait: (TimeInterval) -> Void
    ) -> ProcessIdentityResolution {
        let boundedRetryCount = max(0, retryCount)
        for attempt in 0...boundedRetryCount {
            if let startedAt = startTimeProvider(pid) {
                return .live(startedAtUnixMicroseconds: startedAt)
            }
            switch livenessProvider(pid) {
            case .missing:
                return .exited
            case .unavailable:
                return .unavailable
            case .present:
                guard attempt < boundedRetryCount else {
                    return .unavailable
                }
                wait(max(0, retryInterval))
            }
        }
        return .unavailable
    }

    static func isExactLiveProcessIdentity(
        _ resolution: ProcessIdentityResolution,
        expectedStartTimeUnixMicroseconds: UInt64
    ) -> Bool {
        guard case .live(let observedStartTimeUnixMicroseconds) = resolution
        else { return false }
        return observedStartTimeUnixMicroseconds ==
            expectedStartTimeUnixMicroseconds
    }

    private static func processLiveness(
        for pid: pid_t
    ) -> ProcessLivenessProbe {
        errno = 0
        let result = Darwin.kill(pid, 0)
        let errorCode = errno
        if result == 0 {
            return .present
        }
        if errorCode == ESRCH {
            return .missing
        }
        return .unavailable
    }

    static func makeActiveSessionDescriptor(
        runIdentifier: String,
        evidenceURL: URL,
        prefix: URL,
        runtimeRootURL: URL,
        runtimeFingerprint: String,
        ownerProcessIdentifier: pid_t,
        ownerProcessStartedAtUnixMicroseconds: UInt64,
        registeredAt: Date
    ) throws -> ManagedWineActiveSessionDescriptor {
        guard let normalizedRunIdentifier = UUID(uuidString: runIdentifier)?
                .uuidString.lowercased(),
              normalizedRunIdentifier == runIdentifier.lowercased(),
              evidenceURL.lastPathComponent == evidenceFileName(
                runIdentifier: normalizedRunIdentifier
              ),
              isLowercaseSHA256(runtimeFingerprint),
              ownerProcessIdentifier > 1,
              ownerProcessStartedAtUnixMicroseconds > 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(evidenceURL)
        }
        let registeredAtMilliseconds = registeredAt.timeIntervalSince1970 * 1_000
        guard registeredAtMilliseconds >= 946_684_800_000,
              registeredAtMilliseconds <= Double(Int64.max) else {
            throw SafeProcessRunnerError.cannotCreateLog(evidenceURL)
        }
        return ManagedWineActiveSessionDescriptor(
            schemaVersion: ManagedWineActiveSessionDescriptor
                .currentSchemaVersion,
            producer: ManagedWineActiveSessionDescriptor.producer,
            runIdentifier: normalizedRunIdentifier,
            evidenceFileName: evidenceURL.lastPathComponent,
            prefixScope: prefixScope(for: prefix),
            prefixIdentity: try trustedPrefixIdentity(for: prefix),
            runtimeFingerprint: runtimeFingerprint,
            runtimeRootScope: runtimeRootScope(for: runtimeRootURL),
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartedAtUnixMicroseconds:
                ownerProcessStartedAtUnixMicroseconds,
            registeredAtUnixMilliseconds: Int64(registeredAtMilliseconds)
        )
    }

    @discardableResult
    static func writeActiveSessionDescriptor(
        _ descriptor: ManagedWineActiveSessionDescriptor,
        in directory: URL
    ) throws -> URL {
        let normalizedDirectory = directory.standardizedFileURL
        let destination = activeSessionDescriptorURL(
            runIdentifier: descriptor.runIdentifier,
            evidenceDirectory: normalizedDirectory
        )
        var directoryStatus = stat()
        guard lstat(normalizedDirectory.path, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              (directoryStatus.st_mode & mode_t(0o077)) == 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(destination)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(descriptor)
        guard !data.isEmpty,
              data.count <= Int(maximumActiveSessionDescriptorBytes) else {
            throw SafeProcessRunnerError.cannotCreateLog(destination)
        }

        let temporary = normalizedDirectory.appending(
            path: ".\(descriptor.runIdentifier).\(UUID().uuidString.lowercased()).tmp",
            directoryHint: .notDirectory
        )
        var removeTemporary = true
        defer {
            if removeTemporary {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        let writableDescriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard writableDescriptor >= 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(temporary)
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(writableDescriptor) }
        }
        var status = stat()
        guard fstat(writableDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              (status.st_mode & mode_t(0o777)) ==
                (S_IRUSR | S_IWUSR) else {
            throw SafeProcessRunnerError.cannotCreateLog(temporary)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    writableDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw SafeProcessRunnerError.cannotCreateLog(temporary)
                }
            }
        }
        guard Darwin.fsync(writableDescriptor) == 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(temporary)
        }
        let closeResult = Darwin.close(writableDescriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(temporary)
        }

        let renameResult: Int32 = temporary.withUnsafeFileSystemRepresentation {
            sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(destination)
        }
        removeTemporary = false

        let directoryDescriptor = Darwin.open(
            normalizedDirectory.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw SafeProcessRunnerError.cannotCreateLog(destination)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0,
              try readActiveSessionDescriptor(at: destination) == descriptor else {
            throw SafeProcessRunnerError.cannotCreateLog(destination)
        }
        return destination
    }

    static func readActiveSessionDescriptor(
        at url: URL
    ) throws -> ManagedWineActiveSessionDescriptor {
        let normalized = url.standardizedFileURL
        let descriptor = Darwin.open(
            normalized.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "the active-session descriptor could not be opened"
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              (before.st_mode & mode_t(0o777)) ==
                (S_IRUSR | S_IWUSR),
              before.st_size > 0,
              before.st_size <= maximumActiveSessionDescriptorBytes else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "the active-session descriptor is not an owner-private bounded file"
            )
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remainingByteCount = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    remainingByteCount,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    normalized,
                    "the active-session descriptor read was incomplete"
                )
            }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              let decoded = try? JSONDecoder().decode(
                ManagedWineActiveSessionDescriptor.self,
                from: Data(bytes)
              ) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "the active-session descriptor changed during its bounded read"
            )
        }
        return decoded
    }

    static func readOwnerPrivateBoundedFile(
        at url: URL,
        maximumBytes: Int64,
        purpose: String
    ) throws -> Data? {
        let normalized = url.standardizedFileURL
        guard maximumBytes >= 0 else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "\(purpose) evidence has an invalid read bound"
            )
        }
        let descriptor = Darwin.open(
            normalized.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "\(purpose) evidence could not be opened: " +
                    String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(descriptor) }

        var acquiredStableReadLock = false
        for _ in 0..<100 {
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
                acquiredStableReadLock = true
                break
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard acquiredStableReadLock else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "\(purpose) evidence could not be locked within the bounded stable-read window"
            )
        }
        defer { flock(descriptor, LOCK_UN) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              (before.st_mode & mode_t(0o777)) ==
                (S_IRUSR | S_IWUSR),
              before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "\(purpose) evidence is not an owner-private bounded file"
            )
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remainingByteCount = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    remainingByteCount,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    normalized,
                    "\(purpose) evidence read was incomplete"
                )
            }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalized,
                "\(purpose) evidence changed during its bounded read"
            )
        }
        return Data(bytes)
    }

    static func evidenceFileURL(
        runIdentifier: String,
        fallbackDirectory: URL,
        fileManager: FileManager = .default,
        sandboxEnabled: Bool =
            ForgePlaySandboxPolicy.isAppSandboxEnabled
    ) throws -> URL {
        guard let normalizedRunIdentifier = UUID(uuidString: runIdentifier)?
            .uuidString.lowercased() else {
            throw SafeProcessRunnerError.cannotCreateLog(fallbackDirectory)
        }
        let fileName = "\(normalizedRunIdentifier).jsonl"
        guard sandboxEnabled else {
            return fallbackDirectory
                .appending(
                    path: fileName,
                    directoryHint: .notDirectory
                )
                .standardizedFileURL
        }
        guard let applicationGroupIdentifier =
                ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
              let groupContainer = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier:
                    applicationGroupIdentifier
              ) else {
            throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
        }
        let directory = groupContainer
            .appending(
                path: "Library/Application Support/ForgePlay",
                directoryHint: .isDirectory
            )
            .appending(
                path: evidenceDirectoryName,
                directoryHint: .isDirectory
            )
            .standardizedFileURL
        do {
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                directory,
                trustedAncestor: groupContainer,
                privateTailComponentCount: 1
            )
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                directory,
                fileManager: fileManager
            ) else {
                throw SafeProcessRunnerError.cannotCreateLog(directory)
            }
            return directory.appending(
                path: fileName,
                directoryHint: .notDirectory
            )
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(directory)
        }
    }
}

struct WineSynchronizationPolicy: Hashable, Sendable {
    var selection: WineSynchronizationSelection
    var backend: WineSynchronizationBackend

    static let automaticServer = WineSynchronizationPolicy(
        selection: .automatic,
        backend: .server
    )

    static func isConsistent(
        selection: WineSynchronizationSelection,
        backend: WineSynchronizationBackend
    ) -> Bool {
        selection == .automatic && backend == .server
    }

    var isConsistent: Bool {
        Self.isConsistent(selection: selection, backend: backend)
    }
}

struct WineSynchronizationRuntimeCapabilities: Hashable, Sendable {
    var supportedBackends: Set<WineSynchronizationBackend>

    func supports(_ backend: WineSynchronizationBackend) -> Bool {
        supportedBackends.contains(backend)
    }

    var preferredAutomaticBackend: WineSynchronizationBackend {
        .server
    }
}

enum WindowsRegistryView: String, Sendable, Hashable {
    case bit32 = "32"
    case bit64 = "64"
}

enum SteamClientServiceMaintenanceOperation: Sendable, Hashable {
    case install
    case query

    var actionName: String {
        switch self {
        case .install:
            "installSteamClientService"
        case .query:
            "querySteamClientService"
        }
    }

    var logName: String {
        switch self {
        case .install:
            "steam_client_service_install"
        case .query:
            "steam_client_service_query"
        }
    }
}

enum RunnerAction: Sendable, Hashable {
    case initializePrefix(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case migratePrefixRuntime(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case waitForWinePrefix(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case probeRuntime(executable: URL, logDirectory: URL)
    case installSteam(runtimeExecutable: URL, prefix: URL, installer: URL, logDirectory: URL)
    case maintainSteamClientService(
        runtimeExecutable: URL,
        prefix: URL,
        operation: SteamClientServiceMaintenanceOperation,
        logDirectory: URL
    )
    case requestSteamClientShutdown(runtimeExecutable: URL, prefix: URL, steamExecutable: URL, logDirectory: URL)
    case shutdownWinePrefix(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case launchSteam(
        runtimeExecutable: URL,
        prefix: URL,
        steamExecutable: URL,
        steamArguments: [String],
        graphicsBackend: SteamRendererPolicyPreference?,
        compatibilitySelection: SteamPrelaunchCompatibilitySelection? = nil,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        logDirectory: URL,
        externalStorageRoots: [URL] = []
    )
    case launchWindowsUtility(
        runtimeExecutable: URL,
        prefix: URL,
        executable: URL,
        arguments: [String] = [],
        graphicsBackend: SteamRendererPolicyPreference? = nil,
        logDirectory: URL,
        externalStorageRoots: [URL] = []
    )
    case extractRuntimeArchive(runtimeExecutable: URL, prefix: URL, archive: URL, extractionDirectory: URL, runtime: RuntimeId, logDirectory: URL)
    case installRuntime(runtimeExecutable: URL, prefix: URL, installer: URL, runtime: RuntimeId, logDirectory: URL)
    case setWindowsVersion(runtimeExecutable: URL, prefix: URL, version: String, logDirectory: URL)
    case setRegistryValue(runtimeExecutable: URL, prefix: URL, registryPath: String, valueName: String, valueType: String?, value: String, registryView: WindowsRegistryView? = nil, logDirectory: URL)
    case deleteRegistryValue(runtimeExecutable: URL, prefix: URL, registryPath: String, valueName: String, registryView: WindowsRegistryView? = nil, logDirectory: URL)
    case deleteRegistryValueIfPresent(runtimeExecutable: URL, prefix: URL, registryPath: String, valueName: String, logDirectory: URL)
    case setDLLOverride(runtimeExecutable: URL, prefix: URL, dll: String, override: String, logDirectory: URL)
    case setAppDLLOverride(runtimeExecutable: URL, prefix: URL, appExecutable: String, dll: String, override: String, logDirectory: URL)
    case deleteAppDLLOverrideIfPresent(runtimeExecutable: URL, prefix: URL, appExecutable: String, dll: String, logDirectory: URL)
    case createSupportArchive(sourceDirectory: URL, destinationZip: URL, logDirectory: URL)
}

extension RunnerAction {
    var diagnosticLogDirectoryURL: URL {
        switch self {
        case .initializePrefix(_, _, let logDirectory),
             .migratePrefixRuntime(_, _, let logDirectory),
             .waitForWinePrefix(_, _, let logDirectory),
             .probeRuntime(_, let logDirectory),
             .installSteam(_, _, _, let logDirectory),
             .maintainSteamClientService(_, _, _, let logDirectory),
             .requestSteamClientShutdown(_, _, _, let logDirectory),
             .shutdownWinePrefix(_, _, let logDirectory),
             .launchSteam(_, _, _, _, _, _, _, let logDirectory, _),
             .launchWindowsUtility(_, _, _, _, _, let logDirectory, _),
             .extractRuntimeArchive(_, _, _, _, _, let logDirectory),
             .installRuntime(_, _, _, _, let logDirectory),
             .setWindowsVersion(_, _, _, let logDirectory),
             .setRegistryValue(_, _, _, _, _, _, _, let logDirectory),
             .deleteRegistryValue(_, _, _, _, _, let logDirectory),
             .deleteRegistryValueIfPresent(_, _, _, _, let logDirectory),
             .setDLLOverride(_, _, _, _, let logDirectory),
             .setAppDLLOverride(_, _, _, _, _, let logDirectory),
             .deleteAppDLLOverrideIfPresent(_, _, _, _, let logDirectory),
             .createSupportArchive(_, _, let logDirectory):
            logDirectory
        }
    }

    var detachedProcessPrefixURL: URL? {
        switch self {
        case .initializePrefix(_, let prefix, _),
             .migratePrefixRuntime(_, let prefix, _),
             .waitForWinePrefix(_, let prefix, _),
             .installSteam(_, let prefix, _, _),
             .maintainSteamClientService(_, let prefix, _, _),
             .requestSteamClientShutdown(_, let prefix, _, _),
             .shutdownWinePrefix(_, let prefix, _),
             .launchSteam(_, let prefix, _, _, _, _, _, _, _),
             .launchWindowsUtility(_, let prefix, _, _, _, _, _),
             .extractRuntimeArchive(_, let prefix, _, _, _, _),
             .installRuntime(_, let prefix, _, _, _),
             .setWindowsVersion(_, let prefix, _, _),
             .setRegistryValue(_, let prefix, _, _, _, _, _, _),
             .deleteRegistryValue(_, let prefix, _, _, _, _),
             .deleteRegistryValueIfPresent(_, let prefix, _, _, _),
             .setDLLOverride(_, let prefix, _, _, _),
             .setAppDLLOverride(_, let prefix, _, _, _, _),
             .deleteAppDLLOverrideIfPresent(_, let prefix, _, _, _):
            return prefix.standardizedFileURL
        case .probeRuntime, .createSupportArchive:
            return nil
        }
    }

    var windowsRuntimeExecutableURL: URL? {
        switch self {
        case .initializePrefix(let runtimeExecutable, _, _),
             .migratePrefixRuntime(let runtimeExecutable, _, _),
             .waitForWinePrefix(let runtimeExecutable, _, _),
             .installSteam(let runtimeExecutable, _, _, _),
             .maintainSteamClientService(let runtimeExecutable, _, _, _),
             .requestSteamClientShutdown(let runtimeExecutable, _, _, _),
             .shutdownWinePrefix(let runtimeExecutable, _, _),
             .launchSteam(let runtimeExecutable, _, _, _, _, _, _, _, _),
             .launchWindowsUtility(let runtimeExecutable, _, _, _, _, _, _),
             .extractRuntimeArchive(let runtimeExecutable, _, _, _, _, _),
             .installRuntime(let runtimeExecutable, _, _, _, _),
             .setWindowsVersion(let runtimeExecutable, _, _, _),
             .setRegistryValue(let runtimeExecutable, _, _, _, _, _, _, _),
             .deleteRegistryValue(let runtimeExecutable, _, _, _, _, _),
             .deleteRegistryValueIfPresent(let runtimeExecutable, _, _, _, _),
             .setDLLOverride(let runtimeExecutable, _, _, _, _),
             .setAppDLLOverride(let runtimeExecutable, _, _, _, _, _),
             .deleteAppDLLOverrideIfPresent(let runtimeExecutable, _, _, _, _):
            runtimeExecutable
        case .probeRuntime(let executable, _):
            executable
        case .createSupportArchive:
            nil
        }
    }

    var requiresWindowsRuntime: Bool {
        switch self {
        case .createSupportArchive:
            false
        case .initializePrefix,
             .migratePrefixRuntime,
             .waitForWinePrefix,
             .probeRuntime,
             .installSteam,
             .maintainSteamClientService,
             .requestSteamClientShutdown,
             .shutdownWinePrefix,
             .launchSteam,
             .launchWindowsUtility,
             .extractRuntimeArchive,
             .installRuntime,
             .setWindowsVersion,
             .setRegistryValue,
             .deleteRegistryValue,
             .deleteRegistryValueIfPresent,
             .setDLLOverride,
             .setAppDLLOverride,
             .deleteAppDLLOverrideIfPresent:
            true
        }
    }

    var requiresManagedWineProcessJournal: Bool {
        switch self {
        case .waitForWinePrefix,
             .probeRuntime,
             .shutdownWinePrefix,
             .createSupportArchive:
            false
        case .initializePrefix,
             .migratePrefixRuntime,
             .installSteam,
             .maintainSteamClientService,
             .requestSteamClientShutdown,
             .launchSteam,
             .launchWindowsUtility,
             .extractRuntimeArchive,
             .installRuntime,
             .setWindowsVersion,
             .setRegistryValue,
             .deleteRegistryValue,
             .deleteRegistryValueIfPresent,
             .setDLLOverride,
             .setAppDLLOverride,
             .deleteAppDLLOverrideIfPresent:
            true
        }
    }

    /// Only an active Steam launch turns child-environment readback into a
    /// provider admission receipt. Prefix initialization and maintenance still
    /// journal every managed Wine process for cleanup, but must not fail merely
    /// because their short-lived launcher has already handed off and exited.
    var requiresManagedWineChildSynchronizationReadback: Bool {
        if case .launchSteam = self { return true }
        return false
    }

    var capabilityActionName: String {
        switch self {
        case .initializePrefix:
            "initializePrefix"
        case .migratePrefixRuntime:
            "migratePrefixRuntime"
        case .waitForWinePrefix:
            "waitForWinePrefix"
        case .probeRuntime:
            "probeRuntime"
        case .installSteam:
            "installSteam"
        case .maintainSteamClientService(_, _, let operation, _):
            operation.actionName
        case .requestSteamClientShutdown:
            "requestSteamClientShutdown"
        case .shutdownWinePrefix:
            "shutdownWinePrefix"
        case .launchSteam:
            "launchSteam"
        case .launchWindowsUtility:
            "launchWindowsUtility"
        case .extractRuntimeArchive:
            "extractRuntimeArchive"
        case .installRuntime:
            "installRuntime"
        case .setWindowsVersion:
            "setWindowsVersion"
        case .setRegistryValue:
            "setRegistryValue"
        case .deleteRegistryValue:
            "deleteRegistryValue"
        case .deleteRegistryValueIfPresent:
            "deleteRegistryValueIfPresent"
        case .setDLLOverride:
            "setDLLOverride"
        case .setAppDLLOverride:
            "setAppDLLOverride"
        case .deleteAppDLLOverrideIfPresent:
            "deleteAppDLLOverrideIfPresent"
        case .createSupportArchive:
            "createSupportArchive"
        }
    }
}

enum ForgePlayRuntimeCapabilityError: LocalizedError, ForgePlayTechnicalDescribingError, Sendable {
    case bundledRuntimeUnavailable(actionName: String)
    case nonBundledRuntimeRejected(actionName: String, path: String)
    case bundledRuntimeIdentityIncomplete(actionName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .bundledRuntimeUnavailable(let actionName):
            "앱에 포함된 ForgePlay Runtime을 사용할 수 없습니다: \(actionName)"
        case .nonBundledRuntimeRejected(let actionName, let path):
            "ForgePlay는 앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용합니다: \(actionName), \(path)"
        case .bundledRuntimeIdentityIncomplete(let actionName, let reason):
            "앱에 포함된 ForgePlay Runtime의 핵심 모듈 무결성을 확인할 수 없습니다: \(actionName). \(reason)"
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .bundledRuntimeUnavailable(let actionName):
            "bundled ForgePlay Runtime is unavailable: action=\(actionName)"
        case .nonBundledRuntimeRejected(let actionName, let path):
            "non-bundled Windows runtime rejected: action=\(actionName), path=\(path)"
        case .bundledRuntimeIdentityIncomplete(let actionName, let reason):
            "bundled ForgePlay Runtime identity is incomplete: action=\(actionName), reason=\(reason)"
        }
    }
}

@MainActor
@Observable
final class BundledRuntimeAuthenticationViewState {
    enum Phase: Equatable, Sendable {
        case idle
        case authenticating
        case available
        case failed
    }

    static let shared = BundledRuntimeAuthenticationViewState()

    private(set) var phaseByExecutable: [String: Phase] = [:]
    @ObservationIgnored
    private var requestedExecutables = Set<String>()
    @ObservationIgnored
    private var failedAttemptCountByExecutable: [String: Int] = [:]

    func beginAuthenticationIfNeeded(for executable: URL) {
        let normalized = executable.standardizedFileURL
        let key = normalized.path
        switch phaseByExecutable[key] ?? .idle {
        case .available, .authenticating:
            return
        case .idle:
            break
        case .failed:
            guard (failedAttemptCountByExecutable[key] ?? 0) < 3 else {
                return
            }
        }
        guard requestedExecutables.insert(key).inserted else { return }
        phaseByExecutable[key] = .authenticating
        Task { [weak self] in
            do {
                _ = try await ForgePlayRuntimeCapabilityPolicy
                    .authenticatedBundledRuntimeContext(
                        executable: normalized,
                        actionName: "runtimeCapability"
                    )
                self?.failedAttemptCountByExecutable.removeValue(forKey: key)
                self?.phaseByExecutable[key] = .available
            } catch {
                guard let self else { return }
                let attempts = (self.failedAttemptCountByExecutable[key] ?? 0) + 1
                self.failedAttemptCountByExecutable[key] = attempts
                self.phaseByExecutable[key] = .failed
                // Retry only transient first-use failures, with a strict bound
                // to avoid repeated whole-runtime hashing for a damaged app.
                guard attempts < 3 else {
                    self.requestedExecutables.remove(key)
                    return
                }
                let delay: Duration = attempts == 1
                    ? .seconds(1)
                    : .seconds(5)
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled,
                      self.phaseByExecutable[key] == .failed else {
                    return
                }
                self.requestedExecutables.remove(key)
                self.phaseByExecutable[key] = .idle
                self.beginAuthenticationIfNeeded(for: normalized)
            }
        }
    }

    func publishAuthenticated(_ executable: URL) {
        let key = executable.standardizedFileURL.path
        requestedExecutables.insert(key)
        failedAttemptCountByExecutable.removeValue(forKey: key)
        phaseByExecutable[key] = .available
    }

    func canRun(_ executable: URL) -> Bool {
        phase(for: executable) == .available
    }

    func phase(for executable: URL) -> Phase {
        phaseByExecutable[executable.standardizedFileURL.path] ?? .idle
    }

    func invalidate(_ executable: URL) {
        let key = executable.standardizedFileURL.path
        requestedExecutables.remove(key)
        failedAttemptCountByExecutable.removeValue(forKey: key)
        phaseByExecutable[key] = .idle
    }
}

enum ForgePlayRuntimeCapabilityPolicy {
    private static let legacyIdentityCleanupActions: Set<String> = [
        "shutdownWinePrefix"
    ]

    static var canImportAppleSupplementalRenderer: Bool {
        true
    }

    static func allowsLegacyIdentityForCleanup(
        actionName: String,
        schemaVersion: Int
    ) -> Bool {
        legacyIdentityCleanupActions.contains(actionName) &&
            schemaVersion >= 2 &&
            schemaVersion < RuntimeManifest.currentSchemaVersion
    }

    static var bundledWindowsRuntimeExecutableURL: URL? {
        ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL()
    }

    @MainActor
    static var canRunBundledWindowsRuntime: Bool {
        guard let executable = bundledWindowsRuntimeExecutableURL else {
            return false
        }
        let state = BundledRuntimeAuthenticationViewState.shared
        state.beginAuthenticationIfNeeded(for: executable)
        return state.canRun(executable)
    }

    @MainActor
    static var unavailableReasonKey: String {
        guard let executable = bundledWindowsRuntimeExecutableURL else {
            return "앱에 포함된 ForgePlay Runtime을 찾을 수 없습니다. Runtime이 온전히 포함된 ForgePlay 빌드를 다시 설치하세요."
        }
        switch BundledRuntimeAuthenticationViewState.shared.phase(
            for: executable
        ) {
        case .idle, .authenticating:
            return "앱에 포함된 ForgePlay Runtime을 확인하는 중입니다. 잠시 후 다시 시도하세요."
        case .available:
            return "앱에 포함된 ForgePlay Runtime을 사용할 수 있습니다."
        case .failed:
            return "앱에 포함된 ForgePlay Runtime을 사용할 수 없습니다. Runtime이 온전히 포함된 ForgePlay 빌드를 다시 설치하세요."
        }
    }

    static var supplementalRendererImportDetailKey: String {
        "실행 엔진은 항상 앱에 포함된 ForgePlay Runtime입니다. 필요한 경우 Apple 공식 Evaluation environment의 D3DMetal 보조 렌더러만 가져올 수 있습니다."
    }

    static var runtimeUpdateGuidanceKey: String {
        "앱에 포함된 ForgePlay Runtime은 앱 업데이트로만 교체됩니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
    }

    static func validateBundledWindowsRuntime(
        executable: URL,
        actionName: String
    ) throws {
        guard ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(executable) else {
            throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                actionName: actionName,
                path: executable.path
            )
        }
        do {
            let manifest = try RuntimeManifestResolver().manifest(for: executable)
            try validateAuthenticatedManifest(
                manifest,
                actionName: actionName
            )
        } catch let error as ForgePlayRuntimeCapabilityError {
            throw error
        } catch {
            throw ForgePlayRuntimeCapabilityError.bundledRuntimeIdentityIncomplete(
                actionName: actionName,
                reason: forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    static func authenticatedBundledRuntimeContext(
        executable: URL,
        actionName: String
    ) async throws -> RuntimeAuthenticatedContext {
        guard ForgePlayBundledWindowsRuntimePolicy
            .isBundledRuntimeExecutable(executable) else {
            throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                actionName: actionName,
                path: executable.path
            )
        }
        do {
            let context = try await RuntimeAuthenticationCache.shared
                .authenticatedContext(for: executable)
            try validateAuthenticatedManifest(
                context.manifest,
                actionName: actionName
            )
            return context
        } catch let error as ForgePlayRuntimeCapabilityError {
            throw error
        } catch {
            throw ForgePlayRuntimeCapabilityError
                .bundledRuntimeIdentityIncomplete(
                    actionName: actionName,
                    reason: forgePlayTechnicalErrorSummary(error)
                )
        }
    }

    private static func validateAuthenticatedManifest(
        _ manifest: RuntimeManifest,
        actionName: String
    ) throws {
        // Cleanup must remain available when an app update raises the
        // launch/runtime identity schema. Otherwise an older, still bundled
        // Wine environment cannot be stopped before storage activation or app
        // termination. This exception is limited to the fixed wineserver
        // shutdown action; launching anything still requires current identity.
        if allowsLegacyIdentityForCleanup(
            actionName: actionName,
            schemaVersion: manifest.schemaVersion
        ) {
            return
        }
        guard manifest.schemaVersion == RuntimeManifest.currentSchemaVersion,
              manifest.corePayloadFingerprintState == "verified",
              manifest.identityIssues?.isEmpty == true else {
            throw ForgePlayRuntimeCapabilityError
                .bundledRuntimeIdentityIncomplete(
                    actionName: actionName,
                    reason: manifest.identityIssues?
                        .joined(separator: " | ") ??
                        "runtime manifest schema \(manifest.schemaVersion) is not release-current"
                )
        }
    }

    @MainActor
    static func validateBundledWindowsRuntimeAvailability(actionName: String) throws {
        guard canRunBundledWindowsRuntime else {
            throw ForgePlayRuntimeCapabilityError.bundledRuntimeUnavailable(
                actionName: actionName
            )
        }
    }
}

enum SafeProcessRunnerError: LocalizedError, ForgePlayTechnicalDescribingError {
    case executableMissing(URL)
    case unsafeExecutable(URL)
    case unsafeActionInput(URL)
    case unsafeCommandArgument(String)
    case unsafeArchivePath(URL)
    case cannotCreateLog(URL)
    case metadataReadFailed(URL, String)
    case runnerLibrarySearchFailed(URL, Error)
    case prefixProcessVerificationFailed(URL, String)
    case manualRendererSelectionRequired
    case invalidSteamCompatibilitySelection
    case gameRendererPayloadMissing(URL, String)
    case gameRendererBridgePreparationFailed(URL, String)
    case invalidPrefixSynchronizationProfile(URL)
    case sandboxIPCConfigurationMissing
    case unsafeWineServerRoot(URL, String)
    case invalidRosettaAVXHostOverride(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let url):
            "실행 파일을 찾을 수 없습니다: \(url.path)"
        case .unsafeExecutable(let url):
            "실행 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: \(url.path)"
        case .unsafeActionInput(let url):
            "실행 입력 경로가 안전한 일반 파일/폴더가 아닙니다: \(url.path)"
        case .unsafeCommandArgument(let name):
            "Windows 명령 입력에 허용되지 않은 문자가 있습니다: \(name)"
        case .unsafeArchivePath(let url):
            "압축 파일 경로가 안전한 일반 경로가 아닙니다: \(url.path)"
        case .cannotCreateLog(let url):
            "로그 파일을 만들 수 없습니다: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "실행 입력 경로 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .runnerLibrarySearchFailed(let url, let error):
            "ForgePlay Runtime의 라이브러리 경로를 검사하지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .prefixProcessVerificationFailed(let url, let message):
            "ForgePlay Runtime 프로세스 정리 상태를 확인하지 못했습니다: \(url.path). \(message)"
        case .manualRendererSelectionRequired:
            "Steam을 실행하기 전에 D3DMetal 표준, D3DMetal NVIDIA, DXMT, D9VK 또는 DXVK 중 하나를 직접 선택해야 합니다."
        case .invalidSteamCompatibilitySelection:
            "선택한 그래픽 백엔드와 Steam 실행 호환성 설정이 일치하지 않습니다."
        case .gameRendererPayloadMissing(let url, let architecture):
            "선택한 게임 렌더러의 \(architecture) DLL payload를 찾지 못했습니다: \(url.path)"
        case .gameRendererBridgePreparationFailed(let url, let reason):
            "D3DMetal MetalFX/NGX 브리지를 준비하지 못했습니다: \(url.path). \(reason)"
        case .invalidPrefixSynchronizationProfile(let url):
            "Steam 프리픽스의 Wine 동기화 설정을 읽을 수 없습니다: \(url.path)"
        case .sandboxIPCConfigurationMissing:
            "샌드박스 배포 앱의 ForgePlay Runtime IPC 구성이 없습니다. App Group이 포함된 앱을 다시 설치하세요."
        case .unsafeWineServerRoot(let url, let reason):
            "Wine 서버 경로를 안전하게 준비하지 못했습니다: \(url.path). \(reason)"
        case .invalidRosettaAVXHostOverride:
            "Rosetta AVX 설정 값이 올바르지 않습니다. FORGEPLAY_ROSETTA_ADVERTISE_AVX에는 0 또는 1만 사용하세요."
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .invalidRosettaAVXHostOverride(let value):
            let sanitizedValue = value.utf8.prefix(64).map { byte -> String in
                switch byte {
                case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                    String(decoding: [byte], as: UTF8.self)
                default:
                    String(format: "%%%02X", byte)
                }
            }.joined()
            return "SafeProcessRunnerError case=invalidRosettaAVXHostOverride " +
                "category=host-environment value=\(sanitizedValue) " +
                "key=\(ManagedWineRosettaAVXPolicyV1.hostOverrideKey)"
        default:
            return errorDescription ?? "ForgePlay Runtime process error"
        }
    }
}

struct SteamExternalStorageGrantPreparationError:
    LocalizedError,
    ForgePlayTechnicalDescribingError,
    Sendable
{
    let reasonCode: String
    let requiredForManagedChild: Bool

    var errorDescription: String? {
        "Windows용 Steam 실행에 필요한 외장 저장소 접근 권한을 준비하지 못했습니다. ForgePlay에서 저장공간을 다시 연결한 뒤 다시 실행하세요."
    }

    var forgePlayTechnicalDescription: String {
        "SteamExternalStorageGrantPreparationError " +
            "reason=\(reasonCode) managed-child=\(requiredForManagedChild)"
    }
}

enum DescriptorBoundProcessGroupMemberPolicy {
    enum MemberState: Equatable {
        case active
        case exitedOrZombie
        case indeterminate(Int32)
    }

    enum Presence: Equatable {
        case present
        case absent
        case indeterminate(Int32)

        var diagnosticDescription: String {
            switch self {
            case .present:
                "present"
            case .absent:
                "absent"
            case .indeterminate(let errorCode):
                "indeterminate(errno=\(errorCode))"
            }
        }
    }

    struct EnumerationResult {
        let returnedCount: Int
        let processIDs: [pid_t]
        let errorCode: Int32?
    }

    static func isActiveBSDProcessStatus(_ status: UInt32) -> Bool {
        status != UInt32(SZOMB)
    }

    /// Enumerates the complete process group with count-sized storage plus
    /// growth slack. `proc_listpgrppids` reports PID *count*, while its buffer
    /// argument is bytes. A saturated or concurrently grown snapshot is
    /// retried; continued churn remains indeterminate so cleanup cannot miss a
    /// live or unreadable member at the end of a truncated buffer.
    static func presence(
        rootProcessIdentifier: pid_t,
        rootPIDReuseBarrierRetired: Bool = false,
        maximumEnumerationAttempts: Int = 4,
        countProvider: () -> (count: Int, errorCode: Int32?),
        enumerationProvider: (_ capacity: Int) -> EnumerationResult,
        memberStateProvider: (_ processIdentifier: pid_t) -> MemberState
    ) -> Presence {
        // Reaping is allowed only after this exact root reached terminal state
        // and its owned process group was proven absent. The numeric PID/PGID
        // can be reused after that point, so never probe or signal it again.
        if rootPIDReuseBarrierRetired { return .absent }

        let growthSlack = 16
        let attempts = max(maximumEnumerationAttempts, 1)
        var minimumCapacity = 1

        for _ in 0..<attempts {
            let before = countProvider()
            guard before.errorCode == nil else {
                return .indeterminate(before.errorCode ?? EIO)
            }
            if before.count == 0 { return .absent }
            guard before.count > 0 else { return .indeterminate(EIO) }
            let requested = before.count.addingReportingOverflow(growthSlack)
            guard !requested.overflow else {
                return .indeterminate(EOVERFLOW)
            }
            let capacity = max(minimumCapacity, requested.partialValue)
            guard capacity > 0 else { return .indeterminate(EOVERFLOW) }

            let enumeration = enumerationProvider(capacity)
            guard enumeration.errorCode == nil,
                  enumeration.returnedCount >= 0,
                  enumeration.returnedCount <= capacity,
                  enumeration.returnedCount <= enumeration.processIDs.count else {
                return .indeterminate(enumeration.errorCode ?? EOVERFLOW)
            }
            if enumeration.returnedCount == 0 { return .absent }

            if enumeration.returnedCount == capacity {
                let doubled = capacity.multipliedReportingOverflow(by: 2)
                guard !doubled.overflow else {
                    return .indeterminate(EOVERFLOW)
                }
                minimumCapacity = doubled.partialValue
                continue
            }

            let after = countProvider()
            guard after.errorCode == nil else {
                return .indeterminate(after.errorCode ?? EIO)
            }
            if after.count == 0 { return .absent }
            guard after.count > 0 else { return .indeterminate(EIO) }
            let required = after.count.addingReportingOverflow(
                growthSlack
            )
            guard !required.overflow else {
                return .indeterminate(EOVERFLOW)
            }
            if required.partialValue > capacity {
                let doubled = capacity.multipliedReportingOverflow(by: 2)
                guard !doubled.overflow else {
                    return .indeterminate(EOVERFLOW)
                }
                minimumCapacity = max(
                    required.partialValue,
                    doubled.partialValue
                )
                continue
            }

            let snapshotRows = Array(
                enumeration.processIDs.prefix(enumeration.returnedCount)
            )
            guard snapshotRows.allSatisfy({ $0 > 0 }),
                  Set(snapshotRows).count == snapshotRows.count else {
                return .indeterminate(EIO)
            }
            var indeterminateError: Int32?
            for memberProcessIdentifier in snapshotRows
            where memberProcessIdentifier != rootProcessIdentifier {
                switch memberStateProvider(memberProcessIdentifier) {
                case .active:
                    return .present
                case .exitedOrZombie:
                    continue
                case .indeterminate(let errorCode):
                    indeterminateError = indeterminateError ?? errorCode
                }
            }
            if let indeterminateError {
                return .indeterminate(indeterminateError)
            }

            // Every member in the first snapshot is now proven exited or a
            // zombie, so none of those exact processes can fork. Re-enumerate
            // only after that proof and require the exact PID set to remain
            // unchanged. This closes the race where a formerly live member
            // forks, exits, and becomes a zombie after the earlier count
            // probe while its new child was absent from the first snapshot.
            let confirmation = enumerationProvider(capacity)
            guard confirmation.errorCode == nil,
                  confirmation.returnedCount >= 0,
                  confirmation.returnedCount <= capacity,
                  confirmation.returnedCount <=
                    confirmation.processIDs.count else {
                return .indeterminate(
                    confirmation.errorCode ?? EOVERFLOW
                )
            }
            if confirmation.returnedCount == 0 { return .absent }
            if confirmation.returnedCount == capacity {
                let doubled = capacity.multipliedReportingOverflow(by: 2)
                guard !doubled.overflow else {
                    return .indeterminate(EOVERFLOW)
                }
                minimumCapacity = doubled.partialValue
                continue
            }
            let confirmationRows = Array(
                confirmation.processIDs.prefix(
                    confirmation.returnedCount
                )
            )
            guard confirmationRows.allSatisfy({ $0 > 0 }),
                  Set(confirmationRows).count ==
                    confirmationRows.count else {
                return .indeterminate(EIO)
            }
            guard Set(confirmationRows) == Set(snapshotRows) else {
                continue
            }
            return .absent
        }
        return .indeterminate(EOVERFLOW)
    }
}

private final class DescriptorBoundSpawnedProcess: @unchecked Sendable {
    private typealias ProcessGroupMemberState =
        DescriptorBoundProcessGroupMemberPolicy.MemberState
    typealias ProcessGroupPresence =
        DescriptorBoundProcessGroupMemberPolicy.Presence

    let processIdentifier: pid_t
    private let stateLock = NSLock()
    private var storedWaitStatus: Int32?
    private var storedWaitError: Int32?
    private var storedReapError: Int32?
    private var rootWaitObservation:
        DescriptorBoundRootWaitObservation = .awaitingTerminalState
    private var rootWasReaped = false
    private var reapInProgress = false

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        Thread.detachNewThread { [self] in
            var information = siginfo_t()
            while true {
                let result = waitid(
                    P_PID,
                    id_t(processIdentifier),
                    &information,
                    WEXITED | WNOWAIT
                )
                if result == 0 {
                    stateLock.withLock {
                        rootWaitObservation = .terminalStateObserved
                    }
                    return
                }
                if result < 0, errno == EINTR { continue }
                let errorCode = result < 0 ? errno : ECHILD
                stateLock.withLock {
                    storedWaitError = errorCode
                    rootWaitObservation = .failed(errorCode)
                }
                return
            }
        }
    }

    var isRunning: Bool {
        stateLock.withLock {
            !rootWaitObservation.successfullyObservedTerminalState
        }
    }

    /// `waitid(..., WNOWAIT)` has observed terminal state for the spawned
    /// root, but the root may still be deliberately retained as a zombie so
    /// its PID cannot be reused while descendants remain in the owned process
    /// group.
    var rootExitWasObserved: Bool {
        stateLock.withLock {
            rootWaitObservation.successfullyObservedTerminalState
        }
    }

    var waitObservation: DescriptorBoundRootWaitObservation {
        stateLock.withLock { rootWaitObservation }
    }

    /// Reaping is a separate lifecycle transition from observing root exit.
    /// Diagnostics and journal validation must not infer this value from
    /// `isRunning`.
    var rootWasActuallyReaped: Bool {
        stateLock.withLock { rootWasReaped }
    }

    var hasObservedUnreapedRootExit: Bool {
        stateLock.withLock {
            SafeProcessRunner
                .descriptorRootRetainsUnreapedIdentityBarrier(
                    rootWaitObservation: rootWaitObservation,
                    rootWasActuallyReaped: rootWasReaped,
                    rootReapError: storedReapError,
                    reapInProgress: reapInProgress
                )
        }
    }

    var waitStatus: Int32? {
        stateLock.withLock { storedWaitStatus }
    }

    var waitError: Int32? {
        stateLock.withLock {
            storedReapError ?? storedWaitError ??
                rootWaitObservation.errorCode
        }
    }

    private var rootPIDReuseBarrierRetired: Bool {
        stateLock.withLock {
            rootWaitObservation.successfullyObservedTerminalState &&
                (rootWasReaped || storedReapError != nil)
        }
    }

    var terminationSignal: Int32? {
        guard let waitStatus else { return nil }
        let signal = waitStatus & 0x7f
        return signal == 0 ? nil : signal
    }

    var processExitCode: Int32? {
        guard let waitStatus, terminationSignal == nil else { return nil }
        return (waitStatus >> 8) & 0xff
    }

    /// `EPERM` proves that the group still exists even when this process may
    /// not signal every member. Any other unexpected probe failure is kept as
    /// indeterminate ownership rather than being treated as absence.
    var processGroupPresence: ProcessGroupPresence {
        if isRunning { return .present }
        return DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: processIdentifier,
            rootPIDReuseBarrierRetired: rootPIDReuseBarrierRetired,
            countProvider: {
                errno = 0
                let count = proc_listpgrppids(
                    self.processIdentifier,
                    nil,
                    0
                )
                let errorCode = errno
                return (
                    Int(count),
                    count < 0 || (count == 0 && errorCode != 0)
                        ? errorCode
                        : nil
                )
            },
            enumerationProvider: { capacity in
                let stride = MemoryLayout<pid_t>.stride
                let byteCount = capacity.multipliedReportingOverflow(
                    by: stride
                )
                guard !byteCount.overflow,
                      byteCount.partialValue <= Int(Int32.max) else {
                    return DescriptorBoundProcessGroupMemberPolicy
                        .EnumerationResult(
                            returnedCount: -1,
                            processIDs: [],
                            errorCode: EOVERFLOW
                        )
                }
                var processIDs = [pid_t](
                    repeating: 0,
                    count: capacity
                )
                errno = 0
                let count = processIDs.withUnsafeMutableBytes { bytes in
                    proc_listpgrppids(
                        self.processIdentifier,
                        bytes.baseAddress,
                        Int32(bytes.count)
                    )
                }
                let errorCode = errno
                return DescriptorBoundProcessGroupMemberPolicy
                    .EnumerationResult(
                        returnedCount: Int(count),
                        processIDs: processIDs,
                        errorCode:
                            count < 0 || (count == 0 && errorCode != 0)
                                ? errorCode
                                : nil
                    )
            },
            memberStateProvider: Self.processGroupMemberState
        )
    }

    /// A process-group row that contains only exited zombies is not active
    /// descendant ownership. A live-but-unreadable member remains
    /// indeterminate so cleanup never treats inspection denial as absence.
    private static func processGroupMemberState(
        _ processIdentifier: pid_t
    ) -> ProcessGroupMemberState {
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copiedSize = withUnsafeMutablePointer(to: &information) {
            pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                expectedSize
            )
        }
        if copiedSize == expectedSize {
            return DescriptorBoundProcessGroupMemberPolicy
                .isActiveBSDProcessStatus(information.pbi_status)
                ? .active
                : .exitedOrZombie
        }
        if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
            return .exitedOrZombie
        }
        let errorCode = errno
        return .indeterminate(errorCode == 0 ? EIO : errorCode)
    }

    var hasTrackedOwnership: Bool {
        if isRunning { return true }
        switch processGroupPresence {
        case .present, .indeterminate(_):
            return true
        case .absent:
            _ = reapRootIfExited()
            return false
        }
    }

    @discardableResult
    func reapRootIfExited() -> Bool {
        var alreadyReaped = false
        let shouldReap = stateLock.withLock { () -> Bool in
            guard rootWaitObservation
                .successfullyObservedTerminalState else { return false }
            if rootWasReaped {
                alreadyReaped = true
                return false
            }
            guard !reapInProgress else { return false }
            reapInProgress = true
            return true
        }
        if alreadyReaped { return true }
        guard shouldReap else {
            return stateLock.withLock { rootWasReaped }
        }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR
        stateLock.withLock {
            if result == processIdentifier {
                storedWaitStatus = status
                rootWasReaped = true
            } else {
                storedReapError = result < 0 ? errno : ECHILD
            }
            reapInProgress = false
        }
        return result == processIdentifier
    }

    deinit {
        _ = reapRootIfExited()
    }
}

actor SafeProcessRunner {
    typealias RuntimeAuthenticationContextProvider = @Sendable (
        _ executable: URL,
        _ actionName: String
    ) async throws -> RuntimeAuthenticatedContext
    typealias WindowsRuntimeValidator = @Sendable (_ executable: URL, _ actionName: String) throws -> Void
    typealias RuntimeLaunchObjectIdentityProvider =
        @Sendable (_ executable: URL) throws -> RuntimeLaunchObjectIdentity?
    typealias ManagedWineRuntimeFingerprintResolver =
        @Sendable (_ executable: URL) throws -> String
    typealias ManagedWineRosettaAVXPolicySnapshotProvider =
        @Sendable () throws -> ManagedWineRosettaAVXPolicyV1
    typealias ManagedWineChildSynchronizationReadbackProvider =
        @Sendable (_ processIdentifier: Int32) throws ->
        ManagedWineChildSynchronizationReadback
    typealias ExternalStorageGrantPublisher = @Sendable (
        _ roots: [URL],
        _ prefix: URL,
        _ runIdentifier: String
    ) throws -> SteamExternalStorageProcessGrant
    typealias GameModeSteamChildSelectionResolver = @Sendable (
        _ runtimeExecutable: URL,
        _ prefix: URL,
        _ evidenceLogURL: URL,
        _ runIdentifier: String
    ) throws -> GameModeSteamChildHostSelection
    typealias GameModeHostApplicationGroupContainerResolver = @Sendable (
        _ applicationGroupIdentifier: String
    ) -> URL?

    private struct TrackedDetachedProcess {
        let process: Process
        let prefixPath: String
        let signalCapability: ManagedProcessSignalTarget?
        let identityCaptureFailure: String?
    }

    private struct TrackedDescriptorBoundProcess {
        let process: DescriptorBoundSpawnedProcess
        let prefixPath: String?
        let signalCapability: ManagedProcessSignalTarget?
        let identityCaptureFailure: String?
    }

    private struct VerifiedManagedWineSignalIdentity {
        let prefixPath: String
        let processStartedAtUnixMicroseconds: UInt64
        let executableURL: URL
    }

    private struct ManagedWineProcessValidationResult {
        let processIDs: [pid_t]
        let inactiveReasons: [String]
    }

    private struct ExcludedReusedManagedWineSignalIdentity {
        let prefixPath: String
        let processStartedAtUnixMicroseconds: UInt64
    }

    private struct GameModeHostLaunchRecord: Hashable, Sendable {
        let prefixPath: String
        let runIdentifier: String
        let evidenceURL: URL
        let executableURL: URL
        let registeredAt: Date
    }

    private struct GameModeHostEvidenceRecord: Decodable {
        let schemaVersion: Int
        let producer: String
        let eventCode: String
        let recordedAtUnixMilliseconds: Int64
        let darwinPID: Int32
        let processStartedAtUnixMicroseconds: UInt64?
        let runIdentifier: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case producer
            case eventCode = "event_code"
            case recordedAtUnixMilliseconds = "recorded_at_unix_milliseconds"
            case darwinPID = "darwin_pid"
            case processStartedAtUnixMicroseconds =
                "process_started_at_unix_microseconds"
            case runIdentifier = "run_identifier"
        }
    }

    private struct GameModeHostEvidenceProcessIdentity: Hashable, Sendable {
        let processID: pid_t
        let processStartedAtUnixMicroseconds: UInt64?
        let recordedAt: Date
    }

    private struct ManagedProcessLiveObstruction: Sendable, Hashable {
        let processID: pid_t?
        let reason: String
    }

    private struct ManagedPrefixProcessInspection: Sendable, Hashable {
        var signalCapabilities: [ManagedProcessSignalTarget]
        var liveObstructions: [ManagedProcessLiveObstruction]

        var isClean: Bool {
            signalCapabilities.isEmpty && liveObstructions.isEmpty
        }

        var obstructionSummary: String {
            liveObstructions.map { obstruction in
                obstruction.processID.map {
                    "PID \($0): \(obstruction.reason)"
                } ?? obstruction.reason
            }.joined(separator: "; ")
        }
    }

    private struct ManagedWineProcessEvidenceRecord: Decodable {
        let schemaVersion: Int
        let producer: String
        let eventCode: String
        let role: String
        let runIdentifier: String
        let prefixScope: String
        let runtimeFingerprint: String
        let darwinPID: Int32
        let recordedAtUnixMilliseconds: Int64
        let processStartedAtUnixMicroseconds: Int64

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case producer
            case eventCode = "event_code"
            case role
            case runIdentifier = "run_identifier"
            case prefixScope = "prefix_scope"
            case runtimeFingerprint = "runtime_fingerprint"
            case darwinPID = "darwin_pid"
            case recordedAtUnixMilliseconds = "recorded_at_unix_milliseconds"
            case processStartedAtUnixMicroseconds =
                "process_started_at_unix_microseconds"
        }
    }

    private struct ManagedWineProcessEvidenceIdentity: Hashable, Sendable {
        let processID: pid_t
        let processStartedAtUnixMicroseconds: UInt64
    }

    private let fileManager: FileManager
    private let sandboxEnabled: Bool
    private let managedWineProcessJournalEnabled: Bool
    private let managedWineProcessEvidenceSandboxEnabled: Bool
    private let windowsRuntimeValidator: WindowsRuntimeValidator
    private let runtimeAuthenticationContextProvider:
        RuntimeAuthenticationContextProvider?
    private let runtimeLaunchObjectIdentityProvider:
        RuntimeLaunchObjectIdentityProvider
    private let managedWineRuntimeFingerprintResolver:
        ManagedWineRuntimeFingerprintResolver
    private let managedWineRosettaAVXPolicySnapshotProvider:
        ManagedWineRosettaAVXPolicySnapshotProvider
    private let managedWineChildSynchronizationReadbackProvider:
        ManagedWineChildSynchronizationReadbackProvider
    private let supplementalRendererAuthenticator:
        any AppleSupplementalRendererAuthenticating
    private let externalStorageGrantPublisher:
        ExternalStorageGrantPublisher
    private let gameModeHostApplicationGroupIdentifier: String?
    private let gameModeHostApplicationGroupContainerResolver:
        GameModeHostApplicationGroupContainerResolver?
    private let gameModeSteamChildSelectionResolver:
        GameModeSteamChildSelectionResolver
    private let managedWineSessionRegistry: ManagedWineSessionRegistry
    nonisolated let synchronousProcessCancellationScope =
        BoundedProcessCancellationScope()
    private var trackedDetachedProcesses: [pid_t: TrackedDetachedProcess] = [:]
    private var trackedDescriptorBoundProcesses:
        [pid_t: TrackedDescriptorBoundProcess] = [:]
    private var verifiedManagedWineSignalIdentities:
        [pid_t: VerifiedManagedWineSignalIdentity] = [:]
    private var excludedReusedManagedWineSignalIdentities:
        [pid_t: ExcludedReusedManagedWineSignalIdentity] = [:]
    private var gameModeHostLaunchRecords: Set<GameModeHostLaunchRecord> = []

    init(
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        managedWineProcessJournalEnabled: Bool = true,
        managedWineProcessEvidenceSandboxEnabled: Bool? = nil,
        managedWineSessionRegistry: ManagedWineSessionRegistry =
            ManagedWineSessionRegistry(),
        externalStorageGrantPublisher:
            @escaping ExternalStorageGrantPublisher = {
                roots,
                prefix,
                runIdentifier in
                try SteamExternalStorageProcessGrantPublisher().publish(
                    roots: roots,
                    prefix: prefix,
                    runIdentifier: runIdentifier
                )
            },
        gameModeHostApplicationGroupIdentifier: String? =
            ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
        gameModeHostApplicationGroupContainerResolver:
            GameModeHostApplicationGroupContainerResolver? = nil,
        gameModeSteamChildSelectionResolver:
            @escaping GameModeSteamChildSelectionResolver = {
                runtimeExecutable,
                prefix,
                evidenceLogURL,
                runIdentifier in
                try GameModeHostCapabilityInspector()
                    .inspectSteamChildSelection(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        evidenceLogURL: evidenceLogURL,
                        runIdentifier: runIdentifier
                    )
            },
        managedWineRuntimeFingerprintResolver:
            ManagedWineRuntimeFingerprintResolver? = nil,
        managedWineRosettaAVXPolicySnapshotProvider:
            @escaping ManagedWineRosettaAVXPolicySnapshotProvider = {
                try ManagedWineRosettaAVXPolicyV1.snapshot()
            },
        runtimeLaunchObjectIdentityProvider:
            RuntimeLaunchObjectIdentityProvider? = nil,
        managedWineChildSynchronizationReadbackProvider:
            ManagedWineChildSynchronizationReadbackProvider? = nil,
        windowsRuntimeValidator: WindowsRuntimeValidator? = nil,
        runtimeAuthenticationContextProvider:
            RuntimeAuthenticationContextProvider? = nil,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) {
        self.fileManager = fileManager
        self.sandboxEnabled = sandboxEnabled
        self.managedWineProcessJournalEnabled =
            managedWineProcessJournalEnabled
        self.managedWineProcessEvidenceSandboxEnabled =
            managedWineProcessEvidenceSandboxEnabled ?? sandboxEnabled
        self.managedWineSessionRegistry = managedWineSessionRegistry
        self.externalStorageGrantPublisher =
            externalStorageGrantPublisher
        self.gameModeHostApplicationGroupIdentifier =
            gameModeHostApplicationGroupIdentifier
        self.gameModeHostApplicationGroupContainerResolver =
            gameModeHostApplicationGroupContainerResolver
        self.gameModeSteamChildSelectionResolver =
            gameModeSteamChildSelectionResolver
        self.managedWineRuntimeFingerprintResolver =
            managedWineRuntimeFingerprintResolver ?? { executable in
                try RuntimeManifestResolver()
                    .manifest(for: executable)
                    .runnerBuildFingerprint
            }
        self.managedWineRosettaAVXPolicySnapshotProvider =
            managedWineRosettaAVXPolicySnapshotProvider
        self.managedWineChildSynchronizationReadbackProvider =
            managedWineChildSynchronizationReadbackProvider ?? { processIdentifier in
                try Self.managedWineChildSynchronizationReadback(
                    processIdentifier: processIdentifier
                )
            }
        self.supplementalRendererAuthenticator =
            supplementalRendererAuthenticator
        self.runtimeLaunchObjectIdentityProvider =
            runtimeLaunchObjectIdentityProvider ?? { executable in
                try RuntimeManifestResolver()
                    .launchObjectIdentity(for: executable)
            }
        self.windowsRuntimeValidator = windowsRuntimeValidator ?? {
            executable,
            actionName in
            try ForgePlayRuntimeCapabilityPolicy.validateBundledWindowsRuntime(
                executable: executable,
                actionName: actionName
            )
        }
        let usesLegacyAuthenticationSeams =
            windowsRuntimeValidator != nil ||
            runtimeLaunchObjectIdentityProvider != nil ||
            managedWineRuntimeFingerprintResolver != nil
        if let runtimeAuthenticationContextProvider {
            self.runtimeAuthenticationContextProvider =
                runtimeAuthenticationContextProvider
        } else if usesLegacyAuthenticationSeams {
            self.runtimeAuthenticationContextProvider = nil
        } else {
            self.runtimeAuthenticationContextProvider = {
                executable,
                actionName in
                try await ForgePlayRuntimeCapabilityPolicy
                    .authenticatedBundledRuntimeContext(
                        executable: executable,
                        actionName: actionName
                    )
            }
        }
    }

    func run(_ action: RunnerAction) async throws -> ProcessRunResult {
        try Task.checkCancellation()
        let attemptStartedAt = Date()
        let spec: CommandSpec
        var runtimeAuthenticationContext: RuntimeAuthenticatedContext?
        do {
            if action.requiresWindowsRuntime {
                guard let executable = action.windowsRuntimeExecutableURL else {
                    throw ForgePlayRuntimeCapabilityError.bundledRuntimeUnavailable(
                        actionName: action.capabilityActionName
                    )
                }
                if let runtimeAuthenticationContextProvider {
                    runtimeAuthenticationContext = try await
                        runtimeAuthenticationContextProvider(
                            executable,
                            action.capabilityActionName
                        )
                } else {
                    try windowsRuntimeValidator(
                        executable,
                        action.capabilityActionName
                    )
                }
                try requireExecutableFile(executable)
                guard fileManager.isExecutableFile(atPath: executable.path) else {
                    throw SafeProcessRunnerError.executableMissing(executable)
                }
            }
            try Task.checkCancellation()
            try validateActionInputs(for: action)
            if managedWineProcessJournalEnabled,
               case .shutdownWinePrefix(
                    let runtimeExecutable,
                    let prefix,
                    let logDirectory
               ) = action {
                try hydrateManagedWineSessions(
                    for: prefix,
                    runtimeExecutable: runtimeExecutable,
                    logDirectory: logDirectory,
                    runtimeFingerprint: runtimeAuthenticationContext?
                        .manifest.runnerBuildFingerprint
                )
            }
            var preparedSpec = try commandSpec(for: action)
            if action.requiresWindowsRuntime {
                preparedSpec = try attachingRuntimeLaunchObjectIdentity(
                    to: preparedSpec,
                    authenticatedContext: runtimeAuthenticationContext
                )
            }
            if managedWineProcessJournalEnabled,
               action.requiresManagedWineProcessJournal,
               let prefix = action.detachedProcessPrefixURL,
               let runtimeExecutable =
                action.windowsRuntimeExecutableURL {
                preparedSpec = try attachingManagedWineProcessJournal(
                    to: preparedSpec,
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: action.diagnosticLogDirectoryURL,
                    runtimeFingerprint: runtimeAuthenticationContext?
                        .manifest.runnerBuildFingerprint
                )
            }
            preparedSpec.runtimeCompatibility.merge(
                Self.runtimeCompatibilityDiagnostics(
                    from: preparedSpec.environment
                ),
                uniquingKeysWith: { preparedValue, _ in preparedValue }
            )
            spec = preparedSpec
            registerGameModeHostLaunch(
                from: spec,
                prefix: action.detachedProcessPrefixURL,
                registeredAt: attemptStartedAt
            )
        } catch {
            if let result = persistActionPreparationFailureEvidence(
                action: action,
                startedAt: attemptStartedAt,
                error: error
            ) {
                throw ProcessExecutionEvidenceError(underlyingError: error, result: result)
            }
            throw error
        }
        pruneTrackedDetachedProcesses()
        let cancellationIdentifier =
            synchronousProcessCancellationScope.beginOperation()
        defer {
            synchronousProcessCancellationScope.endOperation(
                cancellationIdentifier
            )
        }
        var result: ProcessRunResult
        do {
            result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try run(
                    spec,
                    detachedProcessPrefix: action.detachedProcessPrefixURL
                )
            } onCancel: { [synchronousProcessCancellationScope] in
                _ = synchronousProcessCancellationScope
                    .requestCancellation()
            }
            result.managedWineLaunchEnvironmentProjection =
                Self.managedWineLaunchEnvironmentProjection(
                    from: Self.processEnvironment(overrides: spec.environment)
                )
            result.managedWineRosettaAVXPolicy =
                spec.managedWineRosettaAVXPolicy
            if action.requiresManagedWineChildSynchronizationReadback,
               !result.waitedForExit,
               let processIdentifier = result.processIdentifier {
                do {
                    let readback = try await
                        managedWineChildSynchronizationReadback(
                            primaryProcessIdentifier: processIdentifier,
                            spec: spec
                        )
                    result.managedWineChildSynchronizationReadback = readback
                    // An exited detach helper is not the active provider
                    // transport. Project the exact same-session live loader
                    // selected below so Steam's PID-bound application receipt
                    // remains tied to the process whose environment was
                    // actually read.
                    result.processIdentifier = readback.processIdentifier
                } catch {
                    result = reconcileManagedWineReadbackFailure(
                        result,
                        spec: spec,
                        error: error
                    )
                    result = Self.applyingPreparationDiagnostics(
                        from: spec,
                        to: result
                    )
                    registerManagedWineProcessLaunch(
                        from: spec,
                        prefix: action.detachedProcessPrefixURL,
                        registeredAt: attemptStartedAt,
                        result: result
                    )
                    let persisted = persistProcessEvidence(
                        result,
                        spec: spec
                    )
                    throw ProcessExecutionEvidenceError(
                        underlyingError: error,
                        result: persisted
                    )
                }
            }
            result = Self.applyingPreparationDiagnostics(
                from: spec,
                to: result
            )
            registerManagedWineProcessLaunch(
                from: spec,
                prefix: action.detachedProcessPrefixURL,
                registeredAt: attemptStartedAt,
                result: result
            )
        } catch let evidenceError as ProcessExecutionEvidenceError {
            throw evidenceError
        } catch {
            let failureResult = persistSpawnFailureEvidence(
                spec: spec,
                startedAt: attemptStartedAt,
                error: error
            )
            if let failureResult {
                // A launcher can fail its parent-side startup gate after Wine
                // already created detached children. Preserve the journal
                // session whenever that failure still produced runtime
                // evidence so application termination cannot lose ownership
                // of those children.
                registerManagedWineProcessLaunch(
                    from: spec,
                    prefix: action.detachedProcessPrefixURL,
                    registeredAt: attemptStartedAt,
                    result: failureResult
                )
            }
            discardUnstartedManagedWineSessionArtifacts(from: spec)
            if let failureResult {
                throw ProcessExecutionEvidenceError(underlyingError: error, result: failureResult)
            }
            throw error
        }
        switch action {
        case .shutdownWinePrefix(let runtimeExecutable, let prefix, let logDirectory):
            do {
                result = try completeWinePrefixShutdown(
                    after: result,
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory,
                    runtimeAuthenticationContext:
                        runtimeAuthenticationContext
                )
            } catch {
                // Preserve the primary attempt and link any secondary-command
                // evidence when a barrier or recovery command could not start.
                var failedShutdown = result
                if let secondaryFailure = diagnosticProcessRunResult(from: error),
                   let secondaryEvidence = secondaryFailure.runEvidenceLog {
                    failedShutdown.relatedRunEvidenceLogs.append(secondaryEvidence)
                }
                failedShutdown.relatedRunEvidenceLogs = Self.deduplicated(
                    failedShutdown.relatedRunEvidenceLogs.map(\.standardizedFileURL)
                )
                failedShutdown.postconditionSatisfied = false
                let warning =
                    "Wine prefix shutdown verification could not complete: " +
                    forgePlayTechnicalErrorSummary(error)
                failedShutdown.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    failedShutdown.diagnosticCaptureWarning,
                    warning
                )
                _ = appendDiagnosticLines(
                    ["", "[ForgePlay] \(warning)"],
                    to: failedShutdown.stderrLog
                )
                let persisted = persistProcessEvidence(failedShutdown, spec: spec)
                throw ProcessExecutionEvidenceError(
                    underlyingError: error,
                    result: persisted
                )
            }
        default:
            break
        }
        return persistProcessEvidence(result, spec: spec)
    }

    /// Requests cancellation of only the synchronous child operation this
    /// runner currently owns. The waiting execution path retains the exact
    /// process-group identity and performs the signal/reap sequence itself.
    /// This is nonisolated so application termination can make progress while
    /// the actor is synchronously waiting for that child.
    @discardableResult
    nonisolated func requestCancellationOfActiveSynchronousProcess() -> Bool {
        synchronousProcessCancellationScope.requestCancellation()
    }

    private nonisolated static func applyingPreparationDiagnostics(
        from spec: CommandSpec,
        to input: ProcessRunResult
    ) -> ProcessRunResult {
        var result = input
        result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
            result.diagnosticCaptureWarning,
            spec.preparationDiagnosticWarning
        )
        result.userFacingWarningLocalizationKey =
            spec.userFacingWarningLocalizationKey ??
            result.userFacingWarningLocalizationKey
        return result
    }

    /// Rewrites the primary process sidecar after the owning operation has
    /// attached its final policy status, diagnostics, warnings, and related
    /// process evidence. The replacement is atomic and identity-checked so a
    /// stale or substituted sidecar can never be updated in place.
    func finalizeProcessEvidence(
        _ input: ProcessRunResult,
        finalizedAt: Date = Date()
    ) -> ProcessRunResult {
        var result = input
        guard let evidenceURL = result.runEvidenceLog else { return result }

        let expectedURL = ProcessRunEvidenceWriter.evidenceURL(for: result.stderrLog)
            .standardizedFileURL
        guard evidenceURL.standardizedFileURL == expectedURL else {
            return processEvidenceFinalizationFailure(
                result,
                error: ProcessRunEvidenceWriterError.invalidEvidenceIdentity(evidenceURL)
            )
        }

        do {
            var document = try ProcessRunEvidenceWriter.read(
                from: expectedURL,
                fileManager: fileManager
            )
            let expectedRunIdentifier = ProcessRunEvidenceWriter.runIdentifier(
                for: result.stderrLog
            )
            guard ProcessRunEvidenceDocument.readableSchemaVersions.contains(document.schemaVersion),
                  document.runIdentifier.lowercased() == expectedRunIdentifier.lowercased(),
                  URL(fileURLWithPath: document.stderrLog).standardizedFileURL ==
                    result.stderrLog.standardizedFileURL else {
                throw ProcessRunEvidenceWriterError.invalidEvidenceIdentity(expectedURL)
            }

            document.schemaVersion = ProcessRunEvidenceDocument.schemaVersion
            document.finalizedAt = finalizedAt
            document.activityLeaseExpiresAt = Self.evidenceActivityLeaseExpiration(
                for: result,
                relativeTo: finalizedAt
            )
            document.endedAt = result.endedAt
            document.durationMilliseconds = Int64(
                max(0, result.endedAt.timeIntervalSince(result.startedAt) * 1_000)
            )
            document.outcome = result.outcome
            document.exitCode = result.processExitCode
            document.forgePlayStatusCode = result.forgePlayStatusCode
            document.relatedRunEvidenceLogs = result.relatedRunEvidenceLogs.map {
                $0.standardizedFileURL.path
            }
            document.terminationSignal = result.terminationSignal
            document.rawWaitStatus = result.rawWaitStatus
            document.didTimeOut = result.didTimeOut
            document.waitedForExit = result.waitedForExit
            document.processIdentifier = result.processIdentifier
            document.stdoutLog = result.stdoutLog.standardizedFileURL.path
            document.stderrLog = result.stderrLog.standardizedFileURL.path
            document.processObservationLog = result.processObservationLog?
                .standardizedFileURL.path
            document.diagnosticLog = result.diagnosticLog?.standardizedFileURL.path
            document.evidenceCaptureWarning = result.evidenceCaptureWarning
            document.diagnosticCaptureWarning = result.diagnosticCaptureWarning
            document.postconditionSatisfied = result.postconditionSatisfied
            try ProcessRunEvidenceWriter.write(
                document,
                to: expectedURL,
                fileManager: fileManager
            )
            result.runEvidenceLog = expectedURL
        } catch {
            result = processEvidenceFinalizationFailure(result, error: error)
        }
        return result
    }

    func hasManagedPrefixActivity(_ prefix: URL) throws -> Bool {
        return try !managedPrefixActivityProcessIDs(under: prefix).isEmpty
    }

    /// Returns only live Darwin process identifiers owned by the exact
    /// managed Wine launch session. This is a read-only lifecycle proof for
    /// callers that must correlate an operating-system snapshot with the
    /// current launch without trusting a process name or command line alone.
    /// The existing journal validator rechecks the run identifier, prefix and
    /// Runtime scopes, kernel start identity, and curated executable identity
    /// on every call.
    func verifiedManagedWineProcessIdentities(
        under prefix: URL,
        runIdentifier: String
    ) throws -> Set<ManagedWineLaunchProcessIdentity> {
        guard let normalizedRunIdentifier = UUID(uuidString: runIdentifier)?
            .uuidString.lowercased(),
              normalizedRunIdentifier == runIdentifier.lowercased() else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                prefix,
                "the managed Wine launch run identifier is invalid"
            )
        }
        let matchingSessions = managedWineSessionRegistry
            .launchSessions(for: prefix)
            .filter { $0.runIdentifier == normalizedRunIdentifier }
        guard matchingSessions.count == 1,
              let launchSession = matchingSessions.first else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                prefix,
                "the exact managed Wine launch session is unavailable"
            )
        }
        let processIDs = try validatedManagedWineProcessIDs(
            for: launchSession
        )
        return try Set(processIDs.map { processID in
            guard let verified = verifiedManagedWineSignalIdentities[
                processID
            ], verified.prefixPath == prefix.standardizedFileURL.path else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    prefix,
                    "validated managed Wine PID \(processID) has no retained exact process identity"
                )
            }
            return ManagedWineLaunchProcessIdentity(
                processID: processID,
                processStartedAtUnixMicroseconds:
                    verified.processStartedAtUnixMicroseconds,
                executableURL: verified.executableURL
            )
        })
    }

    /// Reads the live provider environment from the spawned root while that
    /// root is still active. If `waitid(..., WNOWAIT)` has instead observed an
    /// exact descriptor-bound helper exit while descendant ownership remains,
    /// the root no longer has readable `KERN_PROCARGS2` state. In that case,
    /// select a live Wine loader only from this command's exact journal session
    /// and bind the readback to that loader PID.
    private func managedWineChildSynchronizationReadback(
        primaryProcessIdentifier: pid_t,
        spec: CommandSpec
    ) async throws -> ManagedWineChildSynchronizationReadback {
        guard primaryProcessIdentifier > 1 else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                URL(
                    fileURLWithPath:
                        "/proc/\(primaryProcessIdentifier)/environment"
                )
            )
        }

        guard let tracked = trackedDescriptorBoundProcesses[
            primaryProcessIdentifier
        ] else {
            return try requireManagedWineChildSynchronizationReadback(
                for: primaryProcessIdentifier
            )
        }

        if !Self.descriptorRootRequiresSameSessionReadback(
            rootWaitObservation: tracked.process.waitObservation,
            rootWasActuallyReaped: tracked.process.rootWasActuallyReaped
        ) {
            do {
                return try requireManagedWineChildSynchronizationReadback(
                    for: primaryProcessIdentifier
                )
            } catch {
                let directReadbackError = error
                // The KERN_PROCARGS2 failure and the WNOWAIT observer can race
                // by a few scheduler ticks. Wait only long enough to determine
                // whether this exact tracked root entered terminal state. The
                // root may already be reaped after group absence was proven;
                // either terminal state requires the same-session loader
                // handoff. A still-live unreadable root remains fail-closed.
                for _ in 0..<4
                where !Self.descriptorRootRequiresSameSessionReadback(
                    rootWaitObservation: tracked.process.waitObservation,
                    rootWasActuallyReaped:
                        tracked.process.rootWasActuallyReaped
                ) {
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard Self.descriptorRootRequiresSameSessionReadback(
                    rootWaitObservation: tracked.process.waitObservation,
                    rootWasActuallyReaped:
                        tracked.process.rootWasActuallyReaped
                ) else {
                    throw directReadbackError
                }
            }
        }

        guard let launchSession = spec.managedWineLaunchSession,
              tracked.prefixPath ==
                launchSession.prefixURL.standardizedFileURL.path else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                spec.stderrLog,
                "the exited managed Wine helper has no exact launch-session evidence"
            )
        }
        return try await sameSessionManagedWineLoaderReadback(
            for: launchSession,
            primaryProcessIdentifier: primaryProcessIdentifier
        )
    }

    nonisolated static func descriptorRootRequiresSameSessionReadback(
        rootWaitObservation: DescriptorBoundRootWaitObservation,
        rootWasActuallyReaped: Bool
    ) -> Bool {
        switch (
            rootWaitObservation.successfullyObservedTerminalState,
            rootWasActuallyReaped
        ) {
        case (true, false), (true, true):
            true
        case (false, false), (false, true):
            false
        }
    }

    nonisolated static func descriptorRootRetainsUnreapedIdentityBarrier(
        rootWaitObservation: DescriptorBoundRootWaitObservation,
        rootWasActuallyReaped: Bool,
        rootReapError: Int32?,
        reapInProgress: Bool
    ) -> Bool {
        rootWaitObservation.successfullyObservedTerminalState &&
            !rootWasActuallyReaped && rootReapError == nil &&
            !reapInProgress
    }

    private func requireManagedWineChildSynchronizationReadback(
        for processIdentifier: pid_t
    ) throws -> ManagedWineChildSynchronizationReadback {
        let readback = try managedWineChildSynchronizationReadbackProvider(
            processIdentifier
        )
        guard readback.processIdentifier == processIdentifier else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                URL(
                    fileURLWithPath:
                        "/proc/\(processIdentifier)/environment"
                )
            )
        }
        return readback
    }

    func sameSessionManagedWineLoaderReadback(
        for launchSession: ManagedWineProcessLaunchSession,
        primaryProcessIdentifier: pid_t,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05
    ) async throws -> ManagedWineChildSynchronizationReadback {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var lastError: (any Error)?
        repeat {
            let prefixPath = launchSession.prefixURL
                .standardizedFileURL.path
            let liveLoaderProcessIDs: [pid_t]
            do {
                let validation = try managedWineProcessValidation(
                    for: launchSession
                )
                let validatedProcessIDs = validation.processIDs
                var rejectionReasons: [String] = []
                liveLoaderProcessIDs = validatedProcessIDs.filter {
                    processIdentifier in
                    guard processIdentifier != primaryProcessIdentifier else {
                        rejectionReasons.append(
                            "PID \(processIdentifier) is the exited primary helper"
                        )
                        return false
                    }
                    guard let identity =
                            verifiedManagedWineSignalIdentities[
                                processIdentifier
                            ] else {
                        rejectionReasons.append(
                            "PID \(processIdentifier) has no retained exact identity"
                        )
                        return false
                    }
                    guard identity.prefixPath == prefixPath else {
                        rejectionReasons.append(
                            "PID \(processIdentifier) belongs to another prefix"
                        )
                        return false
                    }
                    guard Self.isManagedWineInputBindingExecutable(
                        identity.executableURL.path
                    ) else {
                        rejectionReasons.append(
                            "PID \(processIdentifier) is not a Wine loader"
                        )
                        return false
                    }
                    return true
                }
                if liveLoaderProcessIDs.isEmpty,
                   !validatedProcessIDs.isEmpty ||
                    !validation.inactiveReasons.isEmpty {
                    lastError = SafeProcessRunnerError
                        .prefixProcessVerificationFailed(
                            launchSession.evidenceURL,
                            "same-session process evidence contained no eligible live Wine loader: " +
                                (rejectionReasons +
                                    validation.inactiveReasons)
                                .joined(separator: "; ")
                        )
                }
            } catch {
                lastError = error
                liveLoaderProcessIDs = []
            }

            // Keep candidate readback outside the retryable journal-validation
            // catch above. A readback failure on a still-exact or
            // unreadable-present loader is terminal and must escape
            // immediately rather than being converted into deadline polling.
            for processIdentifier in liveLoaderProcessIDs {
                guard let expectedIdentity =
                        verifiedManagedWineSignalIdentities[
                            processIdentifier
                        ] else {
                    continue
                }
                do {
                    return try
                        requireManagedWineChildSynchronizationReadback(
                            for: processIdentifier
                        )
                } catch {
                    let readbackError = error
                    let identityAfterReadback = ManagedWineProcessJournal
                        .resolveProcessIdentityAcrossExitBoundary(
                            for: processIdentifier
                        )
                    switch Self
                        .managedWineReadbackFailureIdentityDisposition(
                            expectedStartTimeUnixMicroseconds:
                                expectedIdentity
                                    .processStartedAtUnixMicroseconds,
                            identityAfterReadback:
                                identityAfterReadback
                        ) {
                    case .candidateExited:
                        verifiedManagedWineSignalIdentities.removeValue(
                            forKey: processIdentifier
                        )
                        continue
                    case .candidateWasReused(let observedStart):
                        excludedReusedManagedWineSignalIdentities[
                            processIdentifier
                        ] = ExcludedReusedManagedWineSignalIdentity(
                            prefixPath: prefixPath,
                            processStartedAtUnixMicroseconds:
                                observedStart
                        )
                        verifiedManagedWineSignalIdentities.removeValue(
                            forKey: processIdentifier
                        )
                        continue
                    case .failClosed:
                        // A still-exact or unreadable-present process is not
                        // permission to try a different loader after its
                        // environment readback failed. Preserve the
                        // active-session receipt boundary fail-closed.
                        throw readbackError
                    }
                }
            }

            guard Date() < deadline else {
                if let lastError { throw lastError }
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    launchSession.evidenceURL,
                    "no exact live same-session Wine loader became available for child synchronization readback"
                )
            }
            try await Task.sleep(
                for: .seconds(max(pollInterval, 0.05))
            )
        } while !Task.isCancelled
        throw CancellationError()
    }

    /// Resolves a live Wine loader from ForgePlay-owned process evidence and
    /// independently reads back the synchronization profile from that exact
    /// Darwin process. This is used when the small Windows detach helper has
    /// already exited but the managed Steam/Wine session is still alive.
    func detachedHandoffManagedWineReadback(
        for prefix: URL,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1
    ) async throws -> ManagedWineChildSynchronizationReadback? {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var lastReadbackError: (any Error)?
        repeat {
            do {
                for processIdentifier in try managedInputBindingProcessIDs(
                    under: prefix
                ) {
                    do {
                        let readback = try
                            managedWineChildSynchronizationReadbackProvider(
                                processIdentifier
                            )
                        guard readback.processIdentifier == processIdentifier else {
                            throw SafeProcessRunnerError
                                .invalidPrefixSynchronizationProfile(
                                    URL(
                                        fileURLWithPath:
                                            "/proc/\(processIdentifier)/environment"
                                    )
                                )
                        }
                        return readback
                    } catch {
                        lastReadbackError = error
                    }
                }
            } catch {
                lastReadbackError = error
            }

            guard Date() < deadline else {
                if let lastReadbackError { throw lastReadbackError }
                return nil
            }
            try await Task.sleep(
                for: .seconds(max(pollInterval, 0.05))
            )
        } while !Task.isCancelled
        throw CancellationError()
    }

    func waitForManagedPrefixProcessesToExit(
        _ prefix: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        repeat {
            if try managedPrefixActivityProcessIDs(under: prefix).isEmpty {
                return true
            }
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .seconds(max(pollInterval, 0.05)))
        } while !Task.isCancelled
        return false
    }

    /// Final mutation gate for atomic prefix replacement. A successful
    /// wineserver shutdown is necessary but not sufficient: all exact launch
    /// sessions must already be retired, and no Foundation, descriptor-bound,
    /// managed-journal, Game Mode, or unowned live obstruction may remain.
    func requirePrefixReplacementQuiescence(_ prefix: URL) throws {
        let normalizedPrefix = prefix.standardizedFileURL
        let remainingSessions = managedWineSessionRegistry.launchSessions(
            for: normalizedPrefix
        )
        guard remainingSessions.isEmpty else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalizedPrefix,
                "\(remainingSessions.count) managed Wine launch session(s) remain registered after shutdown"
            )
        }

        pruneTrackedDetachedProcesses()
        let inspection = try managedProcessIDsHoldingOpenFiles(
            under: normalizedPrefix
        )
        guard inspection.isClean else {
            var details: [String] = []
            if !inspection.signalCapabilities.isEmpty {
                details.append(
                    "retained process ownership remains for PID(s): " +
                        Self.formattedPIDList(
                            inspection.signalCapabilities.map(\.processID)
                        )
                )
            }
            if !inspection.liveObstructions.isEmpty {
                details.append(inspection.obstructionSummary)
            }
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                normalizedPrefix,
                details.joined(separator: "; ")
            )
        }
    }

    private func run(
        _ spec: CommandSpec,
        detachedProcessPrefix: URL?
    ) throws -> ProcessRunResult {
        if !FileSystemItemPolicy.isRegularNonSymlinkFile(spec.executable, fileManager: fileManager) {
            try requireExecutableFile(spec.executable)
        }
        guard fileManager.isExecutableFile(atPath: spec.executable.path) else {
            throw SafeProcessRunnerError.executableMissing(spec.executable)
        }

        guard spec.stdoutLog.standardizedFileURL.path != spec.stderrLog.standardizedFileURL.path else {
            throw SafeProcessRunnerError.cannotCreateLog(spec.stdoutLog)
        }

        if let observationLog = spec.processObservationLog {
            let observationPath = observationLog.standardizedFileURL.path
            guard observationPath != spec.stdoutLog.standardizedFileURL.path,
                  observationPath != spec.stderrLog.standardizedFileURL.path else {
                throw SafeProcessRunnerError.cannotCreateLog(observationLog)
            }
            let observation = try Self.openLogFileHandle(at: observationLog, fileManager: fileManager)
            try? observation.close()
        }

        let stdout = try Self.openLogFileHandle(at: spec.stdoutLog, fileManager: fileManager)
        let stderr: FileHandle
        do {
            stderr = try Self.openLogFileHandle(at: spec.stderrLog, fileManager: fileManager)
        } catch {
            try? stdout.close()
            throw error
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        if !spec.preparationDiagnosticMarkers.isEmpty {
            let payload = spec.preparationDiagnosticMarkers
                .joined(separator: "\n") + "\n"
            // The same structured state is also persisted in
            // `runtimeCompatibility`. Required preparation failures have
            // already stopped the launch; writing their diagnostic marker is
            // best-effort and must not introduce a second failure mode.
            try? stderr.write(contentsOf: Data(payload.utf8))
        }

        if spec.runtimeLaunchObjectIdentity != nil {
            guard spec.runtimeLaunchObjectIdentityExecutable?
                    .standardizedFileURL == spec.executable.standardizedFileURL else {
                throw SafeProcessRunnerError.metadataReadFailed(
                    spec.executable,
                    "runtime launch-object identity does not match the final command executable"
                )
            }
        }
        try spec.runtimeLaunchObjectIdentity?.revalidate()
        try spec.anchoredLibraryPathIdentity?.revalidate()
        try spec.windowsUtilityExecutableIdentity?.revalidate()
        let processEnvironment = Self.processEnvironment(overrides: spec.environment)
        let startedAt = Date()
        if spec.runtimeLaunchObjectIdentity != nil ||
            spec.windowsUtilityExecutableIdentity != nil {
            return try runDescriptorBound(
                spec,
                runtimeIdentity: spec.runtimeLaunchObjectIdentity,
                environment: processEnvironment,
                stdoutDescriptor: stdout.fileDescriptor,
                stderrDescriptor: stderr.fileDescriptor,
                detachedProcessPrefix: detachedProcessPrefix,
                startedAt: startedAt
            )
        }
        if spec.waitsForExit, let timeout = spec.timeout, timeout > 0 {
            let execution = try BoundedProcessExecutor.run(
                executable: spec.executable,
                arguments: spec.arguments,
                environment: processEnvironment,
                workingDirectory: spec.workingDirectory,
                stdoutDescriptor: stdout.fileDescriptor,
                stderrDescriptor: stderr.fileDescriptor,
                timeout: timeout,
                cancellationScope: synchronousProcessCancellationScope
            )
            return ProcessRunResult(
                actionName: spec.actionName,
                executable: spec.executable,
                arguments: spec.arguments,
                startedAt: startedAt,
                endedAt: Date(),
                exitCode: execution.processExitCode ?? 0,
                hasProcessExitCode: execution.processExitCode != nil,
                forgePlayStatusCode: execution.forgePlayStatusCode,
                stdoutLog: spec.stdoutLog,
                stderrLog: spec.stderrLog,
                didTimeOut: execution.waitOutcome.didTimeOut,
                waitedForExit: execution.waitOutcome.didExit,
                outcome: execution.wasCancelled
                    ? .signaled
                    : (execution.waitOutcome.didTimeOut
                    ? .timedOut
                    : (execution.rawWaitStatus == nil
                        ? .unknown
                        : (execution.terminationSignal == nil ? .exited : .signaled))),
                terminationSignal: execution.terminationSignal,
                rawWaitStatus: execution.rawWaitStatus,
                processIdentifier: execution.processIdentifier,
                processObservationLog: spec.processObservationLog,
                evidenceCaptureWarning: execution.waitStatusCaptureError.map {
                    "Process exit status capture failed: \($0)"
                }
            )
        }

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = processEnvironment
        process.currentDirectoryURL = spec.workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        var detachedLaunchSignalCapability: ManagedProcessSignalTarget?
        var detachedLaunchIdentityCaptureFailure: String?
        if !spec.waitsForExit, let detachedProcessPrefix {
            let capture = captureManagedSignalCapability(
                processID: process.processIdentifier,
                source: .trackedFoundationProcess,
                failureRoot: detachedProcessPrefix
            )
            detachedLaunchSignalCapability = capture.target
            detachedLaunchIdentityCaptureFailure = capture.failure
        }
        guard spec.waitsForExit else {
            if spec.startupValidationInterval > 0 {
                let deadline = Date().addingTimeInterval(spec.startupValidationInterval)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if !process.isRunning {
                    process.waitUntilExit()
                    let endedAt = Date()
                    return ProcessRunResult(
                        actionName: spec.actionName,
                        executable: spec.executable,
                        arguments: spec.arguments,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        exitCode: process.terminationStatus,
                        hasProcessExitCode: process.terminationReason == .exit,
                        stdoutLog: spec.stdoutLog,
                        stderrLog: spec.stderrLog,
                        didTimeOut: false,
                        waitedForExit: true,
                        outcome: process.terminationReason == .uncaughtSignal ? .signaled : .exited,
                        terminationSignal: process.terminationReason == .uncaughtSignal
                            ? process.terminationStatus
                            : nil,
                        processIdentifier: process.processIdentifier,
                        processObservationLog: spec.processObservationLog
                    )
                }
            }
            if let detachedProcessPrefix, process.isRunning {
                trackedDetachedProcesses[process.processIdentifier] =
                    TrackedDetachedProcess(
                        process: process,
                        prefixPath: detachedProcessPrefix.standardizedFileURL
                            .path,
                        signalCapability: detachedLaunchSignalCapability,
                        identityCaptureFailure:
                            detachedLaunchIdentityCaptureFailure
                    )
            }
            let endedAt = Date()
            return ProcessRunResult(
                actionName: spec.actionName,
                executable: spec.executable,
                arguments: spec.arguments,
                startedAt: startedAt,
                endedAt: endedAt,
                exitCode: 0,
                hasProcessExitCode: false,
                stdoutLog: spec.stdoutLog,
                stderrLog: spec.stderrLog,
                didTimeOut: false,
                waitedForExit: false,
                outcome: .runningDetached,
                processIdentifier: process.processIdentifier,
                processObservationLog: spec.processObservationLog
            )
        }
        process.waitUntilExit()
        let endedAt = Date()

        return ProcessRunResult(
            actionName: spec.actionName,
            executable: spec.executable,
            arguments: spec.arguments,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: process.terminationStatus,
            hasProcessExitCode: process.terminationReason == .exit,
            stdoutLog: spec.stdoutLog,
            stderrLog: spec.stderrLog,
            didTimeOut: false,
            waitedForExit: true,
            outcome: process.terminationReason == .uncaughtSignal ? .signaled : .exited,
            terminationSignal: process.terminationReason == .uncaughtSignal
                ? process.terminationStatus
                : nil,
            processIdentifier: process.processIdentifier,
            processObservationLog: spec.processObservationLog
        )
    }

    private func runDescriptorBound(
        _ spec: CommandSpec,
        runtimeIdentity: RuntimeLaunchObjectIdentity?,
        environment: [String: String],
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        detachedProcessPrefix: URL?,
        startedAt: Date
    ) throws -> ProcessRunResult {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&fileActions)
        guard result == 0 else {
            throw descriptorBoundSpawnError(spec.executable, result)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw descriptorBoundSpawnError(spec.executable, result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        for (source, target) in [
            (stdoutDescriptor, STDOUT_FILENO),
            (stderrDescriptor, STDERR_FILENO)
        ] {
            result = posix_spawn_file_actions_adddup2(
                &fileActions,
                source,
                target
            )
            guard result == 0 else {
                throw descriptorBoundSpawnError(spec.executable, result)
            }
        }
        if let workingDirectory = spec.workingDirectory {
            result = posix_spawn_file_actions_addchdir(
                &fileActions,
                workingDirectory.path
            )
            guard result == 0 else {
                throw descriptorBoundSpawnError(spec.executable, result)
            }
        }

        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        result = posix_spawnattr_setflags(&attributes, spawnFlags)
        guard result == 0 else {
            throw descriptorBoundSpawnError(spec.executable, result)
        }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else {
            throw descriptorBoundSpawnError(spec.executable, result)
        }

        var childEnvironment = environment
        let executablePath: String
        let argumentPrefix: [String]
        if let runtimeIdentity {
            let descriptorInvocation =
                try runtimeIdentity.installSpawnCapabilities(
                    fileActions: &fileActions,
                    environment: &childEnvironment,
                    anchoredLibraryIdentity:
                        spec.anchoredLibraryPathIdentity
                )
            executablePath = descriptorInvocation.executablePath
            argumentPrefix = descriptorInvocation.argumentPrefix
        } else {
            executablePath = spec.executable.path
            argumentPrefix = [spec.executable.path]
        }
        var childArguments = spec.arguments
        if let utilityIdentity =
            spec.windowsUtilityExecutableIdentity {
            childArguments = try utilityIdentity.installSpawnCapability(
                fileActions: &fileActions,
                environment: &childEnvironment,
                arguments: childArguments
            )
        }
        // Revalidate every retained identity at the final boundary after all
        // file actions are fixed and before the kernel consumes descriptors.
        try runtimeIdentity?.revalidate()
        try spec.anchoredLibraryPathIdentity?.revalidate()
        try spec.windowsUtilityExecutableIdentity?.revalidate()

        var processIdentifier: pid_t = 0
        let arguments = argumentPrefix + childArguments
        let environmentRows = childEnvironment.keys.sorted().map {
            "\($0)=\(childEnvironment[$0] ?? "")"
        }
        result = Self.withDescriptorBoundCStringArray(arguments) {
            argumentPointers in
            Self.withDescriptorBoundCStringArray(environmentRows) {
                environmentPointers in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        guard result == 0, processIdentifier > 0 else {
            throw descriptorBoundSpawnError(
                spec.executable,
                result == 0 ? ECHILD : result
            )
        }

        let process = DescriptorBoundSpawnedProcess(
            processIdentifier: processIdentifier
        )
        let descriptorSignalCapture = captureManagedSignalCapability(
            processID: processIdentifier,
            source: .trackedDescriptorBoundProcess,
            failureRoot: spec.executable
        )
        if spec.waitsForExit {
            var didTimeOut = false
            var wasCancelled = false
            if let timeout = spec.timeout, timeout > 0 {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline,
                      !synchronousProcessCancellationScope
                        .isCancellationRequested {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                wasCancelled = synchronousProcessCancellationScope
                    .isCancellationRequested
                if process.isRunning, !wasCancelled {
                    didTimeOut = true
                }
            } else {
                while process.isRunning,
                      !synchronousProcessCancellationScope
                        .isCancellationRequested {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                wasCancelled = synchronousProcessCancellationScope
                    .isCancellationRequested
            }
            let fullyReconciled = terminateAndReapDescriptorBoundOwnership(
                process,
                signalCapability: descriptorSignalCapture.target
            )
            if !fullyReconciled {
                trackedDescriptorBoundProcesses[processIdentifier] =
                    TrackedDescriptorBoundProcess(
                        process: process,
                        prefixPath: detachedProcessPrefix?
                            .standardizedFileURL.path,
                        signalCapability: descriptorSignalCapture.target,
                        identityCaptureFailure: descriptorSignalCapture.failure
                    )
            }
            var waitResult = descriptorBoundResult(
                spec,
                process: process,
                startedAt: startedAt,
                didTimeOut: didTimeOut,
                wasCancelled: wasCancelled
            )
            if !fullyReconciled {
                waitResult.waitedForExit = false
                waitResult.hasProcessExitCode = false
                waitResult.outcome = .runningDetached
                waitResult.postconditionSatisfied = false
                waitResult.evidenceCaptureWarning = DiagnosticWarningText
                    .combined(
                        waitResult.evidenceCaptureWarning,
                        "Descriptor-bound process-group ownership remains " +
                            "tracked after the synchronous wait " +
                            "(pgid=\(processIdentifier), group=" +
                            process.processGroupPresence
                                .diagnosticDescription + ")"
                    )
            }
            return waitResult
        }

        if spec.startupValidationInterval > 0 {
            let deadline = Date().addingTimeInterval(
                spec.startupValidationInterval
            )
            while process.hasTrackedOwnership, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !process.hasTrackedOwnership {
                return descriptorBoundResult(
                    spec,
                    process: process,
                    startedAt: startedAt,
                    didTimeOut: false
                )
            }
        }
        if let detachedProcessPrefix, process.hasTrackedOwnership {
            trackedDescriptorBoundProcesses[processIdentifier] =
                TrackedDescriptorBoundProcess(
                    process: process,
                    prefixPath: detachedProcessPrefix.standardizedFileURL.path,
                    signalCapability: descriptorSignalCapture.target,
                    identityCaptureFailure: descriptorSignalCapture.failure
                )
        }
        return ProcessRunResult(
            actionName: spec.actionName,
            executable: spec.executable,
            arguments: spec.arguments,
            startedAt: startedAt,
            endedAt: Date(),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: spec.stdoutLog,
            stderrLog: spec.stderrLog,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached,
            processIdentifier: processIdentifier,
            processObservationLog: spec.processObservationLog
        )
    }

    private func descriptorBoundResult(
        _ spec: CommandSpec,
        process: DescriptorBoundSpawnedProcess,
        startedAt: Date,
        didTimeOut: Bool,
        wasCancelled: Bool = false
    ) -> ProcessRunResult {
        let signal = process.terminationSignal
        let exitCode = process.processExitCode
        let waitError = process.waitError.map {
            "waitpid(\(process.processIdentifier)) failed: " +
                String(cString: strerror($0)) + " [errno=\($0)]"
        }
        return ProcessRunResult(
            actionName: spec.actionName,
            executable: spec.executable,
            arguments: spec.arguments,
            startedAt: startedAt,
            endedAt: Date(),
            exitCode: exitCode ?? 0,
            hasProcessExitCode: exitCode != nil,
            forgePlayStatusCode: wasCancelled
                ? BoundedProcessExecutor.cancelledExitCode
                : (didTimeOut
                    ? BoundedProcessExecutor.forcedTimeoutExitCode
                    : nil),
            stdoutLog: spec.stdoutLog,
            stderrLog: spec.stderrLog,
            didTimeOut: didTimeOut,
            waitedForExit: !process.isRunning,
            outcome: wasCancelled
                ? .signaled
                : (didTimeOut
                ? .timedOut
                : (process.waitStatus == nil
                    ? .unknown
                    : (signal == nil ? .exited : .signaled))),
            terminationSignal: signal,
            rawWaitStatus: process.waitStatus,
            processIdentifier: process.processIdentifier,
            processObservationLog: spec.processObservationLog,
            evidenceCaptureWarning: waitError
        )
    }

    private nonisolated func descriptorBoundSpawnError(
        _ executable: URL,
        _ errorCode: Int32
    ) -> BoundedProcessExecutorError {
        BoundedProcessExecutorError.cannotStartProcess(
            executable,
            String(cString: strerror(errorCode))
        )
    }

    private nonisolated static func withDescriptorBoundCStringArray<Result>(
        _ values: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Result
    ) -> Result {
        let strings: [UnsafeMutablePointer<CChar>] = values.map {
            strdup($0)!
        }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private enum PrefixProcessCleanupState: Hashable {
        case clean
        case cleaned([pid_t])
        case remaining([pid_t])
        case verificationUnavailable(String)
    }

    private nonisolated static let prefixProcessCleanupFailureExitCode: Int32 = 74

    private struct WinePrefixCleanupReconciliation {
        var result: ProcessRunResult
        var state: PrefixProcessCleanupState

        var confirmsCleanPrefix: Bool {
            switch state {
            case .clean, .cleaned:
                true
            case .remaining, .verificationUnavailable:
                false
            }
        }
    }

    /// Completes Wine shutdown by evaluating the actual postcondition rather
    /// than trusting a single `wineserver` invocation. Every command keeps its
    /// own raw sidecar; the primary result links those attempts and records the
    /// authoritative prefix-shutdown postcondition separately.
    private func completeWinePrefixShutdown(
        after shutdownResult: ProcessRunResult,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        runtimeAuthenticationContext: RuntimeAuthenticatedContext?
    ) throws -> ProcessRunResult {
        let initialCleanup = finalizeWinePrefixShutdown(shutdownResult, prefix: prefix)
        var finalized = initialCleanup.result
        if shutdownResult.didTimeOut {
            _ = appendDiagnosticLines([
                "",
                "[ForgePlay] Initial Wine shutdown attempt timed out: " +
                    "pid=\(shutdownResult.processIdentifier.map(String.init) ?? "unavailable") " +
                    "signal=\(shutdownResult.diagnosticTerminationSignalDescription) " +
                    "rawWaitStatus=\(shutdownResult.rawWaitStatus.map(String.init) ?? "unavailable") " +
                    "durationMs=\(Int64(max(0, shutdownResult.endedAt.timeIntervalSince(shutdownResult.startedAt) * 1_000)))",
                "[ForgePlay] ForgePlay will decide this operation from cleanup plus the wineserver exit barrier instead of the timed-out attempt alone."
            ], to: finalized.stderrLog)
        }

        let barrierSpec = try makeWinePrefixWaitCommandSpec(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            actionName: "confirmWinePrefixShutdown",
            logName: "wine_prefix_shutdown_wait",
            timeout: 15,
            allowsInvalidPrefixSynchronizationProfileForCleanup: true
        )
        let forceSpec = try makeWinePrefixSignalCommandSpec(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            signal: SIGKILL,
            actionName: "forceWinePrefixShutdown",
            logName: "wine_prefix_shutdown_force",
            timeout: 5
        )
        let forcedBarrierSpec = try makeWinePrefixWaitCommandSpec(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            actionName: "confirmForcedWinePrefixShutdown",
            logName: "wine_prefix_shutdown_force_wait",
            timeout: 15,
            allowsInvalidPrefixSynchronizationProfileForCleanup: true
        )

        let barrierResult = try runWineServerControlCommand(
            barrierSpec,
            authenticatedContext: runtimeAuthenticationContext
        )
        finalized = attachingRunEvidence(from: barrierResult, to: finalized)
        if barrierResult.succeeded, initialCleanup.confirmsCleanPrefix {
            finalized.postconditionSatisfied = true
            finalized.forgePlayStatusCode = 0
            let recoveryNote = shutdownResult.succeeded
                ? "Wine prefix shutdown barrier completed; wineserver has exited for this prefix."
                : "The initial Wine shutdown attempt did not succeed, but cleanup and the wineserver exit barrier confirmed that the prefix is inactive."
            _ = appendDiagnosticLines(["", "[ForgePlay] \(recoveryNote)"], to: finalized.stderrLog)
            finalized = clearingManagedProcessLaunchRecords(
                for: prefix,
                from: finalized
            )
            return finalized
        }

        if !barrierResult.succeeded {
            _ = appendDiagnosticLines([
                "",
                "[ForgePlay] Wine prefix shutdown barrier failed: processExit=\(barrierResult.diagnosticExitCodeDescription) " +
                    "forgePlayStatus=\(barrierResult.diagnosticForgePlayStatusDescription) " +
                    "timeout=\(barrierResult.didTimeOut) stderr=\(barrierResult.stderrLog.path) " +
                    "runEvidence=\(barrierResult.runEvidenceLog?.path ?? "unavailable")"
            ], to: finalized.stderrLog)
        }

        if case .verificationUnavailable = initialCleanup.state {
            finalized.postconditionSatisfied = false
            finalized.forgePlayStatusCode = Self.prefixProcessCleanupFailureExitCode
            finalized.didTimeOut = finalized.didTimeOut || barrierResult.didTimeOut
            return finalized
        }

        _ = appendDiagnosticLines([
            "",
            "[ForgePlay] The shutdown postcondition was not confirmed. Requesting a separately logged forced wineserver stop before checking again."
        ], to: finalized.stderrLog)

        let rawForceResult = try runWineServerControlCommand(
            forceSpec,
            authenticatedContext: runtimeAuthenticationContext
        )
        let forceCleanup = finalizeWinePrefixShutdown(rawForceResult, prefix: prefix)
        let forceResult = persistProcessEvidence(forceCleanup.result, spec: forceSpec)
        finalized = attachingRunEvidence(from: forceResult, to: finalized)

        let forcedBarrierResult = try runWineServerControlCommand(
            forcedBarrierSpec,
            authenticatedContext: runtimeAuthenticationContext
        )
        finalized = attachingRunEvidence(from: forcedBarrierResult, to: finalized)
        if forcedBarrierResult.succeeded, forceCleanup.confirmsCleanPrefix {
            finalized.postconditionSatisfied = true
            finalized.forgePlayStatusCode = 0
            _ = appendDiagnosticLines([
                "",
                "[ForgePlay] Forced shutdown recovery completed; cleanup and the final wineserver exit barrier confirmed that the prefix is inactive.",
                "[ForgePlay] Recovery evidence: \(forceResult.runEvidenceLog?.path ?? "unavailable")",
                "[ForgePlay] Final barrier evidence: \(forcedBarrierResult.runEvidenceLog?.path ?? "unavailable")"
            ], to: finalized.stderrLog)
            finalized = clearingManagedProcessLaunchRecords(
                for: prefix,
                from: finalized
            )
            return finalized
        }

        finalized.postconditionSatisfied = false
        finalized.forgePlayStatusCode = forcedBarrierResult.succeeded
            ? Self.prefixProcessCleanupFailureExitCode
            : winePrefixShutdownFailureStatus(for: forcedBarrierResult)
        finalized.didTimeOut = finalized.didTimeOut ||
            barrierResult.didTimeOut || rawForceResult.didTimeOut || forcedBarrierResult.didTimeOut
        _ = appendDiagnosticLines([
            "",
            "[ForgePlay] Wine prefix shutdown remained unconfirmed after forced recovery: " +
                "processExit=\(forcedBarrierResult.diagnosticExitCodeDescription) " +
                "forgePlayStatus=\(forcedBarrierResult.diagnosticForgePlayStatusDescription) " +
                "timeout=\(forcedBarrierResult.didTimeOut) stderr=\(forcedBarrierResult.stderrLog.path) " +
                "runEvidence=\(forcedBarrierResult.runEvidenceLog?.path ?? "unavailable")"
        ], to: finalized.stderrLog)
        return finalized
    }

    private func clearingManagedProcessLaunchRecords(
        for prefix: URL,
        from input: ProcessRunResult
    ) -> ProcessRunResult {
        var result = input
        let prefixPath = prefix.standardizedFileURL.path
        // The clean-prefix postcondition, not best-effort artifact deletion,
        // ends this actor's in-memory ownership. A descriptor that cannot be
        // removed remains an intentional fail-closed marker for a later app
        // process; it is never silently reclassified as an empty registry.
        let launchSessions = managedWineSessionRegistry.completeSessions(
            for: prefix
        )
        gameModeHostLaunchRecords = gameModeHostLaunchRecords.filter {
            $0.prefixPath != prefixPath
        }
        verifiedManagedWineSignalIdentities =
            verifiedManagedWineSignalIdentities.filter {
                $0.value.prefixPath != prefixPath
            }
        excludedReusedManagedWineSignalIdentities =
            excludedReusedManagedWineSignalIdentities.filter {
                $0.value.prefixPath != prefixPath
            }

        var cleanupFailures: [String] = []
        for launchSession in launchSessions {
            var validatedDescriptorURL: URL?
            if let descriptorURL = launchSession.descriptorURL {
                var descriptorStatus = stat()
                if lstat(descriptorURL.path, &descriptorStatus) == 0 {
                    do {
                        let descriptor = try ManagedWineProcessJournal
                            .readActiveSessionDescriptor(at: descriptorURL)
                        guard descriptor.runIdentifier ==
                                launchSession.runIdentifier,
                              descriptor.prefixScope ==
                                launchSession.prefixScope,
                              descriptor.runtimeFingerprint ==
                                launchSession.runtimeFingerprint else {
                            throw SafeProcessRunnerError
                                .prefixProcessVerificationFailed(
                                    descriptorURL,
                                    "the active-session cleanup identity changed"
                                )
                        }
                        validatedDescriptorURL = descriptorURL
                    } catch {
                        cleanupFailures.append(
                            "\(launchSession.runIdentifier):descriptor"
                        )
                        // Keep the paired evidence whenever the ownership
                        // descriptor remains. A later process can then fail
                        // closed or re-verify the complete pair.
                        continue
                    }
                } else if errno != ENOENT {
                    cleanupFailures.append(
                        "\(launchSession.runIdentifier):descriptor"
                    )
                    continue
                }
            }

            // The descriptor is the active-session commit marker. Remove the
            // evidence first and the descriptor last so a crash can leave only
            // a fail-closed active marker, never an unowned journal that a
            // later process could mistake for an empty registry.
            var status = stat()
            if lstat(launchSession.evidenceURL.path, &status) != 0 {
                if errno != ENOENT {
                    cleanupFailures.append(
                        "\(launchSession.runIdentifier):evidence"
                    )
                    continue
                }
            } else {
                do {
                    try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                        launchSession.evidenceURL,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupFailures.append(
                        "\(launchSession.runIdentifier):evidence"
                    )
                    continue
                }
                guard status.st_uid == geteuid(),
                      status.st_nlink == 1,
                      (status.st_mode & mode_t(0o777)) ==
                        (S_IRUSR | S_IWUSR) else {
                    cleanupFailures.append(
                        "\(launchSession.runIdentifier):evidence"
                    )
                    continue
                }
                do {
                    try fileManager.removeItem(at: launchSession.evidenceURL)
                } catch {
                    cleanupFailures.append(
                        "\(launchSession.runIdentifier):evidence"
                    )
                    continue
                }
            }
            if let validatedDescriptorURL {
                do {
                    try fileManager.removeItem(at: validatedDescriptorURL)
                } catch {
                    cleanupFailures.append(
                        "\(launchSession.runIdentifier):descriptor"
                    )
                }
            }
        }

        guard !cleanupFailures.isEmpty else { return result }
        let warning =
            "Managed Wine session ownership was cleared after the clean-prefix " +
            "postcondition, but \(cleanupFailures.count) ownership artifact(s) " +
            "could not be removed (artifacts: " +
            cleanupFailures.sorted().joined(separator: ", ") + ")."
        result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
            result.diagnosticCaptureWarning,
            warning
        )
        _ = appendDiagnosticLines(
            ["", "[ForgePlay] \(warning)"],
            to: result.stderrLog
        )
        return result
    }

    private func runWineServerControlCommand(
        _ input: CommandSpec,
        authenticatedContext: RuntimeAuthenticatedContext?
    ) throws -> ProcessRunResult {
        let startedAt = Date()
        var spec = input
        do {
            spec = try attachingRuntimeLaunchObjectIdentity(
                to: input,
                authenticatedContext: authenticatedContext
            )
            let result = try run(spec, detachedProcessPrefix: nil)
            return persistProcessEvidence(result, spec: spec)
        } catch {
            if let failureResult = persistSpawnFailureEvidence(
                spec: spec,
                startedAt: startedAt,
                error: error
            ) {
                return failureResult
            }
            throw error
        }
    }

    private func attachingRuntimeLaunchObjectIdentity(
        to input: CommandSpec,
        authenticatedContext: RuntimeAuthenticatedContext? = nil
    ) throws -> CommandSpec {
        var spec = input
        let executable = spec.executable.standardizedFileURL
        spec.runtimeLaunchObjectIdentity = try authenticatedContext?
            .launchObjectIdentity(for: executable) ??
            runtimeLaunchObjectIdentityProvider(executable)
        spec.runtimeLaunchObjectIdentityExecutable =
            spec.runtimeLaunchObjectIdentity == nil ? nil : executable
        return spec
    }

    private func attachingRunEvidence(
        from relatedResult: ProcessRunResult,
        to primaryResult: ProcessRunResult
    ) -> ProcessRunResult {
        var primaryResult = primaryResult
        if let evidence = relatedResult.runEvidenceLog {
            primaryResult.relatedRunEvidenceLogs.append(evidence.standardizedFileURL)
        }
        primaryResult.relatedRunEvidenceLogs = Self.deduplicated(
            primaryResult.relatedRunEvidenceLogs
        )
        return primaryResult
    }

    private nonisolated func winePrefixShutdownFailureStatus(
        for result: ProcessRunResult
    ) -> Int32 {
        result.forgePlayStatusCode ?? result.processExitCode ?? Self.prefixProcessCleanupFailureExitCode
    }

    private func finalizeWinePrefixShutdown(
        _ result: ProcessRunResult,
        prefix: URL
    ) -> WinePrefixCleanupReconciliation {
        var finalized = result
        let processLogsWereEmpty = processLogsAreEmpty(finalized)
        let cleanup = cleanupProcessesHoldingPrefix(prefix, logURL: result.stderrLog)
        let isExpectedNoServerExit = finalized.processExitCode == 1 &&
            !finalized.didTimeOut &&
            processLogsWereEmpty
        switch cleanup {
        case .clean:
            if isExpectedNoServerExit {
                appendDiagnosticLines([
                    "",
                    "[ForgePlay] wineserver reported no active server and no ForgePlay-managed process remains for this prefix. Treating the prefix as clean."
                ], to: result.stderrLog)
                finalized.forgePlayStatusCode = 0
            }
        case .cleaned(let pids):
            appendDiagnosticLines([
                "",
                "[ForgePlay] Removed stale process(es) holding Wine prefix: \(Self.formattedPIDList(pids))."
            ], to: result.stderrLog)
            if isExpectedNoServerExit {
                finalized.forgePlayStatusCode = 0
            }
        case .remaining(let pids):
            appendDiagnosticLines([
                "",
                "[ForgePlay] Failed to remove process(es) still holding Wine prefix: \(Self.formattedPIDList(pids))."
            ], to: result.stderrLog)
            finalized.forgePlayStatusCode = Self.prefixProcessCleanupFailureExitCode
        case .verificationUnavailable(let message):
            appendDiagnosticLines([
                "",
                "[ForgePlay] Could not verify Wine prefix process cleanup: \(message)"
            ], to: result.stderrLog)
            finalized.forgePlayStatusCode = Self.prefixProcessCleanupFailureExitCode
        }
        return WinePrefixCleanupReconciliation(result: finalized, state: cleanup)
    }

    private func cleanupProcessesHoldingPrefix(
        _ prefix: URL,
        logURL: URL
    ) -> PrefixProcessCleanupState {
        let initial: ManagedPrefixProcessInspection
        do {
            initial = try managedProcessIDsHoldingOpenFiles(under: prefix)
        } catch {
            return .verificationUnavailable(forgePlayTechnicalErrorSummary(error))
        }
        guard !initial.signalCapabilities.isEmpty else {
            return initial.liveObstructions.isEmpty
                ? .clean
                : .verificationUnavailable(initial.obstructionSummary)
        }
        let initiallyOwnedPIDs = initial.signalCapabilities.map(\.processID)

        appendDiagnosticLines([
            "",
            "[ForgePlay] Detected process(es) still holding Wine prefix after wineserver shutdown: \(Self.formattedPIDList(initiallyOwnedPIDs)).",
            "[ForgePlay] Sending SIGTERM before retrying cleanup."
        ], to: logURL)
        let terminateObstructions = sendSignal(
            SIGTERM,
            to: initial.signalCapabilities,
            for: prefix
        )
        guard terminateObstructions.isEmpty else {
            return .verificationUnavailable(
                ManagedPrefixProcessInspection(
                    signalCapabilities: [],
                    liveObstructions: initial.liveObstructions +
                        terminateObstructions
                ).obstructionSummary
            )
        }
        Thread.sleep(forTimeInterval: 1)

        let afterTerminate: ManagedPrefixProcessInspection
        do {
            afterTerminate = try managedProcessIDsHoldingOpenFiles(under: prefix)
        } catch {
            return .verificationUnavailable(forgePlayTechnicalErrorSummary(error))
        }
        guard !afterTerminate.signalCapabilities.isEmpty else {
            return afterTerminate.liveObstructions.isEmpty
                ? .cleaned(initiallyOwnedPIDs)
                : .verificationUnavailable(afterTerminate.obstructionSummary)
        }

        appendDiagnosticLines([
            "[ForgePlay] Process(es) still holding prefix after SIGTERM: \(Self.formattedPIDList(afterTerminate.signalCapabilities.map(\.processID))).",
                "[ForgePlay] Sending SIGKILL to stale ForgePlay Runtime process(es)."
        ], to: logURL)
        let killObstructions = sendSignal(
            SIGKILL,
            to: afterTerminate.signalCapabilities,
            for: prefix
        )
        guard killObstructions.isEmpty else {
            return .verificationUnavailable(
                ManagedPrefixProcessInspection(
                    signalCapabilities: [],
                    liveObstructions: afterTerminate.liveObstructions +
                        killObstructions
                ).obstructionSummary
            )
        }
        Thread.sleep(forTimeInterval: 1)

        let afterKill: ManagedPrefixProcessInspection
        do {
            afterKill = try managedProcessIDsHoldingOpenFiles(under: prefix)
        } catch {
            return .verificationUnavailable(forgePlayTechnicalErrorSummary(error))
        }
        if afterKill.isClean {
            return .cleaned(initiallyOwnedPIDs)
        }
        if !afterKill.liveObstructions.isEmpty {
            return .verificationUnavailable(afterKill.obstructionSummary)
        }
        return .remaining(afterKill.signalCapabilities.map(\.processID))
    }

    private nonisolated static func formattedPIDList(_ pids: [pid_t]) -> String {
        pids.map(String.init).joined(separator: ", ")
    }

    nonisolated static func latestPrefixHolderProcessIDsRequiringInspection(
        initialSnapshot: [pid_t],
        latestSnapshot: [pid_t]
    ) -> [pid_t] {
        let initial = Set(initialSnapshot.filter { $0 > 0 })
        let latest = Set(latestSnapshot.filter { $0 > 0 })
        let retained = initial.intersection(latest)
        let newlyAppeared = latest.subtracting(initial)
        // The latest snapshot is authoritative. In particular, a holder that
        // appeared between lsof calls must never disappear through an
        // intersection-only confirmation rule.
        return retained.union(newlyAppeared).sorted()
    }

    private func managedProcessIDsHoldingOpenFiles(
        under prefix: URL
    ) throws -> ManagedPrefixProcessInspection {
        var capabilitiesByPID: [pid_t: ManagedProcessSignalTarget] = [:]
        var obstructions: [ManagedProcessLiveObstruction] = []
        var conflictedPIDs = Set<pid_t>()

        func mergeCapability(_ target: ManagedProcessSignalTarget) {
            guard !conflictedPIDs.contains(target.processID) else { return }
            guard let existing = capabilitiesByPID[target.processID] else {
                capabilitiesByPID[target.processID] = target
                return
            }
            switch Self.managedSignalCapabilityMergeDecision(
                existing: existing,
                candidate: target
            ) {
            case .keepExisting:
                break
            case .replaceExisting:
                capabilitiesByPID[target.processID] = target
            case .obstruct:
                capabilitiesByPID.removeValue(forKey: target.processID)
                conflictedPIDs.insert(target.processID)
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: target.processID,
                    reason: "trusted ownership sources disagree on start or executable identity"
                ))
            }
        }

        for target in try registeredManagedWineProcessTargets(for: prefix) {
            mergeCapability(target)
        }
        let gameModeInspection = try registeredGameModeHostProcessInspection(
            for: prefix
        )
        gameModeInspection.signalCapabilities.forEach(mergeCapability)
        obstructions.append(contentsOf: gameModeInspection.liveObstructions)
        let trackedInspection = trackedDetachedProcessInspection(for: prefix)
        trackedInspection.signalCapabilities.forEach(mergeCapability)
        obstructions.append(contentsOf: trackedInspection.liveObstructions)

        let prefixPath = prefix.standardizedFileURL.path
        let excludedForPrefix = excludedReusedManagedWineSignalIdentities
            .filter { $0.value.prefixPath == prefixPath }
        for (pid, _) in excludedForPrefix {
            let resolution = ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(for: pid)
            if Self.managedSignalExclusionMayBeRetired(after: resolution) {
                excludedReusedManagedWineSignalIdentities.removeValue(
                    forKey: pid
                )
            } else {
                capabilitiesByPID.removeValue(forKey: pid)
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "a live or unreadable PID-reuse exclusion still obstructs the prefix"
                ))
            }
        }

        // App Sandbox cannot inspect the host process table. Prefix-specific wineserver IPC
        // handles cross-session shutdown; this actor owns and verifies processes from this session.
        guard !sandboxEnabled else {
            return ManagedPrefixProcessInspection(
                signalCapabilities: capabilitiesByPID.values.sorted {
                    $0.processID < $1.processID
                },
                liveObstructions: obstructions
            )
        }

        let initialHolders = try processIDsHoldingOpenFiles(under: prefix)
        let latestHolders = try processIDsHoldingOpenFiles(under: prefix)
        for pid in Self.latestPrefixHolderProcessIDsRequiringInspection(
            initialSnapshot: initialHolders,
            latestSnapshot: latestHolders
        ) {
            if capabilitiesByPID[pid] != nil { continue }
            if obstructions.contains(where: { $0.processID == pid }) {
                continue
            }
            switch ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(for: pid) {
            case .exited:
                continue
            case .unavailable:
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "lsof-only prefix holder has no readable exact process identity"
                ))
            case .live:
                let executable = try? processCommand(for: pid)
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "lsof-only prefix holder is not a trusted signal capability" +
                        (executable.map { ": \($0)" } ?? "")
                ))
            }
        }
        return ManagedPrefixProcessInspection(
            signalCapabilities: capabilitiesByPID.values.sorted {
                $0.processID < $1.processID
            },
            liveObstructions: obstructions
        )
    }

    private func hydrateManagedWineSessions(
        for prefix: URL,
        runtimeExecutable: URL,
        logDirectory: URL,
        runtimeFingerprint authenticatedRuntimeFingerprint: String?
    ) throws {
        guard let runtimeRootURL = Self.wineRootDirectory(
            for: runtimeExecutable
        ) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                runtimeExecutable,
                "the selected cleanup Runtime has no curated Wine root"
            )
        }
        let runtimeFingerprint = try authenticatedRuntimeFingerprint ??
            managedWineRuntimeFingerprintResolver(runtimeExecutable)
        guard ManagedWineProcessJournal.isLowercaseSHA256(
            runtimeFingerprint
        ) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                runtimeExecutable,
                "the selected cleanup Runtime fingerprint is invalid"
            )
        }

        let evidenceDirectory: URL
        let evidenceTrustedAncestor: URL
        if managedWineProcessEvidenceSandboxEnabled {
            guard let applicationGroupIdentifier =
                    ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
                  let groupContainer = fileManager.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        applicationGroupIdentifier
                  ) else {
                throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
            }
            evidenceDirectory = groupContainer
                .appending(
                    path: "Library/Application Support/ForgePlay",
                    directoryHint: .isDirectory
                )
                .appending(
                    path: ManagedWineProcessJournal.evidenceDirectoryName,
                    directoryHint: .isDirectory
                )
                .standardizedFileURL
            evidenceTrustedAncestor = groupContainer.standardizedFileURL
        } else {
            evidenceDirectory = logDirectory
                .appending(
                    path: ManagedWineProcessJournal.evidenceDirectoryName,
                    directoryHint: .isDirectory
                )
                .standardizedFileURL
            evidenceTrustedAncestor = logDirectory.standardizedFileURL
        }
        let priorSignalIdentities = verifiedManagedWineSignalIdentities
        let priorExcludedIdentities =
            excludedReusedManagedWineSignalIdentities
        do {
            try managedWineSessionRegistry.hydrate(
                from: evidenceDirectory,
                trustedAncestor: evidenceTrustedAncestor,
                for: prefix,
                runtimeRootURL: runtimeRootURL,
                runtimeFingerprint: runtimeFingerprint,
                fileManager: fileManager,
                validating: { launchSession in
                    _ = try self.validatedManagedWineProcessIDs(
                        for: launchSession
                    )
                }
            )
        } catch {
            verifiedManagedWineSignalIdentities = priorSignalIdentities
            excludedReusedManagedWineSignalIdentities =
                priorExcludedIdentities
            throw error
        }
    }

    private func registerManagedWineProcessLaunch(
        from spec: CommandSpec,
        prefix: URL?,
        registeredAt: Date,
        result: ProcessRunResult
    ) {
        guard let prefix,
              let launchSession = spec.managedWineLaunchSession,
              launchSession.prefixURL.standardizedFileURL ==
                prefix.standardizedFileURL,
              launchSession.registeredAt >=
                registeredAt.addingTimeInterval(-1),
              launchSession.registeredAt <=
                Date().addingTimeInterval(5) else {
            return
        }
        let evidenceAttributes = try? fileManager.attributesOfItem(
            atPath: launchSession.evidenceURL.path
        )
        let evidenceSize = (
            evidenceAttributes?[.size] as? NSNumber
        )?.int64Value ?? 0
        guard result.succeeded || evidenceSize > 0 else {
            return
        }
        managedWineSessionRegistry.record(launchSession)
    }

    /// A descriptor is written immediately before spawn so a detached child
    /// can never outrun host ownership persistence. If spawning fails before
    /// the curated Runtime writes even one journal row, remove the empty file
    /// and then its descriptor. Any identity or deletion ambiguity intentionally
    /// leaves the descriptor in place so a later cleanup fails closed.
    private func discardUnstartedManagedWineSessionArtifacts(
        from spec: CommandSpec
    ) {
        guard let launchSession = spec.managedWineLaunchSession,
              let descriptorURL = launchSession.descriptorURL else {
            return
        }
        let evidence: Data
        do {
            guard let loaded = try ManagedWineProcessJournal
                .readOwnerPrivateBoundedFile(
                    at: launchSession.evidenceURL,
                    maximumBytes: ManagedWineProcessJournal
                        .maximumProcessEvidenceBytes,
                    purpose: "unstarted managed Wine process"
                ) else {
                return
            }
            evidence = loaded
        } catch {
            return
        }
        guard evidence.isEmpty,
              let descriptor = try? ManagedWineProcessJournal
                .readActiveSessionDescriptor(at: descriptorURL),
              descriptor.runIdentifier == launchSession.runIdentifier,
              descriptor.evidenceFileName ==
                launchSession.evidenceURL.lastPathComponent,
              descriptor.prefixScope == launchSession.prefixScope,
              descriptor.runtimeFingerprint ==
                launchSession.runtimeFingerprint,
              descriptor.runtimeRootScope == ManagedWineProcessJournal
                .runtimeRootScope(for: launchSession.runtimeRootURL),
              descriptor.ownerProcessIdentifier == Darwin.getpid(),
              ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                for: Darwin.getpid()
              ) == descriptor.ownerProcessStartedAtUnixMicroseconds else {
            return
        }
        do {
            try fileManager.removeItem(at: launchSession.evidenceURL)
            try fileManager.removeItem(at: descriptorURL)
        } catch {
            // The descriptor is deliberately retained when possible; its
            // presence prevents unverified clean-prefix completion later.
        }
    }

    private func registeredManagedWineProcessTargets(
        for prefix: URL
    ) throws -> [ManagedProcessSignalTarget] {
        let launchSessions = managedWineSessionRegistry.launchSessions(
            for: prefix
        )
        guard !launchSessions.isEmpty else { return [] }

        let priorSignalIdentities = verifiedManagedWineSignalIdentities
        let priorExcludedIdentities =
            excludedReusedManagedWineSignalIdentities
        var processIDs = Set<pid_t>()
        do {
            for launchSession in launchSessions {
                processIDs.formUnion(
                    try validatedManagedWineProcessIDs(for: launchSession)
                )
            }
        } catch {
            verifiedManagedWineSignalIdentities = priorSignalIdentities
            excludedReusedManagedWineSignalIdentities =
                priorExcludedIdentities
            throw error
        }
        return try processIDs.sorted().map { pid in
            guard let verified = verifiedManagedWineSignalIdentities[pid],
                  verified.prefixPath == prefix.standardizedFileURL.path else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    prefix,
                    "validated managed Wine PID \(pid) has no retained exact signal identity"
                )
            }
            return ManagedProcessSignalTarget(
                processID: pid,
                processStartedAtUnixMicroseconds:
                    verified.processStartedAtUnixMicroseconds,
                executableURL: verified.executableURL,
                source: .managedWineJournal
            )
        }
    }

    private func validatedManagedWineProcessIDs(
        for launchSession: ManagedWineProcessLaunchSession
    ) throws -> [pid_t] {
        try managedWineProcessValidation(for: launchSession).processIDs
    }

    private func managedWineProcessValidation(
        for launchSession: ManagedWineProcessLaunchSession
    ) throws -> ManagedWineProcessValidationResult {
        guard let data = try ownerPrivateProcessEvidenceTail(
            at: launchSession.evidenceURL,
            purpose: "managed Wine process"
        ) else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                launchSession.evidenceURL,
                "managed Wine process evidence is missing"
            )
        }
        let candidates = Self.managedWineProcessEvidenceIdentities(
            in: data,
            launchSession: launchSession
        )
        guard !candidates.isEmpty else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                launchSession.evidenceURL,
                "the launched Wine session produced no valid Darwin PID evidence"
            )
        }

        let allowedExecutables = Self.allowedManagedWineExecutables(
            for: launchSession
        )
        var processIDs = Set<pid_t>()
        var inactiveReasons: [String] = []
        for candidate in candidates {
            // `waitid(..., WNOWAIT)` intentionally keeps an exited descriptor
            // root unreaped while its negative-PGID ownership is still
            // retained. Such a root can remain kernel-present even though
            // `proc_pidinfo` and `KERN_PROCARGS2` no longer expose live
            // identity. Only the exact in-memory tracker, prefix, PID, and
            // launch-time start capability may classify that one journal row
            // as exited. Every other unreadable-present PID remains
            // fail-closed below.
            if trackedUnreapedDescriptorLeaderMatches(
                candidate,
                launchSession: launchSession
            ) {
                verifiedManagedWineSignalIdentities.removeValue(
                    forKey: candidate.processID
                )
                excludedReusedManagedWineSignalIdentities.removeValue(
                    forKey: candidate.processID
                )
                inactiveReasons.append(
                    "PID \(candidate.processID) is the exact observed-unreaped descriptor leader"
                )
                continue
            }
            let liveIdentity = ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(
                    for: candidate.processID
                )
            switch liveIdentity {
            case .exited:
                verifiedManagedWineSignalIdentities.removeValue(
                    forKey: candidate.processID
                )
                excludedReusedManagedWineSignalIdentities.removeValue(
                    forKey: candidate.processID
                )
                inactiveReasons.append(
                    "PID \(candidate.processID) exited before validation"
                )
                continue
            case .unavailable:
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    launchSession.evidenceURL,
                    "could not verify Darwin PID start identity: \(candidate.processID)"
                )
            case .live:
                break
            }
            // Start identity is an exact kernel-published microsecond value.
            // Even a one-microsecond difference proves PID reuse; never signal
            // the replacement process.
            guard ManagedWineProcessJournal.isExactLiveProcessIdentity(
                liveIdentity,
                expectedStartTimeUnixMicroseconds:
                    candidate.processStartedAtUnixMicroseconds
            ) else {
                if case .live(let reusedStartTimeUnixMicroseconds) =
                    liveIdentity {
                    excludedReusedManagedWineSignalIdentities[
                        candidate.processID
                    ] = ExcludedReusedManagedWineSignalIdentity(
                        prefixPath: launchSession.prefixURL
                            .standardizedFileURL.path,
                        processStartedAtUnixMicroseconds:
                            reusedStartTimeUnixMicroseconds
                        )
                }
                inactiveReasons.append(
                    "PID \(candidate.processID) start identity no longer matches its journal row"
                )
                continue
            }
            // A previously excluded PID cannot become signal-authorized again
            // merely because a later observation happens to match an older
            // journal row. Only an explicit `.exited` observation above may
            // retire the exclusion and permit a future process identity.
            if excludedReusedManagedWineSignalIdentities[
                candidate.processID
            ] != nil {
                inactiveReasons.append(
                    "PID \(candidate.processID) remains covered by a PID-reuse exclusion"
                )
                continue
            }
            guard let command = try processCommand(
                for: candidate.processID
            ) else {
                let identityAfterMissingExecutable =
                    ManagedWineProcessJournal
                        .resolveProcessIdentityAcrossExitBoundary(
                            for: candidate.processID
                        )
                if case .exited = identityAfterMissingExecutable {
                    continue
                }
                throw SafeProcessRunnerError
                    .prefixProcessVerificationFailed(
                        launchSession.evidenceURL,
                        "Darwin PID \(candidate.processID) executable identity became unreadable while ownership remained live or ambiguous"
                    )
            }
            let commandURL = URL(fileURLWithPath: command)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard allowedExecutables.contains(commandURL) else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    launchSession.evidenceURL,
                    "Darwin PID \(candidate.processID) no longer has an exact ForgePlay Runtime executable identity"
                )
            }
            verifiedManagedWineSignalIdentities[candidate.processID] =
                VerifiedManagedWineSignalIdentity(
                    prefixPath: launchSession.prefixURL.standardizedFileURL.path,
                    processStartedAtUnixMicroseconds:
                        candidate.processStartedAtUnixMicroseconds,
                    executableURL: commandURL
                )
            processIDs.insert(candidate.processID)
        }
        return ManagedWineProcessValidationResult(
            processIDs: processIDs.sorted(),
            inactiveReasons: inactiveReasons
        )
    }

    private func trackedUnreapedDescriptorLeaderMatches(
        _ candidate: ManagedWineProcessEvidenceIdentity,
        launchSession: ManagedWineProcessLaunchSession
    ) -> Bool {
        guard let tracked = trackedDescriptorBoundProcesses[
            candidate.processID
        ] else {
            return false
        }
        // A successful WNOWAIT observation alone is insufficient once the
        // retained leader has been reaped, or a later reap failed. Only the
        // still-retained exact zombie can serve as a PID-reuse barrier for
        // journal validation.
        guard tracked.process.hasObservedUnreapedRootExit else {
            return false
        }
        return Self.exactUnreapedDescriptorLeaderMatchesJournalCandidate(
            candidateProcessID: candidate.processID,
            candidateProcessStartedAtUnixMicroseconds:
                candidate.processStartedAtUnixMicroseconds,
            candidatePrefixURL: launchSession.prefixURL,
            trackedProcessID: tracked.process.processIdentifier,
            trackedPrefixPath: tracked.prefixPath,
            retainedSignalCapability: tracked.signalCapability,
            rootWaitObservation: tracked.process.waitObservation,
            rootWasActuallyReaped:
                tracked.process.rootWasActuallyReaped
        )
    }

    nonisolated static func
        exactUnreapedDescriptorLeaderMatchesJournalCandidate(
            candidateProcessID: pid_t,
            candidateProcessStartedAtUnixMicroseconds: UInt64,
            candidatePrefixURL: URL,
            trackedProcessID: pid_t,
            trackedPrefixPath: String?,
            retainedSignalCapability: ManagedProcessSignalTarget?,
            rootWaitObservation: DescriptorBoundRootWaitObservation,
            rootWasActuallyReaped: Bool
        ) -> Bool {
        let candidatePrefixPath = candidatePrefixURL.standardizedFileURL.path
        guard rootWaitObservation.successfullyObservedTerminalState,
              !rootWasActuallyReaped,
              candidateProcessID > 1,
              trackedProcessID == candidateProcessID,
              trackedPrefixPath == candidatePrefixPath,
              let retainedSignalCapability,
              retainedSignalCapability.source ==
                .trackedDescriptorBoundProcess,
              retainedSignalCapability.processID == candidateProcessID,
              retainedSignalCapability
                .processStartedAtUnixMicroseconds ==
                candidateProcessStartedAtUnixMicroseconds else {
            return false
        }
        return true
    }

    nonisolated static func
        managedWineReadbackFailureIdentityDisposition(
            expectedStartTimeUnixMicroseconds: UInt64,
            identityAfterReadback:
                ManagedWineProcessJournal.ProcessIdentityResolution
        ) -> ManagedWineReadbackFailureIdentityDisposition {
        switch identityAfterReadback {
        case .exited:
            return .candidateExited
        case .live(let observedStartTimeUnixMicroseconds)
        where observedStartTimeUnixMicroseconds !=
            expectedStartTimeUnixMicroseconds:
            return .candidateWasReused(
                observedStartTimeUnixMicroseconds:
                    observedStartTimeUnixMicroseconds
            )
        case .live, .unavailable:
            return .failClosed
        }
    }

    nonisolated static func managedWineProcessEvidenceIDs(
        in data: Data,
        launchSession: ManagedWineProcessLaunchSession,
        observedAt: Date = Date()
    ) -> [pid_t] {
        managedWineProcessEvidenceIdentities(
            in: data,
            launchSession: launchSession,
            observedAt: observedAt
        ).map(\.processID)
    }

    private nonisolated static func managedWineProcessEvidenceIdentities(
        in data: Data,
        launchSession: ManagedWineProcessLaunchSession,
        observedAt: Date = Date()
    ) -> [ManagedWineProcessEvidenceIdentity] {
        let decoder = JSONDecoder()
        let acceptedRoles: Set<String> = ["wine-loader", "wineserver"]
        var startsByProcessID: [pid_t: UInt64] = [:]
        var evidenceIsAmbiguous = false
        for line in data.split(separator: 0x0A)
        where !line.isEmpty {
            guard line.count <= 2_048,
                  let record = try? decoder.decode(
                ManagedWineProcessEvidenceRecord.self,
                from: Data(line)
            ),
            record.schemaVersion == 1,
            record.producer == "forgeplay-wine-runtime",
            record.eventCode == "darwin_process_started",
            acceptedRoles.contains(record.role),
            record.runIdentifier.lowercased() ==
                launchSession.runIdentifier,
            record.prefixScope == launchSession.prefixScope,
            record.runtimeFingerprint == launchSession.runtimeFingerprint,
            record.darwinPID > 1,
            record.darwinPID != Darwin.getpid(),
            record.processStartedAtUnixMicroseconds > 0 else {
                evidenceIsAmbiguous = true
                continue
            }

            let recordedAt = Date(
                timeIntervalSince1970:
                    Double(record.recordedAtUnixMilliseconds) / 1_000
            )
            let processStartedAtUnixMicroseconds = UInt64(
                record.processStartedAtUnixMicroseconds
            )
            let processStartedAt = Date(
                timeIntervalSince1970:
                    Double(processStartedAtUnixMicroseconds) /
                        1_000_000
            )
            guard processStartedAt >=
                    launchSession.registeredAt.addingTimeInterval(-2),
                  processStartedAt <= recordedAt.addingTimeInterval(1),
                  recordedAt >=
                    launchSession.registeredAt.addingTimeInterval(-2),
                  recordedAt <= observedAt.addingTimeInterval(5) else {
                evidenceIsAmbiguous = true
                continue
            }
            let processID = pid_t(record.darwinPID)
            if let existing = startsByProcessID[processID],
               existing != processStartedAtUnixMicroseconds {
                evidenceIsAmbiguous = true
                continue
            }
            startsByProcessID[processID] =
                processStartedAtUnixMicroseconds
        }
        guard !evidenceIsAmbiguous else { return [] }
        return startsByProcessID
            .map {
                ManagedWineProcessEvidenceIdentity(
                    processID: $0.key,
                    processStartedAtUnixMicroseconds: $0.value
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    private nonisolated static func allowedManagedWineExecutables(
        for launchSession: ManagedWineProcessLaunchSession
    ) -> Set<URL> {
        let runtimeRoot = launchSession.runtimeRootURL.standardizedFileURL
        let paths = [
            runtimeRoot.appending(
                path: "bin/wine.bin",
                directoryHint: .notDirectory
            ),
            runtimeRoot.appending(
                path: "bin/wineserver.bin",
                directoryHint: .notDirectory
            ),
            runtimeRoot.appending(
                path: "lib/wine/x86_64-unix/wine",
                directoryHint: .notDirectory
            ),
            GameModeHostCapabilityInspector.bundledHostAppURL()
                .appending(
                    path: "Contents/MacOS/GameModeProcessHost",
                    directoryHint: .notDirectory
                )
        ]
        return Set(paths.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        })
    }

    private func registerGameModeHostLaunch(
        from spec: CommandSpec,
        prefix: URL?,
        registeredAt: Date
    ) {
        guard let prefix,
              spec.environment[GameModeHostEnvironment.enabledKey] == "1",
              let runIdentifier =
                spec.environment[GameModeHostEnvironment.runIdentifierKey],
              UUID(uuidString: runIdentifier) != nil,
              let evidencePath =
                spec.environment[GameModeHostEnvironment.evidenceFileKey],
              let executablePath =
                spec.environment[GameModeHostEnvironment.executableKey],
              evidencePath.hasPrefix("/"),
              executablePath.hasPrefix("/") else {
            return
        }
        gameModeHostLaunchRecords.insert(GameModeHostLaunchRecord(
            prefixPath: prefix.standardizedFileURL.path,
            runIdentifier: runIdentifier.lowercased(),
            evidenceURL: URL(fileURLWithPath: evidencePath).standardizedFileURL,
            executableURL: URL(fileURLWithPath: executablePath).standardizedFileURL,
            registeredAt: registeredAt
        ))
    }

    private func registeredGameModeHostProcessInspection(
        for prefix: URL
    ) throws -> ManagedPrefixProcessInspection {
        let prefixPath = prefix.standardizedFileURL.path
        let launchRecords = gameModeHostLaunchRecords.filter {
            $0.prefixPath == prefixPath
        }
        guard !launchRecords.isEmpty else {
            return ManagedPrefixProcessInspection(
                signalCapabilities: [],
                liveObstructions: []
            )
        }

        var evidenceByURL: [URL: Data] = [:]
        var targetsByPID: [pid_t: ManagedProcessSignalTarget] = [:]
        var obstructions: [ManagedProcessLiveObstruction] = []
        var conflictedPIDs = Set<pid_t>()
        for launchRecord in launchRecords {
            let data: Data
            if let cached = evidenceByURL[launchRecord.evidenceURL] {
                data = cached
            } else {
                guard let loaded = try ownerPrivateProcessEvidenceTail(
                    at: launchRecord.evidenceURL,
                    purpose: "Game Mode host"
                ) else {
                    // Enabling the Steam child route registers the future run
                    // before any game child exists. GameModeProcessHost creates
                    // this file and records its exact identity before it can
                    // acquire the prefix execution lease or enter Wine. A
                    // missing file therefore means the route was armed but no
                    // host reached the execution boundary for this run.
                    continue
                }
                evidenceByURL[launchRecord.evidenceURL] = loaded
                data = loaded
            }
            let candidates = Self.gameModeHostEvidenceProcessIdentities(
                in: data,
                runIdentifier: launchRecord.runIdentifier,
                registeredAt: launchRecord.registeredAt
            )
            // The evidence file is shared across Game Mode runs. No candidate
            // for this run is the normal state until Steam actually launches a
            // routed game child. Once a current-run candidate exists, the exact
            // PID/start/executable checks below remain mandatory and fail
            // closed on conflicts or unreadable identity.
            for candidate in candidates {
                if excludedReusedManagedWineSignalIdentities[
                    candidate.processID
                ]?.prefixPath == prefixPath {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "Game Mode PID is covered by a live reuse exclusion"
                    ))
                    continue
                }
                guard let expectedStart =
                        candidate.processStartedAtUnixMicroseconds else {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "legacy Game Mode evidence has no kernel start identity"
                    ))
                    continue
                }
                let firstIdentity = ManagedWineProcessJournal
                    .resolveProcessIdentityAcrossExitBoundary(
                        for: candidate.processID
                    )
                guard case .live(let firstObservedStart) = firstIdentity else {
                    if case .unavailable = firstIdentity {
                        obstructions.append(ManagedProcessLiveObstruction(
                            processID: candidate.processID,
                            reason: "Game Mode process start identity is unreadable"
                        ))
                    }
                    continue
                }
                guard firstObservedStart == expectedStart else {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "Game Mode PID was reused; journal and live start identities differ"
                    ))
                    continue
                }
                guard let executable = try processCommand(
                    for: candidate.processID
                ) else {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "Game Mode executable identity is unreadable"
                    ))
                    continue
                }
                let executableURL = URL(fileURLWithPath: executable)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard executableURL == launchRecord.executableURL
                    .resolvingSymlinksInPath() else {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "Game Mode executable differs from the registered host"
                    ))
                    continue
                }
                let finalIdentity = ManagedWineProcessJournal
                    .resolveProcessIdentityAcrossExitBoundary(
                        for: candidate.processID
                    )
                guard ManagedWineProcessJournal.isExactLiveProcessIdentity(
                    finalIdentity,
                    expectedStartTimeUnixMicroseconds: expectedStart
                ) else {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "Game Mode process identity changed during capability validation"
                    ))
                    continue
                }
                let target = ManagedProcessSignalTarget(
                        processID: candidate.processID,
                        processStartedAtUnixMicroseconds: expectedStart,
                        executableURL: executableURL,
                        source: .gameModeHostJournal
                    )
                guard !conflictedPIDs.contains(candidate.processID) else {
                    continue
                }
                if let existing = targetsByPID[candidate.processID],
                   Self.managedSignalCapabilityMergeDecision(
                    existing: existing,
                    candidate: target
                   ) == .obstruct {
                    targetsByPID.removeValue(forKey: candidate.processID)
                    conflictedPIDs.insert(candidate.processID)
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: candidate.processID,
                        reason: "Game Mode launch evidence conflicts on exact process identity"
                    ))
                } else {
                    targetsByPID[candidate.processID] = target
                }
            }
        }
        return ManagedPrefixProcessInspection(
            signalCapabilities: targetsByPID.values.sorted {
                $0.processID < $1.processID
            },
            liveObstructions: obstructions
        )
    }

    private func ownerPrivateProcessEvidenceTail(
        at url: URL,
        purpose: String
    ) throws -> Data? {
        try ManagedWineProcessJournal.readOwnerPrivateBoundedFile(
            at: url,
            maximumBytes: ManagedWineProcessJournal
                .maximumProcessEvidenceBytes,
            purpose: purpose
        )
    }

    nonisolated static func gameModeHostEvidenceProcessIDs(
        in data: Data,
        runIdentifier: String,
        registeredAt: Date,
        observedAt: Date = Date()
    ) -> [pid_t] {
        gameModeHostEvidenceProcessIdentities(
            in: data,
            runIdentifier: runIdentifier,
            registeredAt: registeredAt,
            observedAt: observedAt
        ).compactMap { identity in
            identity.processStartedAtUnixMicroseconds == nil
                ? nil
                : identity.processID
        }
    }

    private nonisolated static func gameModeHostEvidenceProcessIdentities(
        in data: Data,
        runIdentifier: String,
        registeredAt: Date,
        observedAt: Date = Date()
    ) -> [GameModeHostEvidenceProcessIdentity] {
        let acceptedEvents: Set<String> = [
            "inherited_execution_verified",
            "prefix_execution_lease_acquired",
            "wine_main_entered"
        ]
        let normalizedRunIdentifier = runIdentifier.lowercased()
        let decoder = JSONDecoder()
        var identitiesByProcessID:
            [pid_t: (startedAt: UInt64?, recordedAt: Date)] = [:]
        for line in data.split(separator: 0x0A) where !line.isEmpty && line.count <= 2_048 {
            guard let record = try? decoder.decode(
                GameModeHostEvidenceRecord.self,
                from: Data(line)
            ),
            record.schemaVersion == 1,
            record.producer == "game-mode-process-host",
            acceptedEvents.contains(record.eventCode),
            record.runIdentifier?.lowercased() == normalizedRunIdentifier,
            record.darwinPID > 1,
            record.darwinPID != Darwin.getpid() else {
                continue
            }
            let recordedAt = Date(
                timeIntervalSince1970:
                    Double(record.recordedAtUnixMilliseconds) / 1_000
            )
            guard recordedAt >= registeredAt.addingTimeInterval(-2),
                  recordedAt <= observedAt.addingTimeInterval(5) else {
                continue
            }
            let processID = pid_t(record.darwinPID)
            let decodedStart = record.processStartedAtUnixMicroseconds
                .flatMap { $0 > 0 ? $0 : nil }
            if let existing = identitiesByProcessID[processID] {
                identitiesByProcessID[processID] = (
                    existing.startedAt == decodedStart
                        ? existing.startedAt
                        : nil,
                    max(existing.recordedAt, recordedAt)
                )
            } else {
                identitiesByProcessID[processID] = (
                    decodedStart,
                    recordedAt
                )
            }
        }
        return identitiesByProcessID
            .map {
                GameModeHostEvidenceProcessIdentity(
                    processID: $0.key,
                    processStartedAtUnixMicroseconds:
                        $0.value.startedAt,
                    recordedAt: $0.value.recordedAt
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    private nonisolated static func processStartTimeUnixMicroseconds(
        for pid: pid_t
    ) -> UInt64? {
        ManagedWineProcessJournal.processStartTimeUnixMicroseconds(for: pid)
    }

    private nonisolated static func processStartDate(for pid: pid_t) -> Date? {
        guard let microseconds = processStartTimeUnixMicroseconds(
            for: pid
        ) else {
            return nil
        }
        return Date(
            timeIntervalSince1970:
                TimeInterval(microseconds) / 1_000_000
        )
    }

    private func managedPrefixActivityProcessIDs(under prefix: URL) throws -> [pid_t] {
        // The managed lifecycle journal carries exact Darwin PID/start
        // identities from Wine itself. Prefix activity is therefore answered
        // by that evidence, directly tracked Process objects, and (outside the
        // App Sandbox) the existing process-table/open-file fallback.
        let inspection = try managedProcessIDsHoldingOpenFiles(under: prefix)
        guard inspection.liveObstructions.isEmpty else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                prefix,
                inspection.obstructionSummary
            )
        }
        return inspection.signalCapabilities.map(\.processID)
    }

    private func managedInputBindingProcessIDs(
        under prefix: URL
    ) throws -> [pid_t] {
        try managedPrefixActivityProcessIDs(under: prefix).filter { processID in
            guard let command = try processCommand(for: processID) else {
                return false
            }
            return Self.isManagedWineInputBindingExecutable(command)
        }
    }

    private nonisolated static func isManagedWineInputBindingExecutable(
        _ command: String
    ) -> Bool {
        let executableName = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last?
            .lowercased()
        guard let executableName else { return false }
        return [
            "wine",
            "wine64",
            "wine.bin",
            "wine64.bin",
            "wine-preloader",
            "wine64-preloader"
        ].contains(executableName)
    }

    private func processLogsAreEmpty(_ result: ProcessRunResult) -> Bool {
        [result.stdoutLog, result.stderrLog].allSatisfy { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.int64Value == 0
        }
    }

    private func terminateAndReapDescriptorBoundOwnership(
        _ process: DescriptorBoundSpawnedProcess,
        signalCapability: ManagedProcessSignalTarget?
    ) -> Bool {
        if !process.hasTrackedOwnership {
            return true
        }

        guard Self.descriptorBoundSignalCapabilityAuthorizesOwnership(
            processID: process.processIdentifier,
            signalCapability: signalCapability
        ), let signalCapability else {
            return false
        }
        if process.isRunning {
            guard managedSignalTargetIsExactNow(signalCapability) else {
                return false
            }
        }

        if signalDescriptorBoundOwnership(process, signal: SIGTERM) != nil {
            return false
        }
        let terminationDeadline = Date().addingTimeInterval(1)
        while Date() < terminationDeadline {
            if !process.hasTrackedOwnership {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // The leader may have exited while a TERM-ignoring descendant keeps
        // the retained process group live. A still-running leader must pass
        // start/executable/start validation again immediately before KILL.
        if process.isRunning {
            guard managedSignalTargetIsExactNow(signalCapability) else {
                return false
            }
        }
        if signalDescriptorBoundOwnership(process, signal: SIGKILL) != nil {
            return false
        }

        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline {
            if !process.hasTrackedOwnership {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.hasTrackedOwnership
    }

    @discardableResult
    private func signalDescriptorBoundOwnership(
        _ process: DescriptorBoundSpawnedProcess,
        signal: Int32,
        allowExactLiveLeaderFallback: Bool = true
    ) -> Int32? {
        switch process.processGroupPresence {
        case .present, .indeterminate(_):
            let groupSignalResult = Darwin.kill(
                -process.processIdentifier,
                signal
            )
            if groupSignalResult == 0 { return nil }
            let groupError = errno
            if groupError == ESRCH, process.isRunning,
               allowExactLiveLeaderFallback {
                // A child can create a new session and leave the process
                // group it was assigned at spawn. The WNOWAIT leader is still
                // unreaped, so this exact PID cannot have been reused.
                if Darwin.kill(process.processIdentifier, signal) == 0 {
                    return nil
                }
                return errno
            }
            return groupError == ESRCH ? nil : groupError
        case .absent:
            // A child may move itself out of the group. Its unreaped leader is
            // still an exact task-owned PID and remains safe to signal.
            if process.isRunning, allowExactLiveLeaderFallback {
                if Darwin.kill(process.processIdentifier, signal) != 0 {
                    return errno == ESRCH ? nil : errno
                }
            }
            return nil
        }
    }

    private func reconcileManagedWineReadbackFailure(
        _ input: ProcessRunResult,
        spec: CommandSpec,
        error: Error
    ) -> ProcessRunResult {
        var result = input
        guard let processIdentifier = result.processIdentifier,
              processIdentifier > 0 else {
            result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                result.diagnosticCaptureWarning,
                "Managed Wine child readback failed after spawn, but the child PID was unavailable: " +
                    forgePlayTechnicalErrorSummary(error)
            )
            return result
        }

        var disposition =
            "the spawned child remains tracked with its actual PID"
        if let tracked = trackedDescriptorBoundProcesses[processIdentifier] {
            let fullyTerminated = terminateAndReapDescriptorBoundOwnership(
                tracked.process,
                signalCapability: tracked.signalCapability
            )
            if fullyTerminated {
                trackedDescriptorBoundProcesses.removeValue(
                    forKey: processIdentifier
                )
            }
            result = descriptorBoundResult(
                spec,
                process: tracked.process,
                startedAt: input.startedAt,
                didTimeOut: false
            )
            if fullyTerminated {
                disposition =
                    "the spawned process group was terminated and its leader was reaped"
            } else {
                // Observing leader exit with WNOWAIT is not equivalent to
                // reaping that leader or completing group ownership. Keep the
                // record live and project the residual group as a detached
                // outcome until group absence is proven.
                result.waitedForExit = false
                result.hasProcessExitCode = false
                result.outcome = .runningDetached
                disposition = Self
                    .descriptorBoundResidualOwnershipDiagnostic(
                        processGroupIdentifier: processIdentifier,
                        groupPresence: tracked.process
                            .processGroupPresence.diagnosticDescription,
                        leaderExitObserved:
                            tracked.process.rootExitWasObserved,
                        leaderWasActuallyReaped:
                            tracked.process.rootWasActuallyReaped
                    )
            }
        } else if let tracked = trackedDetachedProcesses[processIdentifier] {
            if tracked.process.isRunning,
               let capability = tracked.signalCapability {
                let termObstructions = sendSignal(
                    SIGTERM,
                    to: [capability],
                    for: URL(fileURLWithPath: tracked.prefixPath)
                )
                let terminationDeadline = Date().addingTimeInterval(1)
                while termObstructions.isEmpty,
                      tracked.process.isRunning,
                      Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if termObstructions.isEmpty, tracked.process.isRunning {
                    let killObstructions = sendSignal(
                        SIGKILL,
                        to: [capability],
                        for: URL(fileURLWithPath: tracked.prefixPath)
                    )
                    let killDeadline = Date().addingTimeInterval(2)
                    while killObstructions.isEmpty,
                          tracked.process.isRunning,
                          Date() < killDeadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            } else if tracked.process.isRunning {
                disposition = "the spawned child remains tracked because no exact launch-time signal capability is available"
            }
            if !tracked.process.isRunning {
                tracked.process.waitUntilExit()
                trackedDetachedProcesses.removeValue(
                    forKey: processIdentifier
                )
                result.endedAt = Date()
                result.waitedForExit = true
                result.hasProcessExitCode =
                    tracked.process.terminationReason == .exit
                result.exitCode = tracked.process.terminationStatus
                result.outcome = tracked.process.terminationReason ==
                    .uncaughtSignal ? .signaled : .exited
                result.terminationSignal = tracked.process.terminationReason ==
                    .uncaughtSignal
                    ? tracked.process.terminationStatus
                    : nil
                disposition = "the spawned child was terminated and reaped"
            }
        } else {
            disposition =
                "the spawned child's actual PID and outcome were preserved " +
                "because no in-memory tracker entry was available"
        }

        result.managedWineLaunchEnvironmentProjection =
            input.managedWineLaunchEnvironmentProjection

        let warning =
            "Managed Wine child synchronization readback failed after spawn; " +
            "\(disposition): " + forgePlayTechnicalErrorSummary(error)
        result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
            result.diagnosticCaptureWarning,
            warning
        )
        _ = appendDiagnosticLines(
            ["", "[ForgePlay] \(warning)"],
            to: result.stderrLog
        )
        return result
    }

    nonisolated static func descriptorBoundResidualOwnershipDiagnostic(
        processGroupIdentifier: pid_t,
        groupPresence: String,
        leaderExitObserved: Bool,
        leaderWasActuallyReaped: Bool
    ) -> String {
        "the spawned process group remains tracked " +
            "(pgid=\(processGroupIdentifier), group=\(groupPresence), " +
            "leaderExitObserved=\(leaderExitObserved), " +
            "leaderReaped=\(leaderWasActuallyReaped))"
    }

    func trackDetachedProcess(_ process: Process, for prefix: URL) {
        guard process.processIdentifier > 0, process.isRunning else { return }
        let capture = captureManagedSignalCapability(
            processID: process.processIdentifier,
            source: .trackedFoundationProcess,
            failureRoot: prefix
        )
        trackedDetachedProcesses[process.processIdentifier] = TrackedDetachedProcess(
            process: process,
            prefixPath: prefix.standardizedFileURL.path,
            signalCapability: capture.target,
            identityCaptureFailure: capture.failure
        )
    }

    private func trackedDetachedProcessInspection(
        for prefix: URL
    ) -> ManagedPrefixProcessInspection {
        pruneTrackedDetachedProcesses()
        let prefixPath = prefix.standardizedFileURL.path
        var targets: [ManagedProcessSignalTarget] = []
        var obstructions: [ManagedProcessLiveObstruction] = []
        for (pid, record) in trackedDetachedProcesses {
            guard record.prefixPath == prefixPath, record.process.isRunning else {
                continue
            }
            if let target = record.signalCapability {
                targets.append(target)
            } else {
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: record.identityCaptureFailure ??
                        "Foundation process has no launch-time exact signal capability"
                ))
            }
        }
        for (pid, record) in trackedDescriptorBoundProcesses {
            guard record.prefixPath == prefixPath,
                  record.process.hasTrackedOwnership else {
                continue
            }
            if let target = record.signalCapability {
                targets.append(target)
            } else {
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: record.identityCaptureFailure ??
                        "descriptor-bound process has no launch-time exact signal capability"
                ))
            }
        }
        return ManagedPrefixProcessInspection(
            signalCapabilities: targets.sorted { $0.processID < $1.processID },
            liveObstructions: obstructions
        )
    }

    private func pruneTrackedDetachedProcesses() {
        trackedDetachedProcesses = trackedDetachedProcesses.filter { _, record in
            record.process.isRunning
        }
        trackedDescriptorBoundProcesses =
            trackedDescriptorBoundProcesses.filter { _, record in
                record.process.hasTrackedOwnership
        }
    }

    private func captureManagedSignalCapability(
        processID: pid_t,
        source: ManagedProcessSignalOwnershipSource,
        failureRoot: URL
    ) -> (target: ManagedProcessSignalTarget?, failure: String?) {
        let startIdentity: UInt64
        switch ManagedWineProcessJournal
            .resolveProcessIdentityAcrossExitBoundary(for: processID) {
        case .live(let startedAtUnixMicroseconds):
            startIdentity = startedAtUnixMicroseconds
        case .exited:
            return (nil, "tracked process exited before launch identity capture")
        case .unavailable:
            return (
                nil,
                "could not bind tracked PID \(processID) to an exact start identity at launch (\(failureRoot.path))"
            )
        }
        let command: String
        do {
            guard let observedCommand = try processCommand(for: processID) else {
                return (nil, "tracked executable exited before launch identity capture")
            }
            command = observedCommand
        } catch {
            return (
                nil,
                "tracked executable identity was unreadable at launch: \(forgePlayTechnicalErrorSummary(error))"
            )
        }
        let finalIdentity = ManagedWineProcessJournal
            .resolveProcessIdentityAcrossExitBoundary(for: processID)
        guard ManagedWineProcessJournal.isExactLiveProcessIdentity(
            finalIdentity,
            expectedStartTimeUnixMicroseconds: startIdentity
        ) else {
            return (
                nil,
                "tracked PID identity changed while launch capability was captured"
            )
        }
        return (ManagedProcessSignalTarget(
            processID: processID,
            processStartedAtUnixMicroseconds: startIdentity,
            executableURL: URL(fileURLWithPath: command)
                .standardizedFileURL
                .resolvingSymlinksInPath(),
            source: source
        ), nil)
    }

    private func managedSignalTargetIsExactNow(
        _ target: ManagedProcessSignalTarget
    ) -> Bool {
        guard case .live(let firstStartedAt) = ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(
                    for: target.processID
                ) else {
            return false
        }
        let executable: String
        do {
            guard let observed = try processCommand(for: target.processID)
            else { return false }
            executable = observed
        } catch {
            return false
        }
        let finalIdentity = ManagedWineProcessJournal
            .resolveProcessIdentityAcrossExitBoundary(for: target.processID)
        let finalStartedAt: UInt64?
        if case .live(let observed) = finalIdentity {
            finalStartedAt = observed
        } else {
            finalStartedAt = nil
        }
        return Self.managedSignalTargetPassesFinalValidation(
            target,
            firstObservedStartTimeUnixMicroseconds: firstStartedAt,
            observedExecutableURL: URL(fileURLWithPath: executable),
            finalObservedStartTimeUnixMicroseconds: finalStartedAt
        )
    }

    private func processCommand(for pid: pid_t) throws -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            if errno == ESRCH {
                return nil
            }
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                URL(fileURLWithPath: "PID-\(pid)"),
                String(cString: strerror(errno))
            )
        }
        let executableBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executablePath = String(decoding: executableBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return executablePath.isEmpty ? nil : executablePath
    }

    private func processIDsHoldingOpenFiles(under prefix: URL) throws -> [pid_t] {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard fileManager.isExecutableFile(atPath: lsof.path) else {
            throw SafeProcessRunnerError.executableMissing(lsof)
        }
        let capture = try BoundedProcessExecutor.capture(
            executable: lsof,
            arguments: ["-t", "+D", prefix.path],
            timeout: 10,
            fileManager: fileManager
        )
        guard capture.didExit else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                prefix,
                "lsof did not exit before the prefix inspection deadline"
            )
        }
        let output = capture.stdout
        let errorOutput = capture.stderr
        let currentPID = Darwin.getpid()
        let pids = String(data: output, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 && $0 != currentPID } ?? []
        if !pids.isEmpty {
            return pids
        }
        if capture.exitCode == 1, output.isEmpty, errorOutput.isEmpty {
            return []
        }
        if capture.exitCode != 0 {
            let message = String(data: errorOutput, encoding: .utf8) ??
                String(data: output, encoding: .utf8) ??
                "lsof exited with \(capture.exitCode)"
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(prefix, message)
        }
        return []
    }

    private func exitedDescriptorBoundGroupSignalObstruction(
        signal: Int32,
        target: ManagedProcessSignalTarget,
        retainedProcess: DescriptorBoundSpawnedProcess,
        retainedSignalCapability: ManagedProcessSignalTarget?
    ) -> ManagedProcessLiveObstruction? {
        let hasTrackedOwnership = retainedProcess.hasTrackedOwnership
        guard Self.exitedDescriptorBoundGroupSignalIsAuthorized(
            processID: target.processID,
            signalCapability: target,
            retainedSignalCapability: retainedSignalCapability,
            leaderExitObserved: true,
            hasTrackedOwnership: hasTrackedOwnership
        ) else {
            // Group absence means the exact retained ownership has ended; it
            // is not authority for any signal and requires no cleanup signal.
            return nil
        }
        let signalError = signalDescriptorBoundOwnership(
            retainedProcess,
            signal: signal,
            allowExactLiveLeaderFallback: false
        )
        guard let signalError, signalError != ESRCH else { return nil }
        return ManagedProcessLiveObstruction(
            processID: target.processID,
            reason: "signal failed with errno \(signalError); ownership remains live"
        )
    }

    private func sendSignal(
        _ signal: Int32,
        to targets: [ManagedProcessSignalTarget],
        for prefix: URL
    ) -> [ManagedProcessLiveObstruction] {
        let prefixPath = prefix.standardizedFileURL.path
        var handled = Set<pid_t>()
        var obstructions: [ManagedProcessLiveObstruction] = []
        for target in targets where target.processID > 0 &&
            target.processID != Darwin.getpid() &&
            handled.insert(target.processID).inserted {
            let pid = target.processID
            let retainedDescriptorProcess: DescriptorBoundSpawnedProcess?
            if target.source == .trackedDescriptorBoundProcess {
                guard let tracked = trackedDescriptorBoundProcesses[pid],
                      Self
                        .retainedDescriptorBoundSignalCapabilityAuthorizesOwnership(
                            processID: pid,
                            signalCapability: target,
                            retainedSignalCapability:
                                tracked.signalCapability
                        ) else {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: pid,
                        reason: "retained tracker/capability is missing or conflicting; no raw fallback signal was sent"
                    ))
                    continue
                }
                retainedDescriptorProcess = tracked.process
                if !tracked.process.isRunning {
                    if let obstruction =
                        exitedDescriptorBoundGroupSignalObstruction(
                            signal: signal,
                            target: target,
                            retainedProcess: tracked.process,
                            retainedSignalCapability:
                                tracked.signalCapability
                        ) {
                        obstructions.append(obstruction)
                    }
                    continue
                }
            } else {
                retainedDescriptorProcess = nil
            }
            let identityBeforeExecutable = ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(for: pid)
            guard case .live(let currentStartedAt) =
                    identityBeforeExecutable else {
                if case .exited = identityBeforeExecutable,
                   let retainedDescriptorProcess,
                   let retainedSignalCapability =
                    trackedDescriptorBoundProcesses[pid]?
                        .signalCapability {
                    if let obstruction =
                        exitedDescriptorBoundGroupSignalObstruction(
                            signal: signal,
                            target: target,
                            retainedProcess: retainedDescriptorProcess,
                            retainedSignalCapability:
                                retainedSignalCapability
                        ) {
                        obstructions.append(obstruction)
                    }
                } else if case .unavailable = identityBeforeExecutable {
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: pid,
                        reason: "final process start identity is unreadable; no signal was sent"
                    ))
                }
                continue
            }
            let executable: String
            do {
                guard let currentExecutable = try processCommand(for: pid) else {
                    let identityAfterMissingExecutable = ManagedWineProcessJournal
                        .resolveProcessIdentityAcrossExitBoundary(for: pid)
                    if case .exited = identityAfterMissingExecutable {
                        if let retainedDescriptorProcess,
                           let retainedSignalCapability =
                            trackedDescriptorBoundProcesses[pid]?
                                .signalCapability,
                           let obstruction =
                            exitedDescriptorBoundGroupSignalObstruction(
                                signal: signal,
                                target: target,
                                retainedProcess: retainedDescriptorProcess,
                                retainedSignalCapability:
                                    retainedSignalCapability
                            ) {
                            obstructions.append(obstruction)
                        }
                        continue
                    }
                    obstructions.append(ManagedProcessLiveObstruction(
                        processID: pid,
                        reason: "final executable identity is unreadable; no signal was sent"
                    ))
                    continue
                }
                executable = currentExecutable
            } catch {
                let identityAfterExecutableError = ManagedWineProcessJournal
                    .resolveProcessIdentityAcrossExitBoundary(for: pid)
                if case .exited = identityAfterExecutableError,
                   let retainedDescriptorProcess,
                   let retainedSignalCapability =
                    trackedDescriptorBoundProcesses[pid]?
                        .signalCapability {
                    if let obstruction =
                        exitedDescriptorBoundGroupSignalObstruction(
                            signal: signal,
                            target: target,
                            retainedProcess: retainedDescriptorProcess,
                            retainedSignalCapability:
                                retainedSignalCapability
                        ) {
                        obstructions.append(obstruction)
                    }
                    continue
                }
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "final executable identity read failed; no signal was sent: \(forgePlayTechnicalErrorSummary(error))"
                ))
                continue
            }
            let executableURL = URL(fileURLWithPath: executable)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let identityAfterExecutable = ManagedWineProcessJournal
                .resolveProcessIdentityAcrossExitBoundary(for: pid)
            if case .exited = identityAfterExecutable,
               let retainedDescriptorProcess,
               let retainedSignalCapability =
                trackedDescriptorBoundProcesses[pid]?
                    .signalCapability {
                if let obstruction =
                    exitedDescriptorBoundGroupSignalObstruction(
                        signal: signal,
                        target: target,
                        retainedProcess: retainedDescriptorProcess,
                        retainedSignalCapability:
                            retainedSignalCapability
                    ) {
                    obstructions.append(obstruction)
                }
                continue
            }
            let finalStartedAt: UInt64?
            if case .live(let observed) = identityAfterExecutable {
                finalStartedAt = observed
            } else {
                finalStartedAt = nil
            }
            guard Self.managedSignalTargetPassesFinalValidation(
                    target,
                    firstObservedStartTimeUnixMicroseconds:
                        currentStartedAt,
                    observedExecutableURL: executableURL,
                    finalObservedStartTimeUnixMicroseconds: finalStartedAt
                  ) else {
                if case .live(let replacementStartedAt) =
                    identityAfterExecutable {
                    excludedReusedManagedWineSignalIdentities[pid] =
                        ExcludedReusedManagedWineSignalIdentity(
                            prefixPath: prefixPath,
                            processStartedAtUnixMicroseconds:
                                replacementStartedAt
                        )
                }
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "final start/executable/start identity revalidation failed; no signal was sent"
                ))
                continue
            }
            let retainedTrackerMatches: Bool
            switch target.source {
            case .trackedDescriptorBoundProcess:
                retainedTrackerMatches =
                    trackedDescriptorBoundProcesses[pid]?
                        .signalCapability == target
            case .trackedFoundationProcess:
                retainedTrackerMatches = trackedDetachedProcesses[pid]?
                    .signalCapability == target
            case .managedWineJournal, .gameModeHostJournal:
                retainedTrackerMatches = false
            }
            if Self.managedSignalSourceRequiresRetainedTracker(
                target.source
            ), !retainedTrackerMatches {
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "retained tracker/capability is missing or conflicting; no raw fallback signal was sent"
                ))
                continue
            }
            let signalError: Int32?
            switch target.source {
            case .trackedDescriptorBoundProcess:
                guard let tracked = trackedDescriptorBoundProcesses[pid]
                else { continue }
                signalError = signalDescriptorBoundOwnership(
                    tracked.process,
                    signal: signal
                )
            case .trackedFoundationProcess:
                signalError = Darwin.kill(pid, signal) == 0 ? nil : errno
            case .managedWineJournal, .gameModeHostJournal:
                signalError = Darwin.kill(pid, signal) == 0 ? nil : errno
            }
            if let signalError, signalError != ESRCH {
                obstructions.append(ManagedProcessLiveObstruction(
                    processID: pid,
                    reason: "signal failed with errno \(signalError); ownership remains live"
                ))
            }
        }
        return obstructions
    }

    nonisolated static func managedSignalTargetRemainsExact(
        _ target: ManagedProcessSignalTarget,
        observedStartTimeUnixMicroseconds: UInt64,
        observedExecutableURL: URL
    ) -> Bool {
        target.processStartedAtUnixMicroseconds ==
            observedStartTimeUnixMicroseconds &&
            target.executableURL.standardizedFileURL
                .resolvingSymlinksInPath() ==
            observedExecutableURL.standardizedFileURL
                .resolvingSymlinksInPath()
    }

    nonisolated static func managedSignalTargetPassesFinalValidation(
        _ target: ManagedProcessSignalTarget,
        firstObservedStartTimeUnixMicroseconds: UInt64?,
        observedExecutableURL: URL?,
        finalObservedStartTimeUnixMicroseconds: UInt64?
    ) -> Bool {
        guard let firstObservedStartTimeUnixMicroseconds,
              let observedExecutableURL,
              let finalObservedStartTimeUnixMicroseconds,
              firstObservedStartTimeUnixMicroseconds ==
                finalObservedStartTimeUnixMicroseconds,
              target.processStartedAtUnixMicroseconds ==
                firstObservedStartTimeUnixMicroseconds else {
            return false
        }
        if target.source == .trackedDescriptorBoundProcess {
            // `RuntimeLaunchObjectIdentity` starts an authenticated shell
            // script through /bin/sh. Modern macOS implements /bin/sh as a
            // shim that execs its shell variant, and the runtime launcher then
            // execs the authenticated Wine loader. Those execs do not change
            // the process instance or its task-owned process group. The
            // retained WNOWAIT tracker prevents PID reuse until the leader is
            // reaped; the exact start -> executable -> same-start observation
            // therefore remains the signal authority for this source.
            return observedExecutableURL.isFileURL &&
                observedExecutableURL.path.hasPrefix("/")
        }
        return managedSignalTargetRemainsExact(
            target,
            observedStartTimeUnixMicroseconds:
                firstObservedStartTimeUnixMicroseconds,
            observedExecutableURL: observedExecutableURL
        )
    }

    nonisolated static func managedSignalCapabilityMergeDecision(
        existing: ManagedProcessSignalTarget,
        candidate: ManagedProcessSignalTarget
    ) -> ManagedSignalCapabilityMergeDecision {
        guard existing.processID == candidate.processID,
              existing.processStartedAtUnixMicroseconds ==
                candidate.processStartedAtUnixMicroseconds,
              existing.executableURL.standardizedFileURL
                .resolvingSymlinksInPath() ==
                candidate.executableURL.standardizedFileURL
                .resolvingSymlinksInPath() else {
            return .obstruct
        }
        return managedSignalSourceStrength(candidate.source) >
            managedSignalSourceStrength(existing.source)
            ? .replaceExisting
            : .keepExisting
    }

    nonisolated static func managedSignalSourceRequiresRetainedTracker(
        _ source: ManagedProcessSignalOwnershipSource
    ) -> Bool {
        switch source {
        case .trackedFoundationProcess, .trackedDescriptorBoundProcess:
            true
        case .managedWineJournal, .gameModeHostJournal:
            false
        }
    }

    nonisolated static func descriptorBoundSignalCapabilityAuthorizesOwnership(
        processID: pid_t,
        signalCapability: ManagedProcessSignalTarget?
    ) -> Bool {
        guard processID > 0,
              let signalCapability,
              signalCapability.processID == processID,
              signalCapability.processStartedAtUnixMicroseconds > 0,
              signalCapability.executableURL.path.hasPrefix("/"),
              signalCapability.source == .trackedDescriptorBoundProcess else {
            return false
        }
        return true
    }

    nonisolated static func retainedDescriptorBoundSignalCapabilityAuthorizesOwnership(
        processID: pid_t,
        signalCapability: ManagedProcessSignalTarget?,
        retainedSignalCapability: ManagedProcessSignalTarget?
    ) -> Bool {
        descriptorBoundSignalCapabilityAuthorizesOwnership(
            processID: processID,
            signalCapability: signalCapability
        ) && signalCapability == retainedSignalCapability
    }

    nonisolated static func exitedDescriptorBoundGroupSignalIsAuthorized(
        processID: pid_t,
        signalCapability: ManagedProcessSignalTarget?,
        retainedSignalCapability: ManagedProcessSignalTarget?,
        leaderExitObserved: Bool,
        hasTrackedOwnership: Bool
    ) -> Bool {
        leaderExitObserved && hasTrackedOwnership &&
            retainedDescriptorBoundSignalCapabilityAuthorizesOwnership(
                processID: processID,
                signalCapability: signalCapability,
                retainedSignalCapability: retainedSignalCapability
            )
    }

    nonisolated static func managedSignalExclusionMayBeRetired(
        after resolution: ManagedWineProcessJournal.ProcessIdentityResolution
    ) -> Bool {
        if case .exited = resolution { return true }
        return false
    }

    private nonisolated static func managedSignalSourceStrength(
        _ source: ManagedProcessSignalOwnershipSource
    ) -> Int {
        switch source {
        case .trackedDescriptorBoundProcess:
            4
        case .trackedFoundationProcess:
            3
        case .managedWineJournal:
            2
        case .gameModeHostJournal:
            1
        }
    }

    private func persistProcessEvidence(
        _ input: ProcessRunResult,
        spec: CommandSpec
    ) -> ProcessRunResult {
        var result = input
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: spec.stderrLog)
        appendSyntheticProcessSummaryIfNeeded(
            for: result,
            spec: spec,
            evidenceURL: evidenceURL
        )
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: spec.stderrLog),
            actionName: spec.actionName,
            executable: spec.executable.path,
            arguments: spec.arguments,
            environmentOverrides: spec.environment,
            runtimeCompatibility: spec.runtimeCompatibility.isEmpty
                ? nil
                : spec.runtimeCompatibility,
            workingDirectory: spec.workingDirectory?.path,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            durationMilliseconds: Int64(max(0, result.endedAt.timeIntervalSince(result.startedAt) * 1_000)),
            outcome: result.outcome,
            exitCode: result.processExitCode,
            forgePlayStatusCode: result.forgePlayStatusCode,
            relatedRunEvidenceLogs: result.relatedRunEvidenceLogs.map(\.path),
            terminationSignal: result.terminationSignal,
            rawWaitStatus: result.rawWaitStatus,
            didTimeOut: result.didTimeOut,
            waitedForExit: result.waitedForExit,
            processIdentifier: result.processIdentifier,
            stdoutLog: result.stdoutLog.path,
            stderrLog: result.stderrLog.path,
            processObservationLog: result.processObservationLog?.path,
            finalizedAt: spec.actionName == "launchSteam" ? nil : Date(),
            activityLeaseExpiresAt: Self.evidenceActivityLeaseExpiration(
                for: result,
                relativeTo: result.endedAt
            ),
            diagnosticLog: result.diagnosticLog?.path,
            evidenceCaptureWarning: result.evidenceCaptureWarning,
            diagnosticCaptureWarning: result.diagnosticCaptureWarning,
            postconditionSatisfied: result.postconditionSatisfied,
            captureError: nil
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
        } catch {
            let warning = "Process evidence metadata could not be written: \(forgePlayTechnicalErrorSummary(error))"
            result.runEvidenceLog = nil
            result.evidenceCaptureWarning = DiagnosticWarningText.combined(
                result.evidenceCaptureWarning,
                warning
            )
            _ = appendDiagnosticLines(["", "[ForgePlay] \(warning)"], to: result.stderrLog)
        }
        return result
    }

    /// Some tools, including wineserver, legitimately emit no text while they
    /// are stuck or killed. Never leave the human-facing failure log empty when
    /// ForgePlay already has the decisive process metadata.
    private func appendSyntheticProcessSummaryIfNeeded(
        for result: ProcessRunResult,
        spec: CommandSpec,
        evidenceURL: URL
    ) {
        let needsSummary = result.didTimeOut || (!result.succeeded && processLogsAreEmpty(result))
        guard needsSummary, diagnosticLogIsEmpty(result.stderrLog) else { return }

        let durationMilliseconds = Int64(
            max(0, result.endedAt.timeIntervalSince(result.startedAt) * 1_000)
        )
        let timeoutDescription = spec.timeout.map {
            String(format: "%.3f seconds", $0)
        } ?? "none"
        let prefixDescription = spec.environment["WINEPREFIX"] ?? "not set"
        _ = appendDiagnosticLines([
            "[ForgePlay] Process execution summary",
            "[ForgePlay] Action: \(result.actionName)",
            "[ForgePlay] Executable: \(result.executable.path)",
            "[ForgePlay] Process ID: \(result.processIdentifier.map(String.init) ?? "unavailable")",
            "[ForgePlay] Configured timeout: \(timeoutDescription)",
            "[ForgePlay] Duration: \(durationMilliseconds) ms",
            "[ForgePlay] Outcome: \(result.outcome.rawValue)",
            "[ForgePlay] Process exit: \(result.diagnosticExitCodeDescription)",
            "[ForgePlay] ForgePlay status: \(result.diagnosticForgePlayStatusDescription)",
            "[ForgePlay] Timed out: \(result.didTimeOut)",
            "[ForgePlay] Termination signal: \(result.diagnosticTerminationSignalDescription)",
            "[ForgePlay] Raw wait status: \(result.rawWaitStatus.map(String.init) ?? "unavailable")",
            "[ForgePlay] Waited for exit: \(result.waitedForExit)",
            "[ForgePlay] Working directory: \(spec.workingDirectory?.path ?? "not set")",
            "[ForgePlay] WINEPREFIX: \(prefixDescription)",
            "[ForgePlay] Standard output: \(result.stdoutLog.path)",
            "[ForgePlay] Structured run evidence: \(evidenceURL.path)"
        ], to: result.stderrLog)
    }

    private func diagnosticLogIsEmpty(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == 0
    }

    private func processEvidenceFinalizationFailure(
        _ input: ProcessRunResult,
        error: Error
    ) -> ProcessRunResult {
        var result = input
        let warning = "Process evidence metadata could not be finalized: " +
            forgePlayTechnicalErrorSummary(error)
        result.evidenceCaptureWarning = DiagnosticWarningText.combined(
            result.evidenceCaptureWarning,
            warning
        )
        _ = appendDiagnosticLines(["", "[ForgePlay] \(warning)"], to: result.stderrLog)
        return result
    }

    private nonisolated static func evidenceActivityLeaseExpiration(
        for result: ProcessRunResult,
        relativeTo referenceDate: Date
    ) -> Date? {
        switch result.outcome {
        case .runningDetached, .unknown:
            return referenceDate.addingTimeInterval(
                ProcessRunEvidenceDocument.defaultActivityLeaseDuration
            )
        case .exited, .signaled, .timedOut:
            return result.waitedForExit
                ? nil
                : referenceDate.addingTimeInterval(
                    ProcessRunEvidenceDocument.defaultActivityLeaseDuration
                )
        case .preflightFailed, .spawnFailed:
            return nil
        }
    }

    @discardableResult
    private func persistActionPreparationFailureEvidence(
        action: RunnerAction,
        startedAt: Date,
        error: Error
    ) -> ProcessRunResult? {
        let logs = Self.logPair(
            in: action.diagnosticLogDirectoryURL,
            name: "\(action.capabilityActionName)_preflight"
        )
        do {
            let stdout = try Self.openLogFileHandle(at: logs.stdout, fileManager: fileManager)
            try stdout.close()
            let stderr = try Self.openLogFileHandle(at: logs.stderr, fileManager: fileManager)
            try stderr.close()
        } catch {
            return nil
        }

        let endedAt = Date()
        let summary = forgePlayTechnicalErrorSummary(error)
        let bridgedError = error as NSError
        let runtimeCompatibility = Self
            .actionPreparationRuntimeCompatibility(for: error)
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: logs.stderr)
        var result = ProcessRunResult(
            actionName: "\(action.capabilityActionName):preflight",
            executable: action.windowsRuntimeExecutableURL ?? URL(fileURLWithPath: "/<unresolved>"),
            arguments: [],
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: 1,
            hasProcessExitCode: false,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .preflightFailed
        )
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: logs.stderr),
            actionName: result.actionName,
            executable: action.windowsRuntimeExecutableURL?.path ?? "unresolved",
            arguments: [],
            environmentOverrides: [:],
            runtimeCompatibility: runtimeCompatibility,
            workingDirectory: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: Int64(max(0, endedAt.timeIntervalSince(startedAt) * 1_000)),
            outcome: .preflightFailed,
            exitCode: nil,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: nil,
            stdoutLog: logs.stdout.path,
            stderrLog: logs.stderr.path,
            processObservationLog: nil,
            captureError: "Action preparation failed before a command could start: \(summary)",
            failureDomain: bridgedError.domain,
            failureCode: bridgedError.code
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
            _ = appendDiagnosticLines(
                ["[ForgePlay] Action preparation failed before a command could start: \(summary)",
                 "[ForgePlay] Structured failure evidence: \(evidenceURL.path)"],
                to: logs.stderr
            )
            return result
        } catch {
            let warning = "Structured failure evidence could not be written: \(forgePlayTechnicalErrorSummary(error))"
            result.evidenceCaptureWarning = warning
            _ = appendDiagnosticLines(
                ["[ForgePlay] Action preparation failed before a command could start: \(summary)",
                 "[ForgePlay] \(warning)"],
                to: logs.stderr
            )
            return result
        }
    }

    @discardableResult
    private func persistSpawnFailureEvidence(
        spec: CommandSpec,
        startedAt: Date,
        error: Error
    ) -> ProcessRunResult? {
        guard ensureDiagnosticLogExists(spec.stdoutLog),
              ensureDiagnosticLogExists(spec.stderrLog) else {
            return nil
        }
        let endedAt = Date()
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: spec.stderrLog)
        let summary = forgePlayTechnicalErrorSummary(error)
        let bridgedError = error as NSError
        var result = ProcessRunResult(
            actionName: spec.actionName,
            executable: spec.executable,
            arguments: spec.arguments,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: 1,
            hasProcessExitCode: false,
            stdoutLog: spec.stdoutLog,
            stderrLog: spec.stderrLog,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .spawnFailed,
            processObservationLog: spec.processObservationLog
        )
        result = Self.applyingPreparationDiagnostics(from: spec, to: result)
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: spec.stderrLog),
            actionName: spec.actionName,
            executable: spec.executable.path,
            arguments: spec.arguments,
            environmentOverrides: spec.environment,
            runtimeCompatibility: spec.runtimeCompatibility.isEmpty
                ? nil
                : spec.runtimeCompatibility,
            workingDirectory: spec.workingDirectory?.path,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: Int64(max(0, endedAt.timeIntervalSince(startedAt) * 1_000)),
            outcome: .spawnFailed,
            exitCode: nil,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: nil,
            stdoutLog: spec.stdoutLog.path,
            stderrLog: spec.stderrLog.path,
            processObservationLog: spec.processObservationLog?.path,
            diagnosticCaptureWarning: result.diagnosticCaptureWarning,
            captureError: summary,
            failureDomain: bridgedError.domain,
            failureCode: bridgedError.code
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
            _ = appendDiagnosticLines(
                ["[ForgePlay] Process start failed before a result was produced: \(summary)",
                 "[ForgePlay] Structured failure evidence: \(evidenceURL.path)"],
                to: spec.stderrLog
            )
            return result
        } catch {
            let warning = "Structured failure evidence could not be written: \(forgePlayTechnicalErrorSummary(error))"
            result.evidenceCaptureWarning = warning
            _ = appendDiagnosticLines(
                ["[ForgePlay] Process start failed before a result was produced: \(summary)",
                 "[ForgePlay] \(warning)"],
                to: spec.stderrLog
            )
            return result
        }
    }

    private func ensureDiagnosticLogExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            do {
                try Self.requireNonSymlinkDirectory(
                    url.deletingLastPathComponent(),
                    fileManager: fileManager,
                    unsafeError: SafeProcessRunnerError.cannotCreateLog
                )
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
                return true
            } catch {
                return false
            }
        }
        do {
            let handle = try Self.openLogFileHandle(at: url, fileManager: fileManager)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func appendDiagnosticLines(_ lines: [String], to url: URL) -> Bool {
        guard !lines.isEmpty else {
            return false
        }
        do {
            try Self.requireNonSymlinkDirectory(
                url.deletingLastPathComponent(),
                fileManager: fileManager,
                unsafeError: SafeProcessRunnerError.cannotCreateLog
            )
        } catch {
            return false
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        do {
            try Self.validateOpenedLogDescriptor(descriptor, url: url)
        } catch {
            Darwin.close(descriptor)
            return false
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.joined(separator: "\n").utf8))
            try handle.write(contentsOf: Data("\n".utf8))
            return true
        } catch {
            return false
        }
    }

    nonisolated static func openLogFileHandle(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> FileHandle {
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(url)
        }
        try requireNonSymlinkDirectory(directory, fileManager: fileManager) { _ in
            SafeProcessRunnerError.cannotCreateLog(url)
        }

        for _ in 0..<2 {
            if fileManager.fileExists(atPath: url.path) {
                guard existingLogFileIsSafe(url) else {
                    throw SafeProcessRunnerError.cannotCreateLog(url)
                }
                let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    throw SafeProcessRunnerError.cannotCreateLog(url)
                }
                do {
                    try validateOpenedLogDescriptor(descriptor, url: url)
                    guard ftruncate(descriptor, 0) == 0 else {
                        Darwin.close(descriptor)
                        throw SafeProcessRunnerError.cannotCreateLog(url)
                    }
                    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }

            let descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            if descriptor >= 0 {
                do {
                    try validateOpenedLogDescriptor(descriptor, url: url)
                    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
            if errno == EEXIST {
                continue
            }
            throw SafeProcessRunnerError.cannotCreateLog(url)
        }
        throw SafeProcessRunnerError.cannotCreateLog(url)
    }

    nonisolated static func validateSupportArchivePaths(
        sourceDirectory: URL,
        destinationZip: URL,
        fileManager: FileManager = .default
    ) throws {
        try requireNonSymlinkDirectory(sourceDirectory, fileManager: fileManager, unsafeError: SafeProcessRunnerError.unsafeArchivePath)
        guard destinationZip.pathExtension.lowercased() == "zip" else {
            throw SafeProcessRunnerError.unsafeArchivePath(destinationZip)
        }
        let destinationDirectory = destinationZip.deletingLastPathComponent()
        try requireNonSymlinkDirectory(destinationDirectory, fileManager: fileManager, unsafeError: SafeProcessRunnerError.unsafeArchivePath)
        guard !fileManager.fileExists(atPath: destinationZip.path) else {
            throw SafeProcessRunnerError.unsafeArchivePath(destinationZip)
        }
    }

    private nonisolated static func existingLogFileIsSafe(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink <= 1
    }

    private nonisolated static func validateOpenedLogDescriptor(_ descriptor: Int32, url: URL) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink <= 1 else {
            throw SafeProcessRunnerError.cannotCreateLog(url)
        }
    }

    /// Builds the exact action command without spawning it. Kept internal so
    /// boundary tests can prove launch admission snapshots ambient AVX policy
    /// once while cleanup/control actions never consult it.
    func commandSpec(for action: RunnerAction) throws -> CommandSpec {
        switch action {
        case .initializePrefix(let runtimeExecutable, let prefix, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "prefix_initialize")
            return CommandSpec(
                actionName: "initializePrefix",
                executable: runtimeExecutable,
                arguments: ["wineboot", "-u"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: [
                        "WINEPREFIX": prefix.path,
                        "WINEARCH": WinePrefixDefaults.architecture,
                        "WINEDLLOVERRIDES": WinePrefixDefaults.bootstrapDisabledAddonDLLOverrides
                    ]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 180
            )
        case .migratePrefixRuntime(let runtimeExecutable, let prefix, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "prefix_runtime_migrate")
            return CommandSpec(
                actionName: "migratePrefixRuntime",
                executable: runtimeExecutable,
                arguments: ["wineboot", "-u"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: [
                        "WINEPREFIX": prefix.path,
                        "WINEARCH": WinePrefixDefaults.architecture,
                        "WINEDLLOVERRIDES": WinePrefixDefaults.bootstrapDisabledAddonDLLOverrides
                    ]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 600
            )
        case .waitForWinePrefix(let runtimeExecutable, let prefix, let logDirectory):
            return try makeWinePrefixWaitCommandSpec(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory,
                actionName: "waitForWinePrefix",
                logName: "wine_prefix_wait",
                timeout: 60
            )
        case .probeRuntime(let executable, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "runtime_probe")
            return CommandSpec(
                actionName: "probeBundledRuntime",
                executable: executable,
                arguments: ["--version"],
                environment: try Self.runnerEnvironment(for: executable),
                workingDirectory: nil,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 8
            )
        case .installSteam(let runtimeExecutable, let prefix, let installer, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "steam_install")
            return CommandSpec(
                actionName: "installSteam",
                executable: runtimeExecutable,
                arguments: [installer.path, "/S"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                // The selected installer can live in Downloads, Desktop, or an
                // external security-scoped directory. The process only needs
                // the installer's absolute path; using its parent as cwd makes
                // Wine's startup shell traverse a directory the sandbox may
                // not enumerate and produces misleading getcwd failures even
                // when Steam installs successfully. The managed prefix is the
                // stable, app-owned working directory for this operation.
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 600
            )
        case .maintainSteamClientService(
            let runtimeExecutable,
            let prefix,
            let operation,
            let logDirectory
        ):
            let logs = Self.logPair(in: logDirectory, name: operation.logName)
            let executable: URL
            let arguments: [String]
            switch operation {
            case .install:
                executable = SteamClientServiceContract.sourceExecutable(in: prefix)
                arguments = [executable.path, "/install"]
            case .query:
                executable = SteamClientServiceContract.serviceControlExecutable(in: prefix)
                arguments = [executable.path, "query", SteamClientServiceContract.serviceName]
            }
            return CommandSpec(
                actionName: operation.actionName,
                executable: runtimeExecutable,
                arguments: arguments,
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .requestSteamClientShutdown(let runtimeExecutable, let prefix, let steamExecutable, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "steam_client_shutdown")
            let steamCommand = [
                Self.windowsPath(for: steamExecutable, in: prefix) ?? Self.windowsHostPath(for: steamExecutable),
                "-shutdown"
            ]
            let steamLaunch = steamLaunchInvocation(
                for: runtimeExecutable,
                prefix: prefix,
                steamCommand: steamCommand
            )
            return CommandSpec(
                actionName: "requestSteamClientShutdown",
                executable: steamLaunch.executable,
                arguments: steamLaunch.arguments,
                environment: try Self.runnerEnvironment(
                    for: steamLaunch.executable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: steamExecutable.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 5
            )
        case .shutdownWinePrefix(let runtimeExecutable, let prefix, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "wine_prefix_shutdown")
            if let wineserver = Self.wineserverExecutable(for: runtimeExecutable) {
                return CommandSpec(
                    actionName: "shutdownWinePrefix",
                    executable: wineserver,
                    // An explicit signal asks wineserver to return after the
                    // request instead of entering its own long implicit wait.
                    // ForgePlay owns the authoritative `-w` barrier below.
                    arguments: ["--kill=\(SIGTERM)"],
                    environment: try Self.runnerEnvironment(
                        for: runtimeExecutable,
                        base: ["WINEPREFIX": prefix.path],
                        allowsInvalidPrefixSynchronizationProfileForCleanup: true
                    ),
                    workingDirectory: prefix,
                    stdoutLog: logs.stdout,
                    stderrLog: logs.stderr,
                    timeout: 5
                )
            }
            return CommandSpec(
                actionName: "shutdownWinePrefix",
                executable: runtimeExecutable,
                arguments: ["wineserver", "--kill=\(SIGTERM)"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path],
                    allowsInvalidPrefixSynchronizationProfileForCleanup: true
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 5
            )
        case .launchSteam(
            let runtimeExecutable,
            let prefix,
            let steamExecutable,
            let steamArguments,
            let graphicsBackend,
            let requestedCompatibilitySelection,
            let gameModePolicy,
            let logDirectory,
            let externalStorageRoots
        ):
            let rosettaAVXPolicy =
                try managedWineRosettaAVXPolicySnapshotProvider()
            guard let graphicsBackend else {
                throw SafeProcessRunnerError.manualRendererSelectionRequired
            }
            let compatibilitySelection =
                requestedCompatibilitySelection ??
                SteamPrelaunchCompatibilitySelection(
                    rendererSelection: SteamRendererPolicyManager.selection(
                        for: graphicsBackend
                    ),
                    networkSelection: .standard,
                    audioInputSelection: .enabled,
                    keyboardMapping: .systemDefault
                )
            guard compatibilitySelection.rendererPreference ==
                    graphicsBackend else {
                throw SafeProcessRunnerError.invalidSteamCompatibilitySelection
            }
            let logs = Self.logPair(in: logDirectory, name: "steam_launch")
            let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(for: logs.stderr)
            let gameRunLogDirectory = logDirectory.appending(
                path: "GameRuns/\(runIdentifier)",
                directoryHint: .isDirectory
            )
            // Renderer and crash diagnostics for an actual Steam session use
            // the managed GameRuns UUID directory. Non-launch Wine actions
            // keep their lifecycle journal out of this game-only namespace.
            _ = try makeGameRunEvidenceDirectory(
                in: logDirectory,
                runIdentifier: runIdentifier
            )
            let processObservationLog = logs.stderr
                .deletingPathExtension()
                .appendingPathExtension("process-observation.log")
            let steamCommand = [
                Self.windowsPath(for: steamExecutable, in: prefix) ?? Self.windowsHostPath(for: steamExecutable)
            ] + steamArguments
            let steamLaunch = steamLaunchInvocation(
                for: runtimeExecutable,
                prefix: prefix,
                steamCommand: steamCommand
            )
            // Steam and WebHelper stay on the base Wine path. The bundled Wine
            // process policy applies exactly the renderer selected for this
            // Steam session to game children below steamapps/common.
            let steamClientGraphicsBackend: SteamRendererPolicyPreference? = nil
            let exposesVulkanICD = try Self.shouldExposeSteamClientVulkanICD(
                for: steamLaunch.executable,
                graphicsBackend: steamClientGraphicsBackend
            )
            var environment = try Self.runnerEnvironment(
                for: steamLaunch.executable,
                base: try Self.launchSteamBaseEnvironment(
                    runnerExecutable: steamLaunch.executable,
                    prefix: prefix,
                    gameGraphicsBackend: graphicsBackend,
                    compatibilitySelection: compatibilitySelection,
                    logDirectory: gameRunLogDirectory,
                    processObservationLog: processObservationLog,
                    correlationIdentifier: runIdentifier,
                    rosettaAVXPolicy: rosettaAVXPolicy,
                    supplementalRendererAuthenticator:
                        supplementalRendererAuthenticator
                ),
                graphicsBackend: steamClientGraphicsBackend,
                exposesVulkanICD: exposesVulkanICD,
                injectGraphicsDLLOverrides: false,
                rosettaAVXPolicy: rosettaAVXPolicy
            )
            switch gameModePolicy {
            case .standard:
                environment = GameModeHostEnvironment.applyingStandardLaunch(
                    to: environment,
                    evidenceLogURL: logs.stderr
                        .deletingPathExtension()
                        .appendingPathExtension("game-mode-host.jsonl"),
                    runIdentifier: runIdentifier
                )
            case .experimentalRequiredHost:
                let gameModeEvidenceLog = try GameModeHostCoordinationPaths
                    .evidenceLogURL(
                        fallbackLogURL: logs.stderr
                            .deletingPathExtension()
                            .appendingPathExtension("game-mode-host.jsonl"),
                        fileManager: fileManager,
                        primaryApplicationGroupIdentifier:
                            gameModeHostApplicationGroupIdentifier,
                        applicationGroupContainerResolver:
                            gameModeHostApplicationGroupContainerResolver
                    )
                let selection = try gameModeSteamChildSelectionResolver(
                    runtimeExecutable,
                    prefix,
                    gameModeEvidenceLog,
                    runIdentifier
                )
                environment = GameModeHostEnvironment.applying(
                    selection,
                    to: environment
                )
            }
            environment = SteamExternalStorageProcessGrant
                .removingEnvironment(from: environment)
            var launchRuntimeCompatibility: [String: String] = [:]
            if compatibilitySelection.managedWineChildPolicy != nil {
                launchRuntimeCompatibility[
                    "externalStorageGrantRequiredForManagedChild"
                ] = "true"
            }
            if sandboxEnabled,
               compatibilitySelection.managedWineChildPolicy != nil,
               externalStorageRoots.isEmpty {
                throw SteamExternalStorageGrantPreparationError(
                    reasonCode: "root-required",
                    requiredForManagedChild: true
                )
            }
            if sandboxEnabled, !externalStorageRoots.isEmpty {
                launchRuntimeCompatibility[
                    "externalStorageGrantRequiredForLaunch"
                ] = "true"
                do {
                    let grant = try externalStorageGrantPublisher(
                        externalStorageRoots,
                        prefix,
                        runIdentifier
                    )
                    environment.merge(
                        grant.environmentOverrides,
                        uniquingKeysWith: { _, grantValue in grantValue }
                    )
                    launchRuntimeCompatibility[
                        "externalStorageGrantPublicationStatus"
                    ] = "published"
                } catch {
                    let reasonCode =
                        Self.externalStorageGrantPublicationFailureCode(
                            for: error
                        )
                    throw SteamExternalStorageGrantPreparationError(
                        reasonCode: reasonCode,
                        requiredForManagedChild:
                            compatibilitySelection.managedWineChildPolicy != nil
                    )
                }
            }
            Self.captureSteamBaseRendererEnvironment(in: &environment)
            var spec = CommandSpec(
                actionName: "launchSteam",
                executable: steamLaunch.executable,
                arguments: steamLaunch.arguments,
                environment: environment,
                runtimeCompatibility: launchRuntimeCompatibility,
                workingDirectory: steamExecutable.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: nil,
                waitsForExit: false,
                startupValidationInterval: steamLaunch.validatesStartup ? 6 : 0,
                processObservationLog: processObservationLog,
                anchoredLibraryPathIdentity:
                    compatibilitySelection.managedWineChildPolicy?
                        .anchoredLibraryPathIdentity
            )
            spec.managedWineRosettaAVXPolicy = rosettaAVXPolicy
            return spec
        case .launchWindowsUtility(
            let runtimeExecutable,
            let prefix,
            let executable,
            let arguments,
            let graphicsBackend,
            let logDirectory,
            let externalStorageRoots
        ):
            let rosettaAVXPolicy =
                try managedWineRosettaAVXPolicySnapshotProvider()
            let logs = Self.logPair(
                in: logDirectory,
                name: "windows_utility_launch"
            )
            let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(
                for: logs.stderr
            )
            let utilityCommand = [
                Self.windowsPath(for: executable, in: prefix) ??
                    Self.windowsHostPath(for: executable)
            ] + arguments
            let utilityExecutableIdentity =
                try WindowsUtilityExecutableLaunchIdentity(
                    executable: executable,
                    originalWindowsCommandPath: utilityCommand[0]
                )
            let utilityLaunch = steamLaunchInvocation(
                for: runtimeExecutable,
                prefix: prefix,
                steamCommand: utilityCommand
            )
            if let graphicsBackend {
                let rendererModules = try Self.rendererWindowsModuleFiles(
                    for: utilityLaunch.executable,
                    graphicsBackend: graphicsBackend,
                    prefix: prefix,
                    supplementalRendererAuthenticator:
                        supplementalRendererAuthenticator
                )
                guard !rendererModules.isEmpty else {
                    throw SafeProcessRunnerError.gameRendererPayloadMissing(
                        utilityLaunch.executable,
                        graphicsBackend.rawValue
                    )
                }
            }
            var environment = try Self.runnerEnvironment(
                for: utilityLaunch.executable,
                base: ["WINEPREFIX": prefix.path],
                graphicsBackend: graphicsBackend,
                exposesVulkanICD: graphicsBackend == .vulkan,
                injectGraphicsDLLOverrides: graphicsBackend != nil,
                rosettaAVXPolicy: rosettaAVXPolicy,
                supplementalRendererAuthenticator:
                    supplementalRendererAuthenticator
            )
            environment = SteamExternalStorageProcessGrant
                .removingEnvironment(from: environment)
            var runtimeCompatibility: [String: String] = [
                "windowsUtilityExecutionProfile": "base-runtime",
                "windowsUtilityExecutableBinding":
                    "descriptor-sha256-v1"
            ]
            if let graphicsBackend {
                environment[
                    "FORGEPLAY_WINDOWS_UTILITY_RENDERER_BACKEND_V1"
                ] = graphicsBackend.rawValue
                runtimeCompatibility[
                    "windowsUtilityExecutionProfile"
                ] = "base-runtime+renderer-\(graphicsBackend.rawValue)"
                runtimeCompatibility[
                    "windowsUtilityRendererBackend"
                ] = graphicsBackend.rawValue
            }
            if sandboxEnabled, !externalStorageRoots.isEmpty {
                let grant = try externalStorageGrantPublisher(
                    externalStorageRoots,
                    prefix,
                    runIdentifier
                )
                environment.merge(
                    grant.environmentOverrides,
                    uniquingKeysWith: { _, grantValue in grantValue }
                )
                runtimeCompatibility[
                    "externalStorageGrantPublicationStatus"
                ] = "published"
            }
            var spec = CommandSpec(
                actionName: "launchWindowsUtility",
                executable: utilityLaunch.executable,
                arguments: utilityLaunch.arguments,
                environment: environment,
                runtimeCompatibility: runtimeCompatibility,
                workingDirectory: executable.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: nil,
                waitsForExit: false,
                startupValidationInterval:
                    utilityLaunch.validatesStartup ? 6 : 0,
                windowsUtilityExecutableIdentity:
                    utilityExecutableIdentity
            )
            spec.managedWineRosettaAVXPolicy = rosettaAVXPolicy
            return spec
        case .extractRuntimeArchive(let runtimeExecutable, let prefix, let archive, let extractionDirectory, let runtime, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "\(runtime.rawValue)_extract")
            return CommandSpec(
                actionName: "extractRuntimeArchive:\(runtime.rawValue)",
                executable: runtimeExecutable,
                arguments: [
                    archive.path,
                    "/Q",
                    "/T:\(Self.windowsHostPath(for: extractionDirectory))"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: archive.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 300
            )
        case .installRuntime(let runtimeExecutable, let prefix, let installer, let runtime, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "\(runtime.rawValue)_install")
            return CommandSpec(
                actionName: "installRuntime:\(runtime.rawValue)",
                executable: runtimeExecutable,
                arguments: Self.installerCommand(for: installer),
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: installer.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 1_800
            )
        case .setWindowsVersion(let runtimeExecutable, let prefix, let version, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "windows_version_\(version)")
            return CommandSpec(
                actionName: "setWindowsVersion:\(version)",
                executable: runtimeExecutable,
                arguments: [
                    "reg",
                    "add",
                    "HKCU\\Software\\Wine",
                    "/v",
                    "Version",
                    "/d",
                    version,
                    "/f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .setRegistryValue(
            let runtimeExecutable,
            let prefix,
            let registryPath,
            let valueName,
            let valueType,
            let value,
            let registryView,
            let logDirectory
        ):
            let safeRegistryName = PathManager.sanitizedFileName(registryPath)
            let safeValueName = PathManager.sanitizedFileName(valueName)
            let logs = Self.logPair(in: logDirectory, name: "registry_value_\(safeRegistryName)_\(safeValueName)")
            var command = [
                "reg",
                "add",
                registryPath,
                "/v",
                valueName
            ]
            if let valueType {
                command.append(contentsOf: ["/t", valueType])
            }
            command.append(contentsOf: [
                "/d",
                value,
                "/f"
            ])
            if let registryView {
                command.append("/reg:\(registryView.rawValue)")
            }
            return CommandSpec(
                actionName: "setRegistryValue:\(registryPath):\(valueName)",
                executable: runtimeExecutable,
                arguments: command,
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .deleteRegistryValue(
            let runtimeExecutable,
            let prefix,
            let registryPath,
            let valueName,
            let registryView,
            let logDirectory
        ):
            let safeRegistryName = PathManager.sanitizedFileName(registryPath)
            let safeValueName = PathManager.sanitizedFileName(valueName)
            let logs = Self.logPair(
                in: logDirectory,
                name: "registry_value_delete_strict_\(safeRegistryName)_\(safeValueName)"
            )
            var command = [
                "reg",
                "delete",
                registryPath,
                "/v",
                valueName,
                "/f"
            ]
            if let registryView {
                command.append("/reg:\(registryView.rawValue)")
            }
            return CommandSpec(
                actionName: "deleteRegistryValue:\(registryPath):\(valueName)",
                executable: runtimeExecutable,
                arguments: command,
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .deleteRegistryValueIfPresent(
            let runtimeExecutable,
            let prefix,
            let registryPath,
            let valueName,
            let logDirectory
        ):
            let safeRegistryName = PathManager.sanitizedFileName(registryPath)
            let safeValueName = PathManager.sanitizedFileName(valueName)
            let logs = Self.logPair(
                in: logDirectory,
                name: "registry_value_delete_\(safeRegistryName)_\(safeValueName)"
            )
            return CommandSpec(
                actionName:
                    "deleteRegistryValueIfPresent:\(registryPath):\(valueName)",
                executable: runtimeExecutable,
                arguments: [
                    "cmd",
                    "/c",
                    "reg query \"\(registryPath)\" /v \"\(valueName)\" >NUL 2>NUL & if errorlevel 1 (exit /b 0) else (reg delete \"\(registryPath)\" /v \"\(valueName)\" /f)"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .setDLLOverride(let runtimeExecutable, let prefix, let dll, let override, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "dll_override_\(dll)")
            return CommandSpec(
                actionName: "setDLLOverride:\(dll)",
                executable: runtimeExecutable,
                arguments: [
                    "reg",
                    "add",
                    "HKCU\\Software\\Wine\\DllOverrides",
                    "/v",
                    dll,
                    "/d",
                    override,
                    "/f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .setAppDLLOverride(let runtimeExecutable, let prefix, let appExecutable, let dll, let override, let logDirectory):
            let safeAppName = PathManager.sanitizedFileName(appExecutable)
            let safeDLLName = PathManager.sanitizedFileName(dll)
            let logs = Self.logPair(in: logDirectory, name: "app_dll_override_\(safeAppName)_\(safeDLLName)")
            return CommandSpec(
                actionName: "setAppDLLOverride:\(appExecutable):\(dll)",
                executable: runtimeExecutable,
                arguments: [
                    "reg",
                    "add",
                    "HKCU\\Software\\Wine\\AppDefaults\\\(appExecutable)\\DllOverrides",
                    "/v",
                    dll,
                    "/d",
                    override,
                    "/f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .deleteAppDLLOverrideIfPresent(let runtimeExecutable, let prefix, let appExecutable, let dll, let logDirectory):
            let safeAppName = PathManager.sanitizedFileName(appExecutable)
            let safeDLLName = PathManager.sanitizedFileName(dll)
            let logs = Self.logPair(in: logDirectory, name: "app_dll_override_delete_\(safeAppName)_\(safeDLLName)")
            let registryPath = "HKCU\\Software\\Wine\\AppDefaults\\\(appExecutable)\\DllOverrides"
            return CommandSpec(
                actionName: "deleteAppDLLOverrideIfPresent:\(appExecutable):\(dll)",
                executable: runtimeExecutable,
                arguments: [
                    "cmd",
                    "/c",
                    "reg query \"\(registryPath)\" /v \"\(dll)\" >NUL 2>NUL || exit /b 0 & reg delete \"\(registryPath)\" /v \"\(dll)\" /f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .createSupportArchive(let sourceDirectory, let destinationZip, let logDirectory):
            try Self.validateSupportArchivePaths(
                sourceDirectory: sourceDirectory,
                destinationZip: destinationZip,
                fileManager: fileManager
            )
            let logs = Self.logPair(in: logDirectory, name: "support_bundle")
            return CommandSpec(
                actionName: "createSupportArchive",
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--keepParent", sourceDirectory.path, destinationZip.path],
                environment: [:],
                workingDirectory: sourceDirectory.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 60
            )
        }
    }

    private func attachingManagedWineProcessJournal(
        to input: CommandSpec,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        runtimeFingerprint authenticatedRuntimeFingerprint: String?
    ) throws -> CommandSpec {
        var spec = input
        let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(
            for: spec.stderrLog
        ).lowercased()
        guard UUID(uuidString: runIdentifier) != nil else {
            throw SafeProcessRunnerError.cannotCreateLog(spec.stderrLog)
        }
        let runtimeFingerprint = try authenticatedRuntimeFingerprint ??
            managedWineRuntimeFingerprintResolver(runtimeExecutable)
        guard runtimeFingerprint.utf8.count == 64,
              runtimeFingerprint.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw SafeProcessRunnerError.metadataReadFailed(
                runtimeExecutable,
                "managed Wine runtime fingerprint is invalid"
            )
        }
        let fallbackDirectory = managedWineProcessEvidenceSandboxEnabled
            ? logDirectory
            : try makeManagedWineProcessEvidenceDirectory(
                in: logDirectory
            )
        let evidenceURL = try ManagedWineProcessJournal.evidenceFileURL(
            runIdentifier: runIdentifier,
            fallbackDirectory: fallbackDirectory,
            fileManager: fileManager,
            sandboxEnabled: managedWineProcessEvidenceSandboxEnabled
        )
        let evidenceHandle = try Self.openLogFileHandle(
            at: evidenceURL,
            fileManager: fileManager
        )
        try evidenceHandle.close()

        guard let wineLoaderPath = spec.environment["WINELOADER"],
              wineLoaderPath.hasPrefix("/") else {
            throw SafeProcessRunnerError.metadataReadFailed(
                runtimeExecutable,
                "the managed Wine loader root is unavailable"
            )
        }
        let wineLoaderURL = URL(fileURLWithPath: wineLoaderPath)
            .standardizedFileURL
        let binDirectory = wineLoaderURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else {
            throw SafeProcessRunnerError.metadataReadFailed(
                runtimeExecutable,
                "the managed Wine loader is outside a curated Runtime bin directory"
            )
        }
        let runtimeRootURL = binDirectory.deletingLastPathComponent()

        let applicationOwnerProcessIdentifier = Darwin.getpid()
        guard applicationOwnerProcessIdentifier > 1,
              let applicationOwnerStartTime =
                Self.processStartTimeUnixMicroseconds(
                    for: applicationOwnerProcessIdentifier
                ) else {
            throw SafeProcessRunnerError.metadataReadFailed(
                runtimeExecutable,
                "ForgePlay application owner process identity is unavailable"
            )
        }
        let registeredAt = Date()
        let activeSessionDescriptor = try ManagedWineProcessJournal
            .makeActiveSessionDescriptor(
                runIdentifier: runIdentifier,
                evidenceURL: evidenceURL,
                prefix: prefix,
                runtimeRootURL: runtimeRootURL,
                runtimeFingerprint: runtimeFingerprint,
                ownerProcessIdentifier: applicationOwnerProcessIdentifier,
                ownerProcessStartedAtUnixMicroseconds:
                    applicationOwnerStartTime,
                registeredAt: registeredAt
            )
        let activeSessionDescriptorURL = try ManagedWineProcessJournal
            .writeActiveSessionDescriptor(
                activeSessionDescriptor,
                in: evidenceURL.deletingLastPathComponent()
            )

        spec.environment[ManagedWineProcessJournal.evidenceFileKey] =
            evidenceURL.path
        spec.environment[ManagedWineProcessJournal.runIdentifierKey] =
            runIdentifier
        spec.environment[ManagedWineProcessJournal.prefixScopeKey] =
            ManagedWineProcessJournal.prefixScope(for: prefix)
        spec.environment[ManagedWineProcessJournal.runtimeFingerprintKey] =
            runtimeFingerprint
        spec.environment[
            ManagedWineProcessJournal.applicationOwnerProcessIdentifierKey
        ] = String(applicationOwnerProcessIdentifier)
        spec.environment[
            ManagedWineProcessJournal.applicationOwnerStartTimeKey
        ] = String(applicationOwnerStartTime)
        spec.managedWineLaunchSession = ManagedWineProcessLaunchSession(
            prefixURL: prefix.standardizedFileURL,
            runIdentifier: runIdentifier,
            evidenceURL: evidenceURL,
            descriptorURL: activeSessionDescriptorURL,
            runtimeRootURL: runtimeRootURL,
            runtimeFingerprint: runtimeFingerprint,
            prefixScope: activeSessionDescriptor.prefixScope,
            registeredAt: registeredAt
        )
        spec.runtimeCompatibility["managedWineProcessJournal"] = "enabled"
        spec.runtimeCompatibility["managedWineProcessJournalSchema"] = "1"
        spec.runtimeCompatibility["managedWineActiveSessionDescriptor"] =
            "schema-1-owner-private-atomic"
        spec.runtimeCompatibility["managedWineOwnerDeathContainment"] =
            "wineserver-owner-process-v2-graceful-hard-watchdog"
        return spec
    }

    private func makeManagedWineProcessEvidenceDirectory(
        in logDirectory: URL
    ) throws -> URL {
        do {
            try fileManager.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            try Self.requireNonSymlinkDirectory(
                logDirectory,
                fileManager: fileManager,
                unsafeError: SafeProcessRunnerError.cannotCreateLog
            )
            let directory = logDirectory.appending(
                path: ManagedWineProcessJournal.evidenceDirectoryName,
                directoryHint: .isDirectory
            )
            try Self.createPrivateDiagnosticDirectory(
                directory,
                parent: logDirectory,
                fileManager: fileManager
            )
            return directory
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(logDirectory)
        }
    }

    private func makeGameRunEvidenceDirectory(
        in logDirectory: URL,
        runIdentifier: String
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try Self.requireNonSymlinkDirectory(
                logDirectory,
                fileManager: fileManager,
                unsafeError: SafeProcessRunnerError.cannotCreateLog
            )
            let gameRuns = logDirectory.appending(path: "GameRuns", directoryHint: .isDirectory)
            try Self.createPrivateDiagnosticDirectory(
                gameRuns,
                parent: logDirectory,
                fileManager: fileManager
            )
            let runDirectory = gameRuns.appending(path: runIdentifier, directoryHint: .isDirectory)
            try Self.createPrivateDiagnosticDirectory(
                runDirectory,
                parent: gameRuns,
                fileManager: fileManager
            )
            return runDirectory
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(logDirectory)
        }
    }

    private nonisolated static func createPrivateDiagnosticDirectory(
        _ directory: URL,
        parent: URL,
        fileManager: FileManager
    ) throws {
        try requireNonSymlinkDirectory(
            parent,
            fileManager: fileManager,
            unsafeError: SafeProcessRunnerError.cannotCreateLog
        )
        if mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
            throw SafeProcessRunnerError.cannotCreateLog(directory)
        }
        try requireNonSymlinkDirectory(
            directory,
            fileManager: fileManager,
            unsafeError: SafeProcessRunnerError.cannotCreateLog
        )
    }

    func makeWinePrefixWaitCommandSpec(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        actionName: String,
        logName: String,
        timeout: TimeInterval,
        allowsInvalidPrefixSynchronizationProfileForCleanup: Bool = false
    ) throws -> CommandSpec {
        let logs = Self.logPair(in: logDirectory, name: logName)
        if let wineserver = Self.wineserverExecutable(for: runtimeExecutable) {
            return CommandSpec(
                actionName: actionName,
                executable: wineserver,
                arguments: ["-w"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path],
                    allowsInvalidPrefixSynchronizationProfileForCleanup:
                        allowsInvalidPrefixSynchronizationProfileForCleanup
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: timeout
            )
        }
        return CommandSpec(
            actionName: actionName,
            executable: runtimeExecutable,
            arguments: ["wineserver", "-w"],
            environment: try Self.runnerEnvironment(
                for: runtimeExecutable,
                base: ["WINEPREFIX": prefix.path],
                allowsInvalidPrefixSynchronizationProfileForCleanup:
                    allowsInvalidPrefixSynchronizationProfileForCleanup
            ),
            workingDirectory: prefix,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            timeout: timeout
        )
    }

    func makeWinePrefixSignalCommandSpec(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        signal: Int32,
        actionName: String,
        logName: String,
        timeout: TimeInterval
    ) throws -> CommandSpec {
        let logs = Self.logPair(in: logDirectory, name: logName)
        let signalArgument = "--kill=\(signal)"
        if let wineserver = Self.wineserverExecutable(for: runtimeExecutable) {
            return CommandSpec(
                actionName: actionName,
                executable: wineserver,
                arguments: [signalArgument],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path],
                    allowsInvalidPrefixSynchronizationProfileForCleanup: true
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: timeout
            )
        }
        return CommandSpec(
            actionName: actionName,
            executable: runtimeExecutable,
            arguments: ["wineserver", signalArgument],
            environment: try Self.runnerEnvironment(
                for: runtimeExecutable,
                base: ["WINEPREFIX": prefix.path],
                allowsInvalidPrefixSynchronizationProfileForCleanup: true
            ),
            workingDirectory: prefix,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            timeout: timeout
        )
    }

    private static func launchSteamBaseEnvironment(
        runnerExecutable: URL,
        prefix: URL,
        gameGraphicsBackend: SteamRendererPolicyPreference,
        compatibilitySelection: SteamPrelaunchCompatibilitySelection,
        logDirectory: URL,
        processObservationLog: URL,
        correlationIdentifier: String,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating
    ) throws -> [String: String] {
        var environment = [
            "WINEPREFIX": prefix.path,
            "MTL_HUD_ENABLED": "0",
            SteamWebHelperLaunchPolicy.observationTargetEnvironmentKey:
                SteamWebHelperLaunchPolicy.executableName,
            SteamWebHelperLaunchPolicy.argumentTargetEnvironmentKey:
                SteamWebHelperLaunchPolicy.executableName,
            SteamWebHelperLaunchPolicy.argumentAppendEnvironmentKey:
                SteamWebHelperLaunchPolicy.requiredArguments.joined(separator: " "),
            SteamWebHelperLaunchPolicy.argumentRootOnlyEnvironmentKey:
                SteamWebHelperLaunchPolicy.argumentRootOnlyEnvironmentValue,
            "FORGEPLAY_PROCESS_OBSERVATION_FILE": Self.windowsHostPath(for: processObservationLog),
            SteamGameCEFBrowserLaunchPolicy.environmentKey:
                SteamGameCEFBrowserLaunchPolicy.enabledValue,
            "FORGEPLAY_GAME_RENDERER_CORRELATION_ID": correlationIdentifier,
            "FORGEPLAY_NETWORK_PROFILE_REQUESTED":
                compatibilitySelection.networkSelection.rawValue,
            "FORGEPLAY_AUDIO_INPUT_MODE":
                compatibilitySelection.audioInputSelection.rawValue
        ]
        if let policy = compatibilitySelection.managedWineChildPolicy {
            environment[
                Helldivers2ManagedWineChildPolicyContract.policyVersionKey
            ] = Helldivers2ManagedWineChildPolicyContract.policyVersion
            environment[
                Helldivers2ManagedWineChildPolicyContract.steamAppIDKey
            ] = policy.steamAppID
            environment[
                Helldivers2ManagedWineChildPolicyContract.hostAuthorizationKey
            ] = Helldivers2ManagedWineChildPolicyContract.hostAuthorization
            environment[
                Helldivers2ManagedWineChildPolicyContract.canonicalRootKey
            ] = Self.windowsHostPath(for: policy.canonicalGameRoot)
            environment[
                Helldivers2ManagedWineChildPolicyContract
                    .canonicalRootIdentityTelemetryDigestKey
            ] = policy.canonicalGameRootIdentityDigest
            environment[
                Helldivers2ManagedWineChildPolicyContract
                    .manifestRootAuthorizationTelemetryDigestKey
            ] = policy.manifestRootAuthorizationDigest
            environment[
                Helldivers2ManagedWineChildPolicyContract.lineageNonceKey
            ] = policy.lineageNonce.uuidString.lowercased()
            environment[
                Helldivers2ManagedWineChildPolicyContract
                    .heapZeroMemoryRequestedKey
            ] = policy.heapZeroMemoryEnabled ? "1" : "0"
            environment[
                Helldivers2ManagedWineChildPolicyContract
                    .gameGuardRendererExclusionRequestedKey
            ] = policy.excludesGameGuardRenderer ? "1" : "0"
        }
        if let wineDebug = ProcessInfo.processInfo.environment["FORGEPLAY_WINEDEBUG"],
           !wineDebug.isEmpty {
            environment["WINEDEBUG"] = wineDebug
        }
        if compatibilitySelection.rendererSelection
            .usesD3DMetalNVIDIACompatibility {
            // NVIDIA Streamline 2.7+ honors these documented overrides. Keep
            // its file in the per-launch GameRuns directory so a field test
            // can distinguish an adapter/driver-store rejection from a later
            // NGX bridge load failure.
            environment["SL_ENABLE_CONSOLE_LOGGING"] = "0"
            environment["SL_LOG_LEVEL"] = "2"
            environment["SL_LOG_PATH"] =
                Self.windowsHostPath(for: logDirectory)
            environment["SL_LOG_NAME"] =
                "forgeplay-streamline.log"
        }
        environment.merge(
            try steamGameRendererPolicyEnvironment(
                for: runnerExecutable,
                prefix: prefix,
                graphicsBackend: gameGraphicsBackend,
                rendererSelection:
                    compatibilitySelection.rendererSelection,
                networkSelection:
                    compatibilitySelection.networkSelection,
                logDirectory: logDirectory,
                rosettaAVXPolicy: rosettaAVXPolicy,
                supplementalRendererAuthenticator:
                    supplementalRendererAuthenticator
            ),
            uniquingKeysWith: { _, rendererValue in rendererValue }
        )
        return environment
    }

    static func steamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        rendererSelection: SteamRendererPolicySelection? = nil,
        networkSelection: SteamNetworkCompatibilitySelection = .standard,
        logDirectory: URL,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1? = nil,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws -> [String: String] {
        let resolvedRendererSelection =
            rendererSelection ??
            SteamRendererPolicyManager.selection(for: graphicsBackend)
        guard resolvedRendererSelection.forcedPreference ==
                graphicsBackend else {
            throw SafeProcessRunnerError.invalidSteamCompatibilitySelection
        }
        switch graphicsBackend {
        case .d3dMetal:
            return try d3dMetalSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                logDirectory: logDirectory,
                scope: .direct3D12,
                rendererSelection: resolvedRendererSelection,
                networkSelection: networkSelection,
                rosettaAVXPolicy: rosettaAVXPolicy,
                supplementalRendererAuthenticator:
                    supplementalRendererAuthenticator
            )
        case .dxmt:
            return try dxmtSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                logDirectory: logDirectory,
                networkSelection: networkSelection,
                rosettaAVXPolicy: rosettaAVXPolicy
            )
        case .d9vk:
            return try d9VKSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                logDirectory: logDirectory,
                networkSelection: networkSelection,
                rosettaAVXPolicy: rosettaAVXPolicy
            )
        case .vulkan:
            return try fixedSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                graphicsBackend: graphicsBackend,
                rendererSelection: resolvedRendererSelection,
                networkSelection: networkSelection,
                logDirectory: logDirectory,
                rosettaAVXPolicy: rosettaAVXPolicy
            )
        }
    }

    private static func d3dMetalSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL,
        scope: D3DMetalRendererPayloadContract.LaunchScope,
        rendererSelection: SteamRendererPolicySelection,
        networkSelection: SteamNetworkCompatibilitySelection,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1?,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating
    ) throws -> [String: String] {
        let d3dMetalRoot = try requiredD3DMetalRendererRoot(
            for: executable,
            prefix: prefix,
            scope: scope,
            requiresNVIDIACompatibility:
                rendererSelection.usesD3DMetalNVIDIACompatibility,
            supplementalRendererAuthenticator:
                supplementalRendererAuthenticator
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: d3dMetalRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        if !rendererSelection.usesD3DMetalNVIDIACompatibility {
            let nvidiaOnlyNames: Set<String> = [
                "nvapi.dll",
                "nvapi64.dll",
                "nvngx.dll",
                "nvngx-on-metalfx.dll"
            ]
            for key in Array(selectedModules.keys) {
                selectedModules[key]?.removeAll {
                    nvidiaOnlyNames.contains($0.lastPathComponent.lowercased())
                }
            }
        }
        var ngxBridgeRoot: URL?
        if rendererSelection.usesD3DMetalNVIDIACompatibility {
            do {
                let materialized = try D3DMetalNGXBridgeContract.materialize(
                    from: d3dMetalRoot,
                    in: prefix
                )
                ngxBridgeRoot = materialized
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: materialized.appending(
                        path: "wine",
                        directoryHint: .isDirectory
                    ),
                    fileManager: .default,
                    modulesByWindowsDirectory: &selectedModules
                )
            } catch {
                throw SafeProcessRunnerError.gameRendererBridgePreparationFailed(
                    prefix,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        selectedModules["syswow64"] = []
        guard !rendererModuleDirectories(
            selectedModules["system32", default: []]
        ).isEmpty else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "D3DMetal \(scope.rawValue) system32"
            )
        }

        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .d3dMetal,
            requested: rendererSelection,
            networkSelection: networkSelection,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [d3dMetalRoot] + [ngxBridgeRoot].compactMap { $0 },
            requiresVulkan: false,
            d3dMetalRoot: d3dMetalRoot,
            d3dMetalNGXBridgeRoot: ngxBridgeRoot,
            rosettaAVXPolicy: rosettaAVXPolicy
        )
    }

    private static func requiredD3DMetalRendererRoot(
        for executable: URL,
        prefix: URL,
        scope: D3DMetalRendererPayloadContract.LaunchScope,
        requiresNVIDIACompatibility: Bool = false,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws -> URL {
        let fileManager = FileManager.default
        var candidates = rendererSupportContentsDirectories(for: executable).map {
            $0.appending(
                path: "Frameworks/renderer/d3dmetal",
                directoryHint: .isDirectory
            )
        }
        if let wineRoot = wineRootDirectory(for: executable) {
            candidates.append(
                wineRoot.appending(path: "lib64/apple_gptk", directoryHint: .isDirectory)
            )
        }
        // The app-bundled renderer is authoritative. A managed Apple renderer is
        // considered only when no bundled root satisfies this exact generation.
        let supplemental = usableSupplementalRendererRoot(
            containingPrefix: prefix
        )
        if let supplemental {
            candidates.append(supplemental)
        }
        if let selected = deduplicated(candidates).first(where: { candidate in
            D3DMetalRendererPayloadContract.isUsable(
                for: scope,
                at: candidate,
                fileManager: fileManager
            ) && (!requiresNVIDIACompatibility ||
                D3DMetalRendererPayloadContract.isNVIDIAMetalFXUsable(
                    at: candidate,
                    fileManager: fileManager
                ))
        }) {
            if let supplemental,
               selected.standardizedFileURL ==
                supplemental.standardizedFileURL {
                try supplementalRendererAuthenticator.authenticate(
                    rendererRoot: selected,
                    fileManager: fileManager
                )
            }
            return selected
        }
        let providerDetail = requiresNVIDIACompatibility
            ? " + NVIDIA/MetalFX provider"
            : ""
        throw SafeProcessRunnerError.gameRendererPayloadMissing(
            executable,
            "D3DMetal \(scope.rawValue)\(providerDetail)"
        )
    }

    /// Performs the non-mutating provider admission used by status/inspection.
    /// Materializing the derived `nvngx.dll` remains part of launch preparation.
    static func validateD3DMetalNVIDIACompatibilityPayload(
        for executable: URL,
        prefix: URL,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws {
        _ = try requiredD3DMetalRendererRoot(
            for: executable,
            prefix: prefix,
            scope: .direct3D12,
            requiresNVIDIACompatibility: true,
            supplementalRendererAuthenticator:
                supplementalRendererAuthenticator
        )
    }

    private static func fixedSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        rendererSelection: SteamRendererPolicySelection,
        networkSelection: SteamNetworkCompatibilitySelection,
        logDirectory: URL,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1?
    ) throws -> [String: String] {
        guard graphicsBackend == .vulkan else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "fixed renderer profile \(graphicsBackend.rawValue)"
            )
        }
        let dxvkRoot = try requiredRendererComponentRoot(
            named: "dxvk",
            executable: executable,
            prefix: prefix,
            requiredWindowsDirectories: ["system32", "syswow64"]
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: dxvkRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .vulkan,
            requested: rendererSelection,
            networkSelection: networkSelection,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [dxvkRoot],
            requiresVulkan: true,
            d3dMetalRoot: nil,
            d3dMetalNGXBridgeRoot: nil,
            rosettaAVXPolicy: rosettaAVXPolicy
        )
    }

    private static func dxmtSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL,
        networkSelection: SteamNetworkCompatibilitySelection,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1?
    ) throws -> [String: String] {
        let dxmtRoot = try requiredRendererComponentRoot(
            named: "dxmt",
            executable: executable,
            prefix: prefix,
            requiredWindowsDirectories: ["system32", "syswow64"]
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: dxmtRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .dxmt,
            requested: .dxmt,
            networkSelection: networkSelection,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [dxmtRoot],
            requiresVulkan: false,
            d3dMetalRoot: nil,
            d3dMetalNGXBridgeRoot: nil,
            rosettaAVXPolicy: rosettaAVXPolicy
        )
    }

    private static func d9VKSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL,
        networkSelection: SteamNetworkCompatibilitySelection,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1?
    ) throws -> [String: String] {
        let d9VKRoot = try requiredRendererComponentRoot(
            named: "d9vk",
            executable: executable,
            prefix: prefix,
            requiredWindowsDirectories: ["system32", "syswow64"]
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: d9VKRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .d9vk,
            requested: .d9vk,
            networkSelection: networkSelection,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [d9VKRoot],
            requiresVulkan: true,
            d3dMetalRoot: nil,
            d3dMetalNGXBridgeRoot: nil,
            rosettaAVXPolicy: rosettaAVXPolicy
        )
    }

    private static func requiredRendererComponentRoot(
        named componentName: String,
        executable: URL,
        prefix: URL?,
        requiredWindowsDirectories: [String]
    ) throws -> URL {
        var candidates = rendererSupportContentsDirectories(for: executable).map {
            $0.appending(
                path: "Frameworks/renderer/\(componentName)",
                directoryHint: .isDirectory
            )
        }
        if componentName == "d3dmetal", let prefix,
           let supplemental = usableSupplementalRendererRoot(containingPrefix: prefix) {
            candidates.append(supplemental)
        }

        for candidate in deduplicated(candidates) where rendererComponentIsUsable(
            named: componentName,
            at: candidate,
            fileManager: .default
        ) {
            var modulesByWindowsDirectory: [String: [URL]] = [:]
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: candidate.appending(path: "wine", directoryHint: .isDirectory),
                fileManager: .default,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
            if requiredWindowsDirectories.allSatisfy({
                !rendererModuleDirectories(
                    modulesByWindowsDirectory[$0, default: []]
                ).isEmpty
            }) {
                return candidate
            }
        }
        throw SafeProcessRunnerError.gameRendererPayloadMissing(
            executable,
            "\(componentName) \(requiredWindowsDirectories.joined(separator: "+"))"
        )
    }

    private static func exactSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL,
        policy: SteamRendererPolicyPreference,
        requested: SteamRendererPolicySelection,
        networkSelection: SteamNetworkCompatibilitySelection,
        modulesByWindowsDirectory: [String: [URL]],
        componentRoots: [URL],
        requiresVulkan: Bool,
        d3dMetalRoot: URL?,
        d3dMetalNGXBridgeRoot: URL?,
        rosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1?
    ) throws -> [String: String] {
        let x64Directories = rendererModuleDirectories(
            modulesByWindowsDirectory["system32", default: []]
        )
        let x86Directories = rendererModuleDirectories(
            modulesByWindowsDirectory["syswow64", default: []]
        )
        guard !x64Directories.isEmpty else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "exact 64-bit renderer profile"
            )
        }

        var rendererBase = ["WINEPREFIX": prefix.path]
        if requiresVulkan {
            let videoMemorySizeMB = SteamClientCompatibilityProfileContract
                .configuredVideoMemorySizeMB(in: prefix) ??
                SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB
            rendererBase["DXVK_LOG_PATH"] = logDirectory.path
            rendererBase["DXVK_LOG_LEVEL"] = "info"
            rendererBase["DXVK_CONFIG"] =
                "dxgi.maxDeviceMemory = \(videoMemorySizeMB); " +
                "d3d9.maxAvailableMemory = \(videoMemorySizeMB)"
        }
        var rendererEnvironment = try runnerEnvironment(
            for: executable,
            base: rendererBase,
            graphicsBackend: nil,
            exposesVulkanICD: requiresVulkan,
            injectGraphicsDLLOverrides: false,
            rosettaAVXPolicy: rosettaAVXPolicy
        )

        let exactRoots = deduplicated(componentRoots)
        let wineRoots = exactRoots.map {
            $0.appending(path: "wine", directoryHint: .isDirectory)
        }.filter { FileSystemItemPolicy.isNonSymlinkDirectory($0) }
        let unixModuleDirectories = wineRoots.map {
            $0.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        }.filter { FileSystemItemPolicy.isNonSymlinkDirectory($0) }
        // WINEDLLPATH entries are Wine layout roots, not architecture leaf
        // directories. Wine appends its paired `x86_64-windows` and
        // `x86_64-unix` suffixes to the same entry when it maps a builtin PE
        // module. Putting the Windows leaf first makes an Apple D3DMetal
        // `dxgi.dll` bind to a nonexistent adjacent `dxgi.so`, so its
        // PROCESS_ATTACH returns false with c0000142.
        let wineDLLPaths = wineRoots.map(\.path)
        var dynamicLibraryDirectories = exactRoots + unixModuleDirectories

        if let d3dMetalRoot {
            let external = d3dMetalRoot.appending(
                path: "external",
                directoryHint: .isDirectory
            )
            let frameworkExecutable = external.appending(
                path: "D3DMetal.framework/D3DMetal"
            )
            let sharedLibrary = external.appending(path: "libd3dshared.dylib")
            guard FileSystemItemPolicy.isNonSymlinkDirectory(external),
                  D3DMetalRendererPayloadContract.isSafePayloadPath(
                    "external/D3DMetal.framework/D3DMetal",
                    at: d3dMetalRoot
                  ),
                  D3DMetalRendererPayloadContract.isSafePayloadPath(
                    D3DMetalRendererPayloadContract.sharedLibraryRelativePath,
                    at: d3dMetalRoot
                  ) else {
                throw SafeProcessRunnerError.gameRendererPayloadMissing(
                    executable,
                    "D3DMetal host closure"
                )
            }
            dynamicLibraryDirectories.append(external)
            rendererEnvironment["DYLD_FRAMEWORK_PATH"] = mergedPathList(
                [external.path],
                existing: rendererEnvironment["DYLD_FRAMEWORK_PATH"]
            )
            rendererEnvironment["D3DMETAL_FRAMEWORK_PATH"] = frameworkExecutable.path
            rendererEnvironment["D3DMETAL_SHARED_LIBRARY"] = sharedLibrary.path
            rendererEnvironment["D3DM_WINE_UNIX_CALL"] = "1"
            if requested.usesD3DMetalNVIDIACompatibility,
               let d3dMetalNGXBridgeRoot,
               D3DMetalNGXBridgeContract.isUsable(
                   at: d3dMetalNGXBridgeRoot
               ) {
                let ngxWindowsDirectory = d3dMetalNGXBridgeRoot.appending(
                    path: "wine/x86_64-windows",
                    directoryHint: .isDirectory
                )
                rendererEnvironment["D3DM_ENABLE_METALFX"] = "1"
                rendererEnvironment["D3DM_NVNGX_PATH"] = ngxWindowsDirectory.path
                rendererEnvironment["D3DM_VENDOR_ID"] = "0x10de"
                // Streamline 2.8 enumerates physical GPUs before explicitly
                // initializing NVAPI. The scoped Wine loader bootstrap primes
                // Apple's verified nvapi64 module before the game entry point.
                rendererEnvironment["FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"] = "1"
            } else {
                rendererEnvironment.removeValue(forKey: "D3DM_ENABLE_METALFX")
                rendererEnvironment.removeValue(forKey: "D3DM_NVNGX_PATH")
                rendererEnvironment.removeValue(forKey: "D3DM_VENDOR_ID")
                rendererEnvironment.removeValue(
                    forKey: "FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
                )
            }
        } else {
            for key in [
                "DYLD_FRAMEWORK_PATH",
                "D3DMETAL_FRAMEWORK_PATH",
                "D3DMETAL_SHARED_LIBRARY",
                "D3DM_WINE_UNIX_CALL",
                "D3DM_ENABLE_METALFX",
                "D3DM_NVNGX_PATH",
                "D3DM_VENDOR_ID",
                "FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
            ] {
                rendererEnvironment.removeValue(forKey: key)
            }
        }
        rendererEnvironment["FORGEPLAY_NETWORK_PROFILE"] =
            networkSelection.rawValue

        let dynamicLibraryPaths = deduplicated(dynamicLibraryDirectories).map(\.path)
        rendererEnvironment["WINEDLLPATH"] = mergedPathList(
            wineDLLPaths,
            existing: rendererEnvironment["WINEDLLPATH"]
        )
        rendererEnvironment["DYLD_LIBRARY_PATH"] = mergedPathList(
            dynamicLibraryPaths,
            existing: rendererEnvironment["DYLD_LIBRARY_PATH"]
        )
        rendererEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = mergedPathList(
            dynamicLibraryPaths,
            existing: rendererEnvironment["DYLD_FALLBACK_LIBRARY_PATH"]
        )

        let overrideModuleNames = deduplicated(
            (modulesByWindowsDirectory["system32", default: []] +
             modulesByWindowsDirectory["syswow64", default: []]).map {
                $0.deletingPathExtension().lastPathComponent.lowercased()
             }
        ).sorted()
        guard !overrideModuleNames.isEmpty else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "exact renderer DLL override"
            )
        }
        rendererEnvironment["WINEDLLOVERRIDES"] = mergedWineDLLOverrides(
            "\(overrideModuleNames.joined(separator: ","))=n,b",
            existing: rendererEnvironment["WINEDLLOVERRIDES"]
        )

        let selectedComponentName: String
        switch policy {
        case .d3dMetal:
            selectedComponentName = "d3dmetal"
        case .dxmt:
            selectedComponentName = "dxmt"
        case .d9vk:
            selectedComponentName = "d9vk"
        case .vulkan:
            selectedComponentName = "dxvk"
        }

        var policyEnvironment = [
            "FORGEPLAY_GAME_RENDERER_POLICY_ENABLED": "1",
            "FORGEPLAY_GAME_RENDERER_POLICY": policy.rawValue,
            "FORGEPLAY_GAME_RENDERER_REQUESTED": requested.rawValue,
            "FORGEPLAY_GAME_RENDERER_COMPONENTS_X64": selectedComponentName,
            "FORGEPLAY_GAME_RENDERER_COMPONENTS_X86":
                x86Directories.isEmpty ? "" : selectedComponentName,
            "FORGEPLAY_GAME_RENDERER_DLL_PATH_X64": x64Directories
                .map(windowsHostPath(for:))
                .joined(separator: ";"),
            "FORGEPLAY_GAME_RENDERER_DLL_PATH_X86": x86Directories
                .map(windowsHostPath(for:))
                .joined(separator: ";"),
            SteamBaseRuntimeCompatibilityHelperContract.environmentKey:
                SteamBaseRuntimeCompatibilityHelperContract.encodedRules
        ]
        for key in gameRendererUnixEnvironmentKeys {
            policyEnvironment["FORGEPLAY_GAME_RENDERER_ENV_\(key)"] =
                rendererEnvironment[key] ?? gameRendererUnsetValue
        }
        return policyEnvironment
    }

    private static func rendererModuleDirectories(_ modules: [URL]) -> [URL] {
        deduplicated(modules.map { $0.deletingLastPathComponent() })
    }

    private func validateActionInputs(for action: RunnerAction) throws {
        switch action {
        case .initializePrefix(_, let prefix, _),
             .migratePrefixRuntime(_, let prefix, _),
             .waitForWinePrefix(_, let prefix, _):
            try requireRunnerDirectory(prefix)
        case .probeRuntime:
            return
        case .installSteam(_, let prefix, let installer, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(installer)
        case .maintainSteamClientService(_, let prefix, let operation, _):
            try requireRunnerDirectory(prefix)
            switch operation {
            case .install:
                try requireRunnerRegularFile(
                    SteamClientServiceContract.sourceExecutable(in: prefix)
                )
            case .query:
                try requireRunnerRegularFile(
                    SteamClientServiceContract.serviceControlExecutable(in: prefix)
                )
            }
        case .requestSteamClientShutdown(_, let prefix, let steamExecutable, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(steamExecutable)
        case .shutdownWinePrefix(_, let prefix, _):
            try requireRunnerDirectory(prefix)
        case .launchSteam(_, let prefix, let steamExecutable, _, _, _, _, _, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(steamExecutable)
        case .launchWindowsUtility(
            _,
            let prefix,
            let executable,
            _,
            _,
            _,
            let externalStorageRoots
        ):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(executable)
            guard executable.pathExtension.lowercased() == "exe" else {
                throw SafeProcessRunnerError.unsafeActionInput(executable)
            }
            for root in externalStorageRoots {
                try requireRunnerDirectory(root)
            }
            let allowedRoots = [prefix] + externalStorageRoots
            guard allowedRoots.contains(where: {
                FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                    from: $0,
                    to: executable,
                    fileManager: fileManager
                )
            }) else {
                throw SafeProcessRunnerError.unsafeActionInput(executable)
            }
        case .extractRuntimeArchive(_, let prefix, let archive, let extractionDirectory, _, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(archive)
            try requireRunnerDirectory(extractionDirectory)
        case .installRuntime(_, let prefix, let installer, _, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(installer)
        case .setWindowsVersion(_, let prefix, _, _),
             .setRegistryValue(_, let prefix, _, _, _, _, _, _),
             .setDLLOverride(_, let prefix, _, _, _),
             .setAppDLLOverride(_, let prefix, _, _, _, _):
            try requireRunnerDirectory(prefix)
        case .deleteRegistryValue(
            _, let prefix, let registryPath, let valueName, _, _
        ), .deleteRegistryValueIfPresent(
            _, let prefix, let registryPath, let valueName, _
        ):
            try requireRunnerDirectory(prefix)
            try Self.requireSafeCommandArgument(
                registryPath,
                name: "registryPath"
            )
            try Self.requireSafeCommandArgument(
                valueName,
                name: "valueName"
            )
        case .deleteAppDLLOverrideIfPresent(
            _, let prefix, let appExecutable, let dll, _
        ):
            try requireRunnerDirectory(prefix)
            try Self.requireSafeCommandArgument(
                appExecutable,
                name: "appExecutable"
            )
            try Self.requireSafeCommandArgument(dll, name: "dll")
        case .createSupportArchive(let sourceDirectory, let destinationZip, _):
            try Self.validateSupportArchivePaths(
                sourceDirectory: sourceDirectory,
                destinationZip: destinationZip,
                fileManager: fileManager
            )
        }
    }

    private func requireRunnerDirectory(_ url: URL) throws {
        try Self.requireNonSymlinkDirectory(url, fileManager: fileManager, unsafeError: SafeProcessRunnerError.unsafeActionInput)
    }

    private nonisolated static func requireSafeCommandArgument(
        _ value: String,
        name: String
    ) throws {
        let metacharacters = CharacterSet(
            charactersIn: "&|<>^%!\"`\r\n\0"
        )
        guard !value.isEmpty,
              value.utf8.count <= 512,
              value.rangeOfCharacter(from: metacharacters) == nil else {
            throw SafeProcessRunnerError.unsafeCommandArgument(name)
        }
    }

    private func requireRunnerRegularFile(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SafeProcessRunnerError.metadataReadFailed(url, message)
        } catch {
            throw SafeProcessRunnerError.unsafeActionInput(url)
        }
    }

    private func requireExecutableFile(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notRegularNonSymlinkFile {
            if fileManager.fileExists(atPath: url.path) {
                throw SafeProcessRunnerError.unsafeExecutable(url)
            }
            throw SafeProcessRunnerError.executableMissing(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SafeProcessRunnerError.metadataReadFailed(url, message)
        } catch {
            throw SafeProcessRunnerError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private nonisolated static func requireNonSymlinkDirectory(
        _ url: URL,
        fileManager: FileManager,
        unsafeError: (URL) -> SafeProcessRunnerError
    ) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SafeProcessRunnerError.metadataReadFailed(url, message)
        } catch {
            throw unsafeError(url)
        }
    }

    nonisolated static func processEnvironment(
        overrides: [String: String],
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = sanitizedParentEnvironment(from: inherited)
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    nonisolated static func managedWineLaunchEnvironmentProjection(
        from environment: [String: String]
    ) -> ManagedWineLaunchEnvironmentProjection? {
        guard environment["WINEPREFIX"]?.isEmpty == false,
              environment["WINELOADER"]?.isEmpty == false else {
            return nil
        }
        let transport = environment[GameModeHostEnvironment.enabledKey] == "1"
            ? "game-mode-host"
            : "wine"
        return ManagedWineLaunchEnvironmentProjection(
            transport: transport,
            rosettaAdvertiseAVX: environment["ROSETTA_ADVERTISE_AVX"],
            policyVersion: environment[
                Helldivers2ManagedWineChildPolicyContract.policyVersionKey
            ],
            hostAuthorization: environment[
                Helldivers2ManagedWineChildPolicyContract.hostAuthorizationKey
            ],
            steamAppID: environment[
                Helldivers2ManagedWineChildPolicyContract.steamAppIDKey
            ],
            canonicalGameRoot: environment[
                Helldivers2ManagedWineChildPolicyContract.canonicalRootKey
            ],
            canonicalGameRootIdentityTelemetryDigest: environment[
                Helldivers2ManagedWineChildPolicyContract
                    .canonicalRootIdentityTelemetryDigestKey
            ],
            manifestRootAuthorizationTelemetryDigest: environment[
                Helldivers2ManagedWineChildPolicyContract
                    .manifestRootAuthorizationTelemetryDigestKey
            ],
            lineageNonce: environment[
                Helldivers2ManagedWineChildPolicyContract.lineageNonceKey
            ],
            heapZeroMemoryRequested: environment[
                Helldivers2ManagedWineChildPolicyContract
                    .heapZeroMemoryRequestedKey
            ],
            gameGuardRendererExclusionRequested: environment[
                Helldivers2ManagedWineChildPolicyContract
                    .gameGuardRendererExclusionRequestedKey
            ],
            rendererSelection: environment[
                "FORGEPLAY_GAME_RENDERER_REQUESTED"
            ],
            networkSelection: environment[
                "FORGEPLAY_NETWORK_PROFILE_REQUESTED"
            ],
            audioInputSelection: environment[
                "FORGEPLAY_AUDIO_INPUT_MODE"
            ],
            synchronizationSelection: environment[
                "FORGEPLAY_SYNCHRONIZATION_SELECTION"
            ],
            synchronizationBackend: environment[
                "FORGEPLAY_SYNCHRONIZATION_BACKEND"
            ]
        )
    }

    private nonisolated static func managedWineChildSynchronizationReadback(
        processIdentifier: Int32
    ) throws -> ManagedWineChildSynchronizationReadback {
        let evidenceURL = URL(
            fileURLWithPath: "/proc/\(processIdentifier)/environment"
        )
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), processIdentifier]
        var byteCount = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), nil, &byteCount, nil, 0)
        }
        guard sizeResult == 0,
              byteCount > MemoryLayout<Int32>.size,
              byteCount <= 1_048_576 else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                evidenceURL
            )
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let readResult = mib.withUnsafeMutableBufferPointer { mibPointer in
            bytes.withUnsafeMutableBytes { bytePointer in
                sysctl(
                    mibPointer.baseAddress,
                    u_int(mibPointer.count),
                    bytePointer.baseAddress,
                    &byteCount,
                    nil,
                    0
                )
            }
        }
        guard readResult == 0,
              byteCount > MemoryLayout<Int32>.size,
              byteCount <= bytes.count else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                evidenceURL
            )
        }
        let boundedBytes = Array(bytes.prefix(byteCount))
        let argc = boundedBytes.withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argc > 0, argc <= 4_096 else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                evidenceURL
            )
        }

        var cursor = MemoryLayout<Int32>.size
        func readCString() -> String? {
            guard cursor < boundedBytes.count else { return nil }
            let start = cursor
            while cursor < boundedBytes.count && boundedBytes[cursor] != 0 {
                cursor += 1
            }
            guard cursor < boundedBytes.count,
                  let value = String(
                    bytes: boundedBytes[start..<cursor],
                    encoding: .utf8
                  ) else {
                return nil
            }
            cursor += 1
            return value
        }
        guard let executablePath = readCString(), !executablePath.isEmpty else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                evidenceURL
            )
        }
        while cursor < boundedBytes.count && boundedBytes[cursor] == 0 {
            cursor += 1
        }
        for _ in 0..<Int(argc) {
            guard readCString() != nil else {
                throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                    evidenceURL
                )
            }
        }
        while cursor < boundedBytes.count && boundedBytes[cursor] == 0 {
            cursor += 1
        }
        var environment: [String: String] = [:]
        while cursor < boundedBytes.count {
            guard let row = readCString() else {
                throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                    evidenceURL
                )
            }
            if row.isEmpty { continue }
            guard let separator = row.firstIndex(of: "=") else {
                throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                    evidenceURL
                )
            }
            let key = String(row[..<separator])
            let value = String(row[row.index(after: separator)...])
            guard !key.isEmpty, environment.updateValue(value, forKey: key) == nil else {
                throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                    evidenceURL
                )
            }
        }
        guard environment["FORGEPLAY_SYNCHRONIZATION_SELECTION"] ==
                WineSynchronizationSelection.automatic.rawValue,
              environment["FORGEPLAY_SYNCHRONIZATION_BACKEND"] ==
                WineSynchronizationBackend.server.rawValue else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                evidenceURL
            )
        }
        return ManagedWineChildSynchronizationReadback(
            processIdentifier: processIdentifier,
            selection: .automatic,
            backend: .server
        )
    }

    private nonisolated static func sanitizedParentEnvironment(from inherited: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": defaultExecutableSearchPath
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        for (key, value) in inherited where key == "LC_ALL" || key.hasPrefix("LC_") {
            if !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    private static func windowsPath(for url: URL, in prefix: URL) -> String? {
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory).standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(driveC + "/") else {
            return nil
        }
        let relative = String(target.dropFirst(driveC.count + 1))
        return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    private static func windowsHostPath(for url: URL) -> String {
        "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    private func steamLaunchInvocation(
        for executable: URL,
        prefix _: URL,
        steamCommand: [String]
    ) -> (executable: URL, arguments: [String], validatesStartup: Bool) {
        if let steamLauncher = Self.forgePlaySteamLauncherExecutable(
            for: executable,
            fileManager: fileManager
        ) {
            return (
                executable,
                [steamLauncher.path, "--detach", "--"] + steamCommand,
                true
            )
        }

        return (
            executable,
            steamCommand,
            true
        )
    }

    private static func installerCommand(for installer: URL) -> [String] {
        if installer.pathExtension.lowercased() == "msi" {
            return ["msiexec", "/i", installer.path]
        }
        return [installer.path]
    }

    private nonisolated static func externalStorageGrantPublicationFailureCode(
        for error: Error
    ) -> String {
        guard let grantError =
                error as? SteamExternalStorageProcessGrantError else {
            return "publisher-error"
        }
        switch grantError {
        case .invalidRunIdentifier:
            return "run-identifier-invalid"
        case .externalStorageRootRequired:
            return "root-required"
        case .tooManyRoots:
            return "root-limit-exceeded"
        case .applicationGroupUnavailable:
            return "application-group-unavailable"
        case .bridgeUnavailable:
            return "bridge-unavailable"
        case .invalidExternalStorageRoot:
            return "root-invalid"
        case .bookmarkCreationFailed:
            return "bookmark-creation-failed"
        case .manifestTooLarge:
            return "manifest-size-exceeded"
        case .unsafeGrantDirectory:
            return "grant-directory-unsafe"
        case .unsafeGrantFile:
            return "grant-file-unsafe"
        case .grantPersistenceFailed:
            return "grant-persistence-failed"
        case .staleGrantCleanupFailed:
            return "grant-cleanup-failed"
        }
    }

    private nonisolated static func actionPreparationRuntimeCompatibility(
        for error: Error
    ) -> [String: String]? {
        guard let preparationError = error as?
                SteamExternalStorageGrantPreparationError else {
            return nil
        }
        var compatibility = [
            "externalStorageGrantPublicationStatus": "failed",
            "externalStorageGrantPublicationFailureReason":
                preparationError.reasonCode,
            "externalStorageGrantRequiredForLaunch": "true"
        ]
        if preparationError.requiredForManagedChild {
            compatibility["externalStorageGrantRequiredForManagedChild"] =
                "true"
        }
        return compatibility
    }

    private nonisolated static func runtimeCompatibilityDiagnostics(
        from environment: [String: String]
    ) -> [String: String] {
        let fields = [
            ("synchronizationSelection", "FORGEPLAY_SYNCHRONIZATION_SELECTION"),
            ("synchronizationBackend", "FORGEPLAY_SYNCHRONIZATION_BACKEND"),
            ("gameRendererRequested", "FORGEPLAY_GAME_RENDERER_REQUESTED"),
            ("gameRendererPolicy", "FORGEPLAY_GAME_RENDERER_POLICY"),
            ("gameRendererCorrelationID", "FORGEPLAY_GAME_RENDERER_CORRELATION_ID"),
            ("gameRendererComponentsX64", "FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"),
            ("gameRendererComponentsX86", "FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"),
            ("networkProfile", "FORGEPLAY_NETWORK_PROFILE_REQUESTED"),
            ("audioInputMode", "FORGEPLAY_AUDIO_INPUT_MODE"),
            ("gameModeHostRequested", "FORGEPLAY_GAME_MODE_HOST_REQUESTED"),
            ("gameModeHostAvailability", "FORGEPLAY_GAME_MODE_HOST_AVAILABILITY"),
            ("gameModeHostDisabledReason", "FORGEPLAY_GAME_MODE_HOST_DISABLED_REASON"),
            ("gameModeHostBundleIdentifier", "FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER"),
            ("gameModeHostExecutableSHA256", "FORGEPLAY_GAME_MODE_HOST_EXECUTABLE_SHA256"),
            ("gameModeHostRunIdentifier", "FORGEPLAY_GAME_MODE_HOST_RUN_ID"),
            (
                "externalStorageGrantRunIdentifier",
                SteamExternalStorageProcessGrant.runIdentifierEnvironmentKey
            ),
            (
                "externalStorageGrantSHA256",
                SteamExternalStorageProcessGrant.manifestSHA256EnvironmentKey
            )
        ]
        return fields.reduce(into: [String: String]()) { result, field in
            guard let value = environment[field.1], !value.isEmpty else { return }
            result[field.0] = value
        }
    }

    /// Routed games replace the real loader variables, but an excluded Steam
    /// infrastructure child can be launched by that game and inherit them. Keep
    /// a host-owned snapshot of the pristine Steam environment so Wine can scrub
    /// the renderer state without discarding the base runtime search paths.
    private nonisolated static func captureSteamBaseRendererEnvironment(
        in environment: inout [String: String]
    ) {
        for profileKey in gameRendererUnixEnvironmentKeys {
            let actualKey = profileKey == "D3DMETAL_SHARED_LIBRARY"
                ? "FORGEPLAY_D3DMETAL_SHARED_LIBRARY"
                : profileKey
            environment["FORGEPLAY_GAME_RENDERER_BASE_ENV_\(profileKey)"] =
                environment[actualKey] ?? gameRendererUnsetValue
        }
    }

    static func runnerEnvironment(
        for executable: URL,
        base: [String: String] = [:],
        graphicsBackend: SteamRendererPolicyPreference? = nil,
        exposesVulkanICD: Bool = false,
        injectGraphicsDLLOverrides: Bool = true,
        allowsInvalidPrefixSynchronizationProfileForCleanup: Bool = false,
        rosettaAVXPolicy suppliedRosettaAVXPolicy:
            ManagedWineRosettaAVXPolicyV1? = nil,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        primaryApplicationGroupIdentifier: String? =
            ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
        applicationGroupContainerResolver: ((String) -> URL?)? = nil,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws -> [String: String] {
        var environment = base
        // Launch admission supplies its one captured ambient policy. Commands
        // without a supplied launch snapshot are lifecycle/control work and
        // use ForgePlay's trusted default, independent of a malformed host
        // override, so recovery remains available.
        let rosettaAVXPolicy = suppliedRosettaAVXPolicy ?? .managedDefault
        rosettaAVXPolicy.apply(to: &environment)
        var supplementalRendererRoot: URL?
        if let prefixPath = environment["WINEPREFIX"], !prefixPath.isEmpty {
            let prefix = URL(fileURLWithPath: prefixPath, isDirectory: true)
            let synchronizationProfile: PrefixSynchronizationProfile
            do {
                synchronizationProfile = try appliedSynchronizationProfile(
                    in: prefix
                )
            } catch {
                guard allowsInvalidPrefixSynchronizationProfileForCleanup else {
                    throw error
                }
                synchronizationProfile = PrefixSynchronizationProfile(
                    selection: .automatic,
                    backend: .server
                )
            }
            applySynchronizationProfile(synchronizationProfile, to: &environment)
            if graphicsBackend == .d3dMetal,
               let candidate = usableSupplementalRendererRoot(
                containingPrefix: prefix
               ) {
                try supplementalRendererAuthenticator.authenticate(
                    rendererRoot: candidate,
                    fileManager: .default
                )
                supplementalRendererRoot = candidate
            }
            if let applicationGroupIdentifier =
                    primaryApplicationGroupIdentifier {
                let applicationGroupContainer: URL?
                if let applicationGroupContainerResolver {
                    applicationGroupContainer = applicationGroupContainerResolver(
                        applicationGroupIdentifier
                    )
                } else {
                    applicationGroupContainer = FileManager.default.containerURL(
                        forSecurityApplicationGroupIdentifier:
                            applicationGroupIdentifier
                    )
                }
                guard let applicationGroupContainer else {
                    throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
                }
                let serverRoot = wineServerRoot(
                    forPrefix: prefix,
                    sandboxEnabled: true,
                    applicationGroupContainerURL: applicationGroupContainer
                )
                try prepareWineServerRoot(
                    serverRoot,
                    trustedAncestor: applicationGroupContainer,
                    privateTailComponentCount: 2
                )
                environment["WINE_SERVER_ROOT"] = serverRoot.path
                let machServiceName = wineMachServiceName(
                    forPrefix: prefix,
                    applicationGroupIdentifier: applicationGroupIdentifier
                )
                environment["WINE_MACH_SERVICE_NAME"] = machServiceName
            } else {
                guard !sandboxEnabled else {
                    throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
                }
                let serverRoot = wineServerRoot(
                    forPrefix: prefix,
                    sandboxEnabled: false
                )
                try prepareWineServerRoot(serverRoot, trustedAncestor: prefix)
                environment["WINE_SERVER_ROOT"] = serverRoot.path
                environment.removeValue(forKey: "WINE_MACH_SERVICE_NAME")
            }
        }
        let rendererUsesVulkan = try rendererCompositionRequiresVulkan(
            for: executable,
            graphicsBackend: graphicsBackend
        )
        let exposesRequiredVulkanICD = exposesVulkanICD || rendererUsesVulkan
        let searchPaths = try runnerSearchPaths(
            for: executable,
            graphicsBackend: graphicsBackend,
            exposesVulkanICD: exposesRequiredVulkanICD,
            supplementalRendererRoot: supplementalRendererRoot
        )
        if injectGraphicsDLLOverrides {
            applyGraphicsBackend(
                graphicsBackend,
                to: &environment
            )
        }
        if !searchPaths.dynamicLibraries.isEmpty {
            environment["DYLD_LIBRARY_PATH"] = mergedPathList(
                searchPaths.dynamicLibraries,
                existing: nil
            )
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = mergedPathList(
                searchPaths.dynamicLibraries,
                existing: nil
            )
        }
        if !searchPaths.frameworks.isEmpty {
            environment["DYLD_FRAMEWORK_PATH"] = mergedPathList(
                searchPaths.frameworks,
                existing: environment["DYLD_FRAMEWORK_PATH"]
            )
        }
        if (graphicsBackend == .d3dMetal || graphicsBackend == .dxmt),
           environment["D3DMETAL_FRAMEWORK_PATH"] == nil,
           let d3dMetalFramework = searchPaths.d3dMetalFrameworkExecutables.first {
            environment["D3DMETAL_FRAMEWORK_PATH"] = d3dMetalFramework
        }
        if Self.shouldSuppressVulkanICD(
            for: graphicsBackend,
            explicitSteamClientExposure: exposesRequiredVulkanICD
        ) {
            environment["VK_ICD_FILENAMES"] = "/dev/null"
            environment["VK_DRIVER_FILES"] = "/dev/null"
        } else if !searchPaths.vulkanICDs.isEmpty {
            let icdPathList = mergedPathList(
                searchPaths.vulkanICDs,
                existing: environment["VK_ICD_FILENAMES"]
            )
            environment["VK_ICD_FILENAMES"] = icdPathList
            environment["VK_DRIVER_FILES"] = mergedPathList(
                searchPaths.vulkanICDs,
                existing: environment["VK_DRIVER_FILES"]
            )
        }

        if let binDirectory = wineBinDirectory(for: executable) {
            environment["PATH"] = mergedPathList(
                [binDirectory.path],
                existing: defaultExecutableSearchPath
            )
            let wineloader = binDirectory.appending(path: "wine.bin")
            if FileSystemItemPolicy.isRegularNonSymlinkFile(wineloader) &&
                FileManager.default.isExecutableFile(atPath: wineloader.path) {
                environment["WINELOADER"] = wineloader.path
            }
            if let steamLauncher = forgePlaySteamLauncherExecutable(for: executable) {
                environment["FORGEPLAY_STEAM_LAUNCHER"] = steamLauncher.path
            }
            let wineserver = binDirectory.appending(path: "wineserver")
            if FileSystemItemPolicy.isRegularNonSymlinkFile(wineserver) &&
                FileManager.default.isExecutableFile(atPath: wineserver.path) {
                environment["WINESERVER"] = wineserver.path
            }
        }

        if let wineRoot = wineRootDirectory(for: executable) {
            let gstreamerRoot = wineRoot.appending(
                path: "gstreamer",
                directoryHint: .isDirectory
            )
            let pluginDirectory = gstreamerRoot.appending(
                path: "lib/gstreamer-1.0",
                directoryHint: .isDirectory
            )
            if FileSystemItemPolicy.isNonSymlinkDirectory(
                pluginDirectory,
                fileManager: FileManager.default
            ), FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: wineRoot,
                to: pluginDirectory,
                fileManager: FileManager.default
            ) {
                // Only load the reviewed, runtime-bundled plug-ins. Allowing a
                // host installation into this process would make Media
                // Foundation support depend on machine state and architecture.
                environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = ""
                environment["GST_PLUGIN_PATH_1_0"] = pluginDirectory.path
            }
        }

        if !searchPaths.wineDLLs.isEmpty {
            environment["WINEDLLPATH"] = mergedPathList(
                searchPaths.wineDLLs,
                existing: nil
            )
        }

        return environment
    }

    nonisolated static func wineServerRoot(
        forPrefix prefix: URL,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationGroupContainerURL: URL? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        if sandboxEnabled {
            let sharedContainer = applicationGroupContainerURL ?? temporaryDirectory
            return sharedContainer
                .appending(path: "Library/Caches/ForgePlay/WineServer", directoryHint: .isDirectory)
                .appending(
                    path: wineServerScopeIdentifier(forPrefix: prefix),
                    directoryHint: .isDirectory
                )
                .standardizedFileURL
        }
        return prefix
            .appending(path: ".forgeplay-wineserver", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// Creates the per-prefix Wine server directory without following a
    /// symlink at any path component. Wine transports process-scoped IPC
    /// through this directory, so accepting a replaced component would let a
    /// different filesystem location impersonate the selected prefix scope.
    nonisolated static func prepareWineServerRoot(
        _ root: URL,
        trustedAncestor: URL,
        privateTailComponentCount: Int = 1
    ) throws {
        do {
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                root,
                trustedAncestor: trustedAncestor,
                privateTailComponentCount: privateTailComponentCount
            )
        } catch {
            throw SafeProcessRunnerError.unsafeWineServerRoot(
                root.standardizedFileURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    nonisolated static func wineMachServiceName(
        forPrefix prefix: URL,
        applicationGroupIdentifier: String
    ) -> String {
        "\(applicationGroupIdentifier).wineserver.\(wineServerScopeIdentifier(forPrefix: prefix))"
    }

    nonisolated static func wineServerScopeIdentifier(forPrefix prefix: URL) -> String {
        let canonicalPrefixPath = prefix.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return SHA256.hash(data: Data(canonicalPrefixPath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func rendererWindowsModuleFiles(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        prefix: URL? = nil,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws -> [URL] {
        try rendererWindowsModuleFilesByWindowsDirectory(
            for: executable,
            graphicsBackend: graphicsBackend,
            prefix: prefix,
            supplementalRendererAuthenticator:
                supplementalRendererAuthenticator
        )["system32"] ?? []
    }

    /// Resolves the exact modules required for the experimental NVIDIA-facing
    /// MetalFX route. Both NVAPI names are staged because Apple's 64-bit module
    /// is requested as `nvapi64.dll` but identifies itself as `nvapi.dll`.
    static func d3dMetalNVIDIAMetalFXSystem32Modules(
        for executable: URL,
        prefix: URL,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws -> [URL] {
        let rendererRoot = try requiredD3DMetalRendererRoot(
            for: executable,
            prefix: prefix,
            scope: .direct3D12,
            requiresNVIDIACompatibility: true,
            supplementalRendererAuthenticator:
                supplementalRendererAuthenticator
        )
        let bridgeRoot = try D3DMetalNGXBridgeContract.materialize(
            from: rendererRoot,
            in: prefix
        )
        let modules = [
            rendererRoot.appending(
                path: "wine/x86_64-windows/nvapi64.dll"
            ),
            rendererRoot.appending(
                path: D3DMetalNVAPIAliasContract.windowsAliasRelativePath
            ),
            bridgeRoot.appending(
                path: D3DMetalNGXBridgeContract.windowsModuleRelativePath
            )
        ]
        for module in modules {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(module)
        }
        return modules
    }

    static func rendererWindowsModuleFilesByWindowsDirectory(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        prefix: URL? = nil,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) throws -> [String: [URL]] {
        let fileManager = FileManager.default
        var modulesByWindowsDirectory: [String: [URL]] = [:]

        if let wineRoot = wineRootDirectory(for: executable) {
            let runtimeRoot = wineRoot.deletingLastPathComponent()
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                frameworks: runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: runtimeRoot,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
            switch graphicsBackend {
            case .d3dMetal:
                let appleD3DMetal = wineRoot.appending(path: "lib64/apple_gptk", directoryHint: .isDirectory)
                if rendererComponentIsUsable(named: "d3dmetal", at: appleD3DMetal, fileManager: fileManager) {
                    try appendRendererWindowsModuleFilesByWindowsDirectory(
                        wineModulesRoot: appleD3DMetal.appending(path: "wine", directoryHint: .isDirectory),
                        fileManager: fileManager,
                        modulesByWindowsDirectory: &modulesByWindowsDirectory
                    )
                }
            case .dxmt:
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: runtimeRoot.appending(
                        path: "Frameworks/renderer/dxmt/wine",
                        directoryHint: .isDirectory
                    ),
                    fileManager: fileManager,
                    modulesByWindowsDirectory: &modulesByWindowsDirectory
                )
            case .d9vk:
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: runtimeRoot.appending(
                        path: "Frameworks/renderer/d9vk/wine",
                        directoryHint: .isDirectory
                    ),
                    fileManager: fileManager,
                    modulesByWindowsDirectory: &modulesByWindowsDirectory
                )
            case .vulkan:
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: wineRoot.appending(path: "lib/dxvk", directoryHint: .isDirectory),
                    fileManager: fileManager,
                    modulesByWindowsDirectory: &modulesByWindowsDirectory
                )
            }
        }
        if let contents = bundleContentsDirectory(for: executable) {
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                frameworks: contents.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: contents,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }
        if graphicsBackend == .d3dMetal,
           let prefix,
           let supplementalRendererRoot = usableSupplementalRendererRoot(containingPrefix: prefix),
           rendererComponentIsUsable(
            named: "d3dmetal",
            at: supplementalRendererRoot,
            fileManager: fileManager
           ) {
            try supplementalRendererAuthenticator.authenticate(
                rendererRoot: supplementalRendererRoot,
                fileManager: fileManager
            )
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: supplementalRendererRoot.appending(path: "wine", directoryHint: .isDirectory),
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }

        return modulesByWindowsDirectory.mapValues { modules in
            let deduplicatedModules = deduplicated(modules)
            guard graphicsBackend == .d3dMetal else {
                return deduplicatedModules
            }
            return deduplicatedModules.filter { module in
                let moduleName = module.lastPathComponent.lowercased()
                guard moduleName == "d3d12.dll" ||
                        moduleName == "d3d12core.dll" else {
                    return true
                }
                let rendererRoot = module
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                return D3DMetalRendererPayloadContract.isUsable(
                    for: .direct3D12,
                    at: rendererRoot,
                    fileManager: fileManager
                )
            }
        }
    }

    private static func rendererWindowsModuleFilesByWindowsDirectory(
        forNamedComponent componentName: String,
        executable: URL,
        prefix: URL? = nil
    ) throws -> [String: [URL]] {
        let fileManager = FileManager.default
        var modulesByWindowsDirectory: [String: [URL]] = [:]

        for contentsDirectory in rendererSupportContentsDirectories(for: executable) {
            let componentRoot = contentsDirectory
                .appending(path: "Frameworks/renderer", directoryHint: .isDirectory)
                .appending(path: componentName, directoryHint: .isDirectory)
            guard rendererComponentIsUsable(
                named: componentName,
                at: componentRoot,
                fileManager: fileManager
            ) else {
                continue
            }
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: componentRoot.appending(path: "wine", directoryHint: .isDirectory),
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }
        if componentName == "d3dmetal",
           let prefix,
           let supplementalRendererRoot = usableSupplementalRendererRoot(containingPrefix: prefix),
           rendererComponentIsUsable(
            named: componentName,
            at: supplementalRendererRoot,
            fileManager: fileManager
           ) {
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: supplementalRendererRoot.appending(
                    path: "wine",
                    directoryHint: .isDirectory
                ),
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }
        return modulesByWindowsDirectory.mapValues(deduplicated)
    }

    private static func applyGraphicsBackend(
        _ graphicsBackend: SteamRendererPolicyPreference?,
        to environment: inout [String: String]
    ) {
        guard let graphicsBackend else { return }
        let override: String?
        switch graphicsBackend {
        case .d3dMetal:
            override = [
                "\(direct3DDLLOverrideGroup)=n,b",
                "winemetal=n,b"
            ].joined(separator: ";")
        case .dxmt:
            override = [
                "\(direct3DDLLOverrideGroup)=n,b",
                "winemetal=n,b"
            ].joined(separator: ";")
        case .d9vk, .vulkan:
            override = "\(direct3DDLLOverrideGroup)=n,b"
        }
        guard let override else { return }
        environment["WINEDLLOVERRIDES"] = mergedWineDLLOverrides(
            override,
            existing: environment["WINEDLLOVERRIDES"]
        )
    }

    private static func runnerSearchPaths(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?,
        exposesVulkanICD: Bool,
        supplementalRendererRoot: URL?
    ) throws -> RunnerSearchPaths {
        let fileManager = FileManager.default
        var dynamicLibraryPaths: [String] = []
        var frameworkPaths: [String] = []
        var d3dMetalFrameworkExecutables: [String] = []
        var rendererWineDLLPaths: [String] = []
        var baseWineDLLPaths: [String] = []
        var vulkanICDs: [String] = []

        if let wineRoot = wineRootDirectory(for: executable) {
            let lib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(lib, fileManager: fileManager) {
                dynamicLibraryPaths.append(lib.path)
            }
            let gstreamerLib = wineRoot.appending(
                path: "gstreamer/lib",
                directoryHint: .isDirectory
            )
            if FileSystemItemPolicy.isNonSymlinkDirectory(
                gstreamerLib,
                fileManager: fileManager
            ), FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: wineRoot,
                to: gstreamerLib,
                fileManager: fileManager
            ) {
                dynamicLibraryPaths.append(gstreamerLib.path)
            }
            let lib64 = wineRoot.appending(path: "lib64", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(lib64, fileManager: fileManager) {
                dynamicLibraryPaths.append(lib64.path)
            }
            if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
                vulkanICDs.append(contentsOf: vulkanICDFiles(in: wineRoot, fileManager: fileManager))
            }
            let dllPath = wineRoot.appending(path: "lib/wine", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(dllPath, fileManager: fileManager) {
                baseWineDLLPaths.append(contentsOf: wineDLLSearchDirectories(for: dllPath, fileManager: fileManager))
            }
            let appleD3DMetal = wineRoot.appending(path: "lib64/apple_gptk", directoryHint: .isDirectory)
            if graphicsBackend == .d3dMetal || graphicsBackend == .dxmt,
               FileSystemItemPolicy.isNonSymlinkDirectory(appleD3DMetal, fileManager: fileManager),
               rendererComponentIsUsable(named: "d3dmetal", at: appleD3DMetal, fileManager: fileManager) {
                let external = appleD3DMetal.appending(path: "external", directoryHint: .isDirectory)
                appendD3DMetalExternalPathsIfComplete(
                    in: external,
                    fileManager: fileManager,
                    dynamicLibraryPaths: &dynamicLibraryPaths,
                    frameworkPaths: &frameworkPaths,
                    d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
                )
                let appleD3DMetalWine = appleD3DMetal.appending(path: "wine", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(appleD3DMetalWine, fileManager: fileManager) {
                    rendererWineDLLPaths.append(contentsOf: wineDLLSearchDirectories(for: appleD3DMetalWine, fileManager: fileManager))
                    let unix = appleD3DMetalWine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
                    if FileSystemItemPolicy.isNonSymlinkDirectory(unix, fileManager: fileManager) {
                        dynamicLibraryPaths.append(unix.path)
                    }
                }
            }
            if graphicsBackend == .vulkan {
                let dxvk = wineRoot.appending(path: "lib/dxvk", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(dxvk, fileManager: fileManager) {
                    rendererWineDLLPaths.append(contentsOf: wineDLLSearchDirectories(for: dxvk, fileManager: fileManager))
                }
            }
            let external = wineRoot.appending(path: "lib/external", directoryHint: .isDirectory)
            if graphicsBackend == .d3dMetal,
               FileSystemItemPolicy.isNonSymlinkDirectory(external, fileManager: fileManager) {
                appendD3DMetalExternalPathsIfComplete(
                    in: external,
                    fileManager: fileManager,
                    dynamicLibraryPaths: &dynamicLibraryPaths,
                    frameworkPaths: &frameworkPaths,
                    d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
                )
            }
            let runtimeRoot = wineRoot.deletingLastPathComponent()
            try appendFrameworkSearchPaths(
                frameworks: runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: runtimeRoot,
                graphicsBackend: graphicsBackend,
                exposesVulkanICD: exposesVulkanICD,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables,
                rendererWineDLLPaths: &rendererWineDLLPaths,
                vulkanICDs: &vulkanICDs
            )
        }

        return try runnerSearchPaths(
            executable: executable,
            graphicsBackend: graphicsBackend,
            exposesVulkanICD: exposesVulkanICD,
            fileManager: fileManager,
            dynamicLibraryPaths: dynamicLibraryPaths,
            frameworkPaths: frameworkPaths,
            d3dMetalFrameworkExecutables: d3dMetalFrameworkExecutables,
            rendererWineDLLPaths: rendererWineDLLPaths,
            baseWineDLLPaths: baseWineDLLPaths,
            vulkanICDs: vulkanICDs,
            supplementalRendererRoot: supplementalRendererRoot
        )
    }

    private static func usableSupplementalRendererRoot(containingPrefix prefix: URL) -> URL? {
        guard let rendererRoot = ForgePlaySupplementalRendererPolicy.rendererRoot(containingPrefix: prefix),
              FileSystemItemPolicy.isNonSymlinkDirectory(rendererRoot) else {
            return nil
        }
        return rendererRoot
    }

    private static func appendStandaloneRendererSearchPaths(
        rendererRoot: URL,
        fileManager: FileManager,
        dynamicLibraryPaths: inout [String],
        frameworkPaths: inout [String],
        d3dMetalFrameworkExecutables: inout [String],
        rendererWineDLLPaths: inout [String]
    ) {
        dynamicLibraryPaths.append(rendererRoot.path)
        let external = rendererRoot.appending(path: "external", directoryHint: .isDirectory)
        if FileSystemItemPolicy.isNonSymlinkDirectory(external, fileManager: fileManager) {
            appendD3DMetalExternalPathsIfComplete(
                in: external,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
            )
        }

        let wine = rendererRoot.appending(path: "wine", directoryHint: .isDirectory)
        guard FileSystemItemPolicy.isNonSymlinkDirectory(wine, fileManager: fileManager) else { return }
        rendererWineDLLPaths.append(contentsOf: rendererWineDLLSearchDirectories(
            for: wine,
            rendererName: "d3dmetal",
            compositionHasD3DMetal: true,
            fileManager: fileManager
        ))
        let unix = wine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        if FileSystemItemPolicy.isNonSymlinkDirectory(unix, fileManager: fileManager) {
            dynamicLibraryPaths.append(unix.path)
        }
    }

    private static func runnerSearchPaths(
        executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?,
        exposesVulkanICD: Bool,
        fileManager: FileManager,
        dynamicLibraryPaths initialDynamicLibraryPaths: [String],
        frameworkPaths initialFrameworkPaths: [String],
        d3dMetalFrameworkExecutables initialD3DMetalFrameworkExecutables: [String],
        rendererWineDLLPaths initialRendererWineDLLPaths: [String],
        baseWineDLLPaths initialBaseWineDLLPaths: [String],
        vulkanICDs initialVulkanICDs: [String],
        supplementalRendererRoot: URL?
    ) throws -> RunnerSearchPaths {
        var dynamicLibraryPaths = initialDynamicLibraryPaths
        var frameworkPaths = initialFrameworkPaths
        var d3dMetalFrameworkExecutables = initialD3DMetalFrameworkExecutables
        var rendererWineDLLPaths = initialRendererWineDLLPaths
        let baseWineDLLPaths = initialBaseWineDLLPaths
        var vulkanICDs = initialVulkanICDs

        if let contents = bundleContentsDirectory(for: executable) {
            if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
                vulkanICDs.append(contentsOf: vulkanICDFiles(in: contents, fileManager: fileManager))
            }
            try appendFrameworkSearchPaths(
                frameworks: contents.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: contents,
                graphicsBackend: graphicsBackend,
                exposesVulkanICD: exposesVulkanICD,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables,
                rendererWineDLLPaths: &rendererWineDLLPaths,
                vulkanICDs: &vulkanICDs
            )
        }
        if graphicsBackend == .d3dMetal,
           let supplementalRendererRoot,
           rendererComponentIsUsable(
            named: "d3dmetal",
            at: supplementalRendererRoot,
            fileManager: fileManager
           ) {
            appendStandaloneRendererSearchPaths(
                rendererRoot: supplementalRendererRoot,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables,
                rendererWineDLLPaths: &rendererWineDLLPaths
            )
        }

        return RunnerSearchPaths(
            dynamicLibraries: deduplicated(dynamicLibraryPaths),
            frameworks: deduplicated(frameworkPaths),
            d3dMetalFrameworkExecutables: deduplicated(d3dMetalFrameworkExecutables),
            wineDLLs: deduplicated(rendererWineDLLPaths + baseWineDLLPaths),
            vulkanICDs: deduplicated(vulkanICDs)
        )
    }

    private static func appendFrameworkSearchPaths(
        frameworks: URL,
        contentsDirectory: URL,
        graphicsBackend: SteamRendererPolicyPreference?,
        exposesVulkanICD: Bool,
        fileManager: FileManager,
        dynamicLibraryPaths: inout [String],
        frameworkPaths: inout [String],
        d3dMetalFrameworkExecutables: inout [String],
        rendererWineDLLPaths: inout [String],
        vulkanICDs: inout [String]
    ) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(frameworks, fileManager: fileManager) else {
            return
        }

        // Keep general host support libraries on DYLD_FALLBACK_LIBRARY_PATH. Putting this
        // directory on DYLD_LIBRARY_PATH lets GNU libiconv override macOS libiconv for
        // Wine's Homebrew-built TLS dependencies, which makes GnuTLS fail to load.
        if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
            vulkanICDs.append(contentsOf: vulkanICDFiles(in: frameworks, fileManager: fileManager))
        }

        let renderer = frameworks.appending(path: "renderer", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: renderer.path) {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(renderer, fileManager: fileManager) else {
                return
            }
            let rendererContents: [URL]
            do {
                rendererContents = try fileManager.contentsOfDirectory(
                    at: renderer,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SafeProcessRunnerError.runnerLibrarySearchFailed(renderer, error)
            }
            let rendererDirectories = selectedRendererDirectories(
                from: rendererContents,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager
            )
            let compositionHasD3DMetal = rendererDirectories.contains {
                $0.lastPathComponent.caseInsensitiveCompare("d3dmetal") == .orderedSame
            }
            for url in rendererDirectories {
                dynamicLibraryPaths.append(url.path)
                let external = url.appending(path: "external", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(external, fileManager: fileManager) {
                    appendD3DMetalExternalPathsIfComplete(
                        in: external,
                        fileManager: fileManager,
                        dynamicLibraryPaths: &dynamicLibraryPaths,
                        frameworkPaths: &frameworkPaths,
                        d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
                    )
                }
                if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
                    vulkanICDs.append(contentsOf: vulkanICDFiles(in: url, fileManager: fileManager))
                }
                let wine = url.appending(path: "wine", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(wine, fileManager: fileManager) {
                    rendererWineDLLPaths.append(contentsOf: rendererWineDLLSearchDirectories(
                        for: wine,
                        rendererName: url.lastPathComponent.lowercased(),
                        compositionHasD3DMetal: compositionHasD3DMetal,
                        fileManager: fileManager
                    ))
                    let unix = wine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
                    if FileSystemItemPolicy.isNonSymlinkDirectory(unix, fileManager: fileManager) {
                        dynamicLibraryPaths.append(unix.path)
                    }
                }
            }
        }

    }

    private static func appendRendererWindowsModuleFilesByWindowsDirectory(
        frameworks: URL,
        contentsDirectory: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        fileManager: FileManager,
        modulesByWindowsDirectory: inout [String: [URL]]
    ) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(frameworks, fileManager: fileManager) else {
            return
        }
        let renderer = frameworks.appending(path: "renderer", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: renderer.path) else {
            return
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(renderer, fileManager: fileManager) else {
            return
        }
        let rendererContents: [URL]
        do {
            rendererContents = try fileManager.contentsOfDirectory(
                at: renderer,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SafeProcessRunnerError.runnerLibrarySearchFailed(renderer, error)
        }
        let rendererDirectories = selectedRendererDirectories(
            from: rendererContents,
            graphicsBackend: graphicsBackend,
            fileManager: fileManager
        )
        let compositionHasD3DMetal = rendererDirectories.contains {
            $0.lastPathComponent.caseInsensitiveCompare("d3dmetal") == .orderedSame
        }
        for url in rendererDirectories {
            let rendererName = url.lastPathComponent.lowercased()
            for mapping in rendererWindowsModuleDirectoryMappings {
                guard shouldUseRendererComponent(
                    rendererName,
                    forWindowsDirectory: mapping.windowsDirectory,
                    compositionHasD3DMetal: compositionHasD3DMetal
                ) else {
                    continue
                }
                let windowsModules = url.appending(path: "wine/\(mapping.rendererDirectory)", directoryHint: .isDirectory)
                guard FileSystemItemPolicy.isNonSymlinkDirectory(windowsModules, fileManager: fileManager) else {
                    continue
                }
                let files: [URL]
                do {
                    files = try fileManager.contentsOfDirectory(
                        at: windowsModules,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    throw SafeProcessRunnerError.runnerLibrarySearchFailed(windowsModules, error)
                }
                for file in files {
                    let moduleName = file.lastPathComponent.lowercased()
                    guard rendererBridgeDLLNames.contains(moduleName),
                          FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager) else {
                        continue
                    }
                    var modules = modulesByWindowsDirectory[mapping.windowsDirectory, default: []]
                    guard !modules.contains(where: { $0.lastPathComponent.lowercased() == moduleName }) else {
                        continue
                    }
                    modules.append(file)
                    modulesByWindowsDirectory[mapping.windowsDirectory] = modules
                }
            }
        }
    }

    private static func appendRendererWindowsModuleFilesByWindowsDirectory(
        wineModulesRoot: URL,
        fileManager: FileManager,
        modulesByWindowsDirectory: inout [String: [URL]]
    ) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(wineModulesRoot, fileManager: fileManager) else {
            return
        }
        for mapping in rendererWindowsModuleDirectoryMappings {
            let windowsModules = wineModulesRoot.appending(path: mapping.rendererDirectory, directoryHint: .isDirectory)
            guard FileSystemItemPolicy.isNonSymlinkDirectory(windowsModules, fileManager: fileManager) else {
                continue
            }
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: windowsModules,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SafeProcessRunnerError.runnerLibrarySearchFailed(windowsModules, error)
            }
            for file in files {
                let moduleName = file.lastPathComponent.lowercased()
                guard rendererBridgeDLLNames.contains(moduleName),
                      FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager) else {
                    continue
                }
                var modules = modulesByWindowsDirectory[mapping.windowsDirectory, default: []]
                guard !modules.contains(where: { $0.lastPathComponent.lowercased() == moduleName }) else {
                    continue
                }
                modules.append(file)
                modulesByWindowsDirectory[mapping.windowsDirectory] = modules
            }
        }
    }

    private static func wineDLLSearchDirectories(for wineDLLRoot: URL, fileManager: FileManager) -> [String] {
        let architectureDirectories = [
            wineDLLRoot.appending(path: "x86_64-unix", directoryHint: .isDirectory),
            wineDLLRoot.appending(path: "x86_64-windows", directoryHint: .isDirectory),
            wineDLLRoot.appending(path: "i386-windows", directoryHint: .isDirectory)
        ].filter {
            FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
        }
        return ([wineDLLRoot] + architectureDirectories).map(\.path)
    }

    private static func rendererWineDLLSearchDirectories(
        for wineDLLRoot: URL,
        rendererName: String,
        compositionHasD3DMetal: Bool,
        fileManager: FileManager
    ) -> [String] {
        let relativeDirectories: [String]
        switch rendererName {
        case "d3dmetal":
            relativeDirectories = ["x86_64-unix", "x86_64-windows"]
        case "dxmt" where compositionHasD3DMetal:
            // D3DMetal owns 64-bit D3D11/DXGI/D3D12. Keep only DXMT's
            // WoW64 Windows modules and Unix Metal bridge in the mixed stack.
            relativeDirectories = ["x86_64-unix", "i386-windows"]
        case "d9vk", "dxvk":
            relativeDirectories = ["x86_64-windows", "i386-windows"]
        default:
            relativeDirectories = ["x86_64-unix", "x86_64-windows", "i386-windows"]
        }
        let directories = relativeDirectories
            .map { wineDLLRoot.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager) }
        return ([wineDLLRoot] + directories).map(\.path)
    }

    private static func shouldUseRendererComponent(
        _ rendererName: String,
        forWindowsDirectory windowsDirectory: String,
        compositionHasD3DMetal: Bool
    ) -> Bool {
        switch rendererName {
        case "d3dmetal":
            return windowsDirectory == "system32"
        case "dxmt" where compositionHasD3DMetal:
            return windowsDirectory == "syswow64"
        default:
            return true
        }
    }

    private static func appendD3DMetalExternalPathsIfComplete(
        in externalDirectory: URL,
        fileManager: FileManager,
        dynamicLibraryPaths: inout [String],
        frameworkPaths: inout [String],
        d3dMetalFrameworkExecutables: inout [String]
    ) {
        let sharedLibrary = externalDirectory.appending(path: "libd3dshared.dylib")
        let frameworkExecutable = externalDirectory
            .appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
            .appending(path: "D3DMetal")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(sharedLibrary, fileManager: fileManager),
              FileSystemItemPolicy.isRegularNonSymlinkFile(frameworkExecutable, fileManager: fileManager) else {
            return
        }
        dynamicLibraryPaths.append(externalDirectory.path)
        frameworkPaths.append(externalDirectory.path)
        d3dMetalFrameworkExecutables.append(frameworkExecutable.path)
    }

    private static func d3dMetalSharedLibraryPath(
        forFrameworkExecutablePath frameworkExecutablePath: String,
        fileManager: FileManager = .default
    ) -> String? {
        let executable = URL(fileURLWithPath: frameworkExecutablePath)
        let framework = executable.deletingLastPathComponent()
        let external = framework.deletingLastPathComponent()
        guard executable.lastPathComponent == "D3DMetal",
              framework.lastPathComponent == "D3DMetal.framework",
              external.lastPathComponent == "external" else {
            return nil
        }
        let sharedLibrary = external.appending(path: "libd3dshared.dylib")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(
            sharedLibrary,
            fileManager: fileManager
        ) else {
            return nil
        }
        return sharedLibrary.path
    }

    private static func vulkanICDFiles(in root: URL, fileManager: FileManager) -> [String] {
        let candidateDirectories = [
            root.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory),
            root.appending(path: "share/vulkan/icd.d", directoryHint: .isDirectory),
            root.appending(path: "lib/vulkan/icd.d", directoryHint: .isDirectory),
            root.appending(path: "vulkan/icd.d", directoryHint: .isDirectory)
        ]
        var paths: [String] = []
        for directory in candidateDirectories where FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) {
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }
            for file in files where file.pathExtension.lowercased() == "json" {
                guard FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager) else {
                    continue
                }
                paths.append(file.path)
            }
        }
        return deduplicated(paths)
    }

    private static func selectedRendererDirectories(
        from rendererContents: [URL],
        graphicsBackend: SteamRendererPolicyPreference?,
        fileManager: FileManager
    ) -> [URL] {
        let directoriesByName = Dictionary(
            uniqueKeysWithValues: rendererContents
                .filter { FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager) }
                .map { ($0.lastPathComponent.lowercased(), $0) }
        )
        let usableDirectoriesByName = directoriesByName.filter {
            rendererComponentIsUsable(
                named: $0.key,
                at: $0.value,
                fileManager: fileManager
            )
        }
        let preferredNames = rendererPreferenceOrder(
            graphicsBackend: graphicsBackend,
            availableRendererNames: Set(usableDirectoriesByName.keys)
        )
        return deduplicated(preferredNames.compactMap { usableDirectoriesByName[$0] })
    }

    private static func rendererPreferenceOrder(
        graphicsBackend: SteamRendererPolicyPreference?,
        availableRendererNames: Set<String>
    ) -> [String] {
        switch graphicsBackend {
        case .d3dMetal:
            return ["d3dmetal"]
        case .dxmt:
            return ["dxmt"]
        case .d9vk:
            return ["d9vk"]
        case .vulkan:
            return ["dxvk"]
        case nil:
            return []
        }
    }

    private static func rendererComponentIsUsable(
        named name: String,
        at rendererDirectory: URL,
        fileManager: FileManager,
        d3dMetalScope: D3DMetalRendererPayloadContract.LaunchScope? = nil
    ) -> Bool {
        if name == "d3dmetal" {
            if let d3dMetalScope {
                return D3DMetalRendererPayloadContract.isUsable(
                    for: d3dMetalScope,
                    at: rendererDirectory,
                    fileManager: fileManager
                )
            }
            return D3DMetalRendererPayloadContract.isUsable(
                for: .direct3D11Family,
                at: rendererDirectory,
                fileManager: fileManager
            ) || D3DMetalRendererPayloadContract.isUsable(
                for: .direct3D12,
                at: rendererDirectory,
                fileManager: fileManager
            )
        }

        let requiredRelativePaths: [String]
        switch name {
        case "d9vk":
            requiredRelativePaths = [
                "wine/i386-windows/d3d9.dll",
                "wine/x86_64-windows/d3d9.dll"
            ]
        case "dxmt":
            requiredRelativePaths = [
                "wine/i386-windows/d3d10core.dll",
                "wine/i386-windows/d3d11.dll",
                "wine/i386-windows/dxgi.dll",
                "wine/i386-windows/winemetal.dll",
                "wine/x86_64-unix/winemetal.so",
                "wine/x86_64-windows/d3d11.dll",
                "wine/x86_64-windows/dxgi.dll",
                "wine/x86_64-windows/winemetal.dll"
            ]
        case "dxvk":
            requiredRelativePaths = [
                "wine/i386-windows/d3d8.dll",
                "wine/i386-windows/d3d9.dll",
                "wine/i386-windows/d3d10core.dll",
                "wine/i386-windows/d3d11.dll",
                "wine/i386-windows/dxgi.dll",
                "wine/x86_64-windows/d3d8.dll",
                "wine/x86_64-windows/d3d9.dll",
                "wine/x86_64-windows/d3d10core.dll",
                "wine/x86_64-windows/d3d11.dll",
                "wine/x86_64-windows/dxgi.dll"
            ]
        default:
            return false
        }

        return requiredRelativePaths.allSatisfy {
            FileSystemItemPolicy.isRegularNonSymlinkFile(
                rendererDirectory.appending(path: $0),
                fileManager: fileManager
            )
        }
    }

    private static func rendererCompositionRequiresVulkan(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?
    ) throws -> Bool {
        guard let graphicsBackend else { return false }
        if graphicsBackend == .vulkan { return true }

        let fileManager = FileManager.default
        for contentsDirectory in rendererSupportContentsDirectories(for: executable) {
            let rendererRoot = contentsDirectory.appending(
                path: "Frameworks/renderer",
                directoryHint: .isDirectory
            )
            guard FileSystemItemPolicy.isNonSymlinkDirectory(rendererRoot, fileManager: fileManager) else {
                continue
            }
            let rendererContents: [URL]
            do {
                rendererContents = try fileManager.contentsOfDirectory(
                    at: rendererRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SafeProcessRunnerError.runnerLibrarySearchFailed(rendererRoot, error)
            }
            let selected = selectedRendererDirectories(
                from: rendererContents,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager
            )
            if selected.contains(where: { ["d9vk", "dxvk"].contains($0.lastPathComponent.lowercased()) }) {
                return true
            }
        }
        return false
    }

    private static func rendererSupportContentsDirectories(for executable: URL) -> [URL] {
        var directories: [URL] = []
        if let wineRoot = wineRootDirectory(for: executable) {
            directories.append(wineRoot.deletingLastPathComponent())
        }
        if let contents = bundleContentsDirectory(for: executable) {
            directories.append(contents)
        }
        return deduplicated(directories)
    }

    private static func shouldExposeVulkanRendererPaths(for graphicsBackend: SteamRendererPolicyPreference?) -> Bool {
        switch graphicsBackend {
        case .d3dMetal, .dxmt:
            false
        case nil:
            false
        case .d9vk, .vulkan:
            true
        }
    }

    private static func shouldExposeVulkanICD(
        for graphicsBackend: SteamRendererPolicyPreference?,
        explicitSteamClientExposure: Bool
    ) -> Bool {
        explicitSteamClientExposure || Self.shouldExposeVulkanRendererPaths(for: graphicsBackend)
    }

    private static func shouldSuppressVulkanICD(
        for graphicsBackend: SteamRendererPolicyPreference?,
        explicitSteamClientExposure: Bool
    ) -> Bool {
        !Self.shouldExposeVulkanICD(
            for: graphicsBackend,
            explicitSteamClientExposure: explicitSteamClientExposure
        )
    }

    private static func shouldExposeSteamClientVulkanICD(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?
    ) throws -> Bool {
        switch graphicsBackend {
        case .d9vk, .vulkan:
            return true
        case .d3dMetal, .dxmt:
            return false
        case nil:
            return true
        }
    }

    private static func wineBinDirectory(for executable: URL) -> URL? {
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        return binDirectory
    }

    private static func wineRootDirectory(for executable: URL) -> URL? {
        guard let binDirectory = wineBinDirectory(for: executable) else { return nil }
        return binDirectory.deletingLastPathComponent()
    }

    nonisolated static func runtimeLayoutSearchRoots(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates = [executable.deletingLastPathComponent()]
        if let wineRoot = wineRootDirectory(for: executable) {
            candidates.append(wineRoot)
            candidates.append(wineRoot.deletingLastPathComponent())
        }
        if let contents = bundleContentsDirectory(for: executable) {
            candidates.append(contents)
            candidates.append(contents.deletingLastPathComponent())
        }
        return deduplicated(candidates).filter {
            FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
        }
    }

    nonisolated static func wineSynchronizationRuntimeCapabilities(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> WineSynchronizationRuntimeCapabilities {
        guard let wineserver = wineserverExecutable(for: executable),
              FileSystemItemPolicy.isRegularNonSymlinkFile(
                wineserver,
                fileManager: fileManager
              ),
              fileManager.isExecutableFile(atPath: wineserver.path) else {
            return WineSynchronizationRuntimeCapabilities(
                supportedBackends: []
            )
        }
        return WineSynchronizationRuntimeCapabilities(
            supportedBackends: [.server]
        )
    }

    private struct PrefixSynchronizationDocument: Decodable {
        var synchronizationSelection: String?
        var synchronizationBackend: String?
    }

    private struct PrefixSynchronizationProfile {
        var selection: WineSynchronizationSelection
        var backend: WineSynchronizationBackend
    }

    private nonisolated static func boundedStablePrefixMetadataData(
        at url: URL
    ) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(url)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 1_048_576 else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(url)
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remainingByteCount = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    remainingByteCount,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(url)
            }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(url)
        }
        return Data(bytes)
    }

    private static func appliedSynchronizationProfile(
        in prefix: URL,
        fileManager: FileManager = .default
    ) throws -> PrefixSynchronizationProfile {
        let metadataURL = prefix.appending(path: "prefix.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return PrefixSynchronizationProfile(selection: .automatic, backend: .server)
        }
        guard let data = try? boundedStablePrefixMetadataData(at: metadataURL),
              let document = try? JSONDecoder().decode(PrefixSynchronizationDocument.self, from: data) else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(metadataURL)
        }
        guard let selectionValue = document.synchronizationSelection,
              let backendValue = document.synchronizationBackend,
              selectionValue == WineSynchronizationSelection.automatic.rawValue,
              backendValue == WineSynchronizationBackend.server.rawValue else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(metadataURL)
        }
        return PrefixSynchronizationProfile(
            selection: .automatic,
            backend: .server
        )
    }

    private static func applySynchronizationProfile(
        _ profile: PrefixSynchronizationProfile,
        to environment: inout [String: String]
    ) {
        environment["FORGEPLAY_SYNCHRONIZATION_SELECTION"] =
            profile.selection.rawValue
        environment["FORGEPLAY_SYNCHRONIZATION_BACKEND"] =
            profile.backend.rawValue
    }

    private static func forgePlaySteamLauncherExecutable(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(executable),
              let wineRoot = wineRootDirectory(for: executable) else {
            return nil
        }
        let candidate = wineRoot.appending(
            path: "lib/wine/x86_64-windows/forgeplay-steam-launcher.exe"
        )
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager) else {
            return nil
        }
        return candidate
    }

    private static func wineserverExecutable(for executable: URL) -> URL? {
        if ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(executable) {
            return nil
        }
        let candidates: [URL]
        if let binDirectory = wineBinDirectory(for: executable) {
            candidates = [binDirectory.appending(path: "wineserver")]
        } else if let contents = bundleContentsDirectory(for: executable) {
            candidates = [
                contents.appending(path: "SharedSupport/wine/bin/wineserver"),
                contents.appending(path: "Resources/wine/bin/wineserver")
            ]
        } else {
            candidates = []
        }
        return candidates.first {
            FileSystemItemPolicy.isRegularNonSymlinkFile($0) &&
                FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func bundleContentsDirectory(for executable: URL) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let contentsIndex = components.lastIndex(of: "Contents") else { return nil }
        let contents = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...contentsIndex])))
        return FileSystemItemPolicy.isNonSymlinkDirectory(contents) ? contents : nil
    }

    private static func mergedPathList(_ paths: [String], existing: String?) -> String {
        var merged = deduplicated(paths)
        if let existing, !existing.isEmpty {
            merged.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        return deduplicated(merged).joined(separator: ":")
    }

    private nonisolated static let direct3DDLLOverrideGroup = [
        "d3d8",
        "d3d9",
        "d3d10",
        "d3d10_1",
        "d3d10core",
        "d3d11",
        "dxgi",
        "d3d12",
        "d3d12core"
    ].joined(separator: ",")

    nonisolated static let rendererBridgeDLLNames: Set<String> = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
        "d3d12.dll",
        "d3d12core.dll",
        "nvapi.dll",
        "nvapi64.dll",
        "nvngx.dll",
        "nvngx-on-metalfx.dll",
        "winemetal.dll"
    ]

    private nonisolated static let rendererWindowsModuleDirectoryMappings: [(windowsDirectory: String, rendererDirectory: String)] = [
        ("system32", "x86_64-windows"),
        ("syswow64", "i386-windows")
    ]

    private static func mergedWineDLLOverrides(_ override: String, existing: String?) -> String {
        var values = [override]
        if let existing, !existing.isEmpty {
            values.append(contentsOf: existing.split(separator: ";").map(String.init))
        }
        return deduplicated(values).joined(separator: ";")
    }

    private nonisolated static let defaultExecutableSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private nonisolated static let gameRendererUnsetValue = "__FORGEPLAY_UNSET__"

    private nonisolated static let gameRendererUnixEnvironmentKeys = [
        "WINEDLLOVERRIDES",
        "WINEDLLPATH",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "D3DMETAL_FRAMEWORK_PATH",
        "D3DMETAL_SHARED_LIBRARY",
        "D3DM_WINE_UNIX_CALL",
        "D3DM_ENABLE_METALFX",
        "D3DM_NVNGX_PATH",
        "D3DM_VENDOR_ID",
        "FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP",
        "FORGEPLAY_NETWORK_PROFILE",
        "VK_ICD_FILENAMES",
        "VK_DRIVER_FILES",
        "DXVK_LOG_PATH",
        "DXVK_LOG_LEVEL",
        "DXVK_CONFIG"
    ]

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where !value.isEmpty && seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }

    private static func deduplicated(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for value in values {
            let path = value.standardizedFileURL.path
            if seen.insert(path).inserted {
                output.append(value)
            }
        }
        return output
    }

    private static func logPair(in directory: URL, name: String) -> (stdout: URL, stderr: URL) {
        let stamp = logTimestampFormatter.string(from: Date())
        let safeName = PathManager.sanitizedFileName(name)
        let uniqueID = UUID().uuidString
        return (
            directory.appending(path: "\(stamp)_\(safeName)_\(uniqueID)_stdout.log"),
            directory.appending(path: "\(stamp)_\(safeName)_\(uniqueID)_stderr.log")
        )
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

extension ProcessRunResult {
    /// A process exit status exists only when the operating system actually
    /// started the command and reported one. Preflight/spawn failures keep a
    /// raw compatibility slot but must never present or persist it as real.
    var processExitCode: Int32? {
        hasProcessExitCode ? exitCode : nil
    }

    var diagnosticExitCodeDescription: String {
        processExitCode.map(String.init) ??
            "unavailable (the process did not produce an exit status)"
    }

    var diagnosticForgePlayStatusDescription: String {
        forgePlayStatusCode.map(String.init) ?? "none"
    }

    var diagnosticTerminationSignalDescription: String {
        guard let terminationSignal else { return "none" }
        let name: String
        switch terminationSignal {
        case SIGABRT: name = "SIGABRT"
        case SIGBUS: name = "SIGBUS"
        case SIGFPE: name = "SIGFPE"
        case SIGILL: name = "SIGILL"
        case SIGINT: name = "SIGINT"
        case SIGKILL: name = "SIGKILL"
        case SIGSEGV: name = "SIGSEGV"
        case SIGTERM: name = "SIGTERM"
        default: name = "signal"
        }
        return "\(name) (\(terminationSignal))"
    }

    var succeeded: Bool {
        if let postconditionSatisfied {
            return postconditionSatisfied
        }
        guard !didTimeOut else { return false }
        if let forgePlayStatusCode {
            return forgePlayStatusCode == 0
        }
        if outcome == .runningDetached {
            return true
        }
        return processExitCode == 0
    }

    var preferredDiagnosticLog: URL {
        let candidates = [diagnosticLog, Optional(stderrLog), Optional(stdoutLog), runEvidenceLog]
            .compactMap { $0 }
        return candidates.first(where: forgePlayDiagnosticLogIsNonEmptyRegularFile) ??
            runEvidenceLog ?? diagnosticLog ?? stderrLog
    }

    var diagnosticSourceLogs: [URL] {
        var logs: [URL]
        if let diagnosticLog {
            logs = [diagnosticLog, stderrLog, stdoutLog]
        } else {
            logs = [stdoutLog, stderrLog]
        }
        if let runEvidenceLog {
            logs.append(runEvidenceLog)
        }
        return logs
    }
}

private func forgePlayDiagnosticLogIsNonEmptyRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    ),
    values.isRegularFile == true,
    values.isSymbolicLink != true,
    let fileSize = values.fileSize else {
        return false
    }
    return fileSize > 0
}
