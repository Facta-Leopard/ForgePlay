import Darwin
import Foundation

/// Valve's Steam language identifiers are not BCP-47 language tags. They are
/// the stable tokens consumed by the Steam client and exposed by Steamworks.
enum SteamClientLanguage: String, CaseIterable, Codable, Hashable, Sendable {
    case english
    case koreana
    case spanish
    case german
    case japanese
    case schinese
    case tchinese
    case french

    /// Locale spelling used by Steam WebHelper after the client has consumed
    /// the Steam language token. This is diagnostic/readback metadata only;
    /// ForgePlay does not launch WebHelper directly.
    var webHelperLocaleIdentifier: String {
        switch self {
        case .english: "en_US"
        case .koreana: "ko_KR"
        case .spanish: "es_ES"
        case .german: "de_DE"
        case .japanese: "ja_JP"
        case .schinese: "zh_CN"
        case .tchinese: "zh_TW"
        case .french: "fr_FR"
        }
    }
}

struct SteamClientLanguageOwnershipLease: Hashable, Sendable {
    fileprivate var claimID: UUID
    fileprivate(set) var language: SteamClientLanguage
}

/// The shared CEF JavaScript context is an internal Steam bootstrap boundary.
/// It is intentionally distinct from a usable login or desktop surface: a
/// zero-sized shared context can emit `BrowserReady` while every renderer is
/// failing and no Steam window is available to the user.
enum SteamWebHelperSharedContextReadiness: Hashable, Sendable {
    case pending
    case ready
}

/// Same-session evidence that Steam created and unhid a non-zero login or
/// desktop surface. This is the first boundary at which Steam's own settings UI
/// can safely become authoritative for user-controlled state.
enum SteamClientUsableUIReadiness: Hashable, Sendable {
    case pending
    case loginWindow
    case desktopWindow

    var isReady: Bool {
        self != .pending
    }
}

/// Same-launch command-line readback from Valve's WebHelper children. Registry
/// projection alone is not enough to prove that Steam consumed the requested
/// language: Steam can retain a matching registry value while an already
/// bootstrapped WebHelper session still runs with a different `-lang` locale.
struct SteamWebHelperLanguageReadback: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case pending
        case evidenceUnavailable
        case matched
        case mismatched
    }

    let state: State
    let observedLocaleIdentifiers: [String]

    func confirms(_ language: SteamClientLanguage) -> Bool {
        guard state == .matched,
              !observedLocaleIdentifiers.isEmpty,
              let expected = SteamWebHelperLaunchPolicy
                .normalizedLanguageLocaleIdentifier(
                    language.webHelperLocaleIdentifier
                ) else {
            return false
        }
        return observedLocaleIdentifiers.allSatisfy {
            SteamWebHelperLaunchPolicy
                .normalizedLanguageLocaleIdentifier($0) == expected
        }
    }
}

/// A fresh, same-session usable Steam surface proving that Steam has reached a
/// point where its own settings UI can become the language authority. A
/// running Steam/WebHelper process, message loop, shared JavaScript context, or
/// `BrowserReady` event is deliberately not evidence: all can occur before a
/// usable Steam UI exists. The surface must also belong to a WebHelper session
/// that read back the expected ICU locale from its own `-lang` argument.
struct SteamClientLanguageUserControlReadiness: Hashable, Sendable {
    let language: SteamClientLanguage
    let steamUI: SteamClientUsableUIReadiness
    let webHelperLanguageReadback: SteamWebHelperLanguageReadback

    init?(
        observation: SteamWebHelperStartupObservation,
        language: SteamClientLanguage,
        webHelperLanguageReadback: SteamWebHelperLanguageReadback
    ) {
        guard observation.usableUIReadiness.isReady,
              webHelperLanguageReadback.confirms(language) else {
            return nil
        }
        self.language = language
        self.steamUI = observation.usableUIReadiness
        self.webHelperLanguageReadback = webHelperLanguageReadback
    }
}

enum SteamClientLanguageOwnershipError:
    LocalizedError,
    ForgePlayTechnicalDescribingError
{
    case unsafeState(URL, String)
    case malformedMarker(URL)
    case registryReadbackFailed(
        expected: SteamClientLanguage,
        observedToken: String?
    )

    var errorDescription: String? { forgePlayTechnicalDescription }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .unsafeState(let url, let detail):
            "Steam language ownership state is unsafe at \(url.path): \(detail)"
        case .malformedMarker(let url):
            "Steam language ownership marker is malformed: \(url.path)"
        case .registryReadbackFailed(let expected, let observedToken):
            "Steam language registry readback did not match \(expected.rawValue); observed \(observedToken ?? "no value")"
        }
    }
}

/// Projects ForgePlay's language into a newly installed Steam client while
/// preserving Steam's own settings UI as the final owner. A marker is created
/// only for a prefix with no Steam executable. On later launches, a registry
/// value different from the last ForgePlay-applied token is treated as a user
/// change: the marker is removed and ForgePlay performs no registry write.
@MainActor
final class SteamClientLanguageOwnershipPolicy {
    typealias RegistryLanguageWriter = (
        _ runtimeExecutable: URL,
        _ prefix: URL,
        _ logDirectory: URL,
        _ language: SteamClientLanguage
    ) async throws -> Void

    private enum MarkerState: String, Codable {
        case pending
        case owned
    }

    private struct Marker: Codable, Equatable {
        var schemaVersion: Int
        var claimID: UUID
        var state: MarkerState
        var steamLanguage: SteamClientLanguage
        var webHelperLocaleIdentifier: String
        /// `false` while the selected installer/updater still owns startup.
        /// Once ForgePlay leaves a usable Steam session running, a subsequent
        /// registry mismatch is Steam/user-owned and must never be rewritten.
        var userControlBoundaryReached: Bool?

        var hasReachedUserControlBoundary: Bool {
            // Markers written before this field was introduced used `.owned`
            // only after their projection completed. Preserve their safer
            // no-overwrite behavior instead of silently reclaiming them.
            userControlBoundaryReached ?? (state == .owned)
        }
    }

    private enum StableFileRead {
        case missing
        case data(Data)
    }

    static let registryPath = "HKCU\\Software\\Valve\\Steam"
    static let registryValueName = "Language"
    static let markerFileName = ".forgeplay-steam-language-ownership-v1.json"

    private let fileManager: FileManager
    private let registryLanguageWriter: RegistryLanguageWriter

