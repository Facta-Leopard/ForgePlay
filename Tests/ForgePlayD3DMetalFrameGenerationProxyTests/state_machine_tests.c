#include "FrameGenerationStateMachine.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void assert_close(double actual, double expected, double tolerance)
{
    assert(fabs(actual - expected) <= tolerance);
}

static FPFrameGenerationSourceObservation observe_source(
    FPFrameGenerationState *state,
    double sourceTime
)
{
    FPFrameGenerationSourceObservation observation =
        FPFrameGenerationObserveSourcePresent(state, sourceTime);

    assert(observation.accepted);
    assert(observation.sourceSequence != 0);
    return observation;
}

static void begin_capture_priming(
    FPFrameGenerationState *state,
    double firstCaptureTime
)
{
    double triggerInterval =
        FPFrameGenerationInterpolationThreshold(state) * 1.5;
    FPFrameGenerationSourceObservation observation;

    observation = observe_source(
        state,
        firstCaptureTime - 3.0 * triggerInterval
    );
    assert(!observation.shouldBeginCapturePriming);
    observation = observe_source(
        state,
        firstCaptureTime - triggerInterval
    );
    assert(observation.shouldBeginCapturePriming);
}

static FPFrameGenerationCapturePlan capture_source(
    FPFrameGenerationState *state,
    double sourceTime
)
{
    FPFrameGenerationSourceObservation observation =
        observe_source(state, sourceTime);
    FPFrameGenerationCapturePlan plan = FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence,
        sourceTime
    );

    if (plan.accepted && !plan.shouldGenerateMidpoint)
    {
        assert(plan.admission ==
               FPFrameGenerationCaptureAdmissionCurrentReserved);
        assert(FPFrameGenerationRecordCurrentReady(
            state,
            plan.epoch,
            sourceTime
        ));
    }
    return plan;
}

static void publish_pair(
    FPFrameGenerationState *state,
    FPFrameGenerationCapturePlan plan
)
{
    assert(plan.accepted);
    assert(plan.shouldGenerateMidpoint);
    assert(plan.admission ==
           FPFrameGenerationCaptureAdmissionCurrentReserved);
    assert(FPFrameGenerationRecordGeneratedPairReady(state, plan.epoch));
}

static void activate_with_current(
    FPFrameGenerationState *state,
    double sourceTime,
    double displayTime
)
{
    FPFrameGenerationCapturePlan seed;
    FPFrameGenerationDisplayCandidate current;

    begin_capture_priming(state, sourceTime);
    seed = capture_source(state, sourceTime);
    assert(seed.accepted);
    assert(!seed.shouldGenerateMidpoint);
    FPFrameGenerationRecordDisplayUpdate(state, displayTime);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    FPFrameGenerationRecordPresented(state, current, displayTime);
    assert(FPFrameGenerationTelemetrySnapshot(state).outputActive);
}

static void present_observed_source_as_current(
    FPFrameGenerationState *state,
    FPFrameGenerationSourceObservation observation,
    double sourceTime,
    double outputTime
)
{
    FPFrameGenerationCapturePlan plan = FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence,
        sourceTime
    );
    FPFrameGenerationDisplayCandidate candidate;

    assert(plan.accepted);
    if (plan.shouldGenerateMidpoint)
        FPFrameGenerationRecordGeneratedFailed(state, plan.epoch);
    assert(FPFrameGenerationRecordCurrentReady(
        state,
        plan.epoch,
        sourceTime
    ));
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputCurrent);
    FPFrameGenerationRecordPresented(state, candidate, outputTime);
}

static void test_common_window_distinguishes_source_from_current_output(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation observation;
    FPFrameGenerationTelemetry telemetry;
    const double origin = 100.0;

    observation = observe_source(state, origin);
    assert(!observation.shouldBeginCapturePriming);
    for (size_t index = 1; index <= 90; ++index)
    {
        double sourceTime = origin + (double)index / 90.0;
        observation = observe_source(state, sourceTime);
        if (index <= 60)
            present_observed_source_as_current(
                state,
                observation,
                sourceTime,
                origin + (double)index / 60.0
            );
    }

    telemetry = FPFrameGenerationTelemetrySnapshotAtTime(state, origin + 1.0);
    assert_close(telemetry.sourceCadenceHz, 90.0, 1e-9);
    assert_close(telemetry.currentOutputCadenceHz, 60.0, 1e-9);
    assert_close(telemetry.finalCadenceHz, 60.0, 1e-9);
    assert_close(telemetry.generatedCadenceHz, 0.0, 1e-12);
    assert(telemetry.sourceCadenceHz > telemetry.currentOutputCadenceHz);
    FPFrameGenerationStateDestroy(state);
}

static void test_common_window_output_arithmetic_and_generated_age_out(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation observation;
    FPFrameGenerationCapturePlan plan;
    FPFrameGenerationDisplayCandidate midpoint, current;
    FPFrameGenerationTelemetry active, aged;
    const double origin = 200.0;
    double sourceTime = origin;
    double outputTime = origin + 0.01;

    observation = observe_source(state, sourceTime);
    assert(!observation.shouldBeginCapturePriming);
    sourceTime += 0.02;
    observation = observe_source(state, sourceTime);
    assert(observation.shouldBeginCapturePriming);
    present_observed_source_as_current(
        state,
        observation,
        sourceTime,
        outputTime
    );

    for (size_t index = 0; index < 30; ++index)
    {
        sourceTime += 0.02;
        observation = observe_source(state, sourceTime);
        plan = FPFrameGenerationRecordCaptureReady(
            state,
            observation.sourceSequence,
            sourceTime
        );
        assert(plan.accepted);
        assert(plan.shouldGenerateMidpoint);
        publish_pair(state, plan);
        midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
        current = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
        assert(current.kind == FPFrameGenerationOutputCurrent);
        outputTime += 0.01;
        FPFrameGenerationRecordPresented(state, midpoint, outputTime);
        outputTime += 0.01;
        FPFrameGenerationRecordPresented(state, current, outputTime);
    }

    active = FPFrameGenerationTelemetrySnapshotAtTime(state, origin + 1.0);
    assert_close(active.finalCadenceHz, 61.0, 1e-9);
    assert_close(active.currentOutputCadenceHz, 31.0, 1e-9);
    assert_close(active.generatedCadenceHz, 30.0, 1e-9);
    assert_close(
        active.finalCadenceHz,
        active.currentOutputCadenceHz + active.generatedCadenceHz,
        1e-12
    );

    aged = FPFrameGenerationTelemetrySnapshotAtTime(
        state,
        outputTime + FP_FRAME_GENERATION_CADENCE_WINDOW_SECONDS + 0.01
    );
    assert_close(aged.finalCadenceHz, 0.0, 1e-12);
    assert_close(aged.currentOutputCadenceHz, 0.0, 1e-12);
    assert_close(aged.generatedCadenceHz, 0.0, 1e-12);
    FPFrameGenerationStateDestroy(state);
}

static void test_source_cadence_rebases_after_long_gap(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationTelemetry beforeGap, atRebase, afterRebase;

    (void)observe_source(state, 300.0);
    (void)observe_source(state, 300.01);
    beforeGap = FPFrameGenerationTelemetrySnapshotAtTime(state, 300.01);
    assert_close(beforeGap.sourceCadenceHz, 100.0, 1e-9);

    (void)observe_source(state, 302.0);
    atRebase = FPFrameGenerationTelemetrySnapshotAtTime(state, 302.0);
    assert_close(atRebase.sourceCadenceHz, 0.0, 1e-12);
    (void)observe_source(state, 302.01);
    afterRebase = FPFrameGenerationTelemetrySnapshotAtTime(state, 302.01);
    assert_close(afterRebase.sourceCadenceHz, 100.0, 1e-9);
    FPFrameGenerationStateDestroy(state);
}

static void test_common_window_retains_full_240_hz_target_horizon(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 240);
    FPFrameGenerationTelemetry telemetry;
    const double origin = 350.0;

    (void)observe_source(state, origin);
    for (size_t index = 1; index <= 240; ++index)
        (void)observe_source(state, origin + (double)index / 240.0);
    telemetry = FPFrameGenerationTelemetrySnapshotAtTime(state, origin + 1.0);
    assert_close(telemetry.sourceCadenceHz, 240.0, 1e-8);
    FPFrameGenerationStateDestroy(state);
}

