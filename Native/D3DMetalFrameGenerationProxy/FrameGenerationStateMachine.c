#include "FrameGenerationStateMachine.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define FP_THRESHOLD_TOLERANCE_SECONDS 0.000000001
#define FP_SOURCE_TIMELINE_TOLERANCE_MULTIPLIER 0.000001
#define FP_DISPLAY_SLOT_EWMA_WEIGHT 0.25
#define FP_DISPLAY_SLOT_DISCONTINUITY_MULTIPLIER 32.0
#define FP_OPTIONAL_SERVICE_BALANCE_MINIMUM -1.0
/* One spendable slot plus its fractional carry. The singleton pair still
 * bounds actual work; this scalar never allocates or queues another frame. */
#define FP_OPTIONAL_SERVICE_BALANCE_MAXIMUM 2.0
#define FP_OPTIONAL_SERVICE_COST 1.0
#define FP_OPTIONAL_SERVICE_BALANCE_TOLERANCE 0.000000001

_Static_assert(
    FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY >= 2 * 240,
    "cadence rings must retain at least two seconds of maximum target samples"
);

typedef enum FPFrameGenerationMode
{
    FPFrameGenerationModeOff = 0,
    FPFrameGenerationModeMonitoringSource = 1,
    FPFrameGenerationModePriming = 2,
    FPFrameGenerationModeActive = 3,
    FPFrameGenerationModeError = 4,
} FPFrameGenerationMode;

typedef struct FPFrameGenerationReadyCurrent
{
    uint64_t epoch;
    uint64_t surfaceEpoch;
    uint64_t sourceSequence;
    uint64_t previousCapturedSourceSequence;
    bool hadPreviousCapture;
    bool ready;
    double sourcePresentedTime;
    double previousCapturedSourcePresentedTime;
} FPFrameGenerationReadyCurrent;

typedef struct FPFrameGenerationOutputJoin
{
    FPFrameGenerationDisplayCandidate candidate;
    bool writerCompleted;
    bool presentationSeen;
} FPFrameGenerationOutputJoin;

struct FPFrameGenerationState
{
    bool enabled;
    bool error;
    bool outputActive;
    bool hasLastCapturedSourcePresentedTime;
    bool hasLastObservedSourcePresentedTime;
    bool readyPair;
    bool pairedCurrentQueued;
    bool generationReservationActive;
    bool generationOutstanding;
    bool hasLastObservedDisplayTarget;
    bool hasObservedDisplaySlot;
    bool currentDisplayTargetValid;
    bool hasLastPresentedOutputSourceTime;
    bool hasLastOutputPresentationTime;
    uint32_t targetFrameRate;
    FPFrameGenerationMode mode;
    uint32_t writersInFlight;
    uint32_t maximumWritersInFlight;
    uint32_t outputJoinCount;
    uint32_t maximumOutputJoinCount;
    uint64_t epoch;
    uint64_t firstEpochForCurrentSurface;
    uint64_t surfaceEpoch;
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
    uint64_t nextSubmissionID;
    uint32_t readyCurrentCount;
    uint64_t lastCapturedSourceSequence;
    uint64_t readyPairEpoch;
    uint64_t readyPairSurfaceEpoch;
    uint64_t pairedCurrentEpoch;
    uint64_t pairedCurrentSurfaceEpoch;
    uint64_t generationReservationEpoch;
    uint64_t generationReservationSurfaceEpoch;
    uint64_t generationOutstandingEpoch;
    uint64_t generationOutstandingSurfaceEpoch;
    double lastCapturedSourcePresentedTime;
    double lastObservedSourcePresentedTime;
    double readyPairMidpointSourcePresentedTime;
    double pairedCurrentSourcePresentedTime;
    double generationPreviousSourcePresentedTime;
    double generationCurrentSourcePresentedTime;
    /* Deterministic optional-output capacity, not an FPS regime or learner.
     * Positive source gaps add service room and fast gaps retain signed debt. */
    double optionalServiceBalance;
    double lastObservedDisplayTarget;
    double observedDisplaySlotEWMA;
    double currentDisplayTarget;
    double lastPresentedOutputSourceTime;
    double lastOutputPresentationTime;
    bool hasCadenceWindowStartTime;
    double cadenceWindowStartTime;
    double presentationSamples[FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY];
    size_t presentationSampleCount;
    size_t presentationSampleCursor;
    double sourcePresentationSamples[
        FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY
    ];
    size_t sourcePresentationSampleCount;
    size_t sourcePresentationSampleCursor;
    double currentOutputPresentationSamples[
        FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY
    ];
    size_t currentOutputPresentationSampleCount;
    size_t currentOutputPresentationSampleCursor;
    double generatedPresentationSamples[
        FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY
    ];
    size_t generatedPresentationSampleCount;
    size_t generatedPresentationSampleCursor;
    FPFrameGenerationDisplayCandidate
        writers[FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT];
    FPFrameGenerationOutputJoin
        outputJoins[FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY];
    FPFrameGenerationReadyCurrent
        readyCurrents[FP_FRAME_GENERATION_READY_CURRENT_CAPACITY];
    char reason[64];
};

