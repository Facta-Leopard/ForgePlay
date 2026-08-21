import XCTest
@testable import ForgePlay

final class AppStartupDestinationResolverTests: XCTestCase {
    func testCompatibilityCatalogUsesExplicitGameDatabaseTitle() {
        XCTAssertEqual(
            AppSection.compatibilityCatalog.title,
            "게임 호환성 DB"
        )
    }

    private var launchableReadiness: SetupReadiness {
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        return SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: prefix.appending(
                path: "drive_c/Program Files (x86)/Steam/steam.exe"
            ),
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .ok,
                userMessage: "ready",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            )
        )
    }

    func testLaunchableDashboardRoutesToSteamLaunchBeforeAuthenticationVerification() {
        let readiness = launchableReadiness
        XCTAssertTrue(readiness.canAttemptWindowsSteamLaunch)
        XCTAssertFalse(readiness.hasUsableAuthenticatedSteamSession)

        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .dashboard,
                readiness: readiness
            ),
            .steamLaunch
        )
    }

    func testBlockedDashboardRoutesToSetup() {
        XCTAssertFalse(SetupReadiness.empty.canAttemptWindowsSteamLaunch)
        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .dashboard,
                readiness: .empty
            ),
            .setup
        )
    }

    func testExactPriorSessionRecoveryReturnsRestartedAppToSteamLaunch() {
        var readiness = launchableReadiness
        readiness.rendererInspection = SteamRendererPolicyInspection(
            selection: .d3dMetalNVIDIA,
            resolvedPolicy: .d3dMetal,
            status: .warning,
            userMessage: "automatic recovery pending",
            appliedModules: [],
            missingModules: [],
            mixedModules: [
                "system32/nvapi.dll",
                "system32/nvapi64.dll",
                "system32/nvngx.dll"
            ],
            recoveryKind: .automaticSessionRecovery
        )

        XCTAssertEqual(readiness.steamPrefixState, .rendererNeedsApply)
        XCTAssertTrue(readiness.canAttemptWindowsSteamLaunch)
        XCTAssertFalse(readiness.rendererInspection?.allowsRecoveryAction == true)
        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .dashboard,
                readiness: readiness
            ),
            .steamLaunch
        )
    }

    func testUnownedRendererRepairStillRoutesRestartedAppToSetup() {
        var readiness = launchableReadiness
        readiness.rendererInspection = SteamRendererPolicyInspection(
            selection: .d3dMetalNVIDIA,
            resolvedPolicy: .d3dMetal,
            status: .error,
            userMessage: "explicit repair required",
            appliedModules: [],
            missingModules: [],
            mixedModules: ["system32/foreign-dxgi.dll"],
            recoveryKind: .repairPolicy
        )

        XCTAssertEqual(readiness.steamPrefixState, .rendererNeedsRepair)
        XCTAssertFalse(readiness.canAttemptWindowsSteamLaunch)
        XCTAssertTrue(readiness.rendererInspection?.allowsRecoveryAction == true)
        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .dashboard,
                readiness: readiness
            ),
            .setup
        )
    }

    func testExplicitUserDestinationIsPreserved() {
        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .settings,
                readiness: launchableReadiness
            ),
            .settings
        )
    }

    func testAutomaticSetupTransitionsWhenSteamBecomesLaunchable() {
        XCTAssertEqual(
            AppStartupDestinationResolver.resolveLaunchabilityTransition(
                current: .setup,
                previousReadiness: .empty,
                readiness: launchableReadiness,
                ownsAutomaticSetupDestination: true
            ),
            .steamLaunch
        )
    }

    func testLaunchableTransitionPreservesUserSelectedDestination() {
        XCTAssertEqual(
            AppStartupDestinationResolver.resolveLaunchabilityTransition(
                current: .settings,
                previousReadiness: .empty,
                readiness: launchableReadiness,
                ownsAutomaticSetupDestination: true
            ),
            .settings
        )
        XCTAssertEqual(
            AppStartupDestinationResolver.resolveLaunchabilityTransition(
                current: .setup,
                previousReadiness: .empty,
                readiness: launchableReadiness,
                ownsAutomaticSetupDestination: false
            ),
            .setup
        )
    }

    func testAlreadyLaunchableRefreshDoesNotForceNavigation() {
        XCTAssertEqual(
            AppStartupDestinationResolver.resolveLaunchabilityTransition(
                current: .setup,
                previousReadiness: launchableReadiness,
                readiness: launchableReadiness,
                ownsAutomaticSetupDestination: true
            ),
            .setup
        )
    }
}
