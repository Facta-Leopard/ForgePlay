import Foundation

enum WineAutomaticBacktraceState: String, Codable, Sendable, Hashable {
    case captured
    case debuggerStartFailed
    case notCaptured
}

struct SteamGameRuntimeCrashEvent: Codable, Sendable, Hashable {
    var exceptionCode: UInt32
    var exceptionStatusHex: String
    var threadIDHex: String?
    var instructionAddressHex: String?
    var windowsProcessID: Int32?
    var automaticBacktraceState: WineAutomaticBacktraceState
    var backtraceFrames: [String]
    var systemInformation: [String]
    var correlationBasis: String
}

struct WineRuntimeCrashObservation: Sendable, Hashable {
    var sourceSequence: Int
    var exceptionCode: UInt32
    var threadIDHex: String?
    var instructionAddressHex: String?
    var debuggerStartFailed: Bool
    var debuggerProcessID: Int32?
    var backtraceFrames: [String]
    var systemInformation: [String]

    var automaticBacktraceState: WineAutomaticBacktraceState {
        if debuggerStartFailed { return .debuggerStartFailed }
        return backtraceFrames.isEmpty ? .notCaptured : .captured
    }
}

/// Parses Wine's unhandled-exception line and the WineDbg `--auto` report.
/// Wine writes those halves to stderr and stdout respectively, so callers must
/// supply both streams from the same launch session.
enum WineRuntimeCrashEventParser {
    private struct DebuggerReport: Sendable, Hashable {
        var sourceSequence: Int
        var processID: Int32
        var exceptionCode: UInt32?
        var instructionAddressHex: String?
        var backtraceFrames: [String]
        var systemInformation: [String]
    }

    private static let maximumBacktraceFrames = 64
    private static let maximumSystemInformationLines = 16
    private static let maximumStoredLineBytes = 2_048

    static func parse(
        stdoutLines: [String],
        stderrLines: [String]
    ) -> [WineRuntimeCrashObservation] {
        var observations = parseRuntimeExceptions(stderrLines)
        let reports = parseDebuggerReports(stdoutLines)
        var unusedReportIndices = Set(reports.indices)

        for observationIndex in observations.indices.reversed() {
            guard let reportIndex = unusedReportIndices.sorted(by: >).first(where: {
                reports[$0].exceptionCode == observations[observationIndex].exceptionCode
            }) else {
                continue
            }
            let report = reports[reportIndex]
            observations[observationIndex].debuggerProcessID = report.processID
            observations[observationIndex].instructionAddressHex =
                observations[observationIndex].instructionAddressHex ?? report.instructionAddressHex
            observations[observationIndex].backtraceFrames = report.backtraceFrames
            observations[observationIndex].systemInformation = report.systemInformation
            unusedReportIndices.remove(reportIndex)
        }

        for reportIndex in unusedReportIndices.sorted() {
            let report = reports[reportIndex]
            guard let exceptionCode = report.exceptionCode else { continue }
            observations.append(WineRuntimeCrashObservation(
                sourceSequence: report.sourceSequence,
                exceptionCode: exceptionCode,
                threadIDHex: nil,
                instructionAddressHex: report.instructionAddressHex,
                debuggerStartFailed: false,
                debuggerProcessID: report.processID,
                backtraceFrames: report.backtraceFrames,
                systemInformation: report.systemInformation
            ))
        }
        return observations
    }

    private static func parseRuntimeExceptions(_ lines: [String]) -> [WineRuntimeCrashObservation] {
        var observations: [WineRuntimeCrashObservation] = []
        for (index, line) in lines.enumerated() {
            guard let parsed = parseUnhandledExceptionLine(line) else { continue }
            let followupEnd = min(lines.endIndex, index + 3)
            let debuggerStartFailed = lines[(index + 1)..<followupEnd].contains {
                $0.contains("start_debugger Couldn't start debugger")
            }
            observations.append(WineRuntimeCrashObservation(
                sourceSequence: index,
                exceptionCode: parsed.code,
                threadIDHex: parsed.threadIDHex,
                instructionAddressHex: parsed.addressHex,
                debuggerStartFailed: debuggerStartFailed,
                debuggerProcessID: nil,
                backtraceFrames: [],
                systemInformation: []
            ))
        }
        return observations
    }

