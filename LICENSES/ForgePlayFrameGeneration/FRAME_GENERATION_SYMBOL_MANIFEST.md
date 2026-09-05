# ForgePlay Frame Generation mixed-file symbol manifest

Copyright (C) 2026 Facta-Leopard

License: `GPL-3.0-only`, with the additional terms in section 7 of
`FRAME_GENERATION_LICENSE_SCOPE.md`.

Base: `1.2_Release`, commit
`72a2598c99f0b649d1384ed0763a00037f5d1d2e`.

This is an external notice: it does not modify the files below. Symbols and
line anchors refer to the exact base commit, not to shifted lines in a later
preparation tree. Unless an entry expressly identifies a complete
declaration, only the Frame Generation-specific fields, parameters,
arguments, validation, branches, serialization, assertions, and associated
copy described in that entry are covered. General-purpose surrounding code
is not newly designated merely because it shares the containing declaration.
The base commit is the identity binding for these mixed sections; the
dedicated file hashes are in `FRAME_GENERATION_FILE_LICENSES.json`.

## Application model and launch configuration

### `Sources/ForgePlay/Models/DomainModels.swift`

- Complete `SteamRendererCurrentReleasePolicy.supportsFrameGeneration`
  (line 267) and `SteamRendererPolicySelection.supportsD3DMetalFrameGeneration`
  (line 323).
- `SteamPrelaunchCompatibilitySelection.frameGenerationConfiguration`, its
  initializer parameter/assignment, and forwarding in
  `withWineChildPOSIXLocalePolicy` (lines 429–469).

### `Sources/ForgePlay/LaunchConfiguration/SteamLaunchConfigurationDomain.swift`

- `SteamGraphicsBackendIdentifier.supportsD3DMetalFrameGeneration` and
  `supportsCurrentReleaseFrameGeneration` (lines 261–266).
- In `SteamLaunchConfigurationSnapshot`: Frame Generation schema-version and
  canonical-header/field-name constants (lines 505–630),
  `frameGenerationConfiguration`, its initializer/default handling,
  Frame Generation validation and canonical serialization/deserialization
  branches, and the complete `currentFrameGenerationConfiguration` and
  `migratedFrameGenerationConfiguration` helpers (lines 652–1131).
- Legacy renderer-scoped Frame Generation mode migration fields in that
  snapshot remain covered as Frame Generation compatibility logic; unrelated
  snapshot identifiers, fields, and canonical encoding are not designated.

### `Sources/ForgePlay/LaunchConfiguration/SteamLaunchConfigurationProductAdapter.swift`

- `SteamLaunchConfigurationProductSelection.frameGenerationConfiguration`
  and its initializer parameter/assignment (lines 5–28).
- Its forwarding in `SteamLaunchConfigurationProductAdapter.standardSnapshot`
  and `productSelection` (lines 81 and 99).

### `Sources/ForgePlay/LaunchConfiguration/SteamCompatibilityLaunchProfileV1.swift`

- The `frameGenerationConfiguration` field/initialization/validation in
  `CompatibilitySteamLaunchUserSelectionsV1` (lines 122–163).
- The `frameGenerationTargetFrameRates` field/initialization/validation in
  `CompatibilitySteamLaunchSupportedOptionsV1` (lines 178–218).
- `CompatibilitySteamLaunchOptionKindV1.frameGeneration` (line 261).
- Frame Generation defaults, placement, and supported/recommended-target
  validation in `SteamCompatibilityLaunchProfileRecipeV1` (lines 354–475).
- Frame Generation and Frame Check canonical fields, encoding, decoding and
  legacy-off migration in `CompatibilitySteamLaunchPreferencePayloadV1`
  (lines 563–792), and the forwarding in
  `SteamCompatibilitySnapshotV1MigrationAdapter.preference` (line 952).

### `Sources/ForgePlay/LaunchConfiguration/SteamCompatibilityLaunchRuntimeV1.swift`

- `CompatibilitySteamLaunchRuntimeCapabilitiesV1.supportedFrameGenerationTargetFrameRates`
  and its initialization/validation/recipe projection (lines 387–466).
- `CompatibilitySteamLaunchOneLaunchOverrideV1.frameGenerationConfiguration`
  and `ResolvedCompatibilitySteamLaunchSnapshotV1.frameGenerationConfiguration`
  (lines 487 and 506).
- Frame Generation validation and canonical value/provenance fields in
  `ResolvedCompatibilityLaunchRequestV1` (lines 566–652).
- Frame Generation-specific initial/recommended/persisted/one-launch value
  resolution, forwarding and capability/recipe validation statements
  (lines 723–941).

### `Sources/ForgePlay/LaunchConfiguration/SteamManagerCompatibilityLaunchRuntimeProviderV1.swift`

- `SteamManagerCompatibilityLaunchProjectionV1.frameGenerationConfiguration`,
  its initialization, renderer-support validation and snapshot projection
  (lines 33–146).