    init(
        runner: SafeProcessRunner,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.registryLanguageWriter = {
            runtimeExecutable,
            prefix,
            logDirectory,
            language in
            let writeResult = try await runner.run(.setRegistryValue(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                registryPath: Self.registryPath,
                valueName: Self.registryValueName,
                valueType: "REG_SZ",
                value: language.rawValue,
                logDirectory: logDirectory
            ))
            guard writeResult.succeeded else {
                throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                    writeResult
                )
            }
            let flushResult = try await runner.run(.waitForWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
            guard flushResult.succeeded else {
                throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                    flushResult
                )
            }
        }
    }

    init(
        fileManager: FileManager = .default,
        registryLanguageWriter: @escaping RegistryLanguageWriter
    ) {
        self.fileManager = fileManager
        self.registryLanguageWriter = registryLanguageWriter
    }

    static func markerURL(in prefix: URL) -> URL {
        prefix.appending(path: markerFileName)
    }

    /// Starts or resumes the only path allowed to claim an unowned prefix.
    /// A partial installer attempt may already have created `steam.exe`, so
    /// executable presence alone cannot distinguish a retry from an existing
    /// Steam installation. Only this policy may make that decision: it starts
    /// a claim when both Steam and the marker are absent, or resumes an exact
    /// pending pre-UI marker. A marker owned after a usable Steam surface and
    /// an unmarked existing Steam installation are always zero-write.
    func claimFreshInstallation(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        language: SteamClientLanguage
    ) async throws -> SteamClientLanguageOwnershipLease? {
        if var existing = try loadMarker(in: prefix) {
            guard existing.state == .pending,
                  !existing.hasReachedUserControlBoundary else {
                return nil
            }
            existing.steamLanguage = language
            existing.webHelperLocaleIdentifier =
                language.webHelperLocaleIdentifier
            try storeMarker(existing, in: prefix)
            try await project(
                language,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            return SteamClientLanguageOwnershipLease(
                claimID: existing.claimID,
                language: language
            )
        }

        guard !Self.pathEntryExists(
            WindowsSteamInstallationLayout.executable(in: prefix)
        ), try observedRegistryLanguageToken(in: prefix) == nil else {
            return nil
        }
        let claimID = UUID()
        let pending = Marker(
            schemaVersion: 1,
            claimID: claimID,
            state: .pending,
            steamLanguage: language,
            webHelperLocaleIdentifier: language.webHelperLocaleIdentifier,
            userControlBoundaryReached: false
        )
        try storeMarker(pending, in: prefix)
        try await project(
            language,
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        return SteamClientLanguageOwnershipLease(
            claimID: claimID,
            language: language
        )
    }

    /// The installer and service preparation are allowed to rewrite registry
    /// state before the first UI. Resume uses the already-created claim rather
    /// than mistaking those bootstrap mutations for a Steam UI user choice.
    func resumeFreshInstallation(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        language: SteamClientLanguage
    ) async throws -> SteamClientLanguageOwnershipLease {
        guard var marker = try loadMarker(in: prefix) else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                Self.markerURL(in: prefix),
                "the fresh-install ownership claim is missing"
            )
        }
        guard marker.state == .pending,
              !marker.hasReachedUserControlBoundary else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                Self.markerURL(in: prefix),
                "the fresh-install ownership claim already crossed the Steam user-control boundary"
            )
        }
        marker.state = .pending
        marker.steamLanguage = language
        marker.webHelperLocaleIdentifier = language.webHelperLocaleIdentifier
        try storeMarker(marker, in: prefix)
        try await project(
            language,
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        // Keep the claim pending until the caller completes every service and
        // compatibility mutation and reaffirms the lease. If preparation
        // fails after rewriting user.reg, the next launch must resume this
        // fresh transaction instead of misclassifying that mutation as a
        // Steam UI user choice.
        return SteamClientLanguageOwnershipLease(
            claimID: marker.claimID,
            language: language
        )
    }

    /// Reads ownership before an ordinary launch. A mismatched registry token
    /// means Steam (or the user through Steam) has taken ownership, so the
    /// marker is relinquished without writing the registry.
    func prepareForLaunch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        desiredLanguage: SteamClientLanguage? = nil
    ) async throws -> SteamClientLanguageOwnershipLease? {
        guard var marker = try loadMarker(in: prefix) else { return nil }

        if marker.state == .owned,
           marker.hasReachedUserControlBoundary {
            let observedToken = try observedRegistryLanguageToken(in: prefix)
            guard Self.normalizedToken(observedToken) == marker.steamLanguage.rawValue else {
                try relinquishMarker(in: prefix)
                return nil
            }
        }

        let projectedLanguage = desiredLanguage ?? marker.steamLanguage
        if marker.state == .pending {
            marker.steamLanguage = projectedLanguage
            marker.webHelperLocaleIdentifier = projectedLanguage.webHelperLocaleIdentifier
            try storeMarker(marker, in: prefix)
            try await project(
                projectedLanguage,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            try storeMarker(marker, in: prefix)
        } else if projectedLanguage != marker.steamLanguage {
            // The usable Steam UI boundary has already been crossed. Keep the
            // persisted marker internally consistent while changing an exact
            // ForgePlay-owned value. A crash between projection and marker
            // update safely relinquishes on the next readback rather than
            // leaving an internally inconsistent persisted state.
            try await project(
                projectedLanguage,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            marker.steamLanguage = projectedLanguage
            marker.webHelperLocaleIdentifier =
                projectedLanguage.webHelperLocaleIdentifier
            try storeMarker(marker, in: prefix)
        }
        return SteamClientLanguageOwnershipLease(
            claimID: marker.claimID,
            language: marker.steamLanguage
        )
    }

    /// Reasserts a lease only inside the already-admitted launch transaction.
    /// This keeps service preparation, updater bootstrap, and WebHelper retry
    /// from dropping the initial language before the first Steam UI appears.
    func reaffirm(
        _ lease: SteamClientLanguageOwnershipLease,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> Bool {
        guard var marker = try loadMarker(in: prefix),
              marker.claimID == lease.claimID,
              marker.steamLanguage == lease.language else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                Self.markerURL(in: prefix),
                "the active language ownership lease no longer matches its marker"
            )
        }
        if try observedRegistryLanguageToken(in: prefix)
            .map(Self.normalizedToken) == lease.language.rawValue,
           marker.state == .owned {
            return false
        }
        if !marker.hasReachedUserControlBoundary {
            marker.state = .pending
            try storeMarker(marker, in: prefix)
        }
        try await project(
            lease.language,
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        if !marker.hasReachedUserControlBoundary {
            try storeMarker(marker, in: prefix)
        }
        return true
    }

    /// Transfers readback authority after a fresh usable login or desktop
    /// surface whose same-launch WebHelper locale matches the lease, without
    /// touching Valve's registry. A matching registry token becomes
    /// readback-owned. A
    /// stable, non-nil mismatch means Steam/user control already won the race,
    /// so ForgePlay relinquishes the marker immediately and performs no write.
    /// Missing or unsafe readback remains transient and is retried by the
    /// session monitor.
    @discardableResult
    func markSteamUserControlAvailable(
        _ lease: SteamClientLanguageOwnershipLease,
        readiness: SteamClientLanguageUserControlReadiness,
        in prefix: URL
    ) throws -> Bool {
        guard var marker = try loadMarker(in: prefix) else { return false }
        guard marker.claimID == lease.claimID,
              marker.steamLanguage == lease.language,
              readiness.language == lease.language,
              readiness.webHelperLanguageReadback.confirms(lease.language) else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                Self.markerURL(in: prefix),
                "the active language ownership lease, readiness evidence, and marker do not match"
            )
        }
        let observedToken = try observedRegistryLanguageToken(in: prefix)
        guard let normalizedObservedToken = Self.normalizedToken(observedToken) else {
            throw SteamClientLanguageOwnershipError.registryReadbackFailed(
                expected: lease.language,
                observedToken: observedToken
            )
        }
        guard normalizedObservedToken == lease.language.rawValue else {
            try relinquishMarker(in: prefix)
            return false
        }
        guard !marker.hasReachedUserControlBoundary || marker.state != .owned else {
            return false
        }
        marker.userControlBoundaryReached = true
        marker.state = .owned
        try storeMarker(marker, in: prefix)
        return true
    }

    static func launchArguments(
        baseArguments: [String],
        lease: SteamClientLanguageOwnershipLease?
    ) -> [String] {
        guard let lease else { return baseArguments }
        var arguments = baseArguments
        if let languageIndex = arguments.firstIndex(where: {
            $0.caseInsensitiveCompare("-language") == .orderedSame
        }) {
            let valueIndex = arguments.index(after: languageIndex)
            if valueIndex < arguments.endIndex {
                arguments[valueIndex] = lease.language.rawValue
            } else {
                arguments.append(lease.language.rawValue)
            }
        } else {
            arguments.append(contentsOf: ["-language", lease.language.rawValue])
        }
        return arguments
    }

    func observedRegistryLanguageToken(in prefix: URL) throws -> String? {
        let registryURL = prefix.appending(path: "user.reg")
        let read = try stableRead(
            registryURL,
            maximumByteCount: 64 * 1_024 * 1_024
        )
        guard case .data(let data) = read else { return nil }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                registryURL,
                "user.reg is not valid UTF-8"
            )
        }
        return WineUserRegistrySnapshot(contents: contents).value(
            forRegistryPath: Self.registryPath,
            valueName: Self.registryValueName
        )
    }

    func hasOwnershipMarker(in prefix: URL) throws -> Bool {
        try loadMarker(in: prefix) != nil
    }

    private func project(
        _ language: SteamClientLanguage,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws {
        if Self.normalizedToken(try observedRegistryLanguageToken(in: prefix)) !=
            language.rawValue {
            try await registryLanguageWriter(
                runtimeExecutable,
                prefix,
                logDirectory,
                language
            )
        }
        let observedToken = try observedRegistryLanguageToken(in: prefix)
        guard Self.normalizedToken(observedToken) == language.rawValue else {
            throw SteamClientLanguageOwnershipError.registryReadbackFailed(
                expected: language,
                observedToken: observedToken
            )
        }
    }

    private func loadMarker(in prefix: URL) throws -> Marker? {
        let markerURL = Self.markerURL(in: prefix)
        switch try stableRead(markerURL, maximumByteCount: 16 * 1_024) {
        case .missing:
            return nil
        case .data(let data):
            guard let marker = try? JSONDecoder().decode(Marker.self, from: data),
                  marker.schemaVersion == 1,
                  marker.webHelperLocaleIdentifier ==
                    marker.steamLanguage.webHelperLocaleIdentifier else {
                throw SteamClientLanguageOwnershipError.malformedMarker(markerURL)
            }
            let hasConsistentState = switch marker.state {
            case .pending:
                !marker.hasReachedUserControlBoundary
            case .owned:
                marker.hasReachedUserControlBoundary
            }
            guard hasConsistentState else {
                throw SteamClientLanguageOwnershipError.unsafeState(
                    markerURL,
                    "the marker state contradicts its Steam user-control boundary"
                )
            }
            return marker
        }
    }

    private func storeMarker(_ marker: Marker, in prefix: URL) throws {
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            prefix,
            fileManager: fileManager
        )
        let markerURL = Self.markerURL(in: prefix)
        if fileManager.fileExists(atPath: markerURL.path) {
            _ = try loadMarker(in: prefix)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
        try FileSystemItemPolicy.normalizeExistingOwnedPrivateRegularFile(
            markerURL
        )
        guard try loadMarker(in: prefix) == marker else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                markerURL,
                "atomic marker readback did not match"
            )
        }
    }

    private func relinquishMarker(in prefix: URL) throws {
        let markerURL = Self.markerURL(in: prefix)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        _ = try loadMarker(in: prefix)
        try fileManager.removeItem(at: markerURL)
    }

    private func stableRead(
        _ url: URL,
        maximumByteCount: Int
    ) throws -> StableFileRead {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .missing }
            throw SteamClientLanguageOwnershipError.unsafeState(
                url,
                String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_uid == geteuid(),
              before.st_size >= 0,
              before.st_size <= maximumByteCount else {
            throw SteamClientLanguageOwnershipError.unsafeState(
                url,
                "expected a bounded, current-user, single-link regular file"
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
                throw SteamClientLanguageOwnershipError.unsafeState(
                    url,
                    "the bounded file could not be read completely"
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
            throw SteamClientLanguageOwnershipError.unsafeState(
                url,
                "the file changed during readback"
            )
        }
        return .data(Data(bytes))
    }

    private static func normalizedToken(_ token: String?) -> String? {
        token?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 || errno != ENOENT
    }
}

enum SteamInstallVerificationState: Hashable, Sendable {
    case installerFailed
    case steamExecutableNotCreatedOrChanged
    case steamLanguageNotReady
    case steamClientServiceNotReady
    case verified
}

struct SteamInstallResult: Hashable {
    var processResult: ProcessRunResult
    var steamExecutableURL: URL
    var hasSteamExecutable: Bool
    var hadSteamExecutableBeforeInstall: Bool
    var didObserveSteamExecutableMutation: Bool
    var requestedSteamLanguage: SteamClientLanguage = .english
    var didClaimSteamLanguageOwnership: Bool = false
    var hasVerifiedSteamLanguageProjection: Bool = false
    var hasVerifiedSteamClientService: Bool = false
    var compatibilityPreparationWarning: String? = nil

    var verificationState: SteamInstallVerificationState {
        guard processResult.succeeded else {
            return .installerFailed
        }
        guard hasSteamExecutable,
              !hadSteamExecutableBeforeInstall || didObserveSteamExecutableMutation else {
            return .steamExecutableNotCreatedOrChanged
        }
        guard !didClaimSteamLanguageOwnership || hasVerifiedSteamLanguageProjection else {
            return .steamLanguageNotReady
        }
        guard hasVerifiedSteamClientService else {
            return .steamClientServiceNotReady
        }
        return .verified
    }

    var installationVerified: Bool {
        verificationState == .verified
    }
}

struct SteamClientServiceInspection: Hashable, Sendable {
    var hasSourceExecutable: Bool
    var hasInstalledExecutable: Bool
    var installedExecutableMatchesSource: Bool
    var hasRequiredServiceRegistry: Bool

    var isReady: Bool {
        hasSourceExecutable &&
            hasInstalledExecutable &&
            installedExecutableMatchesSource &&
            hasRequiredServiceRegistry
    }

    var failureDetail: String {
        var failures: [String] = []
        if !hasSourceExecutable {
            failures.append("Steam/bin/SteamService.exe is missing")
        }
        if !hasInstalledExecutable {
            failures.append("Common Files/Steam/SteamService.exe is missing")
        } else if !installedExecutableMatchesSource {
            failures.append("installed SteamService.exe does not match the current Steam payload")
        }
        if !hasRequiredServiceRegistry {
            failures.append("Steam Client Service registry contract is missing or stale")
        }
        return failures.isEmpty ? "ready" : failures.joined(separator: "; ")
    }
}

enum SteamClientServiceContract {
    static let serviceName = "Steam Client Service"
    static let serviceRegistryPath =
        "HKLM\\System\\CurrentControlSet\\Services\\Steam Client Service"
    static let valveRegistryPath =
        "HKLM\\Software\\Wow6432Node\\Valve\\SteamService"

    static func sourceExecutable(in prefix: URL) -> URL {
        prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/bin/SteamService.exe"
        )
    }

    static func installedExecutable(in prefix: URL) -> URL {
        prefix.appending(
            path: "drive_c/Program Files (x86)/Common Files/Steam/SteamService.exe"
        )
    }

    static func serviceControlExecutable(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/windows/system32/sc.exe")
    }

    static func inspect(
        prefix: URL,
        fileManager: FileManager = .default
    ) -> SteamClientServiceInspection {
        let source = sourceExecutable(in: prefix)
        let installed = installedExecutable(in: prefix)
        let hasSource = FileSystemItemPolicy.isRegularNonSymlinkFile(
            source,
            fileManager: fileManager
        )
        let hasInstalled = FileSystemItemPolicy.isRegularNonSymlinkFile(
            installed,
            fileManager: fileManager
        )
        let matches = hasSource &&
            hasInstalled &&
            fileManager.contentsEqual(atPath: source.path, andPath: installed.path)

        let systemRegistry = prefix.appending(path: "system.reg")
        let registrySnapshot: WineUserRegistrySnapshot? = {
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(
                systemRegistry,
                fileManager: fileManager
            ), let contents = try? String(contentsOf: systemRegistry, encoding: .utf8) else {
                return nil
            }
            return WineUserRegistrySnapshot(contents: contents)
        }()
        let imagePath = registrySnapshot?.value(
            forRegistryPath: serviceRegistryPath,
            valueName: "ImagePath"
        )?.lowercased()
        let expectedWindowsPath =
            #"c:\program files (x86)\common files\steam\steamservice.exe"#
        let hasRequiredRegistry =
            registrySnapshot?.value(
                forRegistryPath: serviceRegistryPath,
                valueName: "DisplayName"
            ) == serviceName &&
            imagePath?.contains(expectedWindowsPath) == true &&
            imagePath?.contains("/runasservice") == true &&
            registrySnapshot?.value(
                forRegistryPath: serviceRegistryPath,
                valueName: "ObjectName"
            )?.lowercased() == "localsystem" &&
            registrySnapshot?.value(
                forRegistryPath: serviceRegistryPath,
                valueName: "Start"
            )?.lowercased() == "dword:00000003" &&
            registrySnapshot?.value(
                forRegistryPath: serviceRegistryPath,
                valueName: "Type"
            )?.lowercased() == "dword:00000010" &&
            registrySnapshot?.value(
                forRegistryPath: serviceRegistryPath,
                valueName: "WOW64"
            )?.lowercased() == "dword:00000001" &&
            registrySnapshot?.value(
                forRegistryPath: valveRegistryPath,
                valueName: "installpath_default"
            )?.lowercased() == "c:\\program files (x86)\\steam"

        return SteamClientServiceInspection(
            hasSourceExecutable: hasSource,
            hasInstalledExecutable: hasInstalled,
            installedExecutableMatchesSource: matches,
            hasRequiredServiceRegistry: hasRequiredRegistry
        )
    }
}