    private static func parseUnhandledExceptionLine(
        _ line: String
    ) -> (code: UInt32, threadIDHex: String, addressHex: String)? {
        guard let codeStart = line.range(of: "wine: Unhandled exception 0x")?.upperBound,
              let threadMarker = line.range(of: " in thread ", range: codeStart..<line.endIndex),
              let addressMarker = line.range(of: " at address ", range: threadMarker.upperBound..<line.endIndex),
              let addressEnd = line.range(of: " (thread ", range: addressMarker.upperBound..<line.endIndex)
                ?? line.range(of: ", starting debugger", range: addressMarker.upperBound..<line.endIndex) else {
            return nil
        }
        let codeText = String(line[codeStart..<threadMarker.lowerBound])
        let threadText = String(line[threadMarker.upperBound..<addressMarker.lowerBound])
        let addressText = String(line[addressMarker.upperBound..<addressEnd.lowerBound])
        guard let code = UInt32(codeText, radix: 16),
              let threadID = UInt64(threadText, radix: 16),
              let address = UInt64(addressText, radix: 16) else {
            return nil
        }
        return (
            code,
            normalizedHex(threadID, minimumDigits: 4),
            normalizedHex(address, minimumDigits: 16)
        )
    }

    private static func parseDebuggerReports(_ lines: [String]) -> [DebuggerReport] {
        var reports: [DebuggerReport] = []
        var current: DebuggerReport?
        var collectingBacktrace = false
        var collectingSystemInformation = false

        func finishCurrent() {
            guard let report = current else { return }
            reports.append(report)
            current = nil
            collectingBacktrace = false
            collectingSystemInformation = false
        }

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let processID = debuggerProcessID(in: line) {
                finishCurrent()
                current = DebuggerReport(
                    sourceSequence: index,
                    processID: processID,
                    exceptionCode: nil,
                    instructionAddressHex: nil,
                    backtraceFrames: [],
                    systemInformation: []
                )
                continue
            }
            guard current != nil else { continue }

            if let exception = debuggerException(in: line) {
                current?.exceptionCode = exception.code
                current?.instructionAddressHex = exception.addressHex
                continue
            }
            if line == "Backtrace:" {
                collectingBacktrace = true
                collectingSystemInformation = false
                continue
            }
            if line == "Modules:" {
                collectingBacktrace = false
                continue
            }
            if line == "System information:" {
                collectingBacktrace = false
                collectingSystemInformation = true
                continue
            }
            if collectingBacktrace,
               current?.backtraceFrames.count ?? 0 < maximumBacktraceFrames,
               isBacktraceFrame(line),
               line.utf8.count <= maximumStoredLineBytes {
                current?.backtraceFrames.append(line)
            } else if collectingSystemInformation,
                      !line.isEmpty,
                      current?.systemInformation.count ?? 0 < maximumSystemInformationLines,
                      line.utf8.count <= maximumStoredLineBytes {
                current?.systemInformation.append(line)
            }
        }
        finishCurrent()
        return reports
    }

    private static func debuggerProcessID(in line: String) -> Int32? {
        let prefix = "WineDbg attached to pid "
        guard line.hasPrefix(prefix) else { return nil }
        let token = line.dropFirst(prefix.count).prefix(while: { $0.isHexDigit })
        guard !token.isEmpty,
              let value = UInt32(token, radix: 16),
              value > 0,
              value <= UInt32(Int32.max) else {
            return nil
        }
        return Int32(value)
    }

    private static func debuggerException(
        in line: String
    ) -> (code: UInt32, addressHex: String?)? {
        let prefix = "Unhandled exception: 0x"
        guard line.hasPrefix(prefix) else { return nil }
        let afterPrefix = line.dropFirst(prefix.count)
        let codeToken = afterPrefix.prefix(while: { $0.isHexDigit })
        guard let code = UInt32(codeToken, radix: 16) else { return nil }
        guard let addressMarker = line.range(of: "(0x", options: .backwards),
              let addressEnd = line.range(of: ").", range: addressMarker.upperBound..<line.endIndex),
              let address = UInt64(line[addressMarker.upperBound..<addressEnd.lowerBound], radix: 16) else {
            return (code, nil)
        }
        return (code, normalizedHex(address, minimumDigits: 16))
    }

    private static func isBacktraceFrame(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 2 else { return false }
        let frameToken = tokens[0].hasPrefix("=>") ? tokens[0].dropFirst(2) : Substring(tokens[0])
        return !frameToken.isEmpty &&
            frameToken.allSatisfy(\.isNumber) &&
            tokens[1].lowercased().hasPrefix("0x")
    }

    private static func normalizedHex(_ value: UInt64, minimumDigits: Int) -> String {
        "0x" + String(format: "%0*llX", minimumDigits, value)
    }
}
