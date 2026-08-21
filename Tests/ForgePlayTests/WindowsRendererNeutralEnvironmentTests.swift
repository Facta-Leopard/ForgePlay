import Foundation
import XCTest
@testable import ForgePlay

final class WindowsRendererNeutralEnvironmentTests: XCTestCase {
    func testCaptureAndClonePreserveUnrelatedKeysAndStripBrokerMarkers()
        throws {
        let catalog = try WindowsRendererEnvironmentCatalog(
            names: ["VK_ICD_FILENAMES", "DXVK_CONFIG_FILE"]
        )
        let base = [
            "Path": "/usr/bin",
            "vk_icd_filenames": "base-icd.json",
            "FORGEPLAY_EXECUTION_DESCRIPTOR_FD_V1": "7",
            "forgeplay_internal_test": "secret",
        ]

        let projection = try WindowsRendererNeutralEnvironmentProjection
            .capture(catalog: catalog, environment: base)
        let clone = try projection.applying(to: base)

        XCTAssertEqual(clone.values["Path"], "/usr/bin")
        XCTAssertEqual(
            clone.values["VK_ICD_FILENAMES"],
            "base-icd.json"
        )
        XCTAssertNil(clone.values["DXVK_CONFIG_FILE"])
        XCTAssertFalse(
            clone.values.keys.contains {
                $0.uppercased().hasPrefix("FORGEPLAY_")
            }
        )
    }

    func testEmptyCatalogProducesAUsableNeutralClone() throws {
        let catalog = try WindowsRendererEnvironmentCatalog(names: [])
        let projection = try WindowsRendererNeutralEnvironmentProjection
            .capture(
                catalog: catalog,
                environment: ["PATH": "/usr/bin"]
            )
        let clone = try projection.applying(
            to: [
                "PATH": "/usr/bin",
                "FORGEPLAY_EXECUTION_AUTHORITY_FD_V1": "12",
            ]
        )

        XCTAssertEqual(clone.values, ["PATH": "/usr/bin"])
        XCTAssertEqual(projection.entries.count, 0)
        XCTAssertFalse(projection.baseProjectionSHA256.isZero)
    }

    func testCaseInsensitiveDuplicatesAreRejected() throws {
        let catalog = try WindowsRendererEnvironmentCatalog(
            names: ["VK_ICD_FILENAMES"]
        )
        XCTAssertThrowsError(
            try WindowsRendererNeutralEnvironmentProjection.capture(
                catalog: catalog,
                environment: [
                    "VK_ICD_FILENAMES": "one",
                    "vk_icd_filenames": "two",
                ]
            )
        )
    }

    func testCloneBudgetHasExactCountAndReleasesIdempotently() throws {
        let catalog = try WindowsRendererEnvironmentCatalog(names: [])
        let projection = try WindowsRendererNeutralEnvironmentProjection
            .capture(catalog: catalog, environment: [:])
        let clone = try projection.applying(to: [:])
        let budget = WindowsRendererEnvironmentCloneBudget()
        var leases: [WindowsRendererEnvironmentCloneLease] = []
        for _ in 0..<WindowsRendererNeutralEnvironmentProjection
            .maximumConcurrentCloneCount {
            leases.append(try budget.reserve(clone))
        }

        XCTAssertThrowsError(try budget.reserve(clone))
        XCTAssertEqual(
            budget.liveResourceCount,
            WindowsRendererNeutralEnvironmentProjection
                .maximumConcurrentCloneCount
        )
        for lease in leases {
            lease.release()
            lease.release()
        }
        XCTAssertEqual(budget.liveResourceCount, 0)
        XCTAssertEqual(budget.liveResourceBytes, 0)
    }
}
