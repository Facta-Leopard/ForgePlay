import CryptoKit
import Foundation

struct WindowsFontCompatibilityInspection: Hashable, Sendable {
    var appliedItems: [String]
    var missingItems: [String]

    var isSatisfied: Bool { missingItems.isEmpty }
}

private struct WindowsFontPayload: Hashable, Sendable {
    var fileName: String
    var sha256: String
    var registryName: String
}

private struct WindowsFontRegistryRequirement: Hashable, Sendable {
    var registryPath: String
    var valueName: String
    var valueType: String? = nil
    var value: String

    var label: String {
        "\(registryPath)\\\(valueName)=\(value)"
    }
}

enum WindowsFontCompatibilityProfileContract {
    nonisolated static let profileIdentifier = "forgeplay-windows-font-compatibility-v4"

    private nonisolated static let fontPayloads = [
        WindowsFontPayload(
            fileName: "NanumGothic-Regular.ttf",
            sha256: "76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31",
            registryName: "NanumGothic (TrueType)"
        ),
        WindowsFontPayload(
            fileName: "NanumGothic-Bold.ttf",
            sha256: "21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2",
            registryName: "NanumGothic Bold (TrueType)"
        )
    ]

    private nonisolated static let koreanFamilyAliases = [
        "Gulim",
        "GulimChe",
        "Dotum",
        "DotumChe",
        "Malgun Gothic",
        "Malgun Gothic Semilight",
        "Batang",
        "BatangChe",
        "Gungsuh",
        "GungsuhChe"
    ]

    private nonisolated static let linkedLatinFamilies = [
        "Tahoma",
        "Arial",
        "Microsoft Sans Serif",
        "Segoe UI",
        "Verdana"
    ]

    // MS Shell Dlg has no installed family, so the standard Windows
    // substitution path can point it directly at the bundled family.
    nonisolated static let standardSubstitutionFamilies = ["MS Shell Dlg"]

    // Wine owns MS Shell Dlg 2 and restores it to Tahoma from wine.inf.
    // Preserve and verify that stable default; ForcedReplacements below turns
    // the resulting Tahoma request into NanumGothic in both GDI and DirectWrite.
    nonisolated static let wineDefaultTahomaSubstitutionFamilies = ["MS Shell Dlg 2"]

    // Tahoma is installed by Wine, which makes ordinary substitutions advisory.
    // The bundled Wine patch treats this opt-in key as an actual family override.
    nonisolated static let forcedReplacementFamilies = ["Tahoma"]

    // Omitting the optional family suffix lets Wine match the font by filename
    // even when the TTF's primary family name is localized.
    nonisolated static let fontLinkFallbackFile = "NanumGothic-Regular.ttf"

