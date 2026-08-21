import Foundation
import Observation
import ServiceManagement

enum AWDLControlBuildCapability {
    #if FORGEPLAY_APP_STORE
    static let isSupportedInCurrentBuild = false
    #else
    static let isSupportedInCurrentBuild = true
    #endif
}

enum AWDLControlRegistrationState: Hashable, Sendable {
    case unsupported
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum AWDLControlError: Error, Equatable, Sendable {
    case unsupportedBuild
    case operationInProgress
    case helperNotFound
    case helperRequiresApproval
    case registrationFailed(String)
    case connectionFailed(String)
    case requestTimedOut
    case helperRejected(code: Int, detail: String)
    case readbackMismatch
}

@MainActor
protocol AWDLHelperRegistrationManaging: AnyObject {
    var registrationState: AWDLControlRegistrationState { get }
    func register() throws
    func openApprovalSettings()
}

@MainActor
final class SMAppServiceAWDLRegistrationManager:
    AWDLHelperRegistrationManaging {
    private let service: SMAppService

    init(
        service: SMAppService = .daemon(
            plistName: ForgePlayNetworkControlIdentity.daemonManifestName
        )
    ) {
        self.service = service
    }

    var registrationState: AWDLControlRegistrationState {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

protocol AWDLControlRequesting: Sendable {
    func readInterfaceState() async throws -> AWDLControlXPCResponse
    func setInterfaceEnabled(_ enabled: Bool) async throws -> AWDLControlXPCResponse
}

enum AWDLControlXPCClientError: Error, Equatable, Sendable {
    case unavailable(String)
    case timedOut
}

private final class AWDLXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<AWDLControlXPCResponse, Error>?
    private let connection: NSXPCConnection
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NSXPCConnection,
        continuation: CheckedContinuation<AWDLControlXPCResponse, Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func armTimeout(seconds: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AWDLControlXPCClientError.timedOut))
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + seconds,
            execute: workItem
        )
    }

    func finish(_ result: Result<AWDLControlXPCResponse, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}

struct AWDLControlXPCClient: AWDLControlRequesting {
    private let serviceName: String
    private let helperRequirement: String
    private let timeoutSeconds: TimeInterval

    init(
        serviceName: String,
        helperRequirement: String,
        timeoutSeconds: TimeInterval = 8
    ) {
        self.serviceName = serviceName
        self.helperRequirement = helperRequirement
        self.timeoutSeconds = timeoutSeconds
    }

    static func currentApplicationClient() throws -> AWDLControlXPCClient {
        let applicationIdentity = try ForgePlayNetworkControlIdentity.current()
        let helperIdentifier = ForgePlayNetworkControlIdentity.helperIdentifier(
            forMainApplication: applicationIdentity
        )
        return AWDLControlXPCClient(
            serviceName: ForgePlayNetworkControlIdentity.machServiceName(
                forMainApplication: applicationIdentity
            ),
            helperRequirement: try ForgePlayNetworkControlIdentity
                .codeSigningRequirement(
                    identifier: helperIdentifier,
                    teamIdentifier: applicationIdentity.teamIdentifier
                )
        )
    }

    func readInterfaceState() async throws -> AWDLControlXPCResponse {
        try await request { proxy, reply in
            proxy.readInterfaceState(withReply: reply)
        }
    }

    func setInterfaceEnabled(_ enabled: Bool) async throws -> AWDLControlXPCResponse {
        try await request { proxy, reply in
            proxy.setInterfaceEnabled(enabled, withReply: reply)
        }
    }

    private func request(
        _ invoke: @escaping (
            ForgePlayAWDLControlXPCProtocol,
            @escaping (Int, Int, String?) -> Void
        ) -> Void
    ) async throws -> AWDLControlXPCResponse {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: serviceName,
                options: .privileged
            )
            let gate = AWDLXPCReplyGate(
                connection: connection,
                continuation: continuation
            )
            connection.remoteObjectInterface = NSXPCInterface(
                with: ForgePlayAWDLControlXPCProtocol.self
            )
            connection.setCodeSigningRequirement(helperRequirement)
            connection.interruptionHandler = {
                gate.finish(.failure(
                    AWDLControlXPCClientError.unavailable("connection interrupted")
                ))
            }
            connection.invalidationHandler = {
                gate.finish(.failure(
                    AWDLControlXPCClientError.unavailable("connection invalidated")
                ))
            }
            connection.activate()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                gate.finish(.failure(
                    AWDLControlXPCClientError.unavailable(
                        String(String(describing: error).prefix(512))
                    )
                ))
            }
            guard let typedProxy = proxy as? ForgePlayAWDLControlXPCProtocol else {
                gate.finish(.failure(
                    AWDLControlXPCClientError.unavailable("invalid remote interface")
                ))
                return
            }

            gate.armTimeout(seconds: timeoutSeconds)
            invoke(typedProxy) { stateRawValue, errorRawValue, detail in
                let state = AWDLInterfaceState(rawValue: stateRawValue) ?? .unavailable
                let errorCode = AWDLControlXPCErrorCode(rawValue: errorRawValue) ??
                    .internalFailure
                gate.finish(.success(
                    AWDLControlXPCResponse(
                        state: state,
                        errorCode: errorCode,
                        technicalDetail: detail.map { String($0.prefix(512)) }
                    )
                ))
            }
        }
    }
}

