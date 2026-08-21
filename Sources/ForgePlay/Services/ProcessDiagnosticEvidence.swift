import Darwin
import Foundation
import Metal

enum ProcessRunOutcome: String, Codable, Hashable, Sendable {
    case exited
    case signaled
    case timedOut
    case runningDetached
    case preflightFailed
    case spawnFailed
    case unknown
}

struct ProcessRunGraphicsDeviceContext: Codable, Hashable, Sendable {
    var name: String
    var unifiedMemory: Bool
    var lowPower: Bool
    var removable: Bool
    var headless: Bool
    var recommendedMaxWorkingSetBytes: UInt64
}

struct ProcessRunHostContext: Codable, Hashable, Sendable {
    var capturedAt: Date
    var applicationVersion: String
    var applicationBuild: String
    var bundleIdentifier: String
    var operatingSystemVersion: String
    var operatingSystemBuild: String?
    var kernelVersion: String?
    var modelIdentifier: String?
    var cpuBrand: String? = nil
    var processArchitecture: String
    var processorCount: Int
    var activeProcessorCount: Int? = nil
    var physicalMemoryBytes: UInt64
    var translatedProcess: Bool?
    var availableMemoryBytesEstimate: UInt64? = nil
    var lowPowerModeEnabled: Bool? = nil
    var thermalState: String? = nil
    var rosettaTranslationAvailability: String? = nil
    var graphicsDevices: [ProcessRunGraphicsDeviceContext]? = nil

    static func capture() -> ProcessRunHostContext {
        let processInfo = ProcessInfo.processInfo
        return ProcessRunHostContext(
            capturedAt: Date(),
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            applicationBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            operatingSystemBuild: sysctlString("kern.osversion"),
            kernelVersion: sysctlString("kern.version"),
            modelIdentifier: sysctlString("hw.model"),
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            processArchitecture: processArchitecture,
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            translatedProcess: sysctlInt32("sysctl.proc_translated").map { $0 == 1 },
            availableMemoryBytesEstimate: availableMemoryBytesEstimate,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateName(processInfo.thermalState),
            rosettaTranslationAvailability: rosettaTranslationAvailability,
            graphicsDevices: MTLCopyAllDevices().map {
                ProcessRunGraphicsDeviceContext(
                    name: $0.name,
                    unifiedMemory: $0.hasUnifiedMemory,
                    lowPower: $0.isLowPower,
                    removable: $0.isRemovable,
                    headless: $0.isHeadless,
                    recommendedMaxWorkingSetBytes: $0.recommendedMaxWorkingSetSize
                )
            }
        )
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

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size || size == MemoryLayout<UInt64>.size else {
            return nil
        }
        return value
    }

    private static var availableMemoryBytesEstimate: UInt64? {
        guard let pageSize = sysctlUInt64("hw.pagesize") else { return nil }
        let pageCounts = [
            sysctlUInt64("vm.page_free_count"),
            sysctlUInt64("vm.page_inactive_count"),
            sysctlUInt64("vm.page_speculative_count")
        ].compactMap { $0 }
        guard !pageCounts.isEmpty else { return nil }
        let (pages, overflow) = pageCounts.reduce(into: (UInt64(0), false)) { result, value in
            let addition = result.0.addingReportingOverflow(value)
            result.0 = addition.partialValue
            result.1 = result.1 || addition.overflow
        }
        guard !overflow else { return nil }
        let bytes = pages.multipliedReportingOverflow(by: pageSize)
        return bytes.overflow ? nil : bytes.partialValue
    }

    private static var rosettaTranslationAvailability: String {
        #if arch(arm64)
        let evidencePaths = [
            "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
            "/Library/Apple/System/Library/LaunchDaemons/com.apple.oahd.plist"
        ]
        return evidencePaths.contains { FileManager.default.fileExists(atPath: $0) }
            ? "installed"
            : "notDetected"
        #else
        return "unsupportedHostArchitecture"
        #endif
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
}

struct ProcessRunEvidenceDocument: Codable, Hashable, Sendable {
    static let schemaVersion = 9
    static let readableSchemaVersions: Set<Int> = [4, 5, 6, 7, 8, schemaVersion]
    static let defaultActivityLeaseDuration: TimeInterval = 6 * 60 * 60

