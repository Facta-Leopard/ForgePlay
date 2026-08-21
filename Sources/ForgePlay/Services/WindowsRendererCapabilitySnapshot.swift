// ForgePlay-authored clean-room output.
// Distribution remains blocked until explicit project license assignment.

import Foundation

struct WindowsRendererArchitectureFlags: OptionSet, Hashable, Sendable, Codable {
    static let rendererPayloadSupported = Self(rawValue: 1 << 0)
    static let runtimeLoadGuardMandatory = Self(rawValue: 1 << 1)
    static let knownMask: UInt16 =
        rendererPayloadSupported.rawValue | runtimeLoadGuardMandatory.rawValue

    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }
}

struct WindowsRendererModuleCategoryFlags: OptionSet, Hashable, Sendable, Codable {
    static let direct3D = Self(rawValue: 1 << 0)
    static let dxgi = Self(rawValue: 1 << 1)
    static let vulkan = Self(rawValue: 1 << 2)
    static let vendorAPI = Self(rawValue: 1 << 3)
    static let rendererBridge = Self(rawValue: 1 << 4)
    static let knownMask: UInt16 =
        direct3D.rawValue |
        dxgi.rawValue |
        vulkan.rawValue |
        vendorAPI.rawValue |
        rendererBridge.rawValue

    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }
}

struct WindowsRendererModuleFamilyEntry: Hashable, Sendable, Codable {
    let moduleFamilyDigestSHA256: WindowsExecutionSHA256
    let categoryFlags: WindowsRendererModuleCategoryFlags

    init(
        moduleFamilyDigestSHA256: WindowsExecutionSHA256,
        categoryFlags: WindowsRendererModuleCategoryFlags
    ) throws {
        guard !moduleFamilyDigestSHA256.isZero,
              categoryFlags.rawValue != 0,
              categoryFlags.rawValue &
                ~WindowsRendererModuleCategoryFlags.knownMask == 0 else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "renderer module-family entry is invalid"
            )
        }
        self.moduleFamilyDigestSHA256 = moduleFamilyDigestSHA256
        self.categoryFlags = categoryFlags
    }
}

struct WindowsRendererArchitectureEntry: Hashable, Sendable, Codable {
    let peMachine: WindowsPEMachine
    let flags: WindowsRendererArchitectureFlags
    let architecturePayloadSHA256: WindowsExecutionSHA256
    let modules: [WindowsRendererModuleFamilyEntry]

    init(
        peMachine: WindowsPEMachine,
        flags: WindowsRendererArchitectureFlags,
        architecturePayloadSHA256: WindowsExecutionSHA256,
        modules: [WindowsRendererModuleFamilyEntry]
    ) throws {
        let supported = flags.contains(.rendererPayloadSupported)
        guard flags.rawValue & ~WindowsRendererArchitectureFlags.knownMask == 0,
              flags.contains(.runtimeLoadGuardMandatory),
              !modules.isEmpty,
              modules.count <= 64,
              modules == modules.sorted(by: {
                  $0.moduleFamilyDigestSHA256 < $1.moduleFamilyDigestSHA256
              }),
              Set(modules.map(\.moduleFamilyDigestSHA256)).count == modules.count,
              supported
                ? !architecturePayloadSHA256.isZero
                : architecturePayloadSHA256.isZero else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "renderer architecture support, guard, or module closure is invalid"
            )
        }
        self.peMachine = peMachine
        self.flags = flags
        self.architecturePayloadSHA256 = architecturePayloadSHA256
        self.modules = modules
    }

    var support: WindowsRendererArchitectureSupport {
        flags.contains(.rendererPayloadSupported) ? .supported : .unsupported
    }

    func ownsModuleFamily(_ digest: WindowsExecutionSHA256) -> Bool {
        modules.contains { $0.moduleFamilyDigestSHA256 == digest }
    }
}

struct WindowsRendererCapabilitySnapshotV1: Hashable, Sendable {
    static let magic = Array("FPRCAPV1".utf8)
    static let maximumByteCount = 2_660

