import XCTest
@testable import ForgePlay

private final class FakeAWDLCommandRunner:
    AWDLCommandRunning,
    @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<AWDLCommandResult, Error>]
    private(set) var recordedArguments: [[String]] = []

    init(_ responses: [Result<AWDLCommandResult, Error>]) {
        self.responses = responses
    }

    func runIfconfig(arguments: [String]) throws -> AWDLCommandResult {
        lock.lock()
        defer { lock.unlock() }
        recordedArguments.append(arguments)
        guard !responses.isEmpty else {
            throw AWDLCommandRunnerError.launchFailed("missing fake response")
        }
        return try responses.removeFirst().get()
    }
}

@MainActor
private final class FakeAWDLRegistrationManager:
    AWDLHelperRegistrationManaging {
    var registrationState: AWDLControlRegistrationState
    var stateAfterRegistration: AWDLControlRegistrationState
    private(set) var registerCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        state: AWDLControlRegistrationState,
        stateAfterRegistration: AWDLControlRegistrationState = .enabled
    ) {
        registrationState = state
        self.stateAfterRegistration = stateAfterRegistration
    }

    func register() throws {
        registerCallCount += 1
        registrationState = stateAfterRegistration
    }

    func openApprovalSettings() {
        openSettingsCallCount += 1
    }
}

private final class FakeAWDLControlClient:
    AWDLControlRequesting,
    @unchecked Sendable {
    let readResponse: AWDLControlXPCResponse
    let setResponse: @Sendable (Bool) -> AWDLControlXPCResponse
    private let lock = NSLock()
    private var recordedSetRequests: [Bool] = []

    init(
        readResponse: AWDLControlXPCResponse,
        setResponse: @escaping @Sendable (Bool) -> AWDLControlXPCResponse
    ) {
        self.readResponse = readResponse
        self.setResponse = setResponse
    }

    var setRequests: [Bool] {
        lock.withLock { recordedSetRequests }
    }

    func readInterfaceState() async throws -> AWDLControlXPCResponse {
        readResponse
    }

    func setInterfaceEnabled(_ enabled: Bool) async throws -> AWDLControlXPCResponse {
        lock.withLock {
            recordedSetRequests.append(enabled)
        }
        return setResponse(enabled)
    }
}

private actor BlockingAWDLControlClient: AWDLControlRequesting {
    private var readContinuation:
        CheckedContinuation<AWDLControlXPCResponse, Never>?
    private var didStartRead = false

    func readInterfaceState() async throws -> AWDLControlXPCResponse {
        didStartRead = true
        return await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
    }

    func setInterfaceEnabled(_ enabled: Bool) async throws -> AWDLControlXPCResponse {
        Self.successResponse(enabled ? .enabled : .disabled)
    }

    func hasStartedRead() -> Bool {
        didStartRead
    }

    func finishRead() {
        readContinuation?.resume(returning: Self.successResponse(.enabled))
        readContinuation = nil
    }

    private static func successResponse(
        _ state: AWDLInterfaceState
    ) -> AWDLControlXPCResponse {
        AWDLControlXPCResponse(
            state: state,
            errorCode: .none,
            technicalDetail: nil
        )
    }
}

final class AWDLControlTests: XCTestCase {
    func testPrivilegedControllerUsesOnlyFixedIfconfigArgumentsAndReadback() {
        let runner = FakeAWDLCommandRunner([
            .success(Self.ifconfigResult(
                "awdl0: flags=8943<UP,BROADCAST,RUNNING,MULTICAST> mtu 1500"
            )),
            .success(Self.ifconfigResult("")),
            .success(Self.ifconfigResult(
                "awdl0: flags=8842<BROADCAST,RUNNING,MULTICAST> mtu 1500"
            ))
        ])
        let controller = AWDLPrivilegedOperationController(runner: runner)

        let response = controller.setInterfaceEnabled(false)

        XCTAssertTrue(response.succeeded)
        XCTAssertEqual(response.state, .disabled)
        XCTAssertEqual(
            runner.recordedArguments,
            [["awdl0"], ["awdl0", "down"], ["awdl0"]]
        )
        XCTAssertEqual(SystemAWDLCommandRunner.executableURL.path, "/sbin/ifconfig")
    }

