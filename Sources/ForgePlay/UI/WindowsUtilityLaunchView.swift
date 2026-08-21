import SwiftData
import SwiftUI

enum WindowsExecutableRendererBackend: String, CaseIterable, Identifiable, Sendable {
    case base
    case d3dMetal
    case dxmt
    case d9vk
    case dxvk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .base: "Wine 기본"
        case .d3dMetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .d9vk: "D9VK"
        case .dxvk: "DXVK"
        }
    }

    var rendererPolicy: SteamRendererPolicyPreference? {
        switch self {
        case .base: nil
        case .d3dMetal: .d3dMetal
        case .dxmt: .dxmt
        case .d9vk: .d9vk
        case .dxvk: .vulkan
        }
    }
}

struct WindowsExecutableRendererCapabilityKey: Equatable, Hashable, Sendable {
    let runtimeExecutable: URL
    let backend: WindowsExecutableRendererBackend
    let environmentRevision: Int
}

struct WindowsExecutableLaunchRequestSnapshot: Equatable {
    let runtimeExecutable: URL
    let executable: URL
    let rendererBackend: WindowsExecutableRendererBackend
    let rendererPolicy: SteamRendererPolicyPreference?
    let rendererCapabilityKey: WindowsExecutableRendererCapabilityKey?
    let environmentRevision: Int

    init(
        runtimeExecutable: URL,
        executable: URL,
        rendererBackend: WindowsExecutableRendererBackend,
        environmentRevision: Int
    ) {
        let runtimeExecutable = runtimeExecutable.standardizedFileURL
        let rendererPolicy = rendererBackend.rendererPolicy
        self.runtimeExecutable = runtimeExecutable
        self.executable = executable.standardizedFileURL
        self.rendererBackend = rendererBackend
        self.rendererPolicy = rendererPolicy
        self.environmentRevision = environmentRevision
        rendererCapabilityKey = rendererPolicy.map { _ in
            WindowsExecutableRendererCapabilityKey(
                runtimeExecutable: runtimeExecutable,
                backend: rendererBackend,
                environmentRevision: environmentRevision
            )
        }
    }
}

/// Keeps the object that owns restored bookmark/security-scope access alive
/// across every suspension in one launch attempt, including throwing and
/// cancellation exits.
@MainActor
func withWindowsExecutableLaunchAccessLifetime<Access, Output>(
    _ access: Access,
    perform operation: () async throws -> Output
) async rethrows -> Output {
    defer { withExtendedLifetime(access) {} }
    return try await operation()
}

enum WindowsExecutableRendererCapabilityState: Equatable {
    case notRequired
    case pending(WindowsExecutableRendererCapabilityKey)
    case satisfied(WindowsExecutableRendererCapabilityKey)
    case unavailable(WindowsExecutableRendererCapabilityKey)

    func launchAvailability(
        for requiredKey: WindowsExecutableRendererCapabilityKey?
    ) -> WindowsExecutableLaunchAvailability? {
        guard let requiredKey else { return nil }
        switch self {
        case .satisfied(let inspectedKey) where inspectedKey == requiredKey:
            return nil
        case .unavailable(let inspectedKey) where inspectedKey == requiredKey:
            return .rendererCapabilityUnavailable
        case .notRequired, .pending, .satisfied, .unavailable:
            return .rendererCapabilityPending
        }
    }

    mutating func recordUnavailable(
        for failedKey: WindowsExecutableRendererCapabilityKey,
        whenCurrentKeyIs currentKey: WindowsExecutableRendererCapabilityKey?
    ) {
        guard currentKey == failedKey else { return }
        self = .unavailable(failedKey)
    }
}

