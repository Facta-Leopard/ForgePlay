// ForgePlay-authored clean-room output.
// Distribution remains blocked until the project owner records an explicit
// license and file/scope assignment. This file declares no license grant.

import CryptoKit
import Foundation

// MARK: - Fixed-width values

struct WindowsExecutionSHA256: Hashable, Sendable, Comparable, Codable {
    static let byteCount = 32
    static let zero = WindowsExecutionSHA256(
        uncheckedBytes: [UInt8](repeating: 0, count: byteCount)
    )

    let bytes: [UInt8]

    private init(uncheckedBytes: [UInt8]) {
        bytes = uncheckedBytes
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .schema,
                detail: "SHA-256 values contain exactly 32 bytes"
            )
        }
        self.bytes = bytes
    }

    init(hexadecimal: String) throws {
        guard hexadecimal.utf8.count == Self.byteCount * 2,
              hexadecimal.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .schema,
                detail: "SHA-256 text is 64 lowercase hexadecimal bytes"
            )
        }
        var result: [UInt8] = []
        result.reserveCapacity(Self.byteCount)
        var index = hexadecimal.startIndex
        for _ in 0..<Self.byteCount {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let value = UInt8(hexadecimal[index..<next], radix: 16) else {
                throw WindowsExecutionContractError(
                    reason: .capabilityDescriptorInvalid,
                    stage: .schema,
                    detail: "SHA-256 text contains an invalid byte"
                )
            }
            result.append(value)
            index = next
        }
        bytes = result
    }

    static func hash(_ data: Data) -> Self {
        Self(uncheckedBytes: Array(SHA256.hash(data: data)))
    }

    static func hash(_ bytes: [UInt8]) -> Self {
        hash(Data(bytes))
    }

    var hexadecimal: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    var isZero: Bool {
        Self.constantTimeEqual(bytes, Self.zero.bytes)
    }

    func isAuthenticatedEqual(to other: Self) -> Bool {
        Self.constantTimeEqual(bytes, other.bytes)
    }

    static func constantTimeEqual(
        _ lhs: some Collection<UInt8>,
        _ rhs: some Collection<UInt8>
    ) -> Bool {
        var lhsIterator = lhs.makeIterator()
        var rhsIterator = rhs.makeIterator()
        var difference: UInt8 = 0
        var count = 0
        while true {
            let left = lhsIterator.next()
            let right = rhsIterator.next()
            switch (left, right) {
            case let (.some(left), .some(right)):
                difference |= left ^ right
                count += 1
            case (.none, .none):
                return count > 0 && difference == 0
            case (.some, .none), (.none, .some):
                // Continue over the longer input so a length mismatch is not
                // an early byte-position oracle.
                difference |= 1
                var remaining = left ?? right
                while remaining != nil {
                    count += 1
                    remaining = left == nil
                        ? rhsIterator.next()
                        : lhsIterator.next()
                }
                return false
            }
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isAuthenticatedEqual(to: rhs)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(hexadecimal: container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexadecimal)
    }
}

struct WindowsExecutionRunID: Hashable, Sendable, Comparable, Codable {
    static let byteCount = 16
    let bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .schema,
                detail: "runID contains exactly 16 RFC 4122 bytes"
            )
        }
        let version = bytes[6] >> 4
        let hasRFC4122Variant = bytes[8] & 0xc0 == 0x80
        guard (1...5).contains(version), hasRFC4122Variant else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .schema,
                detail: "runID has an invalid RFC 4122 version or variant"
            )
        }
        self.bytes = bytes
    }

    init(uuid: UUID) throws {
        var value = uuid.uuid
        try self.init(bytes: withUnsafeBytes(of: &value) { Array($0) })
    }

    init(canonicalString: String) throws {
        let scalars = Array(canonicalString.utf8)
        guard scalars.count == 36,
              scalars[8] == 45,
              scalars[13] == 45,
              scalars[18] == 45,
              scalars[23] == 45,
              canonicalString == canonicalString.lowercased() else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .evidence,
                detail: "runID is a lowercase canonical RFC 4122 UUID"
            )
        }
        let compact = canonicalString.replacingOccurrences(of: "-", with: "")
        var decoded: [UInt8] = []
        var index = compact.startIndex
        for _ in 0..<Self.byteCount {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw WindowsExecutionContractError(
                    reason: .lifecycleEvidenceInvalid,
                    stage: .evidence,
                    detail: "runID contains a non-hexadecimal byte"
                )
            }
            decoded.append(byte)
            index = next
        }
        try self.init(bytes: decoded)
    }

    var canonicalString: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        var result = ""
        for (index, character) in hex.enumerated() {
            if [8, 12, 16, 20].contains(index) {
                result.append("-")
            }
            result.append(character)
        }
        return result
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(canonicalString: container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }
}

struct WindowsExecutionAuthorityIdentifier: Hashable, Sendable, Codable {
    static let byteCount = 16
    static let zero = WindowsExecutionAuthorityIdentifier(
        uncheckedBytes: [UInt8](repeating: 0, count: byteCount)
    )

    let bytes: [UInt8]

    private init(uncheckedBytes: [UInt8]) {
        bytes = uncheckedBytes
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .schema,
                detail: "authority identifiers contain exactly 16 bytes"
            )
        }
        self.bytes = bytes
    }

    var isZero: Bool {
        WindowsExecutionSHA256.constantTimeEqual(bytes, Self.zero.bytes)
    }
}

// MARK: - Frozen enum registry

enum WindowsExecutionMode: UInt8, Codable, CaseIterable, Sendable {
    case maintenance = 1
    case sessionAttached = 2
}

enum WindowsRendererRequirement: UInt8, Codable, CaseIterable, Sendable {
    case forbidden = 1
    case inheritedWhenSupported = 2
}

enum WindowsExecutionLifecycleKind: UInt8, Codable, CaseIterable, Sendable {
    case oneShot = 1
    case windowsService = 2
}

enum WindowsServicePersistence: UInt8, Codable, CaseIterable, Sendable {
    case notApplicable = 0
    case guestPersistent = 1
    case sessionTransient = 2
}