enum WindowsSteamInstallationLayout {
    static func executable(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
    }

    static func configuration(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.cfg")
    }

    static func steamCfgPinPresent(in prefix: URL, fileManager: FileManager = .default) -> Bool {
        let steamConfiguration = configuration(in: prefix)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(steamConfiguration, fileManager: fileManager),
              let data = try? Data(contentsOf: steamConfiguration),
              data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("BootStrapperInhibitAll=enable") &&
            text.contains("BootStrapperForceSelfUpdate=disable")
    }
}

/// Diagnostic boundary for processes launched from another macOS app bundle.
/// ForgePlay never uses such an executable as its runtime; observing one during
/// a conformance run is recorded as foreign-process contamination.
enum ExternalApplicationRunnerPolicy {
    static func isUnsupportedRunnerExecutable(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager),
              fileManager.isExecutableFile(atPath: url.path),
              containingApplicationBundle(for: url, fileManager: fileManager) != nil else {
            return false
        }
        return !ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(url)
    }

    static func containingApplicationBundle(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let bundleIndex = components.lastIndex(where: {
            $0.lowercased().hasSuffix(".app")
        }), bundleIndex > 0 else {
            return nil
        }
        let bundle = URL(
            fileURLWithPath: NSString.path(withComponents: Array(components[0...bundleIndex])),
            isDirectory: true
        )
        guard FileSystemItemPolicy.isNonSymlinkDirectory(bundle, fileManager: fileManager) else {
            return nil
        }
        return bundle
    }
}

