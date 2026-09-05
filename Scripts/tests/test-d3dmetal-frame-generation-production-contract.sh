#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PROXY_SOURCE="$ROOT_DIR/Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m"
STATE_SOURCE="$ROOT_DIR/Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c"
STATE_HEADER="$ROOT_DIR/Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.h"
STATE_TEST_SOURCE="$ROOT_DIR/Tests/ForgePlayD3DMetalFrameGenerationProxyTests/state_machine_tests.c"
WINE_PATCH="$ROOT_DIR/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch"
COMPATIBILITY_PATCH="$ROOT_DIR/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-session-compatibility-controls.patch"
RUNNER_SOURCE="$ROOT_DIR/Sources/ForgePlay/Services/SafeProcessRunner.swift"
GAME_MODE_SOURCE="$ROOT_DIR/Sources/ForgePlay/Services/GameModeHostCapability.swift"
MANAGER_SOURCE="$ROOT_DIR/Sources/ForgePlay/Services/SteamManager.swift"
PROJECT_FILE="$ROOT_DIR/ForgePlay.xcodeproj/project.pbxproj"
PROXY_CONFIG="$ROOT_DIR/Config/ForgePlayD3DMetalFrameGenerationProxy.xcconfig"

git -C "$ROOT_DIR" apply --numstat "$WINE_PATCH" >/dev/null

python3 - \
  "$PROXY_SOURCE" \
  "$STATE_SOURCE" \
  "$STATE_HEADER" \
  "$WINE_PATCH" \
  "$COMPATIBILITY_PATCH" \
  "$RUNNER_SOURCE" \
  "$GAME_MODE_SOURCE" \
  "$MANAGER_SOURCE" \
  "$PROJECT_FILE" \
  "$PROXY_CONFIG" <<'PY'
import sys
import re
from pathlib import Path

proxy, state, header, wine_patch, compatibility_patch, runner, game_mode, manager, project, config = (
    Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"error: {message}")


def method_body(source: str, signature: str, following_signature: str) -> str:
    start = source.find(signature)
    end = source.find(following_signature, start + len(signature))
    require(start >= 0 and end > start, f"method boundary unavailable: {signature}")
    return source[start:end]


display_body = method_body(
    proxy,
    "- (void)metalDisplayLink:",
    "- (void)retireHeldOutputAfterActivation",
)
rebuild_body = method_body(
    proxy,
    "- (void)rebuildOutputSurfaceResettingState:",
    "- (void)sourceSurfaceConfigurationDidChange",
)
source_present_body = method_body(
    proxy,
    "- (void)sourceDrawableTicket:(uint64_t)ticketID\n"
    "             captureWasArmed:(BOOL)captureWasArmed\n"
    "         wasPresentedAtTime:(CFTimeInterval)presentedTime\n{",
    "- (void)sourceCaptureCommandBufferCompletedForTicket:(uint64_t)ticketID\n",
)
source_commit_body = method_body(
    proxy,
    "- (void)prepareSourceCaptureBeforeCommit:\n"
    "    (id<MTLCommandBuffer>)commandBuffer\n{",
    "- (void)sourceDrawableTicket:(uint64_t)ticketID\n",
)
source_completion_body = method_body(
    proxy,
    "- (void)sourceCaptureCommandBufferCompletedForTicket:(uint64_t)ticketID\n"
    "                                    surfaceGeneration:\n"
    "                                        (uint64_t)surfaceGeneration\n"
    "                                                 slot:(NSInteger)slot\n"
    "                                               status:(MTLCommandBufferStatus)status\n{",
    "- (void)acceptCapturedSlot:",
)
source_hook_body = method_body(
    proxy,
    "- (nullable id<CAMetalDrawable>)fp_frameGeneration_nextDrawable\n{",
    "@end\n\n@implementation FPD3DMetalFrameGenerationSession",
)
present_immediate_hook_body = method_body(
    proxy,
    "static void FPCommandBufferPresentDrawable(\n",
    "static void FPCommandBufferPresentDrawableAtTime(\n",
)
present_at_time_hook_body = method_body(
    proxy,
    "static void FPCommandBufferPresentDrawableAtTime(\n",
    "static void FPCommandBufferPresentDrawableAfterMinimumDuration(\n",
)
present_after_duration_hook_body = method_body(
    proxy,
    "static void FPCommandBufferPresentDrawableAfterMinimumDuration(\n",
    "static void FPCommandBufferCommit(id",
)
source_command_commit_hook_body = method_body(
    proxy,
    "static void FPCommandBufferCommit(id<MTLCommandBuffer> self, SEL selector)\n{",
    "static void FPInstallCommandBufferHooksForObject(\n",
)
session_init_body = method_body(
    proxy,
    "failureReasonCapacity:(size_t)failureReasonCapacity\n{",
    "- (void)activateSourceObservation",
)
demand_resource_prepare_body = method_body(
    proxy,
    "- (BOOL)prepareDemandMetalResourcesOnMain\n{",
    "- (void)releaseDemandMetalResourcesOnMain",
)
demand_resource_release_body = method_body(
    proxy,
    "- (void)releaseDemandMetalResourcesOnMain\n{",
    "- (nullable instancetype)initWithOwningMetalView:",
)
capture_priming_body = method_body(
    proxy,
    "- (void)scheduleCapturePrimingOutputSurface\n{",
    "- (void)rebuildOutputSurfaceResettingState:",
)
capture_ready_body = method_body(
    proxy,
    "- (void)acceptCapturedSlot:(NSInteger)slot\n"
    "             sourceSequence:(uint64_t)sourceSequence\n"
    "             presentedTime:(CFTimeInterval)presentedTime\n"
    "          surfaceGeneration:(uint64_t)surfaceGeneration\n{",
    "- (NSInteger)freeTextureSubmissionIndexLocked",
)
retire_body = method_body(
    proxy,
    "- (void)retireHeldOutputAfterActivation",
    "- (void)updateFrameCheckWithTelemetry:",
)
frame_check_body = method_body(
    proxy,
    "- (void)updateFrameCheckWithTelemetry:",
    "- (void)emitTelemetryForced:",
)
telemetry_body = method_body(
    proxy,
    "- (void)emitTelemetryForced:",
    "- (void)failWithReason:",
)
failure_body = method_body(
    proxy,
    "- (void)failWithReason:",
    "- (void)invalidate",
)
invalidate_body = method_body(
    proxy,
    "- (void)invalidate\n{",
    "- (void)dealloc",
)
dealloc_body = method_body(
    proxy,
    "- (void)dealloc",
    "@end\n\nstatic void *FPCreateSessionV1",
)
source_observation_state_body = method_body(
    state,
    "FPFrameGenerationSourceObservation FPFrameGenerationObserveSourcePresent(",
    "FPFrameGenerationCapturePlan FPFrameGenerationRecordCaptureReady(",
)
capture_ready_state_body = method_body(
    state,
    "FPFrameGenerationCapturePlan FPFrameGenerationRecordCaptureReady(",
    "bool FPFrameGenerationRecordCurrentReady(",
)
display_rebase_state_body = method_body(
    state,
    "void FPFrameGenerationRebaseDisplayTargetObservation(",
    "uint64_t FPFrameGenerationHandleLateDisplayUpdate(",
)
late_display_state_body = method_body(
    state,
    "uint64_t FPFrameGenerationHandleLateDisplayUpdate(",
    "void FPFrameGenerationRecordDisplayUpdate(",
)
display_update_state_body = method_body(
    state,
    "void FPFrameGenerationRecordDisplayUpdate(",
    "FPFrameGenerationDisplayCandidate FPFrameGenerationAcquireDisplayCandidate(",
)
proxy_create_body = method_body(
    proxy,
    "static void *FPCreateSessionV1(",
    "static void FPDestroySessionV1(",
)
wine_create_on_main_body = method_body(
    wine_patch,
    "static macdrv_metal_view framegen_view_create_metal_view_on_main_thread(",
    "static macdrv_metal_view framegen_view_create_metal_view(",
)
wine_create_wrapper_body = method_body(
    wine_patch,
    "static macdrv_metal_view framegen_view_create_metal_view(",
    "static macdrv_metal_layer framegen_view_get_metal_layer_on_main_thread(",
)
wine_get_layer_on_main_body = method_body(
    wine_patch,
    "static macdrv_metal_layer framegen_view_get_metal_layer_on_main_thread(",
    "static macdrv_metal_layer framegen_view_get_metal_layer(",
)
wine_get_layer_wrapper_body = method_body(
    wine_patch,
    "static macdrv_metal_layer framegen_view_get_metal_layer(",
    "static void framegen_view_release_metal_view_on_main_thread(",
)
wine_release_on_main_body = method_body(
    wine_patch,
    "static void framegen_view_release_metal_view_on_main_thread(",
    "static void framegen_view_release_metal_view(",
)
wine_release_wrapper_body = method_body(
    wine_patch,
    "static void framegen_view_release_metal_view(",
    "static void metal_surface_init_display_devices",
)

