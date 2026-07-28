import CryptoKit
import Darwin
import Foundation

struct RuntimeManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 3
    static let currentCorePayloadHashAlgorithm = "sha256-macho-signature-independent-v1"
    static let requiredCorePayloadPaths: Set<String> = [
        "wine/bin/wine",
        "wine/bin/wine.bin",
        "wine/bin/wineserver",
        "wine/bin/wineserver.bin",
        "wine/lib/wine/x86_64-unix/wine",
        "wine/lib/wine/x86_64-unix/ntdll.so",
        "wine/lib/wine/i386-windows/ntdll.dll",
        "wine/lib/wine/i386-windows/kernelbase.dll",
        "wine/lib/wine/i386-windows/winegstreamer.dll",
        "wine/lib/wine/x86_64-windows/ntdll.dll",
        "wine/lib/wine/x86_64-windows/kernelbase.dll",
        "wine/lib/wine/x86_64-windows/winegstreamer.dll",
        "wine/lib/wine/x86_64-unix/winegstreamer.so",
        "wine/lib/wine/x86_64-unix/winemac.so",
        "wine/lib/wine/i386-windows/winemac.drv",
        "wine/lib/wine/x86_64-windows/winemac.drv",
        "wine/lib/wine/x86_64-unix/winevulkan.so",
        "wine/lib/wine/i386-windows/winevulkan.dll",
        "wine/lib/wine/x86_64-windows/winevulkan.dll",
        "wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe"
    ]

    var schemaVersion: Int
    var runtimeIdentifier: String
    var wineVersion: String
    var architecture: String
    var sourceTreeSHA256: String?
    var patchSetSHA256: String?
    var runnerLauncherSHA256: String
    var wineInfSHA256: String
    var winebootSHA256: String
    var prefixCompatibilityFingerprint: String
    var runnerBuildFingerprint: String
    var hostSupportSBOMPath: String? = nil
    var hostSupportSBOMSHA256: String? = nil
    var hostSupportPayloadFingerprint: String? = nil
    var corePayloadHashAlgorithm: String? = nil
    var corePayloadSHA256: [String: String]? = nil
    var corePayloadFingerprint: String? = nil
    /// Optional provenance/status fields keep schema-v1 manifests decodable
    /// while making derived, incomplete component identity explicit.
    var identitySource: String? = nil
    var wineInfFingerprintState: String? = nil
    var winebootFingerprintState: String? = nil
    var corePayloadFingerprintState: String? = nil
    var identityIssues: [String]? = nil

    static func prefixCompatibilityFingerprint(
        wineVersion: String,
        architecture: String,
        wineInfSHA256: String,
        winebootSHA256: String
    ) -> String {
        sha256([
            "forgeplay-prefix-compatibility-v1",
            "wineVersion=\(wineVersion)",
            "architecture=\(architecture)",
            "wineInfSHA256=\(wineInfSHA256)",
            "winebootSHA256=\(winebootSHA256)"
        ].joined(separator: "\n") + "\n")
    }

    static func runnerBuildFingerprint(
        sourceTreeSHA256: String?,
        patchSetSHA256: String?,
        runnerLauncherSHA256: String,
        prefixCompatibilityFingerprint: String,
        hostSupportPayloadFingerprint: String? = nil,
        corePayloadFingerprint: String? = nil
    ) -> String {
        let formatVersion: String
        if corePayloadFingerprint != nil {
            formatVersion = "forgeplay-runtime-build-v3"
        } else if hostSupportPayloadFingerprint != nil {
            formatVersion = "forgeplay-runtime-build-v2"
        } else {
            formatVersion = "forgeplay-runtime-build-v1"
        }
        var fields = [
            formatVersion,
            "sourceTreeSHA256=\(sourceTreeSHA256 ?? "unavailable")",
            "patchSetSHA256=\(patchSetSHA256 ?? "unavailable")",
            "runnerLauncherSHA256=\(runnerLauncherSHA256)",
            "prefixCompatibilityFingerprint=\(prefixCompatibilityFingerprint)"
        ]
        if let hostSupportPayloadFingerprint {
            fields.append("hostSupportPayloadFingerprint=\(hostSupportPayloadFingerprint)")
        }
        if let corePayloadFingerprint {
            fields.append("corePayloadFingerprint=\(corePayloadFingerprint)")
        }
        return sha256(fields.joined(separator: "\n") + "\n")
    }

    static func corePayloadFingerprint(_ payloads: [String: String]) -> String {
        let fields = ["forgeplay-runtime-core-payload-v2"] + payloads.keys.sorted().map {
            "\($0)=\(payloads[$0] ?? "")"
        }
        return sha256(fields.joined(separator: "\n") + "\n")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func unavailablePayloadFingerprint(component: String, state: String) -> String {
        sha256([
            "forgeplay-runtime-unavailable-payload-v1",
            "component=\(component)",
            "state=\(state)"
        ].joined(separator: "\n") + "\n")
    }
}

