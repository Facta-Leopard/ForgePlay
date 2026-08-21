// SPDX-FileCopyrightText: 2026 Facta-Leopard
// SPDX-License-Identifier: GPL-3.0-only
//
// ForgePlay Game Mode
// Original source: https://github.com/Facta-Leopard/ForgePlay

import CryptoKit
import Foundation
import Security

struct GameModeHostCapability: Hashable, Sendable {
    let appURL: URL
    let executableURL: URL
    let bundleIdentifier: String
    let executableSHA256: String
    let supportsGameMode: Bool
    let isRosettaRuntimeComponent: Bool
}

enum GameModeHostSigningProfile: String, Hashable, Sendable {
    case sandboxAppGroup = "sandbox-app-group"
    case directUserDomain = "direct-user-domain"
}

struct GameModeSteamChildHostSelection: Hashable, Sendable {
    let host: GameModeHostCapability
    let runtimeNtdllURL: URL
    let prefixExecutionLockURL: URL
    let evidenceLogURL: URL
    let runIdentifier: String
}

enum SteamGameModeLaunchPolicy: String, Hashable, Sendable {
    case standard
    case experimentalRequiredHost
}

enum GameModeHostCapabilityError:
    LocalizedError,
    ForgePlayTechnicalDescribingError,
    Equatable {
    case appMissing(URL)
    case unsafeAppBundle(URL)
    case infoPlistMissing(URL)
    case infoPlistInvalid(URL)
    case unexpectedBundleIdentifier(expected: String, actual: String?)
    case invalidPackageType(String?)
    case gameModeDeclarationMissing
    case identityDeclarationInvalid
    case backgroundOnlyHost
    case executableNameInvalid(String?)
    case executableMissing(URL)
    case executableArchitectureUnsupported(URL)
    case signatureInvalid(URL)
    case sandboxInheritanceContractInvalid(URL, String)
    case directUserDomainContractInvalid(URL, String)
    case executableReadFailed(URL, String)
    case applicationGroupRequired
    case runtimeLayoutUnsupported(URL)
    case runtimeNtdllMissing(URL)
    case prefixExecutionLockUnavailable(URL, String)
    case coordinationStorageUnavailable(URL?, String)

    var diagnosticCode: String {
        switch self {
        case .appMissing: "host-app-missing"
        case .unsafeAppBundle: "unsafe-host-app"
        case .infoPlistMissing: "host-info-missing"
        case .infoPlistInvalid: "host-info-invalid"
        case .unexpectedBundleIdentifier: "host-bundle-identifier-mismatch"
        case .invalidPackageType: "host-package-type-invalid"
        case .gameModeDeclarationMissing: "host-game-mode-declaration-missing"
        case .identityDeclarationInvalid: "host-identity-declaration-invalid"
        case .backgroundOnlyHost: "host-background-only"
        case .executableNameInvalid: "host-executable-name-invalid"
        case .executableMissing: "host-executable-missing"
        case .executableArchitectureUnsupported: "host-architecture-unsupported"
        case .signatureInvalid: "host-signature-invalid"
        case .sandboxInheritanceContractInvalid: "host-sandbox-inheritance-invalid"
        case .directUserDomainContractInvalid: "host-direct-user-domain-invalid"
        case .executableReadFailed: "host-executable-unreadable"
        case .applicationGroupRequired: "host-application-group-required"
        case .runtimeLayoutUnsupported: "runtime-layout-unsupported"
        case .runtimeNtdllMissing: "runtime-ntdll-missing"
        case .prefixExecutionLockUnavailable: "prefix-execution-lock-unavailable"
        case .coordinationStorageUnavailable: "coordination-storage-unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .appMissing(let url):
            "Game Mode 프로세스 호스트가 앱에 포함되지 않았습니다: \(url.path)"
        case .unsafeAppBundle(let url):
            "Game Mode 프로세스 호스트 경로가 안전한 앱 번들이 아닙니다: \(url.path)"
        case .infoPlistMissing(let url):
            "Game Mode 프로세스 호스트의 Info.plist를 찾을 수 없습니다: \(url.path)"
        case .infoPlistInvalid(let url):
            "Game Mode 프로세스 호스트의 Info.plist 형식이 올바르지 않습니다: \(url.path)"
        case .unexpectedBundleIdentifier(let expected, let actual):
            "Game Mode 프로세스 호스트 식별자가 일치하지 않습니다. 예상: \(expected), 실제: \(actual ?? "없음")"
        case .invalidPackageType(let packageType):
            "Game Mode 프로세스 호스트 package type이 APPL이 아닙니다: \(packageType ?? "없음")"
        case .gameModeDeclarationMissing:
            "Game Mode 프로세스 호스트가 LSSupportsGameMode를 선언하지 않았습니다."
        case .identityDeclarationInvalid:
            "Game Mode 프로세스 호스트의 앱 identity 또는 아이콘 선언이 고정 계약과 일치하지 않습니다."
        case .backgroundOnlyHost:
            "Game Mode 프로세스 호스트가 foreground 게임 앱으로 구성되지 않았습니다."
        case .executableNameInvalid(let name):
            "Game Mode 프로세스 호스트 실행 파일 이름이 안전하지 않습니다: \(name ?? "없음")"
        case .executableMissing(let url):
            "Game Mode 프로세스 호스트 실행 파일을 찾을 수 없습니다: \(url.path)"
        case .executableArchitectureUnsupported(let url):
            "Game Mode 프로세스 호스트가 Rosetta용 x86_64 Mach-O가 아닙니다: \(url.path)"
        case .signatureInvalid(let url):
            "Game Mode 프로세스 호스트의 코드 서명을 검증하지 못했습니다: \(url.path)"
        case .sandboxInheritanceContractInvalid(let url, let reason):
            "Game Mode 프로세스 호스트의 샌드박스 상속 서명이 올바르지 않습니다: \(url.path). \(reason)"
        case .directUserDomainContractInvalid(let url, let reason):
            "Game Mode 프로세스 호스트의 직접 실행 서명이 올바르지 않습니다: \(url.path). \(reason)"
        case .executableReadFailed(let url, let message):
            "Game Mode 프로세스 호스트를 읽지 못했습니다: \(url.path). \(message)"
        case .applicationGroupRequired:
            "Game Mode 프로세스 호스트는 서명된 ForgePlay App Group이 있는 빌드에서만 사용할 수 있습니다."
        case .runtimeLayoutUnsupported(let url):
            "Game Mode 프로세스 호스트와 연결할 ForgePlay Runtime 구조가 아닙니다: \(url.path)"
        case .runtimeNtdllMissing(let url):
            "Game Mode 프로세스 호스트와 같은 x86_64 Wine ntdll.so를 찾을 수 없습니다: \(url.path)"
        case .prefixExecutionLockUnavailable(let url, let message):
            "Game Mode 프로세스 호스트의 프리픽스 실행 잠금을 준비하지 못했습니다: \(url.path). \(message)"
        case .coordinationStorageUnavailable(let url, let message):
            if let url {
                "Game Mode 프로세스 호스트의 공유 진단 저장소를 준비하지 못했습니다: \(url.path). \(message)"
            } else {
                "Game Mode 프로세스 호스트의 공유 진단 저장소를 준비하지 못했습니다: \(message)"
            }
        }
    }

    var forgePlayTechnicalDescription: String {
        guard let detail = errorDescription?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !detail.isEmpty else {
            return diagnosticCode
        }
        return "\(diagnosticCode): \(detail)"
    }
}

