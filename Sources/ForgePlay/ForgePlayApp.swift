import AppKit
import Darwin
import SwiftData
import SwiftUI

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

@main
struct ForgePlayApp: App {
    @NSApplicationDelegateAdaptor(ForgePlayApplicationDelegate.self) private var applicationDelegate
    @State private var appState = AppState()
    @State private var services = AppServices()
    @State private var isShowingLaunchSplash = true

    private let modelContainerResult: Result<ModelContainer, Error>

    init() {
        #if DEBUG
        if Self.debugLaunchBooleanValue(key: "FORGEPLAY_QA_STARTUP_FAILURE") == true {
            modelContainerResult = .failure(DebugStartupFailure())
            return
        }
        if Self.isRunningUnitTests {
            modelContainerResult = Result {
                try Self.makeModelContainer(isStoredInMemoryOnly: true)
            }
            return
        }
        if Self.debugLaunchBooleanValue(key: "FORGEPLAY_QA_IN_MEMORY_STORE") == true ||
            Self.debugLaunchRequiresEphemeralStore() {
            modelContainerResult = Result {
                try Self.makeModelContainer(isStoredInMemoryOnly: true)
            }
            return
        }
        #endif

        modelContainerResult = Result {
            try Self.makeModelContainer()
        }
    }

    var body: some Scene {
        WindowGroup(id: ForgePlaySceneID.main) {
            windowContent
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
        }
    }

    @ViewBuilder
    private var windowContent: some View {
        if isShowingLaunchSplash {
            ForgePlayLaunchSplashView()
                .task {
                    try? await Task.sleep(for: .seconds(1))
                    isShowingLaunchSplash = false
                }
        } else {
            switch modelContainerResult {
            case .success(let modelContainer):
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
            case .failure(let error):
                StartupFailureView(error: error)
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
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch modelContainerResult {
        case .success(let modelContainer):
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
        case .failure(let error):
            StartupFailureView(
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
        }
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

    static func makeModelContainer(
        isStoredInMemoryOnly: Bool = false,
        applicationSupportDirectory: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            AppSettingsRecord.self,
            PrefixRecord.self,
            RuntimeRecord.self,
            SteamGameRecord.self,
            SteamStorageMountRecord.self,
            LaunchRecord.self,
            DiagnosticRecord.self,
            CompatibilityRecipeRecord.self,
            AutoFixRecord.self
        ])
        let configuration: ModelConfiguration
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let storeURL = try preparePersistentStoreURL(applicationSupportDirectory: applicationSupportDirectory)
            configuration = ModelConfiguration("ForgePlay", schema: schema, url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
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
        if fileManager.fileExists(atPath: directory.path) {
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
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = discovered
        } else {
            throw ForgePlayStoreConfigurationError.applicationSupportUnavailable
        }

        if fileManager.fileExists(atPath: base.path) {
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
        if fileManager.fileExists(atPath: storeURL.path) {
            try requireStoreFile(storeURL, fileManager: fileManager, unsafeError: ForgePlayStoreConfigurationError.unsafeStoreFile)
            return storeURL
        }

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
        defer { migrationLease.release() }

        if fileManager.fileExists(atPath: storeURL.path) {
            try requireStoreFile(storeURL, fileManager: fileManager, unsafeError: ForgePlayStoreConfigurationError.unsafeStoreFile)
            return storeURL
        }

        let legacyStoreURL = base.appending(path: legacyDefaultStoreFileName, directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: legacyStoreURL.path) {
            try migrateLegacyDefaultStoreIfNeeded(from: legacyStoreURL, to: storeURL, fileManager: fileManager)
        }
        return storeURL
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
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try requireStoreFile(source, fileManager: fileManager, unsafeError: ForgePlayStoreConfigurationError.unsafeLegacyStoreFile)
                let temporary = URL(fileURLWithPath: temporaryBaseURL.path + suffix)
                let final = URL(fileURLWithPath: storeURL.path + suffix)
                try fileManager.copyItem(at: source, to: temporary)
                temporaryURLs.append(temporary)
                migrationComponents.append((temporary, final, suffix))
            }

            if fileManager.fileExists(atPath: storeURL.path) {
                try requireStoreFile(
                    storeURL,
                    fileManager: fileManager,
                    unsafeError: ForgePlayStoreConfigurationError.unsafeStoreFile
                )
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
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notRegularNonSymlinkFile {
            throw unsafeError(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw ForgePlayStoreConfigurationError.metadataReadFailed(url, message)
        } catch {
            throw ForgePlayStoreConfigurationError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private nonisolated static func removeMigrationArtifactIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
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

private struct ForgePlayLaunchSplashView: View {
    var body: some View {
        GeometryReader { geometry in
            Image("LaunchSplash")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityHidden(true)
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
private struct DebugStartupFailure: LocalizedError {
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
            services.steamPrefixLifecycleCoordinator.cancelApplicationTermination()
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
        let plan = services.appTerminationSteamShutdownPlan(
            runtimeExecutable: appState?.runtimeExecutableURL,
            selectedRootURL: appState?.selectedRootURL,
            includeDefaultApplicationSupportRoot: true
        )
        let safeProcessRunner = services.safeProcessRunner
        let resultStore = AppTerminationShutdownResultStore()
        let completion = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let summary = await AppServices.executeAppTerminationSteamShutdown(
                plan,
                safeProcessRunner: safeProcessRunner
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
