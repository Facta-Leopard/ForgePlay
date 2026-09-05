#ifndef FORGEPLAY_FRAME_GENERATION_STATE_MACHINE_H
#define FORGEPLAY_FRAME_GENERATION_STATE_MACHINE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FP_FRAME_GENERATION_THRESHOLD_MULTIPLIER 1.01
#define FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT 3
#define FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY 6
#define FP_FRAME_GENERATION_READY_CURRENT_CAPACITY 4
#define FP_FRAME_GENERATION_CADENCE_WINDOW_SECONDS 1.0
#define FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY 512

typedef struct FPFrameGenerationState FPFrameGenerationState;

typedef struct FPFrameGenerationSourceObservation
{
    bool accepted;
    bool shouldBeginCapturePriming;
    uint64_t sourceSequence;
    double sourceInterval;
} FPFrameGenerationSourceObservation;

typedef enum FPFrameGenerationCaptureAdmission
{
    FPFrameGenerationCaptureAdmissionRejected = 0,
    FPFrameGenerationCaptureAdmissionCurrentReserved = 1,
    FPFrameGenerationCaptureAdmissionCurrentCapacityReached = 2,
} FPFrameGenerationCaptureAdmission;

typedef enum FPFrameGenerationOutputKind
{
    FPFrameGenerationOutputNone = 0,
    FPFrameGenerationOutputMidpoint = 1,
    FPFrameGenerationOutputCurrent = 2,
} FPFrameGenerationOutputKind;

typedef enum FPFrameGenerationSourceCaptureJoinDisposition
{
    FPFrameGenerationSourceCaptureJoinWaiting = 0,
    FPFrameGenerationSourceCaptureJoinAccept = 1,
    FPFrameGenerationSourceCaptureJoinRetire = 2,
    FPFrameGenerationSourceCaptureJoinDuplicate = 3,
} FPFrameGenerationSourceCaptureJoinDisposition;

typedef struct FPFrameGenerationSourceCaptureJoin
{
    bool captureEncoded;
    bool presentationSeen;
    bool commandBufferCompleted;
    bool commandBufferSucceeded;
    bool captureUnavailable;
    bool consumed;
    uint64_t sourceSequence;
    double presentedTime;
} FPFrameGenerationSourceCaptureJoin;

typedef struct FPFrameGenerationCapturePlan
{
    uint64_t epoch;
    uint64_t sourceSequence;
    bool accepted;
    bool shouldGenerateMidpoint;
    FPFrameGenerationCaptureAdmission admission;
    double previousSourcePresentedTime;
    double currentSourcePresentedTime;
    double midpointSourcePresentedTime;
} FPFrameGenerationCapturePlan;

typedef struct FPFrameGenerationDisplayCandidate
{
    uint64_t epoch;
    uint64_t surfaceEpoch;
    uint64_t submissionID;
    FPFrameGenerationOutputKind kind;
    bool pairedCurrent;
    double sourcePresentedTime;
} FPFrameGenerationDisplayCandidate;

typedef struct FPFrameGenerationOutputCallbackResult
{
    bool matched;
    bool duplicate;
    bool writerRetired;
    bool joinRetired;
    bool positivePresentationRecorded;
} FPFrameGenerationOutputCallbackResult;

