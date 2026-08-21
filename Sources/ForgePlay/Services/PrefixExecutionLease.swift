// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import CryptoKit
import Darwin
import Foundation

enum PrefixExecutionLeaseMode: String, Hashable, Sendable {
    case sharedExecution
    case exclusiveMutation
}

enum PrefixExecutionLeaseError: LocalizedError, Equatable {
    case conflictingOperation(URL, PrefixExecutionLeaseMode)
    case unsafeLockFile(URL)
    case lockFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .conflictingOperation(let url, let mode):
            switch mode {
            case .sharedExecution:
                "프리픽스 변경 작업이 진행 중이어서 게임 실행 세션에 참가할 수 없습니다: \(url.path)"
            case .exclusiveMutation:
                "Steam 또는 게임이 프리픽스를 사용 중이어서 변경할 수 없습니다: \(url.path)"
            }
        case .unsafeLockFile(let url):
            "프리픽스 실행 잠금 파일이 안전한 일반 파일이 아닙니다: \(url.path)"
        case .lockFailed(let url, let message):
            "프리픽스 실행 잠금을 준비하지 못했습니다: \(url.path). \(message)"
        }
    }
}

final class PrefixExecutionLease: @unchecked Sendable {
    nonisolated static let metadataHeader = "FORGEPLAY_PREFIX_EXECUTION_LEASE_V1"
    nonisolated static let maximumMetadataBytes = 1_024

    let lockURL: URL

    private let descriptorLock = NSLock()
    private let prefixURL: URL
    private let fileManager: FileManager
    private var descriptor: Int32
    private var currentMode: PrefixExecutionLeaseMode

    var mode: PrefixExecutionLeaseMode {
        descriptorLock.withLock { currentMode }
    }

    private init(
        lockURL: URL,
        prefixURL: URL,
        fileManager: FileManager,
        mode: PrefixExecutionLeaseMode,
        descriptor: Int32
    ) {
        self.lockURL = lockURL
        self.prefixURL = prefixURL
        self.fileManager = fileManager
        self.descriptor = descriptor
        currentMode = mode
    }

    deinit {
        release()
    }

    nonisolated static func coordinatedLockURL(
        forPrefix prefix: URL,
        applicationSupportBaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupportBaseURL = try applicationSupportBaseURL
            ?? defaultCoordinationApplicationSupportURL(fileManager: fileManager)
        let defaultRoot: URL
        do {
            defaultRoot = try PathManager.defaultManagedRootURL(
                applicationSupportBaseURL: applicationSupportBaseURL,
                fileManager: fileManager
            )
        } catch {
            throw PrefixExecutionLeaseError.lockFailed(
                prefix,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        let lockDirectory = defaultRoot
            .deletingLastPathComponent()
            .appending(path: "OperationLocks", directoryHint: .isDirectory)
        let normalizedPath = prefix.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let digest = SHA256.hash(data: Data("prefix=\(normalizedPath)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return lockDirectory.appending(
            path: "prefix-execution-\(digest).lock",
            directoryHint: .notDirectory
        )
    }

    nonisolated static func defaultCoordinationApplicationSupportURL(
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationGroupIdentifier: String? =
            ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
        applicationGroupContainerResolver: ((String) -> URL?)? = nil
    ) throws -> URL {
        let normalizedGroupIdentifier = applicationGroupIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedGroupIdentifier,
           !normalizedGroupIdentifier.isEmpty,
           !normalizedGroupIdentifier.contains("$(") {
            let groupContainer: URL?
            if let applicationGroupContainerResolver {
                groupContainer = applicationGroupContainerResolver(
                    normalizedGroupIdentifier
                )
            } else {
                groupContainer = fileManager.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        normalizedGroupIdentifier
                )
            }
            guard let groupContainer else {
                throw PathManagerError.validationFailed(
                    nil,
                    "Game Mode App Group container is unavailable: " +
                        normalizedGroupIdentifier
                )
            }
            return groupContainer
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .standardizedFileURL
        }
        if sandboxEnabled {
            throw PathManagerError.validationFailed(
                nil,
                "Game Mode App Group identifier is unavailable"
            )
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PathManagerError.applicationSupportUnavailable
        }
        return applicationSupport.standardizedFileURL
    }

    nonisolated static func acquireSharedExecution(
        forPrefix prefix: URL,
        fileManager: FileManager = .default,
        applicationSupportBaseURL: URL? = nil
    ) throws -> PrefixExecutionLease {
        try acquire(
            forPrefix: prefix,
            mode: .sharedExecution,
            fileManager: fileManager,
            applicationSupportBaseURL: applicationSupportBaseURL
        )
    }

    nonisolated static func acquireExclusiveMutation(
        forPrefix prefix: URL,
        fileManager: FileManager = .default,
        applicationSupportBaseURL: URL? = nil
    ) throws -> PrefixExecutionLease {
        try acquire(
            forPrefix: prefix,
            mode: .exclusiveMutation,
            fileManager: fileManager,
            applicationSupportBaseURL: applicationSupportBaseURL
        )
    }

    private nonisolated static func acquire(
        forPrefix prefix: URL,
        mode: PrefixExecutionLeaseMode,
        fileManager: FileManager,
        applicationSupportBaseURL: URL?
    ) throws -> PrefixExecutionLease {
        let lockURL = try coordinatedLockURL(
            forPrefix: prefix,
            applicationSupportBaseURL: applicationSupportBaseURL,
            fileManager: fileManager
        )
        let parent = lockURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw PrefixExecutionLeaseError.lockFailed(
                    lockURL,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(parent, fileManager: fileManager) else {
            throw PrefixExecutionLeaseError.unsafeLockFile(lockURL)
        }

        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw PrefixExecutionLeaseError.unsafeLockFile(lockURL)
            }
            throw PrefixExecutionLeaseError.lockFailed(
                lockURL,
                String(cString: strerror(errno))
            )
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1,
              fileStatus.st_uid == geteuid() else {
            let failure = errno == 0
                ? "lock path is not a single-link regular file owned by the current user"
                : String(cString: strerror(errno))
            close(descriptor)
            throw PrefixExecutionLeaseError.lockFailed(lockURL, failure)
        }

        let requestedOperation = mode == .sharedExecution ? LOCK_SH : LOCK_EX
        var acquiredOperation = LOCK_EX
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard mode == .sharedExecution,
                  (lockError == EWOULDBLOCK || lockError == EAGAIN),
                  flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                let finalLockError = errno
                close(descriptor)
                if lockError == EWOULDBLOCK || lockError == EAGAIN ||
                    finalLockError == EWOULDBLOCK || finalLockError == EAGAIN {
                    throw PrefixExecutionLeaseError.conflictingOperation(lockURL, mode)
                }
                throw PrefixExecutionLeaseError.lockFailed(
                    lockURL,
                    String(cString: strerror(finalLockError))
                )
            }
            acquiredOperation = LOCK_SH
        }

        if (fileStatus.st_mode & mode_t(0o777)) != (S_IRUSR | S_IWUSR) {
            guard acquiredOperation == LOCK_EX,
                  fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                throw PrefixExecutionLeaseError.unsafeLockFile(lockURL)
            }
        }