enum WindowsExecutionLineageRole: UInt8, Codable, CaseIterable, Sendable {
    case directTarget = 1
    case descendant = 2
    case boundServiceActivation = 3
    case trustedHelperRoot = 4
}

enum WindowsRendererIntent: UInt8, Codable, CaseIterable, Sendable {
    case unknown = 0
    case nonRenderingCandidate = 1
    case rendering = 2
}

enum WindowsRendererArchitectureSupport: UInt8, Codable, CaseIterable, Sendable {
    case unsupported = 0
    case supported = 1
}

enum WindowsServiceBindingState: UInt8, Codable, CaseIterable, Sendable {
    case notApplicable = 0
    case valid = 1
    case missing = 2
    case stale = 3
    case scopeMismatch = 4
    case alreadyConsumed = 5
}

enum WindowsAdmissionDecision: UInt8, Codable, CaseIterable, Sendable {
    case selectedRenderer = 1
    case guardedRendererNeutral = 2
    case reject = 3
}

enum WindowsPEMachine: UInt16, Codable, CaseIterable, Comparable, Sendable {
    case pe32I386 = 332
    case pe32PlusAMD64 = 34_404

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum WindowsExecutionReasonCode: UInt32, Codable, CaseIterable, Sendable {
    case capabilityDescriptorInvalid = 1001
    case capabilityDescriptorExpired = 1002
    case capabilityDescriptorReplayed = 1003
    case capabilityRequiredAbsent = 1004
    case capabilityMajorMismatch = 1005
    case capabilityFingerprintMismatch = 1006
    case capabilityProfileInvalid = 1007
    case admissionRoleUnknown = 1101
    case admissionPEInvalid = 1102
    case admissionRendererClosureInvalid = 1103
    case admissionDirectRendererArchitectureUnsupported = 1104
    case admissionIntentUnknown = 1105
    case admissionRendererRequired = 1106
    case admissionRendererLoadBlocked = 1107
    case serviceBindingMissing = 1201
    case serviceBindingStale = 1202
    case serviceBindingScopeMismatch = 1203
    case serviceBindingReplayed = 1204
    case serviceImageReplaced = 1205
    case serviceBindingCommitFailed = 1206
    case serviceBindingUnexpected = 1207
    case lifecycleDeadlineExceeded = 1301
    case lifecycleEvidenceInvalid = 1302
    case lifecycleCleanupFailed = 1303
    case lifecycleProcessIdentityMismatch = 1304
    case wow64TransitionInvariant = 1401
    case bridgeAuthorityUnavailable = 1501
    case bridgeProtocolInvalid = 1502
    case bridgeRuntimeRegistryMismatch = 1503
    case bridgeEnvironmentInvalid = 1504
    case bridgeEnvironmentApplyFailed = 1505
    case bridgeImageHandoffFailed = 1506
    case bridgeGenerationMismatch = 1507
    case bridgeCallerLineageInvalid = 1508
}

enum WindowsExecutionFailureStage: String, Codable, Sendable {
    case schema
    case negotiation
    case descriptor
    case rendererSnapshot
    case admission
    case authority
    case lifecycle
    case evidence
    case cleanup
}

struct WindowsExecutionContractError: LocalizedError, Equatable, Sendable {
    let reason: WindowsExecutionReasonCode
    let stage: WindowsExecutionFailureStage
    let detail: String

    var errorDescription: String? {
        "\(stage.rawValue): \(reason.rawValue): \(detail)"
    }
}

// MARK: - Explicit little-endian codecs

enum WindowsExecutionBinaryCodec {
    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

struct WindowsExecutionByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var remainingCount: Int {
        bytes.count - offset
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= bytes.count - count else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .schema,
                detail: "fixed-layout input is truncated"
            )
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readData(count: Int) throws -> Data {
        Data(try readBytes(count: count))
    }

    mutating func readUInt8() throws -> UInt8 {
        try readBytes(count: 1)[0]
    }

    mutating func readUInt16() throws -> UInt16 {
        let value = try readBytes(count: 2)
        return UInt16(value[0]) | UInt16(value[1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let value = try readBytes(count: 4)
        return UInt32(value[0]) |
            UInt32(value[1]) << 8 |
            UInt32(value[2]) << 16 |
            UInt32(value[3]) << 24
    }

    mutating func readUInt64() throws -> UInt64 {
        let value = try readBytes(count: 8)
        return value.enumerated().reduce(UInt64(0)) {
            $0 | UInt64($1.element) << UInt64($1.offset * 8)
        }
    }

    mutating func requireEnd() throws {
        guard remainingCount == 0 else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .schema,
                detail: "fixed-layout input has trailing bytes"
            )
        }
    }
}

// MARK: - Provider and Runtime capability registries

struct WindowsExecutionProviderEntry: Hashable, Sendable, Codable {
    let identifierSHA256: WindowsExecutionSHA256
    let major: UInt16
    let minor: UInt16