require(
    display_body.find("[commandBuffer commit]") <
    display_body.find("[drawable present]"),
    "CAMetalDisplayLink drawable must be presented only after its writer commits",
)
require("rebuildOutputSurfaceResettingState:" not in session_init_body and
        "_outputLayer =" not in session_init_body and
        "CAMetalDisplayLink" not in session_init_body and
        "createCaptureTexturePoolForDevice:" not in session_init_body and
        "newCommandQueueWithMaxCommandBufferCount:" not in session_init_body and
        "newLibraryWithSource:" not in session_init_body and
        "compositionPipelineForPixelFormat:" not in session_init_body and
        "_compositionPipelines =" not in session_init_body,
        "monitoring startup still eagerly allocates demand-owned Metal resources")
require("captureActive" in source_hook_body and
        "if (captureActive && self.framebufferOnly)" in source_hook_body and
        "trackSourceDrawable:drawable" in source_hook_body and
        "if (observationActive && self.framebufferOnly)" not in source_hook_body,
        "timestamp monitoring still changes framebufferOnly or captures every source")
require("prepareSourceDrawableForCapture" not in proxy and
        "_visualOwnershipLock" not in proxy and
        "os_unfair_lock" not in source_hook_body,
        "source framebuffer setup can re-enter presentation while holding session locks")
require("FPFrameGenerationObserveSourcePresent(" in source_present_body and
        "presentedTime" in source_present_body and
        "FPFrameGenerationRecordSourcePresent(_state)" not in source_present_body and
        "observation.shouldBeginCapturePriming" in source_present_body and
        "scheduleCapturePrimingOutputSurface" in source_present_body,
        "source timestamp demand does not drive the state-machine priming API")
for fragment in (
    "newCommandQueueWithMaxCommandBufferCount:",
    "newLibraryWithSource:FPFrameGenerationCompositionShaderSource()",
    "_compositionPipelines = [NSMutableDictionary dictionary]",
    "compositionPipelineForPixelFormat:_sourceLayer.pixelFormat",
):
    require(fragment in demand_resource_prepare_body,
            f"lazy demand Metal preparation is incomplete: {fragment}")
require("if (!_currentPipeline)" in demand_resource_prepare_body and
        "if (!_midpointPipeline || !_currentPipeline)" not in
            demand_resource_prepare_body and
        "if (!currentPipeline)" in rebuild_body and
        "if (!midpointPipeline || !currentPipeline)" not in rebuild_body,
        "optional midpoint pipeline is still a current-output launch gate")
prepare_index = capture_priming_body.find("prepareDemandMetalResourcesOnMain")
rebuild_index = capture_priming_body.find("rebuildOutputSurfaceResettingState:NO")
framebuffer_index = capture_priming_body.find(
    "self->_sourceLayer.framebufferOnly = NO"
)
state_unlock_before_framebuffer = capture_priming_body.rfind(
    "os_unfair_lock_unlock(&self->_stateLock)",
    0,
    framebuffer_index,
)
capture_arm_index = capture_priming_body.find(
    "atomic_store(&self->_sourceCaptureEnabled, true)"
)
require(0 <= prepare_index < rebuild_index <
        state_unlock_before_framebuffer < framebuffer_index < capture_arm_index and
        "atomic_store(&_sourceCaptureEnabled, true)" not in source_present_body,
        "source capture is armed or framebuffer mode changes under the state lock")
for fragment in (
    "_midpointPipeline = nil",
    "_currentPipeline = nil",
    "_compositionPipelines = nil",
    "_compositionLibrary = nil",
    "_displayQueue = nil",
    "_captureQueue = nil",
    "_resourceDevice = nil",
):
    require(fragment in demand_resource_release_body,
            f"demand Metal teardown is incomplete: {fragment}")
require("releaseDemandMetalResourcesOnMain" in failure_body and
        "releaseDemandMetalResourcesOnMain" in invalidate_body,
        "failure/invalidation can retain demand-owned Metal resources")
require("self->_sourceLayer.framebufferOnly =" in failure_body and
        "[self->_outputLayer removeFromSuperlayer]" in failure_body and
        "self->_outputLayer = nil" in failure_body and
        "[self->_retainedOutputLayer removeFromSuperlayer]" in failure_body and
        "self->_retainedOutputLayer = nil" in failure_body and
        "last positively presented output" not in failure_body,
        "terminal frame-generation failure does not restore live source ownership")
require(
    "CAFrameRateRangeMake(" in rebuild_body and
    "targetRate / 2.0f" in rebuild_body and
    "targetRate," in rebuild_body,
    "display cadence range must be derived from selected N",
)
require(
    "displayLink.preferredFrameLatency = 1.0f" in rebuild_body and
    "displayLink.paused = YES" in rebuild_body,
    "display link does not request one-frame latency and start work-paused",
)
require(
    "layer.framebufferOnly = YES" in rebuild_body,
    "generated output drawable is not using render-target-only allocation",
)
require(
    "layer.opaque = NO" in rebuild_body and
    "NSColor.clearColor.CGColor" in rebuild_body,
    "output layer must remain clear and non-opaque before positive presentation",
)
for fragment in (
    "[self->_outputLayer removeFromSuperlayer]",
    "self->_outputLayer = nil",
    "[self->_retainedOutputLayer removeFromSuperlayer]",
    "self->_retainedOutputLayer = nil",
    "atomic_store(&self->_retainedOutputPending, false)",
    "self->_sourceLayer.framebufferOnly =",
    "self->_sourceFramebufferOnlyBeforeSession",
    "Terminal frame-generation failure is fail-open to the live source",
):
    require(fragment in failure_body,
            f"terminal frame-generation failure can freeze output over the live source: {fragment}")
require("blackColor" not in failure_body and
        "kCGColorBlack" not in failure_body and
        ".opaque = YES" not in failure_body,
        "terminal source recovery can replace the frozen frame with black output")
require(
    ".opacity =" not in proxy and ".hidden =" not in proxy and
    "layer.backgroundColor = NSColor.blackColor" not in proxy and
    "CGColorGetConstantColor(kCGColorBlack)" not in proxy,
    "frame generation must not prearm a hidden, opacity-zero, or black layer",
)
for fragment in (
    "_retainedOutputLayer = _outputLayer",
    "retireHeldOutputAfterActivation",
    "FPFrameGenerationTelemetrySnapshot(self->_state).outputActive",
):
    require(fragment in proxy, f"resize-safe held output contract missing: {fragment}")

