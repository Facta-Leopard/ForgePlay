import Foundation

/// A target-neutral technical error contract shared by the app and its
/// privileged/helper executables. User-facing localization stays in the app.
protocol ForgePlayTechnicalDescribingError: Error {
    var forgePlayTechnicalDescription: String { get }
}

func forgePlayTechnicalErrorSummary(_ error: Error) -> String {
    if let technicalError = error as? ForgePlayTechnicalDescribingError {
        let description = technicalError.forgePlayTechnicalDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
    }

    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
}
