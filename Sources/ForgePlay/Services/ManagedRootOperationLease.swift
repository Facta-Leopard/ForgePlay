import CryptoKit
import Darwin
import Foundation

private enum ManagedRootLeasePurpose {
    case operation
    case runtimeOwnership

    var coordinationPrefix: String {
        switch self {
        case .operation: "managed-root"
        case .runtimeOwnership: "runtime-owner"
        }
    }
}

enum ManagedRootOperationLeaseError: LocalizedError, Equatable {
    case operationInProgress(URL)
    case unsafeLockFile(URL)
    case lockFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress(let url):
            "다른 ForgePlay 프로세스가 이 앱 데이터 위치를 사용 중입니다: \(url.path)"
        case .unsafeLockFile(let url):
            "앱 데이터 작업 잠금 파일이 안전한 일반 파일이 아닙니다: \(url.path)"
        case .lockFailed(let url, let message):
            "앱 데이터 작업 잠금을 준비하지 못했습니다: \(url.path). \(message)"
        }
    }
}

final class ManagedRootOperationLease: @unchecked Sendable {
    let lockURL: URL
    private let descriptorLock = NSLock()
    private var descriptor: Int32

    private init(lockURL: URL, descriptor: Int32) {
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    nonisolated static func coordinatedLockURL(
        forManagedRoot root: URL,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationSupportBaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        try coordinatedLockURL(
            forManagedRoot: root,
            purpose: .operation,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL,
            fileManager: fileManager
        )
    }

    nonisolated static func coordinatedRuntimeOwnershipLockURL(
        forManagedRoot root: URL,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationSupportBaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        try coordinatedLockURL(
            forManagedRoot: root,
            purpose: .runtimeOwnership,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL,
            fileManager: fileManager
        )
    }

    private nonisolated static func coordinatedLockURL(
        forManagedRoot root: URL,
        purpose: ManagedRootLeasePurpose,
        sandboxEnabled _: Bool,
        applicationSupportBaseURL: URL?,
        fileManager: FileManager
    ) throws -> URL {
        let defaultRoot: URL
        do {
            defaultRoot = try PathManager.defaultManagedRootURL(
                applicationSupportBaseURL: applicationSupportBaseURL,
                fileManager: fileManager
            )
        } catch {
            throw ManagedRootOperationLeaseError.lockFailed(
                root,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        let lockDirectory = defaultRoot
            .deletingLastPathComponent()
            .appending(path: "OperationLocks", directoryHint: .isDirectory)
        let identity = managedRootIdentity(root)
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return lockDirectory.appending(
            path: "\(purpose.coordinationPrefix)-\(digest).lock",
            directoryHint: .notDirectory
        )
    }

    nonisolated static func acquireExclusive(
        forManagedRoots roots: [URL],
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationSupportBaseURL: URL? = nil
    ) throws -> [ManagedRootOperationLease] {
        try acquireExclusive(
            forManagedRoots: roots,
            purpose: .operation,
            fileManager: fileManager,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL
        )
    }

    nonisolated static func acquireRuntimeOwnership(
        forManagedRoots roots: [URL],
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationSupportBaseURL: URL? = nil
    ) throws -> [ManagedRootOperationLease] {
        try acquireExclusive(
            forManagedRoots: roots,
            purpose: .runtimeOwnership,
            fileManager: fileManager,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL
        )
    }

    private nonisolated static func acquireExclusive(
        forManagedRoots roots: [URL],
        purpose: ManagedRootLeasePurpose,
        fileManager: FileManager,
        sandboxEnabled: Bool,
        applicationSupportBaseURL: URL?
    ) throws -> [ManagedRootOperationLease] {
        var rootsByLockPath: [String: URL] = [:]
        for root in roots {
            let standardizedRoot = root.standardizedFileURL
            let lockURL = try coordinatedLockURL(
                forManagedRoot: standardizedRoot,
                purpose: purpose,
                sandboxEnabled: sandboxEnabled,
                applicationSupportBaseURL: applicationSupportBaseURL,
                fileManager: fileManager
            )
            rootsByLockPath[lockURL.path] = standardizedRoot
        }

        var leases: [ManagedRootOperationLease] = []
        do {
            for lockPath in rootsByLockPath.keys.sorted() {
                guard let root = rootsByLockPath[lockPath] else { continue }
                leases.append(try acquireExclusive(
                    forManagedRoot: root,
                    purpose: purpose,
                    fileManager: fileManager,
                    sandboxEnabled: sandboxEnabled,
                    applicationSupportBaseURL: applicationSupportBaseURL
                ))
            }
            return leases
        } catch {
            leases.reversed().forEach { $0.release() }
            throw error
        }
    }

    nonisolated static func acquireExclusive(
        forManagedRoot root: URL,
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationSupportBaseURL: URL? = nil
    ) throws -> ManagedRootOperationLease {
        try acquireExclusive(
            forManagedRoot: root,
            purpose: .operation,
            fileManager: fileManager,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL
        )
    }

    nonisolated static func acquireRuntimeOwnership(
        forManagedRoot root: URL,
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationSupportBaseURL: URL? = nil
    ) throws -> ManagedRootOperationLease {
        try acquireExclusive(
            forManagedRoot: root,
            purpose: .runtimeOwnership,
            fileManager: fileManager,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL
        )
    }

    private nonisolated static func acquireExclusive(
        forManagedRoot root: URL,
        purpose: ManagedRootLeasePurpose,
        fileManager: FileManager,
        sandboxEnabled: Bool,
        applicationSupportBaseURL: URL?
    ) throws -> ManagedRootOperationLease {
        let lockURL = try coordinatedLockURL(
            forManagedRoot: root,
            purpose: purpose,
            sandboxEnabled: sandboxEnabled,
            applicationSupportBaseURL: applicationSupportBaseURL,
            fileManager: fileManager
        )
        let parent = lockURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw ManagedRootOperationLeaseError.lockFailed(
                    lockURL,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(parent, fileManager: fileManager) else {
            throw ManagedRootOperationLeaseError.unsafeLockFile(lockURL)
        }

        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ManagedRootOperationLeaseError.unsafeLockFile(lockURL)
            }
            throw ManagedRootOperationLeaseError.lockFailed(lockURL, String(cString: strerror(errno)))
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1 else {
            let failure = errno == 0 ? "lock path is not a single-link regular file" : String(cString: strerror(errno))
            close(descriptor)
            throw ManagedRootOperationLeaseError.lockFailed(lockURL, failure)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw ManagedRootOperationLeaseError.operationInProgress(lockURL)
            }
            throw ManagedRootOperationLeaseError.lockFailed(lockURL, String(cString: strerror(lockError)))
        }

        let lease = ManagedRootOperationLease(lockURL: lockURL, descriptor: descriptor)
        do {
            try lease.writeOwnerMetadata()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    nonisolated func release() {
        let descriptorToClose = descriptorLock.withLock { () -> Int32? in
            guard descriptor >= 0 else { return nil }
            let descriptorToClose = descriptor
            descriptor = -1
            return descriptorToClose
        }
        guard let descriptorToClose else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        _ = close(descriptorToClose)
    }

    private nonisolated func writeOwnerMetadata() throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw ManagedRootOperationLeaseError.lockFailed(lockURL, String(cString: strerror(errno)))
        }
        let payload = Data("pid=\(getpid())\n".utf8)
        let didWriteAllBytes = payload.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var totalWritten = 0
            while totalWritten < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: totalWritten),
                    bytes.count - totalWritten
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return false }
                totalWritten += written
            }
            return true
        }
        guard didWriteAllBytes, fsync(descriptor) == 0 else {
            throw ManagedRootOperationLeaseError.lockFailed(lockURL, String(cString: strerror(errno)))
        }
    }

    private nonisolated static func managedRootIdentity(_ root: URL) -> String {
        // A path key remains stable while the root is created. Inode-based keys do not.
        let normalizedPath = root.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return "path=\(normalizedPath)"
    }
}
