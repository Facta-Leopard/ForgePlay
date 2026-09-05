import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum CompatibilityStatusKind: Equatable {
    case progress
    case success
    case warning
    case failure
}

private struct CompatibilityStatusPresentation: Equatable {
    let kind: CompatibilityStatusKind
    let message: String
    let logURL: URL?

    init(
        _ kind: CompatibilityStatusKind,
        message: String,
        logURL: URL? = nil
    ) {
        self.kind = kind
        self.message = message
        self.logURL = logURL
    }
}

enum CompatibilityProfileDraftInteractionPolicy {
    static func recommendationsRestoreIsDisabled(
        isPersistenceBlocked: Bool,
        isPreparingSession: Bool,
        hasActiveSession: Bool,
        isSteamLaunchInProgress: Bool,
        isStandardSteamLaunchReserved: Bool
    ) -> Bool {
        _ = isPersistenceBlocked
        return isPreparingSession || hasActiveSession || isSteamLaunchInProgress ||
            isStandardSteamLaunchReserved
    }
}

enum CompatibilitySteamLaunchOptionLabelPolicy {
    static func rendererLabelKey(
        _ value: SteamGraphicsBackendIdentifier
    ) -> String {
        switch value {
        case .d3dMetal: SteamRendererPolicySelection.d3dMetal.labelKey
        case .d3dMetalNVIDIA: SteamRendererPolicySelection.d3dMetalNVIDIA.labelKey
        case .dxmt: SteamRendererPolicySelection.dxmt.labelKey
        case .d9vk: SteamRendererPolicySelection.d9vk.labelKey
        case .dxvk: SteamRendererPolicySelection.vulkan.labelKey
        default: "지원되지 않는 이전 저장 값"
        }
    }
}

struct CompatibilityManifestMountCandidate: Hashable, Sendable {
    let id: String
    let path: String
    let bookmark: Data

    init(id: String, path: String, bookmark: Data) {
        self.id = id
        self.path = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path
        self.bookmark = bookmark
    }
}

enum CompatibilityManifestMountSelectionPolicy {
    static func matchingCandidates(
        libraryPath: String,
        candidates: [CompatibilityManifestMountCandidate]
    ) -> [CompatibilityManifestMountCandidate] {
        let libraryURL = URL(fileURLWithPath: libraryPath, isDirectory: true)
            .standardizedFileURL
        return candidates.filter {
            !$0.bookmark.isEmpty && contains(libraryURL, in: URL(
                fileURLWithPath: $0.path,
                isDirectory: true
            ))
        }
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

enum CompatibilityManifestRootReadinessState: Equatable {
    case missing
    case validating
    case ready
    case failed(reason: String)
}

struct CompatibilityManifestRootPreparationService: Sendable {
    typealias SelectionValidator = @Sendable (URL, Bool) async throws ->
        SteamStorageValidatedSelection
    typealias BookmarkResolver = @Sendable (Data) throws ->
        SecurityScopedBookmarkResolvedURL
    typealias SecurityScopeStarter = @Sendable (URL) -> Bool
    typealias SecurityScopeStopper = @Sendable (URL) -> Void

    private let authorizationProvider:
        any CompatibilityManifestRootAuthorizationProviderV1
    private let selectionValidator: SelectionValidator
    private let bookmarkResolver: BookmarkResolver
    private let securityScopeStarter: SecurityScopeStarter
    private let securityScopeStopper: SecurityScopeStopper

    init(
        authorizationProvider:
            any CompatibilityManifestRootAuthorizationProviderV1,
        selectionValidator: @escaping SelectionValidator = { url, requiresScope in
            try await SteamStorageHealthService().validateSelection(
                url,
                requiresSecurityScope: requiresScope
            )
        },
        bookmarkResolver: @escaping BookmarkResolver = {
            try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0)
        },
        securityScopeStarter: @escaping SecurityScopeStarter = {
            $0.startAccessingSecurityScopedResource()
        },
        securityScopeStopper: @escaping SecurityScopeStopper = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.authorizationProvider = authorizationProvider
        self.selectionValidator = selectionValidator
        self.bookmarkResolver = bookmarkResolver
        self.securityScopeStarter = securityScopeStarter
        self.securityScopeStopper = securityScopeStopper
    }

    func prepareSelectedRoot(
        _ selectedRoot: URL,
        requiresSecurityScope: Bool
    ) async throws -> CompatibilityUnresolvedManifestRootBookmarkV1 {
        let expectedRoot = selectedRoot.standardizedFileURL
        let validated = try await selectionValidator(
            expectedRoot,
            requiresSecurityScope
        )
        guard validated.root.standardizedFileURL.path == expectedRoot.path else {
            throw CompatibilityManifestRootAuthorizationErrorV1.providerOutputMismatch
        }
        return try await authorize(validated.bookmark)
    }

    func prepareLibraryRoot(
        libraryPath: String,
        mount: CompatibilityManifestMountCandidate
    ) async throws -> CompatibilityUnresolvedManifestRootBookmarkV1 {
        let expectedMount = URL(fileURLWithPath: mount.path, isDirectory: true)
            .standardizedFileURL
        let libraryRoot = URL(fileURLWithPath: libraryPath, isDirectory: true)
            .standardizedFileURL
        guard CompatibilityManifestMountSelectionPolicy.contains(
            libraryRoot,
            in: expectedMount
        ) else {
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "library-outside-mount"
            )
        }

        let resolved = try bookmarkResolver(mount.bookmark)
        guard !resolved.isStale else {
            throw CompatibilityManifestRootAuthorizationErrorV1.staleBookmark
        }
        let authorizationRoot = resolved.url.standardizedFileURL
        guard authorizationRoot.path == expectedMount.path else {
            throw CompatibilityManifestRootAuthorizationErrorV1.providerOutputMismatch
        }
        guard securityScopeStarter(authorizationRoot) else {
            throw CompatibilityManifestRootAuthorizationErrorV1.securityScopeDenied
        }
        defer { securityScopeStopper(authorizationRoot) }

        let validated = try await selectionValidator(libraryRoot, false)
        guard validated.root.standardizedFileURL.path == libraryRoot.path else {
            throw CompatibilityManifestRootAuthorizationErrorV1.providerOutputMismatch
        }
        return try await authorize(validated.bookmark)
    }

    private func authorize(
        _ bookmark: Data
    ) async throws -> CompatibilityUnresolvedManifestRootBookmarkV1 {
        let unresolved = try CompatibilityUnresolvedManifestRootBookmarkV1(
            securityScopedBookmark: bookmark
        )
        _ = try await authorizationProvider.resolveAndPinManifestRoot(
            bookmark: unresolved
        )
        return unresolved
    }
}

