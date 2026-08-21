import CryptoKit
import Foundation

struct ArgumentParser {
    private var values: [String: String] = [:]
    private var flags = Set<String>()

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--force" {
                flags.insert(argument)
                index += 1
                continue
            }
            guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                fail("invalid argument: \(argument)")
            }
            values[argument] = arguments[index + 1]
            index += 2
        }
    }

    func value(_ key: String) -> String {
        guard let value = values[key], !value.isEmpty else {
            fail("missing required argument: \(key)")
        }
        return value
    }

    func hasFlag(_ key: String) -> Bool {
        flags.contains(key)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func outputURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

func resourceValuesIfPresent(_ url: URL, keys: Set<URLResourceKey>, label: String) -> URLResourceValues? {
    do {
        return try url.resourceValues(forKeys: keys)
    } catch {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
            return nil
        }
        fail("could not inspect \(label): \(url.path). \(error.localizedDescription)")
    }
}

func requireSafeDirectoryAncestorChain(for directory: URL, label: String) {
    var current = directory.standardizedFileURL
    while current.path != "/" {
        if let values = resourceValuesIfPresent(
            current,
            keys: [.isDirectoryKey, .isSymbolicLinkKey],
            label: "\(label) parent path"
        ) {
            let permittedSystemAlias = current.path == "/tmp" || current.path == "/var"
            guard values.isSymbolicLink != true || permittedSystemAlias else {
                fail("\(label) parent path must contain only non-symlink directories: \(current.path)")
            }
            guard values.isSymbolicLink == true || values.isDirectory == true else {
                fail("\(label) parent path must contain only non-symlink directories: \(current.path)")
            }
        }
        let parent = current.deletingLastPathComponent()
        guard parent.path != current.path else {
            break
        }
        current = parent
    }
}

func prepareOutputFile(_ url: URL, label: String, force: Bool) throws {
    let parent = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    requireSafeDirectoryAncestorChain(for: parent, label: label)
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

    guard let values = resourceValuesIfPresent(
        url,
        keys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey],
        label: label
    ) else {
        return
    }
    guard values.isRegularFile == true,
          values.isSymbolicLink != true else {
        fail("\(label) must be a non-symlink regular file: \(url.path)")
    }
    guard values.linkCount == 1 else {
        fail("\(label) must not be hardlinked: \(url.path)")
    }
    guard force else {
        fail("refusing to overwrite existing key file: \(url.path)")
    }
}

func writeKey(_ text: String, to url: URL, mode: Int, force: Bool) throws {
    let fileManager = FileManager.default
    try prepareOutputFile(url, label: "key output", force: force)
    try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
}

let arguments = ArgumentParser(Array(CommandLine.arguments.dropFirst()))
let privateKeyURL = outputURL(arguments.value("--private-key-output"))
let publicKeyURL = outputURL(arguments.value("--public-key-output"))
let force = arguments.hasFlag("--force")

guard privateKeyURL.path != publicKeyURL.path else {
    fail("private and public key output paths must be different")
}

let privateKey = P256.Signing.PrivateKey()
let privateKeyBase64 = privateKey.rawRepresentation.base64EncodedString()
let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

do {
    try writeKey(privateKeyBase64, to: privateKeyURL, mode: 0o600, force: force)
    try writeKey(publicKeyBase64, to: publicKeyURL, mode: 0o644, force: force)
    print("privateKey: \(privateKeyURL.path)")
    print("publicKey: \(publicKeyURL.path)")
} catch {
    fail("could not write signing key files: \(error.localizedDescription)")
}