    init(
        identifierSHA256: WindowsExecutionSHA256,
        major: UInt16,
        minor: UInt16
    ) throws {
        guard major != 0 else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .negotiation,
                detail: "provider major is nonzero"
            )
        }
        self.identifierSHA256 = identifierSHA256
        self.major = major
        self.minor = minor
    }

    func encodedTuple() -> Data {
        var data = Data(identifierSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(major, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(minor, to: &data)
        return data
    }
}

struct WindowsExecutionProviderRegistry: Hashable, Sendable {
    static let rendererNeutralIdentifier =
        "org.forgeplay.renderer-neutral-architecture-gap-lane"
    static let helperSupervisionIdentifier =
        "org.forgeplay.windows-helper-supervision"
    static let lifecycleEvidenceIdentifier =
        "org.forgeplay.windows-service-lifecycle-evidence"
    static let wow64TransitionIdentifier =
        "org.forgeplay.wow64-transition-liveness"
    static let syntheticMaintenanceIdentifier =
        "org.forgeplay.synthetic.maintenance-service-adapter"

    static let standaloneFingerprintHex =
        "af6d8626e89a7fad3476ec53013408c2cab9e25143cb618716cd769b173d7cc7"
    static let combinedFingerprintHex =
        "c50ba10ede08df289fac0928ff735c2f058b9aeeb9f55b457102358191d27077"
    static let syntheticHigherMinorFingerprintHex =
        "87a0590ae9d2b5cd98b73ede78f45b742d85e939e0e2e6aacf541c3395cab21e"

    let entries: [WindowsExecutionProviderEntry]
    let fingerprintSHA256: WindowsExecutionSHA256
    let fixtureOnly: Bool

    init(entries: [WindowsExecutionProviderEntry], fixtureOnly: Bool = false) throws {
        guard (1...16).contains(entries.count) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .negotiation,
                detail: "provider count is outside 1...16"
            )
        }
        for index in entries.indices.dropFirst() {
            guard entries[index - 1].identifierSHA256 <
                    entries[index].identifierSHA256 else {
                throw WindowsExecutionContractError(
                    reason: .capabilityDescriptorInvalid,
                    stage: .negotiation,
                    detail: "provider entries are strictly ordered and unique"
                )
            }
        }
        self.entries = entries
        self.fixtureOnly = fixtureOnly
        fingerprintSHA256 = .hash(
            entries.reduce(into: Data()) { $0.append($1.encodedTuple()) }
        )
    }

    static func entry(
        identifier: String,
        major: UInt16,
        minor: UInt16
    ) throws -> WindowsExecutionProviderEntry {
        try WindowsExecutionProviderEntry(
            identifierSHA256:
                WindowsExecutionCapabilityContract.identifierSHA256(identifier),
            major: major,
            minor: minor
        )
    }

    static func standalone() throws -> Self {
        try Self(entries: [
            entry(identifier: rendererNeutralIdentifier, major: 1, minor: 1),
            entry(identifier: helperSupervisionIdentifier, major: 1, minor: 1),
            entry(identifier: lifecycleEvidenceIdentifier, major: 1, minor: 1),
        ].sorted { $0.identifierSHA256 < $1.identifierSHA256 })
    }

    static func combinedWithWoW64() throws -> Self {
        try Self(entries: [
            entry(identifier: rendererNeutralIdentifier, major: 1, minor: 1),
            entry(identifier: wow64TransitionIdentifier, major: 1, minor: 0),
            entry(identifier: helperSupervisionIdentifier, major: 1, minor: 1),
            entry(identifier: lifecycleEvidenceIdentifier, major: 1, minor: 1),
        ].sorted { $0.identifierSHA256 < $1.identifierSHA256 })
    }

    static func syntheticHigherMinorFixture() throws -> Self {
        try Self(entries: [
            entry(identifier: rendererNeutralIdentifier, major: 1, minor: 1),
            entry(identifier: syntheticMaintenanceIdentifier, major: 1, minor: 0),
            entry(identifier: helperSupervisionIdentifier, major: 1, minor: 2),
            entry(identifier: lifecycleEvidenceIdentifier, major: 1, minor: 1),
        ].sorted { $0.identifierSHA256 < $1.identifierSHA256 }, fixtureOnly: true)
    }

    var canonicalTupleBytes: Data {
        entries.reduce(into: Data()) { $0.append($1.encodedTuple()) }
    }

    func validateFrozenFingerprint() throws {
        let expected: String
        if fixtureOnly {
            expected = Self.syntheticHigherMinorFingerprintHex
        } else if entries.count == 3 {
            expected = Self.standaloneFingerprintHex
        } else if entries.count == 4 {
            expected = Self.combinedFingerprintHex
        } else {
            throw WindowsExecutionContractError(
                reason: .bridgeRuntimeRegistryMismatch,
                stage: .negotiation,
                detail: "provider registry is not a frozen union"
            )
        }
        guard fingerprintSHA256.isAuthenticatedEqual(
            to: try WindowsExecutionSHA256(hexadecimal: expected)
        ) else {
            throw WindowsExecutionContractError(
                reason: .bridgeRuntimeRegistryMismatch,
                stage: .negotiation,
                detail: "provider registry fingerprint mismatch"
            )
        }
    }
}

struct WindowsExecutionCapabilityRequirement: Hashable, Sendable, Codable {
    let identifierSHA256: WindowsExecutionSHA256
    let requiredMajor: UInt16
    let minimumMinor: UInt16

    init(
        identifierSHA256: WindowsExecutionSHA256,
        requiredMajor: UInt16,
        minimumMinor: UInt16
    ) throws {
        guard requiredMajor != 0 else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .negotiation,
                detail: "required capability major is nonzero"
            )
        }
        self.identifierSHA256 = identifierSHA256
        self.requiredMajor = requiredMajor
        self.minimumMinor = minimumMinor
    }
}

struct WindowsRuntimeExecutionCapability: Hashable, Sendable, Codable {
    let identifierSHA256: WindowsExecutionSHA256
    let major: UInt16
    let minor: UInt16
    let owningCorePayloadSHA256: WindowsExecutionSHA256

    init(
        identifierSHA256: WindowsExecutionSHA256,
        major: UInt16,
        minor: UInt16,
        owningCorePayloadSHA256: WindowsExecutionSHA256
    ) throws {
        guard major != 0, !owningCorePayloadSHA256.isZero else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .negotiation,
                detail: "Runtime capability has a version and payload owner"
            )
        }
        self.identifierSHA256 = identifierSHA256
        self.major = major
        self.minor = minor
        self.owningCorePayloadSHA256 = owningCorePayloadSHA256
    }
}

struct WindowsRuntimeExecutionManifestV1: Hashable, Sendable, Codable {
    let runtimeFingerprintSHA256: WindowsExecutionSHA256
    let capabilities: [WindowsRuntimeExecutionCapability]
    let capabilitySetFingerprintSHA256: WindowsExecutionSHA256
    let supportedPEMachines: [WindowsPEMachine]
    let serviceLedgerSchemaMajor: UInt16
    let serviceLedgerSchemaMinor: UInt16