static void test_reversed_presentation_callbacks_do_not_reset_cadence(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation observation, reversedSource;
    FPFrameGenerationTelemetry telemetry;
    const double origin = 400.0;

    observation = observe_source(state, origin);
    assert(!observation.shouldBeginCapturePriming);
    observation = observe_source(state, origin + 0.01);
    present_observed_source_as_current(
        state,
        observation,
        origin + 0.01,
        origin + 0.01
    );
    observation = observe_source(state, origin + 0.02);
    present_observed_source_as_current(
        state,
        observation,
        origin + 0.02,
        origin + 0.02
    );
    observation = observe_source(state, origin + 0.03);
    present_observed_source_as_current(
        state,
        observation,
        origin + 0.03,
        origin + 0.015
    );
    reversedSource = FPFrameGenerationObserveSourcePresent(
        state,
        origin + 0.025
    );
    assert(!reversedSource.accepted);

    telemetry = FPFrameGenerationTelemetrySnapshotAtTime(state, origin + 0.02);
    assert_close(telemetry.finalCadenceHz, 100.0, 1e-9);
    assert_close(telemetry.currentOutputCadenceHz, 100.0, 1e-9);
    assert_close(telemetry.sourceCadenceHz, 100.0, 1e-9);
    assert(telemetry.currentPresented == 3);
    assert(telemetry.sourcePresentSeen == 5);
    assert(telemetry.sourcePresentAccepted == 4);
    FPFrameGenerationStateDestroy(state);
}

static void test_off_and_threshold_contract(void)
{
    const uint32_t targets[] = {120, 144, 240};
    FPFrameGenerationState *off = FPFrameGenerationStateCreate(false, 120);

    assert(off);
    assert(!FPFrameGenerationRecordCaptureReady(off, 1, 1.0).accepted);
    assert(FPFrameGenerationAcquireDisplayCandidate(off).kind ==
           FPFrameGenerationOutputNone);
    assert(strcmp(FPFrameGenerationTelemetrySnapshot(off).state, "off") == 0);
    FPFrameGenerationStateDestroy(off);

    for (size_t index = 0;
         index < sizeof(targets) / sizeof(targets[0]);
         ++index)
    {
        FPFrameGenerationState *state =
            FPFrameGenerationStateCreate(true, targets[index]);
        assert(state);
        assert_close(
            FPFrameGenerationInterpolationThreshold(state),
            1.01 / (double)targets[index],
            1e-15
        );
        assert_close(
            FPFrameGenerationEffectiveDisplaySlotDuration(state),
            1.0 / (double)targets[index],
            1e-15
        );
        FPFrameGenerationStateDestroy(state);
    }
    assert(!FPFrameGenerationStateCreate(true, 60));
}

static void test_source_capture_join_accepts_both_callback_orders(void)
{
    FPFrameGenerationSourceCaptureJoin completionFirst = {0};
    FPFrameGenerationSourceCaptureJoin presentationFirst = {0};

    FPFrameGenerationSourceCaptureJoinMarkEncoded(&completionFirst);
    assert(FPFrameGenerationSourceCaptureJoinRecordCompleted(
        &completionFirst,
        true
    ) == FPFrameGenerationSourceCaptureJoinWaiting);
    assert(FPFrameGenerationSourceCaptureJoinRecordPresented(
        &completionFirst,
        41,
        10.25
    ) == FPFrameGenerationSourceCaptureJoinAccept);
    assert(FPFrameGenerationSourceCaptureJoinRecordCompleted(
        &completionFirst,
        true
    ) == FPFrameGenerationSourceCaptureJoinDuplicate);

    FPFrameGenerationSourceCaptureJoinMarkEncoded(&presentationFirst);
    assert(FPFrameGenerationSourceCaptureJoinRecordPresented(
        &presentationFirst,
        42,
        10.50
    ) == FPFrameGenerationSourceCaptureJoinWaiting);
    assert(FPFrameGenerationSourceCaptureJoinRecordCompleted(
        &presentationFirst,
        true
    ) == FPFrameGenerationSourceCaptureJoinAccept);
    assert(presentationFirst.sourceSequence == 42);
    assert_close(presentationFirst.presentedTime, 10.50, 1e-15);
}

static void test_source_capture_join_retires_skips_and_errors(void)
{
    FPFrameGenerationSourceCaptureJoin capacitySkip = {0};
    FPFrameGenerationSourceCaptureJoin commandError = {0};
    FPFrameGenerationSourceCaptureJoin invalidPresentation = {0};

    FPFrameGenerationSourceCaptureJoinMarkUnavailable(&capacitySkip);
    assert(FPFrameGenerationSourceCaptureJoinRecordPresented(
        &capacitySkip,
        50,
        11.0
    ) == FPFrameGenerationSourceCaptureJoinRetire);
    assert(FPFrameGenerationSourceCaptureJoinRecordPresented(
        &capacitySkip,
        50,
        11.0
    ) == FPFrameGenerationSourceCaptureJoinDuplicate);

    FPFrameGenerationSourceCaptureJoinMarkEncoded(&commandError);
    assert(FPFrameGenerationSourceCaptureJoinRecordCompleted(
        &commandError,
        false
    ) == FPFrameGenerationSourceCaptureJoinWaiting);
    assert(FPFrameGenerationSourceCaptureJoinRecordPresented(
        &commandError,
        51,
        11.1
    ) == FPFrameGenerationSourceCaptureJoinRetire);

    FPFrameGenerationSourceCaptureJoinMarkEncoded(&invalidPresentation);
    assert(FPFrameGenerationSourceCaptureJoinRecordPresented(
        &invalidPresentation,
        0,
        0.0
    ) == FPFrameGenerationSourceCaptureJoinWaiting);
    assert(FPFrameGenerationSourceCaptureJoinRecordCompleted(
        &invalidPresentation,
        true
    ) == FPFrameGenerationSourceCaptureJoinRetire);
}

static void test_source_sequence_is_monotonic_and_rejects_duplicate_time(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation first = observe_source(state, 1.0);
    FPFrameGenerationSourceObservation duplicate =
        FPFrameGenerationObserveSourcePresent(state, 1.0);
    FPFrameGenerationSourceObservation second = observe_source(state, 1.01);
    FPFrameGenerationTelemetry telemetry =
        FPFrameGenerationTelemetrySnapshot(state);

    assert(first.sourceSequence == 1);
    assert(!duplicate.accepted);
    assert(duplicate.sourceSequence == 0);
    assert(second.sourceSequence == 2);
    assert(telemetry.sourcePresentSeen == 3);
    assert(telemetry.sourcePresentAccepted == 2);
    assert_close(telemetry.sourceCadenceRatio, 100.0 / 120.0, 1e-12);
    assert_close(
        telemetry.sourceCadenceLower95,
        telemetry.sourceCadenceRatio,
        1e-12
    );
    assert_close(
        telemetry.sourceCadenceUpper95,
        telemetry.sourceCadenceRatio,
        1e-12
    );
    FPFrameGenerationStateDestroy(state);
}

static void assert_ten_millisecond_pair_suppressed_with_display_hz(
    double observedDisplayHz
)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation observation;
    FPFrameGenerationCapturePlan seed, pair;
    FPFrameGenerationDisplayCandidate current, nextCurrent;
    double displayTime = 100.0;
    double sourceTime = 200.0;

    assert(state);
    FPFrameGenerationRecordDisplayUpdate(state, displayTime);
    displayTime += 1.0 / observedDisplayHz;
    FPFrameGenerationRecordDisplayUpdate(state, displayTime);
    assert_close(
        FPFrameGenerationEffectiveDisplaySlotDuration(state),
        1.0 / observedDisplayHz,
        1e-12
    );

    observation = observe_source(state, sourceTime);
    assert(!observation.shouldBeginCapturePriming);
    sourceTime += 0.010;
    observation = observe_source(state, sourceTime);
    assert(observation.shouldBeginCapturePriming);
    seed = FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence,
        sourceTime
    );
    assert(seed.accepted);
    assert(!seed.shouldGenerateMidpoint);
    assert(FPFrameGenerationRecordCurrentReady(
        state,
        seed.epoch,
        sourceTime
    ));
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    displayTime += 1.0 / observedDisplayHz;
    FPFrameGenerationRecordPresented(state, current, displayTime);

    sourceTime += 0.010;
    observation = observe_source(state, sourceTime);
    pair = FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence,
        sourceTime
    );
    assert(pair.accepted);
    assert(!pair.shouldGenerateMidpoint);
    assert(FPFrameGenerationRecordCurrentReady(
        state,
        pair.epoch,
        sourceTime
    ));
    nextCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(nextCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(!nextCurrent.pairedCurrent);
    FPFrameGenerationRecordPresented(
        state,
        nextCurrent,
        displayTime + 1.0 / observedDisplayHz
    );
    FPFrameGenerationStateDestroy(state);
}

static void test_optional_midpoint_respects_effective_display_service(void)
{
    assert_ten_millisecond_pair_suppressed_with_display_hz(60.0);
    assert_ten_millisecond_pair_suppressed_with_display_hz(75.0);
}