actor WindowsExecutableRendererCapabilityInspector {
    typealias Inspection = @Sendable (
        WindowsExecutableRendererCapabilityKey,
        WindowsRuntimeCapability
    ) -> Bool

    private let inspection: Inspection
    static let shared = WindowsExecutableRendererCapabilityInspector()

    init(
        inspection: @escaping Inspection = { key, capability in
            guard let preference = key.backend.rendererPolicy else { return true }
            return preference.isSatisfied(by: capability)
        }
    ) {
        self.inspection = inspection
    }

    func inspect(
        _ key: WindowsExecutableRendererCapabilityKey,
        capability: WindowsRuntimeCapability
    ) -> Bool {
        inspection(key, capability)
    }
}

@MainActor
final class WindowsExecutableRendererCapabilityInspectionCoordinator {
    private let inspector: WindowsExecutableRendererCapabilityInspector

    init(
        inspector: WindowsExecutableRendererCapabilityInspector =
            .shared
    ) {
        self.inspector = inspector
    }

    func inspect(
        _ key: WindowsExecutableRendererCapabilityKey,
        capability: WindowsRuntimeCapability
    ) async -> Bool {
        await inspector.inspect(key, capability: capability)
    }
}

enum WindowsExecutableLaunchAvailability: Equatable {
    case available
    case launchInProgress
    case executableNotSelected
    case persistedRuntimeNotSelected
    case rendererCapabilityPending
    case rendererCapabilityUnavailable
    case ownershipUnavailable(WindowsExecutableLaunchReservationAvailability)

    var isAvailable: Bool {
        self == .available
    }

    var reasonLocalizationKey: String {
        switch self {
        case .available:
            "선택한 EXE를 실행할 준비가 되었습니다."
        case .launchInProgress:
            "다른 EXE 실행이 끝날 때까지 기다리세요."
        case .executableNotSelected:
            "먼저 실행할 EXE 파일을 선택하세요."
        case .persistedRuntimeNotSelected:
            "설정에서 사용할 ForgePlay Runtime을 먼저 선택하세요."
        case .rendererCapabilityPending:
            "선택한 그래픽 백엔드의 Runtime 지원 여부를 확인하고 있습니다."
        case .rendererCapabilityUnavailable:
            "선택한 그래픽 백엔드를 현재 ForgePlay Runtime에서 사용할 수 없습니다."
        case .ownershipUnavailable(let availability):
            switch availability {
            case .available:
                "선택한 EXE를 실행할 준비가 되었습니다."
            case .blockedByCompatibilitySession:
                "활성 호환성 Steam 세션을 먼저 종료하세요."
            case .blockedByCompatibilityTransition:
                "호환성 Steam 세션 전환이 끝날 때까지 기다리세요."
            case .blockedByStandardSteamLaunch:
                "일반 Steam 실행 준비가 끝날 때까지 기다리세요."
            case .blockedByWindowsExecutableLaunch:
                "다른 EXE 실행이 끝날 때까지 기다리세요."
            case .blockedByPrefixLifecycle:
                "다른 SteamShared 프리픽스 작업이 끝날 때까지 기다리세요."
            }
        }
    }

    static func resolve(
        isLaunching: Bool,
        hasSelectedExecutable: Bool,
        hasPersistedRuntime: Bool,
        rendererAvailability: WindowsExecutableLaunchAvailability?,
        ownershipAvailability: WindowsExecutableLaunchReservationAvailability
    ) -> Self {
        if isLaunching {
            return .launchInProgress
        }
        guard hasSelectedExecutable else {
            return .executableNotSelected
        }
        guard hasPersistedRuntime else {
            return .persistedRuntimeNotSelected
        }
        if let rendererAvailability {
            return rendererAvailability
        }
        guard ownershipAvailability == .available else {
            return .ownershipUnavailable(ownershipAvailability)
        }
        return .available
    }
}

enum WindowsExecutableExternalRootAccessError: Error {
    case accessUnavailable(URL)
}

/// An independent, launch-owned security-scope reference. The view retains a
/// separate selection reference, so disappearing during an unstructured
/// launch cannot revoke the root before grant publication and spawn checks.
final class WindowsExecutableExternalRootAccessLease {
    let root: URL?
    private let stopAccess: (URL) -> Void
    private var didStartAccess = false