    init(
        runtimeFingerprintSHA256: WindowsExecutionSHA256,
        capabilities: [WindowsRuntimeExecutionCapability],
        capabilitySetFingerprintSHA256: WindowsExecutionSHA256,
        supportedPEMachines: [WindowsPEMachine],
        serviceLedgerSchemaMajor: UInt16,
        serviceLedgerSchemaMinor: UInt16
    ) throws {
        guard !runtimeFingerprintSHA256.isZero,
              (1...16).contains(capabilities.count),
              capabilities == capabilities.sorted(by: {
                  $0.identifierSHA256 < $1.identifierSHA256
              }),
              Set(capabilities.map(\.identifierSHA256)).count == capabilities.count,
              capabilitySetFingerprintSHA256.isAuthenticatedEqual(
                  to: WindowsExecutionCapabilityContract
                      .runtimeCapabilitySetFingerprint(capabilities)
              ),
              !supportedPEMachines.isEmpty,
              supportedPEMachines == supportedPEMachines.sorted(),
              Set(supportedPEMachines).count == supportedPEMachines.count,
              serviceLedgerSchemaMajor == 1 else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .negotiation,
                detail: "authenticated Runtime execution manifest is inconsistent"
            )
        }
        self.runtimeFingerprintSHA256 = runtimeFingerprintSHA256
        self.capabilities = capabilities
        self.capabilitySetFingerprintSHA256 = capabilitySetFingerprintSHA256
        self.supportedPEMachines = supportedPEMachines
        self.serviceLedgerSchemaMajor = serviceLedgerSchemaMajor
        self.serviceLedgerSchemaMinor = serviceLedgerSchemaMinor
    }
}

struct WindowsExecutionNegotiationResult: Hashable, Sendable {
    let runtimeCapabilitySetFingerprintSHA256: WindowsExecutionSHA256
    let requiredCapabilitySetFingerprintSHA256: WindowsExecutionSHA256
    let negotiatedCapabilities: [WindowsRuntimeExecutionCapability]
}

enum WindowsExecutionCapabilityContract {
    static let contractMajor: UInt16 = 1
    static let contractMinor: UInt16 = 0

    static func identifierSHA256(_ lowercaseASCIIIdentifier: String) throws
        -> WindowsExecutionSHA256 {
        guard !lowercaseASCIIIdentifier.isEmpty,
              lowercaseASCIIIdentifier == lowercaseASCIIIdentifier.lowercased(),
              lowercaseASCIIIdentifier.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .negotiation,
                detail: "capability identifier is nonempty lowercase ASCII"
            )
        }
        return .hash(Data(lowercaseASCIIIdentifier.utf8))
    }

    static func requiredCapabilitySetFingerprint(
        _ requirements: [WindowsExecutionCapabilityRequirement]
    ) -> WindowsExecutionSHA256 {
        var data = Data()
        for requirement in requirements {
            data.append(contentsOf: requirement.identifierSHA256.bytes)
            WindowsExecutionBinaryCodec.appendUInt16(
                requirement.requiredMajor,
                to: &data
            )
            WindowsExecutionBinaryCodec.appendUInt16(
                requirement.minimumMinor,
                to: &data
            )
        }
        return .hash(data)
    }

    static func runtimeCapabilitySetFingerprint(
        _ capabilities: [WindowsRuntimeExecutionCapability]
    ) -> WindowsExecutionSHA256 {
        var data = Data()
        for capability in capabilities {
            data.append(contentsOf: capability.identifierSHA256.bytes)
            WindowsExecutionBinaryCodec.appendUInt16(capability.major, to: &data)
            WindowsExecutionBinaryCodec.appendUInt16(capability.minor, to: &data)
        }
        return .hash(data)
    }

    static func negotiate(
        requirements: [WindowsExecutionCapabilityRequirement],
        against manifest: WindowsRuntimeExecutionManifestV1
    ) throws -> WindowsExecutionNegotiationResult {
        guard (1...16).contains(requirements.count),
              requirements == requirements.sorted(by: {
                  $0.identifierSHA256 < $1.identifierSHA256
              }),
              Set(requirements.map(\.identifierSHA256)).count ==
                requirements.count else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .negotiation,
                detail: "requirements are bounded, ordered, and unique"
            )
        }
        let runtimeByID = Dictionary(
            uniqueKeysWithValues: manifest.capabilities.map {
                ($0.identifierSHA256, $0)
            }
        )
        let selected = try requirements.map { requirement in
            guard let runtime = runtimeByID[requirement.identifierSHA256] else {
                throw WindowsExecutionContractError(
                    reason: .capabilityRequiredAbsent,
                    stage: .negotiation,
                    detail: "a required Runtime capability is absent"
                )
            }
            guard runtime.major == requirement.requiredMajor else {
                throw WindowsExecutionContractError(
                    reason: .capabilityMajorMismatch,
                    stage: .negotiation,
                    detail: "a required Runtime capability major differs"
                )
            }
            guard runtime.minor >= requirement.minimumMinor else {
                throw WindowsExecutionContractError(
                    reason: .capabilityRequiredAbsent,
                    stage: .negotiation,
                    detail: "a required Runtime capability minor is too old"
                )
            }
            return runtime
        }
        return WindowsExecutionNegotiationResult(
            runtimeCapabilitySetFingerprintSHA256:
                manifest.capabilitySetFingerprintSHA256,
            requiredCapabilitySetFingerprintSHA256:
                requiredCapabilitySetFingerprint(requirements),
            negotiatedCapabilities: selected
        )
    }
}

// MARK: - Launch descriptor and paired consumption

struct WindowsExecutionLaunchDescriptorV1: Hashable, Sendable {
    static let magic = Array("FPWECAP1".utf8)
    static let descriptorTTLNanoseconds: UInt64 = 10_000_000_000
    static let maximumByteCount = 844

    let sequence: UInt64
    let createdMonotonicNanoseconds: UInt64
    let runID: WindowsExecutionRunID
    let sessionNonce: WindowsExecutionSHA256
    let prefixScopeSHA256: WindowsExecutionSHA256
    let runtimeFingerprintSHA256: WindowsExecutionSHA256
    let rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256
    let requiredCapabilitySetFingerprintSHA256: WindowsExecutionSHA256
    let executionMode: WindowsExecutionMode
    let rendererRequirement: WindowsRendererRequirement
    let lifecycleKind: WindowsExecutionLifecycleKind
    let servicePersistence: WindowsServicePersistence
    let processDeadlineMilliseconds: UInt32
    let cleanupDeadlineMilliseconds: UInt32
    let requiredCapabilities: [WindowsExecutionCapabilityRequirement]