        do {
            try validateOrInitializeMetadata(
                descriptor: descriptor,
                prefix: prefix,
                mayInitialize: acquiredOperation == LOCK_EX,
                lockURL: lockURL,
                fileManager: fileManager
            )
        } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }

        if requestedOperation == LOCK_SH && acquiredOperation == LOCK_EX,
           flock(descriptor, LOCK_SH | LOCK_NB) != 0 {
            let lockError = errno
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw PrefixExecutionLeaseError.lockFailed(
                lockURL,
                String(cString: strerror(lockError))
            )
        }
        return PrefixExecutionLease(
            lockURL: lockURL,
            prefixURL: prefix.standardizedFileURL,
            fileManager: fileManager,
            mode: mode,
            descriptor: descriptor
        )
    }

    private nonisolated static func validateOrInitializeMetadata(
        descriptor: Int32,
        prefix: URL,
        mayInitialize: Bool,
        lockURL: URL,
        fileManager: FileManager
    ) throws {
        let identity = try prefixIdentity(prefix, fileManager: fileManager)
        let expected = "\(metadataHeader)\ndevice=\(identity.device)\ninode=\(identity.inode)\n"
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw PrefixExecutionLeaseError.lockFailed(
                lockURL,
                String(cString: strerror(errno))
            )
        }
        guard status.st_size >= 0,
              status.st_size <= maximumMetadataBytes else {
            throw PrefixExecutionLeaseError.unsafeLockFile(lockURL)
        }

        if status.st_size > 0 {
            var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            if readCount == bytes.count,
               String(decoding: bytes, as: UTF8.self) == expected {
                return
            }
        }

        // A prefix rebuild may replace the directory inode. Rebind only while
        // this descriptor owns the exclusive lock; a live game host holds a
        // shared lock and prevents this branch from being reached.
        guard mayInitialize else {
            throw PrefixExecutionLeaseError.unsafeLockFile(lockURL)
        }
        let bytes = Array(expected.utf8)
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0,
              writeAll(bytes, to: descriptor),
              fsync(descriptor) == 0 else {
            throw PrefixExecutionLeaseError.lockFailed(
                lockURL,
                String(cString: strerror(errno))
            )
        }
    }

    private nonisolated static func prefixIdentity(
        _ prefix: URL,
        fileManager: FileManager
    ) throws -> (device: UInt64, inode: UInt64) {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(prefix, fileManager: fileManager) else {
            throw PrefixExecutionLeaseError.lockFailed(
                prefix,
                "prefix is not a non-symlink directory"
            )
        }
        var status = stat()
        guard lstat(prefix.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw PrefixExecutionLeaseError.lockFailed(
                prefix,
                String(cString: strerror(errno))
            )
        }
        return (UInt64(status.st_dev), UInt64(status.st_ino))
    }

    private nonisolated static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
    }

    /// Converts the current lock immediately before a prepared Steam launch.
    /// Existing Game Mode hosts may join the shared lease after this point.
    func transitionToSharedExecution() throws {
        try transition(to: .sharedExecution)
    }

    /// Converts a shared launch lease back to mutation ownership only after
    /// the launched Wine session has been proven stopped. A live host keeps a
    /// shared lease and makes this nonblocking upgrade fail.
    func transitionToExclusiveMutation() throws {
        try transition(to: .exclusiveMutation)
    }

    private func transition(to targetMode: PrefixExecutionLeaseMode) throws {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        guard descriptor >= 0 else {
            throw PrefixExecutionLeaseError.lockFailed(lockURL, "lease is already released")
        }
        guard currentMode != targetMode else { return }

        if targetMode == .sharedExecution {
            // An exclusive prefix operation may atomically replace the
            // directory while retaining this path-scoped lock. Rebind the
            // metadata to the replacement inode before any Game Mode child
            // can join the shared lease. Otherwise the native host correctly
            // rejects the stale identity and Steam reports a process-start
            // failure even though the replacement was owned by this lease.
            try Self.validateOrInitializeMetadata(
                descriptor: descriptor,
                prefix: prefixURL,
                mayInitialize: true,
                lockURL: lockURL,
                fileManager: fileManager
            )
        }

        let operation = targetMode == .sharedExecution ? LOCK_SH : LOCK_EX
        guard flock(descriptor, operation | LOCK_NB) == 0 else {
            let transitionError = errno
            if targetMode == .exclusiveMutation,
               (transitionError == EWOULDBLOCK || transitionError == EAGAIN),
               flock(descriptor, LOCK_SH | LOCK_NB) != 0 {
                let recoveryError = errno
                let descriptorToClose = descriptor
                descriptor = -1
                _ = close(descriptorToClose)
                throw PrefixExecutionLeaseError.lockFailed(
                    lockURL,
                    "shared lease recovery failed: \(String(cString: strerror(recoveryError)))"
                )
            }
            if transitionError == EWOULDBLOCK || transitionError == EAGAIN {
                throw PrefixExecutionLeaseError.conflictingOperation(lockURL, targetMode)
            }
            throw PrefixExecutionLeaseError.lockFailed(
                lockURL,
                String(cString: strerror(transitionError))
            )
        }
        currentMode = targetMode
    }

    nonisolated func release() {
        let descriptorToClose = descriptorLock.withLock { () -> Int32? in
            guard descriptor >= 0 else { return nil }
            let value = descriptor
            descriptor = -1
            return value
        }
        guard let descriptorToClose else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        _ = close(descriptorToClose)
    }
}