    init(
        root: URL?,
        requiresSecurityScope: Bool,
        startAccess: (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccess: @escaping (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) throws {
        self.root = root?.standardizedFileURL
        self.stopAccess = stopAccess
        guard let root = self.root else { return }

        didStartAccess = startAccess(root)
        guard didStartAccess || !requiresSecurityScope else {
            throw WindowsExecutableExternalRootAccessError
                .accessUnavailable(root)
        }
    }

    func release() {
        guard didStartAccess, let root else { return }
        didStartAccess = false
        stopAccess(root)
    }

    deinit {
        release()
    }
}

/// Launches a user-selected Windows maintenance utility in SteamShared without
/// applying any of the game-session compatibility policies.
struct WindowsUtilityLaunchView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedExecutable: URL?
    @State private var authorizedExecutableRoot: URL?
    @State private var didStartAuthorizedRootScope = false
    @State private var isLaunching = false
    @State private var lastLaunchLog: URL?
    @State private var rendererBackend: WindowsExecutableRendererBackend = .base
    @State private var rendererCapabilityState:
        WindowsExecutableRendererCapabilityState = .notRequired
    @State private var dxvkRuntimeAvailability: SteamRendererPolicyAvailability?
    @State private var rendererCapabilityInspectionCoordinator =
        WindowsExecutableRendererCapabilityInspectionCoordinator()

    private var rendererCapabilityKey: WindowsExecutableRendererCapabilityKey? {
        guard rendererBackend.rendererPolicy != nil,
              let runtimeExecutable = appState.runtimeExecutableURL else {
            return nil
        }
        return WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: runtimeExecutable.standardizedFileURL,
            backend: rendererBackend,
            environmentRevision: services.steamEnvironmentRevision
        )
    }

    private var dxvkRuntimeAvailabilityTaskID: String {
        [
            appState.runtimeExecutableURL?.standardizedFileURL.path ??
                "runtime-unavailable",
            String(services.steamEnvironmentRevision)
        ].joined(separator: "#")
    }