    init(
        sequence: UInt64,
        createdMonotonicNanoseconds: UInt64,
        runID: WindowsExecutionRunID,
        sessionNonce: WindowsExecutionSHA256,
        prefixScopeSHA256: WindowsExecutionSHA256,
        runtimeFingerprintSHA256: WindowsExecutionSHA256,
        rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256,
        requiredCapabilitySetFingerprintSHA256: WindowsExecutionSHA256,
        executionMode: WindowsExecutionMode,
        rendererRequirement: WindowsRendererRequirement,
        lifecycleKind: WindowsExecutionLifecycleKind,
        servicePersistence: WindowsServicePersistence,
        processDeadlineMilliseconds: UInt32,
        cleanupDeadlineMilliseconds: UInt32,
        requiredCapabilities: [WindowsExecutionCapabilityRequirement]
    ) throws {
        guard sequence != 0,
              !sessionNonce.isZero,
              !prefixScopeSHA256.isZero,
              !runtimeFingerprintSHA256.isZero,
              !rendererCapabilityFingerprintSHA256.isZero,
              (1_000...3_600_000).contains(processDeadlineMilliseconds),
              (1_000...60_000).contains(cleanupDeadlineMilliseconds),
              (1...16).contains(requiredCapabilities.count),
              requiredCapabilities == requiredCapabilities.sorted(by: {
                  $0.identifierSHA256 < $1.identifierSHA256
              }),
              Set(requiredCapabilities.map(\.identifierSHA256)).count ==
                requiredCapabilities.count,
              requiredCapabilitySetFingerprintSHA256.isAuthenticatedEqual(
                  to: WindowsExecutionCapabilityContract
                      .requiredCapabilitySetFingerprint(requiredCapabilities)
              ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor fields are inconsistent"
            )
        }
        self.sequence = sequence
        self.createdMonotonicNanoseconds = createdMonotonicNanoseconds
        self.runID = runID
        self.sessionNonce = sessionNonce
        self.prefixScopeSHA256 = prefixScopeSHA256
        self.runtimeFingerprintSHA256 = runtimeFingerprintSHA256
        self.rendererCapabilityFingerprintSHA256 =
            rendererCapabilityFingerprintSHA256
        self.requiredCapabilitySetFingerprintSHA256 =
            requiredCapabilitySetFingerprintSHA256
        self.executionMode = executionMode
        self.rendererRequirement = rendererRequirement
        self.lifecycleKind = lifecycleKind
        self.servicePersistence = servicePersistence
        self.processDeadlineMilliseconds = processDeadlineMilliseconds
        self.cleanupDeadlineMilliseconds = cleanupDeadlineMilliseconds
        self.requiredCapabilities = requiredCapabilities
    }

    func validateNotExpired(at nowMonotonicNanoseconds: UInt64) throws {
        let result = createdMonotonicNanoseconds.addingReportingOverflow(
            Self.descriptorTTLNanoseconds
        )
        guard !result.overflow, nowMonotonicNanoseconds < result.partialValue else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorExpired,
                stage: .descriptor,
                detail: "launch descriptor expired or clock arithmetic overflowed"
            )
        }
    }

    func encoded() -> Data {
        var data = Data(Self.magic)
        WindowsExecutionBinaryCodec.appendUInt16(1, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(1, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        WindowsExecutionBinaryCodec.appendUInt32(
            UInt32(268 + requiredCapabilities.count * 36),
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt64(sequence, to: &data)
        WindowsExecutionBinaryCodec.appendUInt64(
            createdMonotonicNanoseconds,
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt64(
            Self.descriptorTTLNanoseconds,
            to: &data
        )
        data.append(contentsOf: runID.bytes)
        data.append(contentsOf: sessionNonce.bytes)
        data.append(contentsOf: prefixScopeSHA256.bytes)
        data.append(contentsOf: runtimeFingerprintSHA256.bytes)
        data.append(contentsOf: rendererCapabilityFingerprintSHA256.bytes)
        data.append(contentsOf: requiredCapabilitySetFingerprintSHA256.bytes)
        data.append(executionMode.rawValue)
        data.append(rendererRequirement.rawValue)
        data.append(lifecycleKind.rawValue)
        data.append(servicePersistence.rawValue)
        WindowsExecutionBinaryCodec.appendUInt32(
            processDeadlineMilliseconds,
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt32(
            cleanupDeadlineMilliseconds,
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(requiredCapabilities.count),
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        for requirement in requiredCapabilities {
            data.append(contentsOf: requirement.identifierSHA256.bytes)
            WindowsExecutionBinaryCodec.appendUInt16(
                requirement.requiredMajor,
                to: &data
            )
            WindowsExecutionBinaryCodec.appendUInt16(
                requirement.minimumMinor,
                to: &data
            )
        }
        data.append(contentsOf: WindowsExecutionSHA256.hash(data).bytes)
        return data
    }

    var recordSHA256: WindowsExecutionSHA256 {
        WindowsExecutionSHA256.hash(encoded().dropLast(32))
    }

    static func decode(
        _ data: Data,
        nowMonotonicNanoseconds: UInt64
    ) throws -> Self {
        guard (304...maximumByteCount).contains(data.count) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor length is outside its bound"
            )
        }
        var reader = WindowsExecutionByteReader(data)
        guard try reader.readBytes(count: 8) == magic,
              try reader.readUInt16() == 1,
              try reader.readUInt16() == 0,
              try reader.readUInt16() == 1,
              try reader.readUInt16() == 0,
              try reader.readUInt32() == UInt32(data.count) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor header is invalid"
            )
        }
        let sequence = try reader.readUInt64()
        let created = try reader.readUInt64()
        guard try reader.readUInt64() == descriptorTTLNanoseconds else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor TTL is not frozen value"
            )
        }
        let runID = try WindowsExecutionRunID(bytes: reader.readBytes(count: 16))
        let nonce = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let prefix = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let runtime = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let renderer = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let requiredFingerprint = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        guard let mode = WindowsExecutionMode(rawValue: try reader.readUInt8()),
              let rendererRequirement = WindowsRendererRequirement(
                  rawValue: try reader.readUInt8()
              ),
              let lifecycle = WindowsExecutionLifecycleKind(
                  rawValue: try reader.readUInt8()
              ),
              let persistence = WindowsServicePersistence(
                  rawValue: try reader.readUInt8()
              ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor contains an unknown enum"
            )
        }
        let processDeadline = try reader.readUInt32()
        let cleanupDeadline = try reader.readUInt32()
        let count = Int(try reader.readUInt16())
        guard try reader.readUInt16() == 0,
              (1...16).contains(count),
              data.count == 268 + count * 36 else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor count or reserved field is invalid"
            )
        }
        var requirements: [WindowsExecutionCapabilityRequirement] = []
        requirements.reserveCapacity(count)
        for _ in 0..<count {
            requirements.append(
                try WindowsExecutionCapabilityRequirement(
                    identifierSHA256: WindowsExecutionSHA256(
                        bytes: reader.readBytes(count: 32)
                    ),
                    requiredMajor: reader.readUInt16(),
                    minimumMinor: reader.readUInt16()
                )
            )
        }
        let receivedDigest = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        try reader.requireEnd()
        guard receivedDigest.isAuthenticatedEqual(
            to: WindowsExecutionSHA256.hash(data.dropLast(32))
        ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "launch descriptor digest mismatch"
            )
        }
        let descriptor = try Self(
            sequence: sequence,
            createdMonotonicNanoseconds: created,
            runID: runID,
            sessionNonce: nonce,
            prefixScopeSHA256: prefix,
            runtimeFingerprintSHA256: runtime,
            rendererCapabilityFingerprintSHA256: renderer,
            requiredCapabilitySetFingerprintSHA256: requiredFingerprint,
            executionMode: mode,
            rendererRequirement: rendererRequirement,
            lifecycleKind: lifecycle,
            servicePersistence: persistence,
            processDeadlineMilliseconds: processDeadline,
            cleanupDeadlineMilliseconds: cleanupDeadline,
            requiredCapabilities: requirements
        )
        try descriptor.validateNotExpired(at: nowMonotonicNanoseconds)
        return descriptor
    }
}