- Frame Generation target capability projection (lines 723–724).
- Complete `frameGenerationProjectionMatches` (lines 1373–1389).

### `Sources/ForgePlay/LaunchConfiguration/SteamCompatibilityLaunchPreferencePersistenceV1.swift`

- The `frameGenerationConfiguration` forwarding statement in
  `CompatibilitySteamLaunchPreferencePayloadV1.snapshotV1Projection`
  (line 61).

## Execution and observation

### `Sources/ForgePlay/Services/SafeProcessRunner.swift`

- `ManagedWineLaunchEnvironmentProjection.frameGenerationEnabled`,
  `frameGenerationTargetFrameRate`, `frameCheckEnabled`, and
  `frameGenerationProxyPath` (lines 117–120).
- Frame Generation requested/status diagnostics, validation, off/fallback
  handling and launch-environment arguments in the Steam launch branch of
  `makeCommandSpec(for:)` (lines 8897–9084).
- Frame Generation parameters/validation/forwarding/observation-path setup in
  `launchSteamBaseEnvironment`, `steamGameRendererPolicyEnvironment`, and
  `d3dMetalSteamGameRendererPolicyEnvironment` (lines 9929–10187).
- Complete `d3dMetalFrameGenerationProxyURL` (lines 10256–10265).
- Frame Generation environment construction/removal in
  `exactSteamGameRendererPolicyEnvironment` (lines 10435 and 10558–10577);
  projection readback in `managedWineLaunchEnvironmentProjection`
  (lines 10925–10939).
- Complete `frameGenerationEnvironmentKeys` (lines 12688–12694) and its
  inclusion in the protected managed-renderer environment key set (line 12715).

### `Sources/ForgePlay/Services/SteamManager.swift`

- Frame Generation parameters, validation, fallback to off, launch forwarding
  and status diagnostics in `launchSteam` / `launchSteamUnfinalized`
  (Frame Generation integration through line 2762).
- Complete `SteamD3DMetalFrameGenerationState`,
  `SteamD3DMetalFrameGenerationPipelineBounds`, and
  `SteamD3DMetalFrameGenerationObservation` declarations (lines 8415–8687).
- `SteamProcessObservationReadResult.d3dMetalFrameGenerationObservations`.
- `SteamProcessCreationObservationLog.d3dMetalFrameGenerationRecordPrefix`,
  all `d3dMetalFrameGeneration*MetricNames` constants,
  `d3dMetalFrameGenerationObservations`, and
  `parseD3DMetalFrameGenerationObservations` (lines 8734–9006).
- The Frame Generation record identification, capacity, metric validation,
  parsing, observation construction and result wiring in
  `SteamProcessCreationObservationLog.parseResult` (lines 9194–10360).
- Frame Generation observation correlation, activation results and diagnostic
  output in `SteamGameLaunchDiagnosticAnalyzer` (lines 10769–10894 and the
  following Frame Generation diagnostic construction); complete
  `correlatedD3DMetalFrameGenerationObservations` and
  `frameGenerationExecutableSHA256` (lines 11530 and 11909).

### `Sources/ForgePlay/Services/SteamPrefixService.swift`

- Frame Generation parameter and forwarding in both `launchSteam` overloads;
  validation/disable-to-off diagnostics and forwarding of
  `effectiveFrameGenerationConfiguration` (lines 796–936).
- Compatibility projection forwarding of `frameGenerationConfiguration`
  (line 1229).

## Existing UI integration (notice only; no UI changes)

### `Sources/ForgePlay/UI/SteamLaunchView.swift`

- `frameGenerationConfigurationForNextSteamLaunch`, active-session Frame
  Generation state, and their initialization, persistence, reset, validation
  and launch/snapshot forwarding statements.
- Complete `frameGenerationControl`, `frameGenerationTargetButtons`, and
  `frameGenerationDraftIsValid` (lines 1007, 1128 and 1452).
- Frame Generation configuration/status presentation and the associated
  renderer-support and Frame Check branches, localized copy, and controls
  (including lines 906–1174).
- Frame Generation-only session restoration/reset and launch argument
  forwarding (lines 1529–1567, 1698–1699, 3114–3116, 3173–3174,
  and 3257–3258).

### `Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift`

- `.frameGeneration` option inclusion/routing (lines 511 and 615–616),
  renderer-change normalization (lines 1205–1208), and complete
  `compatibilityFrameGenerationControl` /
  `compatibilityFrameGenerationTargetButtons` (lines 1214 and 1333).
- `.frameGeneration` label, value/provenance, support validation and
  recommendation-reset branches (lines 1567–1649 and 2083–2085).
- Frame Generation-only normalization/provenance and one-launch override
  projection (lines 2117–2120 and 2370–2371).

## Mixed regression tests

Only Frame Generation/Frame Check fixtures and assertions, and their
necessary setup inside the listed tests, are designated; tests' unrelated
responsibilities remain outside this new assignment.