static void test_midpoint_requires_consecutive_source_capture_tokens(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan gapCurrent, consecutivePair;

    activate_with_current(state, 10.0, 10.0);

    /* A presented source frame that was not captured creates a token gap. */
    (void)observe_source(state, 10.02);
    gapCurrent = capture_source(state, 10.04);
    assert(gapCurrent.accepted);
    assert(!gapCurrent.shouldGenerateMidpoint);

    consecutivePair = capture_source(state, 10.06);
    assert(consecutivePair.accepted);
    assert(consecutivePair.shouldGenerateMidpoint);
    assert(consecutivePair.sourceSequence == gapCurrent.sourceSequence + 1);
    publish_pair(state, consecutivePair);
    FPFrameGenerationStateDestroy(state);
}

static void test_capture_rejects_unknown_or_stale_source_token(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation observation;
    FPFrameGenerationCapturePlan plan;

    begin_capture_priming(state, 12.0);
    observation = observe_source(state, 12.0);
    plan = FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence + 1,
        12.0
    );
    assert(!plan.accepted);
    assert(plan.admission == FPFrameGenerationCaptureAdmissionRejected);

    plan = FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence,
        12.0
    );
    assert(plan.accepted);
    assert(FPFrameGenerationRecordCurrentReady(state, plan.epoch, 12.0));
    assert(!FPFrameGenerationRecordCaptureReady(
        state,
        observation.sourceSequence,
        12.01
    ).accepted);
    FPFrameGenerationStateDestroy(state);
}

static void test_reserved_current_blocks_fifo_until_published(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationSourceObservation firstObservation, secondObservation;
    FPFrameGenerationCapturePlan first, second;
    FPFrameGenerationDisplayCandidate candidate;

    begin_capture_priming(state, 15.0);
    firstObservation = observe_source(state, 15.0);
    first = FPFrameGenerationRecordCaptureReady(
        state,
        firstObservation.sourceSequence,
        15.0
    );
    assert(first.accepted);

    secondObservation = observe_source(state, 15.005);
    second = FPFrameGenerationRecordCaptureReady(
        state,
        secondObservation.sourceSequence,
        15.005
    );
    assert(second.accepted);
    assert(!second.shouldGenerateMidpoint);
    assert(FPFrameGenerationRecordCurrentReady(state, second.epoch, 15.005));

    FPFrameGenerationRecordDisplayUpdate(state, 15.01);
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputNone);

    assert(FPFrameGenerationRecordCurrentReady(state, first.epoch, 15.0));
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputCurrent);
    assert(candidate.epoch == first.epoch);
    FPFrameGenerationRecordPresented(state, candidate, 15.01);
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputCurrent);
    assert(candidate.epoch == second.epoch);
    FPFrameGenerationRecordPresented(state, candidate, 15.02);
    FPFrameGenerationStateDestroy(state);
}

static void test_visible_newer_source_supersedes_only_preactivation_seed(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan seed, latest;
    FPFrameGenerationSourceObservation latestObservation;
    FPFrameGenerationDisplayCandidate candidate;

    begin_capture_priming(state, 17.0);
    seed = capture_source(state, 17.0);
    assert(seed.accepted);
    assert(!seed.shouldGenerateMidpoint);
    latestObservation = observe_source(state, 17.010);

    assert(FPFrameGenerationDiscardStalePreactivationSeed(state) ==
           seed.epoch);
    assert(FPFrameGenerationAcquireDisplayCandidate(state).kind ==
           FPFrameGenerationOutputNone);
    latest = FPFrameGenerationRecordCaptureReady(
        state,
        latestObservation.sourceSequence,
        17.010
    );
    assert(latest.accepted);
    assert(!latest.shouldGenerateMidpoint);
    assert(FPFrameGenerationRecordCurrentReady(
        state,
        latest.epoch,
        17.010
    ));
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputCurrent);
    assert(candidate.epoch == latest.epoch);
    assert(candidate.epoch != seed.epoch);
    FPFrameGenerationRecordPresented(state, candidate, 17.02);
    assert(FPFrameGenerationTelemetrySnapshot(state).outputActive);
    FPFrameGenerationStateDestroy(state);
}

static void test_active_mode_never_supersedes_ready_original(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan original;
    FPFrameGenerationDisplayCandidate candidate;

    activate_with_current(state, 18.0, 18.0);
    original = capture_source(state, 18.005);
    assert(original.accepted);
    assert(!original.shouldGenerateMidpoint);
    (void)observe_source(state, 18.010);
    assert(FPFrameGenerationDiscardStalePreactivationSeed(state) == 0);
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputCurrent);
    assert(candidate.epoch == original.epoch);
    FPFrameGenerationRecordPresented(state, candidate, 18.02);
    assert(FPFrameGenerationTelemetrySnapshot(state).currentPresented == 2);
    FPFrameGenerationStateDestroy(state);
}

static void test_current_admission_capacity_never_loses_an_accepted_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan accepted[4];
    FPFrameGenerationSourceObservation rejectedObservation;
    FPFrameGenerationCapturePlan rejected;
    FPFrameGenerationDisplayCandidate current[4];
    FPFrameGenerationTelemetry telemetry;
    double sourceTime = 20.0;

    activate_with_current(state, sourceTime, sourceTime);
    for (size_t index = 0; index < 4; ++index)
    {
        sourceTime += 0.005;
        accepted[index] = capture_source(state, sourceTime);
        assert(accepted[index].accepted);
        assert(!accepted[index].shouldGenerateMidpoint);
    }

    sourceTime += 0.005;
    rejectedObservation = observe_source(state, sourceTime);
    rejected = FPFrameGenerationRecordCaptureReady(
        state,
        rejectedObservation.sourceSequence,
        sourceTime
    );
    assert(!rejected.accepted);
    assert(rejected.admission ==
           FPFrameGenerationCaptureAdmissionCurrentCapacityReached);
    assert(rejected.epoch == 0);

    for (size_t index = 0; index < 3; ++index)
    {
        current[index] = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(current[index].kind == FPFrameGenerationOutputCurrent);
        assert(current[index].epoch == accepted[index].epoch);
    }
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.presentationsInFlight == 3);
    assert(telemetry.maximumPresentationsInFlight == 3);
    FPFrameGenerationRecordPresented(state, current[0], 20.1);
    current[3] = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current[3].kind == FPFrameGenerationOutputCurrent);
    assert(current[3].epoch == accepted[3].epoch);
    for (size_t index = 1; index < 4; ++index)
        FPFrameGenerationRecordPresented(
            state,
            current[index],
            20.1 + 0.01 * (double)index
        );
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.captureReady == 5);
    assert(telemetry.currentPresented == 5);
    assert(telemetry.presentationsInFlight == 0);
    FPFrameGenerationStateDestroy(state);
}

static void test_midpoint_is_dropped_when_only_one_presentation_slot_remains(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan first, second, pair;
    FPFrameGenerationDisplayCandidate firstCurrent, secondCurrent, pairCurrent;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 25.0, 25.0);
    first = capture_source(state, 25.005);
    second = capture_source(state, 25.010);
    assert(!first.shouldGenerateMidpoint && !second.shouldGenerateMidpoint);
    firstCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    secondCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(firstCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(secondCurrent.kind == FPFrameGenerationOutputCurrent);

    pair = capture_source(state, 25.035);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    pairCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(pairCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(!pairCurrent.pairedCurrent);
    assert(pairCurrent.epoch == pair.epoch);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.presentationsInFlight == 3);
    assert(telemetry.midpointDroppedSuperseded == 1);

    FPFrameGenerationRecordPresented(state, firstCurrent, 25.01);
    FPFrameGenerationRecordPresented(state, secondCurrent, 25.02);
    FPFrameGenerationRecordPresented(state, pairCurrent, 25.03);
    FPFrameGenerationStateDestroy(state);
}

static void test_midpoint_and_current_use_exactly_two_remaining_slots(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan ordinary, pair;
    FPFrameGenerationDisplayCandidate ordinaryCurrent, midpoint, pairCurrent;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 30.0, 30.0);
    ordinary = capture_source(state, 30.005);
    assert(!ordinary.shouldGenerateMidpoint);
    ordinaryCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(ordinaryCurrent.kind == FPFrameGenerationOutputCurrent);

    pair = capture_source(state, 30.025);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    pairCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(pairCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(pairCurrent.pairedCurrent);
    assert(pairCurrent.epoch == midpoint.epoch);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.presentationsInFlight == 3);

    FPFrameGenerationRecordGeneratedCompleted(state, midpoint.epoch);
    FPFrameGenerationRecordPresented(state, ordinaryCurrent, 30.01);
    FPFrameGenerationRecordPresented(state, midpoint, 30.02);
    FPFrameGenerationRecordPresented(state, pairCurrent, 30.03);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.midpointPresented == 1);
    assert(telemetry.currentPresented == 3);
    FPFrameGenerationStateDestroy(state);
}