final class WindowsExecutionSingleConsumeRegistry: @unchecked Sendable {
    private struct ConsumptionKey: Hashable {
        let runID: WindowsExecutionRunID
        let sessionNonce: WindowsExecutionSHA256
    }

    private let lock = NSLock()
    private var consumed: Set<ConsumptionKey> = []
    private var sequencesByRunID: [WindowsExecutionRunID: Set<UInt64>] = [:]
    private let maximumEntries: Int

    init(maximumEntries: Int = 4_096) {
        self.maximumEntries = maximumEntries
    }

    func consume(
        sequence: UInt64,
        runID: WindowsExecutionRunID,
        sessionNonce: WindowsExecutionSHA256
    ) throws {
        try lock.withLock {
            guard consumed.count < maximumEntries else {
                throw WindowsExecutionContractError(
                    reason: .bridgeAuthorityUnavailable,
                    stage: .descriptor,
                    detail: "descriptor replay registry reached its bound"
                )
            }
            let key = ConsumptionKey(runID: runID, sessionNonce: sessionNonce)
            guard !consumed.contains(key),
                  !(sequencesByRunID[runID]?.contains(sequence) ?? false) else {
                throw WindowsExecutionContractError(
                    reason: .capabilityDescriptorReplayed,
                    stage: .descriptor,
                    detail: "runID sequence or session nonce was already consumed"
                )
            }
            consumed.insert(key)
            sequencesByRunID[runID, default: []].insert(sequence)
        }
    }

    var consumptionCount: Int {
        lock.withLock { consumed.count }
    }
}

// MARK: - Revision-15 immutable bootstrap

struct WindowsPreparedSessionBootstrapV2: Hashable, Sendable {
    static let byteCount = 184
    static let identityDomain = Data("FPAUTHSESS2".utf8)

    let sequence: UInt64
    let runID: WindowsExecutionRunID
    let sessionNonce: WindowsExecutionSHA256
    let prefixScopeSHA256: WindowsExecutionSHA256
    let runtimeFingerprintSHA256: WindowsExecutionSHA256
    let launchDescriptorRecordSHA256: WindowsExecutionSHA256
    let rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256

