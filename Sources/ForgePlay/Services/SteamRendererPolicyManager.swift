import Darwin
import CryptoKit
import Foundation

private struct NVIDIAMetalFXRegistryProjection: Codable, Equatable, Hashable {
    let registryPath: String
    let valueName: String
    let stagedValue: String
}

private struct NVIDIAMetalFXRegistrySessionMarker: Codable, Equatable {
    let schemaVersion: Int
    let projections: [NVIDIAMetalFXRegistryProjection]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projections
        case registryPath
        case valueName
        case stagedValue
    }

    init(
        schemaVersion: Int,
        projections: [NVIDIAMetalFXRegistryProjection]
    ) {
        self.schemaVersion = schemaVersion
        self.projections = projections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        if let projections = try container.decodeIfPresent(
            [NVIDIAMetalFXRegistryProjection].self,
            forKey: .projections
        ) {
            self.projections = projections
            return
        }
        self.projections = [
            NVIDIAMetalFXRegistryProjection(
                registryPath: try container.decode(
                    String.self,
                    forKey: .registryPath
                ),
                valueName: try container.decode(
                    String.self,
                    forKey: .valueName
                ),
                stagedValue: try container.decode(
                    String.self,
                    forKey: .stagedValue
                )
            )
        ]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projections, forKey: .projections)
    }
}

private struct NVIDIAMetalFXModuleFileIdentity: Codable, Equatable {
    let byteCount: Int
    let sha256: String
}

private struct NVIDIAMetalFXModuleSessionEntry: Codable, Equatable {
    let moduleName: String
    let stagedIdentity: NVIDIAMetalFXModuleFileIdentity
    let stagedSnapshotName: String?
    let destinationWasPresent: Bool
    let destinationIdentity: NVIDIAMetalFXModuleFileIdentity?
    let backupWasPresent: Bool
    let backupIdentity: NVIDIAMetalFXModuleFileIdentity?
    let destinationSnapshotName: String?

    private enum CodingKeys: String, CodingKey {
        case moduleName
        case stagedIdentity
        case stagedSnapshotName
        case destinationWasPresent
        case destinationIdentity
        case backupWasPresent
        case backupIdentity
        case destinationSnapshotName
    }

    init(
        moduleName: String,
        stagedIdentity: NVIDIAMetalFXModuleFileIdentity,
        stagedSnapshotName: String?,
        destinationWasPresent: Bool,
        destinationIdentity: NVIDIAMetalFXModuleFileIdentity?,
        backupWasPresent: Bool,
        backupIdentity: NVIDIAMetalFXModuleFileIdentity?,
        destinationSnapshotName: String?
    ) {
        self.moduleName = moduleName
        self.stagedIdentity = stagedIdentity
        self.stagedSnapshotName = stagedSnapshotName
        self.destinationWasPresent = destinationWasPresent
        self.destinationIdentity = destinationIdentity
        self.backupWasPresent = backupWasPresent
        self.backupIdentity = backupIdentity
        self.destinationSnapshotName = destinationSnapshotName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moduleName = try container.decode(String.self, forKey: .moduleName)
        stagedIdentity = try container.decode(
            NVIDIAMetalFXModuleFileIdentity.self,
            forKey: .stagedIdentity
        )
        stagedSnapshotName = try container.decodeIfPresent(
            String.self,
            forKey: .stagedSnapshotName
        )
        destinationWasPresent = try container.decode(
            Bool.self,
            forKey: .destinationWasPresent
        )
        destinationIdentity = try container.decodeIfPresent(
            NVIDIAMetalFXModuleFileIdentity.self,
            forKey: .destinationIdentity
        )
        backupWasPresent = try container.decode(
            Bool.self,
            forKey: .backupWasPresent
        )
        backupIdentity = try container.decodeIfPresent(
            NVIDIAMetalFXModuleFileIdentity.self,
            forKey: .backupIdentity
        )
        destinationSnapshotName = try container.decodeIfPresent(
            String.self,
            forKey: .destinationSnapshotName
        )
    }
}

private struct NVIDIAMetalFXModuleSessionMarker: Codable, Equatable {
    let schemaVersion: Int
    let entries: [NVIDIAMetalFXModuleSessionEntry]
}

struct SteamRendererRouteApplicationReceipt: Hashable, Sendable {
    enum ReportedScope: String, Hashable, Sendable {
        case staticRouteEligibility
        case providerConfigurationReadback
    }

    let selection: SteamRendererPolicySelection
    let resolvedPolicy: SteamRendererPolicyPreference
    let staticRouteEligibilityVerified: Bool
    let providerRegistryReadBack: Bool
    let providerModulesReadBack: Bool
    let reportedScope: ReportedScope

    var isPreparationVerified: Bool {
        staticRouteEligibilityVerified &&
            (!selection.usesD3DMetalNVIDIACompatibility ||
                (reportedScope == .providerConfigurationReadback &&
                    providerRegistryReadBack && providerModulesReadBack))
    }
}

final class SteamRendererPolicyManager {
    private enum ModuleRestorationAdmission {
        case completedRegistryBarrier
        case stagingRollback
    }

    private enum NVIDIAMetalFXDestinationRestorationState {
        case staged
        case alreadyRestored
        case alreadyRemoved
    }

    private struct NVIDIAMetalFXValidatedModuleRestoration {
        let destinationState: NVIDIAMetalFXDestinationRestorationState
        let destinationSnapshot: URL?
    }

    typealias RegistryActionExecutor = @MainActor (
        _ action: RunnerAction,
        _ runner: SafeProcessRunner
    ) async throws -> ProcessRunResult

    private let fileManager: FileManager
    private let registryActionExecutor: RegistryActionExecutor?

    init(
        fileManager: FileManager = .default,
        registryActionExecutor: RegistryActionExecutor? = nil
    ) {
        self.fileManager = fileManager
        self.registryActionExecutor = registryActionExecutor
    }

    /// Returns true only for a safely readable ownership marker that the
    /// renderer-policy owner can restore. A malformed or unrelated file must
    /// not attach NVIDIA cleanup ownership to a DXMT or D9VK launch.
    func hasRecoverableNVIDIAMetalFXRegistrySession(in prefix: URL) -> Bool {
        let marker = nvidiaMetalFXRegistrySessionMarker(in: prefix)
        guard fileManager.fileExists(atPath: marker.path) else { return false }
        return (try? loadNVIDIAMetalFXRegistrySessionMarker(marker)) != nil
    }

    func resolvedPolicy(
        _ requestedRendererPolicy: SteamRendererPolicyPreference?,
        capability: WindowsRuntimeCapability
    ) throws -> SteamRendererPolicyPreference {
        if let requestedRendererPolicy {
            guard requestedRendererPolicy.isSatisfied(by: capability) else {
                throw SteamLaunchError.rendererPolicyUnavailable(
                    "선택한 게임 렌더러 payload(\(requestedRendererPolicy.labelKey))는 현재 실행 엔진에서 사용할 수 없습니다."
                )
            }
            return requestedRendererPolicy
        }
        throw SteamLaunchError.rendererPolicyUnavailable(
            "Steam을 실행하기 전에 D3DMetal - NVIDIA, DXMT 또는 D9VK 중 하나를 직접 선택해야 합니다."
        )
    }

