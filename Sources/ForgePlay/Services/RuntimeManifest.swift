import CryptoKit
import Darwin
import Foundation

struct RuntimeManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 3
    static let currentHostSupportSBOMSchemaVersion = 2
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
        "wine/lib/wine/i386-windows/mfplat.dll",
        "wine/lib/wine/i386-windows/winegstreamer.dll",
        "wine/lib/wine/x86_64-windows/ntdll.dll",
        "wine/lib/wine/x86_64-windows/kernelbase.dll",
        "wine/lib/wine/x86_64-windows/mfplat.dll",
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
    static let currentSchemaVersion = 2
    static let currentPrefixCompatibilityEpoch = 1

    var schemaVersion: Int
    var prefixCompatibilityEpoch: Int? = nil
    var runtimeIdentifier: String
    var runnerBuildFingerprint: String
    var prefixCompatibilityFingerprint: String
    var wineInfSHA256: String
    var appliedAt: Date

    init(manifest: RuntimeManifest, appliedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        prefixCompatibilityEpoch = Self.currentPrefixCompatibilityEpoch
        runtimeIdentifier = manifest.runtimeIdentifier
        runnerBuildFingerprint = manifest.runnerBuildFingerprint
        prefixCompatibilityFingerprint = manifest.prefixCompatibilityFingerprint
        wineInfSHA256 = manifest.wineInfSHA256
        self.appliedAt = appliedAt
    }

    func matches(_ manifest: RuntimeManifest) -> Bool {
        matchesPrefixCompatibility(manifest) &&
            runtimeIdentifier == manifest.runtimeIdentifier &&
            runnerBuildFingerprint == manifest.runnerBuildFingerprint
    }

    /// Prefix execution compatibility is an ABI/data-format contract, not a
    /// build-provenance identity. The epoch is the deliberate migration
    /// contract; wine.inf is the data input applied to the prefix. Rebuilt
    /// wineboot bytes and the aggregate compatibility fingerprint remain
    /// provenance/diagnostics and must not force migration on their own.
    func matchesPrefixCompatibility(_ manifest: RuntimeManifest) -> Bool {
        schemaVersion == Self.currentSchemaVersion &&
            prefixCompatibilityEpoch == Self.currentPrefixCompatibilityEpoch &&
            runtimeIdentifier == manifest.runtimeIdentifier &&
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

/// Immutable identity captured after manifest validation and re-opened at the
/// final process-launch boundary. This closes the gap in which either the
/// runtime root or launcher path could be replaced after their payload hashes
/// were validated.
struct RuntimeLaunchObjectIdentity: Hashable, Sendable {
    private static let descriptorBoundMinimumFD: Int32 = 200
    private static let descriptorBoundMaximumFD: Int32 = 4_096

    struct SpawnInvocation: Sendable {
        let executablePath: String
        let argumentPrefix: [String]
    }

    private final class CapabilityLease: @unchecked Sendable, Hashable {
        private enum LauncherFormat {
            case directExecutable
            case binShScript
        }

        let executableDescriptor: Int32
        let runtimeRootDescriptor: Int32
        let executableIdentity: FileIdentity
        let runtimeRootIdentity: FileIdentity
        private let executableURL: URL
        private let launcherFormat: LauncherFormat

        init(
            executable: URL,
            executableIdentity: FileIdentity,
            runtimeRoot: URL,
            runtimeRootIdentity: FileIdentity
        ) throws {
            let openedExecutable = try Self.open(
                executable,
                expectedType: S_IFREG,
                expectedIdentity: executableIdentity
            )
            let format: LauncherFormat
            do {
                format = try Self.launcherFormat(
                    descriptor: openedExecutable,
                    executable: executable,
                    byteCount: executableIdentity.byteCount
                )
            } catch {
                Darwin.close(openedExecutable)
                throw error
            }
            self.executableIdentity = executableIdentity
            self.runtimeRootIdentity = runtimeRootIdentity
            executableURL = executable.standardizedFileURL
            executableDescriptor = openedExecutable
            launcherFormat = format
            do {
                runtimeRootDescriptor = try Self.open(
                    runtimeRoot,
                    expectedType: S_IFDIR,
                    expectedIdentity: runtimeRootIdentity
                )
            } catch {
                Darwin.close(executableDescriptor)
                throw error
            }
        }

        deinit {
            Darwin.close(runtimeRootDescriptor)
            Darwin.close(executableDescriptor)
        }

        static func == (lhs: CapabilityLease, rhs: CapabilityLease) -> Bool {
            lhs === rhs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }

        func revalidate() throws {
            try Self.requireIdentity(
                descriptor: executableDescriptor,
                expectedType: S_IFREG,
                expectedIdentity: executableIdentity
            )
            try Self.requireIdentity(
                descriptor: runtimeRootDescriptor,
                expectedType: S_IFDIR,
                expectedIdentity: runtimeRootIdentity
            )
        }

        func installSpawnCapabilities(
            fileActions: inout posix_spawn_file_actions_t?,
            environment: inout [String: String],
            startingAt firstDescriptor: Int32
        ) throws -> (
            invocation: SpawnInvocation,
            nextDescriptor: Int32
        ) {
            try revalidate()
            let runtimeRootPath = try Self.currentAbsolutePath(
                descriptor: runtimeRootDescriptor
            )
            // Only the executable and runtime-root anchors are consumed by
            // the spawned entrypoint. Core/GStreamer payload descriptors were
            // previously inherited even though no child consumed them,
            // exhausting the normal macOS GUI soft FD limit. Those payloads
            // remain authenticated and are path/identity-revalidated by the
            // owning RuntimeLaunchObjectIdentity immediately before spawn.
            let retainedDescriptors = [
                executableDescriptor,
                runtimeRootDescriptor
            ]
            guard retainedDescriptors.allSatisfy({ descriptor in
                descriptor >= firstDescriptor &&
                    descriptor <= RuntimeLaunchObjectIdentity
                        .descriptorBoundMaximumFD
            }) else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    executableURL,
                    "retained runtime descriptors are outside the child capability range"
                )
            }
            for descriptor in retainedDescriptors {
                try Self.addInherit(&fileActions, descriptor: descriptor)
            }
            environment["FORGEPLAY_BOUND_EXECUTABLE_FD"] =
                String(executableDescriptor)
            environment["FORGEPLAY_BOUND_RUNTIME_ROOT_FD"] =
                String(runtimeRootDescriptor)
            environment["FORGEPLAY_BOUND_RUNTIME_ROOT_PATH"] = runtimeRootPath
            environment["FORGEPLAY_BOUND_RUNTIME_ROOT_IDENTITY"] =
                "\(runtimeRootIdentity.device):\(runtimeRootIdentity.inode)"
            let invocation: SpawnInvocation
            switch launcherFormat {
            case .directExecutable:
                // posix_spawn resolves its executable path before child file
                // actions run, so name the already-open parent descriptor.
                // Mach-O launch behavior therefore remains descriptor-direct.
                invocation = SpawnInvocation(
                    executablePath: "/dev/fd/\(executableDescriptor)",
                    argumentPrefix: [executableURL.path]
                )
            case .binShScript:
                // macOS cannot posix_spawn a script through /dev/fd. Execute
                // only the exact #!/bin/sh form with the trusted system shell.
                // The command is fixed and contains no caller-controlled text;
                // argv after it preserves the script's original $0 and $@.
                invocation = SpawnInvocation(
                    executablePath: "/bin/sh",
                    argumentPrefix: [
                        "/bin/sh",
                        "-c",
                        ". /dev/fd/\(executableDescriptor)",
                        executableURL.path
                    ]
                )
            }
            return (
                invocation,
                (retainedDescriptors.max() ?? firstDescriptor) + 1
            )
        }

        private static func launcherFormat(
            descriptor: Int32,
            executable: URL,
            byteCount: Int64
        ) throws -> LauncherFormat {
            let exactShellShebang = Array("#!/bin/sh".utf8)
            let prefixByteCount = min(
                Int(byteCount),
                exactShellShebang.count + 1
            )
            var prefix = [UInt8](repeating: 0, count: prefixByteCount)
            var offset = 0
            while offset < prefix.count {
                let remainingByteCount = prefix.count - offset
                let count = prefix.withUnsafeMutableBytes { bytes in
                    Darwin.pread(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        remainingByteCount,
                        off_t(offset)
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw RuntimeManifestError.runtimePayloadUnreadable(
                        executable,
                        "runtime launcher changed while reading its format"
                    )
                }
                offset += count
            }

            if prefix.starts(with: exactShellShebang),
               prefix.count == exactShellShebang.count ||
                prefix[exactShellShebang.count] == UInt8(ascii: "\n") {
                return .binShScript
            }
            if prefix.starts(with: Array("#!".utf8)) {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    executable,
                    "unsupported runtime launcher shebang"
                )
            }
            return .directExecutable
        }

        private static func currentAbsolutePath(
            descriptor: Int32
        ) throws -> String {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let errorNumber = buffer.withUnsafeMutableBufferPointer { bytes in
                ForgePlayRuntimeRootPathProjectionCopyCurrentPath(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            guard errorNumber == 0 else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    String(cString: strerror(errorNumber))
                )
            }
            guard let terminator = buffer.firstIndex(of: 0),
                  let path = String(
                    bytes: buffer[..<terminator].map {
                        UInt8(bitPattern: $0)
                    },
                    encoding: .utf8
                  ) else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    "retained runtime root returned an invalid UTF-8 path"
                )
            }
            guard path.hasPrefix("/") else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    "retained runtime root did not resolve to an absolute path"
                )
            }
            return path
        }

        private static func open(
            _ url: URL,
            expectedType: mode_t,
            expectedIdentity: FileIdentity
        ) throws -> Int32 {
            let openedDescriptor = Darwin.open(
                url.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
                    (expectedType == S_IFDIR ? O_DIRECTORY : 0)
            )
            guard openedDescriptor >= 0 else {
                throw RuntimeManifestError.unsafeRuntimePayload(url)
            }
            defer { Darwin.close(openedDescriptor) }
            let descriptor = Darwin.fcntl(
                openedDescriptor,
                F_DUPFD_CLOEXEC,
                RuntimeLaunchObjectIdentity.descriptorBoundMinimumFD
            )
            guard descriptor >= RuntimeLaunchObjectIdentity
                    .descriptorBoundMinimumFD,
                  descriptor <= RuntimeLaunchObjectIdentity
                    .descriptorBoundMaximumFD else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    url,
                    "could not reserve a bounded child capability descriptor"
                )
            }
            do {
                try requireIdentity(
                    descriptor: descriptor,
                    expectedType: expectedType,
                    expectedIdentity: expectedIdentity
                )
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        private static func requireIdentity(
            descriptor: Int32,
            expectedType: mode_t,
            expectedIdentity: FileIdentity?
        ) throws {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == expectedType,
                  expectedType == S_IFDIR || status.st_nlink == 1 else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    "retained runtime capability changed"
                )
            }
            let initialIdentity = RuntimeLaunchObjectIdentity.fileIdentity(
                status,
                contentSHA256: expectedIdentity?.contentSHA256
            )
            // The authenticated action context already hashed this exact
            // object. Most launches therefore need only fstat readback. If any
            // stable metadata changed, authenticate the changed bytes again
            // before accepting the descriptor.
            let contentSHA256: String?
            if expectedType == S_IFREG,
               expectedIdentity.map({
                   !RuntimeLaunchObjectIdentity.sameObjectMetadata(
                       initialIdentity,
                       $0
                   )
               }) ?? true {
                contentSHA256 = try RuntimeLaunchObjectIdentity.rawSHA256(
                    descriptor: descriptor,
                    expectedByteCount: Int64(status.st_size)
                )
            } else {
                contentSHA256 = expectedIdentity?.contentSHA256
            }
            var finalStatus = stat()
            guard fstat(descriptor, &finalStatus) == 0 else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    "retained runtime capability readback failed"
                )
            }
            if let expectedIdentity,
               !RuntimeLaunchObjectIdentity.authenticatedIdentityMatches(
                    RuntimeLaunchObjectIdentity.fileIdentity(
                    finalStatus,
                    contentSHA256: contentSHA256
                    ),
                    expectedIdentity
               ) {
                throw RuntimeManifestError.runtimePayloadFingerprintMismatch(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                )
            }
        }

        private static func addInherit(
            _ actions: inout posix_spawn_file_actions_t?,
            descriptor: Int32
        ) throws {
            let result = posix_spawn_file_actions_addinherit_np(
                &actions,
                descriptor
            )
            guard result == 0 else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    String(cString: strerror(result))
                )
            }
        }
    }

    fileprivate struct FileIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let contentSHA256: String?
    }

    private struct RetainedObjectIdentity: Hashable, Sendable {
        let url: URL
        let expectedType: UInt16
        let identity: FileIdentity
    }

    let runtimeRoot: URL
    let executable: URL
    private let runtimeRootIdentity: FileIdentity
    private let executableIdentity: FileIdentity
    private let retainedObjectIdentities: [RetainedObjectIdentity]
    private let capabilityLease: CapabilityLease

    fileprivate static func capture(
        runtimeRoot: URL,
        executable: URL,
        authenticatedCorePayloads: [String: FileIdentity] = [:],
        authenticatedAuxiliaryPayloads: [String: FileIdentity] = [:],
        authenticatedGStreamerPayloads:
            [RuntimeAuthenticatedGStreamerPayload] = []
    ) throws -> Self {
        let normalizedRoot = runtimeRoot.standardizedFileURL
        let fileManager = FileManager.default
        var retained: [RetainedObjectIdentity] = []
        for relativePath in RuntimeManifest.requiredCorePayloadPaths.sorted() {
            let candidate = normalizedRoot.appending(path: relativePath)
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw RuntimeManifestError.unsafeRuntimePayload(candidate)
            }
            retained.append(
                RetainedObjectIdentity(
                    url: candidate,
                    expectedType: UInt16(S_IFREG),
                    identity: try identity(
                        at: candidate,
                        expectedType: S_IFREG,
                        expectedIdentity: authenticatedCorePayloads[
                            relativePath
                        ]
                    )
                )
            )
        }
        for relativePath in authenticatedAuxiliaryPayloads.keys.sorted() {
            let candidate = normalizedRoot.appending(path: relativePath)
            retained.append(
                RetainedObjectIdentity(
                    url: candidate,
                    expectedType: UInt16(S_IFREG),
                    identity: try identity(
                        at: candidate,
                        expectedType: S_IFREG,
                        expectedIdentity:
                            authenticatedAuxiliaryPayloads[relativePath]
                    )
                )
            )
        }
        let gstreamerRelativePaths = [
            "wine/gstreamer",
            "wine/gstreamer/lib",
            "wine/gstreamer/lib/gstreamer-1.0"
        ]
        let hasGStreamerPayload = gstreamerRelativePaths.contains {
            fileManager.fileExists(
                atPath: normalizedRoot.appending(path: $0).path
            )
        }
        for relativePath in gstreamerRelativePaths where hasGStreamerPayload {
            let candidate = normalizedRoot.appending(path: relativePath)
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw RuntimeManifestError.unsafeRuntimePayload(candidate)
            }
            retained.append(
                RetainedObjectIdentity(
                    url: candidate,
                    expectedType: UInt16(S_IFDIR),
                    identity: try identity(
                        at: candidate,
                        expectedType: S_IFDIR
                    )
                )
            )
        }
        guard Set(authenticatedGStreamerPayloads.map(\.relativePath)).count ==
                authenticatedGStreamerPayloads.count else {
            throw RuntimeManifestError.invalidManifest(
                normalizedRoot.appending(path: "RuntimeSBOM.json"),
                "GStreamer SBOM contains duplicate runtime paths"
            )
        }
        for authenticated in authenticatedGStreamerPayloads.sorted(by: {
            $0.relativePath < $1.relativePath
        }) {
            let candidate = normalizedRoot.appending(
                path: authenticated.relativePath
            )
            retained.append(
                RetainedObjectIdentity(
                    url: candidate,
                    expectedType: UInt16(S_IFREG),
                    identity: try identity(
                        at: candidate,
                        expectedType: S_IFREG,
                        expectedIdentity: authenticated.identity
                    )
                )
            )
        }
        let rootIdentity = try identity(
            at: runtimeRoot,
            expectedType: S_IFDIR
        )
        let launchExecutableIdentity = try identity(
            at: executable,
            expectedType: S_IFREG,
            expectedIdentity: authenticatedCorePayloads[
                relativePath(
                    of: executable.standardizedFileURL,
                    under: normalizedRoot
                ) ?? ""
            ]
        )
        let lease = try CapabilityLease(
            executable: executable.standardizedFileURL,
            executableIdentity: launchExecutableIdentity,
            runtimeRoot: normalizedRoot,
            runtimeRootIdentity: rootIdentity
        )
        return Self(
            runtimeRoot: runtimeRoot.standardizedFileURL,
            executable: executable.standardizedFileURL,
            runtimeRootIdentity: rootIdentity,
            executableIdentity: launchExecutableIdentity,
            retainedObjectIdentities: retained,
            capabilityLease: lease
        )
    }

    func revalidate() throws {
        try capabilityLease.revalidate()
        guard Self.authenticatedIdentityMatches(
            try Self.identity(
                at: runtimeRoot,
                expectedType: S_IFDIR,
                expectedIdentity: runtimeRootIdentity
            ),
            runtimeRootIdentity
        ), Self.authenticatedIdentityMatches(
            try Self.identity(
                at: executable,
                expectedType: S_IFREG,
                expectedIdentity: executableIdentity
            ),
            executableIdentity
        ),
        try retainedObjectIdentities.allSatisfy({ retained in
            let expectedType = mode_t(retained.expectedType)
            return Self.authenticatedIdentityMatches(
                try Self.identity(
                    at: retained.url,
                    expectedType: expectedType,
                    expectedIdentity: retained.identity
                ),
                retained.identity
            )
        }) else {
            throw RuntimeManifestError.runtimePayloadFingerprintMismatch(
                executable
            )
        }
    }

    func installSpawnCapabilities(
        fileActions: inout posix_spawn_file_actions_t?,
        environment: inout [String: String],
        anchoredLibraryIdentity: CompatibilityAnchoredPathIdentityV1?
    ) throws -> SpawnInvocation {
        let runtimeProjection = try capabilityLease.installSpawnCapabilities(
            fileActions: &fileActions,
            environment: &environment,
            startingAt: Self.descriptorBoundMinimumFD
        )
        _ = try anchoredLibraryIdentity?.installSpawnCapabilities(
            fileActions: &fileActions,
            environment: &environment,
            startingAt: runtimeProjection.nextDescriptor
        )
        return runtimeProjection.invocation
    }

    private static func identity(
        at url: URL,
        expectedType: mode_t,
        expectedIdentity: FileIdentity? = nil
    ) throws -> FileIdentity {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
            (expectedType == S_IFDIR ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw RuntimeManifestError.unsafeRuntimePayload(url)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == expectedType,
              expectedType == S_IFDIR || status.st_nlink == 1 else {
            throw RuntimeManifestError.unsafeRuntimePayload(url)
        }
        let initialIdentity = fileIdentity(
            status,
            contentSHA256: expectedIdentity?.contentSHA256
        )
        let contentSHA256: String?
        if expectedType == S_IFREG,
           expectedIdentity.map({
               !sameObjectMetadata(initialIdentity, $0)
           }) ?? true {
            contentSHA256 = try rawSHA256(
                descriptor: descriptor,
                expectedByteCount: Int64(status.st_size)
            )
            guard expectedIdentity?.contentSHA256 == nil ||
                    contentSHA256 == expectedIdentity?.contentSHA256 else {
                throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
            }
        } else {
            contentSHA256 = expectedIdentity?.contentSHA256
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "runtime object readback failed"
            )
        }
        let finalIdentity = fileIdentity(
            finalStatus,
            contentSHA256: contentSHA256
        )
        guard finalIdentity.device == UInt64(status.st_dev),
              finalIdentity.inode == UInt64(status.st_ino),
              finalIdentity.byteCount == Int64(status.st_size),
              finalIdentity.modificationSeconds ==
                status.st_mtimespec.tv_sec,
              finalIdentity.modificationNanoseconds ==
                status.st_mtimespec.tv_nsec,
              finalIdentity.changeSeconds == status.st_ctimespec.tv_sec,
              finalIdentity.changeNanoseconds ==
                status.st_ctimespec.tv_nsec else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "runtime object changed while it was authenticated"
            )
        }
        guard expectedIdentity.map({
            authenticatedIdentityMatches(finalIdentity, $0)
        }) ?? true else {
            throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
        }
        return finalIdentity
    }

    fileprivate static func fileIdentity(
        _ status: stat,
        contentSHA256: String? = nil
    ) -> FileIdentity {
        FileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt16(status.st_mode & S_IFMT),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            contentSHA256: contentSHA256
        )
    }

    fileprivate static func sameObjectMetadata(
        _ lhs: FileIdentity,
        _ rhs: FileIdentity
    ) -> Bool {
        lhs.device == rhs.device &&
            lhs.inode == rhs.inode &&
            lhs.mode == rhs.mode &&
            lhs.byteCount == rhs.byteCount &&
            lhs.modificationSeconds == rhs.modificationSeconds &&
            lhs.modificationNanoseconds == rhs.modificationNanoseconds &&
            lhs.changeSeconds == rhs.changeSeconds &&
            lhs.changeNanoseconds == rhs.changeNanoseconds
    }

    fileprivate static func authenticatedIdentityMatches(
        _ observed: FileIdentity,
        _ expected: FileIdentity
    ) -> Bool {
        sameObjectMetadata(observed, expected) || (
            observed.mode == expected.mode &&
                observed.byteCount == expected.byteCount &&
                observed.contentSHA256 != nil &&
                observed.contentSHA256 == expected.contentSHA256
        )
    }

    private static func relativePath(
        of candidate: URL,
        under root: URL
    ) -> String? {
        let rootPrefix = root.standardizedFileURL.path + "/"
        let path = candidate.standardizedFileURL.path
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }

    private static func rawSHA256(
        descriptor: Int32,
        expectedByteCount: Int64
    ) throws -> String {
        guard expectedByteCount >= 0,
              expectedByteCount <= 512 * 1024 * 1024 else {
            throw RuntimeManifestError.runtimePayloadTooLarge(
                URL(fileURLWithPath: "/dev/fd/\(descriptor)")
            )
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < expectedByteCount {
            let requested = min(
                buffer.count,
                Int(expectedByteCount - offset)
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    "runtime object changed while hashing"
                )
            }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

fileprivate struct RuntimeAuthenticatedGStreamerPayload: Hashable, Sendable {
    let relativePath: String
    let identity: RuntimeLaunchObjectIdentity.FileIdentity
}

/// Cheap cache generation for the package-level objects that identify an
/// installed Runtime revision. Individual payload objects are still verified
/// against their authenticated digests when an action captures its launch
/// identity; this generation only prevents a legitimately replaced manifest,
/// SBOM, launcher, or Runtime root from leaving a process-lifetime stale cache.
private struct RuntimeAuthenticationGeneration: Sendable {
    private struct Snapshot: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let linkCount: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private let objects: [(URL, Snapshot)]

    static func capture(
        runtimeRoot: URL,
        executable: URL
    ) throws -> Self {
        var candidates: [(URL, mode_t)] = [
            (runtimeRoot.standardizedFileURL, S_IFDIR),
            (
                runtimeRoot.appending(path: "RuntimeManifest.json"),
                S_IFREG
            ),
            (executable.standardizedFileURL, S_IFREG)
        ]
        let sbom = runtimeRoot.appending(path: "RuntimeSBOM.json")
        var sbomStatus = stat()
        if Darwin.lstat(sbom.path, &sbomStatus) == 0 {
            candidates.append((sbom, S_IFREG))
        } else if errno != ENOENT {
            throw RuntimeManifestError.unsafeRuntimePayload(sbom)
        }
        return Self(
            objects: try candidates.map { url, expectedType in
                (url, try snapshot(at: url, expectedType: expectedType))
            }
        )
    }

    func matchesCurrentObjects() -> Bool {
        objects.allSatisfy { url, expected in
            (try? Self.snapshot(
                at: url,
                expectedType: mode_t(expected.mode)
            )) == expected
        }
    }

    func matches(_ other: Self) -> Bool {
        guard objects.count == other.objects.count else { return false }
        return zip(objects, other.objects).allSatisfy { lhs, rhs in
            lhs.0.standardizedFileURL.path ==
                rhs.0.standardizedFileURL.path && lhs.1 == rhs.1
        }
    }

    private static func snapshot(
        at url: URL,
        expectedType: mode_t
    ) throws -> Snapshot {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
                (expectedType == S_IFDIR ? O_DIRECTORY : 0)
        )
        guard descriptor >= 0 else {
            throw RuntimeManifestError.unsafeRuntimePayload(url)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == expectedType,
              expectedType == S_IFDIR || status.st_nlink == 1 else {
            throw RuntimeManifestError.unsafeRuntimePayload(url)
        }
        return Snapshot(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt16(status.st_mode & S_IFMT),
            linkCount: UInt64(status.st_nlink),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }
}

/// One process-lifetime authentication result for an immutable Runtime bundle.
/// It owns only value snapshots; every action opens fresh descriptors and
/// revalidates the current objects against these authenticated bytes.
struct RuntimeAuthenticatedContext: Sendable {
    let manifest: RuntimeManifest
    let runtimeRoot: URL
    fileprivate let authenticatedCorePayloads:
        [String: RuntimeLaunchObjectIdentity.FileIdentity]
    fileprivate let authenticatedAuxiliaryPayloads:
        [String: RuntimeLaunchObjectIdentity.FileIdentity]
    fileprivate let authenticatedGStreamerPayloads:
        [RuntimeAuthenticatedGStreamerPayload]
    private let cacheGeneration: RuntimeAuthenticationGeneration?

    init(
        manifest: RuntimeManifest,
        runtimeRoot: URL
    ) {
        self.manifest = manifest
        self.runtimeRoot = runtimeRoot.standardizedFileURL
        authenticatedCorePayloads = [:]
        authenticatedAuxiliaryPayloads = [:]
        authenticatedGStreamerPayloads = []
        cacheGeneration = try? RuntimeAuthenticationGeneration.capture(
            runtimeRoot: runtimeRoot,
            executable: runtimeRoot.appending(path: "wine/bin/wine")
        )
    }

    fileprivate init(
        manifest: RuntimeManifest,
        runtimeRoot: URL,
        authenticatedCorePayloads:
            [String: RuntimeLaunchObjectIdentity.FileIdentity],
        authenticatedAuxiliaryPayloads:
            [String: RuntimeLaunchObjectIdentity.FileIdentity],
        authenticatedGStreamerPayloads:
            [RuntimeAuthenticatedGStreamerPayload],
        cacheGeneration: RuntimeAuthenticationGeneration? = nil
    ) {
        self.manifest = manifest
        self.runtimeRoot = runtimeRoot.standardizedFileURL
        self.authenticatedCorePayloads = authenticatedCorePayloads
        self.authenticatedAuxiliaryPayloads =
            authenticatedAuxiliaryPayloads
        self.authenticatedGStreamerPayloads =
            authenticatedGStreamerPayloads
        self.cacheGeneration = cacheGeneration ??
            (try? RuntimeAuthenticationGeneration.capture(
                runtimeRoot: runtimeRoot,
                executable: runtimeRoot.appending(path: "wine/bin/wine")
            ))
    }

    func launchObjectIdentity(
        for executable: URL
    ) throws -> RuntimeLaunchObjectIdentity {
        try RuntimeLaunchObjectIdentity.capture(
            runtimeRoot: runtimeRoot,
            executable: executable,
            authenticatedCorePayloads: authenticatedCorePayloads,
            authenticatedAuxiliaryPayloads:
                authenticatedAuxiliaryPayloads,
            authenticatedGStreamerPayloads:
                authenticatedGStreamerPayloads
        )
    }

    fileprivate func matchesCurrentCacheGeneration() -> Bool {
        cacheGeneration?.matchesCurrentObjects() == true
    }
}

/// Coalesces the expensive payload authentication once per logical Runtime
/// executable and always performs the first scan away from MainActor.
actor RuntimeAuthenticationCache {
    typealias Authenticator = @Sendable (URL) throws ->
        RuntimeAuthenticatedContext

    static let shared = RuntimeAuthenticationCache()

    private let authenticator: Authenticator
    private var authenticatedByExecutable:
        [String: RuntimeAuthenticatedContext] = [:]
    private var inFlightByExecutable:
        [String: Task<RuntimeAuthenticatedContext, Error>] = [:]

    init(
        authenticator: @escaping Authenticator = { executable in
            try RuntimeManifestResolver().authenticatedContext(
                for: executable
            )
        }
    ) {
        self.authenticator = authenticator
    }

    func authenticatedContext(
        for executable: URL
    ) async throws -> RuntimeAuthenticatedContext {
        let normalized = executable.standardizedFileURL
        let key = normalized.path
        if let authenticated = authenticatedByExecutable[key] {
            if authenticated.matchesCurrentCacheGeneration() {
                return authenticated
            }
            authenticatedByExecutable.removeValue(forKey: key)
        }
        if let inFlight = inFlightByExecutable[key] {
            let authenticated = try await inFlight.value
            guard authenticated.matchesCurrentCacheGeneration() else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    normalized,
                    "Runtime package changed before an authenticated context waiter resumed"
                )
            }
            return authenticated
        }

        let authenticator = self.authenticator
        let task = Task.detached(priority: .userInitiated) {
            for _ in 0..<2 {
                let authenticated = try authenticator(normalized)
                if authenticated.matchesCurrentCacheGeneration() {
                    return authenticated
                }
            }
            throw RuntimeManifestError.runtimePayloadUnreadable(
                normalized,
                "Runtime package changed while its authenticated context was being established"
            )
        }
        inFlightByExecutable[key] = task
        do {
            let authenticated = try await task.value
            guard authenticated.matchesCurrentCacheGeneration() else {
                inFlightByExecutable.removeValue(forKey: key)
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    normalized,
                    "Runtime package changed before its authenticated context was committed"
                )
            }
            authenticatedByExecutable[key] = authenticated
            inFlightByExecutable.removeValue(forKey: key)
            return authenticated
        } catch {
            inFlightByExecutable.removeValue(forKey: key)
            throw error
        }
    }

    func invalidate(for executable: URL) {
        let key = executable.standardizedFileURL.path
        authenticatedByExecutable.removeValue(forKey: key)
        inFlightByExecutable[key]?.cancel()
        inFlightByExecutable.removeValue(forKey: key)
    }
}