typedef struct FPFrameGenerationTelemetry
{
    uint32_t targetFrameRate;
    uint64_t epoch;
    uint64_t sourcePresentSeen;
    uint64_t sourcePresentAccepted;
    uint64_t captureReady;
    uint64_t generatedSubmitted;
    uint64_t generatedCompleted;
    uint64_t generatedPresented;
    uint64_t midpointPresented;
    uint64_t currentPresented;
    uint64_t midpointAdmitted;
    uint64_t midpointDroppedLate;
    uint64_t midpointDroppedTimelineReversal;
    uint64_t midpointDroppedSuperseded;
    uint64_t midpointDroppedPresentationStall;
    uint64_t displayUpdates;
    uint64_t writerCompleted;
    uint64_t currentWriterCompleted;
    uint32_t presentationsInFlight;
    uint32_t maximumPresentationsInFlight;
    uint32_t presentationReceiptsPending;
    uint32_t maximumPresentationReceiptsPending;
    bool generationReservationActive;
    bool generationOutstanding;
    bool outputActive;
    double finalCadenceHz;
    double sourceCadenceHz;
    /* Positive Current drawables actually presented by ForgePlay's output
     * layer. The stable wire key remains original_cadence_hz for compatibility;
     * Frame Check's Original label uses sourceCadenceHz instead. */
    double currentOutputCadenceHz;
    double generatedCadenceHz;
    double sourceCadenceRatio;
    double sourceCadenceLower95;
    double sourceCadenceUpper95;
    double effectiveDisplaySlotDuration;
    double lastPresentedOutputSourceTime;
    double readyMidpointSourceTime;
    char state[16];
    char reason[64];
} FPFrameGenerationTelemetry;

FPFrameGenerationState *FPFrameGenerationStateCreate(
    bool enabled,
    uint32_t targetFrameRate
);
void FPFrameGenerationSourceCaptureJoinMarkEncoded(
    FPFrameGenerationSourceCaptureJoin *join
);
void FPFrameGenerationSourceCaptureJoinMarkUnavailable(
    FPFrameGenerationSourceCaptureJoin *join
);
FPFrameGenerationSourceCaptureJoinDisposition
FPFrameGenerationSourceCaptureJoinRecordPresented(
    FPFrameGenerationSourceCaptureJoin *join,
    uint64_t sourceSequence,
    double presentedTime
);
FPFrameGenerationSourceCaptureJoinDisposition
FPFrameGenerationSourceCaptureJoinRecordCompleted(
    FPFrameGenerationSourceCaptureJoin *join,
    bool succeeded
);
void FPFrameGenerationStateDestroy(FPFrameGenerationState *state);

double FPFrameGenerationInterpolationThreshold(
    const FPFrameGenerationState *state
);
uint64_t FPFrameGenerationRecordSourcePresent(
    FPFrameGenerationState *state
);
/* Timestamp-only source monitoring is the authoritative per-present entry for
 * the capture-on-demand path. Do not also call RecordSourcePresent for the same
 * source frame. A true shouldBeginCapturePriming arms capture for a subsequent
 * frame; the observed frame itself is never counted as captured. */
FPFrameGenerationSourceObservation FPFrameGenerationObserveSourcePresent(
    FPFrameGenerationState *state,
    double sourcePresentedTime
);
FPFrameGenerationCapturePlan FPFrameGenerationRecordCaptureReady(
    FPFrameGenerationState *state,
    uint64_t sourceSequence,
    double sourcePresentedTime
);
/* Every accepted capture owns one current admission until that current is
 * presented or the surface is reset. These calls publish the already-reserved
 * admission; queue pressure cannot reject it. */
bool FPFrameGenerationRecordCurrentReady(
    FPFrameGenerationState *state,
    uint64_t epoch,
    double sourcePresentedTime
);
/* PairReady publishes captured previous/current textures. Submitted belongs at
 * the later midpoint-drawable encode boundary, and Completed belongs to that
 * display command buffer's completion callback. */
void FPFrameGenerationRecordGeneratedSubmitted(
    FPFrameGenerationState *state,
    uint64_t epoch
);
void FPFrameGenerationRecordGeneratedCompleted(
    FPFrameGenerationState *state,
    uint64_t epoch
);
/* Cancels only the failed optional midpoint submission. Its matching current
 * remains queued and later midpoint admission is unblocked. */
void FPFrameGenerationRecordGeneratedFailed(
    FPFrameGenerationState *state,
    uint64_t epoch
);
bool FPFrameGenerationRecordGeneratedPairReady(
    FPFrameGenerationState *state,
    uint64_t epoch
);
/* Retires only one ready, unsubmitted optional midpoint when its retained
 * previous texture prevents the fixed capture pool from accepting new source
 * work. The matching Current remains in the FIFO. Returns the retired epoch. */