struct PrefixRuntimeBinding: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var runtimeIdentifier: String
    var runnerBuildFingerprint: String
    var prefixCompatibilityFingerprint: String
    var wineInfSHA256: String
    var appliedAt: Date

    init(manifest: RuntimeManifest, appliedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        runtimeIdentifier = manifest.runtimeIdentifier
        runnerBuildFingerprint = manifest.runnerBuildFingerprint
        prefixCompatibilityFingerprint = manifest.prefixCompatibilityFingerprint
        wineInfSHA256 = manifest.wineInfSHA256
        self.appliedAt = appliedAt
    }

    func matches(_ manifest: RuntimeManifest) -> Bool {
        schemaVersion == Self.currentSchemaVersion &&
            runtimeIdentifier == manifest.runtimeIdentifier &&
            runnerBuildFingerprint == manifest.runnerBuildFingerprint &&
            prefixCompatibilityFingerprint == manifest.prefixCompatibilityFingerprint &&
            wineInfSHA256 == manifest.wineInfSHA256
    }
}

enum PrefixRuntimeCompatibilityInspection: Hashable, Sendable {
    case compatible
    case migrationRequired(String)
    case runtimeUnavailable(String)

    var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }
}

enum RuntimeManifestError: LocalizedError, Equatable {
    case bundledManifestMissing(URL)
    case unsafeManifest(URL)
    case manifestTooLarge(URL)
    case manifestUnreadable(URL, String)
    case invalidManifest(URL, String)
    case runtimePayloadMissing(URL)
    case unsafeRuntimePayload(URL)
    case runtimePayloadTooLarge(URL)
    case runtimePayloadUnreadable(URL, String)
    case runtimePayloadFingerprintMismatch(URL)

    var errorDescription: String? {
        switch self {
        case .bundledManifestMissing(let url):
            "ForgePlay Runtime manifest를 찾을 수 없습니다: \(url.path)"
        case .unsafeManifest(let url):
            "ForgePlay Runtime manifest가 안전한 일반 파일이 아닙니다: \(url.path)"
        case .manifestTooLarge(let url):
            "ForgePlay Runtime manifest가 허용 크기를 초과했습니다: \(url.path)"
        case .manifestUnreadable(let url, let reason):
            "ForgePlay Runtime manifest를 안전하게 읽지 못했습니다: \(url.path). \(reason)"
        case .invalidManifest(let url, let reason):
            "ForgePlay Runtime manifest가 올바르지 않습니다: \(url.path). \(reason)"
        case .runtimePayloadMissing(let url):
            "ForgePlay Runtime identity에 필요한 파일을 찾을 수 없습니다: \(url.path)"
        case .unsafeRuntimePayload(let url):
            "ForgePlay Runtime identity 파일이 symlink/hardlink가 아닌 안전한 일반 파일이 아닙니다: \(url.path)"
        case .runtimePayloadTooLarge(let url):
            "ForgePlay Runtime identity 파일이 fingerprint 검사 크기 제한을 초과했습니다: \(url.path)"
        case .runtimePayloadUnreadable(let url, let message):
            "ForgePlay Runtime identity 파일을 읽지 못했습니다: \(url.path). \(message)"
        case .runtimePayloadFingerprintMismatch(let url):
            "ForgePlay Runtime 파일이 manifest의 fingerprint와 일치하지 않습니다: \(url.path)"
        }
    }
}