    private var launchAvailability: WindowsExecutableLaunchAvailability {
        let ownershipAvailability = services.steamCompatibilitySessionCoordinator
            .windowsExecutableLaunchReservationAvailability(
                prefixLifecycleIsBusy:
                    services.steamPrefixLifecycleCoordinator.isBusy
            )
        return WindowsExecutableLaunchAvailability.resolve(
            isLaunching: isLaunching,
            hasSelectedExecutable: selectedExecutable != nil,
            hasPersistedRuntime: appState.runtimeExecutableURL != nil,
            rendererAvailability: rendererCapabilityState.launchAvailability(
                for: rendererCapabilityKey
            ),
            ownershipAvailability: ownershipAvailability
        )
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(
            mode: appState.themeMode,
            colorScheme: colorScheme
        )

        ForgePageScaffold(
            "EXE 실행 (베타)",
            subtitle: "고전 게임·독립 실행형 프로그램·패처·설정 도구를 현재 SteamShared 프리픽스에서 기본 Runtime으로 실행합니다.",
            systemImage: "terminal.fill"
        ) {
            SectionHelpButton(section: .windowsUtility)
        } content: {
            ForgeCard(
                "고전 게임·독립 실행형 프로그램·Windows 도구",
                systemImage: "hammer.fill",
                emphasis: .accent
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(appState.localized(
                        "선택한 EXE는 Windows용 Steam과 같은 C: 드라이브와 레지스트리를 사용합니다."
                    ))
                    .font(.callout)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(appState.localized(
                        "기본 Runtime이 기본값이며, 필요한 경우 아래에서 이 EXE에만 그래픽 백엔드를 선택할 수 있습니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    if let selectedExecutable {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(appState.localized("선택한 EXE"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.secondaryText)
                            Text(selectedExecutable.lastPathComponent)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(palette.text)
                            AdaptivePathText(
                                path: selectedExecutable.path,
                                color: palette.secondaryText,
                                isTextSelectionEnabled: true
                            )
                        }
                    } else {
                        Text(appState.localized(
                            "실행할 고전 게임·독립 실행형 프로그램·패처·설정 도구의 .exe 파일을 선택하세요."
                        ))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                    }

                    HStack(spacing: 10) {
                        ThemedActionButton(
                            title: "EXE 파일 선택",
                            systemImage: "doc.badge.plus",
                            prominence: .secondary,
                            isDisabled: isLaunching
                        ) {
                            chooseExecutable()
                        }
                        ThemedActionButton(
                            title: isLaunching
                                ? "실행 준비 중…"
                                : "같은 프리픽스에서 실행",
                            systemImage: "play.fill",
                            prominence: .primary,
                            isDisabled: !launchAvailability.isAvailable
                        ) {
                            launchSelectedExecutable()
                        }
                        .help(appState.localized(
                            launchAvailability.reasonLocalizationKey
                        ))
                        .accessibilityHint(appState.localized(
                            launchAvailability.reasonLocalizationKey
                        ))
                    }

                    if !launchAvailability.isAvailable {
                        Text(appState.localized(
                            launchAvailability.reasonLocalizationKey
                        ))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.localized("선택 그래픽 백엔드"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)

                        Picker(
                            appState.localized("선택 그래픽 백엔드"),
                            selection: $rendererBackend
                        ) {
                            ForEach(WindowsExecutableRendererBackend.allCases) {
                                backend in
                                Text(appState.localized(backend.title))
                                    .tag(backend)
                                    .disabled(
                                        backend == .dxvk &&
                                            dxvkRuntimeAvailability?
                                                .isAvailable != true
                                    )
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isLaunching)

                        Text(appState.localized(
                            "Wine 기본은 고전 2D/GDI·소프트웨어 렌더링 또는 WineD3D(OpenGL 변환)를 사용할 수 있으며 항상 CPU 전용인 것은 아닙니다."
                        ))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        if let availability = dxvkRuntimeAvailability,
                           !availability.isAvailable,
                           let messageKey = availability
                            .userMessageLocalizationKey {
                            Label(
                                appState.localized(messageKey),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(appState.localized(
                            "D9VK는 DX9 고전 3D, DXVK는 DX10/11, DXMT는 DX11 대안, D3DMetal은 최신 Direct3D에 적합합니다. 백엔드 지원 여부는 설치되고 인증된 ForgePlay Runtime 페이로드에 따라 달라집니다."
                        ))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        Text(appState.localized(
                            "직접 EXE 실행에는 Game Mode가 없으며 Steam 네트워크·오디오·컨트롤러·게임 호환성 프로필을 적용하지 않습니다."
                        ))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if isLaunching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(appState.localized(
                                "ForgePlay Runtime과 프리픽스를 확인하고 있습니다."
                            ))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                        }
                    }
                }
            }

            ForgeCard(
                "외부 EXE 주의사항",
                systemImage: "exclamationmark.shield.fill"
            ) {
                Text(appState.localized(
                    "ForgePlay는 선택한 EXE의 출처나 동작, 게임 약관·계정 제재 위험을 검증하거나 보증하지 않습니다. 신뢰하는 파일만 실행하고 필요한 게임 파일은 먼저 백업하세요."
                ))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let lastLaunchLog {
                ForgeCard("최근 EXE 실행 기록", systemImage: "doc.text") {
                    VStack(alignment: .leading, spacing: 10) {
                        AdaptivePathText(
                            path: lastLaunchLog.path,
                            color: palette.secondaryText,
                            isTextSelectionEnabled: true
                        )
                        ThemedActionButton(
                            title: "실행 기록 열기",
                            systemImage: "doc.text.magnifyingglass",
                            prominence: .secondary
                        ) {
                            appState.openFileURL(lastLaunchLog)
                        }
                    }
                }
            }
        }
        .onDisappear {
            releaseAuthorizedRootScope()
            selectedExecutable = nil
        }
        .task(id: rendererCapabilityKey) {
            guard let key = rendererCapabilityKey else {
                rendererCapabilityState = .notRequired
                return
            }
            rendererCapabilityState = .pending(key)
            let isSatisfied: Bool
            do {
                let runtimeSnapshot = try await services.windowsRuntimeService
                    .runtimeCapabilitySnapshot(
                        executable: key.runtimeExecutable
                    )
                isSatisfied = await rendererCapabilityInspectionCoordinator
                    .inspect(
                        key,
                        capability: runtimeSnapshot.capability
                    )
            } catch {
                isSatisfied = false
            }
            guard !Task.isCancelled,
                  rendererCapabilityKey == key else {
                return
            }
            rendererCapabilityState = isSatisfied
                ? .satisfied(key)
                : .unavailable(key)
        }
        .task(id: dxvkRuntimeAvailabilityTaskID) {
            guard let executable = appState.runtimeExecutableURL else {
                dxvkRuntimeAvailability = nil
                return
            }
            let availability: SteamRendererPolicyAvailability
            do {
                let snapshot = try await services.windowsRuntimeService
                    .runtimeCapabilitySnapshot(executable: executable)
                availability = SteamRendererPolicyPreference.vulkan
                    .availability(in: snapshot.capability)
            } catch {
                availability = .unavailable(
                    userMessageLocalizationKey:
                        SteamRendererPolicyPreference
                            .dxvkRuntimeUnavailableLocalizationKey,
                    technicalDetail: forgePlayTechnicalErrorSummary(error)
                )
            }
            guard !Task.isCancelled,
                  dxvkRuntimeAvailabilityTaskID == [
                    executable.standardizedFileURL.path,
                    String(services.steamEnvironmentRevision)
                  ].joined(separator: "#") else {
                return
            }
            dxvkRuntimeAvailability = availability
        }
    }

    private func chooseExecutable() {
        guard let executable = OpenPanelPresenter.chooseFile(
            title: appState.localized("고전 게임·프로그램 EXE 선택"),
            message: appState.localized(
                "SteamShared 프리픽스에서 실행할 고전 게임·독립 실행형 프로그램·패처·설정 도구를 선택하세요."
            ),
            prompt: appState.localized("EXE 선택"),
            allowedExtensions: ["exe"]
        ) else {
            return
        }

        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(executable)
            guard executable.pathExtension.lowercased() == "exe" else {
                throw FileSystemItemPolicyError.notRegularNonSymlinkFile(
                    executable
                )
            }
            let prefix = try services.pathManager.url(
                for: .steamSharedPrefix
            )
            if FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: prefix,
                to: executable
            ) {
                replaceSelection(
                    executable: executable,
                    authorizedRoot: nil,
                    didStartScope: false
                )
                return
            }

            guard let root = OpenPanelPresenter.chooseDirectory(
                title: appState.localized("EXE 폴더 접근 허용"),
                message: appState.localized(
                    "선택한 EXE와 같은 폴더의 보조 파일도 읽을 수 있도록 EXE가 들어 있는 폴더 또는 상위 폴더를 선택하세요."
                ),
                prompt: appState.localized("폴더 허용"),
                initialDirectory: executable.deletingLastPathComponent(),
                canCreateDirectories: false
            ) else {
                return
            }
            try FileSystemItemPolicy.requireNonSymlinkDirectory(root)
            guard FileSystemItemPolicy
                .hasOnlyNonSymlinkDirectoryComponents(
                    from: root,
                    to: executable
                ) else {
                appState.setNotice(
                    appState.localized(
                        "선택한 폴더 안에 EXE가 없습니다. EXE가 들어 있는 폴더를 선택하세요."
                    ),
                    kind: .warning
                )
                return
            }
            let didStartScope =
                root.startAccessingSecurityScopedResource()
            guard didStartScope ||
                    !ForgePlaySandboxPolicy.isAppSandboxEnabled else {
                throw WindowsExecutableExternalRootAccessError
                    .accessUnavailable(root)
            }
            replaceSelection(
                executable: executable,
                authorizedRoot: root,
                didStartScope: didStartScope
            )
            lastLaunchLog = nil
        } catch {
            appState.setError(error)
        }
    }

