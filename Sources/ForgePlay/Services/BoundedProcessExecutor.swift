import Darwin
import Foundation

struct BoundedProcessWaitOutcome: Sendable, Hashable {
    var didExit: Bool
    var didTimeOut: Bool
}

struct BoundedProcessCaptureResult: Sendable, Hashable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var didTimeOut: Bool
    var didExit: Bool
}

struct BoundedProcessExecutionResult: Sendable, Hashable {
    var processIdentifier: Int32
    /// The root process's real exit status, or nil when it was signaled or was
    /// not reaped. This is independent of process-group cleanup policy.
    var processExitCode: Int32?
    /// Overall bounded-execution status such as timeout 124. This is not an OS
    /// process exit status.
    var forgePlayStatusCode: Int32?
    var exitCode: Int32
    var waitOutcome: BoundedProcessWaitOutcome
    var terminationSignal: Int32?
    var rawWaitStatus: Int32?
    /// Present when the operating system no longer exposes the root child's
    /// wait status. Never synthesize an exit code or signal in this state.
    var waitStatusCaptureError: String?
}

enum BoundedProcessExecutorError: LocalizedError {
    case cannotCreateCaptureFile(URL)
    case cannotReadCaptureFile(URL, String)
    case cannotStartProcess(URL, String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateCaptureFile(let url):
            "프로세스 출력 캡처 파일을 안전하게 만들 수 없습니다: \(url.path)"
        case .cannotReadCaptureFile(let url, let message):
            "프로세스 출력 캡처 파일을 읽을 수 없습니다: \(url.path). \(message)"
        case .cannotStartProcess(let url, let message):
            "프로세스를 안전한 실행 그룹에서 시작할 수 없습니다: \(url.path). \(message)"
        }
    }
}

enum BoundedProcessExecutor {
    static let forcedTimeoutExitCode: Int32 = 124

    private final class SpawnedProcessGroup: @unchecked Sendable {
        let processIdentifier: pid_t
        let processGroupIdentifier: pid_t
        private let waitStateLock = NSLock()
        private var storedWaitStatus: Int32?
        private var storedWaitErrorCode: Int32?
        private var waitCompleted = false

        init(processIdentifier: pid_t) {
            self.processIdentifier = processIdentifier
            self.processGroupIdentifier = processIdentifier
        }

        var waitStatus: Int32? {
            waitStateLock.withLock { storedWaitStatus }
        }

        var waitErrorCode: Int32? {
            waitStateLock.withLock { storedWaitErrorCode }
        }

        var isRootRunning: Bool {
            waitStateLock.withLock { !waitCompleted }
        }

        var exitCode: Int32 {
            guard let waitStatus else { return forcedTimeoutExitCode }
            let terminationSignal = waitStatus & 0x7f
            if terminationSignal == 0 {
                return (waitStatus >> 8) & 0xff
            }
            return 128 + terminationSignal
        }

        var terminationSignal: Int32? {
            guard let waitStatus else { return nil }
            let signal = waitStatus & 0x7f
            return signal == 0 ? nil : signal
        }

        func startWaitingForRootStatus() {
            Thread.detachNewThread { [self] in
                waitForRootStatus()
            }
        }

        private func waitForRootStatus() {
            var status: Int32 = 0
            while true {
                let result = waitpid(processIdentifier, &status, 0)
                if result == processIdentifier {
                    finishWaiting(status: status, errorCode: nil)
                    return
                }
                if result < 0, errno == EINTR {
                    continue
                }
                finishWaiting(status: nil, errorCode: result < 0 ? errno : ECHILD)
                return
            }
        }

        private func finishWaiting(status: Int32?, errorCode: Int32?) {
            waitStateLock.withLock {
                storedWaitStatus = status
                storedWaitErrorCode = errorCode
                waitCompleted = true
            }
        }
    }