    var schemaVersion: Int = Self.schemaVersion
    var hostContext: ProcessRunHostContext? = .capture()
    var runIdentifier: String
    var actionName: String
    var executable: String
    var arguments: [String]
    var environmentOverrides: [String: String]
    /// ForgePlay-owned launch decisions which should be visible to support
    /// diagnostics without leaking diagnostic-only keys into the child process.
    var runtimeCompatibility: [String: String]? = nil
    var workingDirectory: String?
    var startedAt: Date
    var endedAt: Date
    var durationMilliseconds: Int64
    var outcome: ProcessRunOutcome
    var exitCode: Int32?
    /// ForgePlay policy/verification status, never an OS process exit status.
    var forgePlayStatusCode: Int32? = nil
    var relatedRunEvidenceLogs: [String]? = nil
    var terminationSignal: Int32?
    var rawWaitStatus: Int32?
    var didTimeOut: Bool
    var waitedForExit: Bool
    var processIdentifier: Int32?
    var stdoutLog: String
    var stderrLog: String
    var processObservationLog: String?
    /// Set when the higher-level operation has finished classifying the process
    /// result and all related diagnostic artifacts have been attached.
    var finalizedAt: Date? = nil
    /// A bounded conservative lease for outcomes whose root process was
    /// intentionally detached or whose final wait status was unavailable.
    var activityLeaseExpiresAt: Date? = nil
    var diagnosticLog: String? = nil
    var evidenceCaptureWarning: String? = nil
    var diagnosticCaptureWarning: String? = nil
    /// Authoritative result for an operation composed of multiple process
    /// attempts. Raw timeout/exit/signal fields continue to describe the
    /// primary process attempt and are never rewritten to manufacture success.
    var postconditionSatisfied: Bool? = nil
    var captureError: String?
    var failureDomain: String? = nil
    var failureCode: Int? = nil
}

enum ProcessRunEvidenceWriterError: LocalizedError {
    case unsafeEvidencePath(URL)
    case evidenceTooLarge(URL, Int64)
    case evidenceChangedDuringRead(URL)
    case invalidEvidenceIdentity(URL)

    var errorDescription: String? {
        switch self {
        case .unsafeEvidencePath(let url):
            "프로세스 증거 파일 경로가 안전하지 않습니다: \(url.path)"
        case .evidenceTooLarge(let url, let byteCount):
            "프로세스 증거 파일이 허용 크기를 초과했습니다: \(url.path) (\(byteCount) bytes)"
        case .evidenceChangedDuringRead(let url):
            "프로세스 증거 파일이 읽는 동안 변경되었습니다: \(url.path)"
        case .invalidEvidenceIdentity(let url):
            "프로세스 증거 파일의 실행 식별자가 일치하지 않습니다: \(url.path)"
        }
    }
}

enum ProcessRunEvidenceWriter {
    private struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64
    }

    private static let maximumEvidenceBytes = 512 * 1_024

    nonisolated static func write(
        _ document: ProcessRunEvidenceDocument,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(document)
        data.append(contentsOf: "\n".utf8)
        try writeAtomically(data, to: url, fileManager: fileManager)
    }

    nonisolated static func writeStructuredDocument<T: Encodable>(
        _ document: T,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(document)
        guard data.count <= maximumEvidenceBytes else {
            throw ProcessRunEvidenceWriterError.evidenceTooLarge(url, Int64(data.count))
        }
        data.append(contentsOf: "\n".utf8)
        try writeAtomically(data, to: url, fileManager: fileManager)
    }