static void test_ready_pair_waits_behind_older_fifo_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan older, pair;
    FPFrameGenerationDisplayCandidate first, midpoint, pairedCurrent;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 35.0, 35.0);
    older = capture_source(state, 35.005);
    pair = capture_source(state, 35.025);
    assert(!older.shouldGenerateMidpoint);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);

    first = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(first.kind == FPFrameGenerationOutputCurrent);
    assert(first.epoch == older.epoch);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    assert(midpoint.epoch == pair.epoch);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    pairedCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(pairedCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(pairedCurrent.pairedCurrent);
    assert(pairedCurrent.epoch == pair.epoch);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.midpointDroppedSuperseded == 0);
    assert(!telemetry.generationReservationActive);

    FPFrameGenerationRecordPresented(state, first, 35.01);
    FPFrameGenerationRecordGeneratedCompleted(state, midpoint.epoch);
    FPFrameGenerationRecordPresented(state, midpoint, 35.02);
    FPFrameGenerationRecordPresented(state, pairedCurrent, 35.03);
    FPFrameGenerationStateDestroy(state);
}

static void test_first_reserved_pair_does_not_chase_newer_currents(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair, newer[2];
    FPFrameGenerationDisplayCandidate midpoint, current[3];
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 37.0, 37.0);
    pair = capture_source(state, 37.020);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    newer[0] = capture_source(state, 37.029);
    newer[1] = capture_source(state, 37.038);
    assert(newer[0].accepted && !newer[0].shouldGenerateMidpoint);
    assert(newer[1].accepted && !newer[1].shouldGenerateMidpoint);

    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    assert(midpoint.epoch == pair.epoch);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    current[0] = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current[0].kind == FPFrameGenerationOutputCurrent);
    assert(current[0].pairedCurrent);
    assert(current[0].epoch == pair.epoch);
    current[1] = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current[1].kind == FPFrameGenerationOutputCurrent);
    assert(!current[1].pairedCurrent);
    assert(current[1].epoch == newer[0].epoch);
    assert(FPFrameGenerationAcquireDisplayCandidate(state).kind ==
           FPFrameGenerationOutputNone);

    FPFrameGenerationRecordGeneratedCompleted(state, midpoint.epoch);
    FPFrameGenerationRecordPresented(state, midpoint, 37.040);
    current[2] = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current[2].kind == FPFrameGenerationOutputCurrent);
    assert(!current[2].pairedCurrent);
    assert(current[2].epoch == newer[1].epoch);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.midpointDroppedSuperseded == 0);
    assert(telemetry.midpointPresented == 1);
    assert(telemetry.presentationsInFlight == 3);
    assert(!telemetry.generationReservationActive);

    for (size_t index = 0; index < 3; ++index)
        FPFrameGenerationRecordPresented(
            state,
            current[index],
            37.050 + 0.010 * (double)index
        );
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.currentPresented == 4);
    assert(telemetry.presentationsInFlight == 0);
    FPFrameGenerationStateDestroy(state);
}

static void test_late_display_update_discards_only_ready_midpoint(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair;
    FPFrameGenerationDisplayCandidate current;
    FPFrameGenerationTelemetry before, after;
    double target = 40.0;
    const double observedSlot = 1.0 / 60.0;

    activate_with_current(state, 40.0, target);
    target += observedSlot;
    FPFrameGenerationRecordDisplayUpdate(state, target);
    pair = capture_source(state, 40.04);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    before = FPFrameGenerationTelemetrySnapshot(state);

    assert(FPFrameGenerationHandleLateDisplayUpdate(state) == pair.epoch);
    after = FPFrameGenerationTelemetrySnapshot(state);
    assert(after.displayUpdates == before.displayUpdates + 1);
    assert(after.midpointDroppedLate == before.midpointDroppedLate + 1);
    assert(after.readyMidpointSourceTime == 0.0);
    assert(!after.generationReservationActive);
    assert_close(
        after.effectiveDisplaySlotDuration,
        observedSlot,
        1e-12
    );

    /* The pause-sized gap is a fresh baseline, not a cadence sample. */
    target += 10.0;
    FPFrameGenerationRecordDisplayUpdate(state, target);
    assert_close(
        FPFrameGenerationEffectiveDisplaySlotDuration(state),
        observedSlot,
        1e-12
    );
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(!current.pairedCurrent);
    assert(current.epoch == pair.epoch);
    FPFrameGenerationRecordPresented(state, current, target);
    FPFrameGenerationStateDestroy(state);
}

static void test_late_update_preserves_already_paired_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair;
    FPFrameGenerationDisplayCandidate midpoint, current;

    activate_with_current(state, 45.0, 45.0);
    pair = capture_source(state, 45.02);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    assert(FPFrameGenerationHandleLateDisplayUpdate(state) == 0);
    FPFrameGenerationRecordDisplayUpdate(state, 45.03);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(current.pairedCurrent);
    assert(current.epoch == midpoint.epoch);

    FPFrameGenerationRecordPresented(state, midpoint, 45.02);
    FPFrameGenerationRecordPresented(state, current, 45.03);
    FPFrameGenerationStateDestroy(state);
}

static void test_skipped_midpoint_keeps_matching_current_live(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair, laterPair;
    FPFrameGenerationDisplayCandidate midpoint, current, laterMidpoint,
        laterCurrent;

    activate_with_current(state, 50.0, 50.0);
    pair = capture_source(state, 50.02);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    assert(FPFrameGenerationTelemetrySnapshot(state).generationOutstanding);
    FPFrameGenerationRecordGeneratedFailed(state, midpoint.epoch);
    FPFrameGenerationRecordPresentationSkipped(state, midpoint);
    assert(!FPFrameGenerationTelemetrySnapshot(state).generationOutstanding);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(current.pairedCurrent);
    assert(current.epoch == pair.epoch);
    FPFrameGenerationRecordPresented(state, current, 50.03);

    laterPair = capture_source(state, 50.04);
    assert(laterPair.shouldGenerateMidpoint);
    publish_pair(state, laterPair);
    laterMidpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(laterMidpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationRecordGeneratedSubmitted(state, laterMidpoint.epoch);
    laterCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(laterCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(laterCurrent.pairedCurrent);
    FPFrameGenerationRecordGeneratedCompleted(state, laterMidpoint.epoch);
    FPFrameGenerationRecordPresented(state, laterMidpoint, 50.04);
    FPFrameGenerationRecordPresented(state, laterCurrent, 50.05);
    assert(FPFrameGenerationTelemetrySnapshot(state).midpointPresented == 1);
    FPFrameGenerationStateDestroy(state);
}

static void test_stalled_midpoint_retires_without_consuming_matching_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair;
    FPFrameGenerationDisplayCandidate midpoint, current;
    FPFrameGenerationTelemetry before, afterDrop, afterLateCallback;
    FPFrameGenerationOutputCallbackResult completion;

    activate_with_current(state, 52.0, 52.0);
    pair = capture_source(state, 52.02);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    before = FPFrameGenerationTelemetrySnapshot(state);
    assert(before.presentationsInFlight == 1);
    assert(before.generationOutstanding);

    completion = FPFrameGenerationRecordWriterCompleted(
        state,
        midpoint,
        true
    );
    assert(completion.matched && completion.writerRetired);
    assert(!completion.joinRetired);
    assert(FPFrameGenerationDropStalledMidpoint(state, midpoint));
    afterDrop = FPFrameGenerationTelemetrySnapshot(state);
    assert(afterDrop.presentationsInFlight == 0);
    assert(!afterDrop.generationOutstanding);
    assert(afterDrop.midpointDroppedLate == before.midpointDroppedLate + 1);
    assert(afterDrop.midpointDroppedPresentationStall == 1);
    assert(strcmp(
        afterDrop.reason,
        "midpoint-dropped-presentation-stall"
    ) == 0);

    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(current.pairedCurrent);
    assert(current.epoch == midpoint.epoch);
    FPFrameGenerationRecordPresented(state, current, 52.03);
    assert(FPFrameGenerationTelemetrySnapshot(state).currentPresented == 2);

    /* A delayed completion/presentation callback cannot reinsert or count the
     * midpoint after both ownership ledgers have retired it. */
    assert(!FPFrameGenerationRecordPresentationReceipt(
        state,
        midpoint,
        52.04
    ).matched);
    assert(!FPFrameGenerationDropStalledMidpoint(state, midpoint));
    afterLateCallback = FPFrameGenerationTelemetrySnapshot(state);
    assert(afterLateCallback.presentationsInFlight == 0);
    assert(afterLateCallback.generatedCompleted ==
           before.generatedCompleted + 1);
    assert(afterLateCallback.midpointPresented == before.midpointPresented);
    assert(afterLateCallback.currentPresented == 2);
    assert(afterLateCallback.outputActive);
    FPFrameGenerationStateDestroy(state);
}

static void test_cancel_accepted_capture_preserves_older_fifo_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan older, pair, afterCancellation;
    FPFrameGenerationDisplayCandidate current, nextCurrent;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 55.0, 55.0);
    older = capture_source(state, 55.005);
    pair = capture_source(state, 55.025);
    assert(!older.shouldGenerateMidpoint);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    assert(FPFrameGenerationCancelAcceptedCapture(state, pair.epoch));
    assert(!FPFrameGenerationCancelAcceptedCapture(state, pair.epoch));

    /* The cancelled slot never became native history. Restoring the preceding
     * capture token prevents the next capture from pairing across that gap. */
    afterCancellation = capture_source(state, 55.045);
    assert(afterCancellation.accepted);
    assert(!afterCancellation.shouldGenerateMidpoint);

    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(current.epoch == older.epoch);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(!telemetry.generationReservationActive);
    assert(telemetry.readyMidpointSourceTime == 0.0);
    FPFrameGenerationRecordPresented(state, current, 55.01);
    nextCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(nextCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(nextCurrent.epoch == afterCancellation.epoch);
    FPFrameGenerationRecordPresented(state, nextCurrent, 55.02);
    FPFrameGenerationStateDestroy(state);
}

