// ForgePlay-authored clean-room output.
// Distribution remains blocked until explicit project license assignment.

import Foundation

enum WindowsRendererBaseEnvironmentValue: Hashable, Sendable {
    case absent
    case utf16(String)
}

struct WindowsRendererEnvironmentCatalogEntry: Hashable, Sendable, Codable {
    let keyID: UInt32
    let canonicalName: String

    init(keyID: UInt32, canonicalName: String) throws {
        guard keyID != 0, Self.isCanonicalName(canonicalName) else {
            throw WindowsExecutionContractError(
                reason: .bridgeEnvironmentInvalid,
                stage: .rendererSnapshot,
                detail: "renderer environment catalog entry is invalid"
            )
        }
        self.keyID = keyID
        self.canonicalName = canonicalName
    }

    static func canonicalize(_ input: String) throws -> String {
        let bytes = Array(input.utf8)
        guard (1...64).contains(bytes.count),
              bytes.allSatisfy({ $0 < 0x80 }),
              !bytes.contains(0),
              !bytes.contains(61) else {
            throw WindowsExecutionContractError(
                reason: .bridgeEnvironmentInvalid,
                stage: .rendererSnapshot,
                detail: "renderer environment name is outside the catalog bound"
            )
        }
        let uppercaseBytes = bytes.map {
            (97...122).contains($0) ? $0 - 32 : $0
        }
        guard let uppercase = String(
            bytes: uppercaseBytes,
            encoding: .ascii
        ),
        isCanonicalName(uppercase) else {
            throw WindowsExecutionContractError(
                reason: .bridgeEnvironmentInvalid,
                stage: .rendererSnapshot,
                detail: "renderer environment name is not canonical ASCII"
            )
        }
        return uppercase
    }

    static func isCanonicalName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count),
              let first = bytes.first,
              (65...90).contains(first) || first == 95 else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            (65...90).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    func encoded() -> Data {
        var data = Data()
        WindowsExecutionBinaryCodec.appendUInt32(keyID, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(canonicalName.utf8.count),
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        data.append(contentsOf: canonicalName.utf8)
        return data
    }
}

struct WindowsRendererEnvironmentCatalog: Hashable, Sendable {
    static let maximumCount = 16

    let entries: [WindowsRendererEnvironmentCatalogEntry]
    let catalogSHA256: WindowsExecutionSHA256

    init(names: [String]) throws {
        guard names.count <= Self.maximumCount else {
            throw WindowsExecutionContractError(
                reason: .bridgeEnvironmentInvalid,
                stage: .rendererSnapshot,
                detail: "renderer environment catalog exceeds 16 keys"
            )
        }
        let canonical = try names.map(
            WindowsRendererEnvironmentCatalogEntry.canonicalize
        ).sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        }
        guard Set(canonical).count == canonical.count else {
            throw WindowsExecutionContractError(
                reason: .bridgeEnvironmentInvalid,
                stage: .rendererSnapshot,
                detail: "renderer environment catalog has a duplicate key"
            )
        }
        entries = try canonical.enumerated().map {
            try WindowsRendererEnvironmentCatalogEntry(
                keyID: UInt32($0.offset + 1),
                canonicalName: $0.element
            )
        }
        catalogSHA256 = .hash(
            entries.reduce(into: Data()) { $0.append($1.encoded()) }
        )
    }

    func entry(
        named name: String
    ) throws -> WindowsRendererEnvironmentCatalogEntry? {
        let canonical = try WindowsRendererEnvironmentCatalogEntry.canonicalize(
            name
        )
        return entries.first { $0.canonicalName == canonical }
    }
}

enum WindowsRendererEnvironmentPlanOperation: UInt8, Codable, Sendable {
    case unset = 1
    case setBaseValue = 2
}

enum WindowsRendererEnvironmentPlanEncoding: UInt8, Codable, Sendable {
    case none = 0
    case utf16LittleEndian = 1
}

struct WindowsRendererEnvironmentPlanEntry: Hashable, Sendable {
    static let maximumValueBytes = 1_024

    let keyID: UInt32
    let operation: WindowsRendererEnvironmentPlanOperation
    let encoding: WindowsRendererEnvironmentPlanEncoding
    let valueBytes: Data

