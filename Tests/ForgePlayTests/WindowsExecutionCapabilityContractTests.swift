import Foundation
import XCTest
@testable import ForgePlay

final class WindowsExecutionCapabilityContractTests: XCTestCase {
    func testSHA256AndCanonicalRunIDAreStable() throws {
        XCTAssertEqual(
            WindowsExecutionSHA256.hash(Data("abc".utf8)).hexadecimal,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let runID = try WindowsExecutionRunID(
            canonicalString: "00112233-4455-4677-8899-aabbccddeeff"
        )
        XCTAssertEqual(
            runID.canonicalString,
            "00112233-4455-4677-8899-aabbccddeeff"
        )
        XCTAssertThrowsError(
            try WindowsExecutionRunID(
                canonicalString: "00112233-4455-4677-8899-AABBCCDDEEFF"
            )
        )
        XCTAssertThrowsError(
            try WindowsExecutionRunID(
                canonicalString: "00112233-4455-6677-8899-aabbccddeeff"
            )
        ) { error in
            XCTAssertEqual(
                (error as? WindowsExecutionContractError)?.reason,
                .capabilityDescriptorInvalid
            )
        }
    }

    func testPreparedBootstrapIsExactly184BytesAndRoundTrips() throws {
        let bootstrap = try makeBootstrap()
        let encoded = bootstrap.encoded()

        XCTAssertEqual(encoded.count, WindowsPreparedSessionBootstrapV2.byteCount)
        XCTAssertEqual(
            try WindowsPreparedSessionBootstrapV2.decode(encoded),
            bootstrap
        )
        XCTAssertThrowsError(
            try WindowsPreparedSessionBootstrapV2.decode(encoded + Data([0]))
        )
    }

    func testFrozenProviderRegistryAndHelloHeaderAreAuthenticatedSeparately()
        throws {
        let registry = try WindowsExecutionProviderRegistry.standalone()
        try registry.validateFrozenFingerprint()
        XCTAssertEqual(
            registry.fingerprintSHA256.hexadecimal,
            WindowsExecutionProviderRegistry.standaloneFingerprintHex
        )

        let requestID = try WindowsExecutionAuthorityIdentifier(
            bytes: Array(1...16)
        )
        let header = try WindowsExecutionAuthorityHeaderV1(
            messageType: .hello,
            flags: [],
            payloadBytes: 0,
            requestID: requestID,
            servicesInstanceID: .zero
        )
        XCTAssertEqual(
            header.encoded().count,
            WindowsExecutionAuthorityHeaderV1.byteCount
        )
        XCTAssertEqual(
            WindowsExecutionAuthorityHeaderV1.admitHello(header.encoded()),
            .trusted(header)
        )

        let semanticallyRejected = try WindowsExecutionAuthorityHeaderV1(
            messageType: .hello,
            flags: [.isResponse],
            payloadBytes: 0,
            requestID: requestID,
            servicesInstanceID: .zero
        )
        XCTAssertEqual(
            WindowsExecutionAuthorityHeaderV1.admitHello(
                semanticallyRejected.encoded()
            ),
            .trustedSemanticRejection(requestID: requestID)
        )

        var structurallyInvalid = header.encoded()
        structurallyInvalid[0] ^= 0xff
        XCTAssertEqual(
            WindowsExecutionAuthorityHeaderV1.admitHello(structurallyInvalid),
            .silentClose
        )
    }

    private func makeBootstrap() throws
        -> WindowsPreparedSessionBootstrapV2 {
        let runID = try WindowsExecutionRunID(
            canonicalString: "00112233-4455-4677-8899-aabbccddeeff"
        )
        return try WindowsPreparedSessionBootstrapV2(
            sequence: 7,
            runID: runID,
            sessionNonce: digest("nonce"),
            prefixScopeSHA256: digest("prefix"),
            runtimeFingerprintSHA256: digest("runtime"),
            launchDescriptorRecordSHA256: digest("descriptor"),
            rendererCapabilityFingerprintSHA256: digest("renderer")
        )
    }

    private func digest(_ value: String) -> WindowsExecutionSHA256 {
        .hash(Data(value.utf8))
    }
}