protocol RuntimeManifestProviding {
    func manifest(for executable: URL) throws -> RuntimeManifest
}

private struct RuntimeSBOMIdentity: Decodable {
    struct HostSupportPayload: Decodable {
        var contentHashAlgorithm: String
        var contentSHA256: String
        var consumptionHashAlgorithm: String?
        var consumptionSHA256: String?
        var path: String
        var type: String
    }

    var schemaVersion: Int
    var runtimeIdentifier: String
    var payloadFingerprint: String
    var hostSupportPayload: [HostSupportPayload]
}

struct RuntimeManifestResolver: RuntimeManifestProviding {
    private struct AuthenticatedManifestResolution {
        let manifest: RuntimeManifest
        let runtimeRoot: URL
        let corePayloads:
            [String: RuntimeLaunchObjectIdentity.FileIdentity]
        let auxiliaryPayloads:
            [String: RuntimeLaunchObjectIdentity.FileIdentity]
        let gStreamerPayloads: [RuntimeAuthenticatedGStreamerPayload]
    }

    private static let maxManifestBytes = 256 * 1024
    private static let maxHashedPayloadBytes: UInt64 = 512 * 1024 * 1024
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func manifest(for executable: URL) throws -> RuntimeManifest {
        if let manifestURL = manifestURL(for: executable) {
            return try loadAuthenticatedManifest(
                at: manifestURL,
                executable: executable
            ).manifest
        }
        if ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(executable) {
            throw RuntimeManifestError.bundledManifestMissing(executable)
        }
        return try derivedManifest(for: executable, permitsIncompletePayloadIdentity: false)
    }