    init(
        keyID: UInt32,
        operation: WindowsRendererEnvironmentPlanOperation,
        encoding: WindowsRendererEnvironmentPlanEncoding,
        valueBytes: Data
    ) throws {
        guard keyID != 0,
              valueBytes.count <= Self.maximumValueBytes else {
            throw Self.environmentError("plan key or value exceeds its bound")
        }
        switch (operation, encoding) {
        case (.unset, .none):
            guard valueBytes.isEmpty else {
                throw Self.environmentError("unset plan entry has value bytes")
            }
        case (.setBaseValue, .utf16LittleEndian):
            guard !valueBytes.isEmpty,
                  valueBytes.count.isMultiple(of: 2),
                  String(data: valueBytes, encoding: .utf16LittleEndian) != nil,
                  !Self.containsUTF16NUL(valueBytes) else {
                throw Self.environmentError(
                    "base value is not bounded NUL-free UTF-16LE"
                )
            }
        default:
            throw Self.environmentError(
                "plan operation and encoding do not pair"
            )
        }
        self.keyID = keyID
        self.operation = operation
        self.encoding = encoding
        self.valueBytes = valueBytes
    }

    static func utf16LittleEndianBytes(_ value: String) throws -> Data {
        guard !value.utf16.contains(0) else {
            throw environmentError("base value contains a NUL code unit")
        }
        var data = Data()
        let byteCount = value.utf16.count.multipliedReportingOverflow(by: 2)
        guard !byteCount.overflow,
              byteCount.partialValue <= maximumValueBytes else {
            throw environmentError("base value exceeds 1024 bytes")
        }
        data.reserveCapacity(byteCount.partialValue)
        for codeUnit in value.utf16 {
            WindowsExecutionBinaryCodec.appendUInt16(codeUnit, to: &data)
        }
        return data
    }

    static func containsUTF16NUL(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.count.isMultiple(of: 2) else { return true }
        return stride(from: 0, to: bytes.count, by: 2).contains {
            bytes[$0] == 0 && bytes[$0 + 1] == 0
        }
    }

    func encoded() -> Data {
        var data = Data()
        WindowsExecutionBinaryCodec.appendUInt32(keyID, to: &data)
        data.append(operation.rawValue)
        data.append(encoding.rawValue)
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(valueBytes.count),
            to: &data
        )
        data.append(valueBytes)
        return data
    }

    private static func environmentError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .bridgeEnvironmentInvalid,
            stage: .rendererSnapshot,
            detail: detail
        )
    }
}

struct WindowsRendererNeutralEnvironmentProjection: Hashable, Sendable {
    static let maximumCloneBytesIncludingDoubleNUL = 65_534
    static let maximumConcurrentCloneCount = 16
    static let maximumConcurrentCloneBytes = 1_048_544
    static let brokerMarkerNames: Set<String> = [
        "FORGEPLAY_EXECUTION_DESCRIPTOR_FD_V1",
        "FORGEPLAY_RENDERER_CAPABILITY_FD_V1",
        "FORGEPLAY_EXECUTION_EVIDENCE_FD_V1",
        "FORGEPLAY_EXECUTION_AUTHORITY_FD_V1",
    ]

    let catalog: WindowsRendererEnvironmentCatalog
    let entries: [WindowsRendererEnvironmentPlanEntry]
    let baseProjectionSHA256: WindowsExecutionSHA256

    init(
        catalog: WindowsRendererEnvironmentCatalog,
        capturedValuesByCanonicalName:
            [String: WindowsRendererBaseEnvironmentValue]
    ) throws {
        let expectedNames = Set(catalog.entries.map(\.canonicalName))
        guard Set(capturedValuesByCanonicalName.keys) == expectedNames else {
            throw Self.projectionError(
                "base capture does not exactly cover catalog"
            )
        }
        var projected: [WindowsRendererEnvironmentPlanEntry] = []
        for entry in catalog.entries.sorted(by: { $0.keyID < $1.keyID }) {
            guard let value =
                    capturedValuesByCanonicalName[entry.canonicalName] else {
                throw Self.projectionError(
                    "base capture omitted a catalog key"
                )
            }
            switch value {
            case .absent:
                projected.append(
                    try WindowsRendererEnvironmentPlanEntry(
                        keyID: entry.keyID,
                        operation: .unset,
                        encoding: .none,
                        valueBytes: Data()
                    )
                )
            case let .utf16(text):
                projected.append(
                    try WindowsRendererEnvironmentPlanEntry(
                        keyID: entry.keyID,
                        operation: .setBaseValue,
                        encoding: .utf16LittleEndian,
                        valueBytes:
                            WindowsRendererEnvironmentPlanEntry
                                .utf16LittleEndianBytes(text)
                    )
                )
            }
        }
        entries = projected
        self.catalog = catalog
        var digestInput = Data("FPBASEP1".utf8)
        digestInput.append(contentsOf: catalog.catalogSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(projected.count),
            to: &digestInput
        )
        for entry in projected {
            digestInput.append(entry.encoded())
        }
        baseProjectionSHA256 = .hash(digestInput)
    }