    fileprivate nonisolated static var registryRequirements: [WindowsFontRegistryRequirement] {
        let fontsPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
        let substitutesPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let linksPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
        let replacementsPath = "HKCU\\Software\\Wine\\Fonts\\Replacements"
        let forcedReplacementsPath = "HKCU\\Software\\Wine\\Fonts\\ForcedReplacements"

        let fontFiles = fontPayloads.map {
            WindowsFontRegistryRequirement(
                registryPath: fontsPath,
                valueName: $0.registryName,
                value: $0.fileName
            )
        }
        let replacements = koreanFamilyAliases.map {
            WindowsFontRegistryRequirement(
                registryPath: replacementsPath,
                valueName: $0,
                value: "NanumGothic"
            )
        }
        let glyphLinks = linkedLatinFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: $0,
                valueType: "REG_MULTI_SZ",
                value: fontLinkFallbackFile
            )
        }
        let standardSubstitutions = standardSubstitutionFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: $0,
                value: "NanumGothic"
            )
        }
        let wineDefaultTahomaSubstitutions = wineDefaultTahomaSubstitutionFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: $0,
                value: "Tahoma"
            )
        }
        let forcedReplacements = forcedReplacementFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: forcedReplacementsPath,
                valueName: $0,
                value: "NanumGothic"
            )
        }
        return fontFiles + replacements + standardSubstitutions +
            wineDefaultTahomaSubstitutions + forcedReplacements + glyphLinks
    }

    nonisolated static func inspect(
        prefix: URL,
        fileManager: FileManager = .default,
        requiresProfileMarker: Bool = true
    ) -> WindowsFontCompatibilityInspection {
        var applied: [String] = []
        var missing: [String] = []
        let fontsDirectory = windowsFontsDirectory(in: prefix)

        for payload in fontPayloads {
            let destination = fontsDirectory.appending(path: payload.fileName)
            let label = "C:\\windows\\Fonts\\\(payload.fileName)=\(payload.sha256)"
            if sha256(of: destination, fileManager: fileManager) == payload.sha256 {
                applied.append(label)
            } else {
                missing.append(label)
            }
        }

        let userSnapshot = registrySnapshot(
            at: prefix.appending(path: "user.reg"),
            fileManager: fileManager
        )
        let systemSnapshot = registrySnapshot(
            at: prefix.appending(path: "system.reg"),
            fileManager: fileManager
        )
        for requirement in registryRequirements {
            let snapshot = requirement.registryPath.hasPrefix("HKCU\\") ? userSnapshot : systemSnapshot
            let matches: Bool
            if requirement.valueType == "REG_MULTI_SZ" {
                matches = snapshot?.multiStringValues(
                    forRegistryPath: requirement.registryPath,
                    valueName: requirement.valueName
                ) == [requirement.value]
            } else {
                matches = snapshot?.value(
                    forRegistryPath: requirement.registryPath,
                    valueName: requirement.valueName
                ) == requirement.value
            }
            if matches {
                applied.append(requirement.label)
            } else {
                missing.append(requirement.label)
            }
        }

        if requiresProfileMarker {
            let marker = markerURL(in: prefix)
            let markerLabel = "\(profileIdentifier)=managed"
            if FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager),
               let data = try? Data(contentsOf: marker),
               data == markerData {
                applied.append(markerLabel)
            } else {
                missing.append(markerLabel)
            }
        }

        return WindowsFontCompatibilityInspection(
            appliedItems: applied.sorted(),
            missingItems: missing.sorted()
        )
    }

    nonisolated static func resourceDirectory(
        for runtimeExecutable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        let binDirectory = runtimeExecutable.deletingLastPathComponent()
        if binDirectory.lastPathComponent == "bin" {
            candidates.append(
                binDirectory.deletingLastPathComponent()
                    .appending(path: "share/wine/fonts", directoryHint: .isDirectory)
            )
        }
        for resourceURL in [
            Bundle.main.resourceURL,
            Bundle(for: WindowsFontCompatibilityBundleToken.self).resourceURL
        ].compactMap({ $0 }) {
            candidates.append(
                resourceURL.appending(
                    path: "Runners/ForgePlayRuntime/wine/share/wine/fonts",
                    directoryHint: .isDirectory
                )
            )
        }
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            sourceRoot.appending(
                path: "Resources/Runners/ForgePlayRuntime/wine/share/wine/fonts",
                directoryHint: .isDirectory
            )
        )
        #endif

        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileSystemItemPolicy.isNonSymlinkDirectory(candidate, fileManager: fileManager) else {
                return false
            }
            return fontPayloads.allSatisfy { payload in
                sha256(
                    of: candidate.appending(path: payload.fileName),
                    fileManager: fileManager
                ) == payload.sha256
            }
        }
    }

    fileprivate nonisolated static func windowsFontsDirectory(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/windows/Fonts", directoryHint: .isDirectory)
    }

    fileprivate nonisolated static func markerURL(in prefix: URL) -> URL {
        prefix.appending(
            path: "drive_c/ForgePlay/FontCompatibility/\(profileIdentifier).txt"
        )
    }

    fileprivate nonisolated static var markerData: Data {
        var lines = [profileIdentifier]
        lines.append(contentsOf: fontPayloads.map { "\($0.fileName)=\($0.sha256)" })
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    fileprivate nonisolated static func fontSourceURLs(in directory: URL) -> [URL] {
        fontPayloads.map { directory.appending(path: $0.fileName) }
    }

    private nonisolated static func registrySnapshot(
        at url: URL,
        fileManager: FileManager
    ) -> WineUserRegistrySnapshot? {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return WineUserRegistrySnapshot(contents: contents)
    }

    private nonisolated static func sha256(
        of url: URL,
        fileManager: FileManager
    ) -> String? {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum WindowsFontCompatibilityProfileError: LocalizedError {
    case bundledPayloadMissing
    case unsafeDestination(URL)
    case verificationFailed([String])

    var errorDescription: String? {
        switch self {
        case .bundledPayloadMissing:
            "번들 한글 글꼴 payload가 없거나 무결성 검사를 통과하지 못했습니다."
        case .unsafeDestination(let url):
            "Windows 글꼴을 적용할 대상이 안전한 폴더가 아닙니다: \(url.path)"
        case .verificationFailed(let missing):
            "Windows 한글 글꼴 호환성 적용을 확인하지 못했습니다: \(missing.joined(separator: ", "))"
        }
    }
}

@MainActor
final class WindowsFontCompatibilityProfile {
    private let runner: SafeProcessRunner
    private let fileManager: FileManager

    init(runner: SafeProcessRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func apply(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult? {
        let initialInspection = WindowsFontCompatibilityProfileContract.inspect(
            prefix: prefix,
            fileManager: fileManager
        )
        guard !initialInspection.isSatisfied else { return nil }
        guard let sourceDirectory = WindowsFontCompatibilityProfileContract.resourceDirectory(
            for: runtimeExecutable,
            fileManager: fileManager
        ) else {
            throw WindowsFontCompatibilityProfileError.bundledPayloadMissing
        }

        try installFonts(from: sourceDirectory, into: prefix)
        for requirement in WindowsFontCompatibilityProfileContract.registryRequirements {
            let result = try await runner.run(.setRegistryValue(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                registryPath: requirement.registryPath,
                valueName: requirement.valueName,
                valueType: requirement.valueType,
                value: requirement.value,
                logDirectory: logDirectory
            ))
            guard result.succeeded else { return result }
        }

        let registryFlush = try await runner.run(.waitForWinePrefix(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ))
        guard registryFlush.succeeded else { return registryFlush }

        let finalInspection = WindowsFontCompatibilityProfileContract.inspect(
            prefix: prefix,
            fileManager: fileManager,
            requiresProfileMarker: false
        )
        guard finalInspection.isSatisfied else {
            throw WindowsFontCompatibilityProfileError.verificationFailed(
                finalInspection.missingItems
            )
        }
        try writeProfileMarker(in: prefix)
        return nil
    }

    private func installFonts(from sourceDirectory: URL, into prefix: URL) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(prefix, fileManager: fileManager) else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(prefix)
        }
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let windows = driveC.appending(path: "windows", directoryHint: .isDirectory)
        let fonts = WindowsFontCompatibilityProfileContract.windowsFontsDirectory(in: prefix)
        for directory in [driveC, windows] {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) else {
                throw WindowsFontCompatibilityProfileError.unsafeDestination(directory)
            }
        }
        if fileManager.fileExists(atPath: fonts.path) {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(fonts, fileManager: fileManager) else {
                throw WindowsFontCompatibilityProfileError.unsafeDestination(fonts)
            }
        } else {
            try fileManager.createDirectory(at: fonts, withIntermediateDirectories: false)
        }

        for source in WindowsFontCompatibilityProfileContract.fontSourceURLs(in: sourceDirectory) {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(source, fileManager: fileManager)
            let destination = fonts.appending(path: source.lastPathComponent)
            if FileSystemItemPolicy.isRegularNonSymlinkFile(destination, fileManager: fileManager),
               fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            }
            let temporary = fonts.appending(path: ".\(source.lastPathComponent).install-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: source, to: temporary)
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(temporary, fileManager: fileManager)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        }
    }

    private func writeProfileMarker(in prefix: URL) throws {
        let marker = WindowsFontCompatibilityProfileContract.markerURL(in: prefix)
        let forgePlayDirectory = marker
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let profileDirectory = marker.deletingLastPathComponent()
        for directory in [forgePlayDirectory, profileDirectory] {
            if fileManager.fileExists(atPath: directory.path) {
                guard FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) else {
                    throw WindowsFontCompatibilityProfileError.unsafeDestination(directory)
                }
            } else {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        if fileManager.fileExists(atPath: marker.path),
           !FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager) {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(marker)
        }
        try WindowsFontCompatibilityProfileContract.markerData.write(to: marker, options: [.atomic])
    }
}

private final class WindowsFontCompatibilityBundleToken: NSObject {}
