import Foundation

final class SteamPrefixProcessSupervisor: @unchecked Sendable {
    private let runner: SafeProcessRunner

    init(runner: SafeProcessRunner) {
        self.runner = runner
    }

    func shutdownBeforeLaunch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult {
        let result = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ))
        guard result.succeeded else {
            throw SteamLaunchError.prefixShutdownFailed(result)
        }
        return result
    }

    func shutdownAfterFailure(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async -> (result: ProcessRunResult?, error: Error?) {
        do {
            let result = try await runner.run(.shutdownWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
            return (result, nil)
        } catch {
            return (nil, error)
        }
    }
}

actor SteamWindowsHelperProcessSupervision:
    WindowsHelperProcessSupervising {
    private enum State {
        case tracking
        case stopping
        case stopped
        case failed
    }

    private let supervisor: SteamPrefixProcessSupervisor
    private let runtimeExecutable: URL
    private let prefix: URL
    private let logDirectory: URL
    private var state = State.tracking

    init(
        supervisor: SteamPrefixProcessSupervisor,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) {
        self.supervisor = supervisor
        self.runtimeExecutable = runtimeExecutable
        self.prefix = prefix
        self.logDirectory = logDirectory
    }

    func requestWindowsHelperTermination() async throws {
        guard state == .tracking else {
            if state == .stopped {
                return
            }
            throw WindowsExecutionContractError(
                reason: .lifecycleCleanupFailed,
                stage: .cleanup,
                detail: "helper termination is already pending or failed"
            )
        }
        state = .stopping
        let outcome = await supervisor.shutdownAfterFailure(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        if let error = outcome.error {
            state = .failed
            throw error
        }
        guard let result = outcome.result, result.succeeded else {
            state = .failed
            if let result = outcome.result {
                throw SteamLaunchError.prefixShutdownFailed(result)
            }
            throw WindowsExecutionContractError(
                reason: .lifecycleCleanupFailed,
                stage: .cleanup,
                detail: "prefix supervisor returned no shutdown result"
            )
        }
        state = .stopped
    }

    func waitForWindowsHelperTermination(
        deadlineMonotonicNanoseconds: UInt64
    ) async throws -> Bool {
        guard deadlineMonotonicNanoseconds != 0 else {
            throw WindowsExecutionContractError(
                reason: .lifecycleDeadlineExceeded,
                stage: .cleanup,
                detail: "helper termination deadline is absent"
            )
        }
        return state == .stopped
    }

    func windowsHelperTrackedProcessCount() async -> Int {
        state == .stopped ? 0 : 1
    }
}

extension SteamPrefixProcessSupervisor {
    func windowsHelperSupervision(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) -> SteamWindowsHelperProcessSupervision {
        SteamWindowsHelperProcessSupervision(
            supervisor: self,
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
    }
}