uint64_t FPFrameGenerationEvictReadyMidpointForCaptureCapacity(
    FPFrameGenerationState *state
);
/* Rolls back an accepted capture only before its current is acquired. This is
 * for an owning texture queue's invariant failure, not normal backpressure. */
bool FPFrameGenerationCancelAcceptedCapture(
    FPFrameGenerationState *state,
    uint64_t epoch
);
/* Before first positive output only, retires one pending ready seed when a
 * newer source presentation is already visible. No submitted candidate or
 * active-output FIFO entry is ever changed. The capture history baseline is
 * cleared so the newer capture is admitted current-only. */
uint64_t FPFrameGenerationDiscardStalePreactivationSeed(
    FPFrameGenerationState *state
);

/* Call once for every usable CAMetalDisplayLink callback before acquiring its
 * output candidate. Invalid target timestamps rebase target observation. The
 * effective slot is nominal 1/N until a display slot has been measured, then
 * retains the cached service EWMA across that rebase. */
void FPFrameGenerationRecordDisplayUpdate(
    FPFrameGenerationState *state,
    double targetPresentationTimestamp
);
/* Call immediately before a normally paused display link resumes. The first
 * following target timestamp becomes a baseline without erasing the prior
 * stable EWMA or signed optional-service balance. */
void FPFrameGenerationRebaseDisplayTargetObservation(
    FPFrameGenerationState *state
);
/* Records an unusably late callback, rebases display timing, and discards only
 * an optional ready midpoint. Its current remains admitted at the FIFO head.
 * Returns the discarded midpoint epoch, or zero when none was ready. */
uint64_t FPFrameGenerationHandleLateDisplayUpdate(
    FPFrameGenerationState *state
);
double FPFrameGenerationEffectiveDisplaySlotDuration(
    const FPFrameGenerationState *state
);
FPFrameGenerationDisplayCandidate FPFrameGenerationAcquireDisplayCandidate(
    FPFrameGenerationState *state
);
/* GPU completion and WindowServer presentation are independent callbacks.
 * Both APIs are keyed by the complete candidate identity and are safe in either
 * order. GPU success retires writer ownership; positive presentation alone
 * updates visible-output telemetry and only a positive Current activates. */
FPFrameGenerationOutputCallbackResult FPFrameGenerationRecordWriterCompleted(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    bool succeeded
);
FPFrameGenerationOutputCallbackResult FPFrameGenerationRecordPresentationReceipt(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    double presentedTime
);
void FPFrameGenerationRecordPresented(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    double presentedTime
);
void FPFrameGenerationRecordPresentationSkipped(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
);
/* Atomically retires only an overdue, writer-completed optional midpoint from
 * the metadata-only output join. Its matching Current remains queued or in
 * flight, and a later drawable callback is a harmless no-op. */
bool FPFrameGenerationDropStalledMidpoint(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
);
/* Retires capture/current work for a replacement capture queue while keeping
 * the already-presented output surface as the active visual owner. */
void FPFrameGenerationRecoverCapturePipeline(
    FPFrameGenerationState *state,
    const char *reason
);
void FPFrameGenerationResetForSurfaceChange(
    FPFrameGenerationState *state,
    const char *reason
);
void FPFrameGenerationSetError(
    FPFrameGenerationState *state,
    const char *reason
);
FPFrameGenerationTelemetry FPFrameGenerationTelemetrySnapshot(
    const FPFrameGenerationState *state
);
/* Uses one recent wall-time window and one observation-time anchor for source,
 * final, current-output, and generated cadence. Passing the host monotonic time
 * lets inactive streams age to zero even when their last event was positive. */
FPFrameGenerationTelemetry FPFrameGenerationTelemetrySnapshotAtTime(
    const FPFrameGenerationState *state,
    double observationTime
);

#ifdef __cplusplus
}
#endif

#endif