    init(
        sequence: UInt64,
        runID: WindowsExecutionRunID,
        sessionNonce: WindowsExecutionSHA256,
        prefixScopeSHA256: WindowsExecutionSHA256,
        runtimeFingerprintSHA256: WindowsExecutionSHA256,
        launchDescriptorRecordSHA256: WindowsExecutionSHA256,
        rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256
    ) throws {
        guard sequence != 0,
              !sessionNonce.isZero,
              !prefixScopeSHA256.isZero,
              !runtimeFingerprintSHA256.isZero,
              !launchDescriptorRecordSHA256.isZero,
              !rendererCapabilityFingerprintSHA256.isZero else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "prepared-session bootstrap fields are nonzero"
            )
        }
        self.sequence = sequence
        self.runID = runID
        self.sessionNonce = sessionNonce
        self.prefixScopeSHA256 = prefixScopeSHA256
        self.runtimeFingerprintSHA256 = runtimeFingerprintSHA256
        self.launchDescriptorRecordSHA256 = launchDescriptorRecordSHA256
        self.rendererCapabilityFingerprintSHA256 =
            rendererCapabilityFingerprintSHA256
    }

    init(
        descriptor: WindowsExecutionLaunchDescriptorV1,
        rendererSnapshot: WindowsRendererCapabilitySnapshotV1
    ) throws {
        guard descriptor.sequence == rendererSnapshot.sequence,
              descriptor.runID == rendererSnapshot.runID,
              descriptor.sessionNonce == rendererSnapshot.sessionNonce,
              descriptor.prefixScopeSHA256 ==
                rendererSnapshot.prefixScopeSHA256,
              descriptor.runtimeFingerprintSHA256 ==
                rendererSnapshot.runtimeFingerprintSHA256,
              descriptor.rendererCapabilityFingerprintSHA256
                .isAuthenticatedEqual(to: rendererSnapshot.recordSHA256) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .descriptor,
                detail: "prepared-session records are not cross-bound"
            )
        }
        try self.init(
            sequence: descriptor.sequence,
            runID: descriptor.runID,
            sessionNonce: descriptor.sessionNonce,
            prefixScopeSHA256: descriptor.prefixScopeSHA256,
            runtimeFingerprintSHA256: descriptor.runtimeFingerprintSHA256,
            launchDescriptorRecordSHA256: descriptor.recordSHA256,
            rendererCapabilityFingerprintSHA256: rendererSnapshot.recordSHA256
        )
    }

    func encoded() -> Data {
        var data = Data()
        WindowsExecutionBinaryCodec.appendUInt64(sequence, to: &data)
        data.append(contentsOf: runID.bytes)
        data.append(contentsOf: sessionNonce.bytes)
        data.append(contentsOf: prefixScopeSHA256.bytes)
        data.append(contentsOf: runtimeFingerprintSHA256.bytes)
        data.append(contentsOf: launchDescriptorRecordSHA256.bytes)
        data.append(contentsOf: rendererCapabilityFingerprintSHA256.bytes)
        return data
    }

    var sha256: WindowsExecutionSHA256 {
        WindowsExecutionSHA256.hash(encoded())
    }

    func authoritySessionIdentity(
        localCapabilityRegistryFingerprintSHA256: WindowsExecutionSHA256
    ) -> WindowsExecutionSHA256 {
        var data = Self.identityDomain
        data.append(encoded())
        data.append(
            contentsOf: localCapabilityRegistryFingerprintSHA256.bytes
        )
        return .hash(data)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count == byteCount else {
            throw WindowsExecutionContractError(
                reason: .capabilityDescriptorInvalid,
                stage: .descriptor,
                detail: "prepared-session bootstrap contains exactly 184 bytes"
            )
        }
        var reader = WindowsExecutionByteReader(data)
        let value = try Self(
            sequence: reader.readUInt64(),
            runID: WindowsExecutionRunID(bytes: reader.readBytes(count: 16)),
            sessionNonce: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            prefixScopeSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            runtimeFingerprintSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            launchDescriptorRecordSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            )
        )
        try reader.requireEnd()
        return value
    }
}

// MARK: - Frozen authority frame header

enum WindowsExecutionAuthorityMessageType: UInt16, Codable, CaseIterable, Sendable {
    case hello = 1
    case registry = 2
    case acquire = 3
    case activate = 4
    case commit = 5
    case abort = 6
    case release = 7
    case bind = 8
    case evidence = 9
    case error = 255
}

struct WindowsExecutionAuthorityFlags: OptionSet, Hashable, Sendable, Codable {
    static let forbiddenDescriptorFD = Self(rawValue: 1 << 0)
    static let isResponse = Self(rawValue: 1 << 1)
    static let neutralBaseProjection = Self(rawValue: 1 << 2)
    static let rejected = Self(rawValue: 1 << 3)
    static let existingServiceRebind = Self(rawValue: 1 << 4)
    static let knownMask: UInt32 = 0x1f

    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
}

struct WindowsExecutionAuthorityHeaderV1: Hashable, Sendable {
    static let magic = Array("WINECAP1".utf8)
    static let byteCount = 64
    static let maximumPayloadBytes = 65_536
    static let maximumFrameBytes = 65_600

    let messageType: WindowsExecutionAuthorityMessageType
    let flags: WindowsExecutionAuthorityFlags
    let payloadBytes: UInt32
    let requestID: WindowsExecutionAuthorityIdentifier
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier

    init(
        messageType: WindowsExecutionAuthorityMessageType,
        flags: WindowsExecutionAuthorityFlags,
        payloadBytes: UInt32,
        requestID: WindowsExecutionAuthorityIdentifier,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier
    ) throws {
        guard payloadBytes <= UInt32(Self.maximumPayloadBytes),
              !requestID.isZero,
              flags.rawValue & ~WindowsExecutionAuthorityFlags.knownMask == 0,
              !flags.contains(.forbiddenDescriptorFD) else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .schema,
                detail: "authority header bounds, identity, or flags are invalid"
            )
        }
        self.messageType = messageType
        self.flags = flags
        self.payloadBytes = payloadBytes
        self.requestID = requestID
        self.servicesInstanceID = servicesInstanceID
    }

    func encoded() -> Data {
        var data = Data(Self.magic)
        WindowsExecutionBinaryCodec.appendUInt16(1, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(messageType.rawValue, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(UInt16(Self.byteCount), to: &data)
        WindowsExecutionBinaryCodec.appendUInt32(flags.rawValue, to: &data)
        WindowsExecutionBinaryCodec.appendUInt32(payloadBytes, to: &data)
        data.append(contentsOf: requestID.bytes)
        data.append(contentsOf: servicesInstanceID.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(0, to: &data)
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        let raw = try decodeRaw(data)
        guard let type = WindowsExecutionAuthorityMessageType(
            rawValue: raw.messageType
        ) else {
            throw protocolError("authority message type is unknown")
        }
        return try Self(
            messageType: type,
            flags: WindowsExecutionAuthorityFlags(rawValue: raw.flags),
            payloadBytes: raw.payloadBytes,
            requestID: raw.requestID,
            servicesInstanceID: raw.servicesInstanceID
        )
    }

    enum HelloAdmission: Sendable, Equatable {
        case trusted(WindowsExecutionAuthorityHeaderV1)
        case trustedSemanticRejection(requestID: WindowsExecutionAuthorityIdentifier)
        case silentClose
    }

    static func admitHello(_ data: Data) -> HelloAdmission {
        guard let raw = try? decodeRaw(data),
              raw.messageType == WindowsExecutionAuthorityMessageType.hello.rawValue,
              raw.payloadBytes <= UInt32(maximumPayloadBytes),
              !raw.requestID.isZero,
              raw.servicesInstanceID.isZero else {
            return .silentClose
        }
        let flags = WindowsExecutionAuthorityFlags(rawValue: raw.flags)
        guard flags.rawValue & ~WindowsExecutionAuthorityFlags.knownMask == 0,
              !flags.contains(.forbiddenDescriptorFD),
              flags.isEmpty else {
            return .trustedSemanticRejection(requestID: raw.requestID)
        }
        guard let header = try? Self(
            messageType: .hello,
            flags: flags,
            payloadBytes: raw.payloadBytes,
            requestID: raw.requestID,
            servicesInstanceID: raw.servicesInstanceID
        ) else {
            return .trustedSemanticRejection(requestID: raw.requestID)
        }
        return .trusted(header)
    }

    private struct RawHeader {
        let messageType: UInt16
        let flags: UInt32
        let payloadBytes: UInt32
        let requestID: WindowsExecutionAuthorityIdentifier
        let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    }

    private static func decodeRaw(_ data: Data) throws -> RawHeader {
        guard data.count == byteCount else {
            throw protocolError("authority header contains exactly 64 bytes")
        }
        var reader = WindowsExecutionByteReader(data)
        guard try reader.readBytes(count: 8) == magic,
              try reader.readUInt16() == 1,
              try reader.readUInt16() == 0 else {
            throw protocolError("authority magic or schema is invalid")
        }
        let type = try reader.readUInt16()
        guard try reader.readUInt16() == UInt16(byteCount) else {
            throw protocolError("authority headerBytes is not 64")
        }
        let flags = try reader.readUInt32()
        let payloadBytes = try reader.readUInt32()
        let request = try WindowsExecutionAuthorityIdentifier(
            bytes: reader.readBytes(count: 16)
        )
        let services = try WindowsExecutionAuthorityIdentifier(
            bytes: reader.readBytes(count: 16)
        )
        guard try reader.readUInt64() == 0 else {
            throw protocolError("authority header reserved bytes are nonzero")
        }
        try reader.requireEnd()
        return RawHeader(
            messageType: type,
            flags: flags,
            payloadBytes: payloadBytes,
            requestID: request,
            servicesInstanceID: services
        )
    }

    private static func protocolError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .bridgeProtocolInvalid,
            stage: .schema,
            detail: detail
        )
    }
}

// MARK: - HELLO payload

struct WindowsExecutionHelloPayloadV1: Hashable, Sendable {
    static let fixedBytesBeforeCapabilities = 220

    let bootstrap: WindowsPreparedSessionBootstrapV2
    let localCapabilityRegistryFingerprintSHA256: WindowsExecutionSHA256
    let providers: [WindowsExecutionProviderEntry]

    init(
        bootstrap: WindowsPreparedSessionBootstrapV2,
        providers: [WindowsExecutionProviderEntry]
    ) throws {
        let registry = try WindowsExecutionProviderRegistry(entries: providers)
        self.bootstrap = bootstrap
        localCapabilityRegistryFingerprintSHA256 = registry.fingerprintSHA256
        self.providers = providers
    }

    func encoded() -> Data {
        var data = bootstrap.encoded()
        data.append(contentsOf: localCapabilityRegistryFingerprintSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(UInt16(providers.count), to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        for provider in providers {
            data.append(provider.encodedTuple())
        }
        return data
    }

    static func decodeStructurally(_ data: Data) throws -> Self {
        guard data.count >= fixedBytesBeforeCapabilities else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .authority,
                detail: "HELLO payload is truncated"
            )
        }
        var reader = WindowsExecutionByteReader(data)
        let bootstrap = try WindowsPreparedSessionBootstrapV2.decode(
            reader.readData(count: WindowsPreparedSessionBootstrapV2.byteCount)
        )
        let receivedFingerprint = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        let count = Int(try reader.readUInt16())
        guard try reader.readUInt16() == 0,
              (1...16).contains(count),
              data.count == fixedBytesBeforeCapabilities + count * 36 else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .authority,
                detail: "HELLO provider count, reserved field, or length is invalid"
            )
        }
        var providers: [WindowsExecutionProviderEntry] = []
        providers.reserveCapacity(count)
        for _ in 0..<count {
            providers.append(
                try WindowsExecutionProviderEntry(
                    identifierSHA256: WindowsExecutionSHA256(
                        bytes: reader.readBytes(count: 32)
                    ),
                    major: reader.readUInt16(),
                    minor: reader.readUInt16()
                )
            )
        }
        try reader.requireEnd()
        let result = try Self(bootstrap: bootstrap, providers: providers)
        guard result.localCapabilityRegistryFingerprintSHA256
            .isAuthenticatedEqual(to: receivedFingerprint) else {
            throw WindowsExecutionContractError(
                reason: .bridgeRuntimeRegistryMismatch,
                stage: .authority,
                detail: "HELLO provider tuples do not match the transmitted digest"
            )
        }
        return result
    }

    func authenticate(
        expectedBootstrap: WindowsPreparedSessionBootstrapV2,
        expectedRegistry: WindowsExecutionProviderRegistry
    ) throws -> WindowsExecutionSHA256 {
        guard WindowsExecutionSHA256.constantTimeEqual(
            bootstrap.encoded(),
            expectedBootstrap.encoded()
        ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .authority,
                detail: "HELLO bootstrap does not match the immutable session"
            )
        }
        let received = try WindowsExecutionProviderRegistry(
            entries: providers,
            fixtureOnly: expectedRegistry.fixtureOnly
        )
        guard received.fingerprintSHA256.isAuthenticatedEqual(
            to: expectedRegistry.fingerprintSHA256
        ),
        received.canonicalTupleBytes == expectedRegistry.canonicalTupleBytes else {
            throw WindowsExecutionContractError(
                reason: .bridgeRuntimeRegistryMismatch,
                stage: .authority,
                detail: "HELLO provider registry does not match the session"
            )
        }
        return expectedBootstrap.authoritySessionIdentity(
            localCapabilityRegistryFingerprintSHA256:
                received.fingerprintSHA256
        )
    }
}
