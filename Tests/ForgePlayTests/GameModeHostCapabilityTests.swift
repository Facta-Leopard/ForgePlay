// SPDX-FileCopyrightText: 2026 Facta-Leopard
// SPDX-License-Identifier: GPL-3.0-only
//
// ForgePlay Game Mode
// Original source: https://github.com/Facta-Leopard/ForgePlay

import Foundation
import XCTest
@testable import ForgePlay

final class GameModeHostCapabilityTests: XCTestCase {
    func testCapabilityErrorProvidesStableTechnicalDescription() {
        let error = GameModeHostCapabilityError.applicationGroupRequired

        XCTAssertTrue(
            error.forgePlayTechnicalDescription.hasPrefix(
                "host-application-group-required:"
            )
        )
        XCTAssertEqual(
            forgePlayTechnicalErrorSummary(error),
            error.forgePlayTechnicalDescription
        )
        XCTAssertFalse(
            forgePlayTechnicalErrorSummary(error).contains(
                "GameModeHostCapabilityError 19"
            )
        )
    }

    func testValidFixedHostProducesCapabilityAndEnvironment() throws {
        let fixture = try makeFixture(assetCatalogCompatibilityIconFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        let capability = try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.helpers
        )

        XCTAssertTrue(capability.supportsGameMode)
        XCTAssertTrue(capability.isRosettaRuntimeComponent)
        XCTAssertEqual(capability.bundleIdentifier, "com.forgeplay.client.game-mode-host")
        XCTAssertEqual(capability.executableSHA256.count, 64)
        let environment = GameModeHostEnvironment.applying(capability, to: ["BASE": "1"])
        XCTAssertEqual(environment[GameModeHostEnvironment.enabledKey], "1")
        XCTAssertEqual(environment[GameModeHostEnvironment.executableKey], fixture.executable.path)
        XCTAssertEqual(environment["BASE"], "1")
    }

