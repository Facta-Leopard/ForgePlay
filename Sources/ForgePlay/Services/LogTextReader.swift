import Darwin
import Foundation

enum LogTextReaderError: LocalizedError, Equatable {
    case unsafeLogFile(URL)
    case scanFailed(URL, String)
    case metadataReadFailed(URL, String)
    case textDecodeFailed(URL)
    case changedDuringRead(URL)

    var errorDescription: String? {
        switch self {
        case .unsafeLogFile(let url):
            "로그 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: \(url.path)"
        case .scanFailed(let url, let message):
            "최근 로그 폴더를 검사하지 못했습니다: \(url.path). \(message)"
        case .metadataReadFailed(let url, let message):
            "최근 로그 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .textDecodeFailed(let url):
            "최근 로그 파일을 UTF-8 텍스트로 읽지 못했습니다: \(url.path)"
        case .changedDuringRead(let url):
            "최근 로그 파일이 읽는 동안 변경되어 일관된 스냅샷을 만들지 못했습니다: \(url.path)"
        }
    }
}

struct DiagnosticLogSnapshot {
    var text: String
    var readError: Error?
}

enum DiagnosticWarningText {
    static func combined(_ warnings: String?...) -> String? {
        let lines = warnings
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

enum LogTextReader {
    private struct CompiledExpression: @unchecked Sendable {
        let value: NSRegularExpression

        init(pattern: String) throws {
            value = try NSRegularExpression(pattern: pattern)
        }
    }

    private struct BoundedTextSnapshot {
        var text: String
        var changedDuringRead: Bool
    }

    private struct DescriptorMetadata: Equatable {
        var device: UInt64
        var inode: UInt64
        var byteCount: UInt64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64
    }

    static func combinedTrailingTextStrict(
        from urls: [URL],
        maxBytesPerFile: Int = 256_000,
        maxTotalCharacters: Int = 800_000
    ) throws -> String {
        let boundedCharacterLimit = max(maxTotalCharacters, 0)
        var output = ""
        for url in urls {
            guard output.count < boundedCharacterLimit else { break }
            let text = try trailingText(from: url, maxBytes: maxBytesPerFile)
            output += output.isEmpty ? text : "\n\(text)"
        }
        return String(output.prefix(boundedCharacterLimit))
    }

    static func diagnosticSnapshot(
        from urls: [URL],
        maxBytesPerFile: Int = 256_000,
        maxTotalCharacters: Int = 800_000
    ) -> DiagnosticLogSnapshot {
        do {
            return DiagnosticLogSnapshot(
                text: try combinedDiagnosticTextStrict(
                    from: urls,
                    maxBytesPerFile: maxBytesPerFile,
                    maxTotalCharacters: maxTotalCharacters
                ),
                readError: nil
            )
        } catch {
            return DiagnosticLogSnapshot(
                text: "",
                readError: error
            )
        }
    }

    static func tolerantDiagnosticSnapshot(
        from urls: [URL],
        maxBytesPerFile: Int = 256_000,
        maxTotalCharacters: Int = 800_000
    ) -> DiagnosticLogSnapshot {
        let boundedCharacterLimit = max(maxTotalCharacters, 0)
        var output = ""
        var firstReadError: Error?

        for (index, url) in urls.enumerated() {
            guard output.count < boundedCharacterLimit else { break }
            let text: String
            do {
                let snapshot = try diagnosticTextSnapshot(
                    from: url,
                    maxBytes: maxBytesPerFile,
                    lossy: false
                )
                text = snapshot.text
                if snapshot.changedDuringRead, firstReadError == nil {
                    firstReadError = LogTextReaderError.changedDuringRead(url)
                }
            } catch LogTextReaderError.textDecodeFailed {
                do {
                    let snapshot = try diagnosticTextSnapshot(
                        from: url,
                        maxBytes: maxBytesPerFile,
                        lossy: true
                    )
                    text = snapshot.text
                    if firstReadError == nil {
                        firstReadError = LogTextReaderError.textDecodeFailed(url)
                    }
                } catch {
                    if firstReadError == nil { firstReadError = error }
                    continue
                }
            } catch {
                if firstReadError == nil { firstReadError = error }
                continue
            }

            let header = "===== ForgePlay diagnostic artifact \(index + 1): \(url.lastPathComponent) ====="
            let fragment = "\(header)\n\(text)"
            output += output.isEmpty ? fragment : "\n\(fragment)"
        }

        return DiagnosticLogSnapshot(
            text: String(output.prefix(boundedCharacterLimit)),
            readError: firstReadError
        )
    }

    static func combinedDiagnosticTextStrict(
        from urls: [URL],
        maxBytesPerFile: Int = 256_000,
        maxTotalCharacters: Int = 800_000
    ) throws -> String {
        let boundedCharacterLimit = max(maxTotalCharacters, 0)
        var output = ""
        for url in urls {
            guard output.count < boundedCharacterLimit else { break }
            let text = try diagnosticText(from: url, maxBytes: maxBytesPerFile)
            output += output.isEmpty ? text : "\n\(text)"
        }
        return String(output.prefix(boundedCharacterLimit))
    }

    static func recentLogFiles(
        under logsRoot: URL,
        maxFiles: Int = 8,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: logsRoot.path) else {
            throw LogTextReaderError.scanFailed(
                logsRoot,
                forgePlayTechnicalErrorSummary(POSIXError(.ENOENT))
            )
        }
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(
                logsRoot,
                fileManager: fileManager
            )
        } catch {
            throw LogTextReaderError.scanFailed(
                logsRoot,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: logsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .linkCountKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LogTextReaderError.scanFailed(logsRoot, forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown)))
        }