struct GameModeHostCapabilityInspector {
    nonisolated static let hostBundleName = "GameModeProcessHost.app"
    nonisolated static let executableName = "GameModeProcessHost"
    nonisolated static let defaultBundleIdentifierSuffix = ".game-mode-host"

    private let fileManager: FileManager
    private let signatureValidator: @Sendable (URL) -> Bool
    private let signingProfileValidator:
        @Sendable (URL, GameModeHostSigningProfile, String?) -> String?

    init(
        fileManager: FileManager = .default,
        signatureValidator: @escaping @Sendable (URL) -> Bool = {
            GameModeHostCapabilityInspector.validateCodeSignature($0)
        },
        signingProfileValidator: @escaping @Sendable (
            URL,
            GameModeHostSigningProfile,
            String?
        ) -> String? = {
            GameModeHostCapabilityInspector.signingProfileViolation(
                at: $0,
                profile: $1,
                applicationGroupIdentifier: $2
            )
        }
    ) {
        self.fileManager = fileManager
        self.signatureValidator = signatureValidator
        self.signingProfileValidator = signingProfileValidator
    }

    nonisolated static func bundledHostAppURL(mainBundleURL: URL = Bundle.main.bundleURL) -> URL {
        mainBundleURL
            .appending(path: "Contents/Helpers", directoryHint: .isDirectory)
            .appending(path: hostBundleName, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    nonisolated static func expectedBundleIdentifier(
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String? {
        guard let mainBundleIdentifier,
              !mainBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return mainBundleIdentifier + defaultBundleIdentifierSuffix
    }

    func inspectBundledHost(
        mainBundleURL: URL = Bundle.main.bundleURL,
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        signingProfile: GameModeHostSigningProfile = .sandboxAppGroup,
        applicationGroupIdentifier: String? = nil
    ) throws -> GameModeHostCapability {
        guard let expectedBundleIdentifier = Self.expectedBundleIdentifier(
            mainBundleIdentifier: mainBundleIdentifier
        ) else {
            throw GameModeHostCapabilityError.unexpectedBundleIdentifier(
                expected: "<main-bundle-id>\(Self.defaultBundleIdentifierSuffix)",
                actual: nil
            )
        }
        return try inspect(
            appURL: Self.bundledHostAppURL(mainBundleURL: mainBundleURL),
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedContainerURL: mainBundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory),
            signingProfile: signingProfile,
            applicationGroupIdentifier: applicationGroupIdentifier
        )
    }

    /// Performs only immutable host-artifact admission. This deliberately
    /// avoids runtime, prefix-lock, and coordination-storage preparation so a
    /// mis-signed distribution can be rejected before SteamShared is mutated.
    func inspectBundledHostForSteamLaunchAdmission(
        mainBundleURL: URL = Bundle.main.bundleURL,
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        primaryApplicationGroupIdentifier: String? =
            ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier
    ) throws -> GameModeHostCapability {
        let applicationGroupIdentifier = primaryApplicationGroupIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let applicationGroupIdentifier,
              !applicationGroupIdentifier.isEmpty,
              !applicationGroupIdentifier.contains("$(") else {
            throw GameModeHostCapabilityError.applicationGroupRequired
        }
        let signingProfile: GameModeHostSigningProfile = sandboxEnabled
            ? .sandboxAppGroup
            : .directUserDomain
        return try inspectBundledHost(
            mainBundleURL: mainBundleURL,
            mainBundleIdentifier: mainBundleIdentifier,
            signingProfile: signingProfile,
            applicationGroupIdentifier: applicationGroupIdentifier
        )
    }

    func inspect(
        appURL: URL,
        expectedBundleIdentifier: String,
        expectedContainerURL: URL? = nil,
        signingProfile: GameModeHostSigningProfile = .sandboxAppGroup,
        applicationGroupIdentifier: String? = nil
    ) throws -> GameModeHostCapability {
        let appURL = appURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory) else {
            throw GameModeHostCapabilityError.appMissing(appURL)
        }
        guard isDirectory.boolValue,
              FileSystemItemPolicy.isNonSymlinkDirectory(appURL, fileManager: fileManager),
              appURL.pathExtension.lowercased() == "app" else {
            throw GameModeHostCapabilityError.unsafeAppBundle(appURL)
        }
        if let expectedContainerURL {
            let container = expectedContainerURL.standardizedFileURL.resolvingSymlinksInPath()
            let resolvedApp = appURL.resolvingSymlinksInPath()
            guard resolvedApp.deletingLastPathComponent().path == container.path else {
                throw GameModeHostCapabilityError.unsafeAppBundle(appURL)
            }
        }

        let infoPlistURL = appURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(infoPlistURL, fileManager: fileManager) else {
            throw GameModeHostCapabilityError.infoPlistMissing(infoPlistURL)
        }
        let plist: [String: Any]
        do {
            let data = try Data(contentsOf: infoPlistURL, options: [.mappedIfSafe])
            guard data.count <= 1_048_576,
                  let decoded = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any] else {
                throw GameModeHostCapabilityError.infoPlistInvalid(infoPlistURL)
            }
            plist = decoded
        } catch let error as GameModeHostCapabilityError {
            throw error
        } catch {
            throw GameModeHostCapabilityError.infoPlistInvalid(infoPlistURL)
        }

        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        guard bundleIdentifier == expectedBundleIdentifier else {
            throw GameModeHostCapabilityError.unexpectedBundleIdentifier(
                expected: expectedBundleIdentifier,
                actual: bundleIdentifier
            )
        }
        let packageType = plist["CFBundlePackageType"] as? String
        guard packageType == "APPL" else {
            throw GameModeHostCapabilityError.invalidPackageType(packageType)
        }
        guard plist["LSSupportsGameMode"] as? Bool == true else {
            throw GameModeHostCapabilityError.gameModeDeclarationMissing
        }
        let assetCatalogIconFile = plist["CFBundleIconFile"] as? String
        let hasAssetCatalogIcon = plist["CFBundleIconName"] as? String == "AppIcon" &&
            (assetCatalogIconFile == nil || assetCatalogIconFile == "AppIcon")
        let hasStandaloneIcon = plist["CFBundleIconFile"] as? String == "AppIcon.icns" &&
            plist["CFBundleIconName"] == nil
        guard plist["LSApplicationCategoryType"] as? String == "public.app-category.games",
              plist["NSPrincipalClass"] as? String == "WineApplication",
              hasAssetCatalogIcon || hasStandaloneIcon else {
            throw GameModeHostCapabilityError.identityDeclarationInvalid
        }
        if plist["LSUIElement"] != nil ||
            plist["LSBackgroundOnly"] != nil ||
            plist["LSMultipleInstancesProhibited"] != nil {
            throw GameModeHostCapabilityError.backgroundOnlyHost
        }
        let executableName = plist["CFBundleExecutable"] as? String
        guard executableName == Self.executableName,
              !Self.containsPathSeparator(executableName) else {
            throw GameModeHostCapabilityError.executableNameInvalid(executableName)
        }
        let executableURL = appURL
            .appending(path: "Contents/MacOS", directoryHint: .isDirectory)
            .appending(path: Self.executableName, directoryHint: .notDirectory)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(executableURL, fileManager: fileManager),
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw GameModeHostCapabilityError.executableMissing(executableURL)
        }