    nonisolated static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 2,
        killGrace: TimeInterval = 2
    ) throws -> BoundedProcessExecutionResult {
        let process = try spawnProcessGroup(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            stdoutDescriptor: stdoutDescriptor,
            stderrDescriptor: stderrDescriptor
        )
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while process.isRootRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRootRunning else {
            let descendantsExited = terminateRemainingProcessGroup(
                process,
                terminationGrace: terminationGrace,
                killGrace: killGrace
            )
            return BoundedProcessExecutionResult(
                processIdentifier: process.processIdentifier,
                processExitCode: process.terminationSignal == nil && process.waitStatus != nil
                    ? process.exitCode
                    : nil,
                forgePlayStatusCode: descendantsExited ? nil : forcedTimeoutExitCode,
                exitCode: descendantsExited ? process.exitCode : forcedTimeoutExitCode,
                waitOutcome: BoundedProcessWaitOutcome(
                    didExit: descendantsExited,
                    didTimeOut: !descendantsExited
                ),
                terminationSignal: process.terminationSignal,
                rawWaitStatus: process.waitStatus,
                waitStatusCaptureError: waitStatusCaptureError(for: process)
            )
        }

        signalProcessGroup(process, signal: SIGTERM)
        let terminationDeadline = Date().addingTimeInterval(max(terminationGrace, 0))
        while processGroupIsLive(process), Date() < terminationDeadline {
            _ = process.isRootRunning
            Thread.sleep(forTimeInterval: 0.01)
        }
        if processGroupIsLive(process) {
            signalProcessGroup(process, signal: SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(max(killGrace, 0))
        while processGroupIsLive(process), Date() < killDeadline {
            _ = process.isRootRunning
            Thread.sleep(forTimeInterval: 0.01)
        }
        _ = process.isRootRunning
        let didExit = !processGroupIsLive(process) && !process.isRootRunning
        if !didExit {
            startProcessGroupReaper(process.processGroupIdentifier)
        }
        return BoundedProcessExecutionResult(
            processIdentifier: process.processIdentifier,
            processExitCode: process.terminationSignal == nil && process.waitStatus != nil
                ? process.exitCode
                : nil,
            forgePlayStatusCode: forcedTimeoutExitCode,
            exitCode: didExit ? process.exitCode : forcedTimeoutExitCode,
            waitOutcome: BoundedProcessWaitOutcome(didExit: didExit, didTimeOut: true),
            terminationSignal: process.terminationSignal,
            rawWaitStatus: process.waitStatus,
            waitStatusCaptureError: waitStatusCaptureError(for: process)
        )
    }

    private nonisolated static func terminateRemainingProcessGroup(
        _ process: SpawnedProcessGroup,
        terminationGrace: TimeInterval,
        killGrace: TimeInterval
    ) -> Bool {
        guard processGroupIsLive(process) else { return true }
        signalProcessGroup(process, signal: SIGTERM)
        let terminationDeadline = Date().addingTimeInterval(max(terminationGrace, 0))
        while processGroupIsLive(process), Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard processGroupIsLive(process) else { return true }
        signalProcessGroup(process, signal: SIGKILL)
        let killDeadline = Date().addingTimeInterval(max(killGrace, 0))
        while processGroupIsLive(process), Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if processGroupIsLive(process) {
            startProcessGroupReaper(process.processGroupIdentifier)
            return false
        }
        return true
    }

    private nonisolated static func signalProcessGroup(
        _ process: SpawnedProcessGroup,
        signal: Int32
    ) {
        _ = Darwin.kill(-process.processGroupIdentifier, signal)
    }

    private nonisolated static func processGroupIsLive(_ process: SpawnedProcessGroup) -> Bool {
        _ = process.isRootRunning
        guard Darwin.kill(-process.processGroupIdentifier, 0) != 0 else { return true }
        return errno == EPERM
    }

    private nonisolated static func startProcessGroupReaper(_ processGroupIdentifier: pid_t) {
        Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard Darwin.kill(-processGroupIdentifier, 0) == 0 || errno == EPERM else { return }
                _ = Darwin.kill(-processGroupIdentifier, SIGKILL)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private nonisolated static func spawnProcessGroup(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32
    ) throws -> SpawnedProcessGroup {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&fileActions)
        guard result == 0 else {
            throw spawnError(executable: executable, code: result)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw spawnError(executable: executable, code: result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        for (descriptor, target) in [
            (stdoutDescriptor, STDOUT_FILENO),
            (stderrDescriptor, STDERR_FILENO)
        ] {
            result = posix_spawn_file_actions_adddup2(&fileActions, descriptor, target)
            guard result == 0 else {
                throw spawnError(executable: executable, code: result)
            }
        }
        if let workingDirectory {
            result = posix_spawn_file_actions_addchdir(&fileActions, workingDirectory.path)
            guard result == 0 else {
                throw spawnError(executable: executable, code: result)
            }
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        result = posix_spawnattr_setflags(&attributes, flags)
        guard result == 0 else {
            throw spawnError(executable: executable, code: result)
        }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else {
            throw spawnError(executable: executable, code: result)
        }

        var processIdentifier: pid_t = 0
        let argumentValues = [executable.path] + arguments
        let environmentValues = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        result = withCStringArray(argumentValues) { argumentPointers in
            withCStringArray(environmentValues) { environmentPointers in
                posix_spawn(
                    &processIdentifier,
                    executable.path,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        guard result == 0, processIdentifier > 0 else {
            throw spawnError(executable: executable, code: result == 0 ? ECHILD : result)
        }
        let process = SpawnedProcessGroup(processIdentifier: processIdentifier)
        process.startWaitingForRootStatus()
        return process
    }

    private nonisolated static func waitStatusCaptureError(
        for process: SpawnedProcessGroup
    ) -> String? {
        guard let errorCode = process.waitErrorCode else { return nil }
        return "waitpid(\(process.processIdentifier)) failed: " +
            String(cString: strerror(errorCode)) + " [errno=\(errorCode)]"
    }

    private nonisolated static func withCStringArray<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let strings: [UnsafeMutablePointer<CChar>] = values.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private nonisolated static func spawnError(
        executable: URL,
        code: Int32
    ) -> BoundedProcessExecutorError {
        BoundedProcessExecutorError.cannotStartProcess(
            executable,
            String(cString: strerror(code))
        )
    }

    nonisolated static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        fileManager: FileManager = .default
    ) throws -> BoundedProcessCaptureResult {
        let captureDirectory = fileManager.temporaryDirectory.appending(
            path: "ForgePlayProcessCapture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: captureDirectory) }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: captureDirectory.path)

        let stdoutURL = captureDirectory.appending(path: "stdout.log")
        let stderrURL = captureDirectory.appending(path: "stderr.log")
        let stdoutHandle = try openCaptureFileHandle(at: stdoutURL)
        let stderrHandle: FileHandle
        do {
            stderrHandle = try openCaptureFileHandle(at: stderrURL)
        } catch {
            try? stdoutHandle.close()
            throw error
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let execution = try run(
            executable: executable,
            arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment,
            workingDirectory: workingDirectory,
            stdoutDescriptor: stdoutHandle.fileDescriptor,
            stderrDescriptor: stderrHandle.fileDescriptor,
            timeout: timeout
        )
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdout: Data
        let stderr: Data
        do {
            stdout = try Data(contentsOf: stdoutURL, options: [.mappedIfSafe])
        } catch {
            throw BoundedProcessExecutorError.cannotReadCaptureFile(
                stdoutURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        do {
            stderr = try Data(contentsOf: stderrURL, options: [.mappedIfSafe])
        } catch {
            throw BoundedProcessExecutorError.cannotReadCaptureFile(
                stderrURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }

        return BoundedProcessCaptureResult(
            exitCode: execution.exitCode,
            stdout: stdout,
            stderr: stderr,
            didTimeOut: execution.waitOutcome.didTimeOut,
            didExit: execution.waitOutcome.didExit
        )
    }

    private nonisolated static func openCaptureFileHandle(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw BoundedProcessExecutorError.cannotCreateCaptureFile(url)
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw BoundedProcessExecutorError.cannotCreateCaptureFile(url)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