- `Tests/ForgePlayTests/LocalizationTests.swift`:
  `testFrameGenerationBetaAndNVIDIACopyHasEightLocaleParity` and the Frame
  Generation layout assertions in
  `testSteamLaunchTopLevelLayoutUsesSteamLaunchPanelsInsteadOfSplitGameDetail`.
- `Tests/ForgePlayTests/SteamLaunchConfigurationPersistenceTests.swift`:
  Frame Generation migration/save/reload checks in
  `testDeployedSchema4SingletonMigratesThenSavesAndReloads`.
- `Tests/ForgePlayTests/SteamLaunchConfigurationTests.swift`:
  `testStandardFrameGenerationAndFrameCheckRoundTrip`,
  `testLegacyCanonicalPayloadMigratesWithFrameGenerationOff`,
  `testDeployedFrameGenerationSchemasAndInterimSchema2MigrateToSchema5`, and
  Frame Generation field-order checks in
  `testCanonicalPayloadRoundTripsAndUsesExactFieldOrder`.
- `Tests/ForgePlayTests/SafeProcessRunnerTests.swift`:
  `testFrameGenerationRequestUsesProductionProxyPathWithoutPrelaunchFileGate`,
  `testFrameGenerationWithFrameCheckOffProjectsExplicitZero`,
  `testFrameGenerationRejectsHiddenStandardD3DMetalSelection`,
  `testFrameGenerationOffLeavesOriginalD3DMetalPathWithoutProxyEnvironment`,
  and Frame Generation environment/fallback fixtures and assertions in
  `testLaunchSteamD3DMetalKeepsGameRendererOutOfSteamClientEnvironment`,
  `testSteamCommandSpecFallsBackFromNVIDIAToPlainD3DMetalThenBaseWine`, and
  `assertGameModePreparationFailureDoesNotLaunchWine`.
- `Tests/ForgePlayTests/SteamCompatibilityLaunchProfileV1Tests.swift`:
  `testCurrentReleaseFrameGenerationResolvesOnlyForNVIDIAD3DMetal`,
  `testPreferenceCanonicalRoundTripPreservesFrameGenerationAndFrameCheck`,
  and Frame Generation default/normalization assertions in
  `testBuiltInRecipeIdentityDefaultsAndOrderedDescriptors` and
  `testHiddenD3DMetalPreferenceNormalizesWithoutDroppingEnvelope`.

`Tests/ForgePlayTests/GameModeHostCapabilityTests.swift` and the Game Mode
host's existing covered files retain their existing whole-file Game Mode GPL
assignment; no new whole-file assignment is needed for their Frame Generation
environment-preservation integration.

## Build and verification sections

- `project.yml`: the ForgePlay target dependency embedding
  `D3DMetalFrameGenerationProxy` at Frameworks (lines 85–90), and the complete
  `D3DMetalFrameGenerationProxy` target (lines 213–235), including source,
  configuration and public Apple framework dependency declarations.
- `Config/ForgePlayPublicDistributionSourceGraph.json`: only the entries for
  `Config/ForgePlayD3DMetalFrameGenerationProxy.xcconfig` and the five
  `Native/D3DMetalFrameGenerationProxy/` files (base lines 14 and 24–28).
- `Scripts/package-forgeplay-runtime.sh`: complete
  `verify_frame_generation_source_contract` and
  `verify_frame_generation_runtime_modules`; their call sites; the Frame
  Generation environment-key and patch-contract checks, and Frame Generation
  clauses in generated Runtime notices. General Wine packaging is not newly
  designated by these entries.
- `Scripts/verify-bundled-runtime-capability.sh`: Frame Generation key mapping
  and consumption checks for kernelbase, ntdll and winemac (lines 963–994).
- `Scripts/test-wine-game-renderer-d3dmetal.sh`: the five Frame Generation /
  Frame Check unset environment entries (lines 412–416).

Verification or packaging preparation may change unrelated sections of these
mixed build files. Such edits do not change this exact-base assignment; the
conveyed source inventory must identify those edits separately. A change to
a covered section requires review of this symbol assignment and its identity.

## Explicit exclusions and existing assignments

The `forgeplay_framegen_*` / `framegen_*` Wine-side declarations in
`wine-11.12-forgeplay-metal-window-surface-contract.patch` and the environment
mapping/propagation statements in
`wine-11.12-steam-session-compatibility-controls.patch` are excluded from this
GPL designation. Their LGPL-derived source-copy boundary, exact patch hashes,
and upstream notices remain intact.

The existing Game Mode symbol/file manifests remain authoritative for their
own scope, including overlap in mixed files. No Apple binary, D3DMetal
implementation, MetalFX implementation, third-party renderer, artwork, font,
trademark, unrelated target, or general-purpose application responsibility is
newly licensed by this manifest. These source-copy boundaries do not exempt a
conveyed combined work from GPLv3 obligations.