    let sequence: UInt64
    let runID: WindowsExecutionRunID
    let sessionNonce: WindowsExecutionSHA256
    let prefixScopeSHA256: WindowsExecutionSHA256
    let runtimeFingerprintSHA256: WindowsExecutionSHA256
    let backendCapabilityIdentifierSHA256: WindowsExecutionSHA256
    let backendCapabilityMajor: UInt16
    let backendCapabilityMinor: UInt16
    let hostClosureSHA256: WindowsExecutionSHA256
    let completePayloadSHA256: WindowsExecutionSHA256
    let architectures: [WindowsRendererArchitectureEntry]

    init(
        sequence: UInt64,
        runID: WindowsExecutionRunID,
        sessionNonce: WindowsExecutionSHA256,
        prefixScopeSHA256: WindowsExecutionSHA256,
        runtimeFingerprintSHA256: WindowsExecutionSHA256,
        backendCapabilityIdentifierSHA256: WindowsExecutionSHA256,
        backendCapabilityMajor: UInt16,
        backendCapabilityMinor: UInt16,
        hostClosureSHA256: WindowsExecutionSHA256,
        completePayloadSHA256: WindowsExecutionSHA256,
        architectures: [WindowsRendererArchitectureEntry]
    ) throws {
        let moduleCount = architectures.reduce(0) { $0 + $1.modules.count }
        guard sequence != 0,
              !sessionNonce.isZero,
              !prefixScopeSHA256.isZero,
              !runtimeFingerprintSHA256.isZero,
              !backendCapabilityIdentifierSHA256.isZero,
              backendCapabilityMajor != 0,
              !hostClosureSHA256.isZero,
              !completePayloadSHA256.isZero,
              (1...2).contains(architectures.count),
              (1...64).contains(moduleCount),
              architectures == architectures.sorted(by: {
                  $0.peMachine < $1.peMachine
              }),
              Set(architectures.map(\.peMachine)).count == architectures.count else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "renderer snapshot fields are inconsistent"
            )
        }
        self.sequence = sequence
        self.runID = runID
        self.sessionNonce = sessionNonce
        self.prefixScopeSHA256 = prefixScopeSHA256
        self.runtimeFingerprintSHA256 = runtimeFingerprintSHA256
        self.backendCapabilityIdentifierSHA256 =
            backendCapabilityIdentifierSHA256
        self.backendCapabilityMajor = backendCapabilityMajor
        self.backendCapabilityMinor = backendCapabilityMinor
        self.hostClosureSHA256 = hostClosureSHA256
        self.completePayloadSHA256 = completePayloadSHA256
        self.architectures = architectures
    }

    var moduleEntryCount: Int {
        architectures.reduce(0) { $0 + $1.modules.count }
    }

    var recordSHA256: WindowsExecutionSHA256 {
        WindowsExecutionSHA256.hash(Data(encoded().dropLast(32)))
    }

    func architecture(
        for peMachine: WindowsPEMachine
    ) -> WindowsRendererArchitectureEntry? {
        architectures.first { $0.peMachine == peMachine }
    }

    func encoded() -> Data {
        var data = Data(Self.magic)
        WindowsExecutionBinaryCodec.appendUInt16(1, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(2, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        WindowsExecutionBinaryCodec.appendUInt32(
            UInt32(276 + architectures.count * 40 + moduleEntryCount * 36),
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt64(sequence, to: &data)
        data.append(contentsOf: runID.bytes)
        data.append(contentsOf: sessionNonce.bytes)
        data.append(contentsOf: prefixScopeSHA256.bytes)
        data.append(contentsOf: runtimeFingerprintSHA256.bytes)
        data.append(contentsOf: backendCapabilityIdentifierSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(backendCapabilityMajor, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(backendCapabilityMinor, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(architectures.count),
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(moduleEntryCount),
            to: &data
        )
        data.append(contentsOf: hostClosureSHA256.bytes)
        data.append(contentsOf: completePayloadSHA256.bytes)
        for architecture in architectures {
            WindowsExecutionBinaryCodec.appendUInt16(
                architecture.peMachine.rawValue,
                to: &data
            )
            WindowsExecutionBinaryCodec.appendUInt16(
                architecture.flags.rawValue,
                to: &data
            )
            WindowsExecutionBinaryCodec.appendUInt16(
                UInt16(architecture.modules.count),
                to: &data
            )
            WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
            data.append(contentsOf: architecture.architecturePayloadSHA256.bytes)
            for module in architecture.modules {
                data.append(contentsOf: module.moduleFamilyDigestSHA256.bytes)
                WindowsExecutionBinaryCodec.appendUInt16(
                    module.categoryFlags.rawValue,
                    to: &data
                )
                WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
            }
        }
        data.append(contentsOf: WindowsExecutionSHA256.hash(data).bytes)
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard (352...maximumByteCount).contains(data.count) else {
            throw snapshotError("renderer snapshot length is outside its bound")
        }
        var reader = WindowsExecutionByteReader(data)
        guard try reader.readBytes(count: 8) == magic,
              try reader.readUInt16() == 1,
              try reader.readUInt16() == 0,
              try reader.readUInt16() == 2,
              try reader.readUInt16() == 0,
              try reader.readUInt32() == UInt32(data.count) else {
            throw snapshotError("renderer snapshot header is invalid")
        }
        let sequence = try reader.readUInt64()
        let runID = try WindowsExecutionRunID(bytes: reader.readBytes(count: 16))
        let nonce = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let prefix = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let runtime = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let backend = try WindowsExecutionSHA256(bytes: reader.readBytes(count: 32))
        let backendMajor = try reader.readUInt16()
        let backendMinor = try reader.readUInt16()
        let architectureCount = Int(try reader.readUInt16())
        let declaredModuleCount = Int(try reader.readUInt16())
        let hostClosure = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        let completePayload = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        guard (1...2).contains(architectureCount),
              (1...64).contains(declaredModuleCount),
              data.count == 276 + architectureCount * 40 +
                declaredModuleCount * 36 else {
            throw snapshotError("renderer snapshot entry counts are invalid")
        }
        var architectures: [WindowsRendererArchitectureEntry] = []
        var decodedModuleCount = 0
        for _ in 0..<architectureCount {
            guard let machine = WindowsPEMachine(
                rawValue: try reader.readUInt16()
            ) else {
                throw WindowsExecutionContractError(
                    reason: .admissionPEInvalid,
                    stage: .rendererSnapshot,
                    detail: "renderer snapshot PE machine is unknown"
                )
            }
            let flags = WindowsRendererArchitectureFlags(
                rawValue: try reader.readUInt16()
            )
            let moduleCount = Int(try reader.readUInt16())
            guard try reader.readUInt16() == 0,
                  moduleCount > 0,
                  decodedModuleCount <= declaredModuleCount - moduleCount else {
                throw snapshotError("renderer architecture count is invalid")
            }
            let payload = try WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            )
            var modules: [WindowsRendererModuleFamilyEntry] = []
            modules.reserveCapacity(moduleCount)
            for _ in 0..<moduleCount {
                let digest = try WindowsExecutionSHA256(
                    bytes: reader.readBytes(count: 32)
                )
                let categories = WindowsRendererModuleCategoryFlags(
                    rawValue: try reader.readUInt16()
                )
                guard try reader.readUInt16() == 0 else {
                    throw snapshotError("renderer module reserved field is nonzero")
                }
                modules.append(
                    try WindowsRendererModuleFamilyEntry(
                        moduleFamilyDigestSHA256: digest,
                        categoryFlags: categories
                    )
                )
            }
            architectures.append(
                try WindowsRendererArchitectureEntry(
                    peMachine: machine,
                    flags: flags,
                    architecturePayloadSHA256: payload,
                    modules: modules
                )
            )
            decodedModuleCount += moduleCount
        }
        let receivedDigest = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        try reader.requireEnd()
        guard decodedModuleCount == declaredModuleCount,
              receivedDigest.isAuthenticatedEqual(
                  to: WindowsExecutionSHA256.hash(Data(data.dropLast(32)))
              ) else {
            throw snapshotError("renderer snapshot digest or module count differs")
        }
        return try Self(
            sequence: sequence,
            runID: runID,
            sessionNonce: nonce,
            prefixScopeSHA256: prefix,
            runtimeFingerprintSHA256: runtime,
            backendCapabilityIdentifierSHA256: backend,
            backendCapabilityMajor: backendMajor,
            backendCapabilityMinor: backendMinor,
            hostClosureSHA256: hostClosure,
            completePayloadSHA256: completePayload,
            architectures: architectures
        )
    }

    private static func snapshotError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .admissionRendererClosureInvalid,
            stage: .rendererSnapshot,
            detail: detail
        )
    }
}

// MARK: - Authenticated manifest projection

struct WindowsAuthenticatedRendererModuleV1: Hashable, Sendable {
    let moduleFamily: String
    let moduleFileSHA256: WindowsExecutionSHA256?
    let categoryFlags: WindowsRendererModuleCategoryFlags

    init(
        moduleFamily: String,
        moduleFileSHA256: WindowsExecutionSHA256?,
        categoryFlags: WindowsRendererModuleCategoryFlags
    ) throws {
        _ = try WindowsRendererCapabilitySnapshotBuilder.moduleFamilyDigest(
            moduleFamily
        )
        guard categoryFlags.rawValue != 0,
              categoryFlags.rawValue &
                ~WindowsRendererModuleCategoryFlags.knownMask == 0 else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "authenticated renderer module category is invalid"
            )
        }
        self.moduleFamily = moduleFamily
        self.moduleFileSHA256 = moduleFileSHA256
        self.categoryFlags = categoryFlags
    }
}