require("FP_FRAME_GENERATION_THRESHOLD_MULTIPLIER 1.01" in header and
        "FP_FRAME_GENERATION_THRESHOLD_MULTIPLIER /" in state and
        "currentPairEligible = interval >" in capture_ready_state_body and
        "threshold + FP_THRESHOLD_TOLERANCE_SECONDS" in
            capture_ready_state_body and
        "FPFrameGenerationInterpolationThreshold(state)" in
            source_observation_state_body and
        "effective_display_slot(state)" not in source_observation_state_body and
        "optionalServiceBalance" in capture_ready_state_body and
        "interval / slot - 1.0" in capture_ready_state_body and
        "FP_OPTIONAL_SERVICE_BALANCE_MINIMUM" in state and
        "FP_OPTIONAL_SERVICE_BALANCE_MAXIMUM" in state,
        "strict 1.01/N eligibility and bounded signed display-service balance are incomplete")
for obsolete in (
    "FPFrameGenerationReturnToSourceMonitoring",
    "FPFrameGenerationSettleProgressWindow",
    "FPFrameGenerationSettledProgress",
    "midpointAdmissionCredit",
):
    require(obsolete not in header and obsolete not in state,
            f"obsolete direct-handoff/debt API remains: {obsolete}")
require("FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT 3" in header,
        "display submission ownership is not bounded to three drawables")
require("FP_FRAME_GENERATION_READY_CURRENT_CAPACITY 4" in header and
        "readyCurrents[FP_FRAME_GENERATION_READY_CURRENT_CAPACITY]" in state,
        "ready current ownership is not bounded to four ordered entries")
require("surfaceEpoch" in header and "surfaceEpoch" in state,
        "retired-surface presentations can contaminate active telemetry")
record_update_index = display_body.find("FPFrameGenerationRecordDisplayUpdate(")
target_timestamp_index = display_body.find("update.targetPresentationTimestamp")
global_ledger_index = display_body.find("freeTextureSubmissionIndexLocked")
drawable_index = display_body.find("drawable = update.drawable")
drawable_texture_index = display_body.find("destination = drawable.texture")
acquire_index = display_body.find("FPFrameGenerationAcquireDisplayCandidate(")
require(0 <= record_update_index < target_timestamp_index <
        global_ledger_index < acquire_index,
        "display candidate acquisition is not paced by the actual target presentation timestamp")
require(0 <= drawable_index < drawable_texture_index < acquire_index and
        "if (!drawable || !destination)" in display_body,
        "drawable starvation can still pop and lose an ordered Current")
late_guard_index = display_body.find("CACurrentMediaTime() >= callbackDeadline")
late_rebase_index = display_body.find(
    "FPFrameGenerationHandleLateDisplayUpdate(_state)"
)
late_return_index = display_body.find("return;", late_rebase_index)
require(0 <= late_guard_index < late_rebase_index < late_return_index <
        record_update_index and
        "_readyPairEpoch = 0" in
            display_body[late_rebase_index:late_return_index] and
        "scheduleDisplayLinkRebaseAfterLateUpdate:link" in
            display_body[late_rebase_index:late_return_index],
        "late display callback can consume current or retain an optional midpoint")
require("writersInFlight" in state and
        "outputJoinCount" in state and
        "FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT" in state and
        "FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY 6" in header and
        "outputJoins[FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY]" in state and
        "writers[FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT]" in state,
        "state machine does not separate bounded writer and presentation ownership")
require("pairedCurrentQueued" in state and
        "pairedCurrentEpoch" in state and
        "pairedCurrentSurfaceEpoch" in state,
        "started midpoint/current pair ownership is missing")
require("availableWriterSlots < 2" in state and
        "availableOutputJoinSlots < 2" in state and
        '"midpoint-dropped-headroom"' in state,
        "midpoint can start without two writer and receipt slots")
require("readyCurrents[0].epoch < state->readyPairEpoch" in state and
        "pair_has_matching_current(state)" in state and
        "olderCurrentPrecedesPair" in state,
        "an older FIFO Current can still destroy or be overtaken by the singleton pair")
require("_queuedPairedCurrentSlot" in proxy and
        "candidate.pairedCurrent" in display_body,
        "proxy texture ownership can still split a started midpoint/current pair")
require("acquiredTelemetry.readyMidpointSourceTime <= 0.0" in display_body and
        "retireNativeReadyMidpointLockedForEpoch" in display_body,
        "native pair mapping is discarded while an older FIFO Current drains")
require("single ordered _displayQueue" in display_body and
        "Three writer entries" in display_body and
        "Six fixed metadata receipts" in display_body and
        "delayed presented callbacks cannot" in display_body,
        "midpoint/current order can regress to presented-callback serialization")

for forbidden in (
    "MPSImageAdd",
    "_midpointFilter",
    "_generationQueue",
    "generateMidpointBetween:",
    "newPrivateTextureMatching:",
    "_readyMidpointTexture",
):
    require(forbidden not in proxy,
            f"per-pair midpoint pre-pass remains in production proxy: {forbidden}")
for fragment in (
    "newLibraryWithSource:FPFrameGenerationCompositionShaderSource()",
    "fp_frame_generation_vertex",
    "fp_frame_generation_midpoint",
    "return half4(mix(previousColor, currentColor, 0.5h), 1.0h)",
    "fp_frame_generation_current",
    "return half4(current.read(coordinate).rgb, 1.0h)",
    "renderCommandEncoderWithDescriptor:renderPass",
    "setRenderPipelineState:pipeline",
    "setFragmentTexture:previousTexture atIndex:0",
    "setFragmentTexture:currentTexture atIndex:1",
):
    require(fragment in proxy,
            f"direct drawable composition pipeline is incomplete: {fragment}")
require("FPFrameGenerationRecordGeneratedPairReady(" in capture_ready_body and
        "enqueueReadyCurrentSlotLocked:slot" in capture_ready_body and
        "FPFrameGenerationRecordGeneratedSubmitted" not in capture_ready_body and
        "FPFrameGenerationRecordGeneratedSubmitted(_state, candidate.epoch)" in
        display_body and
        "FPFrameGenerationRecordWriterCompleted(" in display_body and
        "FPFrameGenerationRecordGeneratedCompleted(state, candidate.epoch)" in state,
        "generated submit/complete telemetry is not owned by the midpoint drawable command")
require("observation.sourceSequence" in source_present_body and
        "FPFrameGenerationRecordCaptureReady(" in capture_ready_body and
        "sourceSequence," in capture_ready_body and
        "FPFrameGenerationCancelAcceptedCapture" in capture_ready_body and
        "FPFrameGenerationCaptureAdmissionCurrentCapacityReached" in header and
        "sourceSequence - state->lastCapturedSourceSequence == 1" in state,
        "capture/current admission is not atomic or capture gaps can still create midpoints")
require("candidate.kind == FPFrameGenerationOutputMidpoint" in display_body and
        "? _midpointPipeline : _currentPipeline" in display_body and
        "[encoder setFragmentTexture:currentTexture atIndex:0]" in display_body and
        "currentWeight" not in proxy,
        "current replay still performs the midpoint's second full-frame read")
require("optionalMidpointFailure" in display_body and
        "FPFrameGenerationRecordGeneratedFailed" in display_body and
        "candidate.kind == FPFrameGenerationOutputCurrent" in display_body and
        'failWithReason:"current-output-writer-unavailable"' in display_body and
        'failWithReason:"current-output-writer-failed"' in display_body and
        'failWithReason:"display-writer-unavailable"' not in display_body and
        'failWithReason:"display-writer-failed"' not in display_body,
        "optional midpoint failures can still terminate the mandatory current path")

require("#define FP_CAPTURE_TEXTURE_POOL_CAPACITY 6" in proxy,
        "capture pool is not bounded to six reusable surface textures")