        let executableData: Data
        do {
            executableData = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        } catch {
            throw GameModeHostCapabilityError.executableReadFailed(
                executableURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        guard Self.isThinX86_64MachO(executableData) else {
            throw GameModeHostCapabilityError.executableArchitectureUnsupported(executableURL)
        }
        guard signatureValidator(appURL) else {
            throw GameModeHostCapabilityError.signatureInvalid(appURL)
        }
        if let violation = signingProfileValidator(
            appURL,
            signingProfile,
            applicationGroupIdentifier
        ) {
            switch signingProfile {
            case .sandboxAppGroup:
                throw GameModeHostCapabilityError.sandboxInheritanceContractInvalid(
                    appURL,
                    violation
                )
            case .directUserDomain:
                throw GameModeHostCapabilityError.directUserDomainContractInvalid(
                    appURL,
                    violation
                )
            }
        }

        let digest = SHA256.hash(data: executableData)
            .map { String(format: "%02x", $0) }
            .joined()
        return GameModeHostCapability(
            appURL: appURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier ?? expectedBundleIdentifier,
            executableSHA256: digest,
            supportsGameMode: true,
            isRosettaRuntimeComponent: true
        )
    }

    func inspectSteamChildSelection(
        runtimeExecutable: URL,
        prefix: URL,
        evidenceLogURL: URL,
        runIdentifier: String,
        mainBundleURL: URL = Bundle.main.bundleURL,
        mainBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> GameModeSteamChildHostSelection {
        let host = try inspectBundledHostForSteamLaunchAdmission(
            mainBundleURL: mainBundleURL,
            mainBundleIdentifier: mainBundleIdentifier
        )
        let binDirectory = runtimeExecutable.standardizedFileURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else {
            throw GameModeHostCapabilityError.runtimeLayoutUnsupported(runtimeExecutable)
        }
        let wineRoot = binDirectory.deletingLastPathComponent()
        let runtimeNtdllURL = wineRoot.appending(
            path: "lib/wine/x86_64-unix/ntdll.so",
            directoryHint: .notDirectory
        )
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(
            runtimeNtdllURL,
            fileManager: fileManager
        ), let ntdllData = try? Data(contentsOf: runtimeNtdllURL, options: [.mappedIfSafe]),
           Self.isThinX86_64MachO(ntdllData) else {
            throw GameModeHostCapabilityError.runtimeNtdllMissing(runtimeNtdllURL)
        }
        let prefixExecutionLockURL: URL
        do {
            prefixExecutionLockURL = try PrefixExecutionLease.coordinatedLockURL(
                forPrefix: prefix,
                fileManager: fileManager
            )
        } catch {
            throw GameModeHostCapabilityError.prefixExecutionLockUnavailable(
                prefix,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(
            prefixExecutionLockURL,
            fileManager: fileManager
        ), let lockAttributes = try? fileManager.attributesOfItem(
            atPath: prefixExecutionLockURL.path
        ), ((lockAttributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw GameModeHostCapabilityError.prefixExecutionLockUnavailable(
                prefixExecutionLockURL,
                "lock metadata is not initialized"
            )
        }
        guard evidenceLogURL.isFileURL,
              evidenceLogURL.path.hasPrefix("/") else {
            throw GameModeHostCapabilityError.prefixExecutionLockUnavailable(
                evidenceLogURL,
                "evidence log path is not absolute"
            )
        }
        guard UUID(uuidString: runIdentifier) != nil else {
            throw GameModeHostCapabilityError.prefixExecutionLockUnavailable(
                evidenceLogURL,
                "run identifier is invalid"
            )
        }
        return GameModeSteamChildHostSelection(
            host: host,
            runtimeNtdllURL: runtimeNtdllURL,
            prefixExecutionLockURL: prefixExecutionLockURL,
            evidenceLogURL: evidenceLogURL,
            runIdentifier: runIdentifier.lowercased()
        )
    }

    private nonisolated static func containsPathSeparator(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.contains("/") || value.contains("\\") || value == "." || value == ".."
    }

    private nonisolated static func isThinX86_64MachO(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let magic = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        let cpuType = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }
        return magic == 0xfeedfacf && cpuType == 0x0100_0007
    }

    private nonisolated static func validateCodeSignature(_ appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else { return false }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess
    }

    /// Validates one of the two intentionally disjoint host signatures. A
    /// sandbox host inherits the main app's profile, while a direct Release
    /// host receives exactly one shared App Group plus the two hardened-runtime
    /// exceptions required by Wine. Keeping both contracts exact prevents an
    /// accidentally mixed sandbox/direct host from reaching secinit or the
    /// Wine bootstrap path.
    private nonisolated static func signingProfileViolation(
        at appURL: URL,
        profile: GameModeHostSigningProfile,
        applicationGroupIdentifier: String?
    ) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return "signed entitlement dictionary is unavailable"
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let entitlements = information[
            kSecCodeInfoEntitlementsDict as String
        ] as? [String: Any] else {
            return "signed entitlement dictionary is unavailable"
        }

        return signingProfileViolation(
            in: entitlements,
            profile: profile,
            applicationGroupIdentifier: applicationGroupIdentifier
        )
    }

    nonisolated static func signingProfileViolation(
        in entitlements: [String: Any],
        profile: GameModeHostSigningProfile,
        applicationGroupIdentifier: String? = nil
    ) -> String? {
        let requiredKeys: Set<String>
        switch profile {
        case .sandboxAppGroup:
            requiredKeys = [
                "com.apple.security.app-sandbox",
                "com.apple.security.inherit",
                "com.apple.security.cs.allow-unsigned-executable-memory",
                "com.apple.security.cs.disable-library-validation"
            ]
        case .directUserDomain:
            requiredKeys = [
                "com.apple.security.application-groups",
                "com.apple.security.cs.allow-unsigned-executable-memory",
                "com.apple.security.cs.disable-library-validation"
            ]
        }
        let booleanRequiredKeys = requiredKeys.subtracting([
            "com.apple.security.application-groups"
        ])
        for key in booleanRequiredKeys where entitlements[key] as? Bool != true {
            return "required entitlement is missing: \(key)"
        }
        if profile == .directUserDomain {
            guard let applicationGroupIdentifier,
                  entitlements["com.apple.security.application-groups"] as? [String] == [
                    applicationGroupIdentifier
                  ] else {
                return "required entitlement does not match: com.apple.security.application-groups"
            }
        }
        let unexpectedKeys = Set(entitlements.keys).subtracting(requiredKeys)
        guard unexpectedKeys.isEmpty else {
            return "entitlement is forbidden for \(profile.rawValue): " +
                unexpectedKeys.sorted().joined(separator: ",")
        }
        return nil
    }
}

enum GameModeHostCoordinationPaths {
    nonisolated static let evidenceDirectoryName = "GameModeProcessHostEvidence"
    nonisolated static let evidenceFileName = "GameModeProcessHost-v1.jsonl"

    nonisolated static func existingEvidenceDirectoryURL(
        fileManager: FileManager = .default,
        primaryApplicationGroupIdentifier: String? =
            ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
        applicationGroupContainerResolver: ((String) -> URL?)? = nil
    ) -> URL? {
        guard let applicationGroupIdentifier = validApplicationGroupIdentifier(
            primaryApplicationGroupIdentifier
        ), let groupContainer = resolveApplicationGroupContainer(
            identifier: applicationGroupIdentifier,
            fileManager: fileManager,
            resolver: applicationGroupContainerResolver
        ) else {
            return nil
        }
        let directory = evidenceDirectoryURL(groupContainer: groupContainer)
        return FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager)
            ? directory
            : nil
    }

    nonisolated static func evidenceLogURL(
        fallbackLogURL: URL,
        fileManager: FileManager = .default,
        primaryApplicationGroupIdentifier: String? =
            ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
        applicationGroupContainerResolver: ((String) -> URL?)? = nil
    ) throws -> URL {
        guard let applicationGroupIdentifier = validApplicationGroupIdentifier(
            primaryApplicationGroupIdentifier
        ), let groupContainer = resolveApplicationGroupContainer(
            identifier: applicationGroupIdentifier,
            fileManager: fileManager,
            resolver: applicationGroupContainerResolver
        ) else {
            throw GameModeHostCapabilityError.coordinationStorageUnavailable(
                nil,
                "signed App Group container is unavailable"
            )
        }
        let directory = evidenceDirectoryURL(groupContainer: groupContainer)
        let trustedAncestor = groupContainer.standardizedFileURL
        // Game Mode coordination is always confined to the signed App Group.
        // The fallback remains an input only for call-site compatibility and
        // is never an admissible native-host evidence destination.
        _ = fallbackLogURL
        do {
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                directory,
                trustedAncestor: trustedAncestor,
                privateTailComponentCount: 1
            )
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                directory,
                fileManager: fileManager
            ) else {
                throw GameModeHostCapabilityError.coordinationStorageUnavailable(
                    directory,
                    "directory is unsafe"
                )
            }
            let evidence = directory.appending(
                path: evidenceFileName,
                directoryHint: .notDirectory
            )
            try FileSystemItemPolicy.normalizeExistingOwnedPrivateRegularFile(evidence)
            return evidence
        } catch let error as GameModeHostCapabilityError {
            throw error
        } catch {
            throw GameModeHostCapabilityError.coordinationStorageUnavailable(
                directory,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private nonisolated static func validApplicationGroupIdentifier(
        _ value: String?
    ) -> String? {
        guard let identifier = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !identifier.isEmpty, !identifier.contains("$(") else {
            return nil
        }
        return identifier
    }

    private nonisolated static func resolveApplicationGroupContainer(
        identifier: String,
        fileManager: FileManager,
        resolver: ((String) -> URL?)?
    ) -> URL? {
        if let resolver {
            return resolver(identifier)?.standardizedFileURL
        }
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )?.standardizedFileURL
    }

    private nonisolated static func evidenceDirectoryURL(
        groupContainer: URL
    ) -> URL {
        groupContainer
            .appending(
                path: "Library/Application Support/ForgePlay",
                directoryHint: .isDirectory
            )
            .appending(path: evidenceDirectoryName, directoryHint: .isDirectory)
            .standardizedFileURL
    }
}

enum GameModeHostEnvironment {
    nonisolated static let requestedKey = "FORGEPLAY_GAME_MODE_HOST_REQUESTED"
    nonisolated static let availabilityKey = "FORGEPLAY_GAME_MODE_HOST_AVAILABILITY"
    nonisolated static let disabledReasonKey = "FORGEPLAY_GAME_MODE_HOST_DISABLED_REASON"
    nonisolated static let enabledKey = "FORGEPLAY_GAME_MODE_HOST_ENABLED"
    nonisolated static let executableKey = "FORGEPLAY_GAME_MODE_HOST_EXECUTABLE"
    nonisolated static let bundleIdentifierKey = "FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER"
    nonisolated static let executableSHA256Key = "FORGEPLAY_GAME_MODE_HOST_EXECUTABLE_SHA256"
    nonisolated static let modeKey = "FORGEPLAY_GAME_MODE_HOST_MODE"
    nonisolated static let ntdllKey = "FORGEPLAY_GAME_MODE_HOST_NTDLL"
    nonisolated static let evidenceFileKey = "FORGEPLAY_GAME_MODE_HOST_EVIDENCE_FILE"
    nonisolated static let runIdentifierKey = "FORGEPLAY_GAME_MODE_HOST_RUN_ID"
    nonisolated static let prefixExecutionLockKey = "FORGEPLAY_PREFIX_EXECUTION_LOCK"
    nonisolated static let directTargetKey = "FORGEPLAY_GAME_MODE_DIRECT_TARGET"
    nonisolated static let routedKey = "FORGEPLAY_GAME_MODE_HOST_ROUTED"
    nonisolated static let steamChildMode = "steam-child"
    nonisolated static let notRequestedAvailability = "not-requested"

    nonisolated static func applying(
        _ capability: GameModeHostCapability,
        to environment: [String: String]
    ) -> [String: String] {
        var result = environment
        result[requestedKey] = "1"
        result[availabilityKey] = "ready"
        result.removeValue(forKey: disabledReasonKey)
        result[enabledKey] = "1"
        result[executableKey] = capability.executableURL.path
        result[bundleIdentifierKey] = capability.bundleIdentifier
        result[executableSHA256Key] = capability.executableSHA256
        result.removeValue(forKey: directTargetKey)
        result.removeValue(forKey: routedKey)
        return result
    }

    nonisolated static func applying(
        _ selection: GameModeSteamChildHostSelection,
        to environment: [String: String]
    ) -> [String: String] {
        var result = applying(selection.host, to: environment)
        result[modeKey] = steamChildMode
        result[ntdllKey] = selection.runtimeNtdllURL.path
        result[evidenceFileKey] = selection.evidenceLogURL.path
        result[runIdentifierKey] = selection.runIdentifier
        result[prefixExecutionLockKey] = selection.prefixExecutionLockURL.path
        return result
    }

    nonisolated static func removingHostSelection(
        from environment: [String: String],
        disabledReason: String? = nil
    ) -> [String: String] {
        var result = environment
        result[requestedKey] = "1"
        result[availabilityKey] = "unavailable"
        if let disabledReason {
            result[disabledReasonKey] = disabledReason
        } else {
            result.removeValue(forKey: disabledReasonKey)
        }
        result.removeValue(forKey: enabledKey)
        result.removeValue(forKey: executableKey)
        result.removeValue(forKey: bundleIdentifierKey)
        result.removeValue(forKey: executableSHA256Key)
        result.removeValue(forKey: modeKey)
        result.removeValue(forKey: ntdllKey)
        result.removeValue(forKey: evidenceFileKey)
        result.removeValue(forKey: runIdentifierKey)
        result.removeValue(forKey: prefixExecutionLockKey)
        result.removeValue(forKey: directTargetKey)
        result.removeValue(forKey: routedKey)
        return result
    }

    nonisolated static func applyingStandardLaunch(
        to environment: [String: String]
    ) -> [String: String] {
        var result = removingHostSelection(from: environment)
        result[requestedKey] = "0"
        result[availabilityKey] = notRequestedAvailability
        result.removeValue(forKey: disabledReasonKey)
        return result
    }

    nonisolated static func applyingStandardLaunch(
        to environment: [String: String],
        evidenceLogURL: URL,
        runIdentifier: String
    ) -> [String: String] {
        var result = applyingStandardLaunch(to: environment)
        if evidenceLogURL.isFileURL,
           evidenceLogURL.path.hasPrefix("/"),
           let identifier = UUID(uuidString: runIdentifier) {
            result[evidenceFileKey] = evidenceLogURL.standardizedFileURL.path
            result[runIdentifierKey] = identifier.uuidString.lowercased()
        }
        return result
    }
}