static void test_capture_recovery_keeps_output_owner_and_reseeds_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair, seed;
    FPFrameGenerationDisplayCandidate candidate;
    FPFrameGenerationTelemetry before, recovered;

    activate_with_current(state, 58.0, 58.0);
    pair = capture_source(state, 58.02);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputMidpoint);
    before = FPFrameGenerationTelemetrySnapshot(state);
    assert(before.outputActive);

    FPFrameGenerationRecoverCapturePipeline(
        state,
        "capture-resource-recovery"
    );
    recovered = FPFrameGenerationTelemetrySnapshot(state);
    assert(recovered.outputActive);
    assert(strcmp(recovered.state, "active") == 0);
    assert(recovered.presentationsInFlight == 0);
    assert(!recovered.generationReservationActive);
    assert(recovered.currentPresented == before.currentPresented);

    seed = capture_source(state, 58.04);
    assert(seed.accepted);
    assert(!seed.shouldGenerateMidpoint);
    candidate = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(candidate.kind == FPFrameGenerationOutputCurrent);
    FPFrameGenerationRecordPresented(state, candidate, 58.05);
    assert(FPFrameGenerationTelemetrySnapshot(state).outputActive);
    FPFrameGenerationStateDestroy(state);
}

static void present_one_capture_plan(
    FPFrameGenerationState *state,
    FPFrameGenerationCapturePlan plan,
    double displaySlot,
    double *outputTime
)
{
    FPFrameGenerationDisplayCandidate midpoint, current;

    assert(state && plan.accepted && outputTime);
    if (plan.shouldGenerateMidpoint)
    {
        publish_pair(state, plan);
        midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
        FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
        current = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(current.kind == FPFrameGenerationOutputCurrent);
        assert(current.pairedCurrent);
        assert(current.epoch == midpoint.epoch);
        FPFrameGenerationRecordGeneratedCompleted(state, midpoint.epoch);
        *outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, midpoint, *outputTime);
        *outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, current, *outputTime);
    }
    else
    {
        current = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(current.kind == FPFrameGenerationOutputCurrent);
        assert(!current.pairedCurrent);
        assert(current.epoch == plan.epoch);
        *outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, current, *outputTime);
    }
}

static uint64_t run_continuous_service_credit_case(
    double sourceHz,
    double displayHz,
    size_t sourceFrameCount
)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationTelemetry telemetry;
    double sourceTime = 100.0;
    double outputTime = sourceTime;
    double displaySlot = 1.0 / displayHz;

    activate_with_current(state, sourceTime, outputTime);
    if (displayHz != 120.0)
    {
        FPFrameGenerationRecordDisplayUpdate(
            state,
            outputTime + displaySlot
        );
        assert_close(
            FPFrameGenerationEffectiveDisplaySlotDuration(state),
            displaySlot,
            1e-12
        );
    }
    for (size_t index = 0; index < sourceFrameCount; ++index)
    {
        FPFrameGenerationCapturePlan plan;

        sourceTime += 1.0 / sourceHz;
        plan = capture_source(state, sourceTime);
        assert(plan.accepted);
        present_one_capture_plan(state, plan, displaySlot, &outputTime);
    }
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.currentPresented == sourceFrameCount + 1);
    assert(telemetry.presentationsInFlight == 0);
    FPFrameGenerationStateDestroy(state);
    return telemetry.midpointPresented;
}

static void test_fractional_service_credit_rate_matrix(void)
{
    /* Non-divisor source rates must retain the fractional surplus left after
     * one midpoint. At 75 source Hz, 120 service slots leave 45 optional slots;
     * clipping 1.2 credits to 1 before spending loses that remainder. */
    assert(run_continuous_service_credit_case(75.0, 120.0, 75) == 45);
    assert(run_continuous_service_credit_case(70.0, 120.0, 70) == 50);
    assert(run_continuous_service_credit_case(85.0, 120.0, 85) == 35);
    assert(run_continuous_service_credit_case(95.0, 120.0, 95) == 25);
    assert(run_continuous_service_credit_case(100.0, 120.0, 100) == 20);
    assert(run_continuous_service_credit_case(119.0, 120.0, 119) == 0);
    assert(run_continuous_service_credit_case(90.0, 100.0, 90) == 10);
    assert(run_continuous_service_credit_case(90.0, 90.0, 90) == 0);
    assert(run_continuous_service_credit_case(90.0, 80.0, 90) == 0);
}

static void test_signed_credit_does_not_overgenerate_alternating_intervals(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationTelemetry telemetry;
    double sourceTime = 200.0;
    double outputTime = sourceTime;
    const double displaySlot = 1.0 / 120.0;

    activate_with_current(state, sourceTime, outputTime);
    for (size_t cycle = 0; cycle < 100; ++cycle)
    {
        FPFrameGenerationCapturePlan plan;

        sourceTime += 0.012;
        plan = capture_source(state, sourceTime);
        present_one_capture_plan(state, plan, displaySlot, &outputTime);
        sourceTime += 0.005;
        plan = capture_source(state, sourceTime);
        present_one_capture_plan(state, plan, displaySlot, &outputTime);
    }
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.currentPresented == 201);
    assert(telemetry.midpointPresented == 4);
    assert(telemetry.presentationsInFlight == 0);
    FPFrameGenerationStateDestroy(state);
}

static void test_fractional_carry_with_display_cadence_and_delayed_receipts(void)
{
    const unsigned sourceRates[] = {70, 75, 85, 95};
    const unsigned displayRate = 120, durationSeconds = 4;
    for (size_t rateIndex = 0; rateIndex < 4; ++rateIndex)
    {
        const unsigned sourceRate = sourceRates[rateIndex];
        const unsigned sourceLimit = sourceRate * durationSeconds;
        FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, displayRate);
        struct {
            FPFrameGenerationDisplayCandidate candidate;
            unsigned dueTick;
            double displayedAt;
        } pending[FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY] = {0};
        unsigned sourceCount = 0, currentCount = 0;
        uint64_t expectedPairedEpoch = 0;
        double lastSubmittedSourceTime = 700.0;
        activate_with_current(state, 700.0, 700.0);
        /* One candidate per real display slot. GPU completion is immediate,
         * but actual-presentation callbacks arrive three slots later. */
        for (unsigned tick = 1; tick <= displayRate * durationSeconds + 12; ++tick)
        {
            const double now = 700.0 + (double)tick / displayRate;
            for (size_t index = 0; index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY; ++index)
            {
                if (pending[index].candidate.submissionID && pending[index].dueTick == tick)
                {
                    assert(FPFrameGenerationRecordPresentationReceipt(
                        state, pending[index].candidate, pending[index].displayedAt
                    ).joinRetired);
                    pending[index].candidate = (FPFrameGenerationDisplayCandidate){0};
                }
            }
            unsigned dueSources = tick * sourceRate / displayRate;
            if (dueSources > sourceLimit) dueSources = sourceLimit;
            while (sourceCount < dueSources)
            {
                FPFrameGenerationCapturePlan plan = capture_source(
                    state, 700.0 + (double)++sourceCount / sourceRate
                );
                assert(plan.accepted);
                if (plan.shouldGenerateMidpoint) publish_pair(state, plan);
            }
            FPFrameGenerationRecordDisplayUpdate(state, now);
            FPFrameGenerationDisplayCandidate candidate = FPFrameGenerationAcquireDisplayCandidate(state);
            if (candidate.kind == FPFrameGenerationOutputNone) continue;
            assert(candidate.sourcePresentedTime > lastSubmittedSourceTime);
            lastSubmittedSourceTime = candidate.sourcePresentedTime;
            if (expectedPairedEpoch)
            {
                assert(candidate.kind == FPFrameGenerationOutputCurrent);
                assert(candidate.pairedCurrent && candidate.epoch == expectedPairedEpoch);
                expectedPairedEpoch = 0;
            }
            if (candidate.kind == FPFrameGenerationOutputMidpoint)
            {
                FPFrameGenerationRecordGeneratedSubmitted(state, candidate.epoch);
                expectedPairedEpoch = candidate.epoch;
            }
            else
            {
                assert_close(candidate.sourcePresentedTime,
                    700.0 + (double)++currentCount / sourceRate, 1e-8);
            }
            assert(FPFrameGenerationRecordWriterCompleted(state, candidate, true).writerRetired);
            size_t receiptIndex = 0;
            while (receiptIndex < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY &&
                   pending[receiptIndex].candidate.submissionID) ++receiptIndex;
            assert(receiptIndex < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY);
            pending[receiptIndex].candidate = candidate;
            pending[receiptIndex].dueTick = tick + 3;
            pending[receiptIndex].displayedAt = now;
        }
        FPFrameGenerationTelemetry telemetry = FPFrameGenerationTelemetrySnapshot(state);
        assert(currentCount == sourceLimit && telemetry.currentPresented == sourceLimit + 1);
        /* A final fractional slot may await a new pair while the last
         * matching Current drains. It must not grow into a sustained deficit. */
        const uint64_t spareSlots = (displayRate - sourceRate) * durationSeconds;
        assert(telemetry.midpointPresented <= spareSlots);
        assert(telemetry.midpointPresented + 1 >= spareSlots);
        assert(telemetry.presentationsInFlight == 0 && telemetry.presentationReceiptsPending == 0);
        assert(expectedPairedEpoch == 0);
        FPFrameGenerationStateDestroy(state);
    }
}