    func authenticatedContext(
        for executable: URL
    ) throws -> RuntimeAuthenticatedContext {
        if let manifestURL = manifestURL(for: executable) {
            let runtimeRoot = manifestURL.deletingLastPathComponent()
            let generationExecutable = runtimeRoot.appending(
                path: "wine/bin/wine"
            )
            let generationBefore = try RuntimeAuthenticationGeneration.capture(
                runtimeRoot: runtimeRoot,
                executable: generationExecutable
            )
            let resolution = try loadAuthenticatedManifest(
                at: manifestURL,
                executable: executable
            )
            let generationAfter = try RuntimeAuthenticationGeneration.capture(
                runtimeRoot: runtimeRoot,
                executable: generationExecutable
            )
            guard generationBefore.matches(generationAfter) else {
                throw RuntimeManifestError.runtimePayloadUnreadable(
                    manifestURL,
                    "Runtime package changed while its payloads were being authenticated"
                )
            }
            return RuntimeAuthenticatedContext(
                manifest: resolution.manifest,
                runtimeRoot: resolution.runtimeRoot,
                authenticatedCorePayloads: resolution.corePayloads,
                authenticatedAuxiliaryPayloads:
                    resolution.auxiliaryPayloads,
                authenticatedGStreamerPayloads:
                    resolution.gStreamerPayloads,
                cacheGeneration: generationAfter
            )
        }
        if ForgePlayBundledWindowsRuntimePolicy
            .isBundledRuntimeExecutable(executable) {
            throw RuntimeManifestError.bundledManifestMissing(executable)
        }
        let manifest = try derivedManifest(
            for: executable,
            permitsIncompletePayloadIdentity: false
        )
        let runtimeRoot = executable.standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return RuntimeAuthenticatedContext(
            manifest: manifest,
            runtimeRoot: runtimeRoot,
            authenticatedCorePayloads: [:],
            authenticatedAuxiliaryPayloads: [:],
            authenticatedGStreamerPayloads: []
        )
    }