    nonisolated static func selection(
        for policy: SteamRendererPolicyPreference
    ) -> SteamRendererPolicySelection {
        switch policy {
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

    func inspect(
        prefix: URL,
        runtimeExecutable: URL,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int? = nil
    ) -> SteamRendererPolicyInspection {
        let capability = runtimeCapability ??
            WindowsRuntimeService.inspectRuntimeCapability(
                for: runtimeExecutable,
                supplementalRendererRoot: ForgePlaySupplementalRendererPolicy
                    .rendererRoot(containingPrefix: prefix),
                fileManager: fileManager
            )
        let steamClientVerification = SteamClientCompatibilityVerifier.verify(capability: capability)
        guard steamClientVerification.canLaunchWindowsSteam else {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: selection.resolvedLaunchPreference(capability: capability),
                status: .error,
                userMessage: steamClientVerification.userMessage,
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                recoveryKind: .runtimeUnavailable
            )
        }
        guard let resolvedPolicy = selection.resolvedLaunchPreference(capability: capability) else {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: nil,
                status: .error,
                userMessage: capability.userMessage,
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                recoveryKind: .runtimeUnavailable
            )
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(prefix, fileManager: fileManager) else {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: resolvedPolicy,
                status: .warning,
                userMessage: "Steam 프리픽스를 먼저 만들어야 Steam 실행 경로를 정비할 수 있습니다.",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            )
        }

        do {
            let selectedModules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
                for: runtimeExecutable,
                graphicsBackend: resolvedPolicy,
                prefix: prefix
            )
            let allKnownModules = try knownRendererBridgeModulesByWindowsDirectory(
                for: runtimeExecutable,
                prefix: prefix
            )
            guard selectedModules.values.contains(where: { !$0.isEmpty }) else {
                return SteamRendererPolicyInspection(
                    selection: selection,
                    resolvedPolicy: resolvedPolicy,
                    status: .error,
                    userMessage: "선택한 게임 렌더러 payload에 필요한 renderer DLL을 실행 엔진에서 찾지 못했습니다.",
                    appliedModules: [],
                    missingModules: [],
                    mixedModules: []
                )
            }
            if selection.usesD3DMetalNVIDIACompatibility {
                try SafeProcessRunner
                    .validateD3DMetalNVIDIACompatibilityPayload(
                        for: runtimeExecutable,
                        prefix: prefix
                    )
            }
            // This validates the selected core renderer without performing the
            // NVIDIA route's derived-file materialization during inspection.
            _ = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: runtimeExecutable,
                prefix: prefix,
                graphicsBackend: resolvedPolicy,
                logDirectory: prefix
            )

            // A prior NVIDIA session is owned by its session marker, not by
            // whichever renderer bytes happen to ship in the current app.
            // Surface that transaction before comparing against the current
            // payload catalog so an app update cannot make the old staged
            // System32 files invisible to the restoration path.
            var contaminatingModules = Set(
                nvidiaMetalFXSessionInspectionPaths(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable
                )
            )
            let existingWindowsDirectoryNames = Self.rendererPolicyWindowsDirectoryNames.filter { directoryName in
                fileManager.fileExists(
                    atPath: prefix.appending(path: "drive_c/windows/\(directoryName)", directoryHint: .isDirectory).path
                )
            }
            let directoryNamesToInspect = Set(selectedModules.keys)
                .union(allKnownModules.keys)
                .union(existingWindowsDirectoryNames)
            for windowsDirectoryName in directoryNamesToInspect.sorted() {
                let windowsDirectory = prefix.appending(path: "drive_c/windows/\(windowsDirectoryName)", directoryHint: .isDirectory)
                if !fileManager.fileExists(atPath: windowsDirectory.path) {
                    continue
                }
                guard FileSystemItemPolicy.isNonSymlinkDirectory(windowsDirectory, fileManager: fileManager) else {
                    contaminatingModules.insert(
                        "\(windowsDirectoryName): directory unavailable"
                    )
                    continue
                }

                for moduleName in Self.rendererPolicyDLLNames {
                    let destination = windowsDirectory.appending(path: moduleName)
                    guard FileSystemItemPolicy.isRegularNonSymlinkFile(destination, fileManager: fileManager) else {
                        continue
                    }
                    if isKnownRendererModule(
                        destination,
                        knownRendererModules: allKnownModules[windowsDirectoryName, default: []]
                    ) || Self.hasRendererBridgeMarker(destination, fileManager: fileManager) {
                        contaminatingModules.insert(
                            "\(windowsDirectoryName)/\(moduleName)"
                        )
                    }
                }
            }

