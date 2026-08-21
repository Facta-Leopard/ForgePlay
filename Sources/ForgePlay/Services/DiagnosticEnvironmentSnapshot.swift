import AppKit
import Darwin
import Foundation
import Metal

struct DiagnosticCollectionIssue: Codable, Hashable, Sendable {
    var component: String
    var message: String
}

struct DiagnosticEnvironmentSnapshot: Codable, Hashable, Sendable {
    struct Application: Codable, Hashable, Sendable {
        var name: String
        var bundleIdentifier: String
        var version: String
        var build: String
        var buildConfiguration: String
        var processArchitecture: String
        var sandboxed: Bool
    }

    struct Host: Codable, Hashable, Sendable {
        var operatingSystemVersion: String
        var operatingSystemVersionString: String
        var operatingSystemBuild: String?
        var kernelVersion: String?
        var modelIdentifier: String?
        var cpuBrand: String?
        var processorCount: Int
        var activeProcessorCount: Int
        var physicalMemoryBytes: UInt64
        var translatedProcess: Bool?
        var availableMemoryBytesEstimate: UInt64? = nil
        var rosettaTranslationAvailability: String? = nil
        var lowPowerModeEnabled: Bool
        var thermalState: String
        var localeIdentifier: String
        var timeZoneIdentifier: String
    }

    struct GraphicsDevice: Codable, Hashable, Sendable {
        var name: String
        var lowPower: Bool
        var removable: Bool
        var headless: Bool
        var unifiedMemory: Bool
        var recommendedMaxWorkingSetBytes: UInt64
    }

    struct Display: Codable, Hashable, Sendable {
        var pixelWidth: Int
        var pixelHeight: Int
        var scaleFactor: Double
        var primary: Bool
    }

    struct Volume: Codable, Hashable, Sendable {
        var role: String
        var available: Bool
        var formatDescription: String?
        var totalCapacityBytes: Int64?
        var availableCapacityBytes: Int64?
        var readOnly: Bool?
        var removable: Bool?
        var internalVolume: Bool?
    }

    struct Runtime: Codable, Hashable, Sendable {
        var configured: Bool
        var executableName: String?
        var exists: Bool
        var regularFile: Bool?
        var symbolicLink: Bool?
        var executable: Bool?
        var byteCount: Int64?
        var modifiedAt: Date?
        var graphicsBackend: String?
        var availableGraphicsBackends: [String]
        var supportedDirect3DGenerations: [String]
        var supportedDirect3DGenerationsByBackend: [String: [String]]? = nil
        var supportedSynchronizationBackends: [String]?
        var capabilityEvidence: [String]
        var limitations: [String]
        var identity: RuntimeIdentity
    }

    struct RuntimeIdentity: Codable, Hashable, Sendable {
        /// `verified`, `derivedIncomplete`, `unavailable`, `invalid`, or `notConfigured`.
        var state: String
        var schemaVersion: Int?
        var runtimeIdentifier: String?
        var wineVersion: String?
        var architecture: String?
        var sourceTreeSHA256: String?
        var patchSetSHA256: String?
        var runnerLauncherSHA256: String?
        var wineInfSHA256: String?
        var winebootSHA256: String?
        var prefixCompatibilityFingerprint: String?
        var runnerBuildFingerprint: String?
        var corePayloadFingerprint: String? = nil
        var identitySource: String?
        var wineInfFingerprintState: String?
        var winebootFingerprintState: String?
        var corePayloadFingerprintState: String? = nil
        var identityIssues: [String]
        var validationError: String?

        static let notConfigured = RuntimeIdentity(
            state: "notConfigured",
            schemaVersion: nil,
            runtimeIdentifier: nil,
            wineVersion: nil,
            architecture: nil,
            sourceTreeSHA256: nil,
            patchSetSHA256: nil,
            runnerLauncherSHA256: nil,
            wineInfSHA256: nil,
            winebootSHA256: nil,
            prefixCompatibilityFingerprint: nil,
            runnerBuildFingerprint: nil,
            identitySource: nil,
            wineInfFingerprintState: nil,
            winebootFingerprintState: nil,
            identityIssues: [],
            validationError: nil
        )
    }