    /// Captures the exact root and launcher objects whose manifest payload was
    /// just validated. Callers retain this value in their command and must
    /// revalidate it immediately before spawning.
    func launchObjectIdentity(
        for executable: URL
    ) throws -> RuntimeLaunchObjectIdentity {
        try authenticatedContext(for: executable)
            .launchObjectIdentity(for: executable)
    }

    /// Support evidence needs to explain an incomplete unmanaged runtime without
    /// turning that best-effort identity into an operational compatibility key.
    /// `manifest(for:)` remains strict for Prefix binding; only diagnostics call
    /// this method and receive component-tagged unavailable fingerprints.
    func diagnosticManifest(for executable: URL) throws -> RuntimeManifest {
        if let manifestURL = manifestURL(for: executable) {
            return try loadAuthenticatedManifest(
                at: manifestURL,
                executable: executable
            ).manifest
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

    private func loadAuthenticatedManifest(
        at manifestURL: URL,
        executable: URL
    ) throws -> AuthenticatedManifestResolution {
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
        var authenticatedAuxiliaryPayloads:
            [String: RuntimeLaunchObjectIdentity.FileIdentity] = [:]
        authenticatedAuxiliaryPayloads["wine/share/wine/wine.inf"] = try
            requireFingerprint(manifest.wineInfSHA256, for: wineInf)
        authenticatedAuxiliaryPayloads[
            "wine/lib/wine/x86_64-windows/wineboot.exe"
        ] = try requireFingerprint(manifest.winebootSHA256, for: wineboot)
        _ = try requireFingerprint(
            manifest.runnerLauncherSHA256,
            for: executable
        )
        var authenticatedGStreamerPayloads:
            [RuntimeAuthenticatedGStreamerPayload] = []
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
            guard sbomIdentity.schemaVersion ==
                    RuntimeManifest.currentHostSupportSBOMSchemaVersion,
                  sbomIdentity.runtimeIdentifier == manifest.runtimeIdentifier,
                  sbomIdentity.payloadFingerprint == expectedPayloadFingerprint else {
                throw RuntimeManifestError.invalidManifest(
                    manifestURL,
                    "host-support SBOM identity does not match the bundled manifest"
                )
            }
            authenticatedGStreamerPayloads = try authenticateGStreamerPayloads(
                sbomIdentity.hostSupportPayload,
                runtimeRoot: runtimeRoot,
                manifestURL: manifestURL
            )
        }
        var authenticatedCorePayloads:
            [String: RuntimeLaunchObjectIdentity.FileIdentity] = [:]
        if manifest.schemaVersion == RuntimeManifest.currentSchemaVersion,
           let corePayloads = manifest.corePayloadSHA256 {
            for path in RuntimeManifest.requiredCorePayloadPaths.sorted() {
                guard let expected = corePayloads[path] else {
                    throw RuntimeManifestError.invalidManifest(
                        manifestURL,
                        "core runtime payload identity is missing \(path)"
                    )
                }
                authenticatedCorePayloads[path] = try
                    requireCorePayloadFingerprint(
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
        return AuthenticatedManifestResolution(
            manifest: manifest,
            runtimeRoot: runtimeRoot,
            corePayloads: authenticatedCorePayloads,
            auxiliaryPayloads: authenticatedAuxiliaryPayloads,
            gStreamerPayloads: authenticatedGStreamerPayloads
        )
    }

    private func authenticateGStreamerPayloads(
        _ hostSupportPayload: [RuntimeSBOMIdentity.HostSupportPayload],
        runtimeRoot: URL,
        manifestURL: URL
    ) throws -> [RuntimeAuthenticatedGStreamerPayload] {
        let entries = hostSupportPayload.filter {
            $0.path.hasPrefix("wine/gstreamer/") &&
                $0.path.hasSuffix(".dylib")
        }
        guard !entries.isEmpty,
              Set(entries.map(\.path)).count == entries.count else {
            throw RuntimeManifestError.invalidManifest(
                manifestURL,
                "GStreamer SBOM file identity set is missing or ambiguous"
            )
        }

        let expectedPaths = Set(entries.map(\.path))
        let gstreamerRoot = runtimeRoot.appending(path: "wine/gstreamer")
        guard let enumerator = fileManager.enumerator(
            at: gstreamerRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw RuntimeManifestError.invalidManifest(
                manifestURL,
                "GStreamer runtime payload cannot be enumerated"
            )
        }
        var observedPaths = Set<String>()
        for case let candidate as URL in enumerator {
            guard candidate.pathExtension == "dylib" else { continue }
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw RuntimeManifestError.unsafeRuntimePayload(candidate)
            }
            let rootPrefix = runtimeRoot.standardizedFileURL.path + "/"
            let candidatePath = candidate.standardizedFileURL.path
            guard candidatePath.hasPrefix(rootPrefix) else {
                throw RuntimeManifestError.unsafeRuntimePayload(candidate)
            }
            observedPaths.insert(String(candidatePath.dropFirst(rootPrefix.count)))
        }
        guard observedPaths == expectedPaths else {
            throw RuntimeManifestError.invalidManifest(
                manifestURL,
                "GStreamer runtime file set differs from its SBOM"
            )
        }

        return try entries.sorted(by: { $0.path < $1.path }).map { entry in
            let components = entry.path.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard entry.type == "file",
                  components.count >= 4,
                  !entry.path.hasPrefix("/"),
                  !components.contains("."),
                  !components.contains(".."),
                  isSHA256(entry.contentSHA256),
                  entry.consumptionHashAlgorithm ==
                    RuntimeManifest.currentCorePayloadHashAlgorithm,
                  entry.consumptionSHA256.map(isSHA256) == true,
                  [
                    "sha256",
                    "sha256-after-canonical-adhoc-sign-and-remove-signature-v1"
                  ].contains(entry.contentHashAlgorithm) else {
                throw RuntimeManifestError.invalidManifest(
                    manifestURL,
                    "GStreamer SBOM entry is invalid: \(entry.path)"
                )
            }
            let url = runtimeRoot.appending(path: entry.path)
            let identity = try corePayloadIdentity(of: url)
            guard identity.canonicalSHA256 == entry.consumptionSHA256 else {
                throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
            }
            return RuntimeAuthenticatedGStreamerPayload(
                relativePath: entry.path,
                identity: identity.fileIdentity
            )
        }
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

    private func requireFingerprint(
        _ expected: String,
        for url: URL
    ) throws -> RuntimeLaunchObjectIdentity.FileIdentity {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeManifestError.runtimePayloadMissing(url)
        }
        let identity = try sha256Identity(of: url)
        guard identity.contentSHA256 == expected else {
            throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
        }
        return identity
    }

    private func requireCorePayloadFingerprint(
        _ expected: String,
        for url: URL
    ) throws -> RuntimeLaunchObjectIdentity.FileIdentity {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeManifestError.runtimePayloadMissing(url)
        }
        let identity = try corePayloadIdentity(of: url)
        guard identity.canonicalSHA256 == expected else {
            throw RuntimeManifestError.runtimePayloadFingerprintMismatch(url)
        }
        return identity.fileIdentity
    }

    private func corePayloadSHA256(of url: URL) throws -> String {
        try corePayloadIdentity(of: url).canonicalSHA256
    }

    private func corePayloadIdentity(
        of url: URL
    ) throws -> (
        canonicalSHA256: String,
        rawSHA256: String,
        fileIdentity: RuntimeLaunchObjectIdentity.FileIdentity
    ) {
        let stablePayload = try readStablePayloadData(at: url)
        var data = stablePayload.data
        let rawSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileIdentity = RuntimeLaunchObjectIdentity.FileIdentity(
            device: stablePayload.identity.device,
            inode: stablePayload.identity.inode,
            mode: stablePayload.identity.mode,
            byteCount: stablePayload.identity.byteCount,
            modificationSeconds:
                stablePayload.identity.modificationSeconds,
            modificationNanoseconds:
                stablePayload.identity.modificationNanoseconds,
            changeSeconds: stablePayload.identity.changeSeconds,
            changeNanoseconds: stablePayload.identity.changeNanoseconds,
            contentSHA256: rawSHA256
        )
        guard data.count >= 32,
              littleEndianUInt32(in: data, at: 0) == 0xFEEDFACF else {
            return (rawSHA256, rawSHA256, fileIdentity)
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
        let canonicalSHA256 = SHA256.hash(data: data.prefix(signatureOffset))
            .map { String(format: "%02x", $0) }
            .joined()
        return (canonicalSHA256, rawSHA256, fileIdentity)
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

    private struct StablePayloadData {
        let data: Data
        let identity: RuntimeLaunchObjectIdentity.FileIdentity
    }

    private func readStablePayloadData(
        at url: URL
    ) throws -> StablePayloadData {
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
              finalStatus.st_mode == initialStatus.st_mode,
              finalStatus.st_nlink == initialStatus.st_nlink,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec,
              finalStatus.st_ctimespec.tv_sec == initialStatus.st_ctimespec.tv_sec,
              finalStatus.st_ctimespec.tv_nsec == initialStatus.st_ctimespec.tv_nsec else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "payload changed while its fingerprint was being read"
            )
        }
        return StablePayloadData(
            data: Data(bytes),
            identity: RuntimeLaunchObjectIdentity.fileIdentity(initialStatus)
        )
    }

    private func sha256(of url: URL) throws -> String {
        guard let digest = try sha256Identity(of: url).contentSHA256 else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "payload digest is unavailable"
            )
        }
        return digest
    }