static void test_ninety_hz_three_capture_bursts_use_one_optional_slot(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    double sourceTime = 300.0;
    double outputTime = sourceTime;
    const double sourceSlot = 1.0 / 90.0;
    const double displaySlot = 1.0 / 120.0;

    activate_with_current(state, sourceTime, outputTime);
    for (size_t cycle = 0; cycle < 30; ++cycle)
    {
        FPFrameGenerationCapturePlan plans[3];
        FPFrameGenerationDisplayCandidate first, second, midpoint, current;

        for (size_t index = 0; index < 3; ++index)
        {
            sourceTime += sourceSlot;
            plans[index] = capture_source(state, sourceTime);
            assert(plans[index].accepted);
            if (index == 0)
            {
                /* Native no-work pause/resume rebases target observation. It
                 * must not erase the fractional capacity accumulated between
                 * phase-batched capture completions. */
                FPFrameGenerationRebaseDisplayTargetObservation(state);
                FPFrameGenerationRecordDisplayUpdate(
                    state,
                    outputTime + displaySlot
                );
            }
        }
        assert(!plans[0].shouldGenerateMidpoint);
        assert(!plans[1].shouldGenerateMidpoint);
        assert(plans[2].shouldGenerateMidpoint);
        publish_pair(state, plans[2]);
        FPFrameGenerationRebaseDisplayTargetObservation(state);
        FPFrameGenerationRecordDisplayUpdate(
            state,
            outputTime + displaySlot
        );
        assert(FPFrameGenerationTelemetrySnapshot(state).generationReservationActive);

        first = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(first.kind == FPFrameGenerationOutputCurrent);
        assert(first.epoch == plans[0].epoch);
        outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, first, outputTime);

        second = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(second.kind == FPFrameGenerationOutputCurrent);
        assert(second.epoch == plans[1].epoch);
        outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, second, outputTime);

        midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
        assert(midpoint.epoch == plans[2].epoch);
        assert(midpoint.sourcePresentedTime >
               plans[1].currentSourcePresentedTime);
        assert(midpoint.sourcePresentedTime <
               plans[2].currentSourcePresentedTime);
        FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
        current = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(current.kind == FPFrameGenerationOutputCurrent);
        assert(current.pairedCurrent);
        assert(current.epoch == plans[2].epoch);
        FPFrameGenerationRecordGeneratedCompleted(state, midpoint.epoch);
        outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, midpoint, outputTime);
        outputTime += displaySlot;
        FPFrameGenerationRecordPresented(state, current, outputTime);
    }
    FPFrameGenerationTelemetry telemetry =
        FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.midpointAdmitted == 30);
    assert(telemetry.midpointPresented == 30);
    assert(telemetry.currentPresented == 91);
    assert(telemetry.midpointDroppedSuperseded == 0);
    assert(telemetry.presentationsInFlight == 0);
    FPFrameGenerationStateDestroy(state);
}

static void test_fast_capture_after_reservation_drops_only_optional_midpoint(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair, fastCurrent;
    FPFrameGenerationDisplayCandidate first, second;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 400.0, 400.0);
    pair = capture_source(state, 400.020);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    /* 20 ms earns 1.4 slots; 4 ms spends 0.52, leaving less than a
     * midpoint. A 5 ms gap would leave exactly one usable slot. */
    fastCurrent = capture_source(state, 400.024);
    assert(fastCurrent.accepted);
    assert(!fastCurrent.shouldGenerateMidpoint);

    first = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(first.kind == FPFrameGenerationOutputCurrent);
    assert(!first.pairedCurrent);
    assert(first.epoch == pair.epoch);
    FPFrameGenerationRecordPresented(state, first, 400.030);
    second = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(second.kind == FPFrameGenerationOutputCurrent);
    assert(second.epoch == fastCurrent.epoch);
    FPFrameGenerationRecordPresented(state, second, 400.035);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.midpointPresented == 0);
    assert(telemetry.midpointDroppedSuperseded == 1);
    assert(telemetry.currentPresented == 3);
    FPFrameGenerationStateDestroy(state);
}

static void test_capture_capacity_evicts_only_ready_optional_midpoint(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair, submittedPair;
    FPFrameGenerationDisplayCandidate current, midpoint, pairedCurrent;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 500.0, 500.0);
    pair = capture_source(state, 500.020);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    assert(FPFrameGenerationEvictReadyMidpointForCaptureCapacity(state) ==
           pair.epoch);
    assert(FPFrameGenerationEvictReadyMidpointForCaptureCapacity(state) == 0);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(!current.pairedCurrent);
    assert(current.epoch == pair.epoch);
    FPFrameGenerationRecordPresented(state, current, 500.030);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.currentPresented == 2);
    assert(telemetry.midpointPresented == 0);
    assert(telemetry.midpointDroppedSuperseded == 1);
    assert(!telemetry.generationReservationActive);

    submittedPair = capture_source(state, 500.050);
    assert(submittedPair.shouldGenerateMidpoint);
    publish_pair(state, submittedPair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    assert(FPFrameGenerationEvictReadyMidpointForCaptureCapacity(state) == 0);
    pairedCurrent = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(pairedCurrent.kind == FPFrameGenerationOutputCurrent);
    assert(pairedCurrent.pairedCurrent);
    FPFrameGenerationRecordGeneratedCompleted(state, midpoint.epoch);
    FPFrameGenerationRecordPresented(state, midpoint, 500.060);
    FPFrameGenerationRecordPresented(state, pairedCurrent, 500.070);
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.midpointPresented == 1);
    assert(telemetry.currentPresented == 3);
    FPFrameGenerationStateDestroy(state);
}

static FPFrameGenerationDisplayCandidate acquire_preactivation_current(
    FPFrameGenerationState *state,
    double sourceTime
)
{
    FPFrameGenerationCapturePlan seed;
    FPFrameGenerationDisplayCandidate current;

    begin_capture_priming(state, sourceTime);
    seed = capture_source(state, sourceTime);
    assert(seed.accepted && !seed.shouldGenerateMidpoint);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    return current;
}

