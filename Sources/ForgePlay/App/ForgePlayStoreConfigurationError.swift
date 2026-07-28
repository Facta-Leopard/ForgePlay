import Foundation

enum ForgePlayStoreConfigurationError: LocalizedError, ForgePlayTechnicalDescribingError {
    case applicationSupportUnavailable
    case unsafeApplicationSupportDirectory(URL)
    case createApplicationSupportDirectoryFailed(URL, Error)
    case unsafeStoreDirectory(URL)
    case createStoreDirectoryFailed(URL, Error)
    case unsafeStoreFile(URL)
    case unsafeLegacyStoreFile(URL)
    case metadataReadFailed(URL, String)
    case legacyStoreMarkerReadFailed(URL, Error)
    case legacyStoreMigrationFailed(URL, URL, Error)
    case legacyStoreMigrationCleanupFailed(URL, URL, URL, Error, Error)

    var errorDescription: String? {
        forgePlayTechnicalDescription
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .applicationSupportUnavailable:
            "Could not locate the user Application Support directory."
        case .unsafeApplicationSupportDirectory(let url):
            "Application Support is not a safe regular directory: \(url.path)"
        case .createApplicationSupportDirectoryFailed(let url, let error):
            "Could not create Application Support directory: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .unsafeStoreDirectory(let url):
            "ForgePlay data directory is not a safe regular directory: \(url.path)"
        case .createStoreDirectoryFailed(let url, let error):
            "Could not create ForgePlay data directory: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .unsafeStoreFile(let url):
            "ForgePlay data store is not a safe regular file: \(url.path)"
        case .unsafeLegacyStoreFile(let url):
            "Legacy ForgePlay data store is not a safe regular file: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "Could not read ForgePlay data store file information: \(url.path). \(message)"
        case .legacyStoreMarkerReadFailed(let url, let error):
            "Could not inspect legacy ForgePlay data store marker: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .legacyStoreMigrationFailed(let source, let destination, let error):
            "Could not migrate legacy ForgePlay data store from \(source.path) to \(destination.path). \(forgePlayTechnicalErrorSummary(error))"
        case .legacyStoreMigrationCleanupFailed(let source, let destination, let cleanupTarget, let originalError, let cleanupError):
            "Could not migrate legacy ForgePlay data store from \(source.path) to \(destination.path), and cleanup failed for \(cleanupTarget.path). Cause: \(forgePlayTechnicalErrorSummary(originalError)). Cleanup error: \(forgePlayTechnicalErrorSummary(cleanupError))"
        }
    }
}