        var files: [(url: URL, modificationDate: Date)] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .linkCountKey]
                )
            } catch {
                throw LogTextReaderError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                throw LogTextReaderError.unsafeLogFile(url)
            }
            guard ["log", "txt"].contains(url.pathExtension.lowercased()) else {
                continue
            }
            guard values.isRegularFile == true else {
                throw LogTextReaderError.unsafeLogFile(url)
            }
            if isHardlinkedRegularFile(values) {
                throw LogTextReaderError.unsafeLogFile(url)
            }
            guard let modificationDate = values.contentModificationDate else {
                throw LogTextReaderError.metadataReadFailed(
                    url,
                    forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown))
                )
            }
            files.append((url, modificationDate))
        }
        if let enumerationError {
            throw LogTextReaderError.scanFailed(logsRoot, forgePlayTechnicalErrorSummary(enumerationError))
        }
        return files
            .sorted { $0.modificationDate > $1.modificationDate }
            .prefix(max(maxFiles, 0))
            .map(\.url)
    }

    /// Selects evidence from one execution instead of mixing unrelated recent
    /// stdout/stderr/diagnostic files. SafeProcessRunner embeds a UUID in every
    /// run path; legacy files fall back to a normalized basename correlation key.
    static func mostRecentRunLogFiles(
        under logsRoot: URL,
        maxFiles: Int = 8,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let boundedMaxFiles = max(maxFiles, 0)
        guard boundedMaxFiles > 0 else { return [] }
        let candidates = try recentLogFiles(
            under: logsRoot,
            maxFiles: max(64, boundedMaxFiles * 8),
            fileManager: fileManager
        )
        guard let newest = candidates.first,
              let correlationKey = runCorrelationKey(for: newest, relativeTo: logsRoot) else {
            return Array(candidates.prefix(1))
        }
        return Array(candidates.lazy
            .filter { runCorrelationKey(for: $0, relativeTo: logsRoot) == correlationKey }
            .prefix(boundedMaxFiles))
    }

    static func trailingText(from url: URL, maxBytes: Int = 256_000) throws -> String {
        let snapshot = try trailingTextSnapshot(from: url, maxBytes: maxBytes, lossy: false)
        guard !snapshot.changedDuringRead else {
            throw LogTextReaderError.changedDuringRead(url)
        }
        return snapshot.text
    }

    private static func diagnosticText(from url: URL, maxBytes: Int) throws -> String {
        let snapshot = try diagnosticTextSnapshot(from: url, maxBytes: maxBytes, lossy: false)
        guard !snapshot.changedDuringRead else {
            throw LogTextReaderError.changedDuringRead(url)
        }
        return snapshot.text
    }

    private static func diagnosticTextSnapshot(
        from url: URL,
        maxBytes: Int,
        lossy: Bool
    ) throws -> BoundedTextSnapshot {
        if url.lastPathComponent.hasSuffix(".diagnostics.log") {
            return try leadingAndTrailingTextSnapshot(from: url, maxBytes: maxBytes, lossy: lossy)
        }
        return try trailingTextSnapshot(from: url, maxBytes: maxBytes, lossy: lossy)
    }

    private static func trailingTextSnapshot(
        from url: URL,
        maxBytes: Int,
        lossy: Bool
    ) throws -> BoundedTextSnapshot {
        let boundedMaxBytes = max(maxBytes, 0)
        let handle = try openReadableRegularLogFile(url)
        defer { try? handle.close() }
        let initial = try descriptorMetadata(for: handle, url: url)
        let size = initial.byteCount
        let offset = size > UInt64(boundedMaxBytes) ? size - UInt64(boundedMaxBytes) : 0
        try handle.seek(toOffset: offset)
        let data = boundedMaxBytes > 0
            ? (try handle.read(upToCount: boundedMaxBytes) ?? Data())
            : Data()
        let changed = try descriptorMetadata(for: handle, url: url) != initial
        let decoded = try decodedText(data, from: url, lossy: lossy)
        var markers: [String] = []
        if offset > 0 {
            markers.append("[ForgePlay: log truncated to last \(boundedMaxBytes) bytes]")
        }
        if changed {
            markers.append("[ForgePlay: log changed during read; captured text is a bounded partial snapshot]")
        }
        let prefix = markers.isEmpty ? "" : markers.joined(separator: "\n") + "\n"
        return BoundedTextSnapshot(text: prefix + decoded, changedDuringRead: changed)
    }

    private static func leadingAndTrailingTextSnapshot(
        from url: URL,
        maxBytes: Int,
        lossy: Bool
    ) throws -> BoundedTextSnapshot {
        let boundedMaxBytes = max(maxBytes, 0)
        let handle = try openReadableRegularLogFile(url)
        defer { try? handle.close() }
        let initial = try descriptorMetadata(for: handle, url: url)
        guard boundedMaxBytes > 0 else {
            let changed = try descriptorMetadata(for: handle, url: url) != initial
            return BoundedTextSnapshot(text: "", changedDuringRead: changed)
        }
        let size = initial.byteCount
        guard size > UInt64(boundedMaxBytes) else {
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: boundedMaxBytes) ?? Data()
            let changed = try descriptorMetadata(for: handle, url: url) != initial
            let text = try decodedText(data, from: url, lossy: lossy)
            let marker = changed
                ? "[ForgePlay: log changed during read; captured text is a bounded partial snapshot]\n"
                : ""
            return BoundedTextSnapshot(text: marker + text, changedDuringRead: changed)
        }

        let leadingByteCount = boundedMaxBytes / 2
        let trailingByteCount = boundedMaxBytes - leadingByteCount
        try handle.seek(toOffset: 0)
        let leadingData = try handle.read(upToCount: leadingByteCount) ?? Data()
        try handle.seek(toOffset: size - UInt64(trailingByteCount))
        let trailingData = try handle.read(upToCount: trailingByteCount) ?? Data()
        let changed = try descriptorMetadata(for: handle, url: url) != initial
        let leadingText = try decodedText(leadingData, from: url, lossy: lossy)
        let trailingText = try decodedText(trailingData, from: url, lossy: lossy)
        var fragments = [
            leadingText,
            "[ForgePlay: diagnostics log middle truncated; showing first \(leadingByteCount) and last \(trailingByteCount) bytes]",
            trailingText
        ]
        if changed {
            fragments.insert(
                "[ForgePlay: log changed during read; captured text is a bounded partial snapshot]",
                at: 0
            )
        }
        return BoundedTextSnapshot(
            text: fragments.joined(separator: "\n"),
            changedDuringRead: changed
        )
    }

    private static func decodedText(_ data: Data, from url: URL, lossy: Bool) throws -> String {
        if lossy { return String(decoding: data, as: UTF8.self) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LogTextReaderError.textDecodeFailed(url)
        }
        return text
    }

    private static func descriptorMetadata(
        for handle: FileHandle,
        url: URL
    ) throws -> DescriptorMetadata {
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0 else {
            throw LogTextReaderError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(
                    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                )
            )
        }
        return DescriptorMetadata(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private static func openReadableRegularLogFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw LogTextReaderError.unsafeLogFile(url)
            }
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw LogTextReaderError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw LogTextReaderError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw LogTextReaderError.unsafeLogFile(url)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func isHardlinkedRegularFile(_ values: URLResourceValues) -> Bool {
        values.isRegularFile == true && (values.linkCount ?? 1) > 1
    }

    private static func runCorrelationKey(for url: URL, relativeTo logsRoot: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = logsRoot.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        let scopedPath = path.hasPrefix(rootPrefix)
            ? String(path.dropFirst(rootPrefix.count))
            : url.lastPathComponent
        let range = NSRange(scopedPath.startIndex..<scopedPath.endIndex, in: scopedPath)
        if let runIdentifierExpression,
           let match = runIdentifierExpression.value.firstMatch(in: scopedPath, range: range),
           let swiftRange = Range(match.range, in: scopedPath) {
            return "uuid:\(scopedPath[swiftRange].lowercased())"
        }

        var stem = url.lastPathComponent.lowercased()
        for suffix in [
            ".diagnostics.log", "_stdout.log", "_stderr.log", ".log", ".txt"
        ] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        return stem.isEmpty ? nil : "legacy:\(stem)"
    }

    private static let runIdentifierExpression = try? CompiledExpression(
        pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
    )
}
