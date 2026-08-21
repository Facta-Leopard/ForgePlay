import Darwin
import Foundation

final class ForgePlayAWDLControlXPCService:
    NSObject,
    ForgePlayAWDLControlXPCProtocol {
    private let controller: AWDLPrivilegedOperationController

    init(controller: AWDLPrivilegedOperationController) {
        self.controller = controller
    }

    func readInterfaceState(
        withReply reply: @escaping (Int, Int, String?) -> Void
    ) {
        send(controller.readInterfaceState(), to: reply)
    }

    func setInterfaceEnabled(
        _ enabled: Bool,
        withReply reply: @escaping (Int, Int, String?) -> Void
    ) {
        send(controller.setInterfaceEnabled(enabled), to: reply)
    }

    private func send(
        _ response: AWDLControlXPCResponse,
        to reply: (Int, Int, String?) -> Void
    ) {
        reply(
            response.state.rawValue,
            response.errorCode.rawValue,
            response.technicalDetail
        )
    }
}

final class ForgePlayNetworkControlListenerDelegate:
    NSObject,
    NSXPCListenerDelegate {
    private let service: ForgePlayAWDLControlXPCService

    init(service: ForgePlayAWDLControlXPCService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: ForgePlayAWDLControlXPCProtocol.self
        )
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

private func runForgePlayNetworkControlHelper() throws -> Never {
    guard geteuid() == 0 else {
        throw AWDLPrivilegedOperationError.commandFailed(
            status: EPERM,
            detail: "network-control helper requires root launchd context"
        )
    }

    let helperIdentity = try ForgePlayNetworkControlIdentity.current()
    let applicationIdentity = try ForgePlayNetworkControlIdentity
        .mainApplicationIdentity(fromHelper: helperIdentity)
    let serviceName = ForgePlayNetworkControlIdentity.machServiceName(
        forMainApplication: applicationIdentity
    )
    let clientRequirement = try ForgePlayNetworkControlIdentity
        .codeSigningRequirement(
            identifier: applicationIdentity.identifier,
            teamIdentifier: applicationIdentity.teamIdentifier
        )

    let listener = NSXPCListener(machServiceName: serviceName)
    listener.setConnectionCodeSigningRequirement(clientRequirement)
    let service = ForgePlayAWDLControlXPCService(
        controller: AWDLPrivilegedOperationController()
    )
    let delegate = ForgePlayNetworkControlListenerDelegate(service: service)
    listener.delegate = delegate
    listener.activate()
    dispatchMain()
}

do {
    try runForgePlayNetworkControlHelper()
} catch {
    FileHandle.standardError.write(
        Data("ForgePlay network-control helper failed: \(error)\n".utf8)
    )
    exit(EXIT_FAILURE)
}