    func testSteamLaunchAdmissionRequiresApplicationGroupForBothProfiles() throws {
        let fixture = try makeFixture(assetCatalogCompatibilityIconFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        for (sandboxEnabled, applicationGroupIdentifier) in [
            (false, nil),
            (false, "" as String?),
            (false, "$(FORGEPLAY_APPLICATION_GROUP)" as String?),
            (true, nil),
            (true, "" as String?),
            (true, "$(FORGEPLAY_APPLICATION_GROUP)" as String?)
        ] {
            XCTAssertThrowsError(
                try inspector.inspectBundledHostForSteamLaunchAdmission(
                    mainBundleURL: fixture.root,
                    mainBundleIdentifier: "com.forgeplay.client",
                    sandboxEnabled: sandboxEnabled,
                    primaryApplicationGroupIdentifier:
                        applicationGroupIdentifier
                )
            ) { error in
                XCTAssertEqual(
                    error as? GameModeHostCapabilityError,
                    .applicationGroupRequired
                )
            }
        }
    }

    func testSteamLaunchAdmissionSelectsProfileFromMainSandboxState() throws {
        let fixture = try makeFixture(assetCatalogCompatibilityIconFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selectedProfiles = GameModeTestLockedValues<GameModeHostSigningProfile>()
        let inspector = testInspector { profile, applicationGroupIdentifier in
            selectedProfiles.append(profile)
            XCTAssertEqual(
                applicationGroupIdentifier,
                "group.com.forgeplay.client"
            )
            return nil
        }

        let sandboxCapability = try inspector
            .inspectBundledHostForSteamLaunchAdmission(
                mainBundleURL: fixture.root,
                mainBundleIdentifier: "com.forgeplay.client",
                sandboxEnabled: true,
                primaryApplicationGroupIdentifier:
                    "group.com.forgeplay.client"
            )
        let directCapability = try inspector
            .inspectBundledHostForSteamLaunchAdmission(
                mainBundleURL: fixture.root,
                mainBundleIdentifier: "com.forgeplay.client",
                sandboxEnabled: false,
                primaryApplicationGroupIdentifier:
                    "group.com.forgeplay.client"
            )

        XCTAssertEqual(sandboxCapability.appURL, fixture.app.standardizedFileURL)
        XCTAssertEqual(directCapability.appURL, fixture.app.standardizedFileURL)
        XCTAssertEqual(
            selectedProfiles.values,
            [.sandboxAppGroup, .directUserDomain]
        )
    }

    func testSteamLaunchAdmissionValidatesBundledHostWithoutPrefixInputs() throws {
        let fixture = try makeFixture(assetCatalogCompatibilityIconFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capability = try testInspector()
            .inspectBundledHostForSteamLaunchAdmission(
                mainBundleURL: fixture.root,
                mainBundleIdentifier: "com.forgeplay.client",
                sandboxEnabled: true,
                primaryApplicationGroupIdentifier:
                    "group.com.forgeplay.client"
            )

        XCTAssertEqual(capability.appURL, fixture.app.standardizedFileURL)
        XCTAssertEqual(
            capability.bundleIdentifier,
            "com.forgeplay.client.game-mode-host"
        )
    }

    func testSandboxSigningProfileRequiresExactInheritanceEntitlements() {
        let required: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.inherit": true,
            "com.apple.security.cs.allow-unsigned-executable-memory": true,
            "com.apple.security.cs.disable-library-validation": true
        ]

        XCTAssertNil(
            GameModeHostCapabilityInspector.signingProfileViolation(
                in: required,
                profile: .sandboxAppGroup
            )
        )
        var missing = required
        missing.removeValue(forKey: "com.apple.security.inherit")
        XCTAssertEqual(
            GameModeHostCapabilityInspector.signingProfileViolation(
                in: missing,
                profile: .sandboxAppGroup
            ),
            "required entitlement is missing: com.apple.security.inherit"
        )
        var mixed = required
        mixed["com.apple.security.application-groups"] = [
            "group.com.forgeplay.client"
        ]
        XCTAssertEqual(
            GameModeHostCapabilityInspector.signingProfileViolation(
                in: mixed,
                profile: .sandboxAppGroup
            ),
            "entitlement is forbidden for sandbox-app-group: " +
                "com.apple.security.application-groups"
        )
    }

    func testDirectSigningProfileRequiresExactApplicationGroupAndRuntimeEntitlements() {
        let group = "group.com.forgeplay.client"
        let required: [String: Any] = [
            "com.apple.security.application-groups": [group],
            "com.apple.security.cs.allow-unsigned-executable-memory": true,
            "com.apple.security.cs.disable-library-validation": true
        ]

        XCTAssertNil(
            GameModeHostCapabilityInspector.signingProfileViolation(
                in: required,
                profile: .directUserDomain,
                applicationGroupIdentifier: group
            )
        )
        for invalidGroups: [String] in [
            [],
            ["group.other"],
            [group, "group.other"]
        ] {
            var invalid = required
            invalid["com.apple.security.application-groups"] = invalidGroups
            XCTAssertNotNil(
                GameModeHostCapabilityInspector.signingProfileViolation(
                    in: invalid,
                    profile: .directUserDomain,
                    applicationGroupIdentifier: group
                )
            )
        }
        for forbiddenKey in [
            "com.apple.security.app-sandbox",
            "com.apple.security.inherit",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client"
        ] {
            var invalid = required
            invalid[forbiddenKey] = true
            XCTAssertEqual(
                GameModeHostCapabilityInspector.signingProfileViolation(
                    in: invalid,
                    profile: .directUserDomain,
                    applicationGroupIdentifier: group
                ),
                "entitlement is forbidden for direct-user-domain: \(forbiddenKey)"
            )
        }
    }

    func testDirectSigningProfileViolationUsesDirectDiagnostic() throws {
        let fixture = try makeFixture(assetCatalogCompatibilityIconFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector { profile, _ in
            profile == .directUserDomain ? "direct contract mismatch" : nil
        }

        XCTAssertThrowsError(
            try inspector.inspectBundledHostForSteamLaunchAdmission(
                mainBundleURL: fixture.root,
                mainBundleIdentifier: "com.forgeplay.client",
                sandboxEnabled: false,
                primaryApplicationGroupIdentifier:
                    "group.com.forgeplay.client"
            )
        ) { error in
            XCTAssertEqual(
                error as? GameModeHostCapabilityError,
                .directUserDomainContractInvalid(
                    fixture.app.standardizedFileURL,
                    "direct contract mismatch"
                )
            )
        }
    }

    func testCoordinationEvidenceAlwaysUsesPreparedApplicationGroupPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "forgeplay-game-mode-coordination-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let fallback = root.appending(path: "arbitrary/fallback.jsonl")
        let group = "group.com.forgeplay.client"

        let evidence = try GameModeHostCoordinationPaths.evidenceLogURL(
            fallbackLogURL: fallback,
            fileManager: fileManager,
            primaryApplicationGroupIdentifier: group,
            applicationGroupContainerResolver: { identifier in
                XCTAssertEqual(identifier, group)
                return root
            }
        )

        XCTAssertEqual(
            evidence.path,
            root.appending(
                path: "Library/Application Support/ForgePlay/" +
                    "GameModeProcessHostEvidence/GameModeProcessHost-v1.jsonl"
            ).path
        )
        XCTAssertNotEqual(evidence.standardizedFileURL, fallback.standardizedFileURL)
        XCTAssertEqual(
            GameModeHostCoordinationPaths.existingEvidenceDirectoryURL(
                fileManager: fileManager,
                primaryApplicationGroupIdentifier: group,
                applicationGroupContainerResolver: { _ in root }
            ),
            evidence.deletingLastPathComponent()
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: evidence.deletingLastPathComponent().path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            0o700
        )
    }

    func testCoordinationEvidenceFailsClosedWithoutApplicationGroupContainer() {
        XCTAssertThrowsError(
            try GameModeHostCoordinationPaths.evidenceLogURL(
                fallbackLogURL: URL(fileURLWithPath: "/tmp/fallback.jsonl"),
                primaryApplicationGroupIdentifier:
                    "group.com.forgeplay.client",
                applicationGroupContainerResolver: { _ in nil }
            )
        ) { error in
            guard case .coordinationStorageUnavailable(nil, _) =
                    error as? GameModeHostCapabilityError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStandardLaunchExplicitlyRemovesExperimentalHostSelection() {
        let environment = GameModeHostEnvironment.applyingStandardLaunch(to: [
            "BASE": "1",
            GameModeHostEnvironment.requestedKey: "1",
            GameModeHostEnvironment.availabilityKey: "ready",
            GameModeHostEnvironment.enabledKey: "1",
            GameModeHostEnvironment.executableKey: "/tmp/GameModeProcessHost",
            GameModeHostEnvironment.directTargetKey: "1",
            GameModeHostEnvironment.routedKey: "1"
        ])

        XCTAssertEqual(environment["BASE"], "1")
        XCTAssertEqual(environment[GameModeHostEnvironment.requestedKey], "0")
        XCTAssertEqual(
            environment[GameModeHostEnvironment.availabilityKey],
            GameModeHostEnvironment.notRequestedAvailability
        )
        XCTAssertNil(environment[GameModeHostEnvironment.enabledKey])
        XCTAssertNil(environment[GameModeHostEnvironment.executableKey])
        XCTAssertNil(environment[GameModeHostEnvironment.directTargetKey])
        XCTAssertNil(environment[GameModeHostEnvironment.routedKey])
    }

    func testStandardLaunchRetainsOnlyPathSafeSkipEvidenceIdentity() {
        let runIdentifier = UUID()
        let evidenceURL = URL(fileURLWithPath: "/tmp/forgeplay-game-mode-skip.jsonl")
        let environment = GameModeHostEnvironment.applyingStandardLaunch(
            to: [:],
            evidenceLogURL: evidenceURL,
            runIdentifier: runIdentifier.uuidString
        )

        XCTAssertEqual(
            environment[GameModeHostEnvironment.evidenceFileKey],
            evidenceURL.path
        )
        XCTAssertEqual(
            environment[GameModeHostEnvironment.runIdentifierKey],
            runIdentifier.uuidString.lowercased()
        )
        XCTAssertNil(environment[GameModeHostEnvironment.enabledKey])
    }

    func testRejectsUnexpectedAssetCatalogCompatibilityIconFile() throws {
        let fixture = try makeFixture(assetCatalogCompatibilityIconFile: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let infoPlist = fixture.app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoPlist),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        plist["CFBundleIconFile"] = "OtherIcon"
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: infoPlist, options: .atomic)
        let inspector = testInspector()

        XCTAssertThrowsError(try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.helpers
        )) { error in
            XCTAssertEqual(error as? GameModeHostCapabilityError, .identityDeclarationInvalid)
        }
    }

    func testRejectsHostWithoutGameModeDeclaration() throws {
        let fixture = try makeFixture(supportsGameMode: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        XCTAssertThrowsError(try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.helpers
        )) { error in
            XCTAssertEqual(error as? GameModeHostCapabilityError, .gameModeDeclarationMissing)
        }
    }

    func testRejectsBackgroundOnlyHost() throws {
        let fixture = try makeFixture(isUIElement: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        XCTAssertThrowsError(try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.helpers
        )) { error in
            XCTAssertEqual(error as? GameModeHostCapabilityError, .backgroundOnlyHost)
        }
    }

    func testRejectsSingleInstanceHost() throws {
        let fixture = try makeFixture(prohibitsMultipleInstances: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        XCTAssertThrowsError(try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.helpers
        )) { error in
            XCTAssertEqual(error as? GameModeHostCapabilityError, .backgroundOnlyHost)
        }
    }

    func testRejectsArm64Host() throws {
        let fixture = try makeFixture(cpuType: 0x0100_000c)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        XCTAssertThrowsError(try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.helpers
        )) { error in
            guard case .executableArchitectureUnsupported = error as? GameModeHostCapabilityError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsUnexpectedContainer() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = testInspector()

        XCTAssertThrowsError(try inspector.inspect(
            appURL: fixture.app,
            expectedBundleIdentifier: "com.forgeplay.client.game-mode-host",
            expectedContainerURL: fixture.root.appending(path: "Other", directoryHint: .isDirectory)
        )) { error in
            XCTAssertEqual(error as? GameModeHostCapabilityError, .unsafeAppBundle(fixture.app))
        }
    }

    private func testInspector(
        signingProfileViolation: @escaping @Sendable (
            GameModeHostSigningProfile,
            String?
        ) -> String? = { _, _ in nil }
    ) -> GameModeHostCapabilityInspector {
        GameModeHostCapabilityInspector(
            signatureValidator: { _ in true },
            signingProfileValidator: { _, profile, applicationGroupIdentifier in
                signingProfileViolation(profile, applicationGroupIdentifier)
            }
        )
    }

    private func makeFixture(
        supportsGameMode: Bool = true,
        isUIElement: Bool = false,
        prohibitsMultipleInstances: Bool = false,
        assetCatalogCompatibilityIconFile: Bool = false,
        cpuType: UInt32 = 0x0100_0007
    ) throws -> (root: URL, helpers: URL, app: URL, executable: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "forgeplay-game-mode-host-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let helpers = root.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        let app = helpers.appending(path: GameModeHostCapabilityInspector.hostBundleName, directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.forgeplay.client.game-mode-host",
            "CFBundleExecutable": GameModeHostCapabilityInspector.executableName,
            "CFBundleIconName": "AppIcon",
            "CFBundlePackageType": "APPL",
            "LSApplicationCategoryType": "public.app-category.games",
            "LSSupportsGameMode": supportsGameMode,
            "NSPrincipalClass": "WineApplication"
        ]
        if assetCatalogCompatibilityIconFile { plist["CFBundleIconFile"] = "AppIcon" }
        if isUIElement { plist["LSUIElement"] = true }
        if prohibitsMultipleInstances { plist["LSMultipleInstancesProhibited"] = true }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appending(path: "Info.plist"), options: .atomic)

        let executable = macOS.appending(path: GameModeHostCapabilityInspector.executableName)
        var binary = Data()
        var magic = UInt32(0xfeedfacf).littleEndian
        var cpuType = cpuType.littleEndian
        withUnsafeBytes(of: &magic) { binary.append(contentsOf: $0) }
        withUnsafeBytes(of: &cpuType) { binary.append(contentsOf: $0) }
        binary.append(Data(repeating: 0, count: 24))
        try binary.write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        return (root, helpers, app, executable)
    }
}

private final class GameModeTestLockedValues<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