struct SteamLaunchTarget: Hashable, Sendable {
    var expectedRunnerPath: URL
    var expectedPrefixPath: URL
    var expectedSteamExecutablePath: URL
    var allowHostSteam: Bool = false

    var normalizedRunnerPath: String {
        expectedRunnerPath.standardizedFileURL.path
    }

    var normalizedRunnerDirectoryPath: String {
        expectedRunnerPath.deletingLastPathComponent().standardizedFileURL.path
    }

    var normalizedRunnerWineRootPath: String {
        expectedRunnerPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path
    }

    var normalizedPrefixPath: String {
        expectedPrefixPath.standardizedFileURL.path
    }

    var normalizedSteamExecutablePath: String {
        expectedSteamExecutablePath.standardizedFileURL.path
    }
}

enum SteamWebHelperLaunchPolicy {
    static let executableName = "steamwebhelper.exe"
    static let observationTargetEnvironmentKey =
        "FORGEPLAY_PROCESS_OBSERVATION_TARGET"
    static let argumentTargetEnvironmentKey =
        "FORGEPLAY_PROCESS_ARGUMENT_TARGET"
    static let argumentAppendEnvironmentKey =
        "FORGEPLAY_PROCESS_ARGUMENT_APPEND"
    static let argumentRootOnlyEnvironmentKey =
        "FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY"
    static let argumentRootOnlyEnvironmentValue = "1"
    /// This is the exact executable-scoped policy used by the 2026-07-10
    /// same-run Steam login render that produced visible account, password,
    /// and QR-code pixels. Valve retains ownership of `steamwebhelper.exe`.
    /// Current Chromium subprocesses retain their Valve command lines; Wine
    /// appends these root-process compatibility arguments only when the target
    /// has no standalone `--type=` role.
    static let requiredArguments = [
        "--no-sandbox",
        "--in-process-gpu",
        "--disable-gpu"
    ]