struct WindowsAuthenticatedRendererArchitectureV1: Hashable, Sendable {
    let peMachine: WindowsPEMachine
    let payloadSupported: Bool
    let runtimeLoadGuardMandatory: Bool
    let modules: [WindowsAuthenticatedRendererModuleV1]
    let authenticatedArchitecturePayloadSHA256: WindowsExecutionSHA256
}

struct WindowsAuthenticatedRendererHostDependencyV1: Hashable, Sendable {
    let relativePath: String
    let fileSHA256: WindowsExecutionSHA256
}

struct WindowsAuthenticatedRendererManifestV1: Hashable, Sendable {
    let backendCapabilityIdentifierSHA256: WindowsExecutionSHA256
    let backendCapabilityMajor: UInt16
    let backendCapabilityMinor: UInt16
    let hostDependencies: [WindowsAuthenticatedRendererHostDependencyV1]
    let architectures: [WindowsAuthenticatedRendererArchitectureV1]
    let authenticatedHostClosureSHA256: WindowsExecutionSHA256
    let authenticatedCompletePayloadSHA256: WindowsExecutionSHA256
}

enum WindowsRendererCapabilitySnapshotBuilder {
    static let maximumHostDependencyCount = 64
    static let maximumHostDependencyAggregateBytes = 1_048_576