    func testPrivilegedControllerFailsWhenReadbackDoesNotMatchRequest() {
        let enabled = Self.ifconfigResult(
            "awdl0: flags=8943<UP,BROADCAST,RUNNING,MULTICAST> mtu 1500"
        )
        let runner = FakeAWDLCommandRunner([
            .success(enabled),
            .success(Self.ifconfigResult("")),
            .success(enabled)
        ])
        let response = AWDLPrivilegedOperationController(runner: runner)
            .setInterfaceEnabled(false)

        XCTAssertFalse(response.succeeded)
        XCTAssertEqual(response.state, .unavailable)
        XCTAssertEqual(response.errorCode, .readbackMismatch)
    }

    func testInterfaceParserRequiresExactAWDLInterfaceAndUPFlag() throws {
        XCTAssertEqual(
            try AWDLPrivilegedOperationController.parseInterfaceState(
                "awdl0: flags=8943<UP,BROADCAST,RUNNING> mtu 1500\n"
            ),
            .enabled
        )
        XCTAssertEqual(
            try AWDLPrivilegedOperationController.parseInterfaceState(
                "awdl0: flags=8842<BROADCAST,RUNNING> mtu 1500\n"
            ),
            .disabled
        )
        XCTAssertThrowsError(
            try AWDLPrivilegedOperationController.parseInterfaceState(
                "en0: flags=8943<UP,BROADCAST,RUNNING> mtu 1500\n"
            )
        )
    }