    static func commandLineContainsRequiredArguments(_ commandLine: String) -> Bool {
        let arguments = commandLineArguments(commandLine)
        return requiredArguments.allSatisfy(arguments.contains)
    }

    static func isChromiumSubprocessCommandLine(_ commandLine: String) -> Bool {
        commandLineArguments(commandLine).contains {
            $0.lowercased().hasPrefix("--type=")
        }
    }

    static func rootCommandLineContainsRequiredArguments(
        _ commandLine: String
    ) -> Bool {
        !isChromiumSubprocessCommandLine(commandLine) &&
            commandLineContainsRequiredArguments(commandLine)
    }

    static func textContainsRequiredRootProcessCommandLine(
        _ text: String
    ) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = String(rawLine)
            return line.lowercased().contains(executableName) &&
                rootCommandLineContainsRequiredArguments(line)
        }
    }

    /// Extracts Valve WebHelper's ICU locale arguments without interpreting
    /// Steam's surrounding command line as a shell command. Both spellings are
    /// accepted because Valve has emitted `-lang=` and Chromium-style
    /// `--lang=` forms across client revisions.
    static func observedLanguageLocaleIdentifiers(
        in commandLine: String
    ) -> [String] {
        var observed: [String] = []
        for rawArgument in commandLine.split(whereSeparator: \.isWhitespace) {
            let argument = String(rawArgument).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'")
            )
            guard let separator = argument.firstIndex(of: "=") else {
                continue
            }
            let name = argument[..<separator].lowercased()
            guard name == "-lang" || name == "--lang" else {
                continue
            }
            let value = String(argument[argument.index(after: separator)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }
            observed.append(value)
        }
        return observed
    }

    /// Canonical comparison form for the language/region ICU locales used by
    /// Steam WebHelper. Separator and ASCII case differences are not semantic;
    /// script aliases or unrelated locale shapes are deliberately not folded
    /// into a supported language.
    static func normalizedLanguageLocaleIdentifier(
        _ value: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        let components = trimmed.split(
            separator: "_",
            omittingEmptySubsequences: false
        )
        guard components.count == 2 else { return nil }
        let language = String(components[0])
        let region = String(components[1])
        guard (2...3).contains(language.utf8.count),
              language.utf8.allSatisfy(Self.isASCIIAlpha),
              (region.utf8.count == 2 &&
                  region.utf8.allSatisfy(Self.isASCIIAlpha) ||
                  region.utf8.count == 3 &&
                  region.utf8.allSatisfy(Self.isASCIIDigit)) else {
            return nil
        }
        return "\(language.lowercased())_\(region.uppercased())"
    }

    private static func commandLineArguments(_ commandLine: String) -> Set<String> {
        Set(commandLine.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'")
            )
        })
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}

enum SteamGameCEFBrowserLaunchPolicy {
    /// Separate from Valve's Steam infrastructure WebHelper policy. The Wine
    /// adapter applies this only to a root CEF browser executable beneath a
    /// Steam `steamapps/common` game, after finding its `libcef.dll` import;
    /// CEF `--type=` subprocesses and Steam infrastructure remain excluded.
    static let environmentKey = "FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED"
    static let enabledValue = "1"
    static let requiredArgument = "--in-process-gpu"
}

enum SteamLaunchGateStatus: String, Codable, Hashable, Sendable {
    case success = "SUCCESS"
    case launched = "LAUNCHED"
    case failed = "FAILED"
    case blocked = "BLOCKED"
    case deferred = "DEFERRED"
}

enum SteamLaunchVerificationMode: Hashable, Sendable {
    case operational
    case conformance

    var requiresVisibleUIEvidence: Bool {
        self == .conformance
    }
}

