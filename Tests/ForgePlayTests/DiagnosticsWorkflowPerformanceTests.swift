import Foundation
import XCTest
@testable import ForgePlay

@MainActor
final class DiagnosticsWorkflowPerformanceTests: XCTestCase {
    func testPresentationWindowUsesLimitPlusOneTruncationSemantics() {
        let exact = DiagnosticPresentationWindow(Array(0..<50), limit: 50)
        XCTAssertEqual(exact.values, Array(0..<50))
        XCTAssertFalse(exact.isTruncated)

        let overflow = DiagnosticPresentationWindow(Array(0..<51), limit: 50)
        XCTAssertEqual(overflow.values, Array(0..<50))
        XCTAssertTrue(overflow.isTruncated)
        XCTAssertEqual(DiagnosticPresentationLimits.diagnosticQueryFetchLimit, 51)
        XCTAssertEqual(DiagnosticPresentationLimits.launchQueryFetchLimit, 51)
    }

    func testAIRequestEnvelopeAndGateKeepOriginalEvidenceAssociation() throws {
        var gate = DiagnosticExactTaskTokenGate()
        let token = try XCTUnwrap(gate.beginIfIdle())
        XCTAssertNil(gate.beginIfIdle(), "A repeated click must not start a second request.")

        let original = DiagnosticEvidenceAssociation(gameID: "game-a", launchRecordID: "launch-a")
        let envelope = DiagnosticAIRequestEnvelope(preview: "preview-a", evidenceAssociation: original)
        let laterSelection = DiagnosticEvidenceAssociation(gameID: "game-b", launchRecordID: "launch-b")

        XCTAssertNotEqual(envelope.evidenceAssociation, laterSelection)
        XCTAssertEqual(envelope.evidenceAssociation, original)
        XCTAssertTrue(gate.release(token))
        XCTAssertNotNil(gate.beginIfIdle())
    }

    func testExactTokenGateRejectsStaleDecodePublication() {
        var gate = DiagnosticExactTaskTokenGate()
        let stale = gate.beginReplacingCurrent()
        let current = gate.beginReplacingCurrent()

        XCTAssertFalse(gate.owns(stale))
        XCTAssertFalse(gate.release(stale))
        XCTAssertTrue(gate.owns(current))
        XCTAssertTrue(gate.release(current))
    }

    func testOversizedUTF8PayloadIsRejectedBeforeConsumerAllocation() {
        var consumerWasCalled = false
        XCTAssertThrowsError(try DiagnosticRecordPayloadDecoder.withBoundedUTF8Bytes(
            "12345",
            recordIdentifier: "oversized",
            limit: 4
        ) { bytes in
            consumerWasCalled = true
            return Data(bytes)
        }) { error in
            XCTAssertEqual(
                error as? DiagnosticRecordDecodeError,
                .oversized("oversized", 5, 4)
            )
        }
        XCTAssertFalse(consumerWasCalled)
    }

    func testDecodePipelineBoundsConcurrencyAndPreservesOrder() async throws {
        let probe = DiagnosticDecodeConcurrencyProbe()
        let snapshots = makeSnapshots(count: 7)
        let outcomes = try await DiagnosticPresentationDecodePipeline.decode(
            snapshots,
            maxConcurrent: 2
        ) { snapshot in
            await probe.enter()
            do {
                try await Task.sleep(for: .milliseconds(10))
                await probe.leave()
                return .failure(snapshot: snapshot, error: .decodeFailed(snapshot.id))
            } catch {
                await probe.leave()
                throw error
            }
        }

        let identifiers = outcomes.map(\.snapshot.id)
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(identifiers, snapshots.map(\.id))
        XCTAssertEqual(maximumActive, 2)
    }

    func testDecodePipelineCancellationDoesNotProduceAResult() async throws {
        let latch = DiagnosticDecodeStartLatch()
        let snapshots = makeSnapshots(count: 3)
        let task = Task {
            try await DiagnosticPresentationDecodePipeline.decode(
                snapshots,
                maxConcurrent: 1
            ) { snapshot in
                await latch.signal()
                try await Task.sleep(for: .seconds(10))
                return .failure(snapshot: snapshot, error: .decodeFailed(snapshot.id))
            }
        }

        await latch.waitUntilSignalled()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must prevent decode publication.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testDiagnosticsViewOwnsOneSharedDependencyQuerySetAndBoundedHistoryQueries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/ForgePlay/UI/DiagnosticsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "@Query(sort: \\PrefixRecord.displayName)").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "@Query(sort: \\SteamGameRecord.name)").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "@Query(sort: \\RuntimeRecord.runtime)").count - 1, 1)
        XCTAssertTrue(source.contains("diagnosticDescriptor.fetchLimit = DiagnosticPresentationLimits.diagnosticQueryFetchLimit"))
        XCTAssertTrue(source.contains("launchDescriptor.fetchLimit = DiagnosticPresentationLimits.launchQueryFetchLimit"))

        let cardStart = try XCTUnwrap(source.range(of: "private struct DiagnosticResultCard"))
        let cardEnd = try XCTUnwrap(source.range(
            of: "private struct InvalidDiagnosticRecordCard",
            range: cardStart.upperBound..<source.endIndex
        ))
        let cardSource = source[cardStart.lowerBound..<cardEnd.lowerBound]
        XCTAssertFalse(cardSource.contains("@Query"))
    }

    func testDashboardFetchesOnlyTheDiagnosticRecordItDisplays() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/ForgePlay/UI/DashboardView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("diagnosticDescriptor.fetchLimit = 1"))
        XCTAssertTrue(source.contains("if let latest = diagnostics.first"))
    }

    func testSetupSheetsDoNotDeclareLaunchHistoryQueries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "Sources/ForgePlay/UI/SheetHostView.swift",
            "Sources/ForgePlay/UI/ManagedStorageLocationView.swift"
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("LaunchRecord"), relativePath)
            XCTAssertFalse(source.contains("launchRecords"), relativePath)
        }
    }

    func testReadinessOnlyViewsFetchAtMostOneSteamGameReference() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "Sources/ForgePlay/UI/RootView.swift",
            "Sources/ForgePlay/UI/SheetHostView.swift",
            "Sources/ForgePlay/UI/ManagedStorageLocationView.swift"
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("gameDescriptor.fetchLimit = 1"),
                relativePath
            )
        }
    }

    private func makeSnapshots(count: Int) -> [DiagnosticRecordDecodeSnapshot] {
        (0..<count).map { index in
            DiagnosticRecordDecodeSnapshot(
                id: "diagnostic-\(index)",
                source: DiagnosticRecordSource.ruleEngine.rawValue,
                resultJSON: "{}",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }
}

private actor DiagnosticDecodeConcurrencyProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
    }
}

private actor DiagnosticDecodeStartLatch {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilSignalled() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