static void test_output_join_callbacks_are_order_independent(void)
{
    FPFrameGenerationState *completionFirst =
        FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationDisplayCandidate first =
        acquire_preactivation_current(completionFirst, 600.0);
    FPFrameGenerationOutputCallbackResult result;
    FPFrameGenerationTelemetry telemetry;

    telemetry = FPFrameGenerationTelemetrySnapshot(completionFirst);
    assert(telemetry.presentationsInFlight == 1);
    assert(telemetry.presentationReceiptsPending == 1);
    assert(!telemetry.outputActive);
    result = FPFrameGenerationRecordWriterCompleted(
        completionFirst,
        first,
        true
    );
    assert(result.matched && result.writerRetired && !result.joinRetired);
    telemetry = FPFrameGenerationTelemetrySnapshot(completionFirst);
    assert(telemetry.presentationsInFlight == 0);
    assert(telemetry.presentationReceiptsPending == 1);
    assert(telemetry.writerCompleted == 1);
    assert(telemetry.currentWriterCompleted == 1);
    assert(!telemetry.outputActive);
    /* Writer completion cannot let a newer seed pass before the first actual
     * positive Current receipt transfers visual ownership. */
    assert(FPFrameGenerationAcquireDisplayCandidate(completionFirst).kind ==
           FPFrameGenerationOutputNone);
    result = FPFrameGenerationRecordWriterCompleted(
        completionFirst,
        first,
        true
    );
    assert(!result.matched && result.duplicate);
    result = FPFrameGenerationRecordPresentationReceipt(
        completionFirst,
        first,
        600.01
    );
    assert(result.matched && result.joinRetired);
    assert(result.positivePresentationRecorded);
    telemetry = FPFrameGenerationTelemetrySnapshot(completionFirst);
    assert(telemetry.presentationReceiptsPending == 0);
    assert(telemetry.currentPresented == 1);
    assert(telemetry.outputActive);
    result = FPFrameGenerationRecordPresentationReceipt(
        completionFirst,
        first,
        600.02
    );
    assert(!result.matched && !result.positivePresentationRecorded);
    assert(FPFrameGenerationTelemetrySnapshot(completionFirst).
           currentPresented == 1);
    FPFrameGenerationStateDestroy(completionFirst);

    FPFrameGenerationState *presentationFirst =
        FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationDisplayCandidate second =
        acquire_preactivation_current(presentationFirst, 610.0);
    result = FPFrameGenerationRecordPresentationReceipt(
        presentationFirst,
        second,
        610.01
    );
    assert(result.matched && !result.joinRetired);
    assert(result.positivePresentationRecorded);
    telemetry = FPFrameGenerationTelemetrySnapshot(presentationFirst);
    assert(telemetry.presentationsInFlight == 1);
    assert(telemetry.presentationReceiptsPending == 1);
    assert(telemetry.currentPresented == 1);
    assert(telemetry.outputActive);
    result = FPFrameGenerationRecordPresentationReceipt(
        presentationFirst,
        second,
        610.02
    );
    assert(!result.matched && result.duplicate);
    assert(FPFrameGenerationTelemetrySnapshot(presentationFirst).
           currentPresented == 1);
    result = FPFrameGenerationRecordWriterCompleted(
        presentationFirst,
        second,
        true
    );
    assert(result.matched && result.writerRetired && result.joinRetired);
    telemetry = FPFrameGenerationTelemetrySnapshot(presentationFirst);
    assert(telemetry.presentationsInFlight == 0);
    assert(telemetry.presentationReceiptsPending == 0);
    assert(telemetry.writerCompleted == 1);
    FPFrameGenerationStateDestroy(presentationFirst);
}

static void test_nonpositive_current_receipt_retires_and_fresh_current_activates(void)
{
    FPFrameGenerationState *receiptFirst =
        FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationDisplayCandidate current =
        acquire_preactivation_current(receiptFirst, 620.0);
    FPFrameGenerationOutputCallbackResult receipt =
        FPFrameGenerationRecordPresentationReceipt(receiptFirst, current, 0.0);

    assert(receipt.matched && !receipt.positivePresentationRecorded);
    FPFrameGenerationTelemetry waiting =
        FPFrameGenerationTelemetrySnapshot(receiptFirst);
    assert(!waiting.outputActive);
    assert(waiting.presentationsInFlight == 1);
    assert(waiting.presentationReceiptsPending == 1);
    FPFrameGenerationOutputCallbackResult completion =
        FPFrameGenerationRecordWriterCompleted(receiptFirst, current, true);
    assert(completion.matched && completion.joinRetired);
    FPFrameGenerationTelemetry telemetry =
        FPFrameGenerationTelemetrySnapshot(receiptFirst);
    assert(!telemetry.outputActive);
    assert(telemetry.currentPresented == 0);
    assert(telemetry.presentationReceiptsPending == 0);

    FPFrameGenerationCapturePlan freshPlan = capture_source(
        receiptFirst,
        620.005
    );
    assert(freshPlan.accepted && !freshPlan.shouldGenerateMidpoint);
    current = FPFrameGenerationAcquireDisplayCandidate(receiptFirst);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(FPFrameGenerationRecordWriterCompleted(
        receiptFirst,
        current,
        true
    ).writerRetired);
    receipt = FPFrameGenerationRecordPresentationReceipt(
        receiptFirst,
        current,
        620.010
    );
    assert(receipt.matched && receipt.positivePresentationRecorded);
    assert(FPFrameGenerationTelemetrySnapshot(receiptFirst).outputActive);
    FPFrameGenerationStateDestroy(receiptFirst);

    FPFrameGenerationState *completionFirst =
        FPFrameGenerationStateCreate(true, 120);
    current = acquire_preactivation_current(completionFirst, 625.0);
    completion = FPFrameGenerationRecordWriterCompleted(
        completionFirst,
        current,
        true
    );
    assert(completion.matched && !completion.joinRetired);
    telemetry = FPFrameGenerationTelemetrySnapshot(completionFirst);
    assert(telemetry.presentationsInFlight == 0);
    assert(telemetry.presentationReceiptsPending == 1);
    assert(!telemetry.outputActive);
    receipt = FPFrameGenerationRecordPresentationReceipt(
        completionFirst,
        current,
        0.0
    );
    assert(receipt.matched && receipt.joinRetired);
    assert(!receipt.positivePresentationRecorded);
    assert(!FPFrameGenerationTelemetrySnapshot(completionFirst).outputActive);

    freshPlan = capture_source(completionFirst, 625.005);
    assert(freshPlan.accepted && !freshPlan.shouldGenerateMidpoint);
    current = FPFrameGenerationAcquireDisplayCandidate(completionFirst);
    assert(FPFrameGenerationRecordPresentationReceipt(
        completionFirst,
        current,
        625.010
    ).positivePresentationRecorded);
    assert(FPFrameGenerationRecordWriterCompleted(
        completionFirst,
        current,
        true
    ).joinRetired);
    assert(FPFrameGenerationTelemetrySnapshot(completionFirst).outputActive);
    FPFrameGenerationStateDestroy(completionFirst);
}

static void test_midpoint_join_orders_and_writer_failure_preserve_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair, failedPair;
    FPFrameGenerationDisplayCandidate midpoint, current;
    FPFrameGenerationOutputCallbackResult result;

    activate_with_current(state, 630.0, 630.0);
    pair = capture_source(state, 630.020);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    result = FPFrameGenerationRecordPresentationReceipt(
        state,
        midpoint,
        630.025
    );
    assert(result.matched && result.positivePresentationRecorded);
    assert(!result.joinRetired);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(current.pairedCurrent && current.epoch == midpoint.epoch);
    result = FPFrameGenerationRecordWriterCompleted(state, midpoint, true);
    assert(result.matched && result.writerRetired && result.joinRetired);
    assert(FPFrameGenerationTelemetrySnapshot(state).generatedCompleted == 1);
    result = FPFrameGenerationRecordWriterCompleted(state, current, true);
    assert(result.matched && !result.joinRetired);
    result = FPFrameGenerationRecordPresentationReceipt(
        state,
        current,
        630.030
    );
    assert(result.matched && result.joinRetired);
    assert(FPFrameGenerationTelemetrySnapshot(state).midpointPresented == 1);

    failedPair = capture_source(state, 630.050);
    assert(failedPair.shouldGenerateMidpoint);
    publish_pair(state, failedPair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    FPFrameGenerationRecordGeneratedSubmitted(state, midpoint.epoch);
    result = FPFrameGenerationRecordWriterCompleted(state, midpoint, false);
    assert(result.matched && result.writerRetired && result.joinRetired);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(current.pairedCurrent && current.epoch == midpoint.epoch);
    FPFrameGenerationRecordPresented(state, current, 630.060);
    assert(FPFrameGenerationTelemetrySnapshot(state).currentPresented == 3);
    FPFrameGenerationStateDestroy(state);
}

static void test_output_receipt_capacity_preserves_next_current(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationDisplayCandidate pending[6], blocked, resumed;
    FPFrameGenerationCapturePlan blockedPlan;
    double sourceTime = 640.0;

    activate_with_current(state, sourceTime, sourceTime);
    for (size_t index = 0; index < 6; ++index)
    {
        sourceTime += 0.005;
        FPFrameGenerationCapturePlan plan = capture_source(state, sourceTime);
        assert(plan.accepted && !plan.shouldGenerateMidpoint);
        pending[index] = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(pending[index].kind == FPFrameGenerationOutputCurrent);
        assert(FPFrameGenerationRecordWriterCompleted(
            state,
            pending[index],
            true
        ).writerRetired);
    }
    FPFrameGenerationTelemetry full = FPFrameGenerationTelemetrySnapshot(state);
    assert(full.presentationsInFlight == 0);
    assert(full.presentationReceiptsPending == 6);
    assert(full.maximumPresentationReceiptsPending == 6);

    sourceTime += 0.005;
    blockedPlan = capture_source(state, sourceTime);
    assert(blockedPlan.accepted && !blockedPlan.shouldGenerateMidpoint);
    blocked = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(blocked.kind == FPFrameGenerationOutputNone);
    assert(FPFrameGenerationRecordPresentationReceipt(
        state,
        pending[0],
        640.1
    ).joinRetired);
    resumed = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(resumed.kind == FPFrameGenerationOutputCurrent);
    assert(resumed.epoch == blockedPlan.epoch);
    FPFrameGenerationRecordPresented(state, resumed, 640.11);
    for (size_t index = 1; index < 6; ++index)
        assert(FPFrameGenerationRecordPresentationReceipt(
            state,
            pending[index],
            640.11 + 0.01 * (double)index
        ).joinRetired);
    assert(FPFrameGenerationTelemetrySnapshot(state).
           presentationReceiptsPending == 0);
    FPFrameGenerationStateDestroy(state);
}

