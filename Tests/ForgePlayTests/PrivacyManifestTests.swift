import Foundation
import XCTest

final class PrivacyManifestTests: XCTestCase {
    func testPrivacyManifestDeclaresCommercialRuntimePrivacyContract() throws {
        let manifest = try privacyManifest()

        XCTAssertEqual(manifest.tracking, false)
        XCTAssertEqual(manifest.trackingDomains, [])
        XCTAssertTrue(manifest.collectedDataTypes.isEmpty)
        XCTAssertEqual(
            manifest.accessedAPITypeReasons,
            [
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
                "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]
            ]
        )
    }

    func testAppStoreControllerEntitlementsStayOnMainApp() throws {
        let root = try projectRoot()
        let mainEntitlements = try propertyList(
            at: root.appending(path: "Sources/ForgePlay/ForgePlay-AppStore.entitlements")
        )
        let runtimeEntitlements = try propertyList(
            at: root.appending(path: "Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements")
        )

        XCTAssertEqual(mainEntitlements["com.apple.security.device.usb"] as? Bool, true)
        XCTAssertEqual(mainEntitlements["com.apple.security.device.bluetooth"] as? Bool, true)
        XCTAssertEqual(
            Set(runtimeEntitlements.keys),
            [
                "com.apple.security.app-sandbox",
                "com.apple.security.inherit",
                "com.apple.security.cs.allow-unsigned-executable-memory",
                "com.apple.security.cs.disable-library-validation"
            ]
        )
        XCTAssertEqual(runtimeEntitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(runtimeEntitlements["com.apple.security.inherit"] as? Bool, true)
        XCTAssertEqual(
            runtimeEntitlements["com.apple.security.cs.allow-unsigned-executable-memory"] as? Bool,
            true
        )
        XCTAssertEqual(
            runtimeEntitlements["com.apple.security.cs.disable-library-validation"] as? Bool,
            true
        )
    }

    private func privacyManifest() throws -> PrivacyManifest {
        let url = try projectRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "PrivacyInfo.xcprivacy", directoryHint: .notDirectory)
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let accessedTypes = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var accessedAPITypeReasons: [String: [String]] = [:]
        for entry in accessedTypes {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            accessedAPITypeReasons[type] = reasons
        }

        return PrivacyManifest(
            tracking: try XCTUnwrap(plist["NSPrivacyTracking"] as? Bool),
            trackingDomains: try XCTUnwrap(plist["NSPrivacyTrackingDomains"] as? [String]),
            collectedDataTypes: try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [Any]),
            accessedAPITypeReasons: accessedAPITypeReasons
        )
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
        }
        throw XCTSkip("Project root not found")
    }
}

private struct PrivacyManifest {
    var tracking: Bool
    var trackingDomains: [String]
    var collectedDataTypes: [Any]
    var accessedAPITypeReasons: [String: [String]]
}