reset_texture_body = method_body(
    proxy,
    "- (void)resetTextureBookkeepingLocked",
    "- (BOOL)captureSlotIsReferencedLocked:",
)
require("memset(_textureSubmissions, 0, sizeof(_textureSubmissions))" in
            reset_texture_body and
        "memset(_presentationReceipts, 0, sizeof(_presentationReceipts))" in
            reset_texture_body and
        "detached or retained as a last-good image" in reset_texture_body and
        "stale" in reset_texture_body,
        "detached output can permanently retain native submission ownership")
state_reset_index = rebuild_body.find(
    'FPFrameGenerationResetForSurfaceChange(_state, "surface-change")'
)
ledger_reset_index = rebuild_body.find("[self resetTextureBookkeepingLocked]")
reset_unlock_index = rebuild_body.find(
    "os_unfair_lock_unlock(&_stateLock)", ledger_reset_index
)
require(0 <= state_reset_index < ledger_reset_index < reset_unlock_index,
        "state and native submission ledgers are not retired atomically")
presentation_watchdog_body = method_body(
    proxy,
    "- (void)schedulePresentationWatchdog\n{",
    "- (void)scheduleDisplayLinkResume\n{",
)
for fragment in (
    "atomic_exchange(&_presentationWatchdogPending, true)",
    "FPPresentationWatchdogSlotMultiplier * currentSlot",
    "dispatch_after(",
    "owningWindowIsActiveAndVisible",
    "_surfaceUpdatePending",
    "receipt->presentationStallChecks",
    "refreshPresentationStallChecksLocked",
    "FPFrameGenerationDropStalledMidpoint(",
    "receipt->writerCompleted",
    "midpointCommandStalled",
    "sizeof(*receipt)",
    "droppedStalledMidpoint = YES",
    "atomic_store(&strongSelf->_presentationWatchdogPending, false)",
    "[strongSelf schedulePresentationWatchdog]",
    "[strongSelf failWithReason:",
):
    require(fragment in presentation_watchdog_body,
            f"positive-presentation watchdog is incomplete: {fragment}")
require("#define FP_PRESENTATION_STALL_FAILURE_CHECKS 3u" in proxy,
        "one presentation deadline can still become a permanent failure")
require("receipt->candidate.kind ==\n                                         FPFrameGenerationOutputCurrent" in
            presentation_watchdog_body and
        "receipt->candidate.kind ==\n                                         FPFrameGenerationOutputMidpoint" in
            presentation_watchdog_body,
        "writer and receipt stalls do not distinguish mandatory Current from optional midpoint")
require('"midpoint-command-stalled"' in presentation_watchdog_body and
        '"current-output-writer-stalled"' in presentation_watchdog_body and
        '"presentation-stalled"' in presentation_watchdog_body and
        "if (!receipt->writerCompleted)" in
            presentation_watchdog_body and
        "midpointCommandStalled\n                        ?" in
            presentation_watchdog_body,
        "an incomplete midpoint command can still rearm forever or release GPU-owned textures")
require("FPFrameGenerationDisplayCandidate candidate" in proxy and
        "BOOL writerCompleted" in proxy and
        "completed.status == MTLCommandBufferStatusCompleted" in display_body and
        "FPFrameGenerationRecordWriterCompleted(" in display_body and
        "removeTextureSubmissionLockedForCandidate" in display_body and
        "FPFrameGenerationRecordPresentationReceipt(" in display_body and
        "presentationReceiptIndexLockedForCandidate" in display_body and
        "midpoint_dropped_presentation_stall=%llu" in proxy and
        "midpointDroppedPresentationStall" in header and
        "midpoint-dropped-presentation-stall" in state,
        "writer/presentation join lacks exact identity, GPU retirement, or diagnostics")
require("currentPresentationFailed" not in header and
        "currentPresentationFailed" not in state and
        "current-presentation-invalid" not in proxy and
        '"current-presentation-dropped"' in state and
        "positivePresentationRecorded" in state,
        "one non-positive Current receipt can still terminally disable frame generation")
require("submittedAtTime = CACurrentMediaTime()" in display_body and
        "[self schedulePresentationWatchdog]" in display_body and
        "schedulePresentationWatchdogForSubmissionID" not in proxy,
        "committed display candidates can occupy the global ledger forever")
require("NSApp.isActive" in proxy and "window.isVisible" in proxy and
        "NSWindowOcclusionStateVisible" in proxy,
        "inactive, hidden, or occluded windows can consume stall strikes")
require("resetPresentationStallChecksLocked" not in proxy and
        "[self refreshPresentationStallChecksLocked]" in proxy,
        "one successful drawable can still erase another stuck submission's strikes")
first_watchdog_ledger = presentation_watchdog_body.find(
    "_presentationReceipts[index]"
)
watchdog_visibility = presentation_watchdog_body.find(
    "[strongSelf owningWindowIsActiveAndVisible]"
)
require(0 <= first_watchdog_ledger < watchdog_visibility,
        "successful submissions still synchronize with AppKit before ledger rejection")
require("presentationReceiptIndexLockedForCandidate:candidate" in
            display_body and
        "removeTextureSubmissionLockedForCandidate:candidate" in display_body and
        "surfaceGeneration:surfaceGeneration" in display_body,
        "stale output callbacks can still mutate or fail a rebuilt surface")
pool_body = method_body(
    proxy,
    "- (BOOL)createCaptureTexturePoolForDevice:",
    "- (void)rebuildOutputSurfaceResettingState:",
)
require("newTextureWithDescriptor:descriptor" in pool_body and
        "newTextureWithDescriptor" not in source_present_body and
        "newTextureWithDescriptor" not in source_commit_body and
        "newTextureWithDescriptor" not in capture_ready_body and
        "newTextureWithDescriptor" not in display_body,
        "capture textures are still allocated on the source/display hot path")
for fragment in (
    "FP_SOURCE_DRAWABLE_TICKET_CAPACITY 4u",
    "FP_CAPTURE_MAX_IN_FLIGHT 3u",
    "slot = [self freeCaptureSlotLocked]",
    "_captureSubmissions[slot] =",
    ".sequence = _nextCaptureSequence",
    "sourceTexture.device == commandBuffer.device",
    "capturedTexture.device == commandBuffer.device",
    "[commandBuffer blitCommandEncoder]",
    "[commandBuffer addCompletedHandler:",
    "(void)capturedTexture",
):
    require(fragment in proxy,
            f"bounded source-command-buffer capture is incomplete: {fragment}")
require("[commandBuffer commit]" not in source_commit_body and
        "waitUntilCompleted" not in source_commit_body and
        "dispatch_sync" not in source_commit_body and
        "newCommandBuffer" not in source_present_body,
        "source capture can still fork, wait, retry, or create a post-present command buffer")
require("FPFrameGenerationSourceCaptureJoinMarkUnavailable(" in
            source_commit_body and
        "!preactivationCurrentOwned && _captureInFlight > 0" in
            source_commit_body and
        "recordCaptureBusyLockedAtTime:CACurrentMediaTime()" in
            source_commit_body and
        "[self scheduleCaptureResourceRecovery]" in source_commit_body and
        source_commit_body.find("os_unfair_lock_unlock(&_stateLock)") <
            source_commit_body.find("[self scheduleCaptureResourceRecovery]") and
        "FPFrameGenerationSourceCaptureJoinRecordPresented(" in
            source_present_body and
        "FPFrameGenerationSourceCaptureJoinRetire" in source_present_body,
        "a normal capture skip can leak a fixed ticket or bypass bounded busy recovery")