            if !contaminatingModules.isEmpty {
                let profileInspection = SteamClientCompatibilityProfileContract.inspect(
                    prefix: prefix,
                    fileManager: fileManager,
                    videoMemorySizeMB: videoMemorySizeMB
                )
                return SteamRendererPolicyInspection(
                    selection: selection,
                    resolvedPolicy: resolvedPolicy,
                    status: .error,
                    userMessage: "Steam 프리픽스에 Windows용 Steam 클라이언트가 직접 로드할 수 있는 renderer DLL overlay가 남아 있습니다. Steam UI는 기본 Wine 경로로 실행해야 하므로 Steam 실행 전에 실행 경로 정비/검증으로 overlay를 복구해야 합니다.",
                    appliedModules: [],
                    missingModules: [],
                    mixedModules: contaminatingModules.sorted(),
                    appliedProfileOverrides: profileInspection.appliedOverrides,
                    missingProfileOverrides: profileInspection.missingOverrides,
                    staleProfileOverrides: profileInspection.staleOverrides,
                    appliedSteamClientFiles: profileInspection.appliedFiles,
                    missingSteamClientFiles: profileInspection.missingFiles,
                    staleSteamClientFiles: profileInspection.staleFiles
                )
            }
            let profileInspection = SteamClientCompatibilityProfileContract.inspect(
                prefix: prefix,
                fileManager: fileManager,
                videoMemorySizeMB: videoMemorySizeMB
            )
            if !profileInspection.isSatisfied {
                let requiresExplicitFileRepair = !profileInspection.staleFiles.isEmpty
                let message: String
                if !profileInspection.staleOverrides.isEmpty {
                    message = "Steam 클라이언트에 오래된 renderer 강제 override가 남아 있습니다. Steam 실행 전에 ForgePlay가 프로필을 정비해야 합니다."
                } else if !profileInspection.staleFiles.isEmpty {
                    message = "Steam 클라이언트 보조 구성요소가 현재 앱 버전과 맞지 않습니다. Steam 실행 전에 ForgePlay가 실행 경로를 복구해야 합니다."
                } else if !profileInspection.missingFiles.isEmpty {
                    message = "Steam 클라이언트 보조 구성요소가 아직 준비되지 않았습니다. Steam 실행 전에 ForgePlay가 실행 경로를 준비해야 합니다."
                } else {
                    message = "Steam 클라이언트 호환성 프로필이 Steam 프리픽스에 아직 적용되지 않았습니다. Steam 실행 전에 ForgePlay가 프로필을 적용해야 합니다."
                }
                return SteamRendererPolicyInspection(
                    selection: selection,
                    resolvedPolicy: resolvedPolicy,
                    status: requiresExplicitFileRepair ? .error : .warning,
                    userMessage: message,
                    appliedModules: [],
                    missingModules: [],
                    mixedModules: [],
                    appliedProfileOverrides: profileInspection.appliedOverrides,
                    missingProfileOverrides: profileInspection.missingOverrides,
                    staleProfileOverrides: profileInspection.staleOverrides,
                    appliedSteamClientFiles: profileInspection.appliedFiles,
                    missingSteamClientFiles: profileInspection.missingFiles,
                    staleSteamClientFiles: profileInspection.staleFiles,
                    recoveryKind: requiresExplicitFileRepair ? .repairPolicy : .applyPolicy
                )
            }
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: resolvedPolicy,
                status: .ok,
                userMessage: "Steam UI는 기본 Wine 경로로 유지되고, 선택한 단일 백엔드를 Steam 게임 실행 계보에 적용할 준비가 되어 있습니다.",
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                appliedProfileOverrides: profileInspection.appliedOverrides,
                missingProfileOverrides: [],
                staleProfileOverrides: [],
                appliedSteamClientFiles: profileInspection.appliedFiles,
                missingSteamClientFiles: [],
                staleSteamClientFiles: []
            )
        } catch {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: resolvedPolicy,
                status: .error,
                userMessage: "Steam 실행 경로와 게임 렌더러 payload 상태를 확인하지 못했습니다: \(forgePlayTechnicalErrorSummary(error))",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            )
        }
    }

    func applicationReceipt(
        prefix: URL,
        runtimeExecutable: URL,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int
    ) throws -> SteamRendererRouteApplicationReceipt {
        let inspection = inspect(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: runtimeCapability,
            selection: selection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        let exactOwnedNVIDIAStage =
            selection.usesD3DMetalNVIDIACompatibility &&
            isRecoverableNVIDIAMetalFXSessionResidue(
                inspection,
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )
        guard (inspection.status == .ok || exactOwnedNVIDIAStage),
              inspection.requiresApply == false,
              let resolvedPolicy = inspection.resolvedPolicy else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(
                inspection.userMessage
            )
        }

        let registryReadback: Bool
        let moduleReadback: Bool
        if selection.usesD3DMetalNVIDIACompatibility {
            registryReadback = try nvidiaMetalFXNGXCoreRegistryViewsArePrepared(
                in: prefix
            )
            let sourcesByName = try nvidiaMetalFXSourcesByName(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )
            let system32 = prefix.appending(
                path: "drive_c/windows/system32",
                directoryHint: .isDirectory
            )
            moduleReadback = Set(sourcesByName.keys) ==
                Set(Self.nvidiaMetalFXSystem32ModuleNames) &&
                sourcesByName.allSatisfy { moduleName, source in
                    let destination = system32.appending(path: moduleName)
                    return (try? stableRendererFileIdentity(destination)) ==
                        (try? stableRendererFileIdentity(source))
                }
        } else {
            registryReadback = false
            moduleReadback = false
        }

        let receipt = SteamRendererRouteApplicationReceipt(
            selection: selection,
            resolvedPolicy: resolvedPolicy,
            staticRouteEligibilityVerified: true,
            providerRegistryReadBack: registryReadback,
            providerModulesReadBack: moduleReadback,
            reportedScope: selection.usesD3DMetalNVIDIACompatibility
                ? .providerConfigurationReadback
                : .staticRouteEligibility
        )
        guard receipt.isPreparationVerified else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(
                "선택한 D3DMetal 공급자 경로에 실제로 적용된 레지스트리 또는 모듈 상태가 요청과 일치하지 않습니다."
            )
        }
        return receipt
    }

    func restoreBridgeModules(
        prefix: URL,
        runtimeExecutable: URL
    ) throws {
        try requireContainedNonSymlinkDirectory(prefix, within: prefix)
        let allKnownModulesByWindowsDirectory = try knownRendererBridgeModulesByWindowsDirectory(
            for: runtimeExecutable,
            prefix: prefix
        )
        for directoryName in Self.rendererPolicyWindowsDirectoryNames {
            let windowsDirectory = prefix.appending(path: "drive_c/windows/\(directoryName)", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: windowsDirectory.path) else {
                continue
            }
            do {
                try requireContainedNonSymlinkDirectory(windowsDirectory, within: prefix)
            } catch {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    windowsDirectory,
                    "\(directoryName) folder is outside the safe prefix directory boundary: \(forgePlayTechnicalErrorSummary(error))"
                )
            }
            let backupDirectory = prefix.appending(
                path: "drive_c/ForgePlay/RendererBackups/\(directoryName)",
                directoryHint: .isDirectory
            )
            do {
                try createContainedNonSymlinkDirectoryIfNeeded(backupDirectory, within: prefix)
                try restoreUnselectedBridgeModules(
                    in: windowsDirectory,
                    backupDirectory: backupDirectory,
                    selectedModuleNames: []
                )
                try removeUnbackedBridgeModules(
                    in: windowsDirectory,
                    backupDirectory: backupDirectory,
                    knownRendererModules: allKnownModulesByWindowsDirectory[directoryName, default: []]
                )
            } catch {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    backupDirectory,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
    }

    /// Returns true only for the exact transient System32 pair staged by a
    /// prior NVIDIA MetalFX session. Other renderer overlays remain a hard
    /// launch failure and must go through the explicit repair workflow.
    func isRecoverableNVIDIAMetalFXSessionResidue(
        _ inspection: SteamRendererPolicyInspection,
        prefix: URL,
        runtimeExecutable: URL
    ) -> Bool {
        guard inspection.status == .error,
              !inspection.mixedModules.isEmpty,
              inspection.staleProfileOverrides.isEmpty,
              inspection.staleSteamClientFiles.isEmpty else {
            return false
        }

        let backupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32",
            directoryHint: .isDirectory
        )
        let sessionDirectory = nvidiaMetalFXModuleSessionDirectory(
            backupDirectory: backupDirectory
        )
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            return false
        }
        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: prefix,
                to: sessionDirectory,
                fileManager: fileManager
              ),
              FileSystemItemPolicy.isNonSymlinkDirectory(
                sessionDirectory,
                fileManager: fileManager
              ) else {
            return false
        }
        let markerURL = sessionDirectory.appending(path: "session.json")
        guard let marker = try? loadNVIDIAMetalFXModuleSessionMarker(markerURL),
              let sessionModuleNames = Self
                .recognizedNVIDIAMetalFXModuleSessionNames(marker) else {
            return false
        }

        let allowedPaths = Set(
            sessionModuleNames.map {
                "system32/\($0)"
            }
        )
        let observedPaths = Set(inspection.mixedModules)
        guard observedPaths.isSubset(of: allowedPaths) else {
            return false
        }

        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        for entry in marker.entries {
            do {
                _ = try validatedNVIDIAMetalFXModuleRestoration(
                    for: entry,
                    schemaVersion: marker.schemaVersion,
                    sessionDirectory: sessionDirectory,
                    system32: system32,
                    backupDirectory: backupDirectory,
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable
                )
            } catch {
                return false
            }
        }
        return true
    }

    private func nvidiaMetalFXSessionInspectionPaths(
        prefix: URL,
        runtimeExecutable: URL
    ) -> [String] {
        let backupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32",
            directoryHint: .isDirectory
        )
        let sessionDirectory = nvidiaMetalFXModuleSessionDirectory(
            backupDirectory: backupDirectory
        )
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            return []
        }
        // Exact paths deliberately remain visible even when the marker or a
        // snapshot is malformed. The recovery predicate will then reject the
        // transaction and keep Steam blocked instead of silently treating the
        // overlay as ordinary prefix content.
        let allKnownOwnedPaths = Self
            .nvidiaMetalFXKnownSessionModuleNames.sorted().map {
            "system32/\($0)"
        }
        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: prefix,
                to: sessionDirectory,
                fileManager: fileManager
              ),
              FileSystemItemPolicy.isNonSymlinkDirectory(
                sessionDirectory,
                fileManager: fileManager
              ) else {
            return allKnownOwnedPaths
        }
        let markerURL = sessionDirectory.appending(path: "session.json")
        guard let marker = try? loadNVIDIAMetalFXModuleSessionMarker(markerURL),
              let sessionModuleNames = Self
                .recognizedNVIDIAMetalFXModuleSessionNames(marker) else {
            return allKnownOwnedPaths
        }
        for entry in marker.entries {
            guard (try? nvidiaMetalFXStagedSource(
                for: entry,
                schemaVersion: marker.schemaVersion,
                sessionDirectory: sessionDirectory,
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )) != nil else {
                return allKnownOwnedPaths
            }
        }
        return sessionModuleNames.map { "system32/\($0)" }
    }

    /// Restores only the exact files recorded by the transient NVIDIA MetalFX
    /// session. This deliberately does not repair unrelated renderer overlays.
    func restoreNVIDIAMetalFXSessionModules(
        prefix: URL,
        runtimeExecutable: URL
    ) throws {
        try restoreNVIDIAMetalFXSessionModules(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            admission: .completedRegistryBarrier
        )
    }

    private func restoreNVIDIAMetalFXSessionModules(
        prefix: URL,
        runtimeExecutable: URL,
        admission: ModuleRestorationAdmission
    ) throws {
        try requireContainedNonSymlinkDirectory(prefix, within: prefix)
        if case .completedRegistryBarrier = admission {
            // The registry marker owns the session-restoration barrier. A
            // delete may already be visible in system.reg while wineserver -w
            // has not yet proved that the prefix is quiescent. Keep the module
            // transaction staged until that barrier retires the marker.
            let registryMarker = nvidiaMetalFXRegistrySessionMarker(in: prefix)
            guard !fileManager.fileExists(atPath: registryMarker.path) else {
                return
            }
        }
        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        let backupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32",
            directoryHint: .isDirectory
        )
        try requireContainedNonSymlinkDirectory(system32, within: prefix)
        let sessionDirectory = nvidiaMetalFXModuleSessionDirectory(
            backupDirectory: backupDirectory
        )
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            return
        }
        try requireContainedNonSymlinkDirectory(
            sessionDirectory,
            within: prefix
        )
        let markerURL = sessionDirectory.appending(path: "session.json")
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        let marker = try loadNVIDIAMetalFXModuleSessionMarker(markerURL)
        guard Self.recognizedNVIDIAMetalFXModuleSessionNames(marker) != nil else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                markerURL,
                "MetalFX module ownership marker has an unsupported version or module set"
            )
        }

        var restoredModuleNames: [String] = []
        do {
            for entry in marker.entries {
                let destination = system32.appending(path: entry.moduleName)
                let validated = try validatedNVIDIAMetalFXModuleRestoration(
                    for: entry,
                    schemaVersion: marker.schemaVersion,
                    sessionDirectory: sessionDirectory,
                    system32: system32,
                    backupDirectory: backupDirectory,
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable
                )

                if entry.destinationWasPresent {
                    guard let snapshot = validated.destinationSnapshot,
                          let expected = entry.destinationIdentity else {
                        throw SteamLaunchError.rendererBridgeInstallFailed(
                            markerURL,
                            "MetalFX destination snapshot metadata is incomplete"
                        )
                    }
                    if validated.destinationState != .alreadyRestored {
                        // Once restoration starts, even a later temporary-file
                        // retirement or readback failure can leave this destination
                        // partially restored. Enroll it in rollback before the first
                        // mutation so the ownership marker always remains retryable.
                        restoredModuleNames.append(entry.moduleName)
                        try restoreRegularFileAtomically(
                            from: snapshot,
                            to: destination
                        )
                        guard try stableRendererFileIdentity(destination) == expected else {
                            throw SteamLaunchError.rendererBridgeInstallFailed(
                                destination,
                                "MetalFX destination restoration verification failed"
                            )
                        }
                    }
                } else {
                    if validated.destinationState != .alreadyRemoved {
                        restoredModuleNames.append(entry.moduleName)
                        try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                            destination,
                            fileManager: fileManager
                        )
                        try fileManager.removeItem(at: destination)
                    }
                }
            }
            try fileManager.removeItem(at: sessionDirectory)
            guard !fileManager.fileExists(atPath: sessionDirectory.path) else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    sessionDirectory,
                    "MetalFX transaction-created snapshots were not retired"
                )
            }
        } catch let restorationError {
            var rollbackFailures: [String] = []
            for moduleName in restoredModuleNames.reversed() {
                guard let entry = marker.entries.first(where: {
                    $0.moduleName == moduleName
                }) else { continue }
                let destination = system32.appending(path: moduleName)
                do {
                    let stagedSource = try nvidiaMetalFXStagedSource(
                        for: entry,
                        schemaVersion: marker.schemaVersion,
                        sessionDirectory: sessionDirectory,
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable
                    )
                    try restoreRegularFileAtomically(
                        from: stagedSource,
                        to: destination
                    )
                    guard try stableRendererFileIdentity(destination) ==
                            entry.stagedIdentity else {
                        throw SteamLaunchError.rendererBridgeInstallFailed(
                            destination,
                            "MetalFX staged-state rollback verification failed"
                        )
                    }
                } catch {
                    rollbackFailures.append(
                        "\(moduleName): \(forgePlayTechnicalErrorSummary(error))"
                    )
                }
            }
            let rollbackDetail = rollbackFailures.isEmpty
                ? ""
                : "; staged-state rollback failed: \(rollbackFailures.joined(separator: ", "))"
            throw SteamLaunchError.rendererBridgeInstallFailed(
                system32,
                "\(forgePlayTechnicalErrorSummary(restorationError))\(rollbackDetail)"
            )
        }
    }

    /// Restores only the NGXCore value created by ForgePlay for a prior
    /// NVIDIA MetalFX session. A pre-existing matching user/vendor value is
    /// never marked as ForgePlay-owned and is therefore never removed.
    @MainActor
    func restoreNVIDIAMetalFXRegistrySessionIfNeeded(
        prefix: URL,
        runtimeExecutable: URL,
        runner: SafeProcessRunner,
        logDirectory: URL,
        phase: SteamRendererLifecyclePhase = .postLaunchRestoration
    ) async throws {
        try requireContainedNonSymlinkDirectory(prefix, within: prefix)
        let marker = nvidiaMetalFXRegistrySessionMarker(in: prefix)
        guard fileManager.fileExists(atPath: marker.path) else { return }
        let session = try loadNVIDIAMetalFXRegistrySessionMarker(marker)
        try await rollbackNVIDIAMetalFXRegistryStage(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runner: runner,
            logDirectory: logDirectory,
            marker: marker,
            session: session,
            phase: phase
        )
    }

    /// Advertises the verified System32 NGX bridge to game-side NVIDIA NGX
    /// loaders for the detached Steam session. ForgePlay records ownership
    /// before mutation and removes only that exact value on the next
    /// prefix-mutation boundary.
    @MainActor
    func stageNVIDIAMetalFXRegistrySession(
        prefix: URL,
        runtimeExecutable: URL,
        runner: SafeProcessRunner,
        logDirectory: URL
    ) async throws {
        try requireContainedNonSymlinkDirectory(prefix, within: prefix)
        let marker = nvidiaMetalFXRegistrySessionMarker(in: prefix)

        if fileManager.fileExists(atPath: marker.path) {
            let existingSession = try loadNVIDIAMetalFXRegistrySessionMarker(
                marker
            )
            for projection in existingSession.projections {
                let currentValue = try nvidiaMetalFXNGXCoreFullPath(
                    in: prefix,
                    registryPath: projection.registryPath,
                    valueName: projection.valueName
                )
                guard currentValue == nil ||
                        Self.isExpectedNVIDIAMetalFXNGXCoreFullPath(
                            currentValue
                        ) else {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        marker,
                        "ForgePlay-owned NGXCore registry state changed before reuse"
                    )
                }
            }
            if existingSession.schemaVersion == 2,
               try nvidiaMetalFXNGXCoreRegistryViewsArePrepared(in: prefix) {
                return
            }

            // Retire legacy one-view markers and interrupted partial v2
            // transactions before creating the complete dual-view projection.
            try await rollbackNVIDIAMetalFXRegistryStage(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runner: runner,
                logDirectory: logDirectory,
                marker: marker,
                session: existingSession,
                phase: .preparationRollback
            )
        }

        var ownedProjections: [NVIDIAMetalFXRegistryProjection] = []
        for projection in Self.nvidiaMetalFXNGXCoreRegistryProjections {
            let currentValue = try nvidiaMetalFXNGXCoreFullPath(
                in: prefix,
                registryPath: projection.registryPath,
                valueName: projection.valueName
            )
            if Self.isExpectedNVIDIAMetalFXNGXCoreFullPath(currentValue) {
                continue
            }
            guard currentValue == nil else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    prefix.appending(path: "system.reg"),
                    "NGXCore FullPath already contains a non-ForgePlay value; refusing to overwrite it"
                )
            }
            ownedProjections.append(projection)
        }
        guard !ownedProjections.isEmpty else { return }

        let session = NVIDIAMetalFXRegistrySessionMarker(
            schemaVersion: 2,
            projections: ownedProjections
        )
        try writeNVIDIAMetalFXRegistrySessionMarker(
            marker,
            prefix: prefix,
            session: session
        )
        do {
            for projection in ownedProjections {
                try await runNVIDIAMetalFXRegistryAction(
                    .setRegistryValue(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        registryPath: projection.registryPath,
                        valueName: projection.valueName,
                        valueType: "REG_SZ",
                        value: projection.stagedValue,
                        registryView: projection.registryPath ==
                            Self.nvidiaMetalFXNGXCoreRegistryPath
                            ? .bit32
                            : .bit64,
                        logDirectory: logDirectory
                    ),
                    runner: runner,
                    phase: .preparation,
                    operation: .ngxCoreFullPathRegistration,
                    target: prefix.appending(path: "system.reg")
                )
            }
            try await flushNVIDIAMetalFXRegistry(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                runner: runner,
                logDirectory: logDirectory,
                phase: .preparation
            )
            guard try nvidiaMetalFXNGXCoreRegistryViewsArePrepared(
                in: prefix
            ) else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    prefix.appending(path: "system.reg"),
                    "NGX provider path registration was not persisted in every required NVIDIA registry projection"
                )
            }
        } catch let stageError {
            let rollbackFailure: String?
            var processResults = diagnosticProcessRunResults(
                from: stageError
            )
            do {
                try await rollbackNVIDIAMetalFXRegistryStage(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    runner: runner,
                    logDirectory: logDirectory,
                    marker: marker,
                    session: session,
                    phase: .preparationRollback
                )
                rollbackFailure = nil
            } catch {
                rollbackFailure = forgePlayTechnicalErrorSummary(error)
                processResults.append(
                    contentsOf: diagnosticProcessRunResults(from: error)
                )
            }
            let detail = [
                forgePlayTechnicalErrorSummary(stageError),
                rollbackFailure.map {
                    "NGXCore registry rollback failed: \($0)"
                }
            ]
            .compactMap { $0 }
            .joined(separator: "; ")
            throw SteamLaunchError.rendererLifecycleFailed(
                SteamRendererLifecycleFailure(
                    phase: .preparation,
                    operation: .ngxCoreFullPathRegistration,
                    target: marker,
                    detail: detail,
                    processResults: processResults.reduce(into: []) {
                        if !$0.contains($1) { $0.append($1) }
                    }
                )
            )
        }
    }

    /// Stages the canonical modules and byte-identical compatibility aliases
    /// required in the Wine prefix System32 directory
    /// for experimental MetalFX conversion of DLSS calls. The
    /// original files, when present, are backed up for the targeted session
    /// restoration path; the explicit full repair path remains separate.
    func stageNVIDIAMetalFXBridgeModules(
        prefix: URL,
        runtimeExecutable: URL
    ) throws -> [String] {
        try requireContainedNonSymlinkDirectory(prefix, within: prefix)
        let requiredNames = Set(
            Self.nvidiaMetalFXSystem32ModuleNames
        )
        let sourcesByName = try nvidiaMetalFXSourcesByName(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable
        )
        guard Set(sourcesByName.keys) == requiredNames else {
            let missing = requiredNames
                .subtracting(sourcesByName.keys)
                .sorted()
                .joined(separator: ", ")
            throw SteamLaunchError.rendererBridgeInstallFailed(
                runtimeExecutable,
                "MetalFX requires verified System32 modules: \(missing)"
            )
        }

        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        let backupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32",
            directoryHint: .isDirectory
        )
        try requireContainedNonSymlinkDirectory(system32, within: prefix)
        try createContainedNonSymlinkDirectoryIfNeeded(
            backupDirectory,
            within: prefix
        )
        let sessionDirectory = nvidiaMetalFXModuleSessionDirectory(
            backupDirectory: backupDirectory
        )
        if fileManager.fileExists(atPath: sessionDirectory.path) {
            try requireContainedNonSymlinkDirectory(
                sessionDirectory,
                within: prefix
            )
        }
        let markerURL = sessionDirectory.appending(path: "session.json")
        if fileManager.fileExists(atPath: markerURL.path) {
            let marker = try loadNVIDIAMetalFXModuleSessionMarker(markerURL)
            guard let sessionModuleNames = Self
                    .recognizedNVIDIAMetalFXModuleSessionNames(marker) else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    markerURL,
                    "Existing MetalFX session ownership marker is unsupported"
                )
            }
            let reusableCurrentSession: Bool
            if sessionModuleNames == requiredNames.sorted() {
                reusableCurrentSession = try marker.entries.allSatisfy({ entry in
                      let destination = system32.appending(path: entry.moduleName)
                      guard fileManager.fileExists(atPath: destination.path) else {
                          return false
                      }
                      let stagedSource = try nvidiaMetalFXStagedSource(
                          for: entry,
                          schemaVersion: marker.schemaVersion,
                          sessionDirectory: sessionDirectory,
                          prefix: prefix,
                          runtimeExecutable: runtimeExecutable
                      )
                      let destinationIdentity = try stableRendererFileIdentity(
                          destination
                      )
                      return try stableRendererFileIdentity(stagedSource) ==
                              entry.stagedIdentity &&
                          destinationIdentity == entry.stagedIdentity
                  })
            } else {
                reusableCurrentSession = false
            }
            if reusableCurrentSession {
                return requiredNames.sorted()
            }
            // Normal orchestration retires registry ownership, restores the
            // prior module transaction through the completed-barrier path, and
            // only then calls stage. A direct stage call must not bypass that
            // ordering for a historical schema.
            throw SteamLaunchError.rendererBridgeInstallFailed(
                markerURL,
                "Existing MetalFX session must be restored before staging"
            )
        }
        if fileManager.fileExists(atPath: sessionDirectory.path) {
            // System32 mutation starts only after the complete marker is
            // atomically published and reread. A contained markerless directory
            // therefore owns snapshots only and is safe to retire before a new
            // transaction; it must not become a permanent launch gate.
            try fileManager.removeItem(at: sessionDirectory)
            guard !fileManager.fileExists(atPath: sessionDirectory.path) else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    sessionDirectory,
                    "Markerless MetalFX transaction could not be retired"
                )
            }
        }
        guard !fileManager.fileExists(atPath: sessionDirectory.path) else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                sessionDirectory,
                "Uncommitted MetalFX session directory already exists"
            )
        }
        try fileManager.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: false
        )
        try requireContainedNonSymlinkDirectory(sessionDirectory, within: prefix)

        var entries: [NVIDIAMetalFXModuleSessionEntry] = []
        do {
            for moduleName in requiredNames.sorted() {
                guard let source = sourcesByName[moduleName] else {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        runtimeExecutable,
                        "MetalFX source is unavailable: \(moduleName)"
                    )
                }
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                    source,
                    fileManager: fileManager
                )
                let destination = system32.appending(path: moduleName)
                let legacyBackup = backupDirectory.appending(
                    path: "\(moduleName).original"
                )
                let destinationWasPresent = fileManager.fileExists(
                    atPath: destination.path
                )
                let backupWasPresent = fileManager.fileExists(
                    atPath: legacyBackup.path
                )
                let destinationIdentity = destinationWasPresent
                    ? try stableRendererFileIdentity(destination)
                    : nil
                let backupIdentity = backupWasPresent
                    ? try stableRendererFileIdentity(legacyBackup)
                    : nil
                let snapshotName = destinationWasPresent
                    ? "destination-\(moduleName).original"
                    : nil
                let stagedSnapshotName = "staged-\(moduleName)"
                let stagedSnapshot = sessionDirectory.appending(
                    path: stagedSnapshotName
                )
                try restoreRegularFileAtomically(
                    from: source,
                    to: stagedSnapshot
                )
                let stagedIdentity = try stableRendererFileIdentity(source)
                guard try stableRendererFileIdentity(stagedSnapshot) ==
                        stagedIdentity else {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        stagedSnapshot,
                        "MetalFX staged source snapshot verification failed"
                    )
                }
                if let snapshotName {
                    let snapshot = sessionDirectory.appending(path: snapshotName)
                    try restoreRegularFileAtomically(
                        from: destination,
                        to: snapshot
                    )
                    guard try stableRendererFileIdentity(snapshot) == destinationIdentity else {
                        throw SteamLaunchError.rendererBridgeInstallFailed(
                            snapshot,
                            "MetalFX destination snapshot verification failed"
                        )
                    }
                }
                entries.append(
                    NVIDIAMetalFXModuleSessionEntry(
                        moduleName: moduleName,
                        stagedIdentity: stagedIdentity,
                        stagedSnapshotName: stagedSnapshotName,
                        destinationWasPresent: destinationWasPresent,
                        destinationIdentity: destinationIdentity,
                        backupWasPresent: backupWasPresent,
                        backupIdentity: backupIdentity,
                        destinationSnapshotName: snapshotName
                    )
                )
            }
            let marker = NVIDIAMetalFXModuleSessionMarker(
                schemaVersion:
                    D3DMetalNVIDIAProviderContract
                        .moduleSessionSchemaVersion,
                entries: entries
            )
            try writeNVIDIAMetalFXModuleSessionMarker(marker, to: markerURL)

            for moduleName in requiredNames.sorted() {
                guard let source = sourcesByName[moduleName] else { continue }
                let destination = system32.appending(path: moduleName)
                let sourceIdentity = try stableRendererFileIdentity(source)
                let destinationMatchesSource: Bool
                if fileManager.fileExists(atPath: destination.path) {
                    destinationMatchesSource = sourceIdentity ==
                        (try stableRendererFileIdentity(destination))
                } else {
                    destinationMatchesSource = false
                }
                if !destinationMatchesSource {
                    try restoreRegularFileAtomically(
                        from: source,
                        to: destination
                    )
                }
                guard sourceIdentity ==
                        (try stableRendererFileIdentity(destination)) else {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        destination,
                        "MetalFX System32 module verification failed"
                    )
                }
            }
        } catch let stageError {
            let rollbackFailure: String?
            do {
                if fileManager.fileExists(atPath: markerURL.path) {
                    try restoreNVIDIAMetalFXSessionModules(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable,
                        admission: .stagingRollback
                    )
                } else if fileManager.fileExists(atPath: sessionDirectory.path) {
                    try fileManager.removeItem(at: sessionDirectory)
                }
                rollbackFailure = nil
            } catch {
                rollbackFailure = forgePlayTechnicalErrorSummary(error)
            }
            let detail = [
                forgePlayTechnicalErrorSummary(stageError),
                rollbackFailure.map {
                    "MetalFX rollback failed: \($0)"
                }
            ]
            .compactMap { $0 }
            .joined(separator: "; ")
            throw SteamLaunchError.rendererBridgeInstallFailed(
                system32,
                detail
            )
        }
        return requiredNames.sorted()
    }

    /// Version 2 sessions carry a session-owned copy of the exact bytes put in
    /// System32. Restoration therefore remains valid after an app/runtime
    /// update. Version 1 sessions predate that snapshot and retain the stricter
    /// current-runtime identity check.
    private func nvidiaMetalFXStagedSource(
        for entry: NVIDIAMetalFXModuleSessionEntry,
        schemaVersion: Int,
        sessionDirectory: URL,
        prefix: URL,
        runtimeExecutable: URL
    ) throws -> URL {
        let source: URL
        switch schemaVersion {
        case 2, 3:
            guard entry.stagedSnapshotName ==
                    "staged-\(entry.moduleName)" else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    sessionDirectory,
                    "MetalFX staged snapshot metadata is incomplete"
                )
            }
            source = sessionDirectory.appending(
                path: "staged-\(entry.moduleName)"
            )
        case 1:
            guard let legacySource = try nvidiaMetalFXSourcesByName(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )[entry.moduleName] else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    runtimeExecutable,
                    "MetalFX legacy staged source is unavailable: \(entry.moduleName)"
                )
            }
            source = legacySource
        default:
            throw SteamLaunchError.rendererBridgeInstallFailed(
                sessionDirectory,
                "MetalFX module ownership marker version is unsupported"
            )
        }
        guard try stableRendererFileIdentity(source) == entry.stagedIdentity else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                source,
                "MetalFX staged source snapshot changed during the session"
            )
        }
        return source
    }

    private func nvidiaMetalFXDestinationRestorationState(
        for entry: NVIDIAMetalFXModuleSessionEntry,
        in system32: URL
    ) throws -> NVIDIAMetalFXDestinationRestorationState? {
        let destination = system32.appending(path: entry.moduleName)
        guard fileManager.fileExists(atPath: destination.path) else {
            return entry.destinationWasPresent ? nil : .alreadyRemoved
        }
        let identity = try stableRendererFileIdentity(destination)
        if identity == entry.stagedIdentity {
            return .staged
        }
        if entry.destinationWasPresent,
           let originalIdentity = entry.destinationIdentity,
           identity == originalIdentity {
            return .alreadyRestored
        }
        return nil
    }

    private func validatedNVIDIAMetalFXModuleRestoration(
        for entry: NVIDIAMetalFXModuleSessionEntry,
        schemaVersion: Int,
        sessionDirectory: URL,
        system32: URL,
        backupDirectory: URL,
        prefix: URL,
        runtimeExecutable: URL
    ) throws -> NVIDIAMetalFXValidatedModuleRestoration {
        _ = try nvidiaMetalFXStagedSource(
            for: entry,
            schemaVersion: schemaVersion,
            sessionDirectory: sessionDirectory,
            prefix: prefix,
            runtimeExecutable: runtimeExecutable
        )
        guard let destinationState = try
                nvidiaMetalFXDestinationRestorationState(
            for: entry,
            in: system32
        ) else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                system32.appending(path: entry.moduleName),
                "MetalFX destination changed before restoration"
            )
        }

        let legacyBackup = backupDirectory.appending(
            path: "\(entry.moduleName).original"
        )
        if entry.backupWasPresent {
            guard let expected = entry.backupIdentity,
                  fileManager.fileExists(atPath: legacyBackup.path),
                  try stableRendererFileIdentity(legacyBackup) == expected else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    legacyBackup,
                    "Pre-existing MetalFX backup changed during the session"
                )
            }
        } else {
            guard entry.backupIdentity == nil else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    sessionDirectory,
                    "MetalFX backup marker flags are contradictory"
                )
            }
            guard !fileManager.fileExists(atPath: legacyBackup.path) else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    legacyBackup,
                    "An unowned MetalFX backup appeared during the session"
                )
            }
        }

        let destinationSnapshot: URL?
        if entry.destinationWasPresent {
            guard let snapshotName = entry.destinationSnapshotName,
                  snapshotName ==
                    "destination-\(entry.moduleName).original",
                  let expected = entry.destinationIdentity else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    sessionDirectory,
                    "MetalFX destination snapshot metadata is incomplete"
                )
            }
            let snapshot = sessionDirectory.appending(path: snapshotName)
            guard try stableRendererFileIdentity(snapshot) == expected else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    snapshot,
                    "MetalFX destination snapshot changed"
                )
            }
            destinationSnapshot = snapshot
        } else {
            guard entry.destinationIdentity == nil,
                  entry.destinationSnapshotName == nil else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    sessionDirectory,
                    "MetalFX destination marker flags are contradictory"
                )
            }
            destinationSnapshot = nil
        }
        return NVIDIAMetalFXValidatedModuleRestoration(
            destinationState: destinationState,
            destinationSnapshot: destinationSnapshot
        )
    }

    @MainActor
    private func rollbackNVIDIAMetalFXRegistryStage(
        prefix: URL,
        runtimeExecutable: URL,
        runner: SafeProcessRunner,
        logDirectory: URL,
        marker: URL,
        session: NVIDIAMetalFXRegistrySessionMarker,
        phase: SteamRendererLifecyclePhase
    ) async throws {
        for projection in session.projections {
            let currentValue = try nvidiaMetalFXNGXCoreFullPath(
                in: prefix,
                registryPath: projection.registryPath,
                valueName: projection.valueName
            )
            if let currentValue {
                guard Self.isExpectedNVIDIAMetalFXNGXCoreFullPath(
                    currentValue
                ) else {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        marker,
                        "ForgePlay-owned NGXCore FullPath changed before restoration"
                    )
                }
                do {
                    try await runNVIDIAMetalFXRegistryAction(
                        .deleteRegistryValue(
                            runtimeExecutable: runtimeExecutable,
                            prefix: prefix,
                            registryPath: projection.registryPath,
                            valueName: projection.valueName,
                            registryView: projection.registryPath ==
                                Self.nvidiaMetalFXNGXCoreRegistryPath
                                ? .bit32
                                : .bit64,
                            logDirectory: logDirectory
                        ),
                        runner: runner,
                        phase: phase,
                        operation: .ngxCoreFullPathRestoration,
                        target: prefix.appending(path: "system.reg")
                    )
                } catch {
                    // Treat an externally/idempotently completed strict
                    // delete as success only when authoritative registry
                    // readback proves the owned value is already absent.
                    guard try nvidiaMetalFXNGXCoreFullPath(
                        in: prefix,
                        registryPath: projection.registryPath,
                        valueName: projection.valueName
                    ) == nil else {
                        throw error
                    }
                }
            }
        }
        // The marker represents the whole registry restoration transaction,
        // not only presence of FullPath. Always repeat the authoritative Wine
        // prefix flush before retiring it, including retries where a prior
        // delete is already visible in system.reg.
        try await flushNVIDIAMetalFXRegistry(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            runner: runner,
            logDirectory: logDirectory,
            phase: phase
        )
        for projection in session.projections {
            guard try nvidiaMetalFXNGXCoreFullPath(
                in: prefix,
                registryPath: projection.registryPath,
                valueName: projection.valueName
            ) == nil else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    prefix.appending(path: "system.reg"),
                    "NGX provider path restoration was not persisted"
                )
            }
        }
        try removeNVIDIAMetalFXRegistrySessionMarker(marker)
    }

    @MainActor
    private func runNVIDIAMetalFXRegistryAction(
        _ action: RunnerAction,
        runner: SafeProcessRunner,
        phase: SteamRendererLifecyclePhase,
        operation: SteamRendererLifecycleOperation,
        target: URL
    ) async throws {
        let result: ProcessRunResult
        if let registryActionExecutor {
            result = try await registryActionExecutor(action, runner)
        } else {
            result = try await runner.run(action)
        }
        guard result.succeeded else {
            let rawWaitStatusDescription = result.rawWaitStatus.map(String.init) ?? "none"
            throw SteamLaunchError.rendererLifecycleFailed(
                SteamRendererLifecycleFailure(
                    phase: phase,
                    operation: operation,
                    target: target,
                    detail:
                        "outcome=\(result.outcome.rawValue), " +
                        "timedOut=\(result.didTimeOut), " +
                        "processExit=\(result.diagnosticExitCodeDescription), " +
                        "forgePlayStatus=\(result.diagnosticForgePlayStatusDescription), " +
                        "signal=\(result.diagnosticTerminationSignalDescription), " +
                        "rawWaitStatus=\(rawWaitStatusDescription)",
                    processResults: [result]
                )
            )
        }
    }

    @MainActor
    private func flushNVIDIAMetalFXRegistry(
        runtimeExecutable: URL,
        prefix: URL,
        runner: SafeProcessRunner,
        logDirectory: URL,
        phase: SteamRendererLifecyclePhase
    ) async throws {
        try await runNVIDIAMetalFXRegistryAction(
            .waitForWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ),
            runner: runner,
            phase: phase,
            operation: .ngxCoreRegistryFlush,
            target: prefix.appending(path: "system.reg")
        )
    }

    private func nvidiaMetalFXNGXCoreRegistryViewsArePrepared(
        in prefix: URL
    ) throws -> Bool {
        try Self.nvidiaMetalFXNGXCoreRegistryProjections.allSatisfy {
            projection in
            Self.isExpectedNVIDIAMetalFXNGXCoreFullPath(
                try nvidiaMetalFXNGXCoreFullPath(
                    in: prefix,
                    registryPath: projection.registryPath,
                    valueName: projection.valueName
                )
            )
        }
    }

    private func nvidiaMetalFXNGXCoreFullPath(
        in prefix: URL,
        registryPath: String,
        valueName: String
    ) throws -> String? {
        let registry = prefix.appending(path: "system.reg")
        let data = try Self.boundedStableRegularFileData(
            at: registry,
            maximumByteCount: 32 * 1_024 * 1_024
        )
        guard let contents = String(data: data, encoding: .utf8) else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                registry,
                "system.reg is not valid bounded UTF-8 registry data"
            )
        }
        return WineUserRegistrySnapshot(contents: contents).value(
            forRegistryPath: registryPath,
            valueName: valueName
        )
    }

    private func nvidiaMetalFXRegistrySessionMarker(in prefix: URL) -> URL {
        prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/" +
                Self.nvidiaMetalFXRegistrySessionMarkerName
        )
    }

    private func nvidiaMetalFXModuleSessionDirectory(
        backupDirectory: URL
    ) -> URL {
        backupDirectory.appending(
            path: ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
    }

    private func stableRendererFileIdentity(
        _ url: URL
    ) throws -> NVIDIAMetalFXModuleFileIdentity {
        let data = try Self.boundedStableRegularFileData(
            at: url,
            maximumByteCount: 256 * 1_024 * 1_024
        )
        return NVIDIAMetalFXModuleFileIdentity(
            byteCount: data.count,
            sha256: SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private func loadNVIDIAMetalFXModuleSessionMarker(
        _ marker: URL
    ) throws -> NVIDIAMetalFXModuleSessionMarker {
        let data = try Self.boundedStableRegularFileData(
            at: marker,
            maximumByteCount: 64 * 1_024
        )
        do {
            return try JSONDecoder().decode(
                NVIDIAMetalFXModuleSessionMarker.self,
                from: data
            )
        } catch {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                marker,
                "MetalFX module ownership marker is malformed"
            )
        }
    }

    private func writeNVIDIAMetalFXModuleSessionMarker(
        _ marker: NVIDIAMetalFXModuleSessionMarker,
        to markerURL: URL
    ) throws {
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                markerURL,
                "MetalFX module ownership marker already exists"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
        guard try loadNVIDIAMetalFXModuleSessionMarker(markerURL) == marker else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                markerURL,
                "MetalFX 모듈 복원 정보 파일을 저장한 뒤 내용이 일치하는지 확인하지 못했습니다."
            )
        }
    }

    private nonisolated static func boundedStableRegularFileData(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                url,
                "File could not be opened without following links"
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= maximumByteCount else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                url,
                "File exceeds the bounded stable-read contract"
            )
        }
        let expectedByteCount = Int(before.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedByteCount)
        var offset = 0
        while offset < expectedByteCount {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    expectedByteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    url,
                    "File could not be read completely"
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
            throw SteamLaunchError.rendererBridgeInstallFailed(
                url,
                "File changed during the bounded read"
            )
        }
        return Data(bytes)
    }

    private func loadNVIDIAMetalFXRegistrySessionMarker(
        _ marker: URL
    ) throws -> NVIDIAMetalFXRegistrySessionMarker {
        let descriptor = open(marker.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                marker,
                "NGXCore registry ownership marker could not be opened safely"
            )
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 16 * 1_024 else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                marker,
                "NGXCore registry ownership marker is not a bounded stable file"
            )
        }
        let expectedByteCount = Int(before.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedByteCount)
        var offset = 0
        while offset < expectedByteCount {
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    expectedByteCount - offset,
                    off_t(offset)
                )
            }
            guard count > 0 else {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    marker,
                    "NGXCore registry ownership marker could not be read completely"
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
            throw SteamLaunchError.rendererBridgeInstallFailed(
                marker,
                "NGXCore registry ownership marker changed while it was read"
            )
        }
        let decoded = try JSONDecoder().decode(
            NVIDIAMetalFXRegistrySessionMarker.self,
            from: Data(bytes)
        )
        let supported = Set(Self.nvidiaMetalFXNGXCoreRegistryProjections)
        let decodedProjections = Set(decoded.projections)
        let schemaIsSupported =
            (decoded.schemaVersion == 1 && decoded.projections.count == 1) ||
            (decoded.schemaVersion == 2 && !decoded.projections.isEmpty)
        guard schemaIsSupported,
              decodedProjections.count == decoded.projections.count,
              decodedProjections.isSubset(of: supported) else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                marker,
                "NGXCore registry ownership marker does not match the current contract"
            )
        }
        return decoded
    }

    private func writeNVIDIAMetalFXRegistrySessionMarker(
        _ marker: URL,
        prefix: URL,
        session: NVIDIAMetalFXRegistrySessionMarker
    ) throws {
        let parent = marker.deletingLastPathComponent()
        try createContainedNonSymlinkDirectoryIfNeeded(parent, within: prefix)
        guard !fileManager.fileExists(atPath: marker.path) else {
            throw SteamLaunchError.rendererBridgeInstallFailed(
                marker,
                "NGXCore registry ownership marker already exists"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session)
            .write(to: marker, options: .atomic)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(
            marker,
            fileManager: fileManager
        )
    }

    private func removeNVIDIAMetalFXRegistrySessionMarker(
        _ marker: URL
    ) throws {
        guard fileManager.fileExists(atPath: marker.path) else { return }
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(
            marker,
            fileManager: fileManager
        )
        try fileManager.removeItem(at: marker)
    }

    private func nvidiaMetalFXSourcesByName(
        prefix: URL,
        runtimeExecutable: URL
    ) throws -> [String: URL] {
        Dictionary(
            uniqueKeysWithValues:
                try SafeProcessRunner
                    .d3dMetalNVIDIAMetalFXSystem32Modules(
                        for: runtimeExecutable,
                        prefix: prefix
                    )
                    .map {
                        ($0.lastPathComponent.lowercased(), $0)
                    }
        )
    }

    private func restoreUnselectedBridgeModules(
        in system32: URL,
        backupDirectory: URL,
        selectedModuleNames: Set<String>
    ) throws {
        for moduleName in SafeProcessRunner.rendererBridgeDLLNames.subtracting(selectedModuleNames) {
            let destination = system32.appending(path: moduleName)
            let backup = backupDirectory.appending(path: "\(moduleName).original")
            guard fileManager.fileExists(atPath: backup.path) else { continue }
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(backup, fileManager: fileManager)

            if fileManager.fileExists(atPath: destination.path) {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
                if fileManager.contentsEqual(atPath: destination.path, andPath: backup.path) {
                    continue
                }
            }

            try restoreRegularFileAtomically(from: backup, to: destination)
        }
    }

    private func restoreRegularFileAtomically(from backup: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).restore-\(UUID().uuidString)"
        )
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try fileManager.copyItem(at: backup, to: temporary)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(temporary, fileManager: fileManager)

        if fileManager.fileExists(atPath: destination.path) {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            try swapFilesAtomically(temporary, destination)
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            } catch {
                do {
                    try swapFilesAtomically(temporary, destination)
                } catch let rollbackError {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        destination,
                        "restored renderer validation failed and the original could not be rolled back: \(forgePlayTechnicalErrorSummary(error)); rollback: \(forgePlayTechnicalErrorSummary(rollbackError))"
                    )
                }
                throw error
            }
            try fileManager.removeItem(at: temporary)
        } else {
            try renameFileAtomically(temporary, destination)
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
        }
    }

    private func requireContainedNonSymlinkDirectory(_ directory: URL, within prefix: URL) throws {
        let prefix = prefix.standardizedFileURL
        let directory = directory.standardizedFileURL
        if directory.path == prefix.path {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(directory, fileManager: fileManager)
            return
        }
        guard directory.path.hasPrefix("\(prefix.path)/"),
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: prefix,
                to: directory,
                fileManager: fileManager
              ),
              FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(directory)
        }
    }

    private func createContainedNonSymlinkDirectoryIfNeeded(_ directory: URL, within prefix: URL) throws {
        let prefix = prefix.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard directory.path == prefix.path || directory.path.hasPrefix("\(prefix.path)/") else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(directory)
        }
        if directory.path == prefix.path {
            try requireContainedNonSymlinkDirectory(directory, within: prefix)
            return
        }

        let parent = directory.deletingLastPathComponent()
        try createContainedNonSymlinkDirectoryIfNeeded(parent, within: prefix)
        if fileManager.fileExists(atPath: directory.path) {
            try requireContainedNonSymlinkDirectory(directory, within: prefix)
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try requireContainedNonSymlinkDirectory(directory, within: prefix)
    }

    private func swapFilesAtomically(_ first: URL, _ second: URL) throws {
        let result: Int32 = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else {
                    errno = EINVAL
                    return -1
                }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func renameFileAtomically(_ source: URL, _ destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeUnbackedBridgeModules(
        in system32: URL,
        backupDirectory: URL,
        knownRendererModules: [URL]
    ) throws {
        guard !knownRendererModules.isEmpty else { return }

        for moduleName in SafeProcessRunner.rendererBridgeDLLNames {
            let destination = system32.appending(path: moduleName)
            let backup = backupDirectory.appending(path: "\(moduleName).original")
            guard fileManager.fileExists(atPath: destination.path),
                  !fileManager.fileExists(atPath: backup.path) else {
                continue
            }
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            guard isKnownRendererModule(destination, knownRendererModules: knownRendererModules) ||
                Self.hasRendererBridgeMarker(destination, fileManager: fileManager) else {
                continue
            }
            try fileManager.removeItem(at: destination)
        }
    }

    private func isKnownRendererModule(_ file: URL, knownRendererModules: [URL]) -> Bool {
        knownRendererModules.contains { fileManager.contentsEqual(atPath: $0.path, andPath: file.path) }
    }

    private func knownRendererBridgeModulesByWindowsDirectory(
        for runtimeExecutable: URL,
        prefix: URL
    ) throws -> [String: [URL]] {
        var modulesByWindowsDirectory: [String: [URL]] = [:]
        for backend in SteamRendererPolicyPreference.allCases {
            do {
                let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
                    for: runtimeExecutable,
                    graphicsBackend: backend,
                    prefix: prefix
                )
                for (directoryName, directoryModules) in modules {
                    modulesByWindowsDirectory[directoryName, default: []].append(contentsOf: directoryModules)
                }
            } catch {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    runtimeExecutable,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        return modulesByWindowsDirectory.mapValues { modules in
            var seen = Set<String>()
            return modules.filter { module in
                seen.insert(module.standardizedFileURL.path).inserted
            }
        }
    }

    private nonisolated static let rendererPolicyWindowsDirectoryNames = [
        "system32",
        "syswow64"
    ]

    private nonisolated static let nvidiaMetalFXSystem32ModuleNames =
        D3DMetalNVIDIAProviderContract.system32ModuleNames
    private nonisolated static let nvidiaMetalFXLegacyThreeModuleNames =
        D3DMetalNVIDIAProviderContract.legacyThreeModuleNames
    private nonisolated static let nvidiaMetalFXKnownSessionModuleNames = Set(
        nvidiaMetalFXSystem32ModuleNames + nvidiaMetalFXLegacyThreeModuleNames
    )

    private nonisolated static func recognizedNVIDIAMetalFXModuleSessionNames(
        _ marker: NVIDIAMetalFXModuleSessionMarker
    ) -> [String]? {
        let names = marker.entries.map(\.moduleName)
        guard names == names.sorted(),
              Set(names).count == names.count else {
            return nil
        }
        switch marker.schemaVersion {
        case 1, 2:
            return names == nvidiaMetalFXLegacyThreeModuleNames.sorted()
                ? names : nil
        case 3:
            return names == nvidiaMetalFXSystem32ModuleNames.sorted()
                ? names : nil
        default:
            return nil
        }
    }

    // Wine serializes the logical 32-bit registry view under Wow6432Node.
    // NVIDIA loaders are not consistent about the location or view they
    // query. Streamline 2.8 checks the native nvlddmkm NGXPath first, then the
    // native NGXCore FullPath, while other integrations explicitly request
    // the 32-bit NGXCore view. Advertise the same owned System32 bridge through
    // all three projections for the detached session.
    nonisolated static let nvidiaMetalFXNGXCoreRegistryPath =
        "HKLM\\Software\\Wow6432Node\\NVIDIA Corporation\\Global\\NGXCore"
    nonisolated static let nvidiaMetalFXNGXCoreNativeRegistryPath =
        "HKLM\\Software\\NVIDIA Corporation\\Global\\NGXCore"
    nonisolated static let nvidiaMetalFXNGXDriverRegistryPath =
        "HKLM\\System\\CurrentControlSet\\Services\\nvlddmkm\\NGXCore"
    nonisolated static let nvidiaMetalFXNGXCoreFullPathValueName = "FullPath"
    nonisolated static let nvidiaMetalFXNGXDriverPathValueName = "NGXPath"
    nonisolated static let nvidiaMetalFXNGXCoreSystem32Path =
        "C:\\windows\\system32"
    nonisolated static let nvidiaMetalFXRegistrySessionMarkerName =
        "nvidia-metalfx-ngxcore-session.json"

    private nonisolated static let nvidiaMetalFXNGXCoreRegistryProjections = [
        NVIDIAMetalFXRegistryProjection(
            registryPath: nvidiaMetalFXNGXDriverRegistryPath,
            valueName: nvidiaMetalFXNGXDriverPathValueName,
            stagedValue: nvidiaMetalFXNGXCoreSystem32Path
        ),
        NVIDIAMetalFXRegistryProjection(
            registryPath: nvidiaMetalFXNGXCoreNativeRegistryPath,
            valueName: nvidiaMetalFXNGXCoreFullPathValueName,
            stagedValue: nvidiaMetalFXNGXCoreSystem32Path
        ),
        NVIDIAMetalFXRegistryProjection(
            registryPath: nvidiaMetalFXNGXCoreRegistryPath,
            valueName: nvidiaMetalFXNGXCoreFullPathValueName,
            stagedValue: nvidiaMetalFXNGXCoreSystem32Path
        )
    ]

    private nonisolated static func isExpectedNVIDIAMetalFXNGXCoreFullPath(
        _ value: String?
    ) -> Bool {
        value?.caseInsensitiveCompare(nvidiaMetalFXNGXCoreSystem32Path) ==
            .orderedSame
    }

    private nonisolated static let rendererPolicyDLLNames: Set<String> = [
        "_nvngx.dll",
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

    private nonisolated static let rendererBridgeFileMarkers = [
        "DXMT",
        "D3DMetal",
        "WineMetalEntry",
        "winemetal.dll",
        "DXVK",
        "dxvk",
        "nvngx-on-metalfx",
        "libd3dshared"
    ]

    private nonisolated static func hasRendererBridgeMarker(_ url: URL, fileManager: FileManager) -> Bool {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager),
              let data = try? boundedStableRegularFileData(
                at: url,
                maximumByteCount: 256 * 1_024 * 1_024
              ),
              let contents = String(data: data, encoding: .utf8) else {
            return false
        }
        return rendererBridgeFileMarkers.contains { contents.localizedCaseInsensitiveContains($0) }
    }
}

extension SteamRendererPolicyManager {
    /// Captures only the authenticated renderer catalog. Unrelated variables
    /// remain outside the projection and broker markers are stripped by the
    /// immutable clone operation.
    func windowsRendererNeutralEnvironment(
        catalog: WindowsRendererEnvironmentCatalog,
        baseEnvironment: [String: String]
    ) throws -> (
        projection: WindowsRendererNeutralEnvironmentProjection,
        clone: WindowsRendererEnvironmentClone
    ) {
        let projection = try WindowsRendererNeutralEnvironmentProjection
            .capture(catalog: catalog, environment: baseEnvironment)
        let clone = try projection.applying(to: baseEnvironment)
        return (projection, clone)
    }
}
