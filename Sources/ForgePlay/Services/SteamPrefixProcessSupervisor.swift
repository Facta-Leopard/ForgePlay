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