@MainActor
@Observable
final class AWDLControlService {
    private(set) var registrationState: AWDLControlRegistrationState
    private(set) var interfaceState: AWDLInterfaceState = .unavailable
    private(set) var isWorking = false
    private(set) var lastError: AWDLControlError?

    @ObservationIgnored
    private let isSupported: Bool
    @ObservationIgnored
    private let registrationManager: any AWDLHelperRegistrationManaging
    @ObservationIgnored
    private let makeClient: @MainActor () throws -> any AWDLControlRequesting

    init(
        isSupported: Bool = AWDLControlBuildCapability.isSupportedInCurrentBuild,
        registrationManager: (any AWDLHelperRegistrationManaging)? = nil,
        makeClient: (@MainActor () throws -> any AWDLControlRequesting)? = nil
    ) {
        self.isSupported = isSupported
        let registrationManager = registrationManager ??
            SMAppServiceAWDLRegistrationManager()
        self.registrationManager = registrationManager
        self.makeClient = makeClient ?? {
            try AWDLControlXPCClient.currentApplicationClient()
        }
        registrationState = isSupported
            ? registrationManager.registrationState
            : .unsupported
    }

    func refresh() async {
        guard !isWorking else { return }
        guard isSupported else {
            registrationState = .unsupported
            interfaceState = .unavailable
            lastError = nil
            return
        }
        isWorking = true
        defer { isWorking = false }
        registrationState = registrationManager.registrationState
        guard registrationState == .enabled else {
            interfaceState = .unavailable
            lastError = nil
            return
        }
        do {
            let client = try makeClient()
            interfaceState = try checkedResponse(
                try await client.readInterfaceState()
            )
            lastError = nil
        } catch {
            interfaceState = .unavailable
            lastError = Self.map(error)
        }
    }

    func registerHelper(defaultInterfaceEnabled: Bool = true) async throws {
        guard !isWorking else { throw AWDLControlError.operationInProgress }
        guard isSupported else { throw AWDLControlError.unsupportedBuild }
        isWorking = true
        defer { isWorking = false }
        do {
            try registrationManager.register()
        } catch {
            let mapped = AWDLControlError.registrationFailed(
                String(String(describing: error).prefix(512))
            )
            lastError = mapped
            throw mapped
        }
        registrationState = registrationManager.registrationState
        if registrationState == .requiresApproval {
            let error = AWDLControlError.helperRequiresApproval
            lastError = error
            throw error
        }
        guard registrationState == .enabled else {
            let error = AWDLControlError.helperNotFound
            lastError = error
            throw error
        }
        do {
            let client = try makeClient()
            let state = try checkedResponse(
                try await client.setInterfaceEnabled(defaultInterfaceEnabled)
            )
            let expected: AWDLInterfaceState = defaultInterfaceEnabled
                ? .enabled
                : .disabled
            guard state == expected else {
                throw AWDLControlError.readbackMismatch
            }
            interfaceState = state
            lastError = nil
        } catch {
            let mapped = Self.map(error)
            lastError = mapped
            throw mapped
        }
    }

    func setInterfaceEnabled(_ enabled: Bool) async throws {
        guard !isWorking else { throw AWDLControlError.operationInProgress }
        guard isSupported else { throw AWDLControlError.unsupportedBuild }
        isWorking = true
        defer { isWorking = false }

        do {
            try ensureRegisteredHelperIsEnabled()
            let client = try makeClient()
            let state = try checkedResponse(
                try await client.setInterfaceEnabled(enabled)
            )
            let expected: AWDLInterfaceState = enabled ? .enabled : .disabled
            guard state == expected else {
                throw AWDLControlError.readbackMismatch
            }
            interfaceState = state
            lastError = nil
        } catch {
            let mapped = Self.map(error)
            registrationState = registrationManager.registrationState
            lastError = mapped
            throw mapped
        }
    }

    func openApprovalSettings() {
        registrationManager.openApprovalSettings()
    }

    private func ensureRegisteredHelperIsEnabled() throws {
        registrationState = registrationManager.registrationState
        if registrationState == .notRegistered || registrationState == .notFound {
            do {
                try registrationManager.register()
            } catch {
                throw AWDLControlError.registrationFailed(
                    String(String(describing: error).prefix(512))
                )
            }
            registrationState = registrationManager.registrationState
        }
        switch registrationState {
        case .enabled:
            return
        case .requiresApproval:
            throw AWDLControlError.helperRequiresApproval
        case .notFound, .notRegistered:
            throw AWDLControlError.helperNotFound
        case .unsupported:
            throw AWDLControlError.unsupportedBuild
        }
    }

    private func checkedResponse(
        _ response: AWDLControlXPCResponse
    ) throws -> AWDLInterfaceState {
        guard response.succeeded else {
            throw AWDLControlError.helperRejected(
                code: response.errorCode.rawValue,
                detail: response.technicalDetail ?? "no detail"
            )
        }
        guard response.state != .unavailable else {
            throw AWDLControlError.readbackMismatch
        }
        return response.state
    }

    private static func map(_ error: Error) -> AWDLControlError {
        if let awdlError = error as? AWDLControlError {
            return awdlError
        }
        if let clientError = error as? AWDLControlXPCClientError {
            switch clientError {
            case .timedOut:
                return .requestTimedOut
            case .unavailable(let detail):
                return .connectionFailed(detail)
            }
        }
        return .connectionFailed(String(String(describing: error).prefix(512)))
    }
}