    static func capture(
        catalog: WindowsRendererEnvironmentCatalog,
        environment: [String: String]
    ) throws -> Self {
        let catalogNames = Set(catalog.entries.map(\.canonicalName))
        var matches: [String: String] = [:]
        var unrelatedNames = Set<String>()
        for (name, value) in environment {
            let comparisonName = windowsComparisonName(name)
            if let canonical = try? WindowsRendererEnvironmentCatalogEntry
                .canonicalize(name),
               catalogNames.contains(canonical) {
                guard matches.updateValue(value, forKey: canonical) == nil else {
                    throw projectionError(
                        "input environment duplicates a catalog key by case"
                    )
                }
            } else {
                guard unrelatedNames.insert(comparisonName).inserted else {
                    throw projectionError(
                        "retained environment has a case-insensitive duplicate"
                    )
                }
            }
        }
        let captured = Dictionary(
            uniqueKeysWithValues: catalog.entries.map {
                (
                    $0.canonicalName,
                    matches[$0.canonicalName].map {
                        WindowsRendererBaseEnvironmentValue.utf16($0)
                    } ?? .absent
                )
            }
        )
        return try Self(
            catalog: catalog,
            capturedValuesByCanonicalName: captured
        )
    }

    func applying(to base: [String: String]) throws
        -> WindowsRendererEnvironmentClone {
        let catalogNames = Set(catalog.entries.map(\.canonicalName))
        var result: [String: String] = [:]
        var retainedComparisonNames = Set<String>()
        for (name, value) in base {
            let comparisonName = Self.windowsComparisonName(name)
            let catalogName = try? WindowsRendererEnvironmentCatalogEntry
                .canonicalize(name)
            if let catalogName, catalogNames.contains(catalogName) {
                continue
            }
            if Self.isBrokerMarker(name) {
                continue
            }
            guard retainedComparisonNames.insert(comparisonName).inserted else {
                throw Self.applicationError(
                    "base environment has a case-insensitive duplicate"
                )
            }
            result[name] = value
        }
        let catalogByID = Dictionary(
            uniqueKeysWithValues: catalog.entries.map { ($0.keyID, $0) }
        )
        guard entries.count == catalog.entries.count,
              Set(entries.map(\.keyID)).count == entries.count else {
            throw Self.applicationError(
                "plan coverage or key uniqueness is invalid"
            )
        }
        for entry in entries.sorted(by: { $0.keyID < $1.keyID }) {
            guard let catalogEntry = catalogByID[entry.keyID] else {
                throw Self.applicationError("plan references an unknown key")
            }
            switch entry.operation {
            case .unset:
                break
            case .setBaseValue:
                guard let value = String(
                    data: entry.valueBytes,
                    encoding: .utf16LittleEndian
                ) else {
                    throw Self.applicationError(
                        "plan UTF-16LE decoding failed"
                    )
                }
                result[catalogEntry.canonicalName] = value
            }
        }
        for catalogEntry in catalog.entries {
            let actual = result.first {
                Self.windowsComparisonName($0.key) ==
                    Self.windowsComparisonName(catalogEntry.canonicalName)
            }?.value
            let expected = entries.first {
                $0.keyID == catalogEntry.keyID
            }
            switch expected?.operation {
            case .unset:
                guard actual == nil else {
                    throw Self.applicationError(
                        "unset catalog key remained"
                    )
                }
            case .setBaseValue:
                guard let expected,
                      actual == String(
                          data: expected.valueBytes,
                          encoding: .utf16LittleEndian
                      ) else {
                    throw Self.applicationError(
                        "catalog base value differs"
                    )
                }
            case .none:
                throw Self.applicationError(
                    "catalog plan entry is missing"
                )
            }
        }
        guard !result.keys.contains(where: Self.isBrokerMarker) else {
            throw Self.applicationError("internal broker marker remained")
        }
        let cloneByteCount = try Self.cloneByteCount(result)
        return WindowsRendererEnvironmentClone(
            values: result,
            encodedByteCountIncludingDoubleNUL: cloneByteCount
        )
    }

    private static func cloneByteCount(
        _ environment: [String: String]
    ) throws -> Int {
        var total = 2
        for (name, value) in environment {
            let codeUnits = name.utf16.count
                .addingReportingOverflow(value.utf16.count)
            guard !codeUnits.overflow else {
                throw applicationError("environment clone length overflowed")
            }
            let withSeparators = codeUnits.partialValue
                .addingReportingOverflow(2)
            guard !withSeparators.overflow else {
                throw applicationError("environment clone length overflowed")
            }
            let bytes = withSeparators.partialValue
                .multipliedReportingOverflow(by: 2)
            let sum = total.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow,
                  !sum.overflow,
                  sum.partialValue <= maximumCloneBytesIncludingDoubleNUL else {
                throw applicationError(
                    "explicit environment clone exceeds 65534 bytes"
                )
            }
            total = sum.partialValue
        }
        return total
    }