static void copy_text(char *destination, size_t capacity, const char *source)
{
    size_t index = 0;

    if (!destination || !capacity) return;
    if (!source) source = "";
    while (index + 1 < capacity && source[index])
    {
        unsigned char character = (unsigned char)source[index];
        destination[index] =
            (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') ||
            character == '-' || character == '_'
            ? (char)character : '-';
        ++index;
    }
    destination[index] = '\0';
}

static FPFrameGenerationSourceCaptureJoinDisposition
source_capture_join_disposition(FPFrameGenerationSourceCaptureJoin *join)
{
    if (!join || join->consumed)
        return FPFrameGenerationSourceCaptureJoinDuplicate;
    if (!join->presentationSeen)
        return FPFrameGenerationSourceCaptureJoinWaiting;
    if (join->captureUnavailable)
    {
        join->consumed = true;
        return FPFrameGenerationSourceCaptureJoinRetire;
    }
    if (!join->commandBufferCompleted)
        return FPFrameGenerationSourceCaptureJoinWaiting;
    join->consumed = true;
    if (join->captureEncoded && join->commandBufferSucceeded &&
        join->sourceSequence && isfinite(join->presentedTime) &&
        join->presentedTime > 0.0)
        return FPFrameGenerationSourceCaptureJoinAccept;
    return FPFrameGenerationSourceCaptureJoinRetire;
}

void FPFrameGenerationSourceCaptureJoinMarkEncoded(
    FPFrameGenerationSourceCaptureJoin *join
)
{
    if (!join || join->consumed) return;
    join->captureEncoded = true;
}

void FPFrameGenerationSourceCaptureJoinMarkUnavailable(
    FPFrameGenerationSourceCaptureJoin *join
)
{
    if (!join || join->consumed) return;
    join->captureUnavailable = true;
}

FPFrameGenerationSourceCaptureJoinDisposition
FPFrameGenerationSourceCaptureJoinRecordPresented(
    FPFrameGenerationSourceCaptureJoin *join,
    uint64_t sourceSequence,
    double presentedTime
)
{
    if (!join || join->consumed)
        return FPFrameGenerationSourceCaptureJoinDuplicate;
    if (join->presentationSeen)
        return FPFrameGenerationSourceCaptureJoinDuplicate;
    join->presentationSeen = true;
    if (sourceSequence && isfinite(presentedTime) && presentedTime > 0.0)
    {
        join->sourceSequence = sourceSequence;
        join->presentedTime = presentedTime;
    }
    return source_capture_join_disposition(join);
}

FPFrameGenerationSourceCaptureJoinDisposition
FPFrameGenerationSourceCaptureJoinRecordCompleted(
    FPFrameGenerationSourceCaptureJoin *join,
    bool succeeded
)
{
    if (!join || join->consumed)
        return FPFrameGenerationSourceCaptureJoinDuplicate;
    if (join->commandBufferCompleted)
        return FPFrameGenerationSourceCaptureJoinDuplicate;
    join->commandBufferCompleted = true;
    join->commandBufferSucceeded = succeeded;
    return source_capture_join_disposition(join);
}

static double nominal_display_slot(const FPFrameGenerationState *state)
{
    if (!state || !state->targetFrameRate) return 0.0;
    return 1.0 / (double)state->targetFrameRate;
}

static double effective_display_slot(const FPFrameGenerationState *state)
{
    double nominal = nominal_display_slot(state);

    if (!state || !state->hasObservedDisplaySlot ||
        !isfinite(state->observedDisplaySlotEWMA) ||
        state->observedDisplaySlotEWMA <= 0.0)
        return nominal;
    return fmax(nominal, state->observedDisplaySlotEWMA);
}

static void clear_generation_reservation(FPFrameGenerationState *state)
{
    state->generationReservationActive = false;
    state->generationReservationEpoch = 0;
    state->generationReservationSurfaceEpoch = 0;
    state->generationPreviousSourcePresentedTime = 0.0;
    state->generationCurrentSourcePresentedTime = 0.0;
}

static void clear_generation_outstanding(FPFrameGenerationState *state)
{
    state->generationOutstanding = false;
    state->generationOutstandingEpoch = 0;
    state->generationOutstandingSurfaceEpoch = 0;
}

static void clear_ready_pair(FPFrameGenerationState *state)
{
    state->readyPair = false;
    state->readyPairEpoch = 0;
    state->readyPairSurfaceEpoch = 0;
    state->readyPairMidpointSourcePresentedTime = 0.0;
}

static void clear_queued_paired_current(FPFrameGenerationState *state)
{
    state->pairedCurrentQueued = false;
    state->pairedCurrentEpoch = 0;
    state->pairedCurrentSurfaceEpoch = 0;
    state->pairedCurrentSourcePresentedTime = 0.0;
}

static void clear_ready_outputs(FPFrameGenerationState *state)
{
    state->readyCurrentCount = 0;
    memset(state->readyCurrents, 0, sizeof(state->readyCurrents));
    clear_ready_pair(state);
    clear_queued_paired_current(state);
}

static void clear_optional_service_balance(FPFrameGenerationState *state)
{
    if (!state) return;
    state->optionalServiceBalance = 0.0;
}

static void clear_cadence_samples(FPFrameGenerationState *state)
{
    if (!state) return;
    state->hasCadenceWindowStartTime = false;
    state->cadenceWindowStartTime = 0.0;
    state->presentationSampleCount = 0;
    state->presentationSampleCursor = 0;
    state->sourcePresentationSampleCount = 0;
    state->sourcePresentationSampleCursor = 0;
    state->currentOutputPresentationSampleCount = 0;
    state->currentOutputPresentationSampleCursor = 0;
    state->generatedPresentationSampleCount = 0;
    state->generatedPresentationSampleCursor = 0;
}

static bool epoch_belongs_to_current_surface(
    const FPFrameGenerationState *state,
    uint64_t epoch
)
{
    return state && epoch >= state->firstEpochForCurrentSurface &&
        epoch <= state->epoch;
}

static double source_timeline_tolerance(
    const FPFrameGenerationState *state
)
{
    return fmax(
        FP_THRESHOLD_TOLERANCE_SECONDS,
        nominal_display_slot(state) *
            FP_SOURCE_TIMELINE_TOLERANCE_MULTIPLIER
    );
}

static uint32_t admitted_current_count(
    const FPFrameGenerationState *state
)
{
    if (!state) return 0;
    return state->readyCurrentCount +
        (state->pairedCurrentQueued ? 1u : 0u);
}

static bool reserve_current(
    FPFrameGenerationState *state,
    uint64_t epoch,
    uint64_t sourceSequence,
    double sourcePresentedTime
)
{
    if (!epoch_belongs_to_current_surface(state, epoch) ||
        !sourceSequence ||
        !isfinite(sourcePresentedTime) || sourcePresentedTime <= 0.0)
        return false;
    if (state->readyCurrentCount)
    {
        FPFrameGenerationReadyCurrent tail =
            state->readyCurrents[state->readyCurrentCount - 1];
        if (epoch <= tail.epoch ||
            sourceSequence <= tail.sourceSequence ||
            sourcePresentedTime <= tail.sourcePresentedTime +
                source_timeline_tolerance(state))
            return false;
    }
    if (state->readyCurrentCount >=
            FP_FRAME_GENERATION_READY_CURRENT_CAPACITY ||
        admitted_current_count(state) >=
        FP_FRAME_GENERATION_READY_CURRENT_CAPACITY)
        return false;
    state->readyCurrents[state->readyCurrentCount++] =
        (FPFrameGenerationReadyCurrent){
            .epoch = epoch,
            .surfaceEpoch = state->surfaceEpoch,
            .sourceSequence = sourceSequence,
            .previousCapturedSourceSequence =
                state->lastCapturedSourceSequence,
            .hadPreviousCapture =
                state->hasLastCapturedSourcePresentedTime,
            .ready = false,
            .sourcePresentedTime = sourcePresentedTime,
            .previousCapturedSourcePresentedTime =
                state->lastCapturedSourcePresentedTime,
        };
    return true;
}

static FPFrameGenerationReadyCurrent *find_reserved_current(
    FPFrameGenerationState *state,
    uint64_t epoch
)
{
    uint32_t index;

    if (!state || !epoch) return NULL;
    for (index = 0; index < state->readyCurrentCount; ++index)
        if (state->readyCurrents[index].epoch == epoch)
            return &state->readyCurrents[index];
    return NULL;
}

static bool publish_reserved_current(
    FPFrameGenerationState *state,
    uint64_t epoch,
    double sourcePresentedTime
)
{
    FPFrameGenerationReadyCurrent *current =
        find_reserved_current(state, epoch);

    if (!current || current->ready ||
        current->surfaceEpoch != state->surfaceEpoch ||
        !isfinite(sourcePresentedTime) ||
        fabs(current->sourcePresentedTime - sourcePresentedTime) >
            source_timeline_tolerance(state))
        return false;
    current->ready = true;
    return true;
}

static bool remove_ready_current(
    FPFrameGenerationState *state,
    uint64_t epoch,
    FPFrameGenerationReadyCurrent *removed
)
{
    uint32_t index;

    if (!state || !epoch) return false;
    for (index = 0; index < state->readyCurrentCount; ++index)
    {
        if (state->readyCurrents[index].epoch != epoch) continue;
        if (removed) *removed = state->readyCurrents[index];
        if (index + 1 < state->readyCurrentCount)
        {
            memmove(
                &state->readyCurrents[index],
                &state->readyCurrents[index + 1],
                (state->readyCurrentCount - index - 1) *
                    sizeof(state->readyCurrents[0])
            );
        }
        --state->readyCurrentCount;
        memset(
            &state->readyCurrents[state->readyCurrentCount],
            0,
            sizeof(state->readyCurrents[0])
        );
        return true;
    }
    return false;
}

static bool pop_ready_current(
    FPFrameGenerationState *state,
    FPFrameGenerationReadyCurrent *removed
)
{
    if (!state || !state->readyCurrentCount ||
        !state->readyCurrents[0].ready)
        return false;
    return remove_ready_current(state, state->readyCurrents[0].epoch, removed);
}

static double last_cadence_sample(
    const double samples[FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY],
    size_t sampleCount,
    size_t sampleCursor
)
{
    size_t lastIndex;

    if (!samples || !sampleCount) return 0.0;
    lastIndex =
        (sampleCursor + FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY - 1) %
        FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY;
    return samples[lastIndex];
}

static bool append_positive_cadence_sample(
    FPFrameGenerationState *state,
    double samples[FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY],
    size_t *sampleCount,
    size_t *sampleCursor,
    double presentedTime
)
{
    double previousTime;

    if (!state || !samples || !sampleCount || !sampleCursor ||
        !isfinite(presentedTime) || presentedTime <= 0.0)
        return false;
    previousTime = last_cadence_sample(samples, *sampleCount, *sampleCursor);
    /* Presented callbacks may arrive on the CPU out of timestamp order. An old
     * callback is not a new cadence baseline and must not erase valid history. */
    if (previousTime > 0.0 &&
        presentedTime <= previousTime + FP_THRESHOLD_TOLERANCE_SECONDS)
        return false;
    if (!state->hasCadenceWindowStartTime)
    {
        state->hasCadenceWindowStartTime = true;
        state->cadenceWindowStartTime = presentedTime;
    }
    samples[*sampleCursor] = presentedTime;
    *sampleCursor = (*sampleCursor + 1) %
        FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY;
    if (*sampleCount < FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY)
        ++*sampleCount;
    return true;
}

static size_t cadence_sample_count_in_window(
    const double samples[FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY],
    size_t sampleCount,
    size_t sampleCursor,
    double windowStart,
    double observationTime
)
{
    size_t firstIndex, count = 0;

    if (!samples || !sampleCount || !isfinite(windowStart) ||
        !isfinite(observationTime) || observationTime <= windowStart)
        return 0;
    firstIndex =
        sampleCount == FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY
            ? sampleCursor : 0;
    for (size_t offset = 0; offset < sampleCount; ++offset)
    {
        double sample = samples[
            (firstIndex + offset) %
                FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY
        ];
        if (sample <= windowStart + FP_THRESHOLD_TOLERANCE_SECONDS)
            continue;
        if (sample > observationTime + FP_THRESHOLD_TOLERANCE_SECONDS)
            break;
        ++count;
    }
    return count;
}

static double latest_cadence_sample_time(
    const FPFrameGenerationState *state
)
{
    double latest = 0.0;

    if (!state) return 0.0;
    latest = fmax(latest, last_cadence_sample(
        state->presentationSamples,
        state->presentationSampleCount,
        state->presentationSampleCursor
    ));
    latest = fmax(latest, last_cadence_sample(
        state->sourcePresentationSamples,
        state->sourcePresentationSampleCount,
        state->sourcePresentationSampleCursor
    ));
    return latest;
}

static double cadence_window_start(
    const FPFrameGenerationState *state,
    double observationTime
)
{
    double windowStart;

    if (!state || !state->hasCadenceWindowStartTime ||
        !isfinite(observationTime) || observationTime <= 0.0)
        return 0.0;
    windowStart = observationTime -
        FP_FRAME_GENERATION_CADENCE_WINDOW_SECONDS;
    return fmax(windowStart, state->cadenceWindowStartTime);
}

static double cadence_hz(
    const FPFrameGenerationState *state,
    const double samples[FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY],
    size_t sampleCount,
    size_t sampleCursor,
    double observationTime
)
{
    double windowStart = cadence_window_start(state, observationTime);
    double duration = observationTime - windowStart;
    size_t count;

    if (!isfinite(duration) ||
        duration <= FP_THRESHOLD_TOLERANCE_SECONDS)
        return 0.0;
    count = cadence_sample_count_in_window(
        samples,
        sampleCount,
        sampleCursor,
        windowStart,
        observationTime
    );
    return (double)count / duration;
}

typedef struct FPFrameGenerationSourceCadenceBounds
{
    double ratio;
    double lower95;
    double upper95;
} FPFrameGenerationSourceCadenceBounds;

static FPFrameGenerationSourceCadenceBounds source_cadence_bounds(
    const FPFrameGenerationState *state,
    double observationTime
)
{
    FPFrameGenerationSourceCadenceBounds bounds = {0};
    size_t firstIndex, intervalCount = 0;
    double mean = 0.0, sumSquaredDifference = 0.0;
    double previousTime = 0.0;
    double windowStart;
    bool hasPreviousTime = false;
    const double z95 = 1.959963984540054;

    if (!state || !state->targetFrameRate ||
        state->sourcePresentationSampleCount < 2)
        return bounds;
    windowStart = cadence_window_start(state, observationTime);
    if (!isfinite(windowStart) || observationTime <= windowStart)
        return bounds;
    firstIndex =
        state->sourcePresentationSampleCount ==
            FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY
            ? state->sourcePresentationSampleCursor : 0;
    for (size_t offset = 0;
         offset < state->sourcePresentationSampleCount;
         ++offset)
    {
        size_t currentIndex = (firstIndex + offset) %
            FP_FRAME_GENERATION_CADENCE_SAMPLE_CAPACITY;
        double currentTime = state->sourcePresentationSamples[currentIndex];
        if (currentTime + FP_THRESHOLD_TOLERANCE_SECONDS < windowStart)
            continue;
        if (currentTime > observationTime + FP_THRESHOLD_TOLERANCE_SECONDS)
            break;
        if (!hasPreviousTime)
        {
            previousTime = currentTime;
            hasPreviousTime = true;
            continue;
        }
        double interval = currentTime - previousTime;
        if (!isfinite(interval) || interval <= 0.0) return bounds;
        previousTime = currentTime;
        ++intervalCount;
        double difference = interval - mean;
        mean += difference / (double)intervalCount;
        sumSquaredDifference += difference * (interval - mean);
    }
    if (!intervalCount || !isfinite(mean) || mean <= 0.0) return bounds;

    double sourceRatio = cadence_hz(
        state,
        state->sourcePresentationSamples,
        state->sourcePresentationSampleCount,
        state->sourcePresentationSampleCursor,
        observationTime
    ) / (double)state->targetFrameRate;
    double standardError = 0.0;
    if (intervalCount > 1)
    {
        double variance = sumSquaredDifference /
            (double)(intervalCount - 1);
        if (isfinite(variance) && variance > 0.0)
            standardError = sqrt(variance / (double)intervalCount);
    }
    double upperInterval = mean + z95 * standardError;
    double lowerInterval = fmax(
        FP_THRESHOLD_TOLERANCE_SECONDS,
        mean - z95 * standardError
    );
    double lowerRatio = 1.0 /
        (upperInterval * (double)state->targetFrameRate);
    double upperRatio = 1.0 /
        (lowerInterval * (double)state->targetFrameRate);
    if (!isfinite(sourceRatio) || sourceRatio < 0.0 ||
        !isfinite(lowerRatio) || lowerRatio < 0.0 ||
        !isfinite(upperRatio) || upperRatio < 0.0)
        return bounds;
    bounds.ratio = sourceRatio;
    bounds.lower95 = fmin(sourceRatio, lowerRatio);
    bounds.upper95 = fmin(1000.0, fmax(sourceRatio, upperRatio));
    return bounds;
}

static bool candidate_identity_matches(
    FPFrameGenerationDisplayCandidate left,
    FPFrameGenerationDisplayCandidate right
)
{
    return left.submissionID && right.submissionID &&
        left.submissionID == right.submissionID && left.epoch == right.epoch &&
        left.surfaceEpoch == right.surfaceEpoch && left.kind == right.kind &&
        left.pairedCurrent == right.pairedCurrent &&
        left.sourcePresentedTime == right.sourcePresentedTime;
}

static int writer_index(
    const FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
)
{
    if (!state || !candidate.submissionID) return -1;
    for (uint32_t index = 0; index < state->writersInFlight; ++index)
        if (candidate_identity_matches(state->writers[index], candidate))
            return (int)index;
    return -1;
}

static bool remove_writer_at(FPFrameGenerationState *state, uint32_t index)
{
    if (!state || index >= state->writersInFlight) return false;
    if (index + 1 < state->writersInFlight)
    {
        memmove(
            &state->writers[index],
            &state->writers[index + 1],
            (state->writersInFlight - index - 1) *
                sizeof(state->writers[0])
        );
    }
    --state->writersInFlight;
    memset(
        &state->writers[state->writersInFlight],
        0,
        sizeof(state->writers[0])
    );
    return true;
}

static int output_join_index(
    const FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
)
{
    if (!state || !candidate.submissionID) return -1;
    for (uint32_t index = 0; index < state->outputJoinCount; ++index)
        if (candidate_identity_matches(
                state->outputJoins[index].candidate,
                candidate
            ))
            return (int)index;
    return -1;
}

static bool remove_output_join_at(
    FPFrameGenerationState *state,
    uint32_t index
)
{
    if (!state || index >= state->outputJoinCount) return false;
    if (index + 1 < state->outputJoinCount)
    {
        memmove(
            &state->outputJoins[index],
            &state->outputJoins[index + 1],
            (state->outputJoinCount - index - 1) *
                sizeof(state->outputJoins[0])
        );
    }
    --state->outputJoinCount;
    memset(
        &state->outputJoins[state->outputJoinCount],
        0,
        sizeof(state->outputJoins[0])
    );
    return true;
}

static bool cancel_output_candidate(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
)
{
    int writerIndex, joinIndex;

    if (!state || !candidate.submissionID) return false;
    writerIndex = writer_index(state, candidate);
    joinIndex = output_join_index(state, candidate);
    if (writerIndex < 0 || joinIndex < 0) return false;
    (void)remove_writer_at(state, (uint32_t)writerIndex);
    (void)remove_output_join_at(state, (uint32_t)joinIndex);
    return true;
}

static bool pair_would_reverse_output_timeline(
    const FPFrameGenerationState *state
)
{
    double tolerance;

    if (!state || !state->readyPair ||
        !state->hasLastPresentedOutputSourceTime)
        return false;
    if (!isfinite(state->readyPairMidpointSourcePresentedTime) ||
        state->readyPairMidpointSourcePresentedTime <= 0.0 ||
        !isfinite(state->lastPresentedOutputSourceTime) ||
        state->lastPresentedOutputSourceTime <= 0.0)
        return false;
    tolerance = source_timeline_tolerance(state);
    return state->readyPairMidpointSourcePresentedTime <=
        state->lastPresentedOutputSourceTime + tolerance;
}

static bool pair_has_matching_current(const FPFrameGenerationState *state)
{
    if (!state || !state->readyPair) return false;
    if (!state->readyCurrentCount ||
        !state->readyCurrents[0].ready ||
        state->readyCurrents[0].epoch != state->readyPairEpoch)
        return false;
    return true;
}

static bool pair_has_effective_service_capacity(
    const FPFrameGenerationState *state
)
{
    double interval, slot;

    if (!state || !state->readyPair ||
        state->optionalServiceBalance +
            FP_OPTIONAL_SERVICE_BALANCE_TOLERANCE <
                FP_OPTIONAL_SERVICE_COST)
        return false;
    interval = state->generationCurrentSourcePresentedTime -
        state->generationPreviousSourcePresentedTime;
    slot = effective_display_slot(state);
    return isfinite(interval) && interval > 0.0 && isfinite(slot) &&
        slot > 0.0 && interval > slot + FP_THRESHOLD_TOLERANCE_SECONDS;
}

static void release_ready_pair_reservation(FPFrameGenerationState *state)
{
    clear_ready_pair(state);
    clear_generation_reservation(state);
    clear_optional_service_balance(state);
}

static bool queue_candidate(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate *candidate
)
{
    if (!state || !candidate || candidate->kind == FPFrameGenerationOutputNone ||
        state->writersInFlight >=
            FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT ||
        state->outputJoinCount >= FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY)
        return false;
    ++state->nextSubmissionID;
    if (!state->nextSubmissionID) ++state->nextSubmissionID;
    candidate->submissionID = state->nextSubmissionID;
    state->writers[state->writersInFlight++] = *candidate;
    state->outputJoins[state->outputJoinCount++] =
        (FPFrameGenerationOutputJoin){.candidate = *candidate};
    if (state->writersInFlight > state->maximumWritersInFlight)
        state->maximumWritersInFlight = state->writersInFlight;
    if (state->outputJoinCount > state->maximumOutputJoinCount)
        state->maximumOutputJoinCount = state->outputJoinCount;
    return true;
}

FPFrameGenerationState *FPFrameGenerationStateCreate(
    bool enabled,
    uint32_t targetFrameRate
)
{
    FPFrameGenerationState *state;

    if (targetFrameRate != 120 &&
        targetFrameRate != 144 &&
        targetFrameRate != 240) return NULL;
    state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->enabled = enabled;
    state->targetFrameRate = targetFrameRate;
    state->mode = enabled
        ? FPFrameGenerationModeMonitoringSource
        : FPFrameGenerationModeOff;
    state->surfaceEpoch = 1;
    state->firstEpochForCurrentSurface = 1;
    copy_text(
        state->reason,
        sizeof(state->reason),
        enabled ? "monitoring-source" : "off"
    );
    return state;
}

void FPFrameGenerationStateDestroy(FPFrameGenerationState *state)
{
    free(state);
}

double FPFrameGenerationInterpolationThreshold(
    const FPFrameGenerationState *state
)
{
    if (!state || !state->targetFrameRate) return 0.0;
    return FP_FRAME_GENERATION_THRESHOLD_MULTIPLIER /
        (double)state->targetFrameRate;
}

double FPFrameGenerationEffectiveDisplaySlotDuration(
    const FPFrameGenerationState *state
)
{
    return effective_display_slot(state);
}

uint64_t FPFrameGenerationRecordSourcePresent(
    FPFrameGenerationState *state
)
{
    if (!state || !state->enabled || state->error) return 0;
    ++state->sourcePresentSeen;
    return state->sourcePresentSeen;
}

FPFrameGenerationSourceObservation FPFrameGenerationObserveSourcePresent(
    FPFrameGenerationState *state,
    double sourcePresentedTime
)
{
    FPFrameGenerationSourceObservation observation = {0};
    double interval = 0.0;

    if (!state || !state->enabled || state->error ||
        !isfinite(sourcePresentedTime) || sourcePresentedTime <= 0.0)
        return observation;
    ++state->sourcePresentSeen;
    if (state->hasLastObservedSourcePresentedTime &&
        sourcePresentedTime <= state->lastObservedSourcePresentedTime +
            source_timeline_tolerance(state))
        return observation;
    ++state->sourcePresentAccepted;
    observation.accepted = true;
    observation.sourceSequence = state->sourcePresentAccepted;
    if (state->hasLastObservedSourcePresentedTime)
    {
        interval = sourcePresentedTime -
            state->lastObservedSourcePresentedTime;
        if (isfinite(interval) && interval > 0.0)
            observation.sourceInterval = interval;
    }
    /* A pause/loading discontinuity is a new measurement regime. Keep the
     * scheduler's source interval contract unchanged, but never average the
     * inactive wall time into the recent cadence HUD. */
    if (observation.sourceInterval >
        FP_FRAME_GENERATION_CADENCE_WINDOW_SECONDS)
    {
        clear_cadence_samples(state);
        clear_optional_service_balance(state);
    }
    (void)append_positive_cadence_sample(
        state,
        state->sourcePresentationSamples,
        &state->sourcePresentationSampleCount,
        &state->sourcePresentationSampleCursor,
        sourcePresentedTime
    );
    state->lastObservedSourcePresentedTime = sourcePresentedTime;
    state->hasLastObservedSourcePresentedTime = true;

    if (state->mode == FPFrameGenerationModeMonitoringSource &&
        observation.sourceInterval >
            FPFrameGenerationInterpolationThreshold(state) +
                FP_THRESHOLD_TOLERANCE_SECONDS)
    {
        state->mode = FPFrameGenerationModePriming;
        observation.shouldBeginCapturePriming = true;
        copy_text(state->reason, sizeof(state->reason), "capture-priming");
    }
    return observation;
}

FPFrameGenerationCapturePlan FPFrameGenerationRecordCaptureReady(
    FPFrameGenerationState *state,
    uint64_t sourceSequence,
    double sourcePresentedTime
)
{
    FPFrameGenerationCapturePlan plan = {0};
    double interval, threshold, slot, balanceIncrement;
    bool currentPairEligible = false;

    if (!state || !state->enabled || state->error ||
        (state->mode != FPFrameGenerationModePriming &&
         state->mode != FPFrameGenerationModeActive) ||
        !sourceSequence || sourceSequence > state->sourcePresentAccepted ||
        !isfinite(sourcePresentedTime) || sourcePresentedTime <= 0.0) return plan;

    if ((state->hasLastCapturedSourcePresentedTime &&
         (sourceSequence <= state->lastCapturedSourceSequence ||
          sourcePresentedTime <= state->lastCapturedSourcePresentedTime +
              source_timeline_tolerance(state))) ||
        (state->hasLastPresentedOutputSourceTime &&
         sourcePresentedTime <= state->lastPresentedOutputSourceTime +
              source_timeline_tolerance(state)))
    {
        copy_text(state->reason, sizeof(state->reason), "capture-stale");
        return plan;
    }
    if (admitted_current_count(state) >=
        FP_FRAME_GENERATION_READY_CURRENT_CAPACITY)
    {
        plan.admission =
            FPFrameGenerationCaptureAdmissionCurrentCapacityReached;
        copy_text(state->reason, sizeof(state->reason), "current-capacity-reached");
        return plan;
    }

    ++state->epoch;
    if (!state->epoch) ++state->epoch;
    plan.epoch = state->epoch;
    plan.sourceSequence = sourceSequence;
    if (!reserve_current(
            state,
            plan.epoch,
            sourceSequence,
            sourcePresentedTime
        ))
    {
        copy_text(state->reason, sizeof(state->reason), "current-reserve-failed");
        return plan;
    }
    ++state->captureReady;
    plan.accepted = true;
    plan.admission = FPFrameGenerationCaptureAdmissionCurrentReserved;
    plan.currentSourcePresentedTime = sourcePresentedTime;
    if (state->hasLastCapturedSourcePresentedTime)
    {
        plan.previousSourcePresentedTime =
            state->lastCapturedSourcePresentedTime;
        interval = sourcePresentedTime -
            state->lastCapturedSourcePresentedTime;
        if (isfinite(interval) && interval > 0.0 &&
            interval <= FP_FRAME_GENERATION_CADENCE_WINDOW_SECONDS)
        {
            if (sourceSequence - state->lastCapturedSourceSequence == 1)
            {
                threshold = FPFrameGenerationInterpolationThreshold(state);
                currentPairEligible = interval >
                    threshold + FP_THRESHOLD_TOLERANCE_SECONDS;
                slot = effective_display_slot(state);
                /* One Current consumes one service slot. Keep the signed
                 * remainder so alternating slow/fast frames cannot turn each
                 * isolated slow interval into an over-target midpoint. */
                balanceIncrement = isfinite(slot) && slot > 0.0
                    ? interval / slot - 1.0 : 0.0;
                state->optionalServiceBalance = fmin(
                    FP_OPTIONAL_SERVICE_BALANCE_MAXIMUM,
                    fmax(
                        FP_OPTIONAL_SERVICE_BALANCE_MINIMUM,
                        state->optionalServiceBalance + balanceIncrement
                    )
                );
                if (state->optionalServiceBalance < FP_OPTIONAL_SERVICE_COST &&
                    state->optionalServiceBalance +
                        FP_OPTIONAL_SERVICE_BALANCE_TOLERANCE >=
                            FP_OPTIONAL_SERVICE_COST)
                    state->optionalServiceBalance =
                        FP_OPTIONAL_SERVICE_COST;
            }
            else
            {
                clear_optional_service_balance(state);
            }
            if (currentPairEligible &&
                state->optionalServiceBalance >=
                    FP_OPTIONAL_SERVICE_COST &&
                !state->generationReservationActive &&
                !state->generationOutstanding &&
                !state->readyPair && !state->pairedCurrentQueued)
            {
                state->generationReservationActive = true;
                state->generationReservationEpoch = plan.epoch;
                state->generationReservationSurfaceEpoch = state->surfaceEpoch;
                state->generationPreviousSourcePresentedTime =
                    state->lastCapturedSourcePresentedTime;
                state->generationCurrentSourcePresentedTime = sourcePresentedTime;
                ++state->midpointAdmitted;
                plan.shouldGenerateMidpoint = true;
                plan.midpointSourcePresentedTime =
                    (state->lastCapturedSourcePresentedTime +
                     sourcePresentedTime) * 0.5;
            }
        }
        else
        {
            clear_optional_service_balance(state);
        }
    }
    state->lastCapturedSourceSequence = sourceSequence;
    state->lastCapturedSourcePresentedTime = sourcePresentedTime;
    state->hasLastCapturedSourcePresentedTime = true;
    copy_text(
        state->reason,
        sizeof(state->reason),
        plan.shouldGenerateMidpoint ? "midpoint-reserved" : "capture-ready"
    );
    return plan;
}

bool FPFrameGenerationRecordCurrentReady(
    FPFrameGenerationState *state,
    uint64_t epoch,
    double sourcePresentedTime
)
{
    if (!state || state->error ||
        (state->mode != FPFrameGenerationModePriming &&
         state->mode != FPFrameGenerationModeActive) ||
        !epoch_belongs_to_current_surface(state, epoch)) return false;
    if (!publish_reserved_current(state, epoch, sourcePresentedTime)) return false;
    copy_text(state->reason, sizeof(state->reason), "current-ready");
    return true;
}

void FPFrameGenerationRecordGeneratedSubmitted(
    FPFrameGenerationState *state,
    uint64_t epoch
)
{
    if (!state || state->error ||
        (state->mode != FPFrameGenerationModePriming &&
         state->mode != FPFrameGenerationModeActive) ||
        !state->generationReservationActive ||
        state->generationReservationEpoch != epoch ||
        state->generationReservationSurfaceEpoch != state->surfaceEpoch ||
        state->generationOutstanding)
        return;
    state->generationOutstanding = true;
    state->generationOutstandingEpoch = epoch;
    state->generationOutstandingSurfaceEpoch = state->surfaceEpoch;
    ++state->generatedSubmitted;
    state->optionalServiceBalance = fmax(
        FP_OPTIONAL_SERVICE_BALANCE_MINIMUM,
        state->optionalServiceBalance -
            FP_OPTIONAL_SERVICE_COST
    );
    copy_text(state->reason, sizeof(state->reason), "generated-submitted");
}

void FPFrameGenerationRecordGeneratedCompleted(
    FPFrameGenerationState *state,
    uint64_t epoch
)
{
    if (!state || state->error ||
        (state->mode != FPFrameGenerationModePriming &&
         state->mode != FPFrameGenerationModeActive) ||
        !state->generationOutstanding ||
        state->generationOutstandingEpoch != epoch ||
        state->generationOutstandingSurfaceEpoch != state->surfaceEpoch)
        return;
    ++state->generatedCompleted;
    clear_generation_outstanding(state);
    copy_text(state->reason, sizeof(state->reason), "generated-completed");
}

void FPFrameGenerationRecordGeneratedFailed(
    FPFrameGenerationState *state,
    uint64_t epoch
)
{
    if (!state || state->error || !epoch ||
        !epoch_belongs_to_current_surface(state, epoch))
        return;
    if (state->generationOutstanding &&
        state->generationOutstandingEpoch == epoch &&
        state->generationOutstandingSurfaceEpoch == state->surfaceEpoch)
        clear_generation_outstanding(state);
    if (state->generationReservationActive &&
        state->generationReservationEpoch == epoch &&
        state->generationReservationSurfaceEpoch == state->surfaceEpoch)
    {
        clear_generation_reservation(state);
        clear_optional_service_balance(state);
    }
    copy_text(state->reason, sizeof(state->reason), "generated-failed");
}

bool FPFrameGenerationRecordGeneratedPairReady(
    FPFrameGenerationState *state,
    uint64_t epoch
)
{
    if (!state || state->error ||
        (state->mode != FPFrameGenerationModePriming &&
         state->mode != FPFrameGenerationModeActive) ||
        !state->generationReservationActive ||
        state->generationReservationEpoch != epoch ||
        state->generationReservationSurfaceEpoch != state->surfaceEpoch)
        return false;
    if (!publish_reserved_current(
            state,
            epoch,
            state->generationCurrentSourcePresentedTime
        ))
        return false;
    state->readyPair = true;
    state->readyPairEpoch = epoch;
    state->readyPairSurfaceEpoch = state->surfaceEpoch;
    state->readyPairMidpointSourcePresentedTime =
        (state->generationPreviousSourcePresentedTime +
         state->generationCurrentSourcePresentedTime) * 0.5;
    copy_text(state->reason, sizeof(state->reason), "generated-pair-ready");
    return true;
}

uint64_t FPFrameGenerationEvictReadyMidpointForCaptureCapacity(
    FPFrameGenerationState *state
)
{
    uint64_t epoch;

    if (!state || state->error || !state->readyPair ||
        !state->generationReservationActive || state->generationOutstanding ||
        state->pairedCurrentQueued ||
        state->readyPairEpoch != state->generationReservationEpoch ||
        state->readyPairSurfaceEpoch != state->surfaceEpoch ||
        state->generationReservationSurfaceEpoch != state->surfaceEpoch)
        return 0;
    epoch = state->readyPairEpoch;
    ++state->midpointDroppedSuperseded;
    release_ready_pair_reservation(state);
    copy_text(
        state->reason,
        sizeof(state->reason),
        "midpoint-evicted-capture-capacity"
    );
    return epoch;
}

bool FPFrameGenerationCancelAcceptedCapture(
    FPFrameGenerationState *state,
    uint64_t epoch
)
{
    FPFrameGenerationReadyCurrent *reservedCurrent;
    FPFrameGenerationReadyCurrent cancelledCurrent;
    bool cancelledMidpoint;

    if (!state || state->error ||
        !(reservedCurrent = find_reserved_current(state, epoch)) ||
        reservedCurrent->sourceSequence != state->lastCapturedSourceSequence)
        return false;
    cancelledCurrent = *reservedCurrent;
    cancelledMidpoint =
        (state->readyPair && state->readyPairEpoch == epoch) ||
        (state->generationReservationActive &&
         state->generationReservationEpoch == epoch);
    if (state->readyPair && state->readyPairEpoch == epoch)
        release_ready_pair_reservation(state);
    else if (state->generationReservationActive &&
             state->generationReservationEpoch == epoch)
        clear_generation_reservation(state);
    if (!remove_ready_current(state, epoch, NULL)) return false;
    state->hasLastCapturedSourcePresentedTime =
        cancelledCurrent.hadPreviousCapture;
    state->lastCapturedSourceSequence =
        cancelledCurrent.previousCapturedSourceSequence;
    state->lastCapturedSourcePresentedTime =
        cancelledCurrent.previousCapturedSourcePresentedTime;
    if (state->captureReady) --state->captureReady;
    if (cancelledMidpoint && state->midpointAdmitted)
        --state->midpointAdmitted;
    copy_text(state->reason, sizeof(state->reason), "capture-admission-cancelled");
    return true;
}

uint64_t FPFrameGenerationDiscardStalePreactivationSeed(
    FPFrameGenerationState *state
)
{
    FPFrameGenerationReadyCurrent seed;

    if (!state || state->error || state->outputActive ||
        state->outputJoinCount != 0 || state->pairedCurrentQueued ||
        state->readyCurrentCount != 1 || !state->readyCurrents[0].ready ||
        !state->hasLastObservedSourcePresentedTime)
        return 0;
    seed = state->readyCurrents[0];
    if (!isfinite(seed.sourcePresentedTime) ||
        state->lastObservedSourcePresentedTime <=
            seed.sourcePresentedTime + source_timeline_tolerance(state))
        return 0;
    if (state->readyPair)
    {
        if (state->readyPairEpoch != seed.epoch) return 0;
        release_ready_pair_reservation(state);
    }
    else if (state->generationReservationActive)
    {
        if (state->generationReservationEpoch != seed.epoch) return 0;
        clear_generation_reservation(state);
    }
    if (!remove_ready_current(state, seed.epoch, NULL)) return 0;
    state->hasLastCapturedSourcePresentedTime = false;
    state->lastCapturedSourceSequence = 0;
    state->lastCapturedSourcePresentedTime = 0.0;
    copy_text(
        state->reason,
        sizeof(state->reason),
        "preactivation-seed-superseded"
    );
    return seed.epoch;
}

void FPFrameGenerationRebaseDisplayTargetObservation(
    FPFrameGenerationState *state
)
{
    if (!state || !state->enabled || state->error) return;
    state->hasLastObservedDisplayTarget = false;
    state->currentDisplayTargetValid = false;
    state->lastObservedDisplayTarget = 0.0;
    state->currentDisplayTarget = 0.0;
    /* Preserve both the stable EWMA and signed optional-service balance. A
     * normal no-work paused->running transition is not lost capacity. The first
     * following target is only a fresh timestamp baseline. */
}

uint64_t FPFrameGenerationHandleLateDisplayUpdate(
    FPFrameGenerationState *state
)
{
    uint64_t discardedMidpointEpoch = 0;

    if (!state || !state->enabled || state->error) return 0;
    ++state->displayUpdates;
    clear_optional_service_balance(state);
    FPFrameGenerationRebaseDisplayTargetObservation(state);
    if (state->readyPair)
    {
        discardedMidpointEpoch = state->readyPairEpoch;
        ++state->midpointDroppedLate;
        release_ready_pair_reservation(state);
        copy_text(
            state->reason,
            sizeof(state->reason),
            "midpoint-dropped-late-callback"
        );
    }
    else
    {
        copy_text(state->reason, sizeof(state->reason), "display-update-late");
    }
    return discardedMidpointEpoch;
}

void FPFrameGenerationRecordDisplayUpdate(
    FPFrameGenerationState *state,
    double targetPresentationTimestamp
)
{
    double nominal, interval;

    if (!state || !state->enabled || state->error) return;
    ++state->displayUpdates;
    nominal = nominal_display_slot(state);
    if (!isfinite(targetPresentationTimestamp) ||
        targetPresentationTimestamp <= 0.0)
    {
        clear_optional_service_balance(state);
        FPFrameGenerationRebaseDisplayTargetObservation(state);
        return;
    }

    state->currentDisplayTargetValid = true;
    state->currentDisplayTarget = targetPresentationTimestamp;
    if (state->hasLastObservedDisplayTarget)
    {
        interval = targetPresentationTimestamp - state->lastObservedDisplayTarget;
        if (isfinite(interval) && interval > 0.0 &&
            interval <= nominal * FP_DISPLAY_SLOT_DISCONTINUITY_MULTIPLIER +
                FP_THRESHOLD_TOLERANCE_SECONDS)
        {
            if (!state->hasObservedDisplaySlot)
            {
                state->observedDisplaySlotEWMA = interval;
                state->hasObservedDisplaySlot = true;
            }
            else
            {
                state->observedDisplaySlotEWMA =
                    FP_DISPLAY_SLOT_EWMA_WEIGHT * interval +
                    (1.0 - FP_DISPLAY_SLOT_EWMA_WEIGHT) *
                        state->observedDisplaySlotEWMA;
            }
        }
        else
        {
            /* Treat discontinuities as a new baseline. A prior stable cadence
             * remains useful until two continuous post-resume targets arrive. */
            clear_optional_service_balance(state);
        }
    }
    state->lastObservedDisplayTarget = targetPresentationTimestamp;
    state->hasLastObservedDisplayTarget = true;
}

FPFrameGenerationDisplayCandidate FPFrameGenerationAcquireDisplayCandidate(
    FPFrameGenerationState *state
)
{
    FPFrameGenerationDisplayCandidate candidate = {0};
    FPFrameGenerationReadyCurrent readyCurrent = {0};
    bool dropTimelineReversal, dropForServiceCapacity, dropForHeadroom;
    bool olderCurrentPrecedesPair, stalePair;
    uint32_t availableWriterSlots, availableOutputJoinSlots;

    if (!state || !state->enabled || state->error ||
        (state->mode != FPFrameGenerationModePriming &&
         state->mode != FPFrameGenerationModeActive) ||
        state->writersInFlight >=
            FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT ||
        state->outputJoinCount >= FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY)
        return candidate;
    /* The seed current is the visual-ownership transaction.  Until it has a
     * positive presentation, no newer drawable may be committed behind it. */
    if (!state->outputActive && state->outputJoinCount > 0)
        return candidate;
    availableWriterSlots =
        FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT -
            state->writersInFlight;
    availableOutputJoinSlots = FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY -
        state->outputJoinCount;
    if (state->pairedCurrentQueued)
    {
        candidate.kind = FPFrameGenerationOutputCurrent;
        candidate.epoch = state->pairedCurrentEpoch;
        candidate.surfaceEpoch = state->pairedCurrentSurfaceEpoch;
        candidate.pairedCurrent = true;
        candidate.sourcePresentedTime =
            state->pairedCurrentSourcePresentedTime;
        clear_queued_paired_current(state);
        clear_generation_reservation(state);
    }
    else
    {
        dropTimelineReversal = pair_would_reverse_output_timeline(state);
        olderCurrentPrecedesPair = state->readyPair &&
            state->readyCurrentCount && state->readyCurrents[0].ready &&
            state->readyCurrents[0].epoch < state->readyPairEpoch;
        stalePair = state->readyPair &&
            !olderCurrentPrecedesPair &&
            !pair_has_matching_current(state);
        dropForServiceCapacity = state->readyPair &&
            !pair_has_effective_service_capacity(state);
        dropForHeadroom = state->readyPair &&
            pair_has_matching_current(state) &&
            (availableWriterSlots < 2 || availableOutputJoinSlots < 2);
        if (state->readyPair &&
            (dropTimelineReversal || stalePair || dropForServiceCapacity ||
             dropForHeadroom ||
             (!state->outputActive && !olderCurrentPrecedesPair)))
        {
            if (dropTimelineReversal)
            {
                ++state->midpointDroppedLate;
                ++state->midpointDroppedTimelineReversal;
            }
            else ++state->midpointDroppedSuperseded;
            release_ready_pair_reservation(state);
            copy_text(
                state->reason,
                sizeof(state->reason),
                dropTimelineReversal ? "midpoint-dropped-timeline" :
                    (dropForServiceCapacity
                        ? "midpoint-dropped-service-capacity" :
                     (dropForHeadroom
                        ? "midpoint-dropped-headroom" :
                     (!state->outputActive
                        ? "midpoint-dropped-preactivation" :
                        "midpoint-dropped-superseded")))
            );
        }

        if (state->readyPair && olderCurrentPrecedesPair)
        {
            if (pop_ready_current(state, &readyCurrent))
            {
                candidate.kind = FPFrameGenerationOutputCurrent;
                candidate.epoch = readyCurrent.epoch;
                candidate.surfaceEpoch = readyCurrent.surfaceEpoch;
                candidate.sourcePresentedTime = readyCurrent.sourcePresentedTime;
            }
        }
        else if (state->readyPair)
        {
            if (!remove_ready_current(
                    state,
                    state->readyPairEpoch,
                    &readyCurrent
                ))
            {
                release_ready_pair_reservation(state);
                copy_text(
                    state->reason,
                    sizeof(state->reason),
                    "matching-current-unavailable"
                );
                return candidate;
            }
            candidate.kind = FPFrameGenerationOutputMidpoint;
            candidate.epoch = state->readyPairEpoch;
            candidate.surfaceEpoch = state->readyPairSurfaceEpoch;
            candidate.sourcePresentedTime =
                state->readyPairMidpointSourcePresentedTime;
            state->pairedCurrentQueued = true;
            state->pairedCurrentEpoch = state->readyPairEpoch;
            state->pairedCurrentSurfaceEpoch = state->readyPairSurfaceEpoch;
            state->pairedCurrentSourcePresentedTime =
                readyCurrent.sourcePresentedTime;
            clear_ready_pair(state);
        }
        else if (pop_ready_current(state, &readyCurrent))
        {
            candidate.kind = FPFrameGenerationOutputCurrent;
            candidate.epoch = readyCurrent.epoch;
            candidate.surfaceEpoch = readyCurrent.surfaceEpoch;
            candidate.sourcePresentedTime = readyCurrent.sourcePresentedTime;
        }
    }

    if (!queue_candidate(state, &candidate))
    {
        memset(&candidate, 0, sizeof(candidate));
        return candidate;
    }
    copy_text(
        state->reason,
        sizeof(state->reason),
        candidate.kind == FPFrameGenerationOutputMidpoint
            ? "midpoint-queued" :
            (candidate.pairedCurrent ? "paired-current-queued" :
             "current-queued")
    );
    return candidate;
}

static void record_positive_output_presentation(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    double presentedTime
)
{
    bool cadenceSampleAccepted;

    cadenceSampleAccepted = append_positive_cadence_sample(
        state,
        state->presentationSamples,
        &state->presentationSampleCount,
        &state->presentationSampleCursor,
        presentedTime
    );
    if (isfinite(candidate.sourcePresentedTime) &&
        candidate.sourcePresentedTime > 0.0 &&
        (!state->hasLastOutputPresentationTime ||
         presentedTime + FP_THRESHOLD_TOLERANCE_SECONDS >=
            state->lastOutputPresentationTime))
    {
        state->hasLastOutputPresentationTime = true;
        state->lastOutputPresentationTime = fmax(
            state->lastOutputPresentationTime,
            presentedTime
        );
        state->hasLastPresentedOutputSourceTime = true;
        state->lastPresentedOutputSourceTime = fmax(
            state->lastPresentedOutputSourceTime,
            candidate.sourcePresentedTime
        );
    }
    if (candidate.kind == FPFrameGenerationOutputMidpoint)
    {
        if (cadenceSampleAccepted)
            (void)append_positive_cadence_sample(
                state,
                state->generatedPresentationSamples,
                &state->generatedPresentationSampleCount,
                &state->generatedPresentationSampleCursor,
                presentedTime
            );
        ++state->generatedPresented;
        ++state->midpointPresented;
        copy_text(state->reason, sizeof(state->reason), "midpoint-presented");
    }
    else
    {
        if (cadenceSampleAccepted)
            (void)append_positive_cadence_sample(
                state,
                state->currentOutputPresentationSamples,
                &state->currentOutputPresentationSampleCount,
                &state->currentOutputPresentationSampleCursor,
                presentedTime
            );
        ++state->currentPresented;
        copy_text(state->reason, sizeof(state->reason), "current-presented");
    }
    if (candidate.kind == FPFrameGenerationOutputCurrent)
    {
        state->outputActive = true;
        state->mode = FPFrameGenerationModeActive;
    }
}

FPFrameGenerationOutputCallbackResult FPFrameGenerationRecordWriterCompleted(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    bool succeeded
)
{
    FPFrameGenerationOutputCallbackResult result = {0};
    int writerIndex, joinIndex;
    FPFrameGenerationOutputJoin *join;

    if (!state || state->error || candidate.kind == FPFrameGenerationOutputNone ||
        candidate.surfaceEpoch != state->surfaceEpoch)
        return result;
    joinIndex = output_join_index(state, candidate);
    if (joinIndex < 0) return result;
    join = &state->outputJoins[joinIndex];
    if (join->writerCompleted)
    {
        result.duplicate = true;
        return result;
    }
    writerIndex = writer_index(state, candidate);
    if (writerIndex < 0) return result;

    join->writerCompleted = true;
    (void)remove_writer_at(state, (uint32_t)writerIndex);
    result.matched = true;
    result.writerRetired = true;
    if (succeeded)
    {
        ++state->writerCompleted;
        if (candidate.kind == FPFrameGenerationOutputCurrent)
            ++state->currentWriterCompleted;
    }
    if (candidate.kind == FPFrameGenerationOutputMidpoint)
    {
        if (succeeded)
            FPFrameGenerationRecordGeneratedCompleted(state, candidate.epoch);
        else
            FPFrameGenerationRecordGeneratedFailed(state, candidate.epoch);
    }
    if (!succeeded || join->presentationSeen)
    {
        (void)remove_output_join_at(state, (uint32_t)joinIndex);
        result.joinRetired = true;
    }
    copy_text(
        state->reason,
        sizeof(state->reason),
        succeeded ? "writer-completed" : "writer-failed"
    );
    return result;
}

FPFrameGenerationOutputCallbackResult FPFrameGenerationRecordPresentationReceipt(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    double presentedTime
)
{
    FPFrameGenerationOutputCallbackResult result = {0};
    int joinIndex;
    FPFrameGenerationOutputJoin *join;
    bool positivePresentation;

    if (!state || state->error || candidate.kind == FPFrameGenerationOutputNone ||
        candidate.surfaceEpoch != state->surfaceEpoch)
        return result;
    joinIndex = output_join_index(state, candidate);
    if (joinIndex < 0) return result;
    join = &state->outputJoins[joinIndex];
    if (join->presentationSeen)
    {
        result.duplicate = true;
        return result;
    }
    join->presentationSeen = true;
    result.matched = true;
    positivePresentation = isfinite(presentedTime) && presentedTime > 0.0;
    if (positivePresentation)
    {
        record_positive_output_presentation(state, candidate, presentedTime);
        result.positivePresentationRecorded = true;
    }
    else
    {
        copy_text(
            state->reason,
            sizeof(state->reason),
            candidate.kind == FPFrameGenerationOutputCurrent
                ? "current-presentation-dropped"
                : "midpoint-presentation-dropped"
        );
    }
    if (join->writerCompleted)
    {
        (void)remove_output_join_at(state, (uint32_t)joinIndex);
        result.joinRetired = true;
    }
    return result;
}

void FPFrameGenerationRecordPresented(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate,
    double presentedTime
)
{
    (void)FPFrameGenerationRecordWriterCompleted(state, candidate, true);
    (void)FPFrameGenerationRecordPresentationReceipt(
        state,
        candidate,
        presentedTime
    );
}

void FPFrameGenerationRecordPresentationSkipped(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
)
{
    if (!state || candidate.kind == FPFrameGenerationOutputNone ||
        !cancel_output_candidate(state, candidate)) return;
    if (candidate.surfaceEpoch != state->surfaceEpoch) return;
    if (candidate.kind == FPFrameGenerationOutputMidpoint)
        FPFrameGenerationRecordGeneratedFailed(state, candidate.epoch);
    copy_text(state->reason, sizeof(state->reason), "presentation-skipped");
}

bool FPFrameGenerationDropStalledMidpoint(
    FPFrameGenerationState *state,
    FPFrameGenerationDisplayCandidate candidate
)
{
    int joinIndex;
    FPFrameGenerationOutputJoin join;

    if (!state || state->error ||
        candidate.kind != FPFrameGenerationOutputMidpoint ||
        candidate.surfaceEpoch != state->surfaceEpoch)
        return false;
    joinIndex = output_join_index(state, candidate);
    if (joinIndex < 0) return false;
    join = state->outputJoins[joinIndex];
    if (!join.writerCompleted || join.presentationSeen ||
        writer_index(state, candidate) >= 0)
        return false;
    (void)remove_output_join_at(state, (uint32_t)joinIndex);
    ++state->midpointDroppedLate;
    ++state->midpointDroppedPresentationStall;
    copy_text(
        state->reason,
        sizeof(state->reason),
        "midpoint-dropped-presentation-stall"
    );
    return true;
}

void FPFrameGenerationRecoverCapturePipeline(
    FPFrameGenerationState *state,
    const char *reason
)
{
    if (!state || !state->enabled || state->error) return;
    ++state->epoch;
    ++state->surfaceEpoch;
    state->firstEpochForCurrentSurface = state->epoch + 1;
    state->mode = state->outputActive
        ? FPFrameGenerationModeActive
        : FPFrameGenerationModePriming;
    state->hasLastCapturedSourcePresentedTime = false;
    state->lastCapturedSourceSequence = 0;
    state->lastCapturedSourcePresentedTime = 0.0;
    state->writersInFlight = 0;
    state->outputJoinCount = 0;
    memset(state->writers, 0, sizeof(state->writers));
    memset(state->outputJoins, 0, sizeof(state->outputJoins));
    clear_generation_reservation(state);
    clear_generation_outstanding(state);
    clear_ready_outputs(state);
    clear_optional_service_balance(state);
    FPFrameGenerationRebaseDisplayTargetObservation(state);
    copy_text(
        state->reason,
        sizeof(state->reason),
        reason && reason[0] ? reason : "capture-resource-recovery"
    );
}

void FPFrameGenerationResetForSurfaceChange(
    FPFrameGenerationState *state,
    const char *reason
)
{
    bool wasMonitoring;

    if (!state || !state->enabled || state->error) return;
    wasMonitoring = state->mode == FPFrameGenerationModeMonitoringSource;
    ++state->epoch;
    ++state->surfaceEpoch;
    state->firstEpochForCurrentSurface = state->epoch + 1;
    state->outputActive = false;
    state->mode = wasMonitoring
        ? FPFrameGenerationModeMonitoringSource
        : FPFrameGenerationModePriming;
    state->hasLastCapturedSourcePresentedTime = false;
    state->lastCapturedSourceSequence = 0;
    state->lastCapturedSourcePresentedTime = 0.0;
    state->writersInFlight = 0;
    state->outputJoinCount = 0;
    memset(state->writers, 0, sizeof(state->writers));
    memset(state->outputJoins, 0, sizeof(state->outputJoins));
    clear_generation_reservation(state);
    clear_generation_outstanding(state);
    clear_ready_outputs(state);
    clear_optional_service_balance(state);
    state->hasLastObservedDisplayTarget = false;
    state->hasObservedDisplaySlot = false;
    state->currentDisplayTargetValid = false;
    state->lastObservedDisplayTarget = 0.0;
    state->observedDisplaySlotEWMA = 0.0;
    state->currentDisplayTarget = 0.0;
    clear_cadence_samples(state);
    state->hasLastPresentedOutputSourceTime = false;
    state->hasLastOutputPresentationTime = false;
    state->lastPresentedOutputSourceTime = 0.0;
    state->lastOutputPresentationTime = 0.0;
    copy_text(
        state->reason,
        sizeof(state->reason),
        reason && reason[0] ? reason : "surface-change"
    );
}

void FPFrameGenerationSetError(
    FPFrameGenerationState *state,
    const char *reason
)
{
    if (!state) return;
    state->error = true;
    state->mode = FPFrameGenerationModeError;
    state->outputActive = false;
    state->writersInFlight = 0;
    state->outputJoinCount = 0;
    memset(state->writers, 0, sizeof(state->writers));
    memset(state->outputJoins, 0, sizeof(state->outputJoins));
    clear_generation_reservation(state);
    clear_generation_outstanding(state);
    clear_ready_outputs(state);
    clear_optional_service_balance(state);
    clear_cadence_samples(state);
    state->hasLastPresentedOutputSourceTime = false;
    state->hasLastOutputPresentationTime = false;
    state->lastPresentedOutputSourceTime = 0.0;
    state->lastOutputPresentationTime = 0.0;
    copy_text(
        state->reason,
        sizeof(state->reason),
        reason && reason[0] ? reason : "runtime-error"
    );
}

FPFrameGenerationTelemetry FPFrameGenerationTelemetrySnapshot(
    const FPFrameGenerationState *state
)
{
    return FPFrameGenerationTelemetrySnapshotAtTime(
        state,
        latest_cadence_sample_time(state)
    );
}

FPFrameGenerationTelemetry FPFrameGenerationTelemetrySnapshotAtTime(
    const FPFrameGenerationState *state,
    double observationTime
)
{
    FPFrameGenerationTelemetry telemetry = {0};
    FPFrameGenerationSourceCadenceBounds cadenceBounds = {0};

    if (!state)
    {
        copy_text(telemetry.state, sizeof(telemetry.state), "error");
        copy_text(telemetry.reason, sizeof(telemetry.reason), "state-unavailable");
        return telemetry;
    }
    if (!isfinite(observationTime) || observationTime <= 0.0)
        observationTime = latest_cadence_sample_time(state);
    telemetry.targetFrameRate = state->targetFrameRate;
    telemetry.epoch = state->epoch;
    telemetry.sourcePresentSeen = state->sourcePresentSeen;
    telemetry.sourcePresentAccepted = state->sourcePresentAccepted;
    telemetry.captureReady = state->captureReady;
    telemetry.generatedSubmitted = state->generatedSubmitted;
    telemetry.generatedCompleted = state->generatedCompleted;
    telemetry.generatedPresented = state->generatedPresented;
    telemetry.midpointPresented = state->midpointPresented;
    telemetry.currentPresented = state->currentPresented;
    telemetry.midpointAdmitted = state->midpointAdmitted;
    telemetry.midpointDroppedLate = state->midpointDroppedLate;
    telemetry.midpointDroppedTimelineReversal =
        state->midpointDroppedTimelineReversal;
    telemetry.midpointDroppedSuperseded = state->midpointDroppedSuperseded;
    telemetry.midpointDroppedPresentationStall =
        state->midpointDroppedPresentationStall;
    telemetry.displayUpdates = state->displayUpdates;
    telemetry.presentationsInFlight = state->writersInFlight;
    telemetry.maximumPresentationsInFlight =
        state->maximumWritersInFlight;
    telemetry.presentationReceiptsPending = state->outputJoinCount;
    telemetry.maximumPresentationReceiptsPending =
        state->maximumOutputJoinCount;
    telemetry.writerCompleted = state->writerCompleted;
    telemetry.currentWriterCompleted = state->currentWriterCompleted;
    telemetry.generationReservationActive =
        state->generationReservationActive;
    telemetry.generationOutstanding = state->generationOutstanding;
    telemetry.outputActive = state->outputActive;
    telemetry.finalCadenceHz = cadence_hz(
        state,
        state->presentationSamples,
        state->presentationSampleCount,
        state->presentationSampleCursor,
        observationTime
    );
    telemetry.sourceCadenceHz = cadence_hz(
        state,
        state->sourcePresentationSamples,
        state->sourcePresentationSampleCount,
        state->sourcePresentationSampleCursor,
        observationTime
    );
    telemetry.currentOutputCadenceHz = cadence_hz(
        state,
        state->currentOutputPresentationSamples,
        state->currentOutputPresentationSampleCount,
        state->currentOutputPresentationSampleCursor,
        observationTime
    );
    telemetry.generatedCadenceHz = cadence_hz(
        state,
        state->generatedPresentationSamples,
        state->generatedPresentationSampleCount,
        state->generatedPresentationSampleCursor,
        observationTime
    );
    cadenceBounds = source_cadence_bounds(state, observationTime);
    telemetry.sourceCadenceRatio = cadenceBounds.ratio;
    telemetry.sourceCadenceLower95 = cadenceBounds.lower95;
    telemetry.sourceCadenceUpper95 = cadenceBounds.upper95;
    telemetry.effectiveDisplaySlotDuration = effective_display_slot(state);
    telemetry.lastPresentedOutputSourceTime =
        state->lastPresentedOutputSourceTime;
    telemetry.readyMidpointSourceTime =
        state->readyPairMidpointSourcePresentedTime;
    if (!state->enabled || state->mode == FPFrameGenerationModeOff)
        copy_text(telemetry.state, sizeof(telemetry.state), "off");
    else if (state->error || state->mode == FPFrameGenerationModeError)
        copy_text(telemetry.state, sizeof(telemetry.state), "error");
    else if (state->mode == FPFrameGenerationModeMonitoringSource)
        copy_text(telemetry.state, sizeof(telemetry.state), "monitoring");
    else if (state->mode == FPFrameGenerationModeActive)
        copy_text(telemetry.state, sizeof(telemetry.state), "active");
    else
        copy_text(telemetry.state, sizeof(telemetry.state), "priming");
    copy_text(telemetry.reason, sizeof(telemetry.reason), state->reason);
    return telemetry;
}