first_pool_lookup = source_commit_body.find("slot = [self freeCaptureSlotLocked]")
optional_evict = source_commit_body.find(
    "FPFrameGenerationEvictReadyMidpointForCaptureCapacity("
)
second_pool_lookup = source_commit_body.find(
    "slot = [self freeCaptureSlotLocked]",
    first_pool_lookup + 1,
)
busy_record = source_commit_body.find(
    "recordCaptureBusyLockedAtTime:CACurrentMediaTime()"
)
require(0 <= first_pool_lookup < optional_evict < second_pool_lookup < busy_record and
        source_commit_body.count("slot = [self freeCaptureSlotLocked]") == 2 and
        "retireNativeReadyMidpointLockedForEpoch" in source_commit_body and
        "FPFrameGenerationEvictReadyMidpointForCaptureCapacity" in header and
        '"midpoint-evicted-capture-capacity"' in state,
        "fixed pool pressure does not perform exactly one optional-only eviction and retry")
require("BOOL preactivationCurrentOwned = !telemetry.outputActive" in
            source_commit_body and
        "_captureInFlight > 0 ||" in
            source_commit_body and
        "telemetry.presentationReceiptsPending > 0" in source_commit_body and
        "!preactivationCurrentOwned" in source_commit_body,
        "commit-time capture does not bound newer preactivation capture ownership")
require("(!ticketID && !surfaceTransitionPending)" in source_present_body and
        "FP_SOURCE_BOUNDARY_FAILURE_PRESENTS 3u" in proxy and
        "source-present-boundary-unavailable" in source_present_body,
        "zero-ticket armed source presents cannot prove bounded hook failure")
require("sourceCaptureCommandBufferCompletedForTicket" in
            source_completion_body and
        "FPFrameGenerationSourceCaptureJoinRecordCompleted(" in
            source_completion_body and
        "ticket->join.sourceSequence" in source_completion_body and
        "acceptCapturedSlot:slot" in source_completion_body and
        "retireCaptureCompletionLockedForSlot:slot" in source_completion_body,
        "source command completion is not safely joined with presentation")
for fragment in (
    "scheduleDisplayLinkResume",
    "atomic_bool _displayLinkPausedForWork",
    "displayLink.paused = YES",
    "self->_displayLink.paused = NO",
):
    require(fragment in proxy,
            f"bounded display-link pause/resume contract is missing: {fragment}")
resume_body = method_body(
    proxy,
    "- (void)scheduleDisplayLinkResume\n{",
    "- (void)metalDisplayLink:",
)
late_rebase_body = method_body(
    proxy,
    "- (void)scheduleDisplayLinkRebaseAfterLateUpdate:\n"
    "    (CAMetalDisplayLink *)displayLink\n{",
    "- (void)scheduleDisplayLinkResume\n{",
)
rebase_index = resume_body.find(
    "FPFrameGenerationRebaseDisplayTargetObservation(self->_state)"
)
resume_index = resume_body.find("self->_displayLink.paused = NO")
require(0 <= rebase_index < resume_index and
        "++self->_displayResumeCount" in resume_body,
        "DisplayLink resume can contaminate effective-slot EWMA with paused time")
require("clear_optional_service_balance(state)" not in
            display_rebase_state_body and
        "signed optional-service balance" in display_rebase_state_body and
        "clear_optional_service_balance(state)" in late_display_state_body and
        display_update_state_body.count(
            "clear_optional_service_balance(state)"
        ) >= 2 and
        "signed optional-service balance" in header,
        "normal DisplayLink resume can erase capacity, or true timing discontinuities retain it")
require("self->_displayLink != displayLink" in late_rebase_body and
        "displayLink.paused = YES" in late_rebase_body and
        "displayLink.paused = NO" in late_rebase_body and
        "FPFrameGenerationRebaseDisplayTargetObservation(self->_state)" in
            late_rebase_body and
        "_outputLayer" not in late_rebase_body and
        "framebufferOnly" not in late_rebase_body,
        "late callback rebase cannot guarantee a fresh same-owner deadline")
require("FP_EMPTY_DISPLAY_UPDATE_GRACE" not in proxy and
        "pauseDisplayLinkForWorkIfCurrent" not in proxy and
        "displayLink.paused = YES" not in display_body and
        "if (!link || link != _displayLink" in display_body,
        "active output does not keep a continuous, stale-safe DisplayLink")
for fragment in (
    "layer.contentsScale = surfaceContentsScale",
    "layer.minificationFilter = surfaceMinificationFilter",
    "layer.magnificationFilter = surfaceMagnificationFilter",
    "layer.contentsGravity = surfaceContentsGravity",
    "layer.drawableSize = surfaceDrawableSize",
    "layer.colorspace = surfaceColorspace",
    "layer.wantsExtendedDynamicRangeContent = surfaceEDR",
    "layer.displaySyncEnabled = surfaceDisplaySyncEnabled",
    "layer.presentsWithTransaction = NO",
    "layer.allowsNextDrawableTimeout = surfaceAllowsNextDrawableTimeout",
):
    require(fragment in rebuild_body,
            f"output surface no longer mirrors source configuration: {fragment}")
require("beginOutputUnderRunBackoff" not in proxy and
        "_sourceDemandBackoffUntil" not in proxy and
        '"output-under-run-backoff"' not in proxy,
        "timed output teardown/backoff retry remains in production")
require("Frame Generation inactive: %@" in failure_body and
        "ensureFrameCheckLayerOnMain" in failure_body and
        "if (self->_frameCheckEnabled)" in failure_body,
        "Frame Check silently disappears when active frame generation fails")
frame_check_rebuild_body = method_body(
    proxy,
    "- (void)installFrameCheckLayerIfNeeded\n{",
    "- (CATextLayer *)ensureFrameCheckLayerOnMain",
)
require("if (!_frameCheckLayer) return" in frame_check_rebuild_body and
        "[_frameCheckLayer removeFromSuperlayer]" in frame_check_rebuild_body and
        "[_hostView.layer addSublayer:_frameCheckLayer]" in
            frame_check_rebuild_body and
        "_frameCheckLayer.string =" not in frame_check_rebuild_body,
        "surface rebuild silently removes or overwrites the honest Frame Check state")
for fragment in (
    'layer.font = (__bridge CFTypeRef)@"Menlo"',
    "layer.fontSize = 16.0",
    '"Target      %6u Hz',
    '"Final       %6.1f FPS',
    '"Original    %6.1f FPS',
    '"Generated   %6.1f FPS',
    "currentTelemetry.finalCadenceHz",
    "currentTelemetry.sourceCadenceHz",
    "currentTelemetry.generatedCadenceHz",
):
    require(fragment in proxy,
            f"four-line Frame Check HUD contract is incomplete: {fragment}")
target_index = frame_check_body.find('"Target')
final_index = frame_check_body.find('"Final')
original_index = frame_check_body.find('"Original')
generated_index = frame_check_body.find('"Generated')
require(0 <= target_index < final_index < original_index < generated_index and
        "double sourceCadence = currentTelemetry.sourceCadenceHz" in
            frame_check_body and
        frame_check_body.count("sourceCadence,") >= 2 and
        frame_check_body.count("currentTelemetry.sourceCadenceHz") >= 3 and
        "currentTelemetry.currentOutputCadenceHz" not in frame_check_body,
        "Frame Check Original is not consistently bound to source cadence")
output_add_index = rebuild_body.find("[_hostView.layer addSublayer:layer]")
hud_reorder_index = rebuild_body.find("[self installFrameCheckLayerIfNeeded]")
require(0 <= output_add_index < hud_reorder_index,
        "reacquiring Frame Check can remain below the replacement output layer")
require("atomic_store(&self->_retainedOutputPending, true)" in retire_body,
        "retained output cannot retry retirement after a racing surface reset")
require("_retainedOutputLayer != nil" in rebuild_body and
        "second reset before reacquisition" in rebuild_body,
        "consecutive surface resets can orphan the last-good output layer")
