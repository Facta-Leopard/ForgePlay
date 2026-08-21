import Foundation

struct RedactionPreview: Hashable {
    var originalCharacterCount: Int
    var redactedCharacterCount: Int
    var replacementCount: Int
    var sample: String
}

enum DiagnosticPathRedactionPolicy {
    static func sensitivePaths(
        rootURL: URL?,
        selectedSteamReference: SteamGame?,
        runtimeExecutable: URL?
    ) -> [String] {
        var paths: [String] = []
        appendSensitiveURL(rootURL, to: &paths)
        appendSensitiveURL(runtimeExecutable, to: &paths)
        appendSensitiveURL(runtimeExecutable?.deletingLastPathComponent(), to: &paths)
        if let runtimeExecutable,
           rootURL.map({ !isInsideOrEqual(runtimeExecutable, root: $0) }) ?? true {
            // RuntimeManifestResolver derives identity evidence from the
            // launcher's grandparent (share/wine and lib/wine are siblings of
            // bin). Redact the complete path so a nonstandard or legacy record
            // cannot expose an installation location through diagnostics.
            let runtimeRoot = runtimeExecutable.standardizedFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if runtimeRoot.path != "/" {
                appendSensitiveURL(runtimeRoot, to: &paths)
            }
        }
        appendSensitivePath(selectedSteamReference?.libraryPath, to: &paths)
        appendSensitivePath(selectedSteamReference?.manifestPath, to: &paths)
        return paths
    }

    static func sensitiveTerms(selectedSteamReference: SteamGame?) -> [String] {
        [
            selectedSteamReference?.installDir
        ].compactMap(normalizedSensitiveTerm)
    }

    private static func appendSensitiveURL(_ url: URL?, to paths: inout [String]) {
        guard let url else { return }
        appendSensitivePath(url.path, to: &paths)
        appendSensitivePath(url.standardizedFileURL.path, to: &paths)
    }

    private static func appendSensitivePath(_ path: String?, to paths: inout [String]) {
        guard let path else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1, !paths.contains(trimmed) else { return }
        paths.append(trimmed)
    }

    private static func isInsideOrEqual(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalizedSensitiveTerm(_ term: String?) -> String? {
        guard let term else { return nil }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6,
              trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        return trimmed
    }
}

struct Redactor: Sendable {
    private struct CompiledReplacement: @unchecked Sendable {
        let expression: NSRegularExpression
        let value: String

        init(_ pattern: String, _ value: String) throws {
            expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.value = value
        }
    }

    private let additionalSensitivePaths: [String]
    private let additionalSensitiveTerms: [String]
    private let dynamicReplacements: [CompiledReplacement]?

    init(additionalSensitivePaths: [String] = [], additionalSensitiveTerms: [String] = []) {
        let normalizedPaths = Self.normalizedSensitivePaths(additionalSensitivePaths)
        let normalizedTerms = Self.normalizedSensitiveTerms(additionalSensitiveTerms)
        self.additionalSensitivePaths = normalizedPaths
        self.additionalSensitiveTerms = normalizedTerms
        self.dynamicReplacements = Self.makeDynamicReplacements(
            sensitivePaths: normalizedPaths,
            sensitiveTerms: normalizedTerms
        )
    }

    func addingSensitivePaths(_ paths: [String]) -> Redactor {
        Redactor(
            additionalSensitivePaths: additionalSensitivePaths + paths,
            additionalSensitiveTerms: additionalSensitiveTerms
        )
    }

    func addingSensitiveTerms(_ terms: [String]) -> Redactor {
        Redactor(
            additionalSensitivePaths: additionalSensitivePaths,
            additionalSensitiveTerms: additionalSensitiveTerms + terms
        )
    }

    func redact(_ text: String) -> String {
        var output = text
        guard let dynamicReplacements else {
            return "[REDACTION_FAILED]"
        }
        for replacement in dynamicReplacements {
            output = replacement.expression.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: replacement.value
            )
        }

