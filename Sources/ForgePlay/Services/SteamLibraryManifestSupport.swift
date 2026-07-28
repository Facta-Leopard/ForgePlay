import Foundation

enum SteamManifestReader {
    static func parseManifest(_ url: URL, libraryPath: URL, parser: VDFParser = VDFParser()) throws -> SteamGame? {
        guard let text = try SteamVDFFileReader.readText(url, maxBytes: SteamVDFFileReader.maxManifestBytes) else {
            return nil
        }
        let parsed = try parser.parse(text)
        guard let appState = parsed["AppState"]?.objectValue else {
            return nil
        }
        guard let appId = SteamGameIdentityPolicy.appId(appState["appid"]?.stringValue),
              let name = SteamGameIdentityPolicy.displayName(appState["name"]?.stringValue),
              let installDir = SteamGameIdentityPolicy.installDirectoryName(appState["installdir"]?.stringValue),
              let stateFlags = Int(appState["StateFlags"]?.stringValue ?? ""),
              stateFlags & 4 != 0,
              SteamGameIdentityPolicy.manifestFileNameMatches(url, appId: appId) else {
            return nil
        }
        let size = max(0, Int64(appState["SizeOnDisk"]?.stringValue ?? "0") ?? 0)
        let updated: Date?
        if let updatedRaw = appState["LastUpdated"]?.stringValue,
           let timestamp = TimeInterval(updatedRaw) {
            updated = Date(timeIntervalSince1970: timestamp)
        } else {
            updated = nil
        }
        return SteamGame(
            steamAppId: appId,
            name: name,
            installDir: installDir,
            libraryPath: libraryPath.path,
            manifestPath: url.path,
            sizeOnDisk: size,
            lastUpdated: updated
        )
    }
}

enum SteamVDFFileReader {
    static let maxLibraryFoldersBytes = 256 * 1024
    static let maxManifestBytes = 256 * 1024

    static func isReadableTextFile(
        _ url: URL,
        maxBytes: Int,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey]
            )
        } catch {
            throw SteamLibraryScanError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              values.isDirectory != true,
              (values.linkCount ?? 1) == 1 else {
            return false
        }
        guard let size = values.fileSize else {
            throw SteamLibraryScanError.metadataReadFailed(
                url,
                forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown))
            )
        }
        guard size <= maxBytes else {
            return false
        }
        return true
    }

    static func readText(_ url: URL, maxBytes: Int) throws -> String? {
        guard try isReadableTextFile(url, maxBytes: maxBytes) else {
            return nil
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SteamLibraryScanError.fileReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw SteamLibraryScanError.fileReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        guard data.count <= maxBytes else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SteamLibraryScanError.fileReadFailed(url, "invalid UTF-8 text")
        }
        return text
    }
}