for field in (
    "current_presented=%llu",
    "midpoint_admitted=%llu",
    "midpoint_dropped_late=%llu",
    "midpoint_dropped_superseded=%llu",
    "presentations_in_flight=%u",
    "presentation_receipts_pending=%u",
    "max_presentation_receipts_pending=%u",
    "writer_completed=%llu",
    "current_writer_completed=%llu",
    "effective_slot_ms=%.3f",
    "capture_busy_episode=%u",
    "capture_outstanding_ms=%.3f",
    "empty_display_updates=%u",
    "display_resume_count=%llu",
    "source_cadence_hz=%.3f",
    "original_cadence_hz=%.3f",
    "generated_cadence_hz=%.3f",
    "output_source_ratio=%.6f",
    "current_source_ratio=%.6f",
    "source_present_accepted=%llu",
    "source_q=%.6f",
    "source_q_lower95=%.6f",
    "source_q_upper95=%.6f",
    "capture_cb_outstanding=%u",
    "display_cb_outstanding=%u",
    "capture_pool_allocations=%llu",
    "capture_pool_releases=%llu",
    "capture_pool_textures=%u",
    "record_time=%.9f",
    "session_id=%llu",
    "presentation_stall_checks=%u",
    "source_present_command_buffer_bound=%llu",
    "source_capture_encoded_on_source_cb=%llu",
    "source_capture_joined=%llu",
    "source_present_uncovered=%llu",
    "executable_sha256=%s",
):
    require(field in proxy,
            f"release telemetry omits bounded scheduler evidence: {field}")
require("runtimeCounters.currentOutputCadenceHz" in proxy and
        "Parser-compatible legacy key" in proxy,
        "legacy original_cadence_hz no longer clearly carries output Current cadence")
require("FPTelemetryMinimumInterval = 2.0" in proxy and
        "FPNextFrameGenerationSessionIdentifier" in proxy and
        "os_unfair_lock_lock(&_telemetryWriteLock)" in telemetry_body and
        "os_unfair_lock_unlock(&_telemetryWriteLock)" in telemetry_body and
        "runtimeCounters.recordMonotonicTime = now" in telemetry_body and
        "telemetry.sourcePresentAccepted" in proxy and
        "telemetry.finalCadenceHz / telemetry.sourceCadenceHz" in
            telemetry_body and
        "telemetry.currentOutputCadenceHz" in telemetry_body and
        "source_cadence_bounds(state, observationTime)" in state and
        "FPFrameGenerationTelemetrySnapshotAtTime(_state, now)" in
            telemetry_body,
        "current activation telemetry is missing identity, time, ratios, or bounded source cadence")
for fragment in (
    "FP_FRAME_GENERATION_CADENCE_WINDOW_SECONDS 1.0",
    "FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY 512",
    "cadence_sample_count_in_window(",
    "FPFrameGenerationTelemetrySnapshotAtTime(",
    "currentOutputCadenceHz",
):
    require(fragment in header or fragment in state,
            f"common recent cadence contract is missing: {fragment}")
for fragment in (
    "<CommonCrypto/CommonDigest.h>",
    "FP_EXECUTABLE_ARGUMENT_SCAN_LIMIT 64u",
    "FP_EXECUTABLE_ARGUMENT_MAXIMUM_BYTES 32768u",
    "NSProcessInfo.processInfo.arguments",
    "for (NSUInteger index = 1; index < upperBound; ++index)",
    "stringByTrimmingCharactersInSet:",
    "normalized.length >= 2",
    'stringByReplacingOccurrencesOfString:@"/"',
    r'rangeOfString:@"\\\\"',
    "normalized.lowercaseString",
    'hasSuffix:@".exe"',
    "CC_SHA256(",
    'static const char hexadecimal[] = "0123456789abcdef"',
    'static char result[CC_SHA256_DIGEST_LENGTH * 2 + 1] = "unavailable"',
    "FPExecutableIdentitySHA256()",
):
    require(fragment in proxy,
            f"bounded executable telemetry identity is incomplete: {fragment}")
require(r"\texecutable=" not in proxy and "openssl" not in proxy.lower(),
        "frame-generation telemetry leaks a raw path or adds third-party crypto")
require("[drawable addPresentedHandler:" in proxy and
        "__weak FPD3DMetalFrameGenerationSession *weakSession" in proxy and
        "FPD3DMetalFrameGenerationSession *strongSession = weakSession" in proxy and
        "[strongSession sourceDrawableTicket:ticketID" in proxy and
        "return drawable;" in proxy and
        "FPSourcePresentationObservation" not in proxy and
        "FPTrackedSourceDrawable" not in proxy,
        "source capture must observe and return CAMetalLayer's original drawable without a per-present observer allocation")
for fragment in (
    "@selector(presentDrawable:)",
    "@selector(presentDrawable:atTime:)",
    "@selector(presentDrawable:afterMinimumDuration:)",
    "@selector(commit)",
    "@selector(commandBuffer)",
    "@selector(commandBufferWithUnretainedReferences)",
    "@selector(commandBufferWithDescriptor:)",
    "FPOriginalMetalImplementation",
    "FPBindTrackedSourceDrawable",
    "FPPrepareTrackedSourceCapture(self)",
    "if (original) original(self, selector)",
    "FPFullyHookedCommandBufferClasses",
    "memory_order_acquire",
    "FPSourceCommandBufferBindings",
    "FPTakeSourceCommandBufferBindings",
    "FPSourceCommandBufferBindings[index].commandBuffer = CFRetain(",
    "FPSourceCommandBufferBindings[index].session = CFRetain(",
    "retainedCommandBuffer",
    "CFRelease(retainedCommandBuffer)",
):
    require(fragment in proxy,
            f"dynamic public Metal command-boundary hook is incomplete: {fragment}")
require("One source\n     * command buffer may legitimately present drawables for multiple sessions" in
            proxy and
        "CFTypeRef sessions[FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY]" in
            proxy and
        "for (uint32_t index = 0; index < sessionCount; ++index)" in proxy and
        "index < FP_SOURCE_DRAWABLE_TICKET_CAPACITY" in source_commit_body and
        "prepareNextSourceCaptureBeforeCommit:commandBuffer" in
            source_commit_body,
        "one source command buffer cannot drain all bounded drawable/session tickets")
require("FPFrameGenerationDiscardStalePreactivationSeed(_state)" in
            capture_ready_body and
        capture_ready_body.find(
            "FPFrameGenerationDiscardStalePreactivationSeed(_state)"
        ) < capture_ready_body.find("FPFrameGenerationRecordCaptureReady(") and
        "retireNativePreactivationSeedLockedForEpoch" in capture_ready_body and
        "FPFrameGenerationDiscardStalePreactivationSeed(_state)" not in
            display_body and
        "!preactivationTelemetry.outputActive && _captureInFlight > 0" not in
            display_body,
        "preactivation seed replacement is not owned exclusively by a completed replacement capture")
require("FPFrameGenerationDiscardStalePreactivationSeed" in header and
        "uint64_t FPFrameGenerationDiscardStalePreactivationSeed(" in state and
        "state->outputActive" in state and
        "state->outputJoinCount != 0" in state and
        "!state->outputActive && state->outputJoinCount > 0" in state and
        '"preactivation-seed-superseded"' in state,
        "preactivation seed retirement is not fenced from active/current output")
require("objc_setAssociatedObject" not in proxy and
        "objc_getAssociatedObject" not in proxy and
        "waitUntilCompleted" not in proxy and
        "source-present-boundary-unavailable" in source_present_body and
        "FP_SOURCE_BOUNDARY_FAILURE_PRESENTS 3u" in proxy,
        "source boundary coverage can mutate renderer objects, block, or retry forever")
for body, name in (
    (present_immediate_hook_body, "presentDrawable:"),
    (present_at_time_hook_body, "presentDrawable:atTime:"),
    (present_after_duration_hook_body, "presentDrawable:afterMinimumDuration:"),
):
    require(body.count("original(self, selector, drawable") == 1 and
            body.find("FPBindTrackedSourceDrawable") <
                body.find("original(self, selector, drawable"),
            f"{name} does not preserve and invoke its original IMP exactly once")