    func testNetworkControlIdentityBindsHelperAndAppGroupChildService() throws {
        let app = try ForgePlayNetworkControlIdentity.validatedIdentity(
            identifier: "com.forgeplay.client",
            teamIdentifier: "ABCDE12345"
        )
        let helper = try ForgePlayNetworkControlIdentity.validatedIdentity(
            identifier: "com.forgeplay.client.network-control-helper",
            teamIdentifier: "ABCDE12345"
        )

        XCTAssertEqual(
            ForgePlayNetworkControlIdentity.machServiceName(
                forMainApplication: app
            ),
            "ABCDE12345.com.forgeplay.client.network-control"
        )
        XCTAssertEqual(
            ForgePlayNetworkControlIdentity.helperIdentifier(
                forMainApplication: app
            ),
            helper.identifier
        )
        XCTAssertEqual(
            try ForgePlayNetworkControlIdentity.mainApplicationIdentity(
                fromHelper: helper
            ),
            app
        )
        let requirement = try ForgePlayNetworkControlIdentity
            .codeSigningRequirement(
                identifier: helper.identifier,
                teamIdentifier: helper.teamIdentifier
            )
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("identifier \"\(helper.identifier)\""))
        XCTAssertTrue(requirement.contains("subject.OU"))
    }

    @MainActor
    func testServiceRegistersThenPublishesActualInterfaceReadback() async throws {
        let registration = FakeAWDLRegistrationManager(state: .notRegistered)
        let client = FakeAWDLControlClient(
            readResponse: Self.successResponse(.enabled),
            setResponse: { enabled in
                Self.successResponse(enabled ? .enabled : .disabled)
            }
        )
        let service = AWDLControlService(
            isSupported: true,
            registrationManager: registration,
            makeClient: { client }
        )

        try await service.registerHelper()
        XCTAssertEqual(registration.registerCallCount, 1)
        XCTAssertEqual(service.registrationState, .enabled)
        XCTAssertEqual(service.interfaceState, .enabled)
        XCTAssertEqual(client.setRequests, [true])

        try await service.setInterfaceEnabled(false)
        XCTAssertEqual(service.interfaceState, .disabled)
        XCTAssertEqual(client.setRequests, [true, false])
        XCTAssertNil(service.lastError)
    }

    @MainActor
    func testServiceStopsForExplicitBackgroundItemApproval() async {
        let registration = FakeAWDLRegistrationManager(
            state: .notRegistered,
            stateAfterRegistration: .requiresApproval
        )
        let client = FakeAWDLControlClient(
            readResponse: Self.successResponse(.enabled),
            setResponse: { _ in Self.successResponse(.disabled) }
        )
        let service = AWDLControlService(
            isSupported: true,
            registrationManager: registration,
            makeClient: { client }
        )

        do {
            try await service.registerHelper()
            XCTFail("registration should require explicit user approval")
        } catch {
            XCTAssertEqual(error as? AWDLControlError, .helperRequiresApproval)
        }
        XCTAssertEqual(service.registrationState, .requiresApproval)
    }

    @MainActor
    func testMutatingCommandsFailInsteadOfReportingSuccessDuringActiveRefresh() async throws {
        let registration = FakeAWDLRegistrationManager(state: .enabled)
        let client = BlockingAWDLControlClient()
        let service = AWDLControlService(
            isSupported: true,
            registrationManager: registration,
            makeClient: { client }
        )
        let refresh = Task { @MainActor in
            await service.refresh()
        }
        while !(await client.hasStartedRead()) {
            await Task.yield()
        }

        do {
            try await service.registerHelper()
            XCTFail("registerHelper must not silently succeed during refresh")
        } catch {
            XCTAssertEqual(error as? AWDLControlError, .operationInProgress)
        }
        do {
            try await service.setInterfaceEnabled(false)
            XCTFail("setInterfaceEnabled must not silently succeed during refresh")
        } catch {
            XCTAssertEqual(error as? AWDLControlError, .operationInProgress)
        }

        await client.finishRead()
        await refresh.value
        XCTAssertEqual(service.interfaceState, .enabled)
    }

    func testCurrentDirectDistributionCompilationEnablesInputAndAWDLControls() {
        #if FORGEPLAY_APP_STORE
        XCTAssertFalse(GameInputProtectionBuildCapability.isSupportedInCurrentBuild)
        XCTAssertFalse(AWDLControlBuildCapability.isSupportedInCurrentBuild)
        #else
        XCTAssertTrue(GameInputProtectionBuildCapability.isSupportedInCurrentBuild)
        XCTAssertTrue(AWDLControlBuildCapability.isSupportedInCurrentBuild)
        #endif
    }

    func testTogglePresentationDoesNotMisrepresentUnavailableStateAsEnabled() {
        XCTAssertEqual(
            AWDLTogglePresentation(interfaceState: .unavailable),
            .unavailable
        )
        XCTAssertNil(
            AWDLTogglePresentation(interfaceState: .unavailable).isOn
        )
        XCTAssertEqual(
            AWDLTogglePresentation(interfaceState: .enabled).isOn,
            true
        )
        XCTAssertEqual(
            AWDLTogglePresentation(interfaceState: .disabled).isOn,
            false
        )
    }

    @MainActor
    func testRefreshClearsStaleConnectionErrorWhenHelperIsNoLongerEnabled() async {
        let registration = FakeAWDLRegistrationManager(state: .enabled)
        let failedResponse = AWDLControlXPCResponse(
            state: .unavailable,
            errorCode: .commandFailed,
            technicalDetail: "fixture failure"
        )
        let service = AWDLControlService(
            isSupported: true,
            registrationManager: registration,
            makeClient: {
                FakeAWDLControlClient(
                    readResponse: failedResponse,
                    setResponse: { _ in failedResponse }
                )
            }
        )

        await service.refresh()
        XCTAssertNotNil(service.lastError)

        registration.registrationState = .notRegistered
        await service.refresh()
        XCTAssertEqual(service.registrationState, .notRegistered)
        XCTAssertEqual(service.interfaceState, .unavailable)
        XCTAssertNil(service.lastError)

        registration.registrationState = .enabled
        await service.refresh()
        XCTAssertNotNil(service.lastError)

        registration.registrationState = .requiresApproval
        await service.refresh()
        XCTAssertEqual(service.registrationState, .requiresApproval)
        XCTAssertEqual(service.interfaceState, .unavailable)
        XCTAssertNil(service.lastError)
    }

    private static func ifconfigResult(_ output: String) -> AWDLCommandResult {
        AWDLCommandResult(
            terminationStatus: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    private static func successResponse(
        _ state: AWDLInterfaceState
    ) -> AWDLControlXPCResponse {
        AWDLControlXPCResponse(
            state: state,
            errorCode: .none,
            technicalDetail: nil
        )
    }
}
