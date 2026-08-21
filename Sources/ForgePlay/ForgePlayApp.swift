import AppKit
import Darwin
import Observation
import SwiftData
import SwiftUI

enum ForgePlayLaunchSplashPolicy {
    static let assetName = "LaunchSplash"
}

@MainActor
@Observable
final class ForgePlayModelContainerBootstrap {
    typealias Factory = @Sendable () async throws -> ModelContainer

    private(set) var result: Result<ModelContainer, Error>?
    @ObservationIgnored
    private(set) var completedPublicationCount = 0
    @ObservationIgnored
    private(set) var startedAttemptCount = 0

    @ObservationIgnored
    private let makeContainer: Factory
    @ObservationIgnored
    private var didStart = false
    @ObservationIgnored
    private var publicationTask: Task<Void, Never>?
    @ObservationIgnored
    private var currentAttemptToken: UUID?

    init(makeContainer: @escaping Factory) {
        self.makeContainer = makeContainer
    }

    func startIfNeeded() {
        guard !didStart else { return }
        beginAttempt()
    }

    @discardableResult
    func retryAfterFailure() -> Bool {
        guard case .failure? = result,
              publicationTask == nil else {
            return false
        }
        beginAttempt()
        return true
    }

    private func beginAttempt() {
        publicationTask?.cancel()
        let attemptToken = UUID()
        currentAttemptToken = attemptToken
        didStart = true
        startedAttemptCount += 1
        result = nil

        let makeContainer = makeContainer
        publicationTask = Task { @MainActor [weak self] in
            let attemptResult: Result<ModelContainer, Error>
            do {
                attemptResult = .success(try await makeContainer())
            } catch {
                attemptResult = .failure(error)
            }
            guard !Task.isCancelled,
                  let self,
                  self.currentAttemptToken == attemptToken else {
                return
            }
            self.publicationTask = nil
            self.completedPublicationCount += 1
            self.result = attemptResult
        }
    }

    func cancel() {
        publicationTask?.cancel()
        publicationTask = nil
        currentAttemptToken = nil
        didStart = false
        result = nil
    }

    deinit {
        publicationTask?.cancel()
    }
}

private final class ForgePlayStoreMigrationLease {
    /// `flock` coordinates separate processes, but does not reliably serialize
    /// two lock attempts made by this process. Pair it with an in-process gate
    /// so concurrent startup paths cannot publish the same migration.
    private static let processLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at lockURL: URL) throws -> ForgePlayStoreMigrationLease {
        processLock.lock()
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            processLock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1 else {
            let failure = errno
            Darwin.close(descriptor)
            processLock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let failure = errno
                Darwin.close(descriptor)
                processLock.unlock()
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
        }
        return ForgePlayStoreMigrationLease(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        let descriptorToClose = descriptor
        descriptor = -1
        _ = flock(descriptorToClose, LOCK_UN)
        Darwin.close(descriptorToClose)
        Self.processLock.unlock()
    }

    deinit {
        release()
    }
}

private struct ForgePlayPreparedPersistentStore {
    let url: URL
    let migrationLease: ForgePlayStoreMigrationLease?
}

struct ForgePlayStartupFailureRecoveryPartition: Equatable {
    let failureFrame: CGRect
    let actionFrame: CGRect
}

struct ForgePlayStartupFailureRecoveryLayout: Layout {
    static let minimumActionRegionHeight: CGFloat = 88

    nonisolated static func partition(
        in bounds: CGRect,
        measuredActionHeight: CGFloat
    ) -> ForgePlayStartupFailureRecoveryPartition {
        let availableWidth = max(0, bounds.width)
        let availableHeight = max(0, bounds.height)
        let measuredHeight = measuredActionHeight.isFinite
            ? max(0, measuredActionHeight)
            : 0
        let actionHeight = min(
            availableHeight,
            max(minimumActionRegionHeight, measuredHeight)
        )
        let failureHeight = availableHeight - actionHeight
        return ForgePlayStartupFailureRecoveryPartition(
            failureFrame: CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: availableWidth,
                height: failureHeight
            ),
            actionFrame: CGRect(
                x: bounds.minX,
                y: bounds.maxY - actionHeight,
                width: availableWidth,
                height: actionHeight
            )
        )
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let contentSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        let actionSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(
            width: max(0, proposal.width ?? max(contentSize.width, actionSize.width)),
            height: max(
                0,
                proposal.height ?? contentSize.height + max(
                    Self.minimumActionRegionHeight,
                    actionSize.height
                )
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        let actionSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        )
        let partition = Self.partition(
            in: bounds,
            measuredActionHeight: actionSize.height
        )
        subviews[0].place(
            at: partition.failureFrame.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: partition.failureFrame.width,
                height: partition.failureFrame.height
            )
        )
        subviews[1].place(
            at: partition.actionFrame.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: partition.actionFrame.width,
                height: partition.actionFrame.height
            )
        )
    }
}