    struct GameManifest: Codable, Hashable, Sendable {
        var steamAppID: String
        var name: String
        var installedByteCount: Int64
        var lastUpdated: Date?
        var manifestAvailable: Bool
        var stateFlags: Int?
        var buildID: String?
        var bytesDownloaded: Int64?
        var bytesToDownload: Int64?
    }

    var capturedAt: Date
    var application: Application
    var host: Host
    var graphicsDevices: [GraphicsDevice]
    var displays: [Display]
    var volumes: [Volume]
    var runtime: Runtime
    var selectedGame: GameManifest?
    var synchronizationSelection: String?
    var appliedSynchronizationSelection: String?
    var appliedSynchronizationBackend: String?
    var rendererSelection: String?
    var videoMemorySelection: String?
    var resolvedVideoMemoryMB: Int?
    var collectionIssues: [DiagnosticCollectionIssue]
}

private struct DiagnosticEnvironmentPresentationSnapshot: Sendable {
    var capturedAt: Date
    var application: DiagnosticEnvironmentSnapshot.Application
    var host: DiagnosticEnvironmentSnapshot.Host
    var graphicsDevices: [DiagnosticEnvironmentSnapshot.GraphicsDevice]
    var displays: [DiagnosticEnvironmentSnapshot.Display]
    var collectionIssues: [DiagnosticCollectionIssue]
}

private struct DiagnosticEnvironmentFileManagerReference: @unchecked Sendable {
    let value: FileManager
}

@MainActor
enum DiagnosticEnvironmentSnapshotCollector {
    static func captureLaunchSelectedGameContext(
        _ game: SteamGame
    ) -> SteamLaunchSelectedGameContext {
        var issues: [DiagnosticCollectionIssue] = []
        let snapshot = captureGameManifest(game, issues: &issues)
        let issueSummary = issues.map(\.message).joined(separator: " | ")
        return SteamLaunchSelectedGameContext(
            steamAppID: snapshot.steamAppID,
            name: snapshot.name,
            buildID: snapshot.buildID,
            manifestStateFlags: snapshot.stateFlags,
            installedByteCount: snapshot.installedByteCount,
            lastUpdated: snapshot.lastUpdated,
            manifestAvailable: snapshot.manifestAvailable,
            manifestCaptureIssue: issueSummary.isEmpty ? nil : issueSummary
        )
    }

    static func capture(
        managedRoot: URL,
        selectedSteamReference: SteamGame?,
        runtimeExecutable: URL?,
        steamStoragePaths: [String] = [],
        synchronizationSelection: String? = nil,
        rendererSelection: String? = nil,
        videoMemorySelection: String? = nil,
        resolvedVideoMemoryMB: Int? = nil,
        runtimeIdentity: DiagnosticEnvironmentSnapshot.RuntimeIdentity? = nil,
        fileManager: FileManager = .default
    ) -> DiagnosticEnvironmentSnapshot {
        assembleSnapshot(
            presentation: capturePresentationSnapshot(),
            managedRoot: managedRoot,
            selectedSteamReference: selectedSteamReference,
            runtimeExecutable: runtimeExecutable,
            steamStoragePaths: steamStoragePaths,
            synchronizationSelection: synchronizationSelection,
            rendererSelection: rendererSelection,
            videoMemorySelection: videoMemorySelection,
            resolvedVideoMemoryMB: resolvedVideoMemoryMB,
            runtimeIdentity: runtimeIdentity,
            fileManager: fileManager
        )
    }

