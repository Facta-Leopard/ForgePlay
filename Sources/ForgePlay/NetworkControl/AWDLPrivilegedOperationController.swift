import Darwin
import Foundation

struct AWDLCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

protocol AWDLCommandRunning: Sendable {
    func runIfconfig(arguments: [String]) throws -> AWDLCommandResult
}

enum AWDLCommandRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
}

struct SystemAWDLCommandRunner: AWDLCommandRunning {
    static let executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
    private let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 3) {
        self.timeoutSeconds = timeoutSeconds
    }

    func runIfconfig(arguments: [String]) throws -> AWDLCommandResult {
        let capture: BoundedProcessCaptureResult
        do {
            capture = try BoundedProcessExecutor.capture(
                executable: Self.executableURL,
                arguments: arguments,
                timeout: timeoutSeconds
            )
        } catch {
            throw AWDLCommandRunnerError.launchFailed(
                Self.boundedDiagnostic(String(describing: error))
            )
        }
        guard !capture.didTimeOut, capture.didExit else {
            throw AWDLCommandRunnerError.timedOut
        }
        return AWDLCommandResult(
            terminationStatus: capture.exitCode,
            standardOutput: Self.boundedDiagnostic(
                String(decoding: capture.stdout, as: UTF8.self)
            ),
            standardError: Self.boundedDiagnostic(
                String(decoding: capture.stderr, as: UTF8.self)
            )
        )
    }

    private static func boundedDiagnostic(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(sanitized.prefix(2_048))
    }
}

enum AWDLPrivilegedOperationError: Error, Equatable, Sendable {
    case commandLaunchFailed(String)
    case commandTimedOut
    case commandFailed(status: Int32, detail: String)
    case invalidReadback(String)
    case readbackMismatch(expected: AWDLInterfaceState, actual: AWDLInterfaceState)
}

final class AWDLPrivilegedOperationController: @unchecked Sendable {
    private static let interfaceName = "awdl0"
    private let runner: any AWDLCommandRunning
    private let operationLock = NSLock()

    init(runner: any AWDLCommandRunning = SystemAWDLCommandRunner()) {
        self.runner = runner
    }

    func readInterfaceState() -> AWDLControlXPCResponse {
        withSerializedOperation {
            Self.response { try queryInterfaceState() }
        }
    }

    func setInterfaceEnabled(_ enabled: Bool) -> AWDLControlXPCResponse {
        withSerializedOperation {
            Self.response {
                let expectedState: AWDLInterfaceState = enabled ? .enabled : .disabled
                if try queryInterfaceState() == expectedState {
                    return expectedState
                }

                _ = try checkedRun([
                    Self.interfaceName,
                    enabled ? "up" : "down"
                ])
                let readbackState = try queryInterfaceState()
                guard readbackState == expectedState else {
                    throw AWDLPrivilegedOperationError.readbackMismatch(
                        expected: expectedState,
                        actual: readbackState
                    )
                }
                return readbackState
            }
        }
    }

    static func parseInterfaceState(_ output: String) throws -> AWDLInterfaceState {
        guard let firstLine = output.split(whereSeparator: \Character.isNewline).first,
              firstLine.hasPrefix("\(interfaceName):"),
              let opening = firstLine.firstIndex(of: "<"),
              let closing = firstLine[opening...].firstIndex(of: ">"),
              opening < closing else {
            throw AWDLPrivilegedOperationError.invalidReadback(
                String(output.prefix(256))
            )
        }
        let flags = firstLine[firstLine.index(after: opening)..<closing]
            .split(separator: ",")
        return flags.contains("UP") ? .enabled : .disabled
    }

    private func queryInterfaceState() throws -> AWDLInterfaceState {
        let result = try checkedRun([Self.interfaceName])
        return try Self.parseInterfaceState(result.standardOutput)
    }

    private func checkedRun(_ arguments: [String]) throws -> AWDLCommandResult {
        let result: AWDLCommandResult
        do {
            result = try runner.runIfconfig(arguments: arguments)
        } catch AWDLCommandRunnerError.timedOut {
            throw AWDLPrivilegedOperationError.commandTimedOut
        } catch AWDLCommandRunnerError.launchFailed(let detail) {
            throw AWDLPrivilegedOperationError.commandLaunchFailed(detail)
        } catch {
            throw AWDLPrivilegedOperationError.commandLaunchFailed(
                String(String(describing: error).prefix(512))
            )
        }
        guard result.terminationStatus == 0 else {
            let detail = result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            throw AWDLPrivilegedOperationError.commandFailed(
                status: result.terminationStatus,
                detail: String(detail.prefix(512))
            )
        }
        return result
    }

    private func withSerializedOperation<T>(_ operation: () -> T) -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return operation()
    }

    private static func response(
        operation: () throws -> AWDLInterfaceState
    ) -> AWDLControlXPCResponse {
        do {
            return AWDLControlXPCResponse(
                state: try operation(),
                errorCode: .none,
                technicalDetail: nil
            )
        } catch AWDLPrivilegedOperationError.commandLaunchFailed(let detail) {
            return failure(.commandLaunchFailed, detail)
        } catch AWDLPrivilegedOperationError.commandTimedOut {
            return failure(.commandTimedOut, "ifconfig timed out")
        } catch AWDLPrivilegedOperationError.commandFailed(let status, let detail) {
            return failure(.commandFailed, "status=\(status) \(detail)")
        } catch AWDLPrivilegedOperationError.invalidReadback(let detail) {
            return failure(.invalidReadback, detail)
        } catch AWDLPrivilegedOperationError.readbackMismatch(let expected, let actual) {
            return failure(
                .readbackMismatch,
                "expected=\(expected.rawValue) actual=\(actual.rawValue)"
            )
        } catch {
            return failure(.internalFailure, String(describing: error))
        }
    }

    private static func failure(
        _ code: AWDLControlXPCErrorCode,
        _ detail: String
    ) -> AWDLControlXPCResponse {
        AWDLControlXPCResponse(
            state: .unavailable,
            errorCode: code,
            technicalDetail: String(detail.prefix(512))
        )
    }
}