protocol RuntimeManifestProviding {
    func manifest(for executable: URL) throws -> RuntimeManifest
}

private struct RuntimeSBOMIdentity: Decodable {
    var schemaVersion: Int
    var runtimeIdentifier: String
    var payloadFingerprint: String
}

struct RuntimeManifestResolver: RuntimeManifestProviding {
    private static let maxManifestBytes = 256 * 1024
    private static let maxHashedPayloadBytes: UInt64 = 512 * 1024 * 1024
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func manifest(for executable: URL) throws -> RuntimeManifest {
        if let manifestURL = manifestURL(for: executable) {
            return try loadAndValidateManifest(at: manifestURL, executable: executable)
        }
        if ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(executable) {
            throw RuntimeManifestError.bundledManifestMissing(executable)
        }
        return try derivedManifest(for: executable, permitsIncompletePayloadIdentity: false)
    }

    /// Support evidence needs to explain an incomplete unmanaged runtime without
    /// turning that best-effort identity into an operational compatibility key.
    /// `manifest(for:)` remains strict for Prefix binding; only diagnostics call
    /// this method and receive component-tagged unavailable fingerprints.
    func diagnosticManifest(for executable: URL) throws -> RuntimeManifest {
        if let manifestURL = manifestURL(for: executable) {
            return try loadAndValidateManifest(at: manifestURL, executable: executable)
        }
        if ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(executable) {
            throw RuntimeManifestError.bundledManifestMissing(executable)
        }
        return try derivedManifest(for: executable, permitsIncompletePayloadIdentity: true)
    }