enum SteamLaunchGateReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case blockedRunnerPreflightFailed = "blocked-runner-preflight-failed"
    case blockedMissingWineFreetypeRuntime = "blocked-missing-wine-freetype-runtime"
    case blockedRunnerMissing = "blocked-runner-missing"
    case blockedPrefixHeldByStaleProcess = "blocked-prefix-held-by-stale-process"
    case blockedHostSteamRunning = "blocked-host-steam-running"
    case blockedExternalApplicationRunner = "blocked-external-application-runner"
    case blockedSupplementalDMGIsNotRuntime = "blocked-supplemental-renderer-is-not-runtime"
    case failedLaunchCommand = "failed-launch-command"
    case failedSteamCrashDumpCreated = "failed-steam-crash-dump-created"
    case failedSteamAccessViolation = "failed-steam-access-violation"
    case failedExpectedPrefixNotObserved = "failed-expected-prefix-not-observed"
    case failedWebHelperCommandLineMissing = "failed-webhelper-commandline-missing"
    case failedWebHelperLaunchPolicyMissing = "failed-webhelper-launch-policy-missing"
    case failedSteamUIStartup = "failed-steam-ui-startup"
    case failedVisibleUINotVerified = "failed-visible-ui-not-verified"
    case failedHostSteamContamination = "failed-host-steam-contamination"
    case failedExternalRunnerContamination = "failed-external-runner-contamination"
    case steamBootstrapUpdateInProgress = "steam-bootstrap-update-in-progress"
    case operationalProcessEvidenceUnavailable = "operational-process-evidence-unavailable"

    var diagnosticMessage: String {
        switch self {
        case .blockedRunnerPreflightFailed:
            "runner preflight failed before Windows Steam launch"
        case .blockedMissingWineFreetypeRuntime:
            "Wine-root FreeType runtime is missing; Steam launch was not attempted"
        case .blockedRunnerMissing:
            "expected runner path is missing or not executable"
        case .blockedPrefixHeldByStaleProcess:
            "expected WINEPREFIX is held by an existing process"
        case .blockedHostSteamRunning:
            "macOS Steam.app process is running in pure validation mode"
        case .blockedExternalApplicationRunner:
            "an unsupported external app-bundled runner is running or selected in pure validation mode"
        case .blockedSupplementalDMGIsNotRuntime:
            "Apple supplemental renderer input is not the bundled runtime executable"
        case .failedLaunchCommand:
            "launch command did not succeed"
        case .failedSteamCrashDumpCreated:
            "Steam crash dump was created during this run"
        case .failedSteamAccessViolation:
            "Steam crash dump reports 0xC0000005 access violation"
        case .failedExpectedPrefixNotObserved:
            "expected WINEPREFIX was not observed with steam.exe or steamwebhelper.exe in same-run launch evidence"
        case .failedWebHelperCommandLineMissing:
            "Steam WebHelper command line evidence for the expected prefix is missing"
        case .failedWebHelperLaunchPolicyMissing:
            "Steam WebHelper same-run command line is missing the executable-scoped CEF compatibility arguments"
        case .failedSteamUIStartup:
            "Steam WebHelper did not expose a usable login or desktop surface after one automatic prefix restart"
        case .failedVisibleUINotVerified:
            "screen-final.png visual evidence did not verify Windows Steam login, Steam Guard, or Library UI"
        case .failedHostSteamContamination:
            "macOS Steam.app process was present in the launch window"
        case .failedExternalRunnerContamination:
            "a foreign macOS application runtime process was present in the launch window"
        case .steamBootstrapUpdateInProgress:
            "Steam bootstrap update is still in progress; UI verification is deferred"
        case .operationalProcessEvidenceUnavailable:
            "Steam launch command succeeded, but live process evidence was unavailable; UI verification is deferred without stopping Steam"
        }
    }
}

struct SteamLaunchGateAssessment: Hashable, Sendable {
    var status: SteamLaunchGateStatus
    var reasonCodes: [SteamLaunchGateReasonCode]
    var details: [String] = []

    var diagnosticReasons: [String] {
        let codeLines = reasonCodes.map { "\($0.rawValue): \($0.diagnosticMessage)" }
        return codeLines + details
    }
}

struct SteamLaunchHardGateManifest: Codable, Hashable {
    struct Target: Codable, Hashable {
        var app: String
        var runner: String
        var wineprefix: String
        var steamExe: String

        enum CodingKeys: String, CodingKey {
            case app
            case runner
            case wineprefix
            case steamExe = "steam_exe"
        }
    }

    struct Evidence: Codable, Hashable {
        var diagnosticsLog: String
        var stderrLog: String
        var stdoutLog: String
        var evidenceDirectory: String
        var dumpsBefore: [String]
        var dumpsAfter: [String]
        var webhelperCommandLine: [String]
        var screenshots: [String]

        enum CodingKeys: String, CodingKey {
            case diagnosticsLog = "diagnostics_log"
            case stderrLog = "stderr_log"
            case stdoutLog = "stdout_log"
            case evidenceDirectory = "evidence_dir"
            case dumpsBefore = "dumps_before"
            case dumpsAfter = "dumps_after"
            case webhelperCommandLine = "webhelper_command_line"
            case screenshots
        }
    }

    var runID: String
    var status: SteamLaunchGateStatus
    var reasonCodes: [SteamLaunchGateReasonCode]
    var target: Target
    var evidence: Evidence
    var expectedRunner: String
    var actualRunnerProcesses: [String]
    var expectedPrefix: String
    var observedSteamProcesses: [String]
    var observedWebhelperProcesses: [String]
    var hostMacOSSteamContamination: Bool
    var externalRunnerContamination: Bool
    var unsupportedExternalRunnerDetected: Bool
    var webhelperCommandLineCaptured: Bool
    var windowsSteamUIVisible: Bool
    var steamUISurface: SteamUISurface?
    var screenshotPath: String?
    var newCrashDumpCount: Int
    var newAssertDumpCount: Int
    var steamCfgPinPresent: Bool
    var steamLaunchArgs: [String]

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case reasonCodes = "reason_codes"
        case target
        case evidence
        case expectedRunner = "expected_runner"
        case actualRunnerProcesses = "actual_runner_processes"
        case expectedPrefix = "expected_prefix"
        case observedSteamProcesses = "observed_steam_processes"
        case observedWebhelperProcesses = "observed_webhelper_processes"
        case hostMacOSSteamContamination = "host_macos_steam_contamination"
        case externalRunnerContamination = "external_runner_contamination"
        case unsupportedExternalRunnerDetected = "unsupported_external_runner_detected"
        case webhelperCommandLineCaptured = "webhelper_command_line_captured"
        case windowsSteamUIVisible = "windows_steam_ui_visible"
        case steamUISurface = "steam_ui_surface"
        case screenshotPath = "screenshot_path"
        case newCrashDumpCount = "new_crash_dump_count"
        case newAssertDumpCount = "new_assert_dump_count"
        case steamCfgPinPresent = "steam_cfg_pin_present"
        case steamLaunchArgs = "steam_launch_args"
    }
}