@main
struct ForgePlayApp: App {
    @NSApplicationDelegateAdaptor(ForgePlayApplicationDelegate.self) private var applicationDelegate
    @State private var appState = AppState()
    @State private var services = AppServices()
    @State private var modelContainerBootstrap: ForgePlayModelContainerBootstrap

    init() {
        _modelContainerBootstrap = State(
            initialValue: ForgePlayModelContainerBootstrap(
                makeContainer: Self.modelContainerFactory()
            )
        )
    }

    var body: some Scene {
        WindowGroup(id: ForgePlaySceneID.main) {
            windowContent
                .task {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    modelContainerBootstrap.startIfNeeded()
                }
                .task(id: appState.effectiveLanguageMode) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    await services.activateFontCompatibilityPack(
                        for: appState.effectiveLanguageMode
                    )
                }
                .frame(minWidth: 1_020, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(appState.localized("ForgePlay 종료")) {
                    applicationDelegate.requestApplicationTermination()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            settingsContent
                .task {
                    modelContainerBootstrap.startIfNeeded()
                }
                .task(id: appState.effectiveLanguageMode) {
                    await services.activateFontCompatibilityPack(
                        for: appState.effectiveLanguageMode
                    )
                }
        }
    }

    @ViewBuilder
    private var windowContent: some View {
        switch modelContainerBootstrap.result {
        case .some(.success(let modelContainer)):
            RootView()
                .onAppear {
                    applicationDelegate.configure(appState: appState, services: services)
                }
                #if DEBUG
                .forgePlayDebugDynamicType(appState.debugDynamicTypeSize)
                #endif
                .environment(appState)
                .environment(services)
                .environment(\.locale, appState.locale)
                .modelContainer(modelContainer)
        case .some(.failure(let error)):
            startupFailureRecoveryView(error: error)
                .onAppear {
                    applicationDelegate.configure(appState: appState, services: services)
                }
                #if DEBUG
                .forgePlayDebugDynamicType(appState.debugDynamicTypeSize)
                .task {
                    appState.applyDebugLaunchOptionsIfNeeded()
                }
                #endif
                .environment(appState)
                .environment(\.locale, appState.locale)
        case .none:
            ForgePlayLaunchSplashView()
                #if DEBUG
                .forgePlayDebugDynamicType(appState.debugDynamicTypeSize)
                #endif
                .environment(appState)
                .environment(\.locale, appState.locale)
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch modelContainerBootstrap.result {
        case .some(.success(let modelContainer)):
            SettingsSceneView()
                .onAppear {
                    applicationDelegate.configure(appState: appState, services: services)
                }
                #if DEBUG
                .forgePlayDebugDynamicType(appState.debugDynamicTypeSize)
                #endif
                .frame(minWidth: 680, idealWidth: 820, minHeight: 580)
                .environment(appState)
                .environment(services)
                .environment(\.locale, appState.locale)
                .modelContainer(modelContainer)
        case .some(.failure(let error)):
            startupFailureRecoveryView(
                title: "설정 저장소를 열 수 없어 설정 화면을 사용할 수 없습니다.",
                error: error
            )
            .onAppear {
                applicationDelegate.configure(appState: appState, services: services)
            }
            #if DEBUG
            .forgePlayDebugDynamicType(appState.debugDynamicTypeSize)
            .task {
                appState.applyDebugLaunchOptionsIfNeeded()
            }
            #endif
            .environment(appState)
            .environment(\.locale, appState.locale)
            .frame(minWidth: 520, minHeight: 420)
        case .none:
            ForgePlayStartupLoadingView()
                #if DEBUG
                .forgePlayDebugDynamicType(appState.debugDynamicTypeSize)
                #endif
                .environment(appState)
                .environment(\.locale, appState.locale)
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    @ViewBuilder
    private func startupFailureRecoveryView(
        title: String? = nil,
        error: Error
    ) -> some View {
        ForgePlayStartupFailureRecoveryLayout {
            if let title {
                StartupFailureView(title: title, error: error)
            } else {
                StartupFailureView(error: error)
            }

            VStack(spacing: 0) {
                Divider()
                    .accessibilityHidden(true)
                Button(appState.localized("다시 시도")) {
                    modelContainerBootstrap.retryAfterFailure()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: ForgePlayStartupFailureRecoveryLayout.minimumActionRegionHeight,
                alignment: .center
            )
            .background(.regularMaterial)
        }
    }

    private static func modelContainerFactory() -> ForgePlayModelContainerBootstrap.Factory {
        #if DEBUG
        if Self.debugLaunchBooleanValue(key: "FORGEPLAY_QA_STARTUP_FAILURE") == true {
            return { throw DebugStartupFailure() }
        }
        if Self.isRunningUnitTests {
            return {
                try await Self.makeModelContainerOffMain(isStoredInMemoryOnly: true)
            }
        }
        if Self.debugLaunchBooleanValue(key: "FORGEPLAY_QA_IN_MEMORY_STORE") == true ||
            Self.debugLaunchRequiresEphemeralStore() {
            return {
                try await Self.makeModelContainerOffMain(isStoredInMemoryOnly: true)
            }
        }
        #endif

        return { try await Self.makeModelContainerOffMain() }
    }

    nonisolated static let applicationSupportDirectoryName = PathManager.applicationSupportDirectoryName
    nonisolated static let persistentStoreFileName = "ForgePlay.store"
    nonisolated static let legacyDefaultStoreFileName = "default.store"

    #if DEBUG
    nonisolated static let ephemeralDebugLaunchKeys: Set<String> = [
        "FORGEPLAY_QA_LANGUAGE",
        "FORGEPLAY_QA_RESET_LANGUAGE_TO_SYSTEM_AFTER_LAUNCH",
        "FORGEPLAY_QA_DISMISS_SHEET_AFTER_LAUNCH",
        "FORGEPLAY_QA_DYNAMIC_TYPE",
        "FORGEPLAY_QA_THEME",
        "FORGEPLAY_QA_SECTION",
        "FORGEPLAY_QA_DIAGNOSTICS_PREVIEW",
        "FORGEPLAY_QA_STEAM_LAUNCH_FIXTURE",
        "FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE",
        "FORGEPLAY_QA_SHEET"
    ]

    nonisolated static func debugLaunchRequiresEphemeralStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        ephemeralDebugLaunchKeys.contains { key in
            if let value = environment[key], !value.isEmpty { return true }
            let prefix = "--\(key)="
            return arguments.contains { $0.hasPrefix(prefix) }
        }
    }
    #endif

    nonisolated static func makeModelContainer(
        isStoredInMemoryOnly: Bool = false,
        applicationSupportDirectory: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            AppSettingsRecord.self,
            StandardSteamLaunchConfigurationRecord.self,
            CompatibilitySteamLaunchPreferenceRecord.self,
            PrefixRecord.self,
            RuntimeRecord.self,
            SteamGameRecord.self,
            SteamStorageMountRecord.self,
            LaunchRecord.self,
            DiagnosticRecord.self,
            CompatibilityRecipeRecord.self,
            AutoFixRecord.self
        ])
        if isStoredInMemoryOnly {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        let preparedStore = try preparePersistentStore(
            applicationSupportDirectory: applicationSupportDirectory
        )
        defer { preparedStore.migrationLease?.release() }
        let configuration = ModelConfiguration("ForgePlay", schema: schema, url: preparedStore.url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private nonisolated static func makeModelContainerOffMain(
        isStoredInMemoryOnly: Bool = false,
        applicationSupportDirectory: URL? = nil
    ) async throws -> ModelContainer {
        let workerTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.makeModelContainer(
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                applicationSupportDirectory: applicationSupportDirectory
            )
        }
        return try await withTaskCancellationHandler {
            try await workerTask.value
        } onCancel: {
            workerTask.cancel()
        }
    }

    nonisolated static func applicationSupportDirectory(
        baseDirectory: URL? = nil,
        creatingIfNeeded: Bool = true,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = discovered
        } else {
            throw ForgePlayStoreConfigurationError.applicationSupportUnavailable
        }

        let directory = base.appending(path: applicationSupportDirectoryName, directoryHint: .isDirectory)
        if try nonFollowingStatus(at: directory) != nil {
            try requireStoreDirectory(directory, fileManager: fileManager, unsafeError: ForgePlayStoreConfigurationError.unsafeStoreDirectory)
        } else if creatingIfNeeded {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ForgePlayStoreConfigurationError.createStoreDirectoryFailed(directory, error)
            }
        }
        return directory
    }

    nonisolated static func preparePersistentStoreURL(
        applicationSupportDirectory baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let preparedStore = try preparePersistentStore(
            applicationSupportDirectory: baseDirectory,
            fileManager: fileManager
        )
        defer { preparedStore.migrationLease?.release() }
        return preparedStore.url
    }

    private nonisolated static func preparePersistentStore(
        applicationSupportDirectory baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ForgePlayPreparedPersistentStore {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = discovered
        } else {
            throw ForgePlayStoreConfigurationError.applicationSupportUnavailable
        }

        if try nonFollowingStatus(at: base) != nil {
            try requireStoreDirectory(
                base,
                fileManager: fileManager,
                unsafeError: ForgePlayStoreConfigurationError.unsafeApplicationSupportDirectory
            )
        } else {
            do {
                try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            } catch {
                throw ForgePlayStoreConfigurationError.createApplicationSupportDirectoryFailed(base, error)
            }
        }

        let directory = try applicationSupportDirectory(
            baseDirectory: base,
            creatingIfNeeded: true,
            fileManager: fileManager
        )
        let storeURL = directory.appending(path: persistentStoreFileName, directoryHint: .notDirectory)
        let migrationLockURL = directory.appending(
            path: ".\(persistentStoreFileName)-migration.lock",
            directoryHint: .notDirectory
        )
        let migrationLease: ForgePlayStoreMigrationLease
        do {
            migrationLease = try ForgePlayStoreMigrationLease.acquire(at: migrationLockURL)
        } catch {
            throw ForgePlayStoreConfigurationError.metadataReadFailed(
                migrationLockURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        do {
            if try validateStoreAndSidecarsIfPresent(at: storeURL) {
                migrationLease.release()
                return ForgePlayPreparedPersistentStore(url: storeURL, migrationLease: nil)
            }

            let legacyStoreURL = base.appending(path: legacyDefaultStoreFileName, directoryHint: .notDirectory)
            if try nonFollowingStatus(at: legacyStoreURL) != nil {
                try migrateLegacyDefaultStoreIfNeeded(
                    from: legacyStoreURL,
                    to: storeURL,
                    fileManager: fileManager
                )
            }
            _ = try validateStoreAndSidecarsIfPresent(at: storeURL)
            return ForgePlayPreparedPersistentStore(
                url: storeURL,
                migrationLease: migrationLease
            )
        } catch {
            migrationLease.release()
            throw error
        }
    }

    private nonisolated static func migrateLegacyDefaultStoreIfNeeded(
        from legacyStoreURL: URL,
        to storeURL: URL,
        fileManager: FileManager
    ) throws {
        try requireStoreFile(legacyStoreURL, fileManager: fileManager, unsafeError: ForgePlayStoreConfigurationError.unsafeLegacyStoreFile)
        guard try legacyStoreLooksLikeForgePlayStore(legacyStoreURL) else {
            return
        }

        let temporaryBaseURL = storeURL.deletingLastPathComponent()
            .appending(path: "\(persistentStoreFileName).migration-\(UUID().uuidString)", directoryHint: .notDirectory)
        var temporaryURLs: [URL] = []
        var migrationComponents: [(temporary: URL, final: URL, suffix: String)] = []
        var installedFinalURLs: [URL] = []

        do {
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: legacyStoreURL.path + suffix)
                guard try nonFollowingStatus(at: source) != nil else { continue }
                try requireStoreFile(source, fileManager: fileManager, unsafeError: ForgePlayStoreConfigurationError.unsafeLegacyStoreFile)
                let temporary = URL(fileURLWithPath: temporaryBaseURL.path + suffix)
                let final = URL(fileURLWithPath: storeURL.path + suffix)
                try fileManager.copyItem(at: source, to: temporary)
                temporaryURLs.append(temporary)
                migrationComponents.append((temporary, final, suffix))
            }

            if try validateStoreAndSidecarsIfPresent(at: storeURL) {
                for temporary in temporaryURLs {
                    try removeMigrationArtifactIfPresent(temporary, fileManager: fileManager)
                }
                return
            }

            let publicationOrder = migrationComponents.sorted { lhs, rhs in
                if lhs.suffix.isEmpty != rhs.suffix.isEmpty {
                    return !lhs.suffix.isEmpty
                }
                return lhs.suffix < rhs.suffix
            }
            for component in publicationOrder {
                try fileManager.moveItem(at: component.temporary, to: component.final)
                installedFinalURLs.append(component.final)
            }
        } catch {
            for url in temporaryURLs + Array(installedFinalURLs.reversed()) {
                do {
                    try removeMigrationArtifactIfPresent(url, fileManager: fileManager)
                } catch let cleanupError {
                    throw ForgePlayStoreConfigurationError.legacyStoreMigrationCleanupFailed(
                        legacyStoreURL,
                        storeURL,
                        url,
                        error,
                        cleanupError
                    )
                }
            }
            throw ForgePlayStoreConfigurationError.legacyStoreMigrationFailed(legacyStoreURL, storeURL, error)
        }
    }

    private nonisolated static func requireStoreDirectory(
        _ url: URL,
        fileManager: FileManager,
        unsafeError: (URL) -> ForgePlayStoreConfigurationError
    ) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            throw unsafeError(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw ForgePlayStoreConfigurationError.metadataReadFailed(url, message)
        } catch {
            throw ForgePlayStoreConfigurationError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private nonisolated static func requireStoreFile(
        _ url: URL,
        fileManager: FileManager,
        unsafeError: (URL) -> ForgePlayStoreConfigurationError
    ) throws {
        _ = fileManager
        guard let status = try nonFollowingStatus(at: url) else {
            throw unsafeError(url)
        }
        try requireSecureRegularFile(
            at: url,
            nonFollowingStatus: status,
            unsafeError: unsafeError
        )
    }

    private nonisolated static func validateStoreAndSidecarsIfPresent(
        at storeURL: URL
    ) throws -> Bool {
        let storeStatus = try nonFollowingStatus(at: storeURL)
        if let storeStatus {
            try requireSecureRegularFile(
                at: storeURL,
                nonFollowingStatus: storeStatus,
                unsafeError: ForgePlayStoreConfigurationError.unsafeStoreFile
            )
        }

        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: storeURL.path + suffix)
            guard let sidecarStatus = try nonFollowingStatus(at: sidecarURL) else { continue }
            try requireSecureRegularFile(
                at: sidecarURL,
                nonFollowingStatus: sidecarStatus,
                unsafeError: ForgePlayStoreConfigurationError.unsafeStoreFile
            )
        }
        return storeStatus != nil
    }

    private nonisolated static func requireSecureRegularFile(
        at url: URL,
        nonFollowingStatus: stat,
        unsafeError: (URL) -> ForgePlayStoreConfigurationError
    ) throws {
        guard (nonFollowingStatus.st_mode & S_IFMT) == S_IFREG,
              nonFollowingStatus.st_nlink == 1 else {
            throw unsafeError(url)
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw ForgePlayStoreConfigurationError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(failure)
            )
        }
        defer { Darwin.close(descriptor) }

        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw ForgePlayStoreConfigurationError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(failure)
            )
        }
        guard (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_dev == nonFollowingStatus.st_dev,
              descriptorStatus.st_ino == nonFollowingStatus.st_ino else {
            throw unsafeError(url)
        }
    }

    private nonisolated static func nonFollowingStatus(at url: URL) throws -> stat? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            let failureCode = errno
            if failureCode == ENOENT {
                return nil
            }
            let failure = POSIXError(POSIXErrorCode(rawValue: failureCode) ?? .EIO)
            throw ForgePlayStoreConfigurationError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(failure)
            )
        }
        return status
    }

    private nonisolated static func removeMigrationArtifactIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        guard try nonFollowingStatus(at: url) != nil else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private nonisolated static func legacyStoreLooksLikeForgePlayStore(_ url: URL) throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ForgePlayStoreConfigurationError.legacyStoreMarkerReadFailed(url, error)
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        } catch {
            throw ForgePlayStoreConfigurationError.legacyStoreMarkerReadFailed(url, error)
        }
        let markers = [
            "ZAPPSETTINGSRECORD",
            "AppSettingsRecord",
            "com.ForgePlay.app",
            "com.forgeplay.app"
        ]
        return markers.contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    #if DEBUG
    private static func debugLaunchBooleanValue(key: String) -> Bool? {
        guard let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    fileprivate static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }
    #endif
}