    nonisolated static func read(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> ProcessRunEvidenceDocument {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ProcessRunEvidenceWriterError.unsafeEvidencePath(url)
        }
        defer { Darwin.close(descriptor) }

        let initialIdentity = try fileIdentity(for: descriptor, url: url)
        guard initialIdentity.byteCount <= Int64(maximumEvidenceBytes) else {
            throw ProcessRunEvidenceWriterError.evidenceTooLarge(url, initialIdentity.byteCount)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumEvidenceBytes else {
                    throw ProcessRunEvidenceWriterError.evidenceTooLarge(url, Int64(data.count))
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard try fileIdentity(for: descriptor, url: url) == initialIdentity else {
            throw ProcessRunEvidenceWriterError.evidenceChangedDuringRead(url)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProcessRunEvidenceDocument.self, from: data)
    }

    nonisolated static func evidenceURL(for stderrLog: URL) -> URL {
        stderrLog.deletingPathExtension().appendingPathExtension("run.json")
    }

    nonisolated static func runIdentifier(for stderrLog: URL) -> String {
        var stem = stderrLog.deletingPathExtension().lastPathComponent
        if stem.hasSuffix("_stderr") {
            stem.removeLast("_stderr".count)
        }
        if let candidate = stem.split(separator: "_").last,
           UUID(uuidString: String(candidate)) != nil {
            return String(candidate).lowercased()
        }
        return stem
    }

    private nonisolated static func writeAtomically(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileSystemItemPolicy.requireNonSymlinkDirectory(directory, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        }

        let temporaryURL = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                _ = temporaryURL.path.withCString { Darwin.unlink($0) }
            }
        }

        let descriptor = temporaryURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw ProcessRunEvidenceWriterError.unsafeEvidencePath(temporaryURL)
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
        }
        _ = try fileIdentity(for: descriptor, url: temporaryURL)

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        descriptorIsOpen = false

        // Revalidate immediately before replacement. rename(2) replaces a name,
        // never follows a destination symlink, but rejecting unsafe existing
        // entries keeps the evidence directory policy conservative.
        try FileSystemItemPolicy.requireNonSymlinkDirectory(directory, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        }
        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporary = false
    }

    private nonisolated static func fileIdentity(
        for descriptor: Int32,
        url: URL
    ) throws -> FileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0 else {
            throw ProcessRunEvidenceWriterError.unsafeEvidencePath(url)
        }
        return FileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }
}

struct FailureDiagnosticEvidenceDocument: Codable, Hashable, Sendable {
    struct Failure: Codable, Hashable, Sendable {
        var domain: String
        var code: Int
        var typeName: String
        var summary: String
        var failureReason: String?
        var recoverySuggestion: String?
    }

    static let currentSchemaVersion = 2

    var schemaVersion: Int = Self.currentSchemaVersion
    var reportIdentifier: String
    var capturedAt: Date
    var evidenceKind: String
    var operationIdentifier: String
    var surfaceIdentifier: String
    var storageKind: String = "managedLogs"
    var captureWarnings: [String] = []
    var hostContext: ProcessRunHostContext
    var failure: Failure
    var privacyNotice: String
}

enum FailureDiagnosticEvidenceResolution: Hashable, Sendable {
    case existingProcessEvidence(URL)
    case capturedFailure(URL)

    var url: URL {
        switch self {
        case .existingProcessEvidence(let url), .capturedFailure(let url):
            url
        }
    }
}

enum FailureDiagnosticEvidenceServiceError: LocalizedError, Equatable {
    case unsafeDiagnosticDirectory(URL)
    case allDiagnosticStorageUnavailable(primary: String, emergency: String)

    var errorDescription: String? {
        switch self {
        case .unsafeDiagnosticDirectory(let url):
            "실패 진단 파일을 저장할 폴더가 안전한 관리 폴더가 아닙니다: \(url.path)"
        case .allDiagnosticStorageUnavailable(let primary, let emergency):
            "기본 로그와 비상 진단 저장소를 모두 사용할 수 없습니다. 기본: \(primary). 비상: \(emergency)"
        }
    }
}

/// Persists a small, redacted failure report when an operation fails before a
/// process sidecar can exist. Process evidence remains authoritative whenever
/// its identity-checked `*.run.json` is already available.
@MainActor
final class FailureDiagnosticEvidenceService {
    private let pathManager: PathManager
    private let redactor: Redactor
    private let fileManager: FileManager
    private let hostContextProvider: @Sendable () -> ProcessRunHostContext
    private let emergencyDiagnosticDirectory: URL

