# ForgePlay Game Mode mixed-file symbol manifest

Copyright (C) 2026 Facta-Leopard

This manifest identifies the `GPL-3.0-only` Game Mode declarations and
integration statements that share files with unrelated ForgePlay
responsibilities. It must be read together with
`GAME_MODE_LICENSE_SCOPE.md` and `GAME_MODE_FILE_LICENSES.json`.

The Git release tag and commit containing this manifest bind it to the exact
source tree conveyed for that release. A public binary must not be built from
an uncommitted working tree: changing any covered declaration requires the
manifest and the release commit to be reviewed together.

This manifest does not apply `GPL-3.0-only` to unrelated declarations merely
because they occur in the same file.

## `Sources/ForgePlay/Services/SafeProcessRunner.swift`

The covered declarations and integration statements are:

- the `gameModePolicy` associated value of `RunnerAction.launchSteam`;
- `SafeProcessRunner.GameModeSteamChildSelectionResolver`;
- `SafeProcessRunner.GameModeHostLaunchRecord`;
- `SafeProcessRunner.GameModeHostEvidenceRecord`;
- `SafeProcessRunner.GameModeHostEvidenceProcessIdentity`;
- the Game Mode resolver and launch-record stored properties and initializer
  wiring;
- the `registerGameModeHostLaunch` call made after command preparation;
- Game Mode launch-record cleanup in `clearManagedProcessLaunchRecords`;
- inclusion of the fixed host in `allowedManagedWineExecutables`;
- `registerGameModeHostLaunch`;
- `registeredGameModeHostProcessInspection`;
- `gameModeHostEvidenceProcessIDs`;
- `gameModeHostEvidenceProcessIdentities`;
- the Game Mode Host process-ID union in
  `managedProcessIDsHoldingOpenFiles`;
- the `.standard` and `.experimentalRequiredHost` Game Mode policy branch in
  `makeCommandSpec(for:)`;
- the `gameModeHost*` fields emitted by
  `runtimeCompatibilityDiagnostics(from:)`.

## `Sources/ForgePlay/UI/SteamLaunchView.swift`

The covered declarations and integration statements are:

- `ActiveSteamSessionConfiguration.gameModePolicy`;
- `isExperimentalGameModeEnabledForNextLaunch`;
- the Game Mode controls and state text in `steamLaunchPanel`;
- `experimentalGameModeControl`;
- `gameModeStateLabel`;
- the `gameModePolicy` parameter and Game Mode-specific statements in
  `launchSteam(rendererPolicySelection:gameModePolicy:)`, including policy
  forwarding, session-state persistence, reset behavior, and the verification
  notice.

## `Sources/ForgePlay/Services/SteamManager.swift`

The covered code is:

- the `gameModePolicy` parameter and its pass-through to
  `RunnerAction.launchSteam` in `launchSteam` and `launchSteamUnfinalized`,
  including the single operational dispatch and non-destructive startup
  observation;
- `GameModeHostLaunchAdmission`, the `gameModeHostLaunchAdmission` stored
  property and initializer wiring, and `requireGameModeHostLaunchAdmission`;
- the required-host admission calls at both `launchSteam` boundaries that run
  before prefix lease acquisition or compatibility and renderer mutation.

## `Sources/ForgePlay/Services/SteamPrefixService.swift`

The covered code is the `gameModePolicy` parameter and its pass-through in
both `launchSteam` overloads.

## `Sources/ForgePlay/Services/SupportBundleService.swift`

The covered code is the `GameModeHostCoordinationPaths` evidence-root
resolution and the bounded, redacted `game-mode-process-host` evidence copy
performed by `createSupportBundle`.

## `Sources/ForgePlay/App/AppServices.swift`

The covered code is:

- creation and shared injection of `ManagedWineSessionRegistry` into
  `SafeProcessRunner`;
- the post-shutdown `PrefixExecutionLease.acquireExclusiveMutation` proof in
  `executeAppTerminationSteamShutdown` that no Game Mode Host retains a shared
  prefix lease.

## `Sources/ForgePlay/Services/PrefixExecutionLease.swift`

The covered code is the shared-execution lease behavior used by the native
Game Mode Host:

- `PrefixExecutionLeaseMode.sharedExecution`;
- `acquireSharedExecution`;
- `transitionToSharedExecution`;
- `transitionToExclusiveMutation`;
- the shared-lock acquisition, metadata rebind, upgrade, and recovery
  statements in `acquire` and `transition(to:)`.

General exclusive prefix coordination that is independent of the Game Mode
Host is not newly designated as Game Mode source by this entry.

## `project.yml`

The covered configuration is:

- the ForgePlay target dependency that embeds `GameModeProcessHost` at
  `Contents/Helpers`;
- the complete `GameModeProcessHost` target;
- its source list, frameworks, per-configuration xcconfig selection, and
  Runtime-identity `preBuildScripts` step.

Other targets, schemes, resources, and build settings in `project.yml` are
outside this source-license designation unless another notice says otherwise.