/// Explicit ownership adapter for the Windows helper control plane. The scope
/// digest is supplied by the already-authenticated prepared bootstrap; the
/// path lock itself is never reinterpreted as cryptographic identity.
final class WindowsHelperPrefixExecutionLeaseOwnership:
    WindowsHelperPrefixLeaseOwning,
    @unchecked Sendable {
    let windowsHelperLeaseScopeSHA256: WindowsExecutionSHA256

    private let lock = NSLock()
    private var lease: PrefixExecutionLease?

    init(
        lease: PrefixExecutionLease,
        preparedPrefixScopeSHA256: WindowsExecutionSHA256
    ) throws {
        guard !preparedPrefixScopeSHA256.isZero else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .lifecycle,
                detail: "prefix lease ownership requires a prepared scope"
            )
        }
        self.lease = lease
        windowsHelperLeaseScopeSHA256 = preparedPrefixScopeSHA256
    }

    func releaseWindowsHelperLease() async throws {
        let ownedLease = lock.withLock { () -> PrefixExecutionLease? in
            defer { lease = nil }
            return lease
        }
        ownedLease?.release()
    }

    var isReleased: Bool {
        lock.withLock { lease == nil }
    }
}

extension PrefixExecutionLease {
    func windowsHelperOwnership(
        preparedPrefixScopeSHA256: WindowsExecutionSHA256
    ) throws -> WindowsHelperPrefixExecutionLeaseOwnership {
        try WindowsHelperPrefixExecutionLeaseOwnership(
            lease: self,
            preparedPrefixScopeSHA256: preparedPrefixScopeSHA256
        )
    }
}