    private func manifestURL(for executable: URL) -> URL? {
        var directory = executable.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appending(path: "RuntimeManifest.json")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private func loadAndValidateManifest(at manifestURL: URL, executable: URL) throws -> RuntimeManifest {
        let data = try readManifestData(at: manifestURL)

        var manifest: RuntimeManifest
        do {
            manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        } catch {
            throw RuntimeManifestError.invalidManifest(
                manifestURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        try validateFields(manifest, at: manifestURL)

        let runtimeRoot = manifestURL.deletingLastPathComponent()
        let wineInf = runtimeRoot.appending(path: "wine/share/wine/wine.inf")
        let wineboot = runtimeRoot.appending(path: "wine/lib/wine/x86_64-windows/wineboot.exe")
        try requireFingerprint(manifest.wineInfSHA256, for: wineInf)
        try requireFingerprint(manifest.winebootSHA256, for: wineboot)
        try requireFingerprint(manifest.runnerLauncherSHA256, for: executable)
        if manifest.schemaVersion >= 2,
           let sbomPath = manifest.hostSupportSBOMPath,
           let expectedSBOMSHA256 = manifest.hostSupportSBOMSHA256,
           let expectedPayloadFingerprint = manifest.hostSupportPayloadFingerprint {
            let sbomURL = runtimeRoot.appending(path: sbomPath)
            let sbomData = try readManifestData(at: sbomURL)
            let actualSBOMSHA256 = SHA256.hash(data: sbomData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualSBOMSHA256 == expectedSBOMSHA256 else {
                throw RuntimeManifestError.invalidManifest(
                    manifestURL,
                    "host-support SBOM fingerprint does not match the bundled manifest"
                )
            }
            let sbomIdentity: RuntimeSBOMIdentity
            do {
                sbomIdentity = try JSONDecoder().decode(RuntimeSBOMIdentity.self, from: sbomData)
            } catch {
                throw RuntimeManifestError.invalidManifest(
                    manifestURL,
                    "host-support SBOM identity is unreadable"
                )
            }
            guard sbomIdentity.schemaVersion == 1,
                  sbomIdentity.runtimeIdentifier == manifest.runtimeIdentifier,
                  sbomIdentity.payloadFingerprint == expectedPayloadFingerprint else {
                throw RuntimeManifestError.invalidManifest(
                    manifestURL,
                    "host-support SBOM identity does not match the bundled manifest"
                )
            }
        }
        if manifest.schemaVersion == RuntimeManifest.currentSchemaVersion,
           let corePayloads = manifest.corePayloadSHA256 {
            for path in RuntimeManifest.requiredCorePayloadPaths.sorted() {
                guard let expected = corePayloads[path] else {
                    throw RuntimeManifestError.invalidManifest(
                        manifestURL,
                        "core runtime payload identity is missing \(path)"
                    )
                }
                try requireCorePayloadFingerprint(
                    expected,
                    for: runtimeRoot.appending(path: path)
                )
            }
        }
        // The on-disk payloads were independently verified above. Do not trust
        // optional status annotations supplied by the manifest itself.
        manifest.identitySource = "manifest"
        manifest.wineInfFingerprintState = "verified"
        manifest.winebootFingerprintState = "verified"
        if manifest.schemaVersion == RuntimeManifest.currentSchemaVersion {
            manifest.corePayloadFingerprintState = "verified"
            manifest.identityIssues = []
        } else {
            manifest.corePayloadFingerprintState = "legacy-unverified"
            manifest.identityIssues = [
                "runtime manifest schema \(manifest.schemaVersion) does not authenticate ForgePlay's core routing modules"
            ]
        }
        return manifest
    }

    private func readManifestData(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw RuntimeManifestError.unsafeManifest(url) }
            throw RuntimeManifestError.manifestUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0 else {
            throw RuntimeManifestError.manifestUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size >= 0 else {
            throw RuntimeManifestError.unsafeManifest(url)
        }
        guard initialStatus.st_size <= off_t(Self.maxManifestBytes) else {
            throw RuntimeManifestError.manifestTooLarge(url)
        }

        let expectedByteCount = Int(initialStatus.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedByteCount)
        var totalRead = 0
        var readError: Int32?
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            while totalRead < expectedByteCount {
                let count = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    expectedByteCount - totalRead,
                    off_t(totalRead)
                )
                if count > 0 {
                    totalRead += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    readError = errno
                    break
                }
            }
        }
        if let readError {
            throw RuntimeManifestError.manifestUnreadable(
                url,
                forgePlayTechnicalErrorSummary(
                    POSIXError(POSIXErrorCode(rawValue: readError) ?? .EIO)
                )
            )
        }
        guard totalRead == expectedByteCount else {
            throw RuntimeManifestError.manifestUnreadable(
                url,
                "manifest changed or became incomplete while it was being read"
            )
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw RuntimeManifestError.manifestUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        guard finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec else {
            throw RuntimeManifestError.manifestUnreadable(
                url,
                "manifest changed while it was being read"
            )
        }
        return Data(bytes)
    }

    private func validateFields(_ manifest: RuntimeManifest, at manifestURL: URL) throws {
        let supportsSchema = (1...RuntimeManifest.currentSchemaVersion).contains(manifest.schemaVersion)
        let hasCurrentHostSupportIdentity = manifest.schemaVersion == 1 || (
            manifest.hostSupportSBOMPath == "RuntimeSBOM.json" &&
                manifest.hostSupportSBOMSHA256.map(isSHA256) == true &&
                manifest.hostSupportPayloadFingerprint.map(isSHA256) == true
        )
        let corePayloads = manifest.corePayloadSHA256 ?? [:]
        let hasCurrentCorePayloadIdentity = manifest.schemaVersion < RuntimeManifest.currentSchemaVersion || (
            manifest.corePayloadHashAlgorithm == RuntimeManifest.currentCorePayloadHashAlgorithm &&
                Set(corePayloads.keys) == RuntimeManifest.requiredCorePayloadPaths &&
                corePayloads.values.allSatisfy(isSHA256) &&
                manifest.corePayloadFingerprint.map(isSHA256) == true &&
                manifest.corePayloadFingerprint == RuntimeManifest.corePayloadFingerprint(corePayloads)
        )
        guard supportsSchema,
              hasCurrentHostSupportIdentity,
              hasCurrentCorePayloadIdentity,
              !manifest.runtimeIdentifier.isEmpty,
              !manifest.wineVersion.isEmpty,
              manifest.architecture == WinePrefixDefaults.architecture,
              isSHA256(manifest.runnerLauncherSHA256),
              isSHA256(manifest.wineInfSHA256),
              isSHA256(manifest.winebootSHA256),
              isSHA256(manifest.prefixCompatibilityFingerprint),
              isSHA256(manifest.runnerBuildFingerprint),
              manifest.sourceTreeSHA256.map(isSHA256) ?? true,
              manifest.patchSetSHA256.map(isSHA256) ?? true else {
            throw RuntimeManifestError.invalidManifest(manifestURL, "required identity field is invalid")
        }

        let expectedPrefixFingerprint = RuntimeManifest.prefixCompatibilityFingerprint(
            wineVersion: manifest.wineVersion,
            architecture: manifest.architecture,
            wineInfSHA256: manifest.wineInfSHA256,
            winebootSHA256: manifest.winebootSHA256
        )
        let expectedBuildFingerprint = RuntimeManifest.runnerBuildFingerprint(
            sourceTreeSHA256: manifest.sourceTreeSHA256,
            patchSetSHA256: manifest.patchSetSHA256,
            runnerLauncherSHA256: manifest.runnerLauncherSHA256,
            prefixCompatibilityFingerprint: manifest.prefixCompatibilityFingerprint,
            hostSupportPayloadFingerprint: manifest.hostSupportPayloadFingerprint,
            corePayloadFingerprint: manifest.corePayloadFingerprint
        )
        guard manifest.prefixCompatibilityFingerprint == expectedPrefixFingerprint,
              manifest.runnerBuildFingerprint == expectedBuildFingerprint else {
            throw RuntimeManifestError.invalidManifest(manifestURL, "derived fingerprint does not match its inputs")
        }
    }

    private func derivedManifest(
        for executable: URL,
        permitsIncompletePayloadIdentity: Bool
    ) throws -> RuntimeManifest {
        let executableSHA256 = try sha256(of: executable)
        let runtimeRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
        let wineInf = runtimeRoot.appending(path: "share/wine/wine.inf")
        let wineboot = runtimeRoot.appending(path: "lib/wine/x86_64-windows/wineboot.exe")
        // A missing/unreadable component must never masquerade as the launcher
        // hash. Unmanaged runners remain representable, but an unavailable
        // payload receives a component-and-state-tagged fingerprint and an
        // explicit issue so support evidence cannot present it as verified.
        let wineInfIdentity = try derivedPayloadIdentity(
            for: wineInf,
            component: "wine.inf",
            permitsUnavailablePayload: permitsIncompletePayloadIdentity
        )
        let winebootIdentity = try derivedPayloadIdentity(
            for: wineboot,
            component: "wineboot.exe",
            permitsUnavailablePayload: permitsIncompletePayloadIdentity
        )
        let wineInfSHA256 = wineInfIdentity.fingerprint
        let winebootSHA256 = winebootIdentity.fingerprint
        let prefixFingerprint = RuntimeManifest.prefixCompatibilityFingerprint(
            wineVersion: "unmanaged",
            architecture: WinePrefixDefaults.architecture,
            wineInfSHA256: wineInfSHA256,
            winebootSHA256: winebootSHA256
        )
        let buildFingerprint = RuntimeManifest.runnerBuildFingerprint(
            sourceTreeSHA256: nil,
            patchSetSHA256: nil,
            runnerLauncherSHA256: executableSHA256,
            prefixCompatibilityFingerprint: prefixFingerprint
        )
        return RuntimeManifest(
            schemaVersion: 1,
            runtimeIdentifier: "derived-\(executableSHA256.prefix(16))",
            wineVersion: "unmanaged",
            architecture: WinePrefixDefaults.architecture,
            sourceTreeSHA256: nil,
            patchSetSHA256: nil,
            runnerLauncherSHA256: executableSHA256,
            wineInfSHA256: wineInfSHA256,
            winebootSHA256: winebootSHA256,
            prefixCompatibilityFingerprint: prefixFingerprint,
            runnerBuildFingerprint: buildFingerprint,
            identitySource: "derived",
            wineInfFingerprintState: wineInfIdentity.state,
            winebootFingerprintState: winebootIdentity.state,
            identityIssues: [wineInfIdentity.issue, winebootIdentity.issue].compactMap { $0 }
        )
    }

    private func derivedPayloadIdentity(
        for url: URL,
        component: String,
        permitsUnavailablePayload: Bool
    ) throws -> (fingerprint: String, state: String, issue: String?) {
        do {
            return (try sha256(of: url), "verified", nil)
        } catch {
            guard permitsUnavailablePayload else { throw error }
            let state: String
            switch error {
            case RuntimeManifestError.runtimePayloadMissing:
                state = "missing"
            case RuntimeManifestError.unsafeRuntimePayload:
                state = "unsafe"
            case RuntimeManifestError.runtimePayloadTooLarge:
                state = "tooLarge"
            case RuntimeManifestError.runtimePayloadUnreadable:
                state = "unreadable"
            default:
                state = "unreadable"
            }
            return (
                RuntimeManifest.unavailablePayloadFingerprint(component: component, state: state),
                state,
                "\(component) fingerprint \(state): \(forgePlayTechnicalErrorSummary(error))"
            )
        }
    }

    private func requireFingerprint(_ expected: String, for url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeManifestError.runtimePayloadMissing(url)
        }
        guard try sha256(of: url) == expected else {
            throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
        }
    }

    private func requireCorePayloadFingerprint(_ expected: String, for url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeManifestError.runtimePayloadMissing(url)
        }
        guard try corePayloadSHA256(of: url) == expected else {
            throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
        }
    }

    private func corePayloadSHA256(of url: URL) throws -> String {
        var data = try readStablePayloadData(at: url)
        guard data.count >= 32,
              littleEndianUInt32(in: data, at: 0) == 0xFEEDFACF else {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        guard let commandCount = littleEndianUInt32(in: data, at: 16),
              let commandByteCount = littleEndianUInt32(in: data, at: 20),
              commandCount <= commandByteCount / 8 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "Mach-O load-command header is invalid"
            )
        }
        let commandLimit = 32 + Int(commandByteCount)
        guard commandLimit <= data.count else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "Mach-O load commands exceed the payload"
            )
        }

        var commandOffset = 32
        var signatureOffset: Int?
        var linkEditFound = false
        for _ in 0..<commandCount {
            guard commandOffset <= commandLimit - 8,
                  let command = littleEndianUInt32(in: data, at: commandOffset),
                  let commandSizeValue = littleEndianUInt32(in: data, at: commandOffset + 4),
                  commandSizeValue >= 8 else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    url,
                    "Mach-O load-command header is truncated"
                )
            }
            let commandSize = Int(commandSizeValue)
            guard commandSize <= commandLimit - commandOffset else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    url,
                    "Mach-O load command exceeds its declared region"
                )
            }

            if command == 0x19 {
                guard commandSize >= 72 else {
                    throw RuntimeManifestError.runtimePayloadUnreadable(
                        url,
                        "Mach-O segment command is truncated"
                    )
                }
                let nameBytes = data[(commandOffset + 8)..<(commandOffset + 24)]
                let segmentName = String(
                    decoding: nameBytes.prefix { $0 != 0 },
                    as: UTF8.self
                )
                if segmentName == "__LINKEDIT" {
                    guard !linkEditFound else {
                        throw RuntimeManifestError.runtimePayloadUnreadable(
                            url,
                            "Mach-O contains duplicate __LINKEDIT segments"
                        )
                    }
                    linkEditFound = true
                    data.replaceSubrange(
                        (commandOffset + 32)..<(commandOffset + 40),
                        with: repeatElement(0, count: 8)
                    )
                    data.replaceSubrange(
                        (commandOffset + 48)..<(commandOffset + 56),
                        with: repeatElement(0, count: 8)
                    )
                }
            } else if command == 0x1D {
                guard commandSize == 16,
                      signatureOffset == nil,
                      let dataOffsetValue = littleEndianUInt32(
                        in: data,
                        at: commandOffset + 8
                      ),
                      let dataSizeValue = littleEndianUInt32(
                        in: data,
                        at: commandOffset + 12
                      ) else {
                    throw RuntimeManifestError.runtimePayloadUnreadable(
                        url,
                        "Mach-O code-signature command is invalid"
                    )
                }
                let dataOffset = Int(dataOffsetValue)
                let dataSize = Int(dataSizeValue)
                guard dataOffset >= commandLimit,
                      dataSize > 0,
                      dataOffset <= data.count,
                      dataSize <= data.count - dataOffset,
                      dataOffset + dataSize == data.count else {
                    throw RuntimeManifestError.runtimePayloadUnreadable(
                        url,
                        "Mach-O code-signature range is invalid"
                    )
                }
                signatureOffset = dataOffset
                data.replaceSubrange(
                    (commandOffset + 8)..<(commandOffset + 16),
                    with: repeatElement(0, count: 8)
                )
            }
            commandOffset += commandSize
        }

        guard commandOffset == commandLimit,
              linkEditFound,
              let signatureOffset else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "Mach-O payload lacks the replaceable code-signature contract"
            )
        }
        return SHA256.hash(data: data.prefix(signatureOffset))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            var value: UInt32 = 0
            memcpy(
                &value,
                baseAddress.advanced(by: offset),
                MemoryLayout<UInt32>.size
            )
            return UInt32(littleEndian: value)
        }
    }

    private func readStablePayloadData(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RuntimeManifestError.runtimePayloadMissing(url) }
            if errno == ELOOP { throw RuntimeManifestError.unsafeRuntimePayload(url) }
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1 else {
            throw RuntimeManifestError.unsafeRuntimePayload(url)
        }
        guard initialStatus.st_size >= 0 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(url, "file size unavailable")
        }
        guard UInt64(initialStatus.st_size) <= Self.maxHashedPayloadBytes else {
            throw RuntimeManifestError.runtimePayloadTooLarge(url)
        }

        let expectedByteCount = Int(initialStatus.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedByteCount)
        var totalRead = 0
        var readError: Int32?
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            while totalRead < expectedByteCount {
                let count = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    expectedByteCount - totalRead,
                    off_t(totalRead)
                )
                if count > 0 {
                    totalRead += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    readError = errno
                    break
                }
            }
        }
        if let readError {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(
                    POSIXError(POSIXErrorCode(rawValue: readError) ?? .EIO)
                )
            )
        }
        guard totalRead == expectedByteCount else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "payload changed or became incomplete while it was being read"
            )
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        guard finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "payload changed while its fingerprint was being read"
            )
        }
        return Data(bytes)
    }

    private func sha256(of url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RuntimeManifestError.runtimePayloadMissing(url) }
            if errno == ELOOP { throw RuntimeManifestError.unsafeRuntimePayload(url) }
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0 else {
            Darwin.close(descriptor)
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw RuntimeManifestError.unsafeRuntimePayload(url)
        }
        guard initialStatus.st_size >= 0 else {
            Darwin.close(descriptor)
            throw RuntimeManifestError.runtimePayloadUnreadable(url, "file size unavailable")
        }
        guard UInt64(initialStatus.st_size) <= Self.maxHashedPayloadBytes else {
            Darwin.close(descriptor)
            throw RuntimeManifestError.runtimePayloadTooLarge(url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                forgePlayTechnicalErrorSummary(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            )
        }
        guard finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "payload changed while its fingerprint was being read"
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (UnicodeScalar("0")...UnicodeScalar("9")).contains($0) ||
                (UnicodeScalar("a")...UnicodeScalar("f")).contains($0)
        }
    }
}