require(source_command_commit_hook_body.count(
            "original(self, selector)"
        ) == 1 and
        source_command_commit_hook_body.find(
            "FPPrepareTrackedSourceCapture(self)"
        ) < source_command_commit_hook_body.find("original(self, selector)"),
        "source capture is not appended immediately before the original commit")
require("object_getClass(commandBuffer)" in proxy and
        "class_getMethodImplementation" in proxy and
        "NSClassFromString" not in proxy,
        "Metal hooks use a private class name instead of dynamically observed concrete classes")
require("@interface FPFrameGenerationSourceLayer" not in proxy and
        "FPInstallSourceDrawableObservationHook" in proxy and
        "objc_setAssociatedObject" not in proxy and
        "objc_getAssociatedObject" not in proxy and
        "NSValue valueWithPointer" not in proxy and
        "FPFrameGenerationSourceSessions" in proxy and
        "FPRegisterFrameGenerationSourceLayer" in proxy and
        "FPUnregisterFrameGenerationSourceLayer" in proxy and
        "_sourceLayer = (CAMetalLayer *)owningMetalView.layer" in proxy,
        "source capture must preserve Wine's original backing-layer lifetime without realizing its private class")
require("dispatch_async(dispatch_get_main_queue()" in proxy_create_body and
        "[session activateSourceObservation]" in proxy_create_body and
        proxy_create_body.find("dispatch_async(dispatch_get_main_queue()") <
        proxy_create_body.find("[session activateSourceObservation]"),
        "source hook installation must not mutate CAMetalLayer synchronously inside the create callback")
for body, name in (
    (rebuild_body, "surface rebuild"),
    (source_present_body, "source presentation"),
    (source_commit_body, "source command commit"),
    (source_completion_body, "source command completion"),
    (capture_ready_body, "capture completion"),
    (display_body, "display callback"),
    (retire_body, "retained-output retirement"),
):
    require("callbackStateIsUsableLocked" in body,
            f"{name} does not revalidate session state while holding the state lock")
require("if (atomic_load(&_invalidated) || atomic_load(&_failed)) return;" in
            source_present_body and
        source_present_body.find(
            "if (atomic_load(&_invalidated) || atomic_load(&_failed)) return;"
        ) <
        source_present_body.find("[self emitTelemetryForced:"),
        "an invalidated source-present callback can still enter telemetry")
require("telemetryStateIsUsableLocked" in telemetry_body and
        "if (atomic_load(&_invalidated)) return;" in telemetry_body,
        "telemetry can still snapshot retired session state")
require("_state == NULL || atomic_load(&_invalidated)" in failure_body,
        "failure reporting can still mutate retired session state")
require("FPFrameGenerationStateDestroy" not in invalidate_body and
        "_state = NULL" not in invalidate_body and
        "__unsafe_unretained FPD3DMetalFrameGenerationSession *unsafeSelf" in
        invalidate_body,
        "invalidate still destroys state while GPU or display callbacks may be in flight")
for fragment in (
    "[self invalidate]",
    "FPFrameGenerationState *stateToDestroy = _state",
    "_state = NULL",
    "FPFrameGenerationStateDestroy(stateToDestroy)",
):
    require(fragment in dealloc_body,
            f"dealloc does not own final frame-generation state destruction: {fragment}")
invalidate_call_index = dealloc_body.find("[self invalidate]")
detach_state_index = dealloc_body.find(
    "FPFrameGenerationState *stateToDestroy = _state"
)
destroy_state_index = dealloc_body.find(
    "FPFrameGenerationStateDestroy(stateToDestroy)"
)
require(0 <= invalidate_call_index < detach_state_index < destroy_state_index,
        "frame-generation state is destroyed before session invalidation finishes")
unregister_source_index = invalidate_body.find(
    "FPUnregisterFrameGenerationSourceLayer("
)
clear_source_index = invalidate_body.find("unsafeSelf->_sourceLayer = nil")
require(0 <= unregister_source_index < clear_source_index,
        "source observation remains registered after the borrowed layer is cleared")
require("Frame Check (Beta)  waiting" not in proxy,
        "frame check must not appear before real output activation")
frame_check_guard = frame_check_body.find("if (!_frameCheckEnabled")
frame_check_dispatch = frame_check_body.find(
    "dispatch_async(dispatch_get_main_queue()"
)
require(0 <= frame_check_guard < frame_check_dispatch and
        "if (_frameCheckEnabled)" in session_init_body and
        "if (!_frameCheckEnabled || !_hostView.layer) return nil" in proxy,
        "Frame Check OFF can still allocate a HUD layer or enqueue HUD main work")
for fragment in (
    "atomic_exchange(&_frameCheckUpdatePending, true)",
    "__weak FPD3DMetalFrameGenerationSession *weakSelf = self",
    "FPD3DMetalFrameGenerationSession *strongSelf = weakSelf",
    "atomic_store(&strongSelf->_frameCheckUpdatePending, false)",
    "FPFrameGenerationTelemetrySnapshotAtTime(",
):
    require(fragment in frame_check_body,
            f"Frame Check update work is not one-pending/weak/latest: {fragment}")
require("atomic_init(&_frameCheckUpdatePending, false)" in session_init_body,
        "Frame Check pending gate is not initialized per session")

disabled_configuration = wine_create_on_main_body.find(
    "if (!framegen_requested_configuration("
)
disabled_passthrough = wine_create_on_main_body.find(
    "return macdrv_view_create_metal_view( client_view, device );",
    disabled_configuration,
)
framegen_allocation = wine_create_on_main_body.find("calloc(")
framegen_proxy_load = wine_create_on_main_body.find("pthread_once(")
framegen_session_create = wine_create_on_main_body.find(
    "framegen_api->create_session("
)
require(0 <= disabled_configuration < disabled_passthrough <
        framegen_allocation < framegen_proxy_load < framegen_session_create,
        "Frame Generation OFF no longer exits before allocation/proxy/session work")
require('if (!enabled || strcmp( enabled, "1" )) return FALSE;' in wine_patch,
        "Frame Generation OFF is not an exact opt-in gate")

for fragment in (
    "original_view = macdrv_view_create_metal_view( client_view, device )",
    "original_view, device, &configuration, &source_layer",
    "view->original_view == public_handle",
    "view->client_view = client_view",
    "framegen_find_client_view( client_view )",
    "return existing->original_view",
    "++existing->reference_count",
    "--(*cursor)->reference_count",
    "return original_view;",
    "macdrv_view_release_metal_view( view->original_view )",
    "macdrv_on_main_thread( (void *)^{",
    "BOOL initializing;",
    "BOOL retiring;",
    "if (existing->initializing || existing->retiring) return NULL;",
    "if (view && (view->initializing || view->retiring)) return NULL;",
    "if ((*cursor)->initializing || (*cursor)->retiring) return;",
):
    require(fragment in wine_patch,
            f"Wine original Metal view ownership is not preserved: {fragment}")
require("(macdrv_metal_view)view" not in wine_patch and
        "view->public_handle" not in wine_patch,
        "a C bookkeeping allocation is still exposed as an Objective-C Metal view")
require("pthread_cond_" not in wine_patch and
        "framegen_views_mutex" not in wine_patch,
        "Metal-view lifecycle can still block the main executor on a condition wait")
main_fast_path_index = wine_patch.find("if ([NSThread isMainThread])")
main_dispatch_index = wine_patch.find(
    "NSMutableDictionary* threadDict", main_fast_path_index
)
require(0 <= main_fast_path_index < main_dispatch_index and
        "if (block) block();" in
        wine_patch[main_fast_path_index:main_dispatch_index],
        "Wine's synchronous main dispatcher still self-deadlocks on nested ownership calls")