    private func sha256Identity(
        of url: URL
    ) throws -> RuntimeLaunchObjectIdentity.FileIdentity {
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
              finalStatus.st_mode == initialStatus.st_mode,
              finalStatus.st_nlink == initialStatus.st_nlink,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec,
              finalStatus.st_ctimespec.tv_sec == initialStatus.st_ctimespec.tv_sec,
              finalStatus.st_ctimespec.tv_nsec == initialStatus.st_ctimespec.tv_nsec else {
            throw RuntimeManifestError.runtimePayloadUnreadable(
                url,
                "payload changed while its fingerprint was being read"
            )
        }
        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return RuntimeLaunchObjectIdentity.fileIdentity(
            finalStatus,
            contentSHA256: digest
        )
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (UnicodeScalar("0")...UnicodeScalar("9")).contains($0) ||
                (UnicodeScalar("a")...UnicodeScalar("f")).contains($0)
        }
    }
}

/// ForgePlay-owned projection from the installed runtime manifest into the
/// immutable Windows execution capability contract. Capability declarations
/// remain explicit so an unrelated runtime payload cannot acquire authority by
/// merely being present in the bundle.
struct RuntimeWindowsExecutionCapabilityDeclaration: Hashable, Sendable {
    let lowercaseASCIIIdentifier: String
    let major: UInt16
    let minor: UInt16
    let owningCorePayloadPath: String
}