    static func captureInBackground(
        managedRoot: URL,
        selectedSteamReference: SteamGame?,
        runtimeExecutable: URL?,
        steamStoragePaths: [String] = [],
        synchronizationSelection: String? = nil,
        rendererSelection: String? = nil,
        videoMemorySelection: String? = nil,
        resolvedVideoMemoryMB: Int? = nil,
        runtimeIdentity: DiagnosticEnvironmentSnapshot.RuntimeIdentity? = nil,
        fileManager: FileManager = .default
    ) async throws -> DiagnosticEnvironmentSnapshot {
        let presentation = capturePresentationSnapshot()
        let filesystem = DiagnosticEnvironmentFileManagerReference(value: fileManager)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let snapshot = Self.assembleSnapshot(
                presentation: presentation,
                managedRoot: managedRoot,
                selectedSteamReference: selectedSteamReference,
                runtimeExecutable: runtimeExecutable,
                steamStoragePaths: steamStoragePaths,
                synchronizationSelection: synchronizationSelection,
                rendererSelection: rendererSelection,
                videoMemorySelection: videoMemorySelection,
                resolvedVideoMemoryMB: resolvedVideoMemoryMB,
                runtimeIdentity: runtimeIdentity,
                fileManager: filesystem.value
            )
            try Task.checkCancellation()
            return snapshot
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func capturePresentationSnapshot() -> DiagnosticEnvironmentPresentationSnapshot {
        var issues: [DiagnosticCollectionIssue] = []
        let processInfo = ProcessInfo.processInfo
        let processHostContext = ProcessRunHostContext.capture()
        let version = processInfo.operatingSystemVersion

        let osBuild = sysctlString("kern.osversion")
        if osBuild == nil {
            issues.append(.init(component: "host.operatingSystemBuild", message: "kern.osversion unavailable"))
        }
        let kernelVersion = sysctlString("kern.version")
        if kernelVersion == nil {
            issues.append(.init(component: "host.kernelVersion", message: "kern.version unavailable"))
        }
        let modelIdentifier = sysctlString("hw.model")
        if modelIdentifier == nil {
            issues.append(.init(component: "host.modelIdentifier", message: "hw.model unavailable"))
        }
        let cpuBrand = sysctlString("machdep.cpu.brand_string")
        if cpuBrand == nil {
            issues.append(.init(component: "host.cpuBrand", message: "machdep.cpu.brand_string unavailable"))
        }

        let app = DiagnosticEnvironmentSnapshot.Application(
            name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ForgePlay",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            buildConfiguration: buildConfiguration,
            processArchitecture: processArchitecture,
            sandboxed: ForgePlaySandboxPolicy.isAppSandboxEnabled
        )
        let host = DiagnosticEnvironmentSnapshot.Host(
            operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemVersionString: processInfo.operatingSystemVersionString,
            operatingSystemBuild: osBuild,
            kernelVersion: kernelVersion,
            modelIdentifier: modelIdentifier,
            cpuBrand: cpuBrand,
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            translatedProcess: sysctlInt32("sysctl.proc_translated").map { $0 == 1 },
            availableMemoryBytesEstimate: processHostContext.availableMemoryBytesEstimate,
            rosettaTranslationAvailability: processHostContext.rosettaTranslationAvailability,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateName(processInfo.thermalState),
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )

        let graphicsDevices = MTLCopyAllDevices().map {
            DiagnosticEnvironmentSnapshot.GraphicsDevice(
                name: $0.name,
                lowPower: $0.isLowPower,
                removable: $0.isRemovable,
                headless: $0.isHeadless,
                unifiedMemory: $0.hasUnifiedMemory,
                recommendedMaxWorkingSetBytes: $0.recommendedMaxWorkingSetSize
            )
        }
        if graphicsDevices.isEmpty {
            issues.append(.init(component: "graphicsDevices", message: "Metal reported no devices"))
        }

        let screens = NSScreen.screens
        let mainScreen = NSScreen.main
        let displays = screens.map { screen in
            let pixels = screen.convertRectToBacking(screen.frame)
            return DiagnosticEnvironmentSnapshot.Display(
                pixelWidth: Int(pixels.width.rounded()),
                pixelHeight: Int(pixels.height.rounded()),
                scaleFactor: screen.backingScaleFactor,
                primary: screen === mainScreen
            )
        }
        if displays.isEmpty {
            issues.append(.init(component: "displays", message: "no active display was reported"))
        }

        return DiagnosticEnvironmentPresentationSnapshot(
            capturedAt: Date(),
            application: app,
            host: host,
            graphicsDevices: graphicsDevices,
            displays: displays,
            collectionIssues: issues
        )
    }

    private nonisolated static func assembleSnapshot(
        presentation: DiagnosticEnvironmentPresentationSnapshot,
        managedRoot: URL,
        selectedSteamReference: SteamGame?,
        runtimeExecutable: URL?,
        steamStoragePaths: [String],
        synchronizationSelection: String?,
        rendererSelection: String?,
        videoMemorySelection: String?,
        resolvedVideoMemoryMB: Int?,
        runtimeIdentity: DiagnosticEnvironmentSnapshot.RuntimeIdentity?,
        fileManager: FileManager
    ) -> DiagnosticEnvironmentSnapshot {
        var issues = presentation.collectionIssues

        var volumeInputs: [(role: String, url: URL)] = [("managedRoot", managedRoot)]
        if let selectedSteamReference {
            volumeInputs.append((
                "selectedGameLibrary",
                URL(fileURLWithPath: selectedSteamReference.libraryPath, isDirectory: true)
            ))
        }
        let boundedSteamStoragePaths = steamStoragePaths.prefix(maximumSteamStoragePaths)
        if steamStoragePaths.count > boundedSteamStoragePaths.count {
            issues.append(.init(
                component: "volumes.steamStoragePaths",
                message: "retained \(boundedSteamStoragePaths.count) of \(steamStoragePaths.count) paths at the diagnostic input limit"
            ))
        }
        for (index, path) in boundedSteamStoragePaths.enumerated() {
            volumeInputs.append((
                "steamStorage\(index + 1)",
                URL(fileURLWithPath: path, isDirectory: true)
            ))
        }

        var seenVolumeRoles = Set<String>()
        let volumes = volumeInputs.compactMap { input -> DiagnosticEnvironmentSnapshot.Volume? in
            guard seenVolumeRoles.insert(input.role).inserted else { return nil }
            return captureVolume(role: input.role, url: input.url, fileManager: fileManager, issues: &issues)
        }

        let runtime = captureRuntime(
            runtimeExecutable,
            resolvedIdentity: runtimeIdentity,
            fileManager: fileManager,
            issues: &issues
        )
        let game = selectedSteamReference.map {
            captureGameManifest($0, issues: &issues)
        }
        let appliedSynchronization = captureAppliedSynchronizationPolicy(
            managedRoot: managedRoot,
            fileManager: fileManager,
            issues: &issues
        )

        return DiagnosticEnvironmentSnapshot(
            capturedAt: presentation.capturedAt,
            application: presentation.application,
            host: presentation.host,
            graphicsDevices: presentation.graphicsDevices,
            displays: presentation.displays,
            volumes: volumes,
            runtime: runtime,
            selectedGame: game,
            synchronizationSelection: synchronizationSelection,
            appliedSynchronizationSelection: appliedSynchronization?.selection.rawValue,
            appliedSynchronizationBackend: appliedSynchronization?.backend.rawValue,
            rendererSelection: rendererSelection,
            videoMemorySelection: videoMemorySelection,
            resolvedVideoMemoryMB: resolvedVideoMemoryMB,
            collectionIssues: issues
        )
    }

    private struct PrefixSynchronizationDocument: Decodable {
        var synchronizationSelection: String?
        var synchronizationBackend: String?
    }

    private nonisolated static func captureAppliedSynchronizationPolicy(
        managedRoot: URL,
        fileManager: FileManager,
        issues: inout [DiagnosticCollectionIssue]
    ) -> WineSynchronizationPolicy? {
        let metadataURL = managedRoot
            .appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
            .appending(path: "prefix.json", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(metadataURL, fileManager: fileManager),
              let byteCount = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              byteCount <= 1_048_576,
              let data = try? Data(contentsOf: metadataURL),
              let document = try? JSONDecoder().decode(PrefixSynchronizationDocument.self, from: data) else {
            issues.append(.init(
                component: "synchronization.appliedPolicy",
                message: "Steam prefix synchronization policy is unavailable or invalid"
            ))
            return nil
        }
        let legacySelections = Set(["automatic", "msync", "esync"])
        let legacyBackends = Set(["server", "msync", "esync"])
        guard document.synchronizationSelection.map(legacySelections.contains) ?? true,
              document.synchronizationBackend.map(legacyBackends.contains) ?? true else {
            issues.append(.init(
                component: "synchronization.appliedPolicy",
                message: "Steam prefix synchronization policy contains unsupported or inconsistent values"
            ))
            return nil
        }
        return .automaticServer
    }

    private nonisolated static func captureVolume(
        role: String,
        url: URL,
        fileManager: FileManager,
        issues: inout [DiagnosticCollectionIssue]
    ) -> DiagnosticEnvironmentSnapshot.Volume {
        guard let existingURL = nearestExistingAncestor(of: url, fileManager: fileManager) else {
            issues.append(.init(component: "volumes.\(role)", message: "path and its ancestors are unavailable"))
            return .init(
                role: role,
                available: false,
                formatDescription: nil,
                totalCapacityBytes: nil,
                availableCapacityBytes: nil,
                readOnly: nil,
                removable: nil,
                internalVolume: nil
            )
        }
        do {
            let values = try existingURL.resourceValues(forKeys: [
                .volumeLocalizedFormatDescriptionKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeIsReadOnlyKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey
            ])
            return .init(
                role: role,
                available: fileManager.fileExists(atPath: url.path),
                formatDescription: values.volumeLocalizedFormatDescription,
                totalCapacityBytes: values.volumeTotalCapacity.map(Int64.init),
                availableCapacityBytes: values.volumeAvailableCapacityForImportantUsage,
                readOnly: values.volumeIsReadOnly,
                removable: values.volumeIsRemovable,
                internalVolume: values.volumeIsInternal
            )
        } catch {
            issues.append(.init(
                component: "volumes.\(role)",
                message: forgePlayTechnicalErrorSummary(error)
            ))
            return .init(
                role: role,
                available: fileManager.fileExists(atPath: url.path),
                formatDescription: nil,
                totalCapacityBytes: nil,
                availableCapacityBytes: nil,
                readOnly: nil,
                removable: nil,
                internalVolume: nil
            )
        }
    }

    private nonisolated static func captureRuntime(
        _ executableURL: URL?,
        resolvedIdentity: DiagnosticEnvironmentSnapshot.RuntimeIdentity?,
        fileManager: FileManager,
        issues: inout [DiagnosticCollectionIssue]
    ) -> DiagnosticEnvironmentSnapshot.Runtime {
        guard let executableURL else {
            return .init(
                configured: false,
                executableName: nil,
                exists: false,
                regularFile: nil,
                symbolicLink: nil,
                executable: nil,
                byteCount: nil,
                modifiedAt: nil,
                graphicsBackend: nil,
                availableGraphicsBackends: [],
                supportedDirect3DGenerations: [],
                supportedSynchronizationBackends: nil,
                capabilityEvidence: [],
                limitations: [],
                identity: .notConfigured
            )
        }
        let identity = resolvedIdentity ?? .init(
            state: "unavailable",
            schemaVersion: nil,
            runtimeIdentifier: nil,
            wineVersion: nil,
            architecture: nil,
            sourceTreeSHA256: nil,
            patchSetSHA256: nil,
            runnerLauncherSHA256: nil,
            wineInfSHA256: nil,
            winebootSHA256: nil,
            prefixCompatibilityFingerprint: nil,
            runnerBuildFingerprint: nil,
            identitySource: nil,
            wineInfFingerprintState: nil,
            winebootFingerprintState: nil,
            identityIssues: [],
            validationError: "runtime identity was not collected"
        )
        if resolvedIdentity == nil {
            issues.append(.init(
                component: "runtime.identity",
                message: "runtime identity was not collected"
            ))
        } else if let validationError = identity.validationError {
            issues.append(.init(component: "runtime.identity", message: validationError))
        }
        for identityIssue in identity.identityIssues {
            issues.append(.init(component: "runtime.identity", message: identityIssue))
        }
        let exists = fileManager.fileExists(atPath: executableURL.path)
        let isExecutable = fileManager.isExecutableFile(atPath: executableURL.path)
        do {
            let values = try executableURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            let capability = values.isRegularFile == true && values.isSymbolicLink != true && isExecutable
                ? WindowsRuntimeService.inspectRuntimeCapability(for: executableURL, fileManager: fileManager)
                : nil
            let synchronizationCapabilities = values.isRegularFile == true &&
                values.isSymbolicLink != true && isExecutable
                ? SafeProcessRunner.wineSynchronizationRuntimeCapabilities(
                    for: executableURL,
                    fileManager: fileManager
                )
                : nil
            return .init(
                configured: true,
                executableName: executableURL.lastPathComponent,
                exists: exists,
                regularFile: values.isRegularFile,
                symbolicLink: values.isSymbolicLink,
                executable: isExecutable,
                byteCount: values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                graphicsBackend: capability.map { graphicsBackendName($0.graphicsBackend) },
                availableGraphicsBackends: capability?.availableGraphicsBackends
                    .map { graphicsBackendName($0) }
                    .sorted() ?? [],
                supportedDirect3DGenerations: capability?.supportedDirect3DGenerations
                    .map(\.rawValue)
                    .sorted() ?? [],
                supportedDirect3DGenerationsByBackend: capability?
                    .direct3DGenerationsByBackendDiagnostics,
                supportedSynchronizationBackends: synchronizationCapabilities?.supportedBackends
                    .map(\.rawValue)
                    .sorted(),
                capabilityEvidence: capability?.evidence ?? [],
                limitations: capability?.limitations ?? [],
                identity: identity
            )
        } catch {
            issues.append(.init(component: "runtime", message: forgePlayTechnicalErrorSummary(error)))
            return .init(
                configured: true,
                executableName: executableURL.lastPathComponent,
                exists: exists,
                regularFile: nil,
                symbolicLink: nil,
                executable: exists ? isExecutable : false,
                byteCount: nil,
                modifiedAt: nil,
                graphicsBackend: nil,
                availableGraphicsBackends: [],
                supportedDirect3DGenerations: [],
                supportedSynchronizationBackends: nil,
                capabilityEvidence: [],
                limitations: [],
                identity: identity
            )
        }
    }

    nonisolated static func resolveRuntimeIdentity(
        for executableURL: URL?,
        fileManager: FileManager = .default
    ) -> DiagnosticEnvironmentSnapshot.RuntimeIdentity {
        guard let executableURL else { return .notConfigured }
        do {
            let manifest = try RuntimeManifestResolver(fileManager: fileManager)
                .diagnosticManifest(for: executableURL)
            let identityIssues = manifest.identityIssues ?? []
            return .init(
                state: identityIssues.isEmpty ? "verified" : "derivedIncomplete",
                schemaVersion: manifest.schemaVersion,
                runtimeIdentifier: manifest.runtimeIdentifier,
                wineVersion: manifest.wineVersion,
                architecture: manifest.architecture,
                sourceTreeSHA256: manifest.sourceTreeSHA256,
                patchSetSHA256: manifest.patchSetSHA256,
                runnerLauncherSHA256: manifest.runnerLauncherSHA256,
                wineInfSHA256: manifest.wineInfSHA256,
                winebootSHA256: manifest.winebootSHA256,
                prefixCompatibilityFingerprint: manifest.prefixCompatibilityFingerprint,
                runnerBuildFingerprint: manifest.runnerBuildFingerprint,
                corePayloadFingerprint: manifest.corePayloadFingerprint,
                identitySource: manifest.identitySource,
                wineInfFingerprintState: manifest.wineInfFingerprintState,
                winebootFingerprintState: manifest.winebootFingerprintState,
                corePayloadFingerprintState: manifest.corePayloadFingerprintState,
                identityIssues: identityIssues,
                validationError: nil
            )
        } catch {
            return .init(
                state: "invalid",
                schemaVersion: nil,
                runtimeIdentifier: nil,
                wineVersion: nil,
                architecture: nil,
                sourceTreeSHA256: nil,
                patchSetSHA256: nil,
                runnerLauncherSHA256: nil,
                wineInfSHA256: nil,
                winebootSHA256: nil,
                prefixCompatibilityFingerprint: nil,
                runnerBuildFingerprint: nil,
                identitySource: nil,
                wineInfFingerprintState: nil,
                winebootFingerprintState: nil,
                identityIssues: [],
                validationError: forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private nonisolated static func graphicsBackendName(
        _ backend: WindowsRuntimeCapability.GraphicsBackend
    ) -> String {
        switch backend {
        case .d3dMetal: "d3dMetal"
        case .moltenVKOrVulkan: "moltenVKOrVulkan"
        case .unsupportedByMetadata: "unsupportedByMetadata"
        case .unknown: "unknown"
        }
    }

    private nonisolated static func captureGameManifest(
        _ game: SteamGame,
        issues: inout [DiagnosticCollectionIssue]
    ) -> DiagnosticEnvironmentSnapshot.GameManifest {
        let manifestURL = URL(fileURLWithPath: game.manifestPath)
        var stateFlags: Int?
        var buildID: String?
        var bytesDownloaded: Int64?
        var bytesToDownload: Int64?
        var available = false
        do {
            if let text = try SteamVDFFileReader.readText(
                manifestURL,
                maxBytes: SteamVDFFileReader.maxManifestBytes
            ) {
                available = true
                let root = try VDFParser().parse(text)
                let appState = root["AppState"]?.objectValue
                guard let parsedAppID = SteamGameIdentityPolicy.appId(
                    appState?["appid"]?.stringValue
                ),
                parsedAppID == game.steamAppId,
                SteamGameIdentityPolicy.manifestFileNameMatches(
                    manifestURL,
                    appId: game.steamAppId
                ) else {
                    issues.append(.init(
                        component: "selectedGame.manifest",
                        message: "manifest AppID or filename does not match the selected game; build/state fields were not attributed"
                    ))
                    return .init(
                        steamAppID: game.steamAppId,
                        name: game.name,
                        installedByteCount: game.sizeOnDisk,
                        lastUpdated: game.lastUpdated,
                        manifestAvailable: true,
                        stateFlags: nil,
                        buildID: nil,
                        bytesDownloaded: nil,
                        bytesToDownload: nil
                    )
                }
                stateFlags = appState?["StateFlags"]?.stringValue.flatMap(Int.init)
                buildID = appState?["buildid"]?.stringValue
                bytesDownloaded = appState?["BytesDownloaded"]?.stringValue.flatMap(Int64.init)
                bytesToDownload = appState?["BytesToDownload"]?.stringValue.flatMap(Int64.init)
            } else {
                issues.append(.init(component: "selectedGame.manifest", message: "manifest unavailable or outside the safe size/type policy"))
            }
        } catch {
            issues.append(.init(component: "selectedGame.manifest", message: forgePlayTechnicalErrorSummary(error)))
        }
        return .init(
            steamAppID: game.steamAppId,
            name: game.name,
            installedByteCount: game.sizeOnDisk,
            lastUpdated: game.lastUpdated,
            manifestAvailable: available,
            stateFlags: stateFlags,
            buildID: buildID,
            bytesDownloaded: bytesDownloaded,
            bytesToDownload: bytesToDownload
        )
    }

    private nonisolated static func nearestExistingAncestor(
        of url: URL,
        fileManager: FileManager
    ) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return fileManager.fileExists(atPath: "/") ? URL(fileURLWithPath: "/", isDirectory: true) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "unsupported-host-architecture"
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    nonisolated static let maximumSteamStoragePaths = 128
}