        guard let baseReplacements = Self.baseReplacements else {
            return "[REDACTION_FAILED]"
        }
        for replacement in baseReplacements {
            output = replacement.expression.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: replacement.value
            )
        }
        return output
    }

    private static func makeDynamicReplacements(
        sensitivePaths: [String],
        sensitiveTerms: [String]
    ) -> [CompiledReplacement]? {
        var replacements: [(pattern: String, value: String)] = []

        // Exact user-selected paths must be removed before broad /Users and
        // /Volumes rules rewrite their prefixes and make the exact value
        // impossible to match. Compile this immutable policy once per Redactor
        // instead of once per support-bundle artifact.
        for path in sensitivePaths {
            replacements.append((
                NSRegularExpression.escapedPattern(for: path),
                "[REDACTED_PATH]"
            ))
        }
        for term in sensitiveTerms {
            replacements.append((
                NSRegularExpression.escapedPattern(for: term),
                "[REDACTED_VALUE]"
            ))
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            replacements.append((
                NSRegularExpression.escapedPattern(for: home),
                "[HOME]"
            ))
        }
        let userName = NSUserName()
        if !userName.isEmpty {
            let escapedUserName = NSRegularExpression.escapedPattern(for: userName)
            replacements.append((
                #"(?i)/users/\#(escapedUserName)"#,
                "/Users/[USER]"
            ))
            replacements.append((
                #"(?i)c:\\users\\\#(escapedUserName)"#,
                #"C:\Users\[USER]"#
            ))
            if userName.count >= 3 {
                replacements.append((
                    #"(?<![A-Za-z0-9_.-])\#(escapedUserName)(?![A-Za-z0-9_.-])"#,
                    "[USER]"
                ))
            }
        }

        do {
            return try replacements.map { replacement in
                try CompiledReplacement(
                    replacement.pattern,
                    NSRegularExpression.escapedTemplate(for: replacement.value)
                )
            }
        } catch {
            // Redaction must fail closed. A malformed dynamic policy must never
            // fall back to partially redacted output.
            return nil
        }
    }

    private static let baseReplacements: [CompiledReplacement]? = try? [
        .init(#"\bsk-(?:proj-)?[A-Za-z0-9_-]{10,}\b"#, "[REDACTED_SECRET]"),
        .init(#"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#, "[REDACTED_SECRET]"),
        .init(#"(https?://)[^/?#\s@]+@"#, "$1[REDACTED_USERINFO]@"),
        .init(#"([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|client[_-]?secret|secret|password|session[_-]?id|steamloginsecure)=)[^&#\s]+"#, "$1[REDACTED_SECRET]"),
        .init(#"(set-cookie:\s*[^=;\s]+)=([^;\n]+)"#, "$1=[REDACTED_SECRET]"),
        .init(#"\b(?:cookie|set-cookie)\s*:\s*[^\r\n]+"#, "Cookie: [REDACTED_SECRET]"),
        .init(#"authorization\s*:\s*basic\s+[A-Za-z0-9+/=._\-]+"#, "Authorization: Basic [REDACTED_SECRET]"),
        .init(#"authorization\s*:\s*bearer\s+[A-Za-z0-9._\-]+"#, "Authorization: Bearer [REDACTED_SECRET]"),
        .init(#"\bbearer\s+[A-Za-z0-9._\-]+"#, "Bearer [REDACTED_SECRET]"),
        .init(#"("?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|authorization|bearer|token|client[_-]?secret|secret|password|session[_-]?id|steamloginsecure)"?\s*:\s*)"[^"\r\n]*""#, "$1\"[REDACTED_SECRET]\""),
        .init(#"(?<![?&])\b(api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|authorization|bearer|token|client[_-]?secret|secret|password|session[_-]?id|steamloginsecure)\s*[:=]\s*["']?[^"',\s}]+"#, "$1: [REDACTED_SECRET]"),
        .init(#"("?(?:steamloginsecure|password|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|client[_-]?secret|secret|authorization|session[_-]?id)"?\s+)"[^"\r\n]*""#, "$1\"[REDACTED_SECRET]\""),
        .init(#"("?(?:accountname|personaname|autologinuser|mostrecent)"?\s+)"[^"\r\n]*""#, "$1\"[REDACTED_STEAM_ACCOUNT]\""),
        .init(#"\b(account[_-]?name|persona[_-]?name|auto[_-]?login[_-]?user|steam[_-]?account)\b\s*[:=]\s*["']?[^"',\s}]+"#, "$1: [REDACTED_STEAM_ACCOUNT]"),
        .init(#"\b[A-Z0-9._%+-]{1,64}@[A-Z0-9.-]{1,255}\.[A-Z]{2,63}\b"#, "[REDACTED_EMAIL]"),
        .init(#"7656119[0-9]{10}"#, "[REDACTED_STEAM_ID]"),
        .init(#"\[[UAG]:\d+:\d+\]"#, "[REDACTED_STEAM_ID]"),
        .init(#"file:///[^\s\"'<>]+"#, "file:///[REDACTED_PATH]"),
        .init(#"\bZ:\\[^\s\"'<>]+"#, #"Z:\\[REDACTED_PATH]"#),
        // Wine drive letters above C: commonly map user-selected external
        // libraries. Preserve the executable/module basename for diagnosis,
        // while removing every preceding mapped-drive directory component.
        .init(#"\b([D-Z]):\\(?:[^\\:\r\n\"']+\\)+"#, #"$1:\\[REDACTED_PATH]\\"#),
        .init(#"/Users/[^\s\"'<>]+"#, "/Users/[REDACTED_PATH]"),
        .init(#"/Volumes/[^\s\"'<>]+"#, "/Volumes/[REDACTED_PATH]"),
        .init(#"/Network/[^\s\"'<>]+"#, "/Network/[REDACTED_PATH]"),
        .init(#"/(?:private/)?var/folders/[^\s\"'<>]+"#, "/private/var/folders/[REDACTED_PATH]"),
        .init(#"/(?:private/)?tmp/[^\s\"'<>]+"#, "/private/tmp/[REDACTED_PATH]"),
        .init(#"\bC:\\Users\\[^\s\"'<>]+"#, #"C:\\Users\\[REDACTED_PATH]"#),
        .init(#"\\\\[^\\\s\"'<>]+\\[^\s\"'<>]+"#, #"\\[REDACTED_UNC_PATH]"#),
        .init(#"(steamguard|steam guard).+"#, "[REDACTED_STEAM_GUARD_LINE]")
    ]

    func redact(data: Data) -> Data {
        redactedUTF8Data(data) ?? Data("[REDACTED_NON_UTF8_DATA]".utf8)
    }

    /// Redacts only string values in a JSON document and then serializes the
    /// document again. Applying regular expressions to already-encoded JSON can
    /// remove quotes or separators (for example when a whole Steam Guard line is
    /// hidden), leaving a support artifact that is no longer valid JSON.
    func redactedJSONData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let redactedObject = redactJSONValue(object, key: nil)
        return try JSONSerialization.data(
            withJSONObject: redactedObject,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        )
    }

    func redactedUTF8Data(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Data(redact(text).utf8)
    }

    func preview(for text: String, limit: Int = 1_200) -> RedactionPreview {
        let redacted = redact(text)
        let replacements = redacted.components(separatedBy: "[REDACTED").count - 1 +
            redacted.components(separatedBy: "[HOME]").count - 1 +
            redacted.components(separatedBy: "[USER]").count - 1
        return RedactionPreview(
            originalCharacterCount: text.count,
            redactedCharacterCount: redacted.count,
            replacementCount: max(0, replacements),
            sample: String(redacted.prefix(limit))
        )
    }

    private static func normalizedSensitivePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && $0.count > 1 }
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedSensitiveTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 6 && $0.rangeOfCharacter(from: .alphanumerics) != nil }
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func redactJSONValue(_ value: Any, key: String?) -> Any {
        if let key {
            let normalizedKey = key
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            if Self.sensitiveJSONKeys.contains(normalizedKey) || normalizedKey.contains("steamguard") {
                return "[REDACTED_SECRET]"
            }
            if Self.steamAccountJSONKeys.contains(normalizedKey) {
                return "[REDACTED_STEAM_ACCOUNT]"
            }
            if Self.steamIdentityJSONKeys.contains(normalizedKey) {
                return "[REDACTED_STEAM_ID]"
            }
        }
        switch value {
        case let string as String:
            return redact(string)
        case let array as [Any]:
            return array.map { redactJSONValue($0, key: key) }
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { output, item in
                output[redact(item.key)] = redactJSONValue(item.value, key: item.key)
            }
        case let number as NSNumber where Self.isSteamIdentityNumber(number):
            return "[REDACTED_STEAM_ID]"
        default:
            return value
        }
    }

    private static let sensitiveJSONKeys: Set<String> = [
        "apikey", "accesstoken", "refreshtoken", "authtoken", "authorization",
        "bearer", "token", "clientsecret", "secret", "password", "sessionid",
        "steamloginsecure", "cookie", "setcookie"
    ]

    private static let steamAccountJSONKeys: Set<String> = [
        "accountname", "personaname", "autologinuser", "mostrecent", "steamaccount"
    ]

    private static let steamIdentityJSONKeys: Set<String> = [
        "steamid", "steamid64", "steamcommunityid"
    ]

    private static func isSteamIdentityNumber(_ number: NSNumber) -> Bool {
        let value = number.stringValue
        guard value.count == 17, value.hasPrefix("7656119") else { return false }
        return value.dropFirst(7).allSatisfy(\.isNumber)
    }
}