    private static func windowsComparisonName(_ name: String) -> String {
        name.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func isBrokerMarker(_ name: String) -> Bool {
        let canonical = windowsComparisonName(name)
        return brokerMarkerNames.contains(canonical) ||
            canonical.hasPrefix("FORGEPLAY_INTERNAL_")
    }

    private static func projectionError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .bridgeEnvironmentInvalid,
            stage: .rendererSnapshot,
            detail: detail
        )
    }

    private static func applicationError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .bridgeEnvironmentApplyFailed,
            stage: .rendererSnapshot,
            detail: detail
        )
    }
}

struct WindowsRendererEnvironmentClone: Hashable, Sendable {
    let values: [String: String]
    let encodedByteCountIncludingDoubleNUL: Int
}

final class WindowsRendererEnvironmentCloneBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var liveTokenIDs = Set<UUID>()
    private var liveBytes = 0

    func reserve(
        _ clone: WindowsRendererEnvironmentClone
    ) throws -> WindowsRendererEnvironmentCloneLease {
        try lock.withLock {
            let sum = liveBytes.addingReportingOverflow(
                clone.encodedByteCountIncludingDoubleNUL
            )
            guard liveTokenIDs.count <
                    WindowsRendererNeutralEnvironmentProjection
                        .maximumConcurrentCloneCount,
                  !sum.overflow,
                  sum.partialValue <=
                    WindowsRendererNeutralEnvironmentProjection
                        .maximumConcurrentCloneBytes else {
                throw WindowsExecutionContractError(
                    reason: .bridgeAuthorityUnavailable,
                    stage: .rendererSnapshot,
                    detail: "environment clone concurrency bound is exhausted"
                )
            }
            let tokenID = UUID()
            liveTokenIDs.insert(tokenID)
            liveBytes = sum.partialValue
            return WindowsRendererEnvironmentCloneLease(
                clone: clone,
                tokenID: tokenID,
                budget: self
            )
        }
    }

    fileprivate func release(tokenID: UUID, byteCount: Int) {
        lock.withLock {
            guard liveTokenIDs.remove(tokenID) != nil,
                  byteCount <= liveBytes else {
                return
            }
            liveBytes -= byteCount
        }
    }

    var liveResourceCount: Int {
        lock.withLock { liveTokenIDs.count }
    }

    var liveResourceBytes: Int {
        lock.withLock { liveBytes }
    }
}

final class WindowsRendererEnvironmentCloneLease: @unchecked Sendable {
    let clone: WindowsRendererEnvironmentClone

    private let lock = NSLock()
    private let tokenID: UUID
    private weak var budget: WindowsRendererEnvironmentCloneBudget?
    private var released = false

    fileprivate init(
        clone: WindowsRendererEnvironmentClone,
        tokenID: UUID,
        budget: WindowsRendererEnvironmentCloneBudget
    ) {
        self.clone = clone
        self.tokenID = tokenID
        self.budget = budget
    }

    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            budget?.release(
                tokenID: tokenID,
                byteCount: clone.encodedByteCountIncludingDoubleNUL
            )
        }
    }

    deinit {
        release()
    }
}

struct WindowsRendererRegistryBinding: Hashable, Sendable {
    let rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256
    let catalogSHA256: WindowsExecutionSHA256
    let baseProjectionSHA256: WindowsExecutionSHA256

    init(
        snapshot: WindowsRendererCapabilitySnapshotV1,
        projection: WindowsRendererNeutralEnvironmentProjection
    ) {
        rendererCapabilityFingerprintSHA256 = snapshot.recordSHA256
        catalogSHA256 = projection.catalog.catalogSHA256
        baseProjectionSHA256 = projection.baseProjectionSHA256
    }

    func authenticate(
        snapshot: WindowsRendererCapabilitySnapshotV1,
        projection: WindowsRendererNeutralEnvironmentProjection
    ) -> Bool {
        rendererCapabilityFingerprintSHA256.isAuthenticatedEqual(
            to: snapshot.recordSHA256
        ) &&
        catalogSHA256.isAuthenticatedEqual(
            to: projection.catalog.catalogSHA256
        ) &&
        baseProjectionSHA256.isAuthenticatedEqual(
            to: projection.baseProjectionSHA256
        )
    }
}