    static func moduleFamilyDigest(
        _ moduleFamily: String
    ) throws -> WindowsExecutionSHA256 {
        let input = Array(moduleFamily.utf8)
        guard (1...64).contains(input.count),
              input.allSatisfy({
                  (65...90).contains($0) ||
                    (97...122).contains($0) ||
                    (48...57).contains($0) ||
                    $0 == 95 || $0 == 46 || $0 == 45
              }),
              !moduleFamily.contains("/") else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "module family is not a valid ASCII basename"
            )
        }
        return .hash(Data(input.map {
            (65...90).contains($0) ? $0 + 32 : $0
        }))
    }

    static func build(
        manifest: WindowsAuthenticatedRendererManifestV1,
        sequence: UInt64,
        runID: WindowsExecutionRunID,
        sessionNonce: WindowsExecutionSHA256,
        prefixScopeSHA256: WindowsExecutionSHA256,
        runtimeFingerprintSHA256: WindowsExecutionSHA256
    ) throws -> WindowsRendererCapabilitySnapshotV1 {
        let moduleCount = manifest.architectures.reduce(0) {
            $0 + $1.modules.count
        }
        guard (1...2).contains(manifest.architectures.count),
              (1...64).contains(moduleCount),
              (1...maximumHostDependencyCount).contains(
                  manifest.hostDependencies.count
              ) else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "authenticated manifest counts exceed bounded input"
            )
        }
        let hostClosure = try hostClosureSHA256(manifest.hostDependencies)
        guard hostClosure.isAuthenticatedEqual(
            to: manifest.authenticatedHostClosureSHA256
        ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .rendererSnapshot,
                detail: "authenticated host closure differs from its tuples"
            )
        }
        var projected: [WindowsRendererArchitectureEntry] = []
        for architecture in manifest.architectures.sorted(by: {
            $0.peMachine < $1.peMachine
        }) {
            let tuples = try architecture.modules.map { module in
                (
                    entry: try WindowsRendererModuleFamilyEntry(
                        moduleFamilyDigestSHA256:
                            moduleFamilyDigest(module.moduleFamily),
                        categoryFlags: module.categoryFlags
                    ),
                    fileSHA256: module.moduleFileSHA256
                )
            }.sorted {
                $0.entry.moduleFamilyDigestSHA256 <
                    $1.entry.moduleFamilyDigestSHA256
            }
            guard Set(tuples.map(\.entry.moduleFamilyDigestSHA256)).count ==
                    tuples.count else {
                throw WindowsExecutionContractError(
                    reason: .admissionRendererClosureInvalid,
                    stage: .rendererSnapshot,
                    detail: "authenticated module family is duplicated"
                )
            }
            let payload: WindowsExecutionSHA256
            if architecture.payloadSupported {
                var bytes = Data()
                for tuple in tuples {
                    guard let fileSHA256 = tuple.fileSHA256,
                          !fileSHA256.isZero else {
                        throw WindowsExecutionContractError(
                            reason: .admissionRendererClosureInvalid,
                            stage: .rendererSnapshot,
                            detail: "supported renderer architecture lacks a file digest"
                        )
                    }
                    bytes.append(
                        contentsOf: tuple.entry.moduleFamilyDigestSHA256.bytes
                    )
                    bytes.append(contentsOf: fileSHA256.bytes)
                    WindowsExecutionBinaryCodec.appendUInt16(
                        tuple.entry.categoryFlags.rawValue,
                        to: &bytes
                    )
                }
                payload = .hash(bytes)
            } else {
                guard tuples.allSatisfy({ $0.fileSHA256 == nil }) else {
                    throw WindowsExecutionContractError(
                        reason: .admissionRendererClosureInvalid,
                        stage: .rendererSnapshot,
                        detail: "unsupported architecture unexpectedly owns payload bytes"
                    )
                }
                payload = .zero
            }
            guard payload.isAuthenticatedEqual(
                to: architecture.authenticatedArchitecturePayloadSHA256
            ) else {
                throw WindowsExecutionContractError(
                    reason: .capabilityFingerprintMismatch,
                    stage: .rendererSnapshot,
                    detail: "architecture payload digest differs"
                )
            }
            var flags: WindowsRendererArchitectureFlags =
                [.runtimeLoadGuardMandatory]
            guard architecture.runtimeLoadGuardMandatory else {
                throw WindowsExecutionContractError(
                    reason: .admissionRendererClosureInvalid,
                    stage: .rendererSnapshot,
                    detail: "renderer load guard is mandatory"
                )
            }
            if architecture.payloadSupported {
                flags.insert(.rendererPayloadSupported)
            }
            projected.append(
                try WindowsRendererArchitectureEntry(
                    peMachine: architecture.peMachine,
                    flags: flags,
                    architecturePayloadSHA256: payload,
                    modules: tuples.map(\.entry)
                )
            )
        }
        guard Set(projected.map(\.peMachine)).count == projected.count else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "renderer architecture is duplicated"
            )
        }
        let complete = completePayloadSHA256(
            backendIdentifier: manifest.backendCapabilityIdentifierSHA256,
            backendMajor: manifest.backendCapabilityMajor,
            backendMinor: manifest.backendCapabilityMinor,
            hostClosure: hostClosure,
            architectures: projected
        )
        guard complete.isAuthenticatedEqual(
            to: manifest.authenticatedCompletePayloadSHA256
        ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .rendererSnapshot,
                detail: "complete renderer payload digest differs"
            )
        }
        return try WindowsRendererCapabilitySnapshotV1(
            sequence: sequence,
            runID: runID,
            sessionNonce: sessionNonce,
            prefixScopeSHA256: prefixScopeSHA256,
            runtimeFingerprintSHA256: runtimeFingerprintSHA256,
            backendCapabilityIdentifierSHA256:
                manifest.backendCapabilityIdentifierSHA256,
            backendCapabilityMajor: manifest.backendCapabilityMajor,
            backendCapabilityMinor: manifest.backendCapabilityMinor,
            hostClosureSHA256: hostClosure,
            completePayloadSHA256: complete,
            architectures: projected
        )
    }

    static func hostClosureSHA256(
        _ dependencies: [WindowsAuthenticatedRendererHostDependencyV1]
    ) throws -> WindowsExecutionSHA256 {
        guard (1...maximumHostDependencyCount).contains(dependencies.count) else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "renderer host dependency count is outside its bound"
            )
        }
        var aggregate = 0
        let canonical = try dependencies.map {
            dependency -> (String, [UInt8], WindowsExecutionSHA256) in
            let path = dependency.relativePath
                .precomposedStringWithCanonicalMapping
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            let components = path.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            let bytes = Array(path.utf8)
            let sum = aggregate.addingReportingOverflow(bytes.count + 34)
            guard !sum.overflow,
                  sum.partialValue <= maximumHostDependencyAggregateBytes,
                  !path.hasPrefix("/"),
                  !path.hasSuffix("/"),
                  !components.contains(where: {
                      $0.isEmpty || $0 == "." || $0 == ".."
                  }),
                  !bytes.contains(0),
                  !bytes.isEmpty,
                  bytes.count <= Int(UInt16.max),
                  !dependency.fileSHA256.isZero else {
                throw WindowsExecutionContractError(
                    reason: .admissionRendererClosureInvalid,
                    stage: .rendererSnapshot,
                    detail: "renderer host dependency path or aggregate is invalid"
                )
            }
            aggregate = sum.partialValue
            return (path, bytes, dependency.fileSHA256)
        }.sorted { $0.1.lexicographicallyPrecedes($1.1) }
        guard Set(canonical.map(\.0)).count == canonical.count else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .rendererSnapshot,
                detail: "renderer host dependency path is duplicated"
            )
        }
        var data = Data()
        for dependency in canonical {
            WindowsExecutionBinaryCodec.appendUInt16(
                UInt16(dependency.1.count),
                to: &data
            )
            data.append(contentsOf: dependency.1)
            data.append(contentsOf: dependency.2.bytes)
        }
        return .hash(data)
    }

    static func completePayloadSHA256(
        backendIdentifier: WindowsExecutionSHA256,
        backendMajor: UInt16,
        backendMinor: UInt16,
        hostClosure: WindowsExecutionSHA256,
        architectures: [WindowsRendererArchitectureEntry]
    ) -> WindowsExecutionSHA256 {
        var data = Data("FPRENDER1".utf8)
        data.append(contentsOf: backendIdentifier.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(backendMajor, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(backendMinor, to: &data)
        data.append(contentsOf: hostClosure.bytes)
        for architecture in architectures.sorted(by: {
            $0.peMachine < $1.peMachine
        }) {
            WindowsExecutionBinaryCodec.appendUInt16(
                architecture.peMachine.rawValue,
                to: &data
            )
            WindowsExecutionBinaryCodec.appendUInt16(
                architecture.flags.rawValue,
                to: &data
            )
            data.append(contentsOf: architecture.architecturePayloadSHA256.bytes)
        }
        return .hash(data)
    }
}

struct WindowsExecutionValidatedCapabilityRecords: Hashable, Sendable {
    let descriptor: WindowsExecutionLaunchDescriptorV1
    let rendererSnapshot: WindowsRendererCapabilitySnapshotV1
    let negotiation: WindowsExecutionNegotiationResult
    let bootstrap: WindowsPreparedSessionBootstrapV2
}

enum WindowsExecutionCapabilityRecordTransaction {
    static func validateAndConsume(
        descriptorData: Data,
        rendererSnapshotData: Data,
        nowMonotonicNanoseconds: UInt64,
        runtimeManifest: WindowsRuntimeExecutionManifestV1,
        consumeRegistry: WindowsExecutionSingleConsumeRegistry
    ) throws -> WindowsExecutionValidatedCapabilityRecords {
        let descriptor = try WindowsExecutionLaunchDescriptorV1.decode(
            descriptorData,
            nowMonotonicNanoseconds: nowMonotonicNanoseconds
        )
        let snapshot = try WindowsRendererCapabilitySnapshotV1.decode(
            rendererSnapshotData
        )
        guard descriptor.sequence == snapshot.sequence,
              descriptor.runID == snapshot.runID,
              descriptor.sessionNonce == snapshot.sessionNonce,
              descriptor.prefixScopeSHA256 == snapshot.prefixScopeSHA256,
              descriptor.runtimeFingerprintSHA256 ==
                snapshot.runtimeFingerprintSHA256,
              descriptor.runtimeFingerprintSHA256 ==
                runtimeManifest.runtimeFingerprintSHA256,
              descriptor.rendererCapabilityFingerprintSHA256
                .isAuthenticatedEqual(to: snapshot.recordSHA256) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .descriptor,
                detail: "launch descriptor and renderer snapshot are not cross-bound"
            )
        }
        let negotiation = try WindowsExecutionCapabilityContract.negotiate(
            requirements: descriptor.requiredCapabilities,
            against: runtimeManifest
        )
        guard negotiation.requiredCapabilitySetFingerprintSHA256
            .isAuthenticatedEqual(
                to: descriptor.requiredCapabilitySetFingerprintSHA256
            ),
        let backend = runtimeManifest.capabilities.first(where: {
            $0.identifierSHA256 ==
                snapshot.backendCapabilityIdentifierSHA256
        }),
        backend.major == snapshot.backendCapabilityMajor,
        backend.minor >= snapshot.backendCapabilityMinor,
        descriptor.requiredCapabilities.contains(where: {
            $0.identifierSHA256 ==
                snapshot.backendCapabilityIdentifierSHA256 &&
            $0.requiredMajor == snapshot.backendCapabilityMajor &&
            snapshot.backendCapabilityMinor >= $0.minimumMinor
        }) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .negotiation,
                detail: "renderer backend is not covered by negotiation"
            )
        }
        let bootstrap = try WindowsPreparedSessionBootstrapV2(
            descriptor: descriptor,
            rendererSnapshot: snapshot
        )
        try consumeRegistry.consume(
            sequence: descriptor.sequence,
            runID: descriptor.runID,
            sessionNonce: descriptor.sessionNonce
        )
        return WindowsExecutionValidatedCapabilityRecords(
            descriptor: descriptor,
            rendererSnapshot: snapshot,
            negotiation: negotiation,
            bootstrap: bootstrap
        )
    }
}