struct ForgePlayLaunchSplashView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            Image(ForgePlayLaunchSplashPolicy.assetName)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("ForgePlay"))
        .accessibilityValue(Text(appState.localized("실행 준비 중…")))
    }
}

struct ForgePlayStartupLoadingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(
            mode: appState.themeMode,
            colorScheme: colorScheme
        )

        ZStack {
            palette.background.ignoresSafeArea()

            VStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("ForgePlay")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(palette.text)
                    Text(appState.localized("Windows 게임을 Mac에서 더 쉽게."))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                }

                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.primary)
                        .accessibilityHidden(true)
                    Text(appState.localized("실행 준비 중…"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.top, 4)
            }
            .padding(36)
            .frame(maxWidth: 460)
            .background(palette.surface)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ForgePlayLayout.panelCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ForgePlayLayout.panelCornerRadius,
                    style: .continuous
                )
                .stroke(palette.border, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("ForgePlay"))
        .accessibilityValue(Text(appState.localized("실행 준비 중…")))
    }
}

private struct SettingsSceneView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @State private var presentedSheet: SheetDestination?

    var body: some View {
        VStack(spacing: 0) {
            if let notice = appState.currentNotice {
                TaskBanner(notice: notice)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            SettingsView(
                sheetPresenter: { destination in
                    presentedSheet = destination
                },
                opensMainWindowForNavigation: true
            )
        }
        .sheet(item: $presentedSheet) { destination in
            SheetHostView(
                destination: destination,
                sheetPresenter: { nextDestination in
                    presentedSheet = nextDestination
                },
                opensMainWindowForNavigation: true
            )
                .environment(appState)
                .environment(services)
                .environment(\.locale, appState.locale)
        }
    }
}

