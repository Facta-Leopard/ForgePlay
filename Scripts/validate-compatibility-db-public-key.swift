import CryptoKit
import Foundation

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let input = String(data: inputData, encoding: .utf8) else {
    fputs("public key input is not valid UTF-8\n", stderr)
    exit(1)
}

let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
guard let rawRepresentation = Data(base64Encoded: trimmed) else {
    fputs("public key input is not valid base64\n", stderr)
    exit(1)
}

do {
    _ = try P256.Signing.PublicKey(rawRepresentation: rawRepresentation)
} catch {
    fputs("public key input is not a valid P-256 signing public key raw representation\n", stderr)
    exit(1)
}