    private func replaceSelection(
        executable: URL,
        authorizedRoot: URL?,
        didStartScope: Bool
    ) {
        releaseAuthorizedRootScope()
        selectedExecutable = executable.standardizedFileURL
        authorizedExecutableRoot = authorizedRoot?.standardizedFileURL
        didStartAuthorizedRootScope = didStartScope
        lastLaunchLog = nil
    }

    private func launchSelectedExecutable() {
        let availability = launchAvailability
        guard availability.isAvailable,
              let runtimeExecutable = appState.runtimeExecutableURL,
              let selectedExecutable else {
            if !availability.isAvailable {
                appState.setNotice(
                    appState.localized(availability.reasonLocalizationKey),
                    kind: .warning
                )
            }
            return
        }
        let launchRequest = WindowsExecutableLaunchRequestSnapshot(
            runtimeExecutable: runtimeExecutable,
            executable: selectedExecutable,
            rendererBackend: rendererBackend,
            environmentRevision: services.steamEnvironmentRevision
        )

        let launchRootAccess: WindowsExecutableExternalRootAccessLease
        do {
            launchRootAccess = try WindowsExecutableExternalRootAccessLease(
                root: authorizedExecutableRoot,
                requiresSecurityScope:
                    ForgePlaySandboxPolicy.isAppSandboxEnabled
            )
        } catch {
            appState.setError(error)
            return
        }

        isLaunching = true
        Task { @MainActor in
            defer {
                launchRootAccess.release()
                isLaunching = false
            }
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                    launchRequest.executable
                )
                let storageAccess =
                    try appState.restorePersistedSteamStorageAccess(
                        in: modelContext
                    )
                var roots = storageAccess.roots
                if let launchRoot = launchRootAccess.root {
                    roots.append(launchRoot)
                }
                roots = deduplicatedRoots(roots)

                let result = try await
                    withWindowsExecutableLaunchAccessLifetime(storageAccess) {
                        try await services.windowsExecutableLaunchService.launch(
                            runtimeExecutable: launchRequest.runtimeExecutable,
                            executable: launchRequest.executable,
                            rendererPolicy: launchRequest.rendererPolicy,
                            externalStorageRoots: roots
                        )
                    }
                lastLaunchLog = result.stderrLog
                if result.succeeded {
                    appState.setNotice(
                        appState.localizedFormat(
                            "%@을(를) SteamShared 프리픽스에서 실행했습니다.",
                            launchRequest.executable.lastPathComponent
                        ),
                        kind: .success
                    )
                } else {
                    appState.setNotice(
                        appState.localizedFormat(
                            "%@ 실행이 바로 종료되었습니다. 실행 기록을 확인하세요.",
                            launchRequest.executable.lastPathComponent
                        ),
                        kind: .warning
                    )
                }
            } catch {
                if let launchError = error as? WindowsExecutableLaunchServiceError,
                   case .rendererCapabilityUnavailable = launchError,
                   let capabilityKey = launchRequest.rendererCapabilityKey {
                    rendererCapabilityState.recordUnavailable(
                        for: capabilityKey,
                        whenCurrentKeyIs: rendererCapabilityKey
                    )
                }
                if let evidence = diagnosticProcessRunResult(from: error) {
                    lastLaunchLog = evidence.stderrLog
                }
                appState.setError(error)
            }
        }
    }

    private func deduplicatedRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let normalized = root.standardizedFileURL
            return seen.insert(normalized.path).inserted
                ? normalized
                : nil
        }
    }

    private func releaseAuthorizedRootScope() {
        if didStartAuthorizedRootScope,
           let authorizedExecutableRoot {
            authorizedExecutableRoot.stopAccessingSecurityScopedResource()
        }
        didStartAuthorizedRootScope = false
        authorizedExecutableRoot = nil
    }
}