extension RuntimeManifest {
    func windowsExecutionCapabilityManifest(
        declarations: [RuntimeWindowsExecutionCapabilityDeclaration],
        supportedPEMachines: [WindowsPEMachine],
        serviceLedgerSchemaMajor: UInt16 = 1,
        serviceLedgerSchemaMinor: UInt16 = 0
    ) throws -> WindowsRuntimeExecutionManifestV1 {
        guard schemaVersion == Self.currentSchemaVersion,
              corePayloadHashAlgorithm ==
                Self.currentCorePayloadHashAlgorithm,
              let corePayloadSHA256,
              !declarations.isEmpty,
              declarations.count <= 16 else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .negotiation,
                detail: "runtime identity cannot project an authenticated capability manifest"
            )
        }
        let runtimeFingerprint = try WindowsExecutionSHA256(
            hexadecimal: runnerBuildFingerprint
        )
        var capabilities: [WindowsRuntimeExecutionCapability] = []
        capabilities.reserveCapacity(declarations.count)
        for declaration in declarations {
            guard Self.requiredCorePayloadPaths.contains(
                declaration.owningCorePayloadPath
            ),
            let payloadHex =
                corePayloadSHA256[declaration.owningCorePayloadPath] else {
                throw WindowsExecutionContractError(
                    reason: .capabilityFingerprintMismatch,
                    stage: .negotiation,
                    detail: "capability owner is absent from the authenticated core payload set"
                )
            }
            capabilities.append(
                try WindowsRuntimeExecutionCapability(
                    identifierSHA256:
                        WindowsExecutionCapabilityContract.identifierSHA256(
                            declaration.lowercaseASCIIIdentifier
                        ),
                    major: declaration.major,
                    minor: declaration.minor,
                    owningCorePayloadSHA256: WindowsExecutionSHA256(
                        hexadecimal: payloadHex
                    )
                )
            )
        }
        capabilities.sort { $0.identifierSHA256 < $1.identifierSHA256 }
        guard Set(capabilities.map(\.identifierSHA256)).count ==
                capabilities.count else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .negotiation,
                detail: "runtime capability declarations contain a duplicate"
            )
        }
        let machines = supportedPEMachines.sorted()
        return try WindowsRuntimeExecutionManifestV1(
            runtimeFingerprintSHA256: runtimeFingerprint,
            capabilities: capabilities,
            capabilitySetFingerprintSHA256:
                WindowsExecutionCapabilityContract
                    .runtimeCapabilitySetFingerprint(capabilities),
            supportedPEMachines: machines,
            serviceLedgerSchemaMajor: serviceLedgerSchemaMajor,
            serviceLedgerSchemaMinor: serviceLedgerSchemaMinor
        )
    }
}