    init(
        pathManager: PathManager,
        redactor: Redactor,
        fileManager: FileManager = .default,
        emergencyDiagnosticDirectory: URL? = nil,
        hostContextProvider: @escaping @Sendable () -> ProcessRunHostContext = {
            ProcessRunHostContext.capture()
        }
    ) {
        self.pathManager = pathManager
        self.redactor = redactor
        self.fileManager = fileManager
        self.hostContextProvider = hostContextProvider
        self.emergencyDiagnosticDirectory = emergencyDiagnosticDirectory ?? Self.defaultEmergencyDiagnosticDirectory(
            fileManager: fileManager
        )
    }

    func ensureEvidence(
        for error: Error,
        operationIdentifier: String,
        surfaceIdentifier: String,
        additionalSensitivePaths: [String] = [],
        additionalSensitiveTerms: [String] = [],
        capturedAt: Date = Date()
    ) throws -> FailureDiagnosticEvidenceResolution {
        if let existingEvidence = diagnosticProcessRunResults(from: error)
            .compactMap(validatedProcessEvidenceURL(for:))
            .first {
            return .existingProcessEvidence(existingEvidence)
        }
        let operationError = error

        do {
            let managedRoot = try pathManager.validateCurrentManagedRoot().standardizedFileURL
            let diagnosticDirectory = try pathManager.url(for: .diagnosticLogs).standardizedFileURL
            try pathManager.createDirectoryIfNeeded(diagnosticDirectory)
            let outputURL = try pathManager.createLogURL(
                kind: "diagnostic",
                name: "failure-\(UUID().uuidString.lowercased())",
                extension: "json"
            ).standardizedFileURL

            guard outputURL.deletingLastPathComponent() == diagnosticDirectory,
                  FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                    from: managedRoot,
                    to: outputURL,
                    fileManager: fileManager
                  ) else {
                throw FailureDiagnosticEvidenceServiceError.unsafeDiagnosticDirectory(diagnosticDirectory)
            }
            try writeFailureEvidence(
                error: operationError,
                operationIdentifier: operationIdentifier,
                surfaceIdentifier: surfaceIdentifier,
                outputURL: outputURL,
                storageKind: "managedLogs",
                captureWarnings: [],
                sensitivePaths: [managedRoot.path, diagnosticDirectory.path] + additionalSensitivePaths,
                sensitiveTerms: additionalSensitiveTerms,
                capturedAt: capturedAt
            )
            return .capturedFailure(outputURL)
        } catch {
            let primaryFailure = forgePlayTechnicalErrorSummary(error)
            do {
                let emergencyDirectory = try prepareEmergencyDiagnosticDirectory()
                let outputURL = emergencyDirectory.appending(
                    path: "failure-\(UUID().uuidString.lowercased()).json",
                    directoryHint: .notDirectory
                )
                try writeFailureEvidence(
                    error: operationError,
                    operationIdentifier: operationIdentifier,
                    surfaceIdentifier: surfaceIdentifier,
                    outputURL: outputURL,
                    storageKind: "privateEmergencyCache",
                    captureWarnings: ["managed diagnostic storage unavailable: \(primaryFailure)"],
                    sensitivePaths: [
                        emergencyDirectory.path,
                        pathManager.rootURL?.path
                    ].compactMap { $0 } + additionalSensitivePaths,
                    sensitiveTerms: additionalSensitiveTerms,
                    capturedAt: capturedAt
                )
                return .capturedFailure(outputURL)
            } catch {
                throw FailureDiagnosticEvidenceServiceError.allDiagnosticStorageUnavailable(
                    primary: primaryFailure,
                    emergency: forgePlayTechnicalErrorSummary(error)
                )
            }
        }
    }

    private func writeFailureEvidence(
        error: Error,
        operationIdentifier: String,
        surfaceIdentifier: String,
        outputURL: URL,
        storageKind: String,
        captureWarnings: [String],
        sensitivePaths: [String],
        sensitiveTerms: [String],
        capturedAt: Date
    ) throws {
        let reportRedactor = redactor
            .addingSensitivePaths(sensitivePaths)
            .addingSensitiveTerms(sensitiveTerms)
        let bridgedError = error as NSError
        let document = FailureDiagnosticEvidenceDocument(
            reportIdentifier: UUID().uuidString.lowercased(),
            capturedAt: capturedAt,
            evidenceKind: "preProcessFailure",
            operationIdentifier: normalizedIdentifier(
                operationIdentifier,
                fallback: "unknown-operation",
                redactor: reportRedactor
            ),
            surfaceIdentifier: normalizedIdentifier(
                surfaceIdentifier,
                fallback: "unknown-surface",
                redactor: reportRedactor
            ),
            storageKind: storageKind,
            captureWarnings: captureWarnings.map {
                redactedBoundedText($0, redactor: reportRedactor)
            },
            hostContext: hostContextProvider(),
            failure: .init(
                domain: redactedBoundedText(bridgedError.domain, redactor: reportRedactor),
                code: bridgedError.code,
                typeName: redactedBoundedText(
                    String(reflecting: type(of: error)),
                    redactor: reportRedactor
                ),
                summary: redactedBoundedText(
                    forgePlayTechnicalErrorSummary(error),
                    limit: 16_384,
                    redactor: reportRedactor
                ),
                failureReason: redactedBoundedOptionalText(
                    bridgedError.localizedFailureReason,
                    redactor: reportRedactor
                ),
                recoverySuggestion: redactedBoundedOptionalText(
                    bridgedError.localizedRecoverySuggestion,
                    redactor: reportRedactor
                )
            ),
            privacyNotice: "This local failure report automatically removes recognized sensitive data, but some data may remain. Review it before sharing."
        )
        try ProcessRunEvidenceWriter.writeStructuredDocument(
            document,
            to: outputURL,
            fileManager: fileManager
        )
    }

    private func prepareEmergencyDiagnosticDirectory() throws -> URL {
        try fileManager.createDirectory(
            at: emergencyDiagnosticDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(emergencyDiagnosticDirectory.path, S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            emergencyDiagnosticDirectory,
            fileManager: fileManager
        )
        var status = stat()
        guard lstat(emergencyDiagnosticDirectory.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw FailureDiagnosticEvidenceServiceError.unsafeDiagnosticDirectory(
                emergencyDiagnosticDirectory
            )
        }
        return emergencyDiagnosticDirectory
    }

    nonisolated static func defaultEmergencyDiagnosticDirectory(
        fileManager: FileManager
    ) -> URL {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory
        return cacheRoot
            .appending(path: "ForgePlay", directoryHint: .isDirectory)
            .appending(path: "EmergencyDiagnostics", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    private func validatedProcessEvidenceURL(for result: ProcessRunResult) -> URL? {
        guard let evidenceURL = result.runEvidenceLog?.standardizedFileURL,
              evidenceURL == ProcessRunEvidenceWriter.evidenceURL(
                for: result.stderrLog
              ).standardizedFileURL,
              let document = try? ProcessRunEvidenceWriter.read(
                from: evidenceURL,
                fileManager: fileManager
              ),
              ProcessRunEvidenceDocument.readableSchemaVersions.contains(document.schemaVersion),
              document.runIdentifier.lowercased() == ProcessRunEvidenceWriter.runIdentifier(
                for: result.stderrLog
              ).lowercased(),
              URL(fileURLWithPath: document.stderrLog).standardizedFileURL ==
                result.stderrLog.standardizedFileURL else {
            return nil
        }
        return evidenceURL
    }

    private func normalizedIdentifier(
        _ value: String,
        fallback: String,
        redactor: Redactor
    ) -> String {
        let normalized = redactedBoundedText(value, limit: 128, redactor: redactor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }

    private func redactedBoundedOptionalText(
        _ value: String?,
        limit: Int = 4_096,
        redactor: Redactor
    ) -> String? {
        guard let value else { return nil }
        let normalized = redactedBoundedText(value, limit: limit, redactor: redactor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func redactedBoundedText(
        _ value: String,
        limit: Int = 4_096,
        redactor: Redactor
    ) -> String {
        String(redactor.redact(value).prefix(limit))
    }
}

protocol DiagnosticEvidenceProvidingError: Error {
    var diagnosticProcessResult: ProcessRunResult? { get }
}

protocol DiagnosticEvidenceCollectionProvidingError: Error {
    var diagnosticProcessResults: [ProcessRunResult] { get }
}

struct ProcessExecutionEvidenceError: LocalizedError, ForgePlayTechnicalDescribingError,
    DiagnosticEvidenceProvidingError, ForgePlayDiagnosticLogProvidingError, @unchecked Sendable {
    let underlyingError: Error
    let result: ProcessRunResult

    var diagnosticProcessResult: ProcessRunResult? { result }
    var forgePlayDiagnosticLogURL: URL? { result.preferredDiagnosticLog }
    var errorDescription: String? {
        (underlyingError as? LocalizedError)?.errorDescription ??
            (underlyingError as NSError).localizedDescription
    }
    var forgePlayTechnicalDescription: String {
        forgePlayTechnicalErrorSummary(underlyingError)
    }
}

func diagnosticProcessRunResults(from error: Error) -> [ProcessRunResult] {
    var results: [ProcessRunResult] = []
    if let provider = error as? any DiagnosticEvidenceCollectionProvidingError {
        results.append(contentsOf: provider.diagnosticProcessResults)
    }
    if let provider = error as? any DiagnosticEvidenceProvidingError,
       let result = provider.diagnosticProcessResult {
        results.append(result)
    }
    if let evidenceError = error as? ProcessExecutionEvidenceError {
        results.append(contentsOf: diagnosticProcessRunResults(from: evidenceError.underlyingError))
    }
    let bridged = error as NSError
    if let underlying = bridged.userInfo[NSUnderlyingErrorKey] as? Error,
       forgePlayTechnicalErrorSummary(underlying) != forgePlayTechnicalErrorSummary(error) {
        results.append(contentsOf: diagnosticProcessRunResults(from: underlying))
    }
    var seen = Set<ProcessRunResult>()
    return results.filter { seen.insert($0).inserted }
}

func diagnosticProcessRunResult(from error: Error) -> ProcessRunResult? {
    diagnosticProcessRunResults(from: error).first
}

extension SteamPrefixLifecycleCleanupError: DiagnosticEvidenceCollectionProvidingError {
    var diagnosticProcessResults: [ProcessRunResult] {
        var results: [ProcessRunResult] = []
        if let originalProcessResult { results.append(originalProcessResult) }
        if let originalError {
            results.append(contentsOf: diagnosticProcessRunResults(from: originalError))
        }
        results.append(contentsOf: cleanupProcessResults)
        if let cleanupError {
            results.append(contentsOf: diagnosticProcessRunResults(from: cleanupError))
        }
        var seen = Set<ProcessRunResult>()
        return results.filter { seen.insert($0).inserted }
    }
}

extension PrefixManagerError: DiagnosticEvidenceProvidingError {
    var diagnosticProcessResult: ProcessRunResult? { result }
}

extension WindowsRuntimeServiceError: DiagnosticEvidenceProvidingError {
    var diagnosticProcessResult: ProcessRunResult? {
        guard case .probeFailed(let result) = self else { return nil }
        return result
    }
}

extension RuntimeManagerError: DiagnosticEvidenceProvidingError {
    var diagnosticProcessResult: ProcessRunResult? { processResult }
}

extension SteamLaunchError: DiagnosticEvidenceCollectionProvidingError {
    var diagnosticProcessResults: [ProcessRunResult] {
        switch self {
        case .prefixShutdownFailed(let result),
             .steamClientCompatibilitySetupFailed(let result):
            return [result]
        case .rendererLifecycleFailed(let failure):
            return failure.processResults
        case .rendererBridgeInstallFailed,
             .rendererPolicyUnavailable,
             .rendererPolicyVerificationFailed,
             .steamClientCompatibilityFileInstallFailed,
             .steamClientCompatibilityVerificationFailed,
             .steamExecutableUnavailable,
             .steamExecutableMetadataReadFailed:
            return []
        }
    }
}