struct SteamCompatibilityLaunchView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SteamGameRecord.name) private var steamGames: [SteamGameRecord]
    @Query(sort: \SteamStorageMountRecord.path) private var steamStorageMounts:
        [SteamStorageMountRecord]

    @State private var selectedRecipeID =
        SteamCompatibilityLaunchProfileCatalogV1.helldivers2.identity.deterministicRecordID
    @State private var draftSelections =
        SteamCompatibilityLaunchProfileCatalogV1.helldivers2.initialSelections
    @State private var fieldProvenance: [
        CompatibilitySteamLaunchOptionKindV1: CompatibilityResolvedValueProvenanceV1
    ] = Dictionary(
        uniqueKeysWithValues: SteamCompatibilityLaunchProfileCatalogV1.helldivers2
            .orderedOptionDescriptors.map {
            ($0.kind, .recipe)
        }
    )
    @State private var savedEnvelope: CompatibilitySteamLaunchPreferenceEnvelopeV1?
    @State private var unresolvedManifestRootBookmark:
        CompatibilityUnresolvedManifestRootBookmarkV1?
    @State private var manifestRootDisplayName: String?
    @State private var manifestRootWasAutoSelected = false
    @State private var manifestRootReadiness: CompatibilityManifestRootReadinessState =
        .missing
    @State private var runtimeExecutableBookmark: Data?
    @State private var runtimeExecutableDisplayName: String?
    @State private var isChoosingManifestRoot = false
    @State private var isAdvancedExpanded = false
    @State private var didLoadSelectedRecipe = false
    @State private var isPersistenceBlocked = false
    @State private var blockedPersistenceRecoveryVersion:
        CompatibilitySteamLaunchPreferenceRecoveryVersionV1?
    @State private var isShowingCompatibilityPreferenceResetConfirmation = false
    @State private var mustReloadAfterConflict = false
    @State private var compatibilityDraftSaveFailed = false
    @State private var compatibilityStatus: CompatibilityStatusPresentation?
    @State private var approvedManifestAutoSelectionFailure: String?
    @State private var managedRuntimeAuthorizationFailure: String?
    @State private var rendererAvailabilityByBackend:
        [SteamGraphicsBackendIdentifier: SteamRendererPolicyAvailability] = [:]

    private let manifestRootAuthorizationProvider:
        any CompatibilityManifestRootAuthorizationProviderV1
    private let runtimeProviderFactory:
        @MainActor (SteamManagerCompatibilityLaunchContextV1) ->
            any CompatibilityLaunchRuntimeProviderV1

    init(
        manifestRootAuthorizationProvider:
            any CompatibilityManifestRootAuthorizationProviderV1 =
                SecurityScopedCompatibilityManifestRootAuthorizationProviderV1(),
        runtimeProviderFactory:
            @escaping @MainActor (SteamManagerCompatibilityLaunchContextV1) ->
                any CompatibilityLaunchRuntimeProviderV1
    ) {
        self.manifestRootAuthorizationProvider = manifestRootAuthorizationProvider
        self.runtimeProviderFactory = runtimeProviderFactory
    }

    private var selectedRecipe: SteamCompatibilityLaunchProfileRecipeV1 {
        SteamCompatibilityLaunchProfileCatalogV1.recipes.first {
            $0.identity.deterministicRecordID == selectedRecipeID
        } ?? SteamCompatibilityLaunchProfileCatalogV1.helldivers2
    }

    private var approvedLaunchInputsTaskID: String {
        let exactRecords = steamGames
            .filter { $0.steamAppId == selectedRecipe.identity.steamAppID }
            .map { record in
                [
                    record.steamAppId,
                    record.name,
                    record.libraryPath
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: ";")
        let mountRecords = steamStorageMounts.map { mount in
            [
                mount.id,
                mount.path,
                String(mount.bookmark?.hashValue ?? 0),
                String(mount.updatedAt.timeIntervalSinceReferenceDate)
            ].joined(separator: "|")
        }
        .sorted()
        .joined(separator: ";")
        return [
            String(didLoadSelectedRecipe),
            selectedRecipe.identity.deterministicRecordID,
            exactRecords,
            mountRecords,
            appState.runtimeExecutableURL?.path ?? "managed-runtime-unavailable"
        ].joined(separator: "#")
    }

    private var rendererAvailabilityTaskID: String {
        [
            appState.runtimeExecutableURL?.standardizedFileURL.path ??
                "managed-runtime-unavailable",
            String(services.steamEnvironmentRevision)
        ].joined(separator: "#")
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(
            mode: appState.themeMode,
            colorScheme: colorScheme
        )

        ForgePageScaffold(
            "Steam 호환성 실행 (베타)",
            subtitle: "게임별 호환성 프로필을 저장하고 별도의 Steam 실행 경로에 적용합니다.",
            systemImage: "gamecontroller.fill"
        ) {
            SectionHelpButton(section: .steamCompatibilityLaunch)
        } content: {
            actionCard(palette: palette)
            profileAndManifestSelectionCard(palette: palette)
            profileOptionsCard(palette: palette)
            ControllerCompatibilityPreflightPanel()
            resolvedOptionsCard(palette: palette)
        }
        .task {
            await Task.yield()
            refreshGameInputProtectionAuthorizationIfNeeded()
            guard !didLoadSelectedRecipe else { return }
            didLoadSelectedRecipe = true
            guard !restoreActiveSessionPresentationIfAvailable() else { return }
            loadSelectedRecipeDraft()
        }
        .task(id: approvedLaunchInputsTaskID) {
            await Task.yield()
            guard didLoadSelectedRecipe else { return }
            await prepareApprovedLaunchInputsIfAvailable()
        }
        .task(id: rendererAvailabilityTaskID) {
            await refreshRendererAvailability(
                taskID: rendererAvailabilityTaskID
            )
        }
        .onChange(of: selectedRecipeID) { _, _ in
            guard !restoreActiveSessionPresentationIfAvailable() else { return }
            unresolvedManifestRootBookmark = nil
            manifestRootDisplayName = nil
            manifestRootWasAutoSelected = false
            manifestRootReadiness = .missing
            approvedManifestAutoSelectionFailure = nil
            sessionCoordinator.clearCompletedSession()
            loadSelectedRecipeDraft()
        }
        .fileImporter(
            isPresented: $isChoosingManifestRoot,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleManifestRootSelection
        )
        .confirmationDialog(
            appState.localized("손상된 저장 값 초기화"),
            isPresented:
                $isShowingCompatibilityPreferenceResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("초기화"), role: .destructive) {
                resetBlockedCompatibilityPreference()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(
                appState.localized(
                    "이 작업은 선택한 게임 프로필의 손상된 호환성 저장 값만 삭제합니다. Steam 라이브러리와 프리픽스는 변경하지 않습니다."
                )
            )
        }
    }

    private func profileAndManifestSelectionCard(
        palette: ForgePlayPalette
    ) -> some View {
        ForgeCard("호환성 프로필", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(appState.localized("게임 프로필"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Spacer(minLength: 8)
                    Picker(
                        appState.localized("게임 프로필"),
                        selection: $selectedRecipeID
                    ) {
                        ForEach(
                            SteamCompatibilityLaunchProfileCatalogV1.recipes,
                            id: \.identity.deterministicRecordID
                        ) { recipe in
                            Text("\(recipe.displayName) · App ID \(recipe.identity.steamAppID)")
                                .tag(recipe.identity.deterministicRecordID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(isPreparingSession || hasActiveSession)
                }

                Text(
                    appState.localizedFormat(
                        "프로필 %@ · 레시피 %@",
                        selectedRecipe.identity.profileID,
                        selectedRecipe.identity.recipeRevision
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.localized("Steam 매니페스트 루트"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                        Text(
                            manifestRootReadiness == .validating
                                ? appState.localized("확인 중")
                                : manifestRootDisplayName.map {
                                appState.localizedFormat(
                                    manifestRootWasAutoSelected
                                        ? "자동 선택됨: %@"
                                        : "선택됨: %@",
                                    $0
                                )
                            } ?? appState.localized(
                                "이 프로필이 적용될 설치의 매니페스트 루트 폴더를 선택하세요."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ThemedActionButton(
                        title: unresolvedManifestRootBookmark == nil ? "루트 선택" : "루트 다시 선택",
                        systemImage: "folder.badge.plus",
                        prominence: .secondary,
                        isDisabled: isPreparingSession || hasActiveSession ||
                            manifestRootReadiness == .validating,
                        controlSize: .small
                    ) {
                        isChoosingManifestRoot = true
                    }
                    .frame(minWidth: 130, idealWidth: 160, maxWidth: 190)
                }

                Text(
                    appState.localized(
                        "선택 시에는 해결되지 않은 보안 범위 북마크만 보관합니다. 세션 준비 직전에 별도 권한 제공자가 북마크를 다시 확인하고 실제 폴더 객체 식별자를 고정해야 하며, 이 결과는 환경설정 payload에 저장되지 않습니다."
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.localized("ForgePlay 관리 Runtime"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                        Text(
                            runtimeExecutableDisplayName.map {
                                appState.localizedFormat("자동 선택됨: %@", $0)
                            } ?? appState.localized(
                                "앱에 포함되어 검증된 ForgePlay Runtime 권한을 준비해야 합니다."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    }
                    Spacer(minLength: 8)
                    ThemedActionButton(
                        title: "관리 Runtime 다시 확인",
                        systemImage: "terminal",
                        prominence: .secondary,
                        isDisabled: isPreparingSession || hasActiveSession,
                        controlSize: .small
                    ) {
                        prepareManagedRuntimeAuthorization()
                    }
                    .frame(minWidth: 130, idealWidth: 160, maxWidth: 190)
                }
            }
        }
    }

    private func profileOptionsCard(palette: ForgePlayPalette) -> some View {
        let alwaysVisibleKinds: Set<CompatibilitySteamLaunchOptionKindV1> = [
            .graphicsBackend,
            .frameGeneration,
            .gameMode,
            .heapZeroMemory,
            .networkPolicy,
            .audioInputPolicy,
            .videoMemoryPolicy
        ]
        let alwaysVisible = selectedRecipe.orderedOptionDescriptors.filter {
            alwaysVisibleKinds.contains($0.kind)
        }
        let remainingPrimary = selectedRecipe.orderedOptionDescriptors.filter {
            $0.placement == .primary &&
                !alwaysVisibleKinds.contains($0.kind) &&
                $0.kind != .keyboardMapping
        }
        let advanced = selectedRecipe.orderedOptionDescriptors.filter {
            $0.placement == .advanced &&
                !alwaysVisibleKinds.contains($0.kind) &&
                $0.kind != .keyboardMapping
        }
        let hasKeyboardMapping = selectedRecipe.orderedOptionDescriptors.contains {
            $0.kind == .keyboardMapping
        }
        let readOnlySummary = selectedRecipe.orderedOptionDescriptors.filter {
            $0.placement == .readOnlySummary &&
                !alwaysVisibleKinds.contains($0.kind) &&
                $0.kind != .keyboardMapping
        }

        return ForgeCard("프로필 옵션", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(alwaysVisible, id: \.kind) { descriptor in
                    optionControl(for: descriptor, palette: palette)
                }

                ForEach(remainingPrimary, id: \.kind) { descriptor in
                    optionControl(for: descriptor, palette: palette)
                }

                if hasKeyboardMapping {
                    keyboardMappingControl(palette: palette)
                }

                if !advanced.isEmpty {
                    DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(advanced, id: \.kind) { descriptor in
                                optionControl(for: descriptor, palette: palette)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appState.localized("고급 설정"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.text)
                            if !isAdvancedExpanded {
                                Text(collapsedAdvancedSummary(advanced))
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .tint(palette.primary)
                }

                if !readOnlySummary.isEmpty {
                    Divider()
                    Text(appState.localized("프로필 읽기 전용 값"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    ForEach(readOnlySummary, id: \.kind) { descriptor in
                        readOnlyDeclaredOptionRow(descriptor.kind, palette: palette)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func optionControl(
        for descriptor: CompatibilitySteamLaunchOptionDescriptorV1,
        palette: ForgePlayPalette
    ) -> some View {
        if descriptor.placement == .readOnlySummary {
            readOnlyDeclaredOptionRow(descriptor.kind, palette: palette)
        } else {
            selectableOrAutomaticOptionControl(
                for: descriptor.kind,
                palette: palette
            )
        }
    }

    @ViewBuilder
    private func selectableOrAutomaticOptionControl(
        for kind: CompatibilitySteamLaunchOptionKindV1,
        palette: ForgePlayPalette
    ) -> some View {
        if hasExactlyOneSupportedValue(kind), isSupportedBySelectedRecipe(kind) {
            singleSupportedOptionRow(kind, palette: palette)
        } else {
            switch kind {
            case .frameGeneration:
                compatibilityFrameGenerationControl(palette: palette)
            case .gameMode:
                toggleOption(
                    title: "Game Mode",
                    detail: "프로필의 초기 권장값은 켬입니다. 같은 프로필에 저장한 명시적 끔 값은 그대로 복원됩니다.",
                    kind: .gameMode,
                    value: binding(\.gameModeEnabled, kind: .gameMode),
                    palette: palette
                )
            case .heapZeroMemory:
                toggleOption(
                    title: "Heap zero memory",
                    detail: "이 게임 프로필의 메모리 호환성 선택이며 다른 Steam 실행 구성과 독립적으로 저장됩니다.",
                    kind: .heapZeroMemory,
                    value: binding(\.heapZeroMemoryEnabled, kind: .heapZeroMemory),
                    palette: palette
                )
            case .automaticProcessPolicies:
                automaticPolicyExplanation(palette: palette)
            case .graphicsBackend:
                identifierPicker(
                    title: "렌더러",
                    kind: .graphicsBackend,
                    selection: graphicsBackendBinding,
                    values: selectedRecipe.supportedOptions.graphicsBackends.filter(
                        \.isCurrentReleaseUserSelectable
                    ),
                    label: CompatibilitySteamLaunchOptionLabelPolicy.rendererLabelKey,
                    isRecommended: {
                        $0 == selectedRecipe.recommendations.graphicsBackend
                    },
                    isEnabled: rendererIsSelectable,
                    unavailableReason: { backend in
                        guard !rendererIsSelectable(backend) else { return nil }
                        let messageKey = rendererAvailability(for: backend)?
                            .userMessageLocalizationKey ??
                            SteamRendererPolicyPreference
                                .dxvkRuntimeUnavailableLocalizationKey
                        return appState.localized(messageKey)
                    },
                    unavailableNotice: nil,
                    palette: palette
                )
            case .networkPolicy:
                identifierPicker(
                    title: "네트워크 (베타)",
                    kind: .networkPolicy,
                    selection: binding(\.networkPolicy, kind: .networkPolicy),
                    values: optionsIncludingCurrent(
                        selectedRecipe.supportedOptions.networkPolicies,
                        current: draftSelections.networkPolicy
                    ),
                    label: networkLabel,
                    palette: palette
                )
            case .audioInputPolicy:
                identifierPicker(
                    title: "오디오 입력 (베타)",
                    kind: .audioInputPolicy,
                    selection: binding(\.audioInputPolicy, kind: .audioInputPolicy),
                    values: optionsIncludingCurrent(
                        selectedRecipe.supportedOptions.audioInputPolicies,
                        current: draftSelections.audioInputPolicy
                    ),
                    label: audioInputLabel,
                    palette: palette
                )
            case .synchronizationPolicy:
                identifierPicker(
                    title: "동기화",
                    kind: .synchronizationPolicy,
                    selection: binding(
                        \.synchronizationPolicy,
                        kind: .synchronizationPolicy
                    ),
                    values: optionsIncludingCurrent(
                        selectedRecipe.supportedOptions.synchronizationPolicies,
                        current: draftSelections.synchronizationPolicy
                    ),
                    label: synchronizationLabel,
                    palette: palette
                )
            case .videoMemoryPolicy:
                identifierPicker(
                    title: "게임 비디오 메모리 (베타)",
                    kind: .videoMemoryPolicy,
                    selection: binding(\.videoMemoryPolicy, kind: .videoMemoryPolicy),
                    values: optionsIncludingCurrent(
                        selectedRecipe.supportedOptions.videoMemoryPolicies,
                        current: draftSelections.videoMemoryPolicy
                    ),
                    label: videoMemoryLabel,
                    palette: palette
                )
            case .fpsCursorPolicy:
                identifierPicker(
                    title: "FPS 커서",
                    kind: .fpsCursorPolicy,
                    selection: binding(\.fpsCursorPolicy, kind: .fpsCursorPolicy),
                    values: optionsIncludingCurrent(
                        selectedRecipe.supportedOptions.fpsCursorPolicies,
                        current: draftSelections.fpsCursorPolicy
                    ),
                    label: fpsCursorLabel,
                    palette: palette
                )
            case .controllerPolicy:
                identifierPicker(
                    title: "컨트롤러",
                    kind: .controllerPolicy,
                    selection: binding(\.controllerPolicy, kind: .controllerPolicy),
                    values: optionsIncludingCurrent(
                        selectedRecipe.supportedOptions.controllerPolicies,
                        current: draftSelections.controllerPolicy
                    ),
                    label: controllerLabel,
                    palette: palette
                )
            case .keyboardMapping:
                keyboardMappingControl(palette: palette)
            }
        }
    }

    private func singleSupportedOptionRow(
        _ kind: CompatibilitySteamLaunchOptionKindV1,
        palette: ForgePlayPalette
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(appState.localized(optionTitle(kind)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    provenanceBadge(for: kind, palette: palette)
                }
                Text(appState.localized("현재는 이 값만 지원됩니다."))
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 8)
            Text(appState.localized(optionValue(kind)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    private func readOnlyDeclaredOptionRow(
        _ kind: CompatibilitySteamLaunchOptionKindV1,
        palette: ForgePlayPalette
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(appState.localized(optionTitle(kind)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            Text(appState.localized(optionValue(kind)))
                .font(.caption.monospaced())
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            provenanceBadge(for: kind, palette: palette)
            Text(appState.localized("읽기 전용"))
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(10)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    private func toggleOption(
        title: String,
        detail: String,
        kind: CompatibilitySteamLaunchOptionKindV1,
        value: Binding<Bool>,
        palette: ForgePlayPalette
    ) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(appState.localized(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    provenanceBadge(for: kind, palette: palette)
                }
                Text(appState.localized(detail))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(palette.primary)
        .disabled(draftControlsAreDisabled)
        .padding(10)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    private func automaticPolicyExplanation(
        palette: ForgePlayPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(
                    appState.localized("자동 렌더러 제외 정책"),
                    systemImage: "lock.shield.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                provenanceBadge(for: .automaticProcessPolicies, palette: palette)
            }
            Text(
                appState.localized(
                    "선택한 매니페스트 루트 안에서 전체 경로 구성요소 또는 최종 파일 stem이 ASCII 대소문자를 무시해 GameGuard와 정확히 일치하는 보조 프로세스는 게임 렌더러 환경과 렌더러 DLL 재정의를 상속하지 않습니다."
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                appState.localized(
                    "이 필수 정책은 끌 수 없으며 보조 프로세스를 종료하거나 안티치트를 변경하거나 게임 파일을 수정하거나 검증을 우회하지 않습니다."
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    private func identifierPicker<Value: Hashable>(
        title: String,
        kind: CompatibilitySteamLaunchOptionKindV1,
        selection: Binding<Value>,
        values: [Value],
        label: @escaping (Value) -> String,
        isRecommended: @escaping (Value) -> Bool = { _ in false },
        isEnabled: @escaping (Value) -> Bool = { _ in true },
        unavailableReason: @escaping (Value) -> String? = { _ in nil },
        unavailableNotice: String? = nil,
        palette: ForgePlayPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(appState.localized(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                        provenanceBadge(for: kind, palette: palette)
                    }
                    if !isSupportedBySelectedRecipe(kind) {
                        Text(appState.localized("지원되지 않는 저장 값 · 세션 준비 차단"))
                            .font(.caption2)
                            .foregroundStyle(palette.warning)
                    }
                }
                Spacer(minLength: 8)
                Picker(appState.localized(title), selection: selection) {
                    ForEach(values, id: \.self) { value in
                        let localizedLabel = appState.localized(label(value))
                        Text(
                            isRecommended(value)
                                ? appState.localizedFormat("%@ (권장)", localizedLabel)
                                : localizedLabel
                        )
                        .tag(value)
                        .disabled(!isEnabled(value))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(draftControlsAreDisabled)
            }
            if let reason = unavailableNotice ??
                unavailableReason(selection.wrappedValue) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    private func keyboardMappingControl(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(appState.localized("키보드 입력"), systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                provenanceBadge(for: .keyboardMapping, palette: palette)
                Spacer(minLength: 8)
                Text(appState.localized(keyboardMappingDisplayValue))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        isSupportedBySelectedRecipe(.keyboardMapping)
                            ? palette.secondaryText
                            : palette.warning
                    )
            }

            Text(
                appState.localized(
                    "Steam 프리픽스 내부 키보드 입력은 System Default로 유지됩니다. 호스트 보조키 매핑과 macOS 단축키 보호는 설정 > 입력 및 게임 보호에서 관리합니다."
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if !isSupportedBySelectedRecipe(.keyboardMapping) {
                Text(
                    appState.localized(
                        "지원되지 않는 이전 키보드 저장 값입니다. 프로필 권장값을 복원한 뒤 설정을 저장하세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
        .accessibilityHint(
            appState.localized(
                "프리픽스 키보드 입력은 읽기 전용이며 System Default로 유지됩니다. 호스트 입력 보호는 설정에서 관리합니다."
            )
        )
    }

    private func resolvedOptionsCard(palette: ForgePlayPalette) -> some View {
        ForgeCard("해결된 초안", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    appState.localized(
                        "모든 프로필 값과 출처를 표시합니다. 런타임 기능 지원 여부는 실제 제공자의 응답 전까지 확인되지 않습니다."
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(resolvedSummaryKinds, id: \.self) { kind in
                    resolvedOptionRow(kind, palette: palette)
                }
            }
        }
    }

    private func resolvedOptionRow(
        _ kind: CompatibilitySteamLaunchOptionKindV1,
        palette: ForgePlayPalette
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(appState.localized(optionTitle(kind)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)
                .frame(width: 150, alignment: .leading)
            Text(appState.localized(optionValue(kind)))
                .font(.caption.monospaced())
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            provenanceBadge(for: kind, palette: palette)
            Text(appState.localized(optionStatus(kind)))
                .font(.caption2)
                .foregroundStyle(isSupportedBySelectedRecipe(kind) ? palette.secondaryText : palette.warning)
        }
        .padding(.vertical, 3)
    }

    private func actionCard(palette: ForgePlayPalette) -> some View {
        let availability = compatibilityLaunchAvailability
        return ForgeCard("호환성 Steam 실행", systemImage: "play.circle.fill", emphasis: .accent) {
            VStack(alignment: .leading, spacing: 12) {
                ResponsiveActionRow {
                    ThemedActionButton(
                        title: "설정 저장",
                        systemImage: "square.and.arrow.down",
                        prominence: .secondary,
                        isDisabled: saveIsDisabled
                    ) {
                        saveDraftFromAction()
                    }
                    ThemedActionButton(
                        title: "Steam 실행",
                        systemImage: "play.fill",
                        prominence: .primary,
                        isDisabled: !availability.isAvailable
                    ) {
                        saveAndPrepareSteamSession()
                    }
                    .help(availability.message)
                    .accessibilityHint(availability.message)
                    ThemedActionButton(
                        title: "프로필 권장값 복원",
                        systemImage: "arrow.counterclockwise",
                        prominence: .secondary,
                        isDisabled: recommendationsRestoreIsDisabled
                    ) {
                        restoreProfileRecommendations()
                    }
                }

                if let disabledReason = availability.disabledReason {
                    Label(disabledReason, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(disabledReason)
                }

                if gameInputProtectionAuthorizationBlockerKey != nil {
                    GameInputProtectionAuthorizationPanel(
                        disablePermissionRequiredProtection:
                            disablePermissionRequiredGameInputProtection
                    )
                }

                Text(appState.localized(
                    "Steam 호환성 실행 (베타)은 선택한 게임 프로필만을 위한 별도 실행 경로입니다. 일반 Steam 실행 화면의 공통 설정과 독립적으로 저장되며 그 설정을 덮어쓰지 않습니다."
                ))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text(appState.localized(
                    "아래에서 게임 프로필과 실행 설정을 확인하세요. Game Mode의 초기 권장값은 켬이며, 같은 프로필에 저장한 끔 값도 그대로 복원됩니다."
                ))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if isPersistenceBlocked || mustReloadAfterConflict {
                    ThemedActionButton(
                        title: isPersistenceBlocked &&
                            blockedPersistenceRecoveryVersion != nil
                            ? "손상된 저장 값 초기화"
                            : "최신 저장 값 다시 불러오기",
                        systemImage: isPersistenceBlocked &&
                            blockedPersistenceRecoveryVersion != nil
                            ? "arrow.counterclockwise"
                            : "arrow.clockwise",
                        prominence: .secondary,
                        isDisabled: isPreparingSession,
                        controlSize: .small
                    ) {
                        if isPersistenceBlocked,
                           blockedPersistenceRecoveryVersion != nil {
                            isShowingCompatibilityPreferenceResetConfirmation =
                                true
                        } else {
                            loadSelectedRecipeDraft()
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                }

                if let compatibilityStatus {
                    compatibilityStatusView(
                        compatibilityStatus,
                        palette: palette
                    )
                }

                if let lastPreparation {
                    Divider()
                    Text(
                        appState.localizedFormat(
                            lastPreparation.receipt.evidence.restoredBaselineDigest == nil
                                ? "제공자 영수증 %@ · 요청 다이제스트 %@ · 실행 세션 활성(기준 상태 복원 대기)"
                                : "제공자 영수증 %@ · 요청 다이제스트 %@ · 실행 세션 완료(기준 상태 복원 확인)",
                            lastPreparation.receipt.receiptID,
                            lastPreparation.request.canonicalDigest
                        )
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    if lastPreparation.receipt.evidence.restoredBaselineDigest == nil {
                        ThemedActionButton(
                            title: "Steam 세션 종료 및 기준 상태 복원",
                            systemImage: "stop.circle",
                            prominence: .secondary,
                            isDisabled: isPreparingSession || !hasActiveSession ||
                                appState.isSteamLaunchInProgress ||
                                sessionCoordinator.isStandardSteamLaunchReserved,
                            controlSize: .small
                        ) {
                            completeSteamSession()
                        }
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
                    }
                }
            }
        }
    }

    private func compatibilityStatusView(
        _ status: CompatibilityStatusPresentation,
        palette: ForgePlayPalette
    ) -> some View {
        let presentation: (symbol: String, color: Color, accessibilityLabel: String) =
            switch status.kind {
            case .progress:
                ("hourglass", palette.primary, appState.localized("진행 상태"))
            case .success:
                ("checkmark.circle.fill", palette.success, appState.localized("성공 상태"))
            case .warning:
                ("exclamationmark.triangle.fill", palette.warning, appState.localized("주의 상태"))
            case .failure:
                ("xmark.octagon.fill", palette.danger, appState.localized("실패 상태"))
            }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.color)
                    .accessibilityHidden(true)
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(presentation.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(status.message)

            if let logURL = status.logURL {
                ThemedActionButton(
                    title: "로그 보기",
                    systemImage: "doc.text.magnifyingglass",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.revealInFinder(logURL)
                }
                .frame(minWidth: 120, idealWidth: 150, maxWidth: 190)
            }
        }
    }

    private var resolvedSummaryKinds: [CompatibilitySteamLaunchOptionKindV1] {
        selectedRecipe.orderedOptionDescriptors.map(\.kind)
    }

    private func collapsedAdvancedSummary(
        _ descriptors: [CompatibilitySteamLaunchOptionDescriptorV1]
    ) -> String {
        descriptors.map {
            "\(appState.localized(optionTitle($0.kind))): \(appState.localized(optionValue($0.kind)))"
        }.joined(separator: " · ")
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<CompatibilitySteamLaunchUserSelectionsV1, Value>,
        kind: CompatibilitySteamLaunchOptionKindV1
    ) -> Binding<Value> {
        Binding(
            get: { draftSelections[keyPath: keyPath] },
            set: { value in
                draftSelections[keyPath: keyPath] = value
                markDraftChanged(kind)
            }
        )
    }

    private var graphicsBackendBinding: Binding<SteamGraphicsBackendIdentifier> {
        Binding(
            get: { draftSelections.graphicsBackend },
            set: { backend in
                draftSelections.graphicsBackend = backend
                markDraftChanged(.graphicsBackend)
                if !backend.supportsCurrentReleaseFrameGeneration,
                   draftSelections.frameGenerationConfiguration != .off {
                    draftSelections.frameGenerationConfiguration = .off
                    markDraftChanged(.frameGeneration)
                }
            }
        )
    }

    private func compatibilityFrameGenerationControl(
        palette: ForgePlayPalette
    ) -> some View {
        let rendererSupportsFrameGeneration =
            draftSelections.graphicsBackend.supportsCurrentReleaseFrameGeneration
        let configuration = draftSelections.frameGenerationConfiguration

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(appState.localized("Frame Generation (베타)"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                provenanceBadge(for: .frameGeneration, palette: palette)
            }

            Toggle(
                isOn: Binding(
                    get: {
                        draftSelections.frameGenerationConfiguration.isEnabled
                    },
                    set: { enabled in
                        draftSelections.frameGenerationConfiguration
                            .setEnabled(enabled)
                        markDraftChanged(.frameGeneration)
                    }
                )
            ) {
                Text(appState.localized(
                    "D3DMetal - NVIDIA에서 원본 프레임 사이에 보간 프레임을 생성해 선택한 표시 목표에 맞춥니다. 현재 베타 기능이며 게임과 입력 방식에 따라 입력 지연이 늘어날 수 있습니다."
                ))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .tint(palette.primary)
            .disabled(draftControlsAreDisabled || !rendererSupportsFrameGeneration)

            if !rendererSupportsFrameGeneration {
                Text(appState.localized(
                    "Frame Generation (베타)은 현재 D3DMetal - NVIDIA에서만 켤 수 있습니다."
                ))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(appState.localized("목표 표시 FPS"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    compatibilityFrameGenerationTargetButtons(
                        configuration: configuration,
                        palette: palette
                    )
                }
                VStack(alignment: .leading, spacing: 6) {
                    compatibilityFrameGenerationTargetButtons(
                        configuration: configuration,
                        palette: palette
                    )
                }
            }

            Toggle(
                isOn: Binding(
                    get: {
                        draftSelections.frameGenerationConfiguration
                            .isFrameCheckEnabled
                    },
                    set: { enabled in
                        guard draftSelections.frameGenerationConfiguration
                            .isEnabled else {
                            draftSelections.frameGenerationConfiguration
                                .isFrameCheckEnabled = false
                            return
                        }
                        draftSelections.frameGenerationConfiguration
                            .isFrameCheckEnabled = enabled
                        markDraftChanged(.frameGeneration)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.localized("Frame Check (베타)"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(appState.localized(
                        "프레임 생성 출력의 실제 최종 표시 cadence(원본과 보간 프레임 포함)를 게임 화면 오른쪽 상단에 표시합니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(palette.primary)
            .disabled(
                draftControlsAreDisabled ||
                    !rendererSupportsFrameGeneration ||
                    !configuration.isEnabled
            )

            Text(appState.localized(
                "입력 지연 가능성이 있습니다. ForgePlay 스케줄러의 보간 프레임 추가 지연 예산: 120 FPS → 약 10.42ms, 144 FPS → 약 8.68ms, 240 FPS → 약 5.21ms. 실제 지연은 macOS 합성기 및 디스플레이 상태에 따라 더 커질 수 있습니다."
            ))
            .font(.caption2)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    @ViewBuilder
    private func compatibilityFrameGenerationTargetButtons(
        configuration: FrameGenerationConfiguration,
        palette: ForgePlayPalette
    ) -> some View {
        ForEach(FrameGenerationPolicy.visibleTargetFrameRates) { targetFrameRate in
            let isSelected = configuration.targetFrameRate == targetFrameRate
            let isSelectable = targetFrameRate.isSelectableInCurrentRelease &&
                selectedRecipe.supportedOptions.frameGenerationTargetFrameRates
                    .contains(targetFrameRate)
            Button {
                draftSelections.frameGenerationConfiguration.targetFrameRate =
                    targetFrameRate
                markDraftChanged(.frameGeneration)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    Text("\(targetFrameRate.rawValue) FPS")
                    if !isSelectable {
                        Text(appState.localized("준비 중"))
                            .font(.caption2)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isSelectable ? palette.text : palette.secondaryText
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(isSelected ? palette.primary.opacity(0.10) : palette.control)
                .overlay {
                    RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius)
                        .stroke(
                            isSelected ? palette.primary : palette.border,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius)
                )
            }
            .buttonStyle(.plain)
            .disabled(
                draftControlsAreDisabled ||
                    !configuration.isEnabled ||
                    !isSelectable
            )
            .help(
                appState.localized(
                    isSelectable
                        ? "이번 Steam 실행의 Frame Generation 목표 표시 FPS입니다."
                        : "현재 Release에서는 선택할 수 없습니다."
                )
            )
            .accessibilityValue(
                appState.localized(
                    !isSelectable
                        ? "사용할 수 없음"
                        : (isSelected ? "선택됨" : "선택되지 않음")
                )
            )
        }
    }

    private func optionsIncludingCurrent<Value: Hashable>(
        _ options: [Value],
        current: Value
    ) -> [Value] {
        options.contains(current) ? options : [current] + options
    }

    private func rendererPreference(
        for backend: SteamGraphicsBackendIdentifier
    ) -> SteamRendererPolicyPreference? {
        switch backend {
        case .d3dMetal, .d3dMetalNVIDIA:
            .d3dMetal
        case .dxmt:
            .dxmt
        case .d9vk:
            .d9vk
        case .dxvk:
            .vulkan
        default:
            nil
        }
    }

    private func rendererAvailability(
        for backend: SteamGraphicsBackendIdentifier
    ) -> SteamRendererPolicyAvailability? {
        rendererAvailabilityByBackend[backend]
    }

    private func rendererIsSelectable(
        _ backend: SteamGraphicsBackendIdentifier
    ) -> Bool {
        guard backend.isCurrentReleaseUserSelectable else { return false }
        guard backend == .dxvk else { return true }
        return rendererAvailability(for: backend)?.isAvailable == true
    }

    private var selectedRendererRuntimeBlocker: String? {
        guard draftSelections.graphicsBackend == .dxvk,
              rendererAvailability(for: .dxvk)?.isAvailable != true else {
            return nil
        }
        let messageKey = rendererAvailability(for: .dxvk)?
            .userMessageLocalizationKey ??
            SteamRendererPolicyPreference.dxvkRuntimeUnavailableLocalizationKey
        return appState.localized(messageKey)
    }

    @MainActor
    private func refreshRendererAvailability(taskID: String) async {
        guard let executable = appState.runtimeExecutableURL else {
            guard taskID == rendererAvailabilityTaskID else { return }
            rendererAvailabilityByBackend = [:]
            return
        }
        let snapshot: WindowsRuntimeCapabilitySnapshot
        do {
            snapshot = try await services.windowsRuntimeService
                .runtimeCapabilitySnapshot(executable: executable)
        } catch {
            guard !Task.isCancelled,
                  taskID == rendererAvailabilityTaskID else {
                return
            }
            rendererAvailabilityByBackend = [:]
            return
        }
        guard !Task.isCancelled,
              taskID == rendererAvailabilityTaskID else {
            return
        }
        let values = selectedRecipe.supportedOptions.graphicsBackends.filter(
            \.isCurrentReleaseUserSelectable
        )
        rendererAvailabilityByBackend = Dictionary(
            values.map { backend in
                let availability = rendererPreference(for: backend)?
                    .availability(in: snapshot.capability) ?? .unavailable()
                return (backend, availability)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func networkLabel(_ value: SteamNetworkPolicyIdentifier) -> String {
        switch value {
        case .standard: SteamNetworkCompatibilitySelection.standard.labelKey
        case .wifiIdentity: SteamNetworkCompatibilitySelection.wifiIdentity.labelKey
        case .ethernetIdentity:
            SteamNetworkCompatibilitySelection.ethernetIdentity.labelKey
        default: "지원되지 않는 이전 저장 값"
        }
    }

    private func audioInputLabel(_ value: SteamAudioInputPolicyIdentifier) -> String {
        switch value {
        case .disabled: SteamAudioInputSelection.disabled.labelKey
        case .enabled: SteamAudioInputSelection.enabled.labelKey
        default: "지원되지 않는 이전 저장 값"
        }
    }

    private func synchronizationLabel(
        _ value: SteamSynchronizationPolicyIdentifier
    ) -> String {
        value == .automatic
            ? WineSynchronizationSelection.automatic.labelKey
            : "지원되지 않는 이전 저장 값"
    }

    private func videoMemoryLabel(_ value: SteamVideoMemoryPolicyIdentifier) -> String {
        switch value {
        case .automatic: SteamVideoMemorySelection.automatic.labelKey
        case .gb2: SteamVideoMemorySelection.gb2.labelKey
        case .gb4: SteamVideoMemorySelection.gb4.labelKey
        case .gb8: SteamVideoMemorySelection.gb8.labelKey
        case .gb12: SteamVideoMemorySelection.gb12.labelKey
        case .gb16: SteamVideoMemorySelection.gb16.labelKey
        default: "지원되지 않는 이전 저장 값"
        }
    }

    private func fpsCursorLabel(_ value: FPSCursorCapturePolicy) -> String {
        value == .off ? "끔" : "지원되지 않는 이전 저장 값"
    }

    private func controllerLabel(_ value: ControllerCompatibilityPolicy) -> String {
        value == .automatic ? "자동" : "지원되지 않는 이전 저장 값"
    }

    private func hasExactlyOneSupportedValue(
        _ kind: CompatibilitySteamLaunchOptionKindV1
    ) -> Bool {
        switch kind {
        case .synchronizationPolicy:
            selectedRecipe.supportedOptions.synchronizationPolicies.count == 1
        case .fpsCursorPolicy:
            selectedRecipe.supportedOptions.fpsCursorPolicies.count == 1
        case .controllerPolicy:
            selectedRecipe.supportedOptions.controllerPolicies.count == 1
        default:
            false
        }
    }

    private func provenanceBadge(
        for kind: CompatibilitySteamLaunchOptionKindV1,
        palette: ForgePlayPalette
    ) -> some View {
        Text(appState.localized(provenanceLabel(kind)))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.control)
            .clipShape(Capsule())
    }

    private func provenanceLabel(_ kind: CompatibilitySteamLaunchOptionKindV1) -> String {
        if kind == .automaticProcessPolicies { return "자동 필수" }
        return switch fieldProvenance[kind] ?? .recipe {
        case .recipe: "프로필 권장"
        case .savedPreference: "저장된 사용자 값"
        case .oneLaunchOverride: "저장 전 사용자 변경"
        case .automaticRequired: "자동 필수"
        }
    }

    private func optionTitle(_ kind: CompatibilitySteamLaunchOptionKindV1) -> String {
        switch kind {
        case .frameGeneration: "Frame Generation (베타)"
        case .gameMode: "Game Mode"
        case .heapZeroMemory: "Heap zero memory"
        case .automaticProcessPolicies: "자동 렌더러 제외 정책"
        case .graphicsBackend: "렌더러"
        case .networkPolicy: "네트워크 (베타)"
        case .audioInputPolicy: "오디오 입력 (베타)"
        case .synchronizationPolicy: "동기화"
        case .videoMemoryPolicy: "게임 비디오 메모리 (베타)"
        case .fpsCursorPolicy: "FPS 커서"
        case .controllerPolicy: "컨트롤러"
        case .keyboardMapping: "키보드 입력"
        }
    }

    private var keyboardMappingDisplayValue: String {
        draftSelections.keyboardMapping == .systemDefault
            ? "System Default"
            : "지원되지 않는 이전 저장 값"
    }

    private func optionValue(_ kind: CompatibilitySteamLaunchOptionKindV1) -> String {
        switch kind {
        case .frameGeneration:
            if !draftSelections.frameGenerationConfiguration.isEnabled {
                "끔"
            } else {
                appState.localizedFormat(
                    "%d FPS 목표 · Frame Check %@",
                    draftSelections.frameGenerationConfiguration.targetFrameRate.rawValue,
                    appState.localized(
                        draftSelections.frameGenerationConfiguration
                            .isFrameCheckEnabled ? "켬" : "끔"
                    )
                )
            }
        case .gameMode:
            draftSelections.gameModeEnabled ? "켬" : "끔"
        case .heapZeroMemory:
            draftSelections.heapZeroMemoryEnabled ? "켬" : "끔"
        case .automaticProcessPolicies:
            "GameGuard exact component-or-stem · renderer exclusions only"
        case .graphicsBackend:
            CompatibilitySteamLaunchOptionLabelPolicy.rendererLabelKey(
                draftSelections.graphicsBackend
            )
        case .networkPolicy:
            networkLabel(draftSelections.networkPolicy)
        case .audioInputPolicy:
            audioInputLabel(draftSelections.audioInputPolicy)
        case .synchronizationPolicy:
            synchronizationLabel(draftSelections.synchronizationPolicy)
        case .videoMemoryPolicy:
            videoMemoryLabel(draftSelections.videoMemoryPolicy)
        case .fpsCursorPolicy:
            fpsCursorLabel(draftSelections.fpsCursorPolicy)
        case .controllerPolicy:
            controllerLabel(draftSelections.controllerPolicy)
        case .keyboardMapping:
            keyboardMappingDisplayValue
        }
    }

    private func optionStatus(_ kind: CompatibilitySteamLaunchOptionKindV1) -> String {
        if kind == .automaticProcessPolicies { return "필수 · 사용자 변경 불가" }
        return isSupportedBySelectedRecipe(kind)
            ? "프로필 유효 · 런타임 기능 확인 전"
            : "프로필 미지원 · 세션 준비 차단"
    }

    private func isSupportedBySelectedRecipe(
        _ kind: CompatibilitySteamLaunchOptionKindV1
    ) -> Bool {
        switch kind {
        case .gameMode, .heapZeroMemory, .automaticProcessPolicies:
            true
        case .frameGeneration:
            selectedRecipe.supportedOptions.frameGenerationTargetFrameRates.contains(
                draftSelections.frameGenerationConfiguration.targetFrameRate
            ) && (try? draftSelections.frameGenerationConfiguration.validate(
                isSupportedRenderer:
                    draftSelections.graphicsBackend
                        .supportsCurrentReleaseFrameGeneration
            )) != nil
        case .graphicsBackend:
            selectedRecipe.supportedOptions.graphicsBackends.contains(
                draftSelections.graphicsBackend
            ) && draftSelections.graphicsBackend.isCurrentReleaseUserSelectable
        case .networkPolicy:
            selectedRecipe.supportedOptions.networkPolicies.contains(
                draftSelections.networkPolicy
            )
        case .audioInputPolicy:
            selectedRecipe.supportedOptions.audioInputPolicies.contains(
                draftSelections.audioInputPolicy
            )
        case .synchronizationPolicy:
            selectedRecipe.supportedOptions.synchronizationPolicies.contains(
                draftSelections.synchronizationPolicy
            )
        case .videoMemoryPolicy:
            selectedRecipe.supportedOptions.videoMemoryPolicies.contains(
                draftSelections.videoMemoryPolicy
            )
        case .fpsCursorPolicy:
            selectedRecipe.supportedOptions.fpsCursorPolicies.contains(
                draftSelections.fpsCursorPolicy
            )
        case .controllerPolicy:
            selectedRecipe.supportedOptions.controllerPolicies.contains(
                draftSelections.controllerPolicy
            )
        case .keyboardMapping:
            draftSelections.keyboardMapping == .systemDefault &&
                selectedRecipe.supportedOptions.keyboardPresets.contains(.systemDefault)
        }
    }

    private var draftControlsAreDisabled: Bool {
        isPreparingSession || hasActiveSession ||
            appState.isSteamLaunchInProgress ||
            sessionCoordinator.isStandardSteamLaunchReserved
    }

    private var recommendationsRestoreIsDisabled: Bool {
        CompatibilityProfileDraftInteractionPolicy
            .recommendationsRestoreIsDisabled(
                isPersistenceBlocked: isPersistenceBlocked,
                isPreparingSession: isPreparingSession,
                hasActiveSession: hasActiveSession,
                isSteamLaunchInProgress: appState.isSteamLaunchInProgress,
                isStandardSteamLaunchReserved:
                    sessionCoordinator.isStandardSteamLaunchReserved
            )
    }

    private var gameInputProtectionAuthorizationBlockerKey: String? {
        SteamLaunchGameInputProtectionAdmissionPolicy.blockerLocalizationKey(
            policy: services.gameInputProtectionPolicyStore.snapshot(),
            authorizationStatus: services.gameInputProtectionAuthorizationStatus
        )
    }

    private func refreshGameInputProtectionAuthorizationIfNeeded() {
        guard services.gameInputProtectionPolicyStore.snapshot().requiresEventTap else {
            return
        }
        services.refreshGameInputProtectionAuthorizationStatus()
    }

    private func disablePermissionRequiredGameInputProtection() {
        let warning = appState.saveUserPreferencesAfterMutation(
            to: modelContext
        ) {
            appState.disableGameInputEventTapProtection()
        }
        guard warning == nil else { return }
        services.synchronizeGameInputProtectionPolicy(from: appState)
        appState.setNotice(
            appState.localized(
                "권한이 필요한 입력 보호를 껐습니다. Steam은 권한이 필요한 보호 없이 실행할 수 있습니다."
            ),
            kind: .success
        )
    }

    private var sessionCoordinator: SteamCompatibilitySessionCoordinator {
        services.steamCompatibilitySessionCoordinator
    }

    private var isPreparingSession: Bool {
        sessionCoordinator.isTransitionInProgress
    }

    private var lastPreparation: CompatibilitySteamLaunchPreparationV1? {
        sessionCoordinator.lastPreparation
    }

    private var hasActiveSession: Bool {
        sessionCoordinator.hasActiveSession
    }

    private var saveIsDisabled: Bool {
        draftControlsAreDisabled
    }

    private var exactApprovedManifestRecords: [SteamGameRecord] {
        steamGames.filter {
            $0.steamAppId == selectedRecipe.identity.steamAppID
        }
    }

    private var canonicalManifestMountCandidates:
        [CompatibilityManifestMountCandidate]
    {
        steamStorageMounts.compactMap { mount in
            guard let bookmark = mount.bookmark, !bookmark.isEmpty else {
                return nil
            }
            return CompatibilityManifestMountCandidate(
                id: mount.id,
                path: mount.path,
                bookmark: bookmark
            )
        }
    }

    private var missingManifestRequirementReason: String {
        switch manifestRootReadiness {
        case .validating:
            return appState.localized("확인 중")
        case .failed(let reason):
            return reason
        case .missing, .ready:
            break
        }
        if let approvedManifestAutoSelectionFailure {
            return approvedManifestAutoSelectionFailure
        }
        if exactApprovedManifestRecords.count > 1 {
            return appState.localized(
                "이 App ID와 일치하는 승인된 SteamLibrary 북마크가 여러 개라 자동으로 추측하지 않았습니다. 매니페스트 루트를 직접 선택하세요."
            )
        }
        return appState.localized(
            "이 게임과 정확히 일치하는 승인된 SteamLibrary 북마크를 찾지 못했습니다. Steam 매니페스트 루트를 직접 선택하세요."
        )
    }

    private var missingManagedRuntimeRequirementReason: String {
        if let managedRuntimeAuthorizationFailure {
            return managedRuntimeAuthorizationFailure
        }
        return appState.localized(
            "관리 ForgePlay Runtime 권한을 자동 준비하지 못했습니다. 관리 Runtime을 다시 확인하세요."
        )
    }

    private var compatibilityLaunchAvailability: LaunchAvailability {
        if appState.isSteamLaunchInProgress ||
            sessionCoordinator.isStandardSteamLaunchReserved {
            return .unavailable(
                reason: appState.localized("Steam 실행이 이미 진행 중입니다.")
            )
        }
        if isPreparingSession {
            return .unavailable(
                reason: appState.localized("Steam 호환성 세션을 준비하는 중입니다.")
            )
        }
        if hasActiveSession {
            return .unavailable(
                reason: appState.localized(
                    "다른 Steam 호환성 세션이 활성 상태입니다. 먼저 세션을 종료하고 기준 상태를 복원하세요."
                )
            )
        }
        var reasons: [String] = []
        if let unsupported = selectedRecipe.orderedOptionDescriptors.first(where: {
            !isSupportedBySelectedRecipe($0.kind)
        }) {
            reasons.append(
                appState.localizedFormat(
                    "지원되지 않는 프로필 옵션이 있습니다: %@. 프로필 권장값을 복원한 뒤 저장하세요.",
                    appState.localized(optionTitle(unsupported.kind))
                )
            )
        }
        if let selectedRendererRuntimeBlocker {
            reasons.append(selectedRendererRuntimeBlocker)
        }
        if manifestRootReadiness != .ready || unresolvedManifestRootBookmark == nil {
            reasons.append(missingManifestRequirementReason)
        }
        if runtimeExecutableBookmark == nil {
            reasons.append(missingManagedRuntimeRequirementReason)
        }
        if !reasons.isEmpty {
            return .unavailable(reason: reasons.joined(separator: " "))
        }

        return .available(
            message: appState.localized(
                "현재 프로필과 필수 실행 입력이 확인되어 Steam을 실행할 수 있습니다."
            )
        )
    }

    private var compatibilityDraftIsPersisted: Bool {
        guard !compatibilityDraftSaveFailed,
              !isPersistenceBlocked,
              !mustReloadAfterConflict,
              let savedEnvelope,
              let currentPayload = try? currentPreferencePayload(),
              currentPayload == savedEnvelope.payload else {
            return false
        }
        return true
    }

    private func diagnosticLogURL(for error: Error) -> URL? {
        (error as? ForgePlayDiagnosticLogProvidingError)?.forgePlayDiagnosticLogURL
    }

    private func compatibilityPreferenceErrorIsRecoverableCorruption(
        _ error: Error
    ) -> Bool {
        if let persistenceError =
            error as? SteamLaunchConfigurationPersistenceError {
            switch persistenceError {
            case .unexpectedMode,
                 .recordIdentityMismatch,
                 .schemaVersionMismatch,
                 .digestMismatch,
                 .invalidPersistenceRevision:
                return true
            case .contextHasPendingChanges,
                 .duplicateRecord,
                 .writeConflict,
                 .incompleteLaunchRecordProjection,
                 .requestedTransactionCannotBeRecorded,
                 .transactionConfigurationMismatch:
                return false
            }
        }
        if error is SteamLaunchConfigurationError { return true }
        if let profileError = error as? SteamCompatibilityLaunchProfileErrorV1 {
            switch profileError {
            case .identityMismatch,
                 .invalidPreference,
                 .invalidCanonicalPayload,
                 .migrationRejected:
                return true
            case .unsupportedContractVersion,
                 .unsupportedRecipeSchemaVersion,
                 .invalidRecipe,
                 .invalidManifestRootAuthorization,
                 .attemptedAutomaticPolicyRemoval,
                 .unsupportedCapability,
                 .invalidReceipt:
                return false
            }
        }
        return false
    }

    @discardableResult
    private func presentCompatibilityFailure(
        _ error: Error,
        message: String
    ) -> AppNotice {
        compatibilityStatus = CompatibilityStatusPresentation(
            .failure,
            message: message,
            logURL: diagnosticLogURL(for: error)
        )
        let errorNotice = appState.setError(
            error,
            operationIdentifier: "steamCompatibilityLaunch",
            surfaceIdentifier: "steamCompatibilityLaunch"
        )
        return appState.setNotice(
            message,
            kind: .failure,
            logURL: errorNotice.logURL,
            captureFailureEvidence: false
        )
    }

    @discardableResult
    private func restoreActiveSessionPresentationIfAvailable() -> Bool {
        guard hasActiveSession,
              let presentation = sessionCoordinator.activePresentation else {
            return false
        }
        selectedRecipeID = presentation.selectedRecipeID
        draftSelections = presentation.selections
        fieldProvenance = presentation.fieldProvenance
        savedEnvelope = presentation.savedPreference
        compatibilityDraftSaveFailed = false
        isPersistenceBlocked = false
        blockedPersistenceRecoveryVersion = nil
        mustReloadAfterConflict = false
        return true
    }

    private func loadSelectedRecipeDraft() {
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(
            container: modelContext.container
        )
        do {
            if let stored = try repository.loadOrMigrate(recipe: selectedRecipe) {
                savedEnvelope = stored
                draftSelections = stored.payload.selections
                setAllUserProvenance(.savedPreference)
            } else {
                savedEnvelope = nil
                draftSelections = selectedRecipe.recommendations.selections
                setAllUserProvenance(.recipe)
            }
            let rendererWasNormalized =
                normalizeRendererDraftForCurrentReleaseIfNeeded()
            var normalizationOverride:
                CompatibilitySteamLaunchOneLaunchOverrideV1?
            if rendererWasNormalized {
                var oneLaunchOverride = CompatibilitySteamLaunchOneLaunchOverrideV1(
                    identity: selectedRecipe.identity
                )
                oneLaunchOverride.graphicsBackend =
                    draftSelections.graphicsBackend
                normalizationOverride = oneLaunchOverride
            } else {
                normalizationOverride = nil
            }
            _ = try SteamCompatibilityLaunchResolverV1.resolveDraft(
                recipe: selectedRecipe,
                savedPreference: savedEnvelope,
                oneLaunchOverride: normalizationOverride
            )
            isPersistenceBlocked = false
            blockedPersistenceRecoveryVersion = nil
            mustReloadAfterConflict = false
            compatibilityDraftSaveFailed = false
            compatibilityStatus = rendererWasNormalized
                ? CompatibilityStatusPresentation(
                    .warning,
                    message: appState.localized(
                        "이전에 저장한 숨겨진 그래픽 백엔드를 현재 선택 가능한 D3DMetal - NVIDIA로 바꾼 저장되지 않은 초안입니다. 저장하기 전에는 기존 저장값을 덮어쓰지 않습니다."
                    )
                )
                : nil
        } catch {
            savedEnvelope = nil
            draftSelections = selectedRecipe.recommendations.selections
            setAllUserProvenance(.recipe)
            _ = normalizeRendererDraftForCurrentReleaseIfNeeded()
            blockedPersistenceRecoveryVersion =
                compatibilityPreferenceErrorIsRecoverableCorruption(error)
                ? (try? repository.recoveryVersion(
                    identity: selectedRecipe.identity
                ))
                : nil
            isPersistenceBlocked = blockedPersistenceRecoveryVersion != nil
            mustReloadAfterConflict = !isPersistenceBlocked
            compatibilityDraftSaveFailed = true
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: appState.localizedFormat(
                    "저장된 호환성 환경설정을 불러오지 못해 프로필 권장값으로 계속합니다. 현재 선택은 저장하지 않아도 이번 실행에 사용할 수 있습니다: %@",
                    appState.localizedError(error)
                ),
                logURL: diagnosticLogURL(for: error)
            )
        }
    }

    private func resetBlockedCompatibilityPreference() {
        guard !isPreparingSession,
              let expectedVersion = blockedPersistenceRecoveryVersion else {
            return
        }
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(
            container: modelContext.container
        )
        do {
            try repository.resetForRecovery(
                identity: selectedRecipe.identity,
                expectedVersion: expectedVersion
            )
            blockedPersistenceRecoveryVersion = nil
            isPersistenceBlocked = false
            loadSelectedRecipeDraft()
            let message = appState.localized(
                "손상된 호환성 환경설정 저장 값을 초기화했습니다."
            )
            compatibilityStatus = CompatibilityStatusPresentation(
                .success,
                message: message
            )
            let notice = appState.setNotice(message, kind: .success)
            clearTaskLater(notice.id)
        } catch {
            let notice = presentCompatibilityFailure(
                error,
                message: appState.localizedFormat(
                    "손상된 호환성 환경설정 저장 값을 초기화하지 못했습니다: %@",
                    appState.localizedError(error)
                )
            )
            clearTaskLater(notice.id)
        }
    }

    private func restoreProfileRecommendations() {
        for descriptor in selectedRecipe.orderedOptionDescriptors where descriptor.isUserSelectable {
            restoreProfileRecommendation(for: descriptor.kind)
            fieldProvenance[descriptor.kind] = .recipe
        }
        _ = normalizeRendererDraftForCurrentReleaseIfNeeded()
        isPersistenceBlocked = false
        blockedPersistenceRecoveryVersion = nil
        compatibilityDraftSaveFailed = false
        sessionCoordinator.clearCompletedSession()
        compatibilityStatus = CompatibilityStatusPresentation(
            .warning,
            message: appState.localized(
                "프로필 권장값을 현재 초안에 복원했습니다. 저장소는 아직 변경하지 않았습니다."
            )
        )
    }

    private func restoreProfileRecommendation(
        for kind: CompatibilitySteamLaunchOptionKindV1
    ) {
        let recommended = selectedRecipe.recommendations.selections
        switch kind {
        case .frameGeneration:
            draftSelections.frameGenerationConfiguration =
                recommended.frameGenerationConfiguration
        case .gameMode:
            draftSelections.gameModeEnabled = recommended.gameModeEnabled
        case .heapZeroMemory:
            draftSelections.heapZeroMemoryEnabled = recommended.heapZeroMemoryEnabled
        case .graphicsBackend:
            draftSelections.graphicsBackend = recommended.graphicsBackend
        case .networkPolicy:
            draftSelections.networkPolicy = recommended.networkPolicy
        case .audioInputPolicy:
            draftSelections.audioInputPolicy = recommended.audioInputPolicy
        case .synchronizationPolicy:
            draftSelections.synchronizationPolicy = recommended.synchronizationPolicy
        case .videoMemoryPolicy:
            draftSelections.videoMemoryPolicy = recommended.videoMemoryPolicy
        case .fpsCursorPolicy:
            draftSelections.fpsCursorPolicy = recommended.fpsCursorPolicy
        case .controllerPolicy:
            draftSelections.controllerPolicy = recommended.controllerPolicy
        case .keyboardMapping:
            draftSelections.keyboardMapping = recommended.keyboardMapping
        case .automaticProcessPolicies:
            break
        }
    }

    @discardableResult
    private func normalizeRendererDraftForCurrentReleaseIfNeeded() -> Bool {
        let normalized = draftSelections.graphicsBackend.normalizedForCurrentRelease
        guard normalized != draftSelections.graphicsBackend else { return false }
        draftSelections.graphicsBackend = normalized
        fieldProvenance[.graphicsBackend] = .oneLaunchOverride
        if !normalized.supportsCurrentReleaseFrameGeneration,
           draftSelections.frameGenerationConfiguration != .off {
            draftSelections.frameGenerationConfiguration = .off
            fieldProvenance[.frameGeneration] = .oneLaunchOverride
        }
        return true
    }

    private func markDraftChanged(_ kind: CompatibilitySteamLaunchOptionKindV1) {
        fieldProvenance[kind] = .oneLaunchOverride
        sessionCoordinator.clearCompletedSession()
        compatibilityStatus = nil
    }

    private func setAllUserProvenance(
        _ provenance: CompatibilityResolvedValueProvenanceV1
    ) {
        for descriptor in selectedRecipe.orderedOptionDescriptors {
            fieldProvenance[descriptor.kind] = descriptor.kind == .automaticProcessPolicies
                ? .automaticRequired
                : provenance
        }
    }

    private func currentPreferencePayload()
        throws -> CompatibilitySteamLaunchPreferencePayloadV1
    {
        try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: selectedRecipe.identity,
            selections: draftSelections
        )
    }

    @discardableResult
    private func persistCurrentDraft()
        throws -> CompatibilitySteamLaunchPreferenceEnvelopeV1
    {
        let payload = try currentPreferencePayload()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(
            container: modelContext.container
        )
        let stored = try repository.save(
            payload,
            expectedSourceVersion: savedEnvelope?.sourceVersion
        )
        savedEnvelope = stored
        draftSelections = stored.payload.selections
        setAllUserProvenance(.savedPreference)
        mustReloadAfterConflict = false
        isPersistenceBlocked = false
        compatibilityDraftSaveFailed = false
        return stored
    }

    private func saveDraftFromAction() {
        guard !draftControlsAreDisabled else { return }
        if isPersistenceBlocked {
            let message = appState.localized(
                "저장된 호환성 환경설정을 초기화한 뒤 다시 저장하세요."
            )
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: message
            )
            let notice = appState.setNotice(message, kind: .warning)
            clearTaskLater(notice.id)
            return
        }
        if let selectedRendererRuntimeBlocker {
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: selectedRendererRuntimeBlocker
            )
            let notice = appState.setNotice(
                selectedRendererRuntimeBlocker,
                kind: .warning
            )
            clearTaskLater(notice.id)
            return
        }
        if let unsupported = selectedRecipe.orderedOptionDescriptors.first(where: {
            !isSupportedBySelectedRecipe($0.kind)
        }) {
            let message = appState.localizedFormat(
                "지원되지 않는 프로필 옵션이 있습니다: %@. 프로필 권장값을 복원한 뒤 저장하세요.",
                appState.localized(optionTitle(unsupported.kind))
            )
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: message
            )
            let notice = appState.setNotice(message, kind: .warning)
            clearTaskLater(notice.id)
            return
        }
        appState.setNotice(
            appState.localized("호환성 환경설정을 저장하는 중입니다."),
            kind: .progress
        )
        do {
            let stored = try persistCurrentDraft()
            let successMessage = appState.localizedFormat(
                "호환성 환경설정을 저장했습니다. 세대: %lld",
                stored.generation
            )
            compatibilityStatus = CompatibilityStatusPresentation(
                .success,
                message: successMessage
            )
            let notice = appState.setNotice(
                successMessage,
                kind: .success
            )
            clearTaskLater(notice.id)
        } catch {
            presentPersistenceError(error)
        }
    }

    private func saveAndPrepareSteamSession() {
        let availability = compatibilityLaunchAvailability
        guard availability.isAvailable else {
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: availability.message
            )
            return
        }
        guard manifestRootReadiness == .ready,
              let unresolvedManifestRootBookmark,
              let runtimeExecutableBookmark else {
            compatibilityStatus = CompatibilityStatusPresentation(
                .failure,
                message: appState.localized(
                    "Steam 실행에 필요한 매니페스트 루트 또는 관리 Runtime 권한이 준비되지 않았습니다."
                )
            )
            return
        }

        compatibilityStatus = CompatibilityStatusPresentation(
            .progress,
            message: appState.localized(
                "루트 권한과 런타임 제공자 기능을 확인하는 중입니다."
            )
        )
        let recipe = selectedRecipe
        let oneLaunchOverride = currentOneLaunchOverride()
        let currentSavedPreference = savedEnvelope
        let currentDraftIsPersisted = compatibilityDraftIsPersisted
        let displaySelections = draftSelections
        let displayFieldProvenance = fieldProvenance
        let authorizationProvider = manifestRootAuthorizationProvider
        let providerFactory = runtimeProviderFactory
        let navigationSessionCoordinator = sessionCoordinator
        Task { @MainActor in
            do {
                let context = try SteamManagerCompatibilityLaunchContextV1(
                    runtimeExecutableBookmark: runtimeExecutableBookmark,
                    steamClientLanguage: appState.effectiveSteamClientLanguage
                )
                let preparation = try await navigationSessionCoordinator.prepareSteamSession(
                    recipe: recipe,
                    unresolvedManifestRootBookmark: unresolvedManifestRootBookmark,
                    savedPreference: currentSavedPreference,
                    oneLaunchOverride: oneLaunchOverride,
                    displaySelections: displaySelections,
                    displayFieldProvenance: displayFieldProvenance,
                    runtimeContext: context,
                    manifestRootAuthorizationProvider: authorizationProvider,
                    runtimeProviderFactory: providerFactory
                )
                if currentDraftIsPersisted, let currentSavedPreference {
                    navigationSessionCoordinator.recordPersistedPreference(
                        currentSavedPreference
                    )
                }
                compatibilityStatus = CompatibilityStatusPresentation(
                    .success,
                    message: currentDraftIsPersisted &&
                        currentSavedPreference != nil
                        ? appState.localizedFormat(
                            "Steam 세션 적용 영수증 %@을 확인했습니다. 저장된 환경설정 세대: %lld",
                            preparation.receipt.receiptID,
                            currentSavedPreference?.generation ?? 0
                        )
                        : appState.localizedFormat(
                            "Steam 세션 적용 영수증 %@을 확인했습니다. 저장되지 않은 현재 초안을 이번 실행에 적용했습니다.",
                            preparation.receipt.receiptID
                        )
                )
            } catch {
                // The draft and the previously persisted envelope remain intact.
                presentCompatibilityFailure(
                    error,
                    message: appState.localizedError(error)
                )
            }
        }
    }

    private func completeSteamSession() {
        guard hasActiveSession else { return }
        guard !appState.isSteamLaunchInProgress,
              !sessionCoordinator.isStandardSteamLaunchReserved else {
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: appState.localized("Steam 실행이 이미 진행 중입니다.")
            )
            return
        }
        let navigationSessionCoordinator = sessionCoordinator
        compatibilityStatus = CompatibilityStatusPresentation(
            .progress,
            message: appState.localized(
                "관리 Wine 프로세스 종료와 기준 상태 복원을 확인하는 중입니다."
            )
        )
        Task { @MainActor in
            do {
                let completedPreparation = try await navigationSessionCoordinator
                    .completeSteamSession()
                compatibilityStatus = CompatibilityStatusPresentation(
                    .success,
                    message: appState.localizedFormat(
                        "Steam 세션 %@의 관리 프로세스 종료와 기준 상태 복원을 확인했습니다.",
                        completedPreparation.receipt.receiptID
                    )
                )
                await prepareApprovedLaunchInputsIfAvailable()
            } catch {
                presentCompatibilityFailure(
                    error,
                    message: appState.localizedFormat(
                        "Steam 세션을 아직 완료하지 못했습니다: %@",
                        appState.localizedError(error)
                    )
                )
            }
        }
    }

    private func currentOneLaunchOverride()
        -> CompatibilitySteamLaunchOneLaunchOverrideV1
    {
        var override = CompatibilitySteamLaunchOneLaunchOverrideV1(
            identity: selectedRecipe.identity
        )
        override.graphicsBackend = draftSelections.graphicsBackend
        override.networkPolicy = draftSelections.networkPolicy
        override.audioInputPolicy = draftSelections.audioInputPolicy
        override.synchronizationPolicy = draftSelections.synchronizationPolicy
        override.videoMemoryPolicy = draftSelections.videoMemoryPolicy
        override.frameGenerationConfiguration =
            draftSelections.frameGenerationConfiguration
        override.gameModeEnabled = draftSelections.gameModeEnabled
        override.heapZeroMemoryEnabled = draftSelections.heapZeroMemoryEnabled
        override.fpsCursorPolicy = draftSelections.fpsCursorPolicy
        override.controllerPolicy = draftSelections.controllerPolicy
        override.keyboardMapping = draftSelections.keyboardMapping
        return override
    }

    private func presentPostLaunchPersistenceError(
        _ error: Error,
        receiptID: String
    ) {
        if let persistenceError = error as? SteamLaunchConfigurationPersistenceError,
           case .writeConflict = persistenceError {
            mustReloadAfterConflict = true
        }
        let message = appState.localizedFormat(
            "Steam 세션은 영수증 %@으로 적용됐지만 환경설정 저장에는 실패했습니다. 현재 초안과 이전 저장 값은 유지됩니다: %@",
            receiptID,
            appState.localizedError(error)
        )
        compatibilityStatus = CompatibilityStatusPresentation(
            .warning,
            message: message,
            logURL: diagnosticLogURL(for: error)
        )
        let notice = appState.setNotice(message, kind: .warning)
        clearTaskLater(notice.id)
    }

    private func presentPersistenceError(_ error: Error) {
        compatibilityDraftSaveFailed = true
        if let persistenceError = error as? SteamLaunchConfigurationPersistenceError,
           case .writeConflict = persistenceError {
            mustReloadAfterConflict = true
            let message = appState.localized(
                "다른 편집기가 이 프로필을 먼저 저장했습니다. 현재 초안은 유지됩니다. 최신 저장 값을 다시 불러온 뒤 다시 시도하세요."
            )
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: message,
                logURL: diagnosticLogURL(for: error)
            )
            let notice = appState.setNotice(message, kind: .warning)
            clearTaskLater(notice.id)
            return
        }
        let notice = presentCompatibilityFailure(
            error,
            message: appState.localizedFormat(
                "호환성 환경설정을 저장하지 못했습니다: %@",
                appState.localizedError(error)
            )
        )
        clearTaskLater(notice.id)
    }

    private func handleManifestRootSelection(
        _ result: Result<[URL], Error>
    ) {
        do {
            guard let url = try result.get().first else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                    "selection-empty"
                )
            }
            guard url.startAccessingSecurityScopedResource() else {
                throw CompatibilityManifestRootAuthorizationErrorV1
                    .securityScopeDenied
            }
            unresolvedManifestRootBookmark = nil
            manifestRootReadiness = .validating
            manifestRootDisplayName = url.lastPathComponent.isEmpty
                ? appState.localized("Steam 매니페스트 루트")
                : url.lastPathComponent
            manifestRootWasAutoSelected = false
            approvedManifestAutoSelectionFailure = nil
            sessionCoordinator.clearCompletedSession()
            compatibilityStatus = nil
            let preparationService = manifestRootPreparationService
            let expectedRecipeID = selectedRecipeID
            Task { @MainActor in
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let prepared = try await preparationService.prepareSelectedRoot(
                        url,
                        requiresSecurityScope: false
                    )
                    try Task.checkCancellation()
                    guard selectedRecipeID == expectedRecipeID else { return }
                    unresolvedManifestRootBookmark = prepared
                    manifestRootReadiness = .ready
                } catch is CancellationError {
                    return
                } catch {
                    guard selectedRecipeID == expectedRecipeID else { return }
                    failManifestRootPreparation(
                        error,
                        message: appState.localizedFormat(
                            "매니페스트 루트 권한을 만들지 못했습니다: %@",
                            appState.localizedError(error)
                        )
                    )
                }
            }
        } catch {
            failManifestRootPreparation(
                error,
                message: appState.localizedFormat(
                    "매니페스트 루트 권한을 만들지 못했습니다: %@",
                    appState.localizedError(error)
                )
            )
        }
    }

    private func prepareApprovedLaunchInputsIfAvailable() async {
        guard !isPreparingSession, !hasActiveSession else { return }
        if unresolvedManifestRootBookmark == nil || manifestRootWasAutoSelected {
            await autoSelectExactApprovedManifestBookmark()
        }
        prepareManagedRuntimeAuthorization()
    }

    private func autoSelectExactApprovedManifestBookmark() async {
        guard exactApprovedManifestRecords.count == 1,
              let record = exactApprovedManifestRecords.first else {
            if manifestRootWasAutoSelected {
                unresolvedManifestRootBookmark = nil
                manifestRootDisplayName = nil
                manifestRootWasAutoSelected = false
            }
            manifestRootReadiness = .missing
            approvedManifestAutoSelectionFailure = nil
            return
        }

        let matchingMounts = CompatibilityManifestMountSelectionPolicy
            .matchingCandidates(
                libraryPath: record.libraryPath,
                candidates: canonicalManifestMountCandidates
            )
        guard matchingMounts.count == 1, let mount = matchingMounts.first else {
            unresolvedManifestRootBookmark = nil
            manifestRootDisplayName = nil
            manifestRootWasAutoSelected = false
            manifestRootReadiness = .missing
            approvedManifestAutoSelectionFailure = matchingMounts.count > 1
                ? appState.localized(
                    "이 App ID와 일치하는 승인된 SteamLibrary 북마크가 여러 개라 자동으로 추측하지 않았습니다. 매니페스트 루트를 직접 선택하세요."
                )
                : nil
            return
        }

        let wasRecovering = approvedManifestAutoSelectionFailure != nil
        manifestRootReadiness = .validating
        unresolvedManifestRootBookmark = nil
        manifestRootDisplayName = "\(record.name) · App ID \(record.steamAppId)"
        manifestRootWasAutoSelected = true
        let expectedRecipeID = selectedRecipeID
        do {
            let prepared = try await manifestRootPreparationService.prepareLibraryRoot(
                libraryPath: record.libraryPath,
                mount: mount
            )
            try Task.checkCancellation()
            guard selectedRecipeID == expectedRecipeID else { return }
            unresolvedManifestRootBookmark = prepared
            manifestRootReadiness = .ready
            approvedManifestAutoSelectionFailure = nil
            sessionCoordinator.clearCompletedSession()
            if wasRecovering {
                compatibilityStatus = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard selectedRecipeID == expectedRecipeID else { return }
            let message = appState.localizedFormat(
                "승인된 SteamLibrary 북마크를 자동 준비하지 못했습니다: %@ 매니페스트 루트를 직접 선택하세요.",
                appState.localizedError(error)
            )
            approvedManifestAutoSelectionFailure = message
            failManifestRootPreparation(error, message: message)
        }
    }

    private var manifestRootPreparationService:
        CompatibilityManifestRootPreparationService
    {
        CompatibilityManifestRootPreparationService(
            authorizationProvider: manifestRootAuthorizationProvider
        )
    }

    private func failManifestRootPreparation(
        _ error: Error,
        message: String
    ) {
        unresolvedManifestRootBookmark = nil
        manifestRootDisplayName = nil
        manifestRootWasAutoSelected = false
        manifestRootReadiness = .failed(reason: message)
        presentCompatibilityFailure(error, message: message)
    }

    private func prepareManagedRuntimeAuthorization() {
        guard !isPreparingSession, !hasActiveSession else { return }
        guard let runtimeExecutable = appState.runtimeExecutableURL,
              ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(
                runtimeExecutable
              ) else {
            runtimeExecutableBookmark = nil
            runtimeExecutableDisplayName = nil
            managedRuntimeAuthorizationFailure = appState.localized(
                "검증된 관리 Runtime을 사용할 수 없습니다. 관리 Runtime을 다시 확인하세요."
            )
            compatibilityStatus = CompatibilityStatusPresentation(
                .warning,
                message: missingManagedRuntimeRequirementReason
            )
            return
        }

        let wasRecovering = managedRuntimeAuthorizationFailure != nil
        do {
            runtimeExecutableBookmark = try SecurityScopedBookmarkPolicy.readOnlyBookmarkData(
                for: runtimeExecutable
            )
            runtimeExecutableDisplayName = WindowsRuntimeDisplayName.displayName(
                for: runtimeExecutable
            )
            managedRuntimeAuthorizationFailure = nil
            sessionCoordinator.clearCompletedSession()
            if wasRecovering {
                compatibilityStatus = nil
            }
        } catch {
            runtimeExecutableBookmark = nil
            runtimeExecutableDisplayName = nil
            let message = appState.localizedFormat(
                "관리 ForgePlay Runtime 권한을 자동 준비하지 못했습니다: %@ 관리 Runtime을 다시 확인하세요.",
                appState.localizedError(error)
            )
            managedRuntimeAuthorizationFailure = message
            presentCompatibilityFailure(
                error,
                message: message
            )
        }
    }

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            appState.clearNotice(id: noticeID)
        }
    }
}