#if DEBUG
private struct DebugStartupFailure: LocalizedError, Sendable {
    var errorDescription: String? {
        "Debug startup failure fixture: SwiftData container creation did not complete."
    }
}
#endif

private final class AppTerminationShutdownResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppTerminationSteamShutdownSummary?

    func store(_ summary: AppTerminationSteamShutdownSummary) {
        lock.lock()
        value = summary
        lock.unlock()
    }

    func load() -> AppTerminationSteamShutdownSummary? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class ForgePlayApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let automaticTerminationReason = "ForgePlay manages Windows Steam processes"

    private var appState: AppState?
    private var services: AppServices?
    private var isTerminationCleanupRunning = false
    private var didCompleteTerminationCleanup = false
    private var isSystemTerminationDisabled = false
    private var terminationRequestTask: Task<Void, Never>?
    #if DEBUG
    private var debugTerminationTask: Task<Void, Never>?
    private var debugTerminationEvents: [String] = []
    #endif

    func configure(appState: AppState, services: AppServices) {
        self.appState = appState
        self.services = services
        appState.configureFailureDiagnostics(
            service: services.failureDiagnosticEvidenceService,
            pathManager: services.pathManager
        )
        services.connectGameInputProtectionLifecycle(to: appState)
        #if DEBUG
        guard !ForgePlayApp.isRunningUnitTests else { return }
        #endif
        disableSystemTerminationIfNeeded()
        #if DEBUG
        let installedDelegate = NSApplication.shared.delegate
        recordDebugTerminationEvent(
            "configured root=\(services.pathManager.rootURL?.path ?? "nil") " +
                "selectedRoot=\(appState.selectedRootURL?.path ?? "nil") " +
                "runner=\(appState.runtimeExecutableURL?.path ?? "nil") " +
                "installedDelegate=\(String(describing: installedDelegate.map { type(of: $0) })) " +
                "isApplicationDelegate=\((installedDelegate as AnyObject?) === self) " +
                "respondsToShouldTerminate=\(installedDelegate?.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))) == true)"
        )
        scheduleDebugTerminationIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func requestApplicationTermination() {
        guard terminationRequestTask == nil, !isTerminationCleanupRunning else { return }

        appState?.presentedSheet = nil
        let application = NSApplication.shared
        dismissPresentedSheets(in: application)
        let services = services ?? AppServices()
        let runtimeExecutable = appState?.runtimeExecutableURL
        let selectedRootURL = appState?.selectedRootURL
        isTerminationCleanupRunning = true

        terminationRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let summary = await services.shutdownSteamProcessesForAppTermination(
                runtimeExecutable: runtimeExecutable,
                selectedRootURL: selectedRootURL,
                includeDefaultApplicationSupportRoot: true
            )
            let allowsTermination = self.handleTerminationCleanupCompletion(
                summary,
                services: services
            )
            self.didCompleteTerminationCleanup = allowsTermination
            self.isTerminationCleanupRunning = false
            self.terminationRequestTask = nil
            guard allowsTermination else {
                return
            }

            self.enableSystemTerminationIfNeeded()
            self.finishExplicitApplicationTermination()
        }
    }

    private func dismissPresentedSheets(in application: NSApplication) {
        if application.modalWindow != nil {
            application.abortModal()
        }

        for window in application.windows {
            let sheets = window.sheets
            for sheet in sheets {
                window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
            }
        }
    }

    private func finishExplicitApplicationTermination() {
        let application = NSApplication.shared
        dismissPresentedSheets(in: application)

        // AppKit can remain in its pre-delegate termination loop while a
        // system-owned permission panel is associated with this process. Wine
        // cleanup has already satisfied the termination postcondition here,
        // so do not leave the app and its UI resident indefinitely.
        let processIdentifier = getpid()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
            guard Darwin.kill(processIdentifier, 0) == 0 else { return }
            Darwin._exit(EXIT_SUCCESS)
        }
        DispatchQueue.main.async {
            application.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        recordDebugTerminationEvent(
            "applicationShouldTerminate complete=\(didCompleteTerminationCleanup) " +
                "running=\(isTerminationCleanupRunning) services=\(services != nil)"
        )
        #endif
        guard !didCompleteTerminationCleanup else {
            enableSystemTerminationIfNeeded()
            return .terminateNow
        }
        guard !isTerminationCleanupRunning else {
            return .terminateLater
        }
        let services = services ?? AppServices()
        #if DEBUG
        if self.services == nil {
            recordDebugTerminationEvent("using emergency default-root cleanup services")
        }
        #endif

        isTerminationCleanupRunning = true
        let runtimeExecutable = appState?.runtimeExecutableURL
        let selectedRootURL = appState?.selectedRootURL
        #if DEBUG
        recordDebugTerminationEvent(
            "cleanup started root=\(services.pathManager.rootURL?.path ?? "nil") " +
                "selectedRoot=\(selectedRootURL?.path ?? "nil") " +
                "runner=\(runtimeExecutable?.path ?? "nil")"
        )
        #endif
        Task { @MainActor in
            let summary = await services.shutdownSteamProcessesForAppTermination(
                runtimeExecutable: runtimeExecutable,
                selectedRootURL: selectedRootURL,
                includeDefaultApplicationSupportRoot: true
            )
            let allowsTermination = self.handleTerminationCleanupCompletion(
                summary,
                services: services
            )
            self.didCompleteTerminationCleanup = allowsTermination
            self.isTerminationCleanupRunning = false
            if allowsTermination {
                self.enableSystemTerminationIfNeeded()
            }
            sender.reply(toApplicationShouldTerminate: allowsTermination)
        }
        return .terminateLater
    }

    private func handleTerminationCleanupCompletion(
        _ summary: AppTerminationSteamShutdownSummary,
        services: AppServices
    ) -> Bool {
        let allowsTermination = Self.shouldAllowTermination(after: summary)
        if !allowsTermination {
            NSLog(
                "ForgePlay termination Steam cleanup did not finish cleanly: %@",
                summary.diagnosticDescription
            )
            services.cancelApplicationTermination()
            let message: String
            if let prefix = summary.prefix ?? summary.prefixes.first {
                message = appState?.localizedError(
                    SafeProcessRunnerError.prefixProcessVerificationFailed(
                        prefix,
                        summary.diagnosticDescription
                    )
                ) ?? summary.diagnosticDescription
            } else {
                message = appState?.localizedFormat(
                    "ForgePlay 종료 정리를 시작하지 못했습니다: %@",
                    summary.diagnosticDescription
                ) ?? summary.diagnosticDescription
            }
            appState?.setNotice(
                message,
                kind: .failure,
                logURL: summary.results.last?.stderrLog,
                diagnosticProcessResult: summary.results.last
            )
        }
        #if DEBUG
        recordDebugTerminationEvent("cleanup completed: \(summary.diagnosticDescription)")
        #endif
        return allowsTermination
    }

    nonisolated static func shouldAllowTermination(
        after summary: AppTerminationSteamShutdownSummary
    ) -> Bool {
        summary.succeeded
    }

    func applicationWillTerminate(_ notification: Notification) {
        performSynchronousTerminationCleanupIfNeeded()
    }

    private func performSynchronousTerminationCleanupIfNeeded() {
        #if DEBUG
        recordDebugTerminationEvent("willTerminate notification received")
        #endif
        guard !didCompleteTerminationCleanup else {
            #if DEBUG
            recordDebugTerminationEvent("willTerminate cleanup already completed")
            #endif
            return
        }
        guard !isTerminationCleanupRunning, let services else {
            #if DEBUG
            recordDebugTerminationEvent(
                isTerminationCleanupRunning
                    ? "willTerminate cleanup already running"
                    : "willTerminate cleanup skipped: services unavailable"
            )
            #endif
            return
        }

        isTerminationCleanupRunning = true
        let plan = services.emergencyAppTerminationSteamShutdownPlan(
            selectedRootURL: appState?.selectedRootURL,
            includeDefaultApplicationSupportRoot: true
        )
        let safeProcessRunner = services.safeProcessRunner
        let windowsExecutablePrefixExecutionLifetimeOwner =
            services.windowsExecutablePrefixExecutionLifetimeOwner
        let resultStore = AppTerminationShutdownResultStore()
        let completion = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let summary = await AppServices.executeAppTerminationSteamShutdown(
                plan,
                safeProcessRunner: safeProcessRunner,
                completeRetainedWindowsExecutableLeases: { prefix in
                    try await windowsExecutablePrefixExecutionLifetimeOwner
                        .completeAfterConfirmedPrefixShutdown(
                            prefix: prefix,
                            inactivityWaiter: { prefix, timeout, pollInterval in
                                try await safeProcessRunner
                                    .waitForManagedPrefixProcessesToExit(
                                        prefix,
                                        timeout: timeout,
                                        pollInterval: pollInterval
                                    )
                            }
                        )
                },
                requiresExclusiveOwnerVerification: false
            )
            resultStore.store(summary)
            completion.signal()
        }

        let actionCount = max(plan.prefixes.count, 1)
        let timeoutSeconds = min(max(actionCount * 20, 30), 90)
        let waitResult = completion.wait(timeout: .now() + .seconds(timeoutSeconds))
        let summary = resultStore.load()
        if waitResult == .timedOut || summary == nil {
            NSLog(
                "ForgePlay termination Steam cleanup timed out after %d seconds for prefixes: %@",
                timeoutSeconds,
                plan.prefixes.map(\.path).joined(separator: ", ")
            )
            #if DEBUG
            recordDebugTerminationEvent("willTerminate cleanup timed out after \(timeoutSeconds) seconds")
            #endif
        } else if let summary {
            if !summary.succeeded {
                NSLog("ForgePlay termination Steam cleanup did not finish cleanly: %@", summary.diagnosticDescription)
            }
            #if DEBUG
            recordDebugTerminationEvent("willTerminate cleanup completed: \(summary.diagnosticDescription)")
            #endif
        }
        didCompleteTerminationCleanup = waitResult != .timedOut && summary?.succeeded == true
        isTerminationCleanupRunning = false
        enableSystemTerminationIfNeeded()
    }

    private func disableSystemTerminationIfNeeded() {
        guard !isSystemTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
        ProcessInfo.processInfo.disableSuddenTermination()
        isSystemTerminationDisabled = true
    }

    private func enableSystemTerminationIfNeeded() {
        guard isSystemTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
        ProcessInfo.processInfo.enableSuddenTermination()
        isSystemTerminationDisabled = false
    }

    #if DEBUG
    private func scheduleDebugTerminationIfRequested() {
        guard debugTerminationTask == nil,
              let rawDelay = ProcessInfo.processInfo.environment["FORGEPLAY_QA_AUTO_TERMINATE_AFTER_SECONDS"],
              let delay = Double(rawDelay),
              delay > 0,
              delay <= 300 else {
            return
        }
        recordDebugTerminationEvent("auto termination scheduled after \(delay) seconds")
        debugTerminationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let installedDelegate = NSApplication.shared.delegate
            recordDebugTerminationEvent(
                "auto termination requested installedDelegate=\(String(describing: installedDelegate.map { type(of: $0) })) " +
                    "isApplicationDelegate=\((installedDelegate as AnyObject?) === self) " +
                    "respondsToShouldTerminate=\(installedDelegate?.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))) == true)"
            )
            requestApplicationTermination()
        }
    }

    private func recordDebugTerminationEvent(_ event: String) {
        guard let rawPath = ProcessInfo.processInfo.environment["FORGEPLAY_QA_TERMINATION_RESULT_PATH"],
              !rawPath.isEmpty else {
            return
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        debugTerminationEvents.append("\(timestamp) \(event)")
        let outputURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((debugTerminationEvents.joined(separator: "\n") + "\n").utf8)
                .write(to: outputURL, options: .atomic)
        } catch {
            NSLog("ForgePlay could not write QA termination evidence: %@", error.localizedDescription)
        }
    }
    #endif
}

#if DEBUG
private extension View {
    @ViewBuilder
    func forgePlayDebugDynamicType(_ size: DynamicTypeSize?) -> some View {
        if let size {
            dynamicTypeSize(size)
        } else {
            self
        }
    }
}
#endif