static void test_midpoint_requires_two_output_join_slots(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationDisplayCandidate pending[5], current;
    FPFrameGenerationCapturePlan pair;
    double sourceTime = 650.0;

    activate_with_current(state, sourceTime, sourceTime);
    for (size_t index = 0; index < 5; ++index)
    {
        sourceTime += 0.005;
        FPFrameGenerationCapturePlan plan = capture_source(state, sourceTime);
        pending[index] = FPFrameGenerationAcquireDisplayCandidate(state);
        assert(plan.accepted && pending[index].kind ==
               FPFrameGenerationOutputCurrent);
        assert(FPFrameGenerationRecordWriterCompleted(
            state,
            pending[index],
            true
        ).writerRetired);
    }
    sourceTime += 0.030;
    pair = capture_source(state, sourceTime);
    assert(pair.shouldGenerateMidpoint);
    publish_pair(state, pair);
    current = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(current.kind == FPFrameGenerationOutputCurrent);
    assert(!current.pairedCurrent && current.epoch == pair.epoch);
    FPFrameGenerationTelemetry telemetry =
        FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.presentationReceiptsPending == 6);
    assert(telemetry.midpointDroppedSuperseded == 1);
    FPFrameGenerationRecordPresented(state, current, 650.05);
    for (size_t index = 0; index < 5; ++index)
        (void)FPFrameGenerationRecordPresentationReceipt(
            state,
            pending[index],
            650.06 + 0.01 * (double)index
        );
    FPFrameGenerationStateDestroy(state);
}

static void test_writer_completion_removes_three_slot_throttle(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationDisplayCandidate pending[90] = {0};
    size_t sourceCount = 0, submittedCount = 0, receiptCount = 0;
    double sourceTime = 660.0;
    double displayTime = sourceTime;

    activate_with_current(state, sourceTime, displayTime);
    for (size_t callback = 0; callback < 119; ++callback)
    {
        size_t dueSources = ((callback + 1) * 90) / 119;
        while (sourceCount < dueSources)
        {
            sourceTime += 1.0 / 90.0;
            FPFrameGenerationCapturePlan plan = capture_source(state, sourceTime);
            if (plan.shouldGenerateMidpoint)
            {
                FPFrameGenerationRecordGeneratedFailed(state, plan.epoch);
                assert(FPFrameGenerationRecordCurrentReady(
                    state,
                    plan.epoch,
                    sourceTime
                ));
            }
            ++sourceCount;
        }
        if (submittedCount >= 5 && receiptCount + 5 <= submittedCount)
        {
            assert(FPFrameGenerationRecordPresentationReceipt(
                state,
                pending[receiptCount],
                displayTime
            ).joinRetired);
            ++receiptCount;
        }
        displayTime += 1.0 / 119.0;
        FPFrameGenerationRecordDisplayUpdate(state, displayTime);
        FPFrameGenerationDisplayCandidate candidate =
            FPFrameGenerationAcquireDisplayCandidate(state);
        if (candidate.kind != FPFrameGenerationOutputNone)
        {
            assert(candidate.kind == FPFrameGenerationOutputCurrent);
            pending[submittedCount++] = candidate;
            assert(FPFrameGenerationRecordWriterCompleted(
                state,
                candidate,
                true
            ).writerRetired);
        }
    }
    assert(sourceCount == 90);
    assert(submittedCount == 90);
    while (receiptCount < submittedCount)
    {
        displayTime += 1.0 / 119.0;
        assert(FPFrameGenerationRecordPresentationReceipt(
            state,
            pending[receiptCount++],
            displayTime
        ).joinRetired);
    }
    FPFrameGenerationTelemetry telemetry =
        FPFrameGenerationTelemetrySnapshot(state);
    assert(telemetry.currentPresented == 91);
    assert(telemetry.currentWriterCompleted == 91);
    assert(telemetry.presentationsInFlight == 0);
    assert(telemetry.presentationReceiptsPending == 0);
    assert(telemetry.maximumPresentationReceiptsPending <= 6);
    FPFrameGenerationStateDestroy(state);
}

static void test_surface_reset_and_error_retire_owned_work(void)
{
    FPFrameGenerationState *state = FPFrameGenerationStateCreate(true, 120);
    FPFrameGenerationCapturePlan pair;
    FPFrameGenerationDisplayCandidate midpoint;
    FPFrameGenerationTelemetry telemetry;

    activate_with_current(state, 60.0, 60.0);
    pair = capture_source(state, 60.02);
    publish_pair(state, pair);
    midpoint = FPFrameGenerationAcquireDisplayCandidate(state);
    assert(midpoint.kind == FPFrameGenerationOutputMidpoint);
    FPFrameGenerationResetForSurfaceChange(state, "resize");
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(!telemetry.outputActive);
    assert(telemetry.presentationsInFlight == 0);
    assert(telemetry.presentationReceiptsPending == 0);
    assert(!telemetry.generationReservationActive);
    assert(!FPFrameGenerationRecordWriterCompleted(
        state,
        midpoint,
        true
    ).matched);
    assert(!FPFrameGenerationRecordPresentationReceipt(
        state,
        midpoint,
        60.03
    ).matched);
    assert(FPFrameGenerationTelemetrySnapshot(state).midpointPresented == 0);

    FPFrameGenerationSetError(state, "runtime-error");
    telemetry = FPFrameGenerationTelemetrySnapshot(state);
    assert(strcmp(telemetry.state, "error") == 0);
    assert(telemetry.presentationsInFlight == 0);
    FPFrameGenerationStateDestroy(state);
}

int main(void)
{
    test_off_and_threshold_contract();
    test_common_window_distinguishes_source_from_current_output();
    test_common_window_output_arithmetic_and_generated_age_out();
    test_source_cadence_rebases_after_long_gap();
    test_common_window_retains_full_240_hz_target_horizon();
    test_reversed_presentation_callbacks_do_not_reset_cadence();
    test_source_capture_join_accepts_both_callback_orders();
    test_source_capture_join_retires_skips_and_errors();
    test_source_sequence_is_monotonic_and_rejects_duplicate_time();
    test_optional_midpoint_respects_effective_display_service();
    test_midpoint_requires_consecutive_source_capture_tokens();
    test_capture_rejects_unknown_or_stale_source_token();
    test_reserved_current_blocks_fifo_until_published();
    test_visible_newer_source_supersedes_only_preactivation_seed();
    test_active_mode_never_supersedes_ready_original();
    test_current_admission_capacity_never_loses_an_accepted_current();
    test_midpoint_is_dropped_when_only_one_presentation_slot_remains();
    test_midpoint_and_current_use_exactly_two_remaining_slots();
    test_ready_pair_waits_behind_older_fifo_current();
    test_first_reserved_pair_does_not_chase_newer_currents();
    test_late_display_update_discards_only_ready_midpoint();
    test_late_update_preserves_already_paired_current();
    test_skipped_midpoint_keeps_matching_current_live();
    test_stalled_midpoint_retires_without_consuming_matching_current();
    test_cancel_accepted_capture_preserves_older_fifo_current();
    test_capture_recovery_keeps_output_owner_and_reseeds_current();
    test_fractional_service_credit_rate_matrix();
    test_signed_credit_does_not_overgenerate_alternating_intervals();
    test_fractional_carry_with_display_cadence_and_delayed_receipts();
    test_ninety_hz_three_capture_bursts_use_one_optional_slot();
    test_fast_capture_after_reservation_drops_only_optional_midpoint();
    test_capture_capacity_evicts_only_ready_optional_midpoint();
    test_output_join_callbacks_are_order_independent();
    test_nonpositive_current_receipt_retires_and_fresh_current_activates();
    test_midpoint_join_orders_and_writer_failure_preserve_current();
    test_output_receipt_capacity_preserves_next_current();
    test_midpoint_requires_two_output_join_slots();
    test_writer_completion_removes_three_slot_throttle();
    test_surface_reset_and_error_retire_owned_work();
    puts("D3DMetal single-path frame-generation state-machine tests passed");
    return 0;
}