enum SteamRendererPolicyRecoveryKind: Hashable {
    case applyPolicy
    case repairPolicy
    /// An exact ForgePlay-owned transient renderer transaction survived a
    /// prior app termination. The normal Steam launch preflight owns its
    /// restoration; this is launchable pending recovery, not a satisfied
    /// renderer policy and not user-repairable contamination.
    case automaticSessionRecovery
    case runtimeUnavailable
}

struct SteamLibraryDriveMapping: Hashable {
    var driveLetter: String
    var macDriveRootURL: URL
    var macLibraryURL: URL
    var windowsLibraryPath: String

    init(
        driveLetter: String,
        macLibraryURL: URL,
        windowsLibraryPath: String,
        macDriveRootURL: URL? = nil
    ) {
        self.driveLetter = driveLetter
        self.macDriveRootURL = macDriveRootURL ?? macLibraryURL
        self.macLibraryURL = macLibraryURL
        self.windowsLibraryPath = windowsLibraryPath
    }
}

/// One macOS folder authorization can contain one or more Steam libraries.
/// The Wine drive must target the user-authorized root directly; Steam then
/// receives the real library's relative Windows path within that drive.
struct SteamLibraryDriveSource: Hashable {
    var authorizedRootURL: URL
    var libraryURL: URL
}

/// Drive exposure and existing-library registration are separate contracts.
/// Every authorized storage root must be available to Steam as a writable
/// Windows drive, including a blank root where Steam will create a library.
/// Only libraries that already carry Steam's own identity metadata are
/// returned as registration mappings.
struct SteamStorageDrivePreparation: Hashable {
    var externalStorageRoots: [URL]
    var libraryMappings: [SteamLibraryDriveMapping]
    /// Existing library-shaped roots whose Steam identity marker is currently
    /// incomplete or invalid. They remain mapped and granted, but are never
    /// added to `libraryfolders.vdf` until Steam publishes a valid identity.
    var pendingLibraryMappings: [SteamLibraryDriveMapping]
}

struct SteamRendererPolicyInspection: Hashable {
    var selection: SteamRendererPolicySelection
    var resolvedPolicy: SteamRendererPolicyPreference?
    var status: CheckStatus
    var userMessage: String
    var appliedModules: [String]
    var missingModules: [String]
    var mixedModules: [String]
    var appliedProfileOverrides: [String] = []
    var missingProfileOverrides: [String] = []
    var staleProfileOverrides: [String] = []
    var appliedSteamClientFiles: [String] = []
    var missingSteamClientFiles: [String] = []
    var staleSteamClientFiles: [String] = []
    var recoveryKind: SteamRendererPolicyRecoveryKind? = nil

    var effectiveRecoveryKind: SteamRendererPolicyRecoveryKind {
        if let recoveryKind {
            return recoveryKind
        }
        if status == .error || !mixedModules.isEmpty {
            return .repairPolicy
        }
        return .applyPolicy
    }

    var requiresRepair: Bool {
        effectiveRecoveryKind == .repairPolicy
    }

    var requiresApply: Bool {
        effectiveRecoveryKind == .applyPolicy && status == .warning && (
            !missingModules.isEmpty ||
            !missingProfileOverrides.isEmpty ||
            !staleProfileOverrides.isEmpty ||
            !missingSteamClientFiles.isEmpty ||
            !staleSteamClientFiles.isEmpty
        )
    }

    var allowsRecoveryAction: Bool {
        switch effectiveRecoveryKind {
        case .applyPolicy, .repairPolicy:
            status != .ok
        case .automaticSessionRecovery, .runtimeUnavailable:
            false
        }
    }

    var recoveryStatusLabelKey: String {
        switch effectiveRecoveryKind {
        case .applyPolicy:
            "Steam 실행 경로 적용 필요"
        case .repairPolicy:
            "Steam 실행 경로 정비 필요"
        case .automaticSessionRecovery:
            "이전 Steam 세션 자동 복구 대기"
        case .runtimeUnavailable:
            "ForgePlay Runtime 교체 필요"
        }
    }

    var recoveryActionTitleKey: String {
        switch effectiveRecoveryKind {
        case .applyPolicy:
            "실행 경로 적용/검증"
        case .repairPolicy:
            "실행 경로 정비/검증"
        case .automaticSessionRecovery:
            "다음 Steam 실행에서 자동 복구"
        case .runtimeUnavailable:
            "Runtime 확인"
        }
    }

    var setupRecoveryActionTitleKey: String {
        switch effectiveRecoveryKind {
        case .applyPolicy:
            "Steam 실행 경로 적용"
        case .repairPolicy:
            "Steam 실행 경로 정비"
        case .automaticSessionRecovery:
            "다음 Steam 실행에서 자동 복구"
        case .runtimeUnavailable:
            "Runtime 확인"
        }
    }
}

enum SteamUIVerificationState: String, Codable, CaseIterable, Hashable {
    case notRun
    case launchedButUnverified
    case rendered
    case blackScreenSuspected
    case failed

    static func inferred(from result: ProcessRunResult) -> SteamUIVerificationState {
        if let explicitState = result.steamUIVerificationState {
            return explicitState
        }
        if result.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
            return .launchedButUnverified
        }
        if result.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode {
            return .launchedButUnverified
        }
        if result.forgePlayStatusCode == SteamManager.steamRenderingFailureExitCode {
            return .blackScreenSuspected
        }
        guard result.succeeded else {
            return .failed
        }
        return .launchedButUnverified
    }
}

enum SteamInstallError: LocalizedError, Equatable {
    case invalidInstaller(URL)
    case installerMetadataReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidInstaller(let url):
            "Steam 공식 페이지에서 받은 일반 파일 SteamSetup.exe를 선택해야 합니다: \(url.path)"
        case .installerMetadataReadFailed(let url, let message):
            "Steam 설치 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        }
    }
}

enum SteamRendererLifecyclePhase: String, Sendable, Hashable {
    case preparation
    case preparationRollback
    case priorSessionRestoration
    case postLaunchRestoration
}

