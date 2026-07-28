import Darwin
import Foundation

enum FileSystemItemPolicyError: LocalizedError, Equatable {
    case notRegularNonSymlinkFile(URL)
    case notNonSymlinkDirectory(URL)
    case metadataReadFailed(URL, String)
    case unsafeManagedDirectory(URL, String)

    var errorDescription: String? {
        switch self {
        case .notRegularNonSymlinkFile(let url):
            "파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: \(url.path)"
        case .notNonSymlinkDirectory(let url):
            "폴더는 symlink가 아닌 디렉터리여야 합니다: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .unsafeManagedDirectory(let url, let message):
            "관리 경로를 안전하게 준비하지 못했습니다: \(url.path). \(message)"
        }
    }
}

enum FileSystemItemPolicy {
    nonisolated static func requireRegularNonSymlinkFile(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemItemPolicyError.notRegularNonSymlinkFile(url)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey]
            )
        } catch {
            throw FileSystemItemPolicyError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true,
              (values.linkCount ?? 1) == 1 else {
            throw FileSystemItemPolicyError.notRegularNonSymlinkFile(url)
        }
    }

    nonisolated static func isRegularNonSymlinkFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try requireRegularNonSymlinkFile(url, fileManager: fileManager)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func requireNonSymlinkDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(url)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        } catch {
            throw FileSystemItemPolicyError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        guard values.isSymbolicLink != true else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(url)
        }
    }

    nonisolated static func isNonSymlinkDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try requireNonSymlinkDirectory(url, fileManager: fileManager)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func hasOnlyNonSymlinkDirectoryComponents(
        from ancestor: URL,
        to descendant: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let ancestor = ancestor.standardizedFileURL
        let descendant = descendant.standardizedFileURL
        guard descendant.path == ancestor.path || descendant.path.hasPrefix("\(ancestor.path)/") else {
            return false
        }
        guard isNonSymlinkDirectory(ancestor, fileManager: fileManager) else {
            return false
        }

        let ancestorComponents = ancestor.pathComponents
        let parentComponents = descendant.deletingLastPathComponent().pathComponents
        guard parentComponents.count >= ancestorComponents.count else {
            return false
        }

        var current = ancestor
        for component in parentComponents.dropFirst(ancestorComponents.count) {
            current = current.appending(path: component, directoryHint: .isDirectory)
            guard isNonSymlinkDirectory(current, fileManager: fileManager) else {
                return false
            }
        }
        return true
    }

    /// Creates a descendant directory tree by walking file descriptors with
    /// `O_NOFOLLOW`. The selected number of trailing directories is normalized
    /// to owner-only permissions so IPC and evidence roots share one policy.
    nonisolated static func prepareOwnedDirectoryTree(
        _ directory: URL,
        trustedAncestor: URL,
        privateTailComponentCount: Int = 1
    ) throws {
        let normalizedDirectory = directory.standardizedFileURL
        let normalizedAncestor = trustedAncestor.standardizedFileURL
        let ancestorComponents = normalizedAncestor.pathComponents
        let directoryComponents = normalizedDirectory.pathComponents
        guard directoryComponents.count > ancestorComponents.count,
              Array(directoryComponents.prefix(ancestorComponents.count)) == ancestorComponents else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedDirectory,
                "경로가 허용된 저장소 범위 밖에 있습니다."
            )
        }

        let relativeComponents = directoryComponents.dropFirst(ancestorComponents.count)
        guard privateTailComponentCount >= 0,
              privateTailComponentCount <= relativeComponents.count else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedDirectory,
                "비공개 디렉터리 범위가 유효하지 않습니다."
            )
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var descriptor = Darwin.open(normalizedAncestor.path, directoryFlags)
        guard descriptor >= 0 else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedDirectory,
                String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(descriptor) }

        var ancestorStatus = stat()
        guard fstat(descriptor, &ancestorStatus) == 0,
              (ancestorStatus.st_mode & S_IFMT) == S_IFDIR,
              ancestorStatus.st_uid == geteuid() else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedDirectory,
                "허용된 저장소가 현재 사용자의 실제 디렉터리가 아닙니다."
            )
        }

        let privateStartIndex = relativeComponents.count - privateTailComponentCount
        for (index, component) in relativeComponents.enumerated() {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw FileSystemItemPolicyError.unsafeManagedDirectory(
                    normalizedDirectory,
                    "유효하지 않은 경로 구성요소가 있습니다."
                )
            }
            if mkdirat(descriptor, component, S_IRWXU) != 0, errno != EEXIST {
                throw FileSystemItemPolicyError.unsafeManagedDirectory(
                    normalizedDirectory,
                    String(cString: strerror(errno))
                )
            }

            let nextDescriptor = openat(descriptor, component, directoryFlags)
            guard nextDescriptor >= 0 else {
                throw FileSystemItemPolicyError.unsafeManagedDirectory(
                    normalizedDirectory,
                    String(cString: strerror(errno))
                )
            }

            var itemStatus = stat()
            guard fstat(nextDescriptor, &itemStatus) == 0,
                  (itemStatus.st_mode & S_IFMT) == S_IFDIR,
                  itemStatus.st_uid == geteuid() else {
                Darwin.close(nextDescriptor)
                throw FileSystemItemPolicyError.unsafeManagedDirectory(
                    normalizedDirectory,
                    "경로 구성요소가 현재 사용자의 실제 디렉터리가 아닙니다."
                )
            }
            if index >= privateStartIndex,
               fchmod(nextDescriptor, S_IRWXU) != 0 {
                let permissionError = String(cString: strerror(errno))
                Darwin.close(nextDescriptor)
                throw FileSystemItemPolicyError.unsafeManagedDirectory(
                    normalizedDirectory,
                    permissionError
                )
            }

            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }
    }

    /// Tightens an existing managed evidence file without creating it. The
    /// eventual writer may still create the file atomically with mode 0600.
    nonisolated static func normalizeExistingOwnedPrivateRegularFile(
        _ file: URL
    ) throws {
        let normalizedFile = file.standardizedFileURL
        let descriptor = Darwin.open(
            normalizedFile.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedFile,
                String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(descriptor) }

        var itemStatus = stat()
        guard fstat(descriptor, &itemStatus) == 0,
              (itemStatus.st_mode & S_IFMT) == S_IFREG,
              itemStatus.st_nlink == 1,
              itemStatus.st_uid == geteuid() else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedFile,
                "기존 파일이 현재 사용자의 단일 링크 일반 파일이 아닙니다."
            )
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                normalizedFile,
                String(cString: strerror(errno))
            )
        }
    }
}