lookup_index = wine_create_on_main_body.find(
    "framegen_find_client_view( client_view )"
)
reserve_index = wine_create_on_main_body.find(
    "framegen_reserve_view( view, client_view )"
)
original_create_index = wine_create_on_main_body.find(
    "if (!(original_view = macdrv_view_create_metal_view( client_view, device )))"
)
create_session_index = wine_create_on_main_body.find("framegen_api->create_session(")
complete_index = wine_create_on_main_body.rfind("framegen_complete_view(")
require(0 <= lookup_index < reserve_index < original_create_index <
        create_session_index < complete_index,
        "main-owned client-view lifecycle is not tombstoned before reentrant original/proxy initialization")
for wrapper, call in (
    (wine_create_wrapper_body,
     "framegen_view_create_metal_view_on_main_thread("),
    (wine_get_layer_wrapper_body,
     "framegen_view_get_metal_layer_on_main_thread("),
    (wine_release_wrapper_body,
     "framegen_view_release_metal_view_on_main_thread("),
):
    require("macdrv_on_main_thread( (void *)^{" in wrapper and call in wrapper,
            f"Metal-view ownership callback is not serialized on Wine's main executor: {call}")
destroy_index = wine_release_on_main_body.find("framegen_api->destroy_session(")
release_original_index = wine_release_on_main_body.find(
    "macdrv_view_release_metal_view( view->original_view )"
)
remove_index = wine_release_on_main_body.find("framegen_remove_view( view )")
retiring_index = wine_release_on_main_body.find("view->retiring = TRUE")
require(0 <= retiring_index < destroy_index < release_original_index < remove_index,
        "final main-owned release does not retain its tombstone through proxy and original teardown")
error_writer_start = wine_patch.find("length = snprintf(")
error_writer_end = wine_patch.find("(long)getpid()", error_writer_start)
require(error_writer_start >= 0 and error_writer_end > error_writer_start,
        "pre-proxy error telemetry format boundary is unavailable")
error_writer_format = wine_patch[error_writer_start:error_writer_end]
error_wire = "".join(
    bytes(literal, "utf-8").decode("unicode_escape")
    for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', error_writer_format)
)
expected_error_fields = (
    "FORGEPLAY_D3DMETAL_FRAMEGEN_V1",
    "%ld",
    "state=error",
    "target_hz=%u",
    "epoch=0",
    "source_present_seen=0",
    "capture_ready=0",
    "generated_submitted=0",
    "generated_completed=0",
    "generated_presented=0",
    "midpoint=0",
    "output_active=0",
    "display_updates=0",
    "cadence_hz=0.0",
    "reason=%s",
)
require(tuple(error_wire.rstrip("\n").split("\t")) == expected_error_fields and
        error_wire.endswith("\n") and "\\t" not in error_wire and
        "\\n" not in error_wire,
        "pre-proxy error telemetry is not a parser-compatible 15-field record")
require("metadata.st_uid != geteuid()" in wine_patch,
        "proxy/error paths do not retain same-user ownership checks")
require("dlclose( handle )" in wine_patch,
        "failed proxy ABI loads leak their dynamic-library handle")
require("FORGEPLAY_D3DMETAL_FRAME_GENERATION_OBSERVATION_FILE" in wine_patch and
        "framegen_observation_path_is_valid" in wine_patch,
        "pre-proxy errors do not use the Unix-native frame telemetry path")

projection_start = compatibility_patch.find(
    "static BOOL apply_forgeplay_steam_game_process_unix_environment("
)
projection_end = compatibility_patch.find("diff --git", projection_start)
require(projection_start >= 0 and projection_end > projection_start,
        "native Unix game-environment projection boundary is missing")
projection_body = compatibility_patch[projection_start:projection_end]
for key in (
    "FORGEPLAY_D3DMETAL_FRAME_GENERATION",
    "FORGEPLAY_D3DMETAL_FRAME_GENERATION_TARGET_HZ",
    "FORGEPLAY_D3DMETAL_FRAME_CHECK",
    "FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY",
    "FORGEPLAY_D3DMETAL_FRAME_GENERATION_OBSERVATION_FILE",
):
    require(f'"{key}"' in projection_body,
            f"native Unix game environment drops frame-generation key: {key}")

require("requiredD3DMetalFrameGenerationProxy" not in runner,
        "Steam launch still gates on the optional frame-generation dylib")
require("d3dMetalFrameGenerationProxyURL" in runner,
        "production proxy path projection is unavailable")
require("optionalGameModeDegradationReason" not in runner,
        "Game Mode can still silently disable frame generation")
require("applyingDegradedOptionalLaunch" not in game_mode,
        "Game Mode still contains the frame-generation clearing path")
for fragment in (
    "FrameGenerationEnvironmentContract.enabledKey",
    "FrameGenerationEnvironmentContract.targetFrameRateKey",
    "FrameGenerationEnvironmentContract.frameCheckEnabledKey",
    "FrameGenerationEnvironmentContract.proxyPathKey",
    "FrameGenerationEnvironmentContract.observationFileKey",
):
    require(fragment in runner, f"game-child environment projection is missing: {fragment}")
require("targetFrameRate > 0 || state == .error" in manager,
        "pre-proxy configuration errors cannot survive telemetry parsing")
require(("outputSourceRatio > 1.0" in manager or
         "outputSourceRatio.map { $0 >= 1.0 } ?? true" in manager) and
        "currentSourceRatio >= 1.0" in manager and
        'extendedMetrics["source_q_lower95"]' in manager and
        'extendedMetrics["session_id"]' in manager and
        'extendedMetrics["record_time"]' in manager,
        "activation completion can still accept generated output slower than source")
require("maximumCaptureDepth: UInt32 = 3" in manager and
        manager.count(".maximumCaptureDepth") >= 8,
        "capture depth three is not shared by parser and activation bounds")
for field in (
    "midpoint_dropped_presentation_stall",
    "source_present_command_buffer_bound",
    "source_capture_encoded_on_source_cb",
    "source_capture_joined",
    "source_present_uncovered",
    "presentation_receipts_pending",
    "max_presentation_receipts_pending",
    "writer_completed",
    "current_writer_completed",
):
    require(f'"{field}"' in manager,
            f"current native telemetry field is not parsed: {field}")
require("d3dMetalFrameGenerationCurrentMetricNames" in manager and
        "d3dMetalFrameGenerationWriterReceiptMetricNames" in manager and
        "d3dMetalFrameGenerationAcceptedMetricNames" in manager and
        "currentMetricsAreValid" in manager and
        "writerReceiptMetricsAreValid" in manager,
        "current writer exact telemetry set is not separated from legacy sets")
require("validatedProcessID(fields[1])" in manager,
        "telemetry parser no longer consumes the writer's bare PID field")
require('after: "epoch="' in manager and
        "fields.count == 14 || fields.count == 15" in manager,
        "telemetry parser does not match the current epoch-bearing writer")

embed_line = next(
    (
        line for line in project.splitlines()
        if "ForgePlayD3DMetalFrameGenerationProxy.dylib in Embed Dependencies" in line
    ),
    "",
)
require("CodeSignOnCopy" in embed_line,
        "generated Xcode project does not embed and sign the production proxy")
require("GCC_C_LANGUAGE_STANDARD = c17" in config,
        "frame-generation proxy is not compiled under its declared C17 contract")

print("D3DMetal frame-generation production contract checks passed")
PY

STATE_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/forgeplay-frame-generation-state.XXXXXX")"
trap 'rm -rf "$STATE_TEST_ROOT"' EXIT
xcrun --sdk macosx clang \
  -std=c17 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$(dirname "$STATE_HEADER")" \
  "$STATE_TEST_SOURCE" \
  "$STATE_SOURCE" \
  -lm \
  -o "$STATE_TEST_ROOT/state-machine-tests"
"$STATE_TEST_ROOT/state-machine-tests"