enum SteamRendererLifecycleOperation: String, Sendable, Hashable {
    case ngxCoreFullPathRegistration
    case ngxCoreRegistryFlush
    case ngxCoreFullPathRestoration
    case sessionRestoration
}

struct SteamRendererLifecycleFailure: Sendable, Hashable {
    let phase: SteamRendererLifecyclePhase
    let operation: SteamRendererLifecycleOperation
    let target: URL
    let detail: String
    let processResults: [ProcessRunResult]
}

enum SteamLaunchError: LocalizedError {
    case prefixShutdownFailed(ProcessRunResult)
    case rendererBridgeInstallFailed(URL, String)
    case rendererLifecycleFailed(SteamRendererLifecycleFailure)
    case rendererPolicyUnavailable(String)
    case rendererPolicyVerificationFailed(String)
    case steamClientCompatibilityFileInstallFailed(URL, String)
    case steamClientCompatibilitySetupFailed(ProcessRunResult)
    case steamClientCompatibilityVerificationFailed(String)
    case steamExecutableUnavailable(URL)
    case steamExecutableMetadataReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .prefixShutdownFailed(let result):
            "Windows용 Steam 실행 전에 기존 ForgePlay Runtime 프로세스를 정리하지 못했습니다. \(Self.processFailureDetail(result))"
        case .rendererBridgeInstallFailed(let url, let message):
            "게임 렌더러 payload 파일을 Steam 프리픽스에 준비하지 못했습니다: \(url.path). \(message)"
        case .rendererLifecycleFailed(let failure):
            "\(Self.rendererLifecyclePhaseDescription(failure.phase)): " +
                "\(failure.target.path). 작업: \(failure.operation.rawValue). " +
                "\(failure.detail)" +
                (failure.processResults.first.map {
                    " \(Self.processFailureDetail($0))"
                } ?? "")
        case .rendererPolicyUnavailable(let message):
            message
        case .rendererPolicyVerificationFailed(let message):
            message
        case .steamClientCompatibilityFileInstallFailed(let url, let message):
            "Windows용 Steam 호환성 파일을 적용하지 못했습니다: \(url.path). \(message)"
        case .steamClientCompatibilitySetupFailed(let result):
            "Windows용 Steam 호환성 설정을 Steam 프리픽스에 적용하지 못했습니다. \(Self.processFailureDetail(result))"
        case .steamClientCompatibilityVerificationFailed(let detail):
            "Windows용 Steam 호환성 설정을 적용한 뒤 검증에 실패했습니다: \(detail)"
        case .steamExecutableUnavailable(let url):
            "Windows용 Steam 실행 파일을 찾지 못했거나 안전한 일반 파일이 아닙니다. SteamSetup.exe를 Steam 프리픽스 안에 먼저 설치하세요: \(url.path)"
        case .steamExecutableMetadataReadFailed(let url, let message):
            "Windows용 Steam 실행 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        }
    }

    private static func processFailureDetail(_ result: ProcessRunResult) -> String {
        let timeout = result.didTimeOut ? ", 시간 초과" : ""
        let processIdentifier = result.processIdentifier.map(String.init) ?? "unavailable"
        return "실패 작업: \(result.actionName), 프로세스 PID: \(processIdentifier), 프로세스 종료 코드: \(result.diagnosticExitCodeDescription), 종료 신호: \(result.diagnosticTerminationSignalDescription), ForgePlay 상태 코드: \(result.diagnosticForgePlayStatusDescription)\(timeout), 로그: \(result.preferredDiagnosticLog.path)"
    }

    private static func rendererLifecyclePhaseDescription(
        _ phase: SteamRendererLifecyclePhase
    ) -> String {
        switch phase {
        case .preparation:
            "게임 렌더러 호환성 설정을 준비하지 못했습니다"
        case .preparationRollback:
            "게임 렌더러 준비 실패 후 원래 설정으로 되돌리지 못했습니다"
        case .priorSessionRestoration:
            "이전 게임 렌더러 세션의 설정을 복원하지 못했습니다"
        case .postLaunchRestoration:
            "Steam 종료 후 게임 렌더러 설정을 원래 상태로 복원하지 못했습니다"
        }
    }
}

enum SteamLibraryScanError: LocalizedError, Equatable {
    case scanFailed(URL, String)
    case metadataReadFailed(URL, String)
    case fileReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .scanFailed(let url, let message):
            "Steam 라이브러리 폴더를 검사하지 못했습니다: \(url.path). \(message)"
        case .metadataReadFailed(let url, let message):
            "Steam 라이브러리 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .fileReadFailed(let url, let message):
            "Steam 라이브러리 파일을 읽지 못했습니다: \(url.path). \(message)"
        }
    }
}

enum SteamLibraryDriveBridgeError: LocalizedError, Equatable {
    case dosdevicesUnavailable(URL)
    case libraryRootUnavailable(URL)
    case noAvailableDriveLetter(URL)
    case driveLetterOccupied(URL)
    case libraryFoldersUnavailable(URL)
    case libraryFoldersInvalid(URL, String)
    case libraryFoldersWriteFailed(URL, String)
    case bridgeDirectoryUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .dosdevicesUnavailable(let url):
            "Steam 라이브러리 드라이브를 연결할 수 없습니다. 프리픽스 dosdevices 폴더를 확인하세요: \(url.path)"
        case .libraryRootUnavailable(let url):
            "Steam 라이브러리 폴더가 안전한 일반 폴더가 아닙니다: \(url.path)"
        case .noAvailableDriveLetter(let url):
            "Steam 라이브러리 폴더에 배정할 Windows 드라이브 문자가 부족합니다: \(url.path)"
        case .driveLetterOccupied(let url):
            "Steam 라이브러리 드라이브 문자가 이미 다른 항목으로 사용 중입니다: \(url.path)"
        case .libraryFoldersUnavailable(let url):
            "Windows용 Steam 라이브러리 설정 폴더를 사용할 수 없습니다: \(url.path)"
        case .libraryFoldersInvalid(let url, let message):
            "Windows용 Steam 라이브러리 설정을 읽거나 검증하지 못했습니다: \(url.path). \(message)"
        case .libraryFoldersWriteFailed(let url, let message):
            "외장 Steam 라이브러리를 Windows용 Steam에 등록하지 못했습니다: \(url.path). \(message)"
        case .bridgeDirectoryUnavailable(let url):
            "외장 Steam 라이브러리용 Windows 드라이브 브리지를 만들 수 없습니다: \(url.path)"
        }
    }
}
