import Foundation
import XCTest
@testable import ForgePlay

final class PrefixExecutionLeaseTests: XCTestCase {
    func testDirectReleaseUsesSignedApplicationGroupForCoordination() throws {
        let group = "group.com.forgeplay.client"
        let groupContainer = URL(
            fileURLWithPath: "/tmp/ForgePlayGroupContainer",
            isDirectory: true
        )

        let applicationSupport = try PrefixExecutionLease
            .defaultCoordinationApplicationSupportURL(
                sandboxEnabled: false,
                applicationGroupIdentifier: group,
                applicationGroupContainerResolver: { identifier in
                    XCTAssertEqual(identifier, group)
                    return groupContainer
                }
            )

        XCTAssertEqual(
            applicationSupport,
            groupContainer.appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )
        )
    }

    func testSignedApplicationGroupContainerFailureDoesNotFallBackToUserDomain() {
        let group = "group.com.forgeplay.client"

        XCTAssertThrowsError(
            try PrefixExecutionLease.defaultCoordinationApplicationSupportURL(
                sandboxEnabled: false,
                applicationGroupIdentifier: group,
                applicationGroupContainerResolver: { _ in nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? PathManagerError,
                .validationFailed(
                    nil,
                    "Game Mode App Group container is unavailable: \(group)"
                )
            )
        }
    }

    func testSharedExecutionLeasesCanCoexistAndBlockMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        let second = try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        defer {
            first.release()
            second.release()
        }

        XCTAssertThrowsError(try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )) { error in
            guard case .conflictingOperation(_, .exclusiveMutation) = error as? PrefixExecutionLeaseError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testExclusiveMutationBlocksSharedExecutionUntilReleased() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let mutation = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        XCTAssertThrowsError(try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )) { error in
            guard case .conflictingOperation(_, .sharedExecution) = error as? PrefixExecutionLeaseError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        mutation.release()
        let execution = try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        execution.release()
    }

    func testLaunchLeaseDowngradesForExecutionAndOnlyUpgradesAfterPeersExit() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let launchLease = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        defer { launchLease.release() }
        try launchLease.transitionToSharedExecution()
        XCTAssertEqual(launchLease.mode, .sharedExecution)

        let gameLease = try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        XCTAssertThrowsError(try launchLease.transitionToExclusiveMutation()) { error in
            guard case .conflictingOperation(_, .exclusiveMutation) = error as? PrefixExecutionLeaseError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(launchLease.mode, .sharedExecution)

        gameLease.release()
        try launchLease.transitionToExclusiveMutation()
        XCTAssertEqual(launchLease.mode, .exclusiveMutation)
    }

    func testRejectsSymlinkLockFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lockURL = try PrefixExecutionLease.coordinatedLockURL(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = fixture.root.appending(path: "target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

        XCTAssertThrowsError(try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )) { error in
            XCTAssertEqual(error as? PrefixExecutionLeaseError, .unsafeLockFile(lockURL))
        }
    }

    func testExclusiveLeaseNormalizesExistingLockToOwnerOnlyPermissions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        let lockURL = initial.lockURL
        initial.release()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: lockURL.path
        )

        let normalized = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        defer { normalized.release() }
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testPrefixReplacementRebindsMetadataOnlyWithoutSharedExecutors() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gameLease = try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )

        try FileManager.default.removeItem(at: fixture.prefix)
        try FileManager.default.createDirectory(
            at: fixture.prefix,
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )) { error in
            guard case .conflictingOperation(_, .exclusiveMutation) = error as? PrefixExecutionLeaseError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        gameLease.release()
        let rebound = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        rebound.release()
    }

    func testLaunchLeaseRebindsAtomicPrefixReplacementBeforeSharedExecution() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacedPrefix = fixture.root.appending(
            path: "ReplacedPrefix",
            directoryHint: .isDirectory
        )
        let launchLease = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        defer { launchLease.release() }

        try FileManager.default.moveItem(
            at: fixture.prefix,
            to: replacedPrefix
        )
        try FileManager.default.createDirectory(
            at: fixture.prefix,
            withIntermediateDirectories: true
        )
        let replacementIdentity = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: fixture.prefix.path
            )[.systemFileNumber] as? NSNumber
        ).uint64Value

        try launchLease.transitionToSharedExecution()

        let metadata = try String(
            contentsOf: launchLease.lockURL,
            encoding: .utf8
        )
        XCTAssertTrue(metadata.contains("inode=\(replacementIdentity)\n"))
        let gameLease = try PrefixExecutionLease.acquireSharedExecution(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        gameLease.release()
    }

    func testWindowsHelperOwnershipUsesPreparedScopeAndReleasesLease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        let preparedScope = WindowsExecutionSHA256.hash(
            Data("prepared-prefix-scope".utf8)
        )
        let ownership = try lease.windowsHelperOwnership(
            preparedPrefixScopeSHA256: preparedScope
        )

        XCTAssertEqual(
            ownership.windowsHelperLeaseScopeSHA256,
            preparedScope
        )
        XCTAssertFalse(ownership.isReleased)
        try await ownership.releaseWindowsHelperLease()
        XCTAssertTrue(ownership.isReleased)

        let replacement = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: fixture.prefix,
            applicationSupportBaseURL: fixture.applicationSupport
        )
        replacement.release()
    }

    private func makeFixture() throws -> (root: URL, applicationSupport: URL, prefix: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "forgeplay-prefix-execution-lease-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        let prefix = root.appending(path: "ManagedData/Prefixes/SteamShared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        return (root, applicationSupport, prefix)
    }
}
