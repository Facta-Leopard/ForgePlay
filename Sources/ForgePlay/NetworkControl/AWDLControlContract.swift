import Foundation
import Security

@objc(ForgePlayAWDLControlXPCProtocol)
protocol ForgePlayAWDLControlXPCProtocol {
    func readInterfaceState(
        withReply reply: @escaping (Int, Int, String?) -> Void
    )

    func setInterfaceEnabled(
        _ enabled: Bool,
        withReply reply: @escaping (Int, Int, String?) -> Void
    )
}

enum AWDLInterfaceState: Int, Hashable, Sendable {
    case unavailable = 0
    case enabled = 1
    case disabled = 2
}

enum AWDLControlXPCErrorCode: Int, Hashable, Sendable {
    case none = 0
    case commandLaunchFailed = 1
    case commandTimedOut = 2
    case commandFailed = 3
    case invalidReadback = 4
    case readbackMismatch = 5
    case internalFailure = 6
}

struct AWDLControlXPCResponse: Hashable, Sendable {
    let state: AWDLInterfaceState
    let errorCode: AWDLControlXPCErrorCode
    let technicalDetail: String?

    var succeeded: Bool { errorCode == .none }
}

struct ForgePlayCodeSigningIdentity: Hashable, Sendable {
    let identifier: String
    let teamIdentifier: String
}

enum ForgePlayNetworkControlIdentityError: Error, Equatable, Sendable {
    case currentCodeUnavailable(Int32)
    case currentStaticCodeUnavailable(Int32)
    case signingInformationUnavailable(Int32)
    case missingIdentifier
    case missingTeamIdentifier
    case invalidIdentifier
    case invalidTeamIdentifier
    case unexpectedHelperIdentifier
}

enum ForgePlayNetworkControlIdentity {
    static let daemonManifestName = "ForgePlayNetworkControl.plist"
    static let helperIdentifierSuffix = ".network-control-helper"
    static let machServiceSuffix = ".network-control"

    static func current() throws -> ForgePlayCodeSigningIdentity {
        var currentCode: SecCode?
        let copySelfStatus = SecCodeCopySelf([], &currentCode)
        guard copySelfStatus == errSecSuccess, let currentCode else {
            throw ForgePlayNetworkControlIdentityError.currentCodeUnavailable(
                copySelfStatus
            )
        }

        var currentStaticCode: SecStaticCode?
        let copyStaticStatus = SecCodeCopyStaticCode(
            currentCode,
            [],
            &currentStaticCode
        )
        guard copyStaticStatus == errSecSuccess, let currentStaticCode else {
            throw ForgePlayNetworkControlIdentityError
                .currentStaticCodeUnavailable(copyStaticStatus)
        }

        var signingInformation: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(
            currentStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard signingStatus == errSecSuccess,
              let information = signingInformation as? [CFString: Any] else {
            throw ForgePlayNetworkControlIdentityError
                .signingInformationUnavailable(signingStatus)
        }
        guard let identifier = information[kSecCodeInfoIdentifier] as? String,
              !identifier.isEmpty else {
            throw ForgePlayNetworkControlIdentityError.missingIdentifier
        }
        guard let teamIdentifier =
                information[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty else {
            throw ForgePlayNetworkControlIdentityError.missingTeamIdentifier
        }
        return try validatedIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }

    static func validatedIdentity(
        identifier: String,
        teamIdentifier: String
    ) throws -> ForgePlayCodeSigningIdentity {
        guard identifier.unicodeScalars.allSatisfy({ scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
                .contains(scalar)
        }) else {
            throw ForgePlayNetworkControlIdentityError.invalidIdentifier
        }
        guard teamIdentifier.unicodeScalars.allSatisfy({ scalar in
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                .contains(scalar)
        }) else {
            throw ForgePlayNetworkControlIdentityError.invalidTeamIdentifier
        }
        return ForgePlayCodeSigningIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }

    static func machServiceName(
        forMainApplication identity: ForgePlayCodeSigningIdentity
    ) -> String {
        "\(identity.teamIdentifier).\(identity.identifier)\(machServiceSuffix)"
    }

    static func helperIdentifier(
        forMainApplication identity: ForgePlayCodeSigningIdentity
    ) -> String {
        identity.identifier + helperIdentifierSuffix
    }

    static func mainApplicationIdentity(
        fromHelper identity: ForgePlayCodeSigningIdentity
    ) throws -> ForgePlayCodeSigningIdentity {
        guard identity.identifier.hasSuffix(helperIdentifierSuffix) else {
            throw ForgePlayNetworkControlIdentityError.unexpectedHelperIdentifier
        }
        let applicationIdentifier = String(
            identity.identifier.dropLast(helperIdentifierSuffix.count)
        )
        return try validatedIdentity(
            identifier: applicationIdentifier,
            teamIdentifier: identity.teamIdentifier
        )
    }

    static func codeSigningRequirement(
        identifier: String,
        teamIdentifier: String
    ) throws -> String {
        _ = try validatedIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
        return "anchor apple generic and identifier \"\(identifier)\" " +
            "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
