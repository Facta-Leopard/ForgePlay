#import "ForgePlayD3DMetalFrameGenerationProxy.h"
#import "FrameGenerationStateMachine.h"

#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <objc/runtime.h>

#include <fcntl.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const size_t FPObservationMaximumBytes = 1024 * 1024;
static const CFTimeInterval FPTelemetryMinimumInterval = 2.0;
static const CFTimeInterval FPFrameCheckMinimumInterval = 0.25;
#define FP_CAPTURE_TEXTURE_POOL_CAPACITY 6
#define FP_CAPTURE_MAX_IN_FLIGHT 3u
#define FP_SOURCE_DRAWABLE_TICKET_CAPACITY 4u
#define FP_SOURCE_BOUNDARY_FAILURE_PRESENTS 3u
#define FP_METAL_HOOK_CAPACITY 32u
#define FP_SOURCE_SESSION_SNAPSHOT_CAPACITY 16u
#define FP_HOOKED_COMMAND_BUFFER_CLASS_CAPACITY 16u
#define FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY 16u
#define FP_CAPTURE_BUSY_EPISODE_MINIMUM_SAMPLES 3u
#define FP_PRESENTATION_STALL_FAILURE_CHECKS 3u
#define FP_EXECUTABLE_ARGUMENT_SCAN_LIMIT 64u
#define FP_EXECUTABLE_ARGUMENT_MAXIMUM_BYTES 32768u
static const NSInteger FPInvalidCaptureTextureSlot = -1;
static const double FPCaptureBackpressureSlotMultiplier = 8.0;
static const double FPPresentationWatchdogSlotMultiplier = 8.0;
static atomic_uint_fast64_t FPNextFrameGenerationSessionIdentifier = 1;

typedef struct FPFrameGenerationRuntimeCounters
{
    uint64_t captureSkippedBusy;
    uint32_t captureInFlight;
    uint32_t maximumCaptureInFlight;
    uint32_t captureBusyEpisode;
    double captureOutstandingMilliseconds;
    uint32_t consecutiveEmptyDisplayUpdates;
    uint64_t displayResumeCount;
    double sourceCadenceHz;
    double currentOutputCadenceHz;
    double generatedCadenceHz;
    double outputSourceRatio;
    double currentSourceRatio;
    double sourceCadenceRatio;
    double sourceCadenceLower95;
    double sourceCadenceUpper95;
    uint32_t captureCommandBuffersOutstanding;
    uint32_t displayCommandBuffersOutstanding;
    uint64_t capturePoolAllocations;
    uint64_t capturePoolReleases;
    uint32_t capturePoolTextureCount;
    uint64_t sessionIdentifier;
    double recordMonotonicTime;
    uint32_t presentationStallChecks;
    uint32_t presentationReceiptsPending;
    uint32_t maximumPresentationReceiptsPending;
    uint64_t writerCompleted;
    uint64_t currentWriterCompleted;
    uint64_t sourcePresentCommandBufferBound;
    uint64_t sourceCaptureEncodedOnSourceCB;
    uint64_t sourceCaptureJoined;
    uint64_t sourcePresentUncovered;
} FPFrameGenerationRuntimeCounters;

typedef struct FPFrameGenerationTextureSubmission
{
    FPFrameGenerationDisplayCandidate candidate;
    uint64_t surfaceGeneration;
    NSInteger previousSlot;
    NSInteger currentSlot;
    CFTimeInterval submittedAtTime;
} FPFrameGenerationTextureSubmission;

typedef struct FPFrameGenerationPresentationReceipt
{
    FPFrameGenerationDisplayCandidate candidate;
    uint64_t surfaceGeneration;
    CFTimeInterval submittedAtTime;
    uint32_t presentationStallChecks;
    BOOL writerCompleted;
    BOOL presentationSeen;
} FPFrameGenerationPresentationReceipt;

typedef struct FPFrameGenerationCaptureSubmission
{
    uint64_t sequence;
    CFTimeInterval submittedAtTime;
    uint32_t busyObservations;
} FPFrameGenerationCaptureSubmission;

typedef struct FPFrameGenerationReadyCurrentTexture
{
    uint64_t epoch;
    NSInteger slot;
} FPFrameGenerationReadyCurrentTexture;

typedef struct FPFrameGenerationSourceDrawableTicket
{
    uint64_t ticketID;
    uint64_t surfaceGeneration;
    uint64_t drawableID;
    const void *drawableIdentity;
    const void *sourceTextureIdentity;
    const void *commandBufferIdentity;
    NSInteger captureSlot;
    BOOL commandBufferBound;
    BOOL commitSeen;
    FPFrameGenerationSourceCaptureJoin join;
} FPFrameGenerationSourceDrawableTicket;

static BOOL FPDisplayCandidateIdentityMatches(
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

@class FPD3DMetalFrameGenerationSession;

static void FPCopyFailureReason(char *destination, size_t capacity, const char *reason)
{
    if (!destination || !capacity) return;
    if (!reason) reason = "unspecified";
    (void)snprintf(destination, capacity, "%s", reason);
}

static BOOL FPPathIsAbsoluteAndSingleLine(const char *path)
{
    const unsigned char *cursor;

    if (!path || path[0] != '/') return NO;
    for (cursor = (const unsigned char *)path; *cursor; ++cursor)
        if (*cursor < 0x20 || *cursor == 0x7f) return NO;
    return YES;
}

static NSString *FPNormalizedWindowsExecutableArgument(NSString *value)
{
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *normalized = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while (normalized.length >= 2 &&
           [normalized characterAtIndex:0] == '"' &&
           [normalized characterAtIndex:normalized.length - 1] == '"')
    {
        normalized = [[normalized substringWithRange:NSMakeRange(
            1,
            normalized.length - 2
        )] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (!normalized.length) return nil;
    normalized = [normalized stringByReplacingOccurrencesOfString:@"/"
                                                        withString:@"\\"];
    while ([normalized rangeOfString:@"\\\\"].location != NSNotFound)
        normalized = [normalized stringByReplacingOccurrencesOfString:@"\\\\"
                                                            withString:@"\\"];
    return normalized.lowercaseString;
}

static const char *FPExecutableIdentitySHA256(void)
{
    static dispatch_once_t onceToken;
    static char result[CC_SHA256_DIGEST_LENGTH * 2 + 1] = "unavailable";
    dispatch_once(&onceToken, ^{
        @autoreleasepool
        {
            NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
            NSUInteger upperBound = MIN(
                arguments.count,
                (NSUInteger)FP_EXECUTABLE_ARGUMENT_SCAN_LIMIT + 1
            );
            for (NSUInteger index = 1; index < upperBound; ++index)
            {
                NSString *rawArgument = arguments[index];
                NSData *rawData = [rawArgument dataUsingEncoding:NSUTF8StringEncoding];
                if (!rawData.length ||
                    rawData.length > FP_EXECUTABLE_ARGUMENT_MAXIMUM_BYTES)
                    continue;
                NSString *normalized =
                    FPNormalizedWindowsExecutableArgument(rawArgument);
                if (!normalized || ![normalized hasSuffix:@".exe"]) continue;
                NSData *normalizedData = [normalized
                    dataUsingEncoding:NSUTF8StringEncoding];
                if (!normalizedData.length ||
                    normalizedData.length > FP_EXECUTABLE_ARGUMENT_MAXIMUM_BYTES)
                    continue;
                unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(
                    normalizedData.bytes,
                    (CC_LONG)normalizedData.length,
                    digest
                );
                static const char hexadecimal[] = "0123456789abcdef";
                for (NSUInteger byte = 0;
                     byte < CC_SHA256_DIGEST_LENGTH;
                     ++byte)
                {
                    result[byte * 2] = hexadecimal[digest[byte] >> 4];
                    result[byte * 2 + 1] = hexadecimal[digest[byte] & 0x0f];
                }
                result[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
                break;
            }
        }
    });
    return result;
}

static void FPWriteTelemetryRecord(
    FPFrameGenerationTelemetry telemetry,
    FPFrameGenerationRuntimeCounters runtimeCounters
)
{
    const char *observationPath = getenv(
        "FORGEPLAY_D3DMETAL_FRAME_GENERATION_OBSERVATION_FILE"
    );
    char record[2304];
    struct stat metadata;
    int descriptor;
    int length;

    if (!FPPathIsAbsoluteAndSingleLine(observationPath))
        observationPath = getenv("FORGEPLAY_PROCESS_OBSERVATION_FILE");
    if (!FPPathIsAbsoluteAndSingleLine(observationPath)) return;
    if (!observationPath) return;
    descriptor = open(
        observationPath,
        O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
    );
    if (descriptor < 0) return;
    if (fstat(descriptor, &metadata) != 0 ||
        !S_ISREG(metadata.st_mode) ||
        metadata.st_nlink != 1 ||
        metadata.st_uid != geteuid() ||
        metadata.st_size < 0 ||
        (size_t)metadata.st_size >= FPObservationMaximumBytes)
    {
        (void)close(descriptor);
        return;
    }

    length = snprintf(
        record,
        sizeof(record),
        "FORGEPLAY_D3DMETAL_FRAMEGEN_V1\t%ld\tstate=%s\ttarget_hz=%u"
        "\tepoch=%llu\tsource_present_seen=%llu\tcapture_ready=%llu"
        "\tgenerated_submitted=%llu\tgenerated_completed=%llu"
        "\tgenerated_presented=%llu\tmidpoint=%llu\toutput_active=%u"
        "\tdisplay_updates=%llu\tcadence_hz=%.3f\treason=%s"
        "\tcurrent_presented=%llu\tmidpoint_admitted=%llu"
        "\tmidpoint_dropped_late=%llu"
        "\tmidpoint_dropped_superseded=%llu"
        "\tmidpoint_dropped_presentation_stall=%llu"
        "\tpresentations_in_flight=%u"
        "\tmax_presentations_in_flight=%u"
        "\tpresentation_receipts_pending=%u"
        "\tmax_presentation_receipts_pending=%u"
        "\twriter_completed=%llu\tcurrent_writer_completed=%llu"
        "\tgeneration_reserved=%u\tgeneration_outstanding=%u"
        "\teffective_slot_ms=%.3f\tcapture_skipped_busy=%llu"
        "\tcapture_inflight=%u\tmax_capture_inflight=%u"
        "\tcapture_busy_episode=%u\tcapture_outstanding_ms=%.3f"
        "\tempty_display_updates=%u"
        "\tdisplay_resume_count=%llu\tsource_cadence_hz=%.3f"
        /* Parser-compatible legacy key: this is output Current cadence, not
         * D3DMetal source cadence or the Frame Check Original value. */
        "\toriginal_cadence_hz=%.3f\tgenerated_cadence_hz=%.3f"
        "\toutput_source_ratio=%.6f\tcurrent_source_ratio=%.6f"
        "\tsource_present_accepted=%llu"
        "\tsource_q=%.6f\tsource_q_lower95=%.6f"
        "\tsource_q_upper95=%.6f"
        "\tcapture_cb_outstanding=%u\tdisplay_cb_outstanding=%u"
        "\tcapture_pool_allocations=%llu\tcapture_pool_releases=%llu"
        "\tcapture_pool_textures=%u"
        "\trecord_time=%.9f\tsession_id=%llu"
        "\tpresentation_stall_checks=%u"
        "\tsource_present_command_buffer_bound=%llu"
        "\tsource_capture_encoded_on_source_cb=%llu"
        "\tsource_capture_joined=%llu"
        "\tsource_present_uncovered=%llu"
        "\texecutable_sha256=%s\n",
        (long)getpid(),
        telemetry.state,
        telemetry.targetFrameRate,
        (unsigned long long)telemetry.epoch,
        (unsigned long long)telemetry.sourcePresentSeen,
        (unsigned long long)telemetry.captureReady,
        (unsigned long long)telemetry.generatedSubmitted,
        (unsigned long long)telemetry.generatedCompleted,
        (unsigned long long)telemetry.generatedPresented,
        (unsigned long long)telemetry.midpointPresented,
        telemetry.outputActive ? 1u : 0u,
        (unsigned long long)telemetry.displayUpdates,
        telemetry.finalCadenceHz,
        telemetry.reason,
        (unsigned long long)telemetry.currentPresented,
        (unsigned long long)telemetry.midpointAdmitted,
        (unsigned long long)telemetry.midpointDroppedLate,
        (unsigned long long)telemetry.midpointDroppedSuperseded,
        (unsigned long long)telemetry.midpointDroppedPresentationStall,
        telemetry.presentationsInFlight,
        telemetry.maximumPresentationsInFlight,
        runtimeCounters.presentationReceiptsPending,
        runtimeCounters.maximumPresentationReceiptsPending,
        (unsigned long long)runtimeCounters.writerCompleted,
        (unsigned long long)runtimeCounters.currentWriterCompleted,
        telemetry.generationReservationActive ? 1u : 0u,
        telemetry.generationOutstanding ? 1u : 0u,
        telemetry.effectiveDisplaySlotDuration * 1000.0,
        (unsigned long long)runtimeCounters.captureSkippedBusy,
        runtimeCounters.captureInFlight,
        runtimeCounters.maximumCaptureInFlight,
        runtimeCounters.captureBusyEpisode,
        runtimeCounters.captureOutstandingMilliseconds,
        runtimeCounters.consecutiveEmptyDisplayUpdates,
        (unsigned long long)runtimeCounters.displayResumeCount,
        runtimeCounters.sourceCadenceHz,
        runtimeCounters.currentOutputCadenceHz,
        runtimeCounters.generatedCadenceHz,
        runtimeCounters.outputSourceRatio,
        runtimeCounters.currentSourceRatio,
        (unsigned long long)telemetry.sourcePresentAccepted,
        runtimeCounters.sourceCadenceRatio,
        runtimeCounters.sourceCadenceLower95,
        runtimeCounters.sourceCadenceUpper95,
        runtimeCounters.captureCommandBuffersOutstanding,
        runtimeCounters.displayCommandBuffersOutstanding,
        (unsigned long long)runtimeCounters.capturePoolAllocations,
        (unsigned long long)runtimeCounters.capturePoolReleases,
        runtimeCounters.capturePoolTextureCount,
        runtimeCounters.recordMonotonicTime,
        (unsigned long long)runtimeCounters.sessionIdentifier,
        runtimeCounters.presentationStallChecks,
        (unsigned long long)runtimeCounters.sourcePresentCommandBufferBound,
        (unsigned long long)runtimeCounters.sourceCaptureEncodedOnSourceCB,
        (unsigned long long)runtimeCounters.sourceCaptureJoined,
        (unsigned long long)runtimeCounters.sourcePresentUncovered,
        FPExecutableIdentitySHA256()
    );
    if (length > 0 && (size_t)length < sizeof(record) &&
        (size_t)metadata.st_size + (size_t)length <= FPObservationMaximumBytes)
        (void)write(descriptor, record, (size_t)length);
    (void)close(descriptor);
}

static void FPWriteStandaloneErrorTelemetry(
    uint32_t targetFrameRate,
    const char *reason
)
{
    FPFrameGenerationTelemetry telemetry = {0};

    telemetry.targetFrameRate = targetFrameRate;
    (void)snprintf(telemetry.state, sizeof(telemetry.state), "error");
    (void)snprintf(
        telemetry.reason,
        sizeof(telemetry.reason),
        "%s",
        reason ? reason : "session-create-failed"
    );
    FPFrameGenerationRuntimeCounters runtimeCounters = {0};
    runtimeCounters.recordMonotonicTime = CACurrentMediaTime();
    FPWriteTelemetryRecord(telemetry, runtimeCounters);
}

static NSString *FPFrameGenerationCompositionShaderSource(void)
{
    return
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct FPVertexOutput { float4 position [[position]]; };\n"
         "vertex FPVertexOutput fp_frame_generation_vertex(\n"
         "    uint vertexID [[vertex_id]])\n"
         "{\n"
         "    const float2 positions[3] = {\n"
         "        float2(-1.0, -1.0),\n"
         "        float2( 3.0, -1.0),\n"
         "        float2(-1.0,  3.0)\n"
         "    };\n"
         "    FPVertexOutput output;\n"
         "    output.position = float4(positions[vertexID], 0.0, 1.0);\n"
         "    return output;\n"
         "}\n"
         "fragment half4 fp_frame_generation_midpoint(\n"
         "    FPVertexOutput input [[stage_in]],\n"
         "    texture2d<half, access::read> previous [[texture(0)]],\n"
         "    texture2d<half, access::read> current [[texture(1)]])\n"
         "{\n"
         "    uint2 coordinate = uint2(input.position.xy);\n"
         "    half3 previousColor = previous.read(coordinate).rgb;\n"
         "    half3 currentColor = current.read(coordinate).rgb;\n"
         "    return half4(mix(previousColor, currentColor, 0.5h), 1.0h);\n"
         "}\n"
         "fragment half4 fp_frame_generation_current(\n"
         "    FPVertexOutput input [[stage_in]],\n"
         "    texture2d<half, access::read> current [[texture(0)]])\n"
         "{\n"
         "    uint2 coordinate = uint2(input.position.xy);\n"
         "    return half4(current.read(coordinate).rgb, 1.0h);\n"
         "}\n";
}

@interface FPFrameGenerationHostView : NSView
@property(nonatomic, weak) FPD3DMetalFrameGenerationSession *frameGenerationSession;
@end

@interface CAMetalLayer (ForgePlayFrameGenerationSourceObservation)
- (nullable id<CAMetalDrawable>)fp_frameGeneration_nextDrawable;
@end

@interface FPD3DMetalFrameGenerationSession : NSObject <CAMetalDisplayLinkDelegate>
@property(nonatomic, readonly) CAMetalLayer *sourceLayer;

- (nullable instancetype)initWithOwningMetalView:(NSView *)owningMetalView
                                     device:(id<MTLDevice>)device
                            targetFrameRate:(uint32_t)targetFrameRate
                          frameCheckEnabled:(BOOL)frameCheckEnabled
                              failureReason:(char *)failureReason
                     failureReasonCapacity:(size_t)failureReasonCapacity;
- (void)activateSourceObservation;
- (void)invalidate;
- (uint64_t)trackSourceDrawable:(id<CAMetalDrawable>)drawable;
- (BOOL)bindSourceDrawable:(id<CAMetalDrawable>)drawable
           toCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (void)prepareSourceCaptureBeforeCommit:
    (id<MTLCommandBuffer>)commandBuffer;
- (void)sourceDrawableTicket:(uint64_t)ticketID
             captureWasArmed:(BOOL)captureWasArmed
         wasPresentedAtTime:(CFTimeInterval)presentedTime;
- (void)sourceCaptureCommandBufferCompletedForTicket:(uint64_t)ticketID
                                    surfaceGeneration:
                                        (uint64_t)surfaceGeneration
                                                 slot:(NSInteger)slot
                                               status:(MTLCommandBufferStatus)status;
- (void)sourceSurfaceConfigurationDidChange;
- (void)layoutOwnedLayers;
- (BOOL)callbackStateIsUsableLocked;
- (BOOL)telemetryStateIsUsableLocked;
- (BOOL)sourceObservationIsActive;
- (BOOL)sourceCaptureIsEnabled;
- (BOOL)prepareDemandMetalResourcesOnMain;
- (void)releaseDemandMetalResourcesOnMain;
- (void)scheduleCapturePrimingOutputSurface;
- (nullable id<MTLRenderPipelineState>)compositionPipelineForPixelFormat:
    (MTLPixelFormat)pixelFormat
                                                     currentOnly:(BOOL)currentOnly
                                                           error:(NSError **)error;
- (void)scheduleDisplayLinkResume;
- (void)scheduleDisplayLinkRebaseAfterLateUpdate:(CAMetalDisplayLink *)displayLink;
- (void)acceptCapturedSlot:(NSInteger)slot
             sourceSequence:(uint64_t)sourceSequence
             presentedTime:(CFTimeInterval)presentedTime
          surfaceGeneration:(uint64_t)surfaceGeneration;
- (BOOL)recordCaptureBusyLockedAtTime:(CFTimeInterval)now
                            telemetry:(FPFrameGenerationTelemetry)telemetry;
- (void)retireCaptureSlotLocked:(NSInteger)slot;
- (BOOL)retireCaptureCompletionLockedForSlot:(NSInteger)slot
                            surfaceGeneration:(uint64_t)surfaceGeneration;
- (BOOL)stageRetiredCaptureGenerationLocked;
- (void)scheduleCaptureResourceRecovery;
- (BOOL)enqueueReadyCurrentSlotLocked:(NSInteger)slot epoch:(uint64_t)epoch;
- (NSInteger)takeReadyCurrentSlotLockedForEpoch:(uint64_t)epoch;
- (void)retireNativeReadyMidpointLockedForEpoch:(uint64_t)epoch;
- (NSInteger)freePresentationReceiptIndexLocked;
- (NSInteger)presentationReceiptIndexLockedForCandidate:
    (FPFrameGenerationDisplayCandidate)candidate
                                     surfaceGeneration:
                                         (uint64_t)surfaceGeneration;
- (BOOL)removeTextureSubmissionLockedForCandidate:
    (FPFrameGenerationDisplayCandidate)candidate
                                        surfaceGeneration:
                                            (uint64_t)surfaceGeneration;
- (BOOL)removePresentationReceiptLockedForCandidate:
    (FPFrameGenerationDisplayCandidate)candidate
                                          surfaceGeneration:
                                              (uint64_t)surfaceGeneration;
- (void)schedulePresentationWatchdog;
- (BOOL)owningWindowIsActiveAndVisible;
- (void)refreshPresentationStallChecksLocked;
- (CATextLayer *)ensureFrameCheckLayerOnMain;
@end

/* Never attach associated objects to D3DMetal's live CAMetalLayer. Apple's
 * Objective-C runtime realizes an object's class on the first association;
 * doing that reentrantly from D3DMetal's surface callback can re-enter the
 * class-realization path seen in the crash. Keep this secondary hazard out of
 * the owning renderer and key the proxy-owned binding by the borrowed layer. */
static os_unfair_lock FPFrameGenerationSourceSessionsLock =
    OS_UNFAIR_LOCK_INIT;

@interface FPFrameGenerationSourceSessionNode : NSObject
{
@public
    __unsafe_unretained CAMetalLayer *_sourceLayer;
    FPD3DMetalFrameGenerationSession *_session;
    FPFrameGenerationSourceSessionNode *_next;
}
@end

@implementation FPFrameGenerationSourceSessionNode
@end

static FPFrameGenerationSourceSessionNode *FPFrameGenerationSourceSessions;
static void FPClearSourceCommandBufferBindingsForSession(
    FPD3DMetalFrameGenerationSession *session
);

static FPD3DMetalFrameGenerationSession *
FPFrameGenerationSessionForSourceLayer(CAMetalLayer *layer)
{
    if (!layer) return nil;
    os_unfair_lock_lock(&FPFrameGenerationSourceSessionsLock);
    FPD3DMetalFrameGenerationSession *session = nil;
    for (FPFrameGenerationSourceSessionNode *node =
            FPFrameGenerationSourceSessions;
         node;
         node = node->_next)
    {
        if (node->_sourceLayer != layer) continue;
        session = node->_session;
        break;
    }
    os_unfair_lock_unlock(&FPFrameGenerationSourceSessionsLock);
    return session;
}

static BOOL FPRegisterFrameGenerationSourceLayer(
    CAMetalLayer *layer,
    FPD3DMetalFrameGenerationSession *session
)
{
    if (!layer || !session) return NO;
    FPFrameGenerationSourceSessionNode *node =
        [FPFrameGenerationSourceSessionNode new];
    node->_sourceLayer = layer;
    node->_session = session;
    os_unfair_lock_lock(&FPFrameGenerationSourceSessionsLock);
    BOOL available = YES;
    for (FPFrameGenerationSourceSessionNode *cursor =
            FPFrameGenerationSourceSessions;
         cursor;
         cursor = cursor->_next)
    {
        if (cursor->_sourceLayer != layer) continue;
        available = NO;
        break;
    }
    if (available)
    {
        node->_next = FPFrameGenerationSourceSessions;
        FPFrameGenerationSourceSessions = node;
    }
    os_unfair_lock_unlock(&FPFrameGenerationSourceSessionsLock);
    return available;
}

static void FPUnregisterFrameGenerationSourceLayer(
    CAMetalLayer *layer,
    FPD3DMetalFrameGenerationSession *session
)
{
    if (!layer || !session) return;
    os_unfair_lock_lock(&FPFrameGenerationSourceSessionsLock);
    FPFrameGenerationSourceSessionNode *previous = nil;
    FPFrameGenerationSourceSessionNode *cursor =
        FPFrameGenerationSourceSessions;
    while (cursor)
    {
        if (cursor->_sourceLayer == layer && cursor->_session == session)
        {
            if (previous) previous->_next = cursor->_next;
            else FPFrameGenerationSourceSessions = cursor->_next;
            cursor->_sourceLayer = nil;
            cursor->_session = nil;
            cursor->_next = nil;
            break;
        }
        previous = cursor;
        cursor = cursor->_next;
    }
    os_unfair_lock_unlock(&FPFrameGenerationSourceSessionsLock);
    FPClearSourceCommandBufferBindingsForSession(session);
}

typedef struct FPMetalMethodHook
{
    Class concreteClass;
    SEL selector;
    IMP originalImplementation;
} FPMetalMethodHook;

static os_unfair_lock FPMetalMethodHooksLock = OS_UNFAIR_LOCK_INIT;
static FPMetalMethodHook FPMetalMethodHooks[FP_METAL_HOOK_CAPACITY];
static atomic_uintptr_t
    FPFullyHookedCommandBufferClasses[
        FP_HOOKED_COMMAND_BUFFER_CLASS_CAPACITY
    ];

typedef struct FPSourceCommandBufferBinding
{
    atomic_uintptr_t commandBufferIdentity;
    CFTypeRef commandBuffer;
    CFTypeRef session;
} FPSourceCommandBufferBinding;

static os_unfair_lock FPSourceCommandBufferBindingsLock = OS_UNFAIR_LOCK_INIT;
static FPSourceCommandBufferBinding
    FPSourceCommandBufferBindings[FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY];

static BOOL FPRegisterSourceCommandBufferBinding(
    id<MTLCommandBuffer> commandBuffer,
    FPD3DMetalFrameGenerationSession *session
)
{
    if (!commandBuffer || !session) return NO;
    uintptr_t identity = (uintptr_t)(__bridge const void *)commandBuffer;
    BOOL registered = NO;
    os_unfair_lock_lock(&FPSourceCommandBufferBindingsLock);
    /* First deduplicate the exact (command buffer, session) pair. One source
     * command buffer may legitimately present drawables for multiple sessions. */
    for (uint32_t index = 0;
         index < FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY;
         ++index)
    {
        uintptr_t observed = atomic_load_explicit(
            &FPSourceCommandBufferBindings[index].commandBufferIdentity,
            memory_order_relaxed
        );
        if (observed == identity)
        {
            if (FPSourceCommandBufferBindings[index].commandBuffer ==
                    (__bridge CFTypeRef)commandBuffer &&
                FPSourceCommandBufferBindings[index].session ==
                    (__bridge CFTypeRef)session)
            {
                registered = YES;
                break;
            }
        }
    }
    for (uint32_t index = 0;
         !registered && index < FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY;
         ++index)
    {
        uintptr_t observed = atomic_load_explicit(
            &FPSourceCommandBufferBindings[index].commandBufferIdentity,
            memory_order_relaxed
        );
        if (observed) continue;
        FPSourceCommandBufferBindings[index].commandBuffer = CFRetain(
            (__bridge CFTypeRef)commandBuffer
        );
        FPSourceCommandBufferBindings[index].session = CFRetain(
            (__bridge CFTypeRef)session
        );
        atomic_store_explicit(
            &FPSourceCommandBufferBindings[index].commandBufferIdentity,
            identity,
            memory_order_release
        );
        registered = YES;
        break;
    }
    os_unfair_lock_unlock(&FPSourceCommandBufferBindingsLock);
    return registered;
}

static uint32_t FPTakeSourceCommandBufferBindings(
    id<MTLCommandBuffer> commandBuffer,
    CFTypeRef sessions[FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY]
)
{
    if (!commandBuffer || !sessions) return 0;
    uintptr_t identity = (uintptr_t)(__bridge const void *)commandBuffer;
    BOOL possiblyBound = NO;
    for (uint32_t index = 0;
         index < FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY;
         ++index)
    {
        if (atomic_load_explicit(
                &FPSourceCommandBufferBindings[index].commandBufferIdentity,
                memory_order_acquire
            ) == identity)
        {
            possiblyBound = YES;
            break;
        }
    }
    if (!possiblyBound) return 0;
    CFTypeRef retainedCommandBuffers[
        FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY
    ] = {NULL};
    uint32_t bindingCount = 0;
    os_unfair_lock_lock(&FPSourceCommandBufferBindingsLock);
    for (uint32_t index = 0;
         index < FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY;
         ++index)
    {
        if (atomic_load_explicit(
                &FPSourceCommandBufferBindings[index].commandBufferIdentity,
                memory_order_relaxed
            ) != identity)
            continue;
        if (FPSourceCommandBufferBindings[index].commandBuffer !=
            (__bridge CFTypeRef)commandBuffer)
            continue;
        retainedCommandBuffers[bindingCount] =
            FPSourceCommandBufferBindings[index].commandBuffer;
        sessions[bindingCount] =
            FPSourceCommandBufferBindings[index].session;
        ++bindingCount;
        FPSourceCommandBufferBindings[index].commandBuffer = NULL;
        FPSourceCommandBufferBindings[index].session = NULL;
        atomic_store_explicit(
            &FPSourceCommandBufferBindings[index].commandBufferIdentity,
            0,
            memory_order_release
        );
    }
    os_unfair_lock_unlock(&FPSourceCommandBufferBindingsLock);
    for (uint32_t index = 0; index < bindingCount; ++index)
        if (retainedCommandBuffers[index])
            CFRelease(retainedCommandBuffers[index]);
    return bindingCount;
}

static void FPClearSourceCommandBufferBindingsForSession(
    FPD3DMetalFrameGenerationSession *session
)
{
    if (!session) return;
    CFTypeRef sessionIdentity = (__bridge CFTypeRef)session;
    os_unfair_lock_lock(&FPSourceCommandBufferBindingsLock);
    for (uint32_t index = 0;
         index < FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY;
         ++index)
    {
        if (FPSourceCommandBufferBindings[index].session != sessionIdentity)
            continue;
        CFTypeRef retainedSession =
            FPSourceCommandBufferBindings[index].session;
        CFTypeRef retainedCommandBuffer =
            FPSourceCommandBufferBindings[index].commandBuffer;
        FPSourceCommandBufferBindings[index].commandBuffer = NULL;
        FPSourceCommandBufferBindings[index].session = NULL;
        atomic_store_explicit(
            &FPSourceCommandBufferBindings[index].commandBufferIdentity,
            0,
            memory_order_release
        );
        if (retainedCommandBuffer) CFRelease(retainedCommandBuffer);
        if (retainedSession) CFRelease(retainedSession);
    }
    os_unfair_lock_unlock(&FPSourceCommandBufferBindingsLock);
}

static IMP FPOriginalMetalImplementation(id object, SEL selector)
{
    if (!object || !selector) return NULL;
    IMP implementation = NULL;
    os_unfair_lock_lock(&FPMetalMethodHooksLock);
    for (Class concreteClass = object_getClass(object);
         concreteClass && !implementation;
         concreteClass = class_getSuperclass(concreteClass))
    {
        for (uint32_t index = 0; index < FP_METAL_HOOK_CAPACITY; ++index)
        {
            FPMetalMethodHook hook = FPMetalMethodHooks[index];
            if (hook.concreteClass == concreteClass &&
                hook.selector == selector)
            {
                implementation = hook.originalImplementation;
                break;
            }
        }
    }
    os_unfair_lock_unlock(&FPMetalMethodHooksLock);
    return implementation;
}

static BOOL FPInstallMetalMethodHook(
    Class concreteClass,
    SEL selector,
    IMP replacement
)
{
    if (!concreteClass || !selector || !replacement) return NO;
    os_unfair_lock_lock(&FPMetalMethodHooksLock);
    IMP current = class_getMethodImplementation(concreteClass, selector);
    if (!current)
    {
        os_unfair_lock_unlock(&FPMetalMethodHooksLock);
        return NO;
    }
    if (current == replacement)
    {
        os_unfair_lock_unlock(&FPMetalMethodHooksLock);
        return YES;
    }
    for (uint32_t index = 0; index < FP_METAL_HOOK_CAPACITY; ++index)
    {
        if (FPMetalMethodHooks[index].concreteClass == concreteClass &&
            FPMetalMethodHooks[index].selector == selector)
        {
            os_unfair_lock_unlock(&FPMetalMethodHooksLock);
            return YES;
        }
    }
    Method method = class_getInstanceMethod(concreteClass, selector);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    uint32_t freeIndex = FP_METAL_HOOK_CAPACITY;
    for (uint32_t index = 0; index < FP_METAL_HOOK_CAPACITY; ++index)
    {
        if (!FPMetalMethodHooks[index].concreteClass)
        {
            freeIndex = index;
            break;
        }
    }
    if (!method || !types || freeIndex == FP_METAL_HOOK_CAPACITY)
    {
        os_unfair_lock_unlock(&FPMetalMethodHooksLock);
        return NO;
    }
    FPMetalMethodHooks[freeIndex] = (FPMetalMethodHook){
        .concreteClass = concreteClass,
        .selector = selector,
        .originalImplementation = current,
    };
    if (!class_addMethod(concreteClass, selector, replacement, types))
        method_setImplementation(method, replacement);
    os_unfair_lock_unlock(&FPMetalMethodHooksLock);
    return YES;
}

static BOOL FPBindTrackedSourceDrawable(
    id<CAMetalDrawable> drawable,
    id<MTLCommandBuffer> commandBuffer
)
{
    if (!drawable || !commandBuffer) return NO;
    CFTypeRef sessions[FP_SOURCE_SESSION_SNAPSHOT_CAPACITY] = {NULL};
    uint32_t sessionCount = 0;
    os_unfair_lock_lock(&FPFrameGenerationSourceSessionsLock);
    for (FPFrameGenerationSourceSessionNode *node =
            FPFrameGenerationSourceSessions;
         node && sessionCount < FP_SOURCE_SESSION_SNAPSHOT_CAPACITY;
         node = node->_next)
    {
        if (!node->_session) continue;
        sessions[sessionCount] = CFRetain(
            (__bridge CFTypeRef)node->_session
        );
        ++sessionCount;
    }
    os_unfair_lock_unlock(&FPFrameGenerationSourceSessionsLock);
    BOOL bound = NO;
    for (uint32_t index = 0; index < sessionCount; ++index)
    {
        FPD3DMetalFrameGenerationSession *session =
            (__bridge FPD3DMetalFrameGenerationSession *)sessions[index];
        if (!bound)
        {
            bound = [session bindSourceDrawable:drawable
                                toCommandBuffer:commandBuffer];
            if (bound && !FPRegisterSourceCommandBufferBinding(
                    commandBuffer,
                    session
                ))
                bound = NO;
        }
        CFRelease(sessions[index]);
    }
    return bound;
}

static void FPPrepareTrackedSourceCapture(
    id<MTLCommandBuffer> commandBuffer
)
{
    if (!commandBuffer) return;
    CFTypeRef sessions[FP_SOURCE_COMMAND_BUFFER_BINDING_CAPACITY] = {NULL};
    uint32_t sessionCount = FPTakeSourceCommandBufferBindings(
        commandBuffer,
        sessions
    );
    for (uint32_t index = 0; index < sessionCount; ++index)
    {
        FPD3DMetalFrameGenerationSession *session =
            (__bridge FPD3DMetalFrameGenerationSession *)sessions[index];
        [session prepareSourceCaptureBeforeCommit:commandBuffer];
        CFRelease(sessions[index]);
    }
}

static void FPInstallCommandBufferHooksForObject(
    id<MTLCommandBuffer> commandBuffer
);

static id<MTLCommandBuffer> FPCommandQueueCommandBuffer(id self, SEL selector)
{
    typedef id<MTLCommandBuffer> (*Original)(id, SEL);
    Original original = (Original)FPOriginalMetalImplementation(self, selector);
    id<MTLCommandBuffer> commandBuffer = original ? original(self, selector) : nil;
    FPInstallCommandBufferHooksForObject(commandBuffer);
    return commandBuffer;
}

static id<MTLCommandBuffer> FPCommandQueueCommandBufferWithDescriptor(
    id self,
    SEL selector,
    MTLCommandBufferDescriptor *descriptor
)
{
    typedef id<MTLCommandBuffer> (*Original)(id, SEL, MTLCommandBufferDescriptor *);
    Original original = (Original)FPOriginalMetalImplementation(self, selector);
    id<MTLCommandBuffer> commandBuffer = original
        ? original(self, selector, descriptor) : nil;
    FPInstallCommandBufferHooksForObject(commandBuffer);
    return commandBuffer;
}

static void FPCommandBufferPresentDrawable(
    id<MTLCommandBuffer> self,
    SEL selector,
    id<MTLDrawable> drawable
)
{
    typedef void (*Original)(id, SEL, id<MTLDrawable>);
    Original original = (Original)FPOriginalMetalImplementation(self, selector);
    (void)FPBindTrackedSourceDrawable((id<CAMetalDrawable>)drawable, self);
    if (original) original(self, selector, drawable);
}

static void FPCommandBufferPresentDrawableAtTime(
    id<MTLCommandBuffer> self,
    SEL selector,
    id<MTLDrawable> drawable,
    CFTimeInterval presentationTime
)
{
    typedef void (*Original)(id, SEL, id<MTLDrawable>, CFTimeInterval);
    Original original = (Original)FPOriginalMetalImplementation(self, selector);
    (void)FPBindTrackedSourceDrawable((id<CAMetalDrawable>)drawable, self);
    if (original) original(self, selector, drawable, presentationTime);
}

static void FPCommandBufferPresentDrawableAfterMinimumDuration(
    id<MTLCommandBuffer> self,
    SEL selector,
    id<MTLDrawable> drawable,
    CFTimeInterval duration
)
{
    typedef void (*Original)(id, SEL, id<MTLDrawable>, CFTimeInterval);
    Original original = (Original)FPOriginalMetalImplementation(self, selector);
    (void)FPBindTrackedSourceDrawable((id<CAMetalDrawable>)drawable, self);
    if (original) original(self, selector, drawable, duration);
}

static void FPCommandBufferCommit(id<MTLCommandBuffer> self, SEL selector)
{
    typedef void (*Original)(id, SEL);
    Original original = (Original)FPOriginalMetalImplementation(self, selector);
    FPPrepareTrackedSourceCapture(self);
    if (original) original(self, selector);
}

static void FPInstallCommandBufferHooksForObject(
    id<MTLCommandBuffer> commandBuffer
)
{
    if (!commandBuffer) return;
    Class concreteClass = object_getClass(commandBuffer);
    uintptr_t classIdentity = (uintptr_t)(__bridge const void *)concreteClass;
    for (uint32_t index = 0;
         index < FP_HOOKED_COMMAND_BUFFER_CLASS_CAPACITY;
         ++index)
        if (atomic_load_explicit(
                &FPFullyHookedCommandBufferClasses[index],
                memory_order_acquire
            ) == classIdentity)
            return;
    BOOL installed = FPInstallMetalMethodHook(
        concreteClass,
        @selector(presentDrawable:),
        (IMP)FPCommandBufferPresentDrawable
    );
    installed = FPInstallMetalMethodHook(
        concreteClass,
        @selector(presentDrawable:atTime:),
        (IMP)FPCommandBufferPresentDrawableAtTime
    ) && installed;
    installed = FPInstallMetalMethodHook(
        concreteClass,
        @selector(presentDrawable:afterMinimumDuration:),
        (IMP)FPCommandBufferPresentDrawableAfterMinimumDuration
    ) && installed;
    installed = FPInstallMetalMethodHook(
        concreteClass,
        @selector(commit),
        (IMP)FPCommandBufferCommit
    ) && installed;
    if (!installed) return;
    for (uint32_t index = 0;
         index < FP_HOOKED_COMMAND_BUFFER_CLASS_CAPACITY;
         ++index)
    {
        uintptr_t observed = atomic_load_explicit(
            &FPFullyHookedCommandBufferClasses[index],
            memory_order_acquire
        );
        if (observed == classIdentity) return;
        if (observed) continue;
        uintptr_t empty = 0;
        if (atomic_compare_exchange_strong_explicit(
                &FPFullyHookedCommandBufferClasses[index],
                &empty,
                classIdentity,
                memory_order_release,
                memory_order_relaxed
            ))
            return;
    }
}

static BOOL FPInstallCommandQueueObservationHooks(id<MTLCommandQueue> queue)
{
    if (!queue) return NO;
    Class concreteClass = object_getClass(queue);
    BOOL installed = FPInstallMetalMethodHook(
        concreteClass,
        @selector(commandBuffer),
        (IMP)FPCommandQueueCommandBuffer
    );
    if ([queue respondsToSelector:@selector(commandBufferWithUnretainedReferences)])
        installed = FPInstallMetalMethodHook(
            concreteClass,
            @selector(commandBufferWithUnretainedReferences),
            (IMP)FPCommandQueueCommandBuffer
        ) && installed;
    if ([queue respondsToSelector:@selector(commandBufferWithDescriptor:)])
        installed = FPInstallMetalMethodHook(
            concreteClass,
            @selector(commandBufferWithDescriptor:),
            (IMP)FPCommandQueueCommandBufferWithDescriptor
        ) && installed;
    id<MTLCommandBuffer> probe = [queue commandBuffer];
    if (!probe) return NO;
    [probe commit];
    return installed;
}

static BOOL FPInstallSourceDrawableObservationHook(void)
{
    static dispatch_once_t onceToken;
    static BOOL installed = NO;

    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(
            CAMetalLayer.class,
            @selector(nextDrawable)
        );
        Method replacement = class_getInstanceMethod(
            CAMetalLayer.class,
            @selector(fp_frameGeneration_nextDrawable)
        );
        if (!original || !replacement) return;
        method_exchangeImplementations(original, replacement);
        installed = YES;
    });
    return installed;
}

@implementation FPFrameGenerationHostView

- (BOOL)isFlipped
{
    return YES;
}

- (NSView *)hitTest:(NSPoint)point
{
    (void)point;
    return nil;
}

- (void)layout
{
    [super layout];
    [self.frameGenerationSession layoutOwnedLayers];
}

@end

@implementation CAMetalLayer (ForgePlayFrameGenerationSourceObservation)

- (nullable id<CAMetalDrawable>)fp_frameGeneration_nextDrawable
{
    /* After method exchange this selector calls CAMetalLayer's original
     * implementation. Registry-free layers remain an exact pass-through. */
    FPD3DMetalFrameGenerationSession *session =
        FPFrameGenerationSessionForSourceLayer(self);
    BOOL observationActive = session && [session sourceObservationIsActive];
    BOOL captureActive = observationActive && [session sourceCaptureIsEnabled];
    /* Timestamp monitoring must remain the renderer's original direct path.
     * Only a demand transition arms a subsequent drawable for shader-readable
     * capture; the drawable that detected the slow interval is never reused as
     * a synthetic seed. */
    if (captureActive && self.framebufferOnly) self.framebufferOnly = NO;
    id<CAMetalDrawable> drawable = [self fp_frameGeneration_nextDrawable];

    if (!drawable || !observationActive) return drawable;
    /* Keep D3DMetal's concrete drawable identity intact. Pixel capture is
     * joined later to the renderer's own source command buffer; this handler
     * records only the public positive presentation timestamp. */
    __weak FPD3DMetalFrameGenerationSession *weakSession = session;
    uint64_t ticketID = captureActive
        ? [session trackSourceDrawable:drawable] : 0;
    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
        FPD3DMetalFrameGenerationSession *strongSession = weakSession;
        if (!strongSession) return;
        [strongSession sourceDrawableTicket:ticketID
                            captureWasArmed:captureActive
                        wasPresentedAtTime:presentedDrawable.presentedTime];
    }];
    return drawable;
}

@end

@implementation FPD3DMetalFrameGenerationSession
{
    __weak NSView *_owningMetalView;
    FPFrameGenerationHostView *_hostView;
    CAMetalLayer *_sourceLayer;
    CAMetalLayer *_outputLayer;
    CAMetalLayer *_retainedOutputLayer;
    CATextLayer *_frameCheckLayer;
    CAMetalDisplayLink *_displayLink;
    id<MTLDevice> _device;
    id<MTLDevice> _resourceDevice;
    id<MTLCommandQueue> _captureQueue;
    id<MTLCommandQueue> _displayQueue;
    id<MTLLibrary> _compositionLibrary;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>>
        *_compositionPipelines;
    id<MTLRenderPipelineState> _midpointPipeline;
    id<MTLRenderPipelineState> _currentPipeline;
    NSArray<id<MTLTexture>> *_captureTextures;
    FPFrameGenerationState *_state;
    os_unfair_lock _stateLock;
    os_unfair_lock _telemetryWriteLock;
    BOOL _captureSlotInFlight[FP_CAPTURE_TEXTURE_POOL_CAPACITY];
    FPFrameGenerationCaptureSubmission
        _captureSubmissions[FP_CAPTURE_TEXTURE_POOL_CAPACITY];
    NSInteger _historySlot;
    NSInteger _readyPairPreviousSlot;
    NSInteger _readyPairCurrentSlot;
    NSInteger _queuedPairedCurrentSlot;
    FPFrameGenerationReadyCurrentTexture
        _readyCurrentTextures[FP_FRAME_GENERATION_READY_CURRENT_CAPACITY];
    FPFrameGenerationSourceDrawableTicket
        _sourceDrawableTickets[FP_SOURCE_DRAWABLE_TICKET_CAPACITY];
    uint32_t _readyCurrentTextureCount;
    uint64_t _readyPairEpoch;
    uint64_t _queuedPairedCurrentEpoch;
    FPFrameGenerationTextureSubmission
        _textureSubmissions[FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT];
    FPFrameGenerationPresentationReceipt
        _presentationReceipts[FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY];
    uint64_t _surfaceGeneration;
    CGSize _surfaceDrawableSize;
    MTLPixelFormat _surfacePixelFormat;
    id<MTLDevice> _surfaceDevice;
    uint64_t _captureSkippedBusy;
    uint32_t _captureInFlight;
    uint32_t _maximumCaptureInFlight;
    uint64_t _nextCaptureSequence;
    uint32_t _captureBusyEpisode;
    CFTimeInterval _captureOutstandingStartTime;
    uint64_t _capturePoolAllocations;
    uint64_t _capturePoolReleases;
    uint64_t _nextSourceDrawableTicketID;
    uint64_t _sourcePresentCommandBufferBound;
    uint64_t _sourceCaptureEncodedOnSourceCB;
    uint64_t _sourceCaptureJoined;
    uint64_t _sourcePresentUncovered;
    uint32_t _consecutiveSourcePresentUncovered;
    uint64_t _retiredCaptureSurfaceGeneration;
    uint32_t _retiredCaptureSlotMask;
    uint32_t _retiredCaptureCommandBufferCount;
    uint64_t _captureResourceRecoveryCount;
    BOOL _captureRecoveryAwaitingProgress;
    uint64_t _sessionIdentifier;
    CFTimeInterval _lastOutputProgressTime;
    uint32_t _consecutiveEmptyDisplayUpdates;
    uint64_t _displayResumeCount;
    uint32_t _presentationStallChecks;
    uint32_t _targetFrameRate;
    BOOL _frameCheckEnabled;
    BOOL _sourceFramebufferOnlyBeforeSession;
    atomic_bool _displayLinkPausedForWork;
    atomic_bool _invalidated;
    atomic_bool _failed;
    atomic_bool _sourceCaptureEnabled;
    atomic_bool _surfaceUpdatePending;
    atomic_bool _captureRecoveryPending;
    atomic_bool _displayLinkResumePending;
    atomic_bool _presentationWatchdogPending;
    atomic_bool _retainedOutputPending;
    atomic_bool _frameCheckUpdatePending;
    CFTimeInterval _lastTelemetryTime;
    CFTimeInterval _lastFrameCheckUpdateTime;
}

@synthesize sourceLayer = _sourceLayer;

/* The caller must hold _stateLock. Keeping these checks next to every state
 * access prevents a callback that raced invalidate from touching retired
 * state. The allocation itself remains alive until dealloc, when no callback
 * can still hold a strong reference to the session. */
- (BOOL)callbackStateIsUsableLocked
{
    return _state != NULL &&
        !atomic_load(&_invalidated) &&
        !atomic_load(&_failed);
}

- (BOOL)telemetryStateIsUsableLocked
{
    return _state != NULL && !atomic_load(&_invalidated);
}

- (BOOL)sourceObservationIsActive
{
    return !atomic_load(&_invalidated) && !atomic_load(&_failed);
}

- (BOOL)sourceCaptureIsEnabled
{
    return !atomic_load(&_invalidated) && !atomic_load(&_failed) &&
        atomic_load(&_sourceCaptureEnabled);
}

- (nullable id<MTLRenderPipelineState>)compositionPipelineForPixelFormat:
    (MTLPixelFormat)pixelFormat
                                                     currentOnly:(BOOL)currentOnly
                                                           error:(NSError **)error
{
    if (!_compositionLibrary || pixelFormat == MTLPixelFormatInvalid) return nil;
    NSNumber *key = @(((uint64_t)pixelFormat << 1) | (currentOnly ? 1u : 0u));
    id<MTLRenderPipelineState> cached = _compositionPipelines[key];
    if (cached) return cached;

    id<MTLFunction> vertex = [_compositionLibrary
        newFunctionWithName:@"fp_frame_generation_vertex"];
    id<MTLFunction> fragment = [_compositionLibrary newFunctionWithName:
        currentOnly ? @"fp_frame_generation_current" :
            @"fp_frame_generation_midpoint"];
    if (!vertex || !fragment) return nil;
    MTLRenderPipelineDescriptor *descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;
    id<MTLRenderPipelineState> pipeline = [_resourceDevice
        newRenderPipelineStateWithDescriptor:descriptor
        error:error];
    if (pipeline) _compositionPipelines[key] = pipeline;
    return pipeline;
}

- (BOOL)prepareDemandMetalResourcesOnMain
{
    NSAssert(NSThread.isMainThread, @"%@", @"demand Metal setup is main-thread bound");
    id<MTLDevice> resourceDevice = _sourceLayer.device
        ? _sourceLayer.device : _device;
    if (_captureQueue && _displayQueue && _compositionLibrary &&
        _compositionPipelines && _currentPipeline &&
        _resourceDevice == resourceDevice)
        return YES;

    [self releaseDemandMetalResourcesOnMain];
    _resourceDevice = resourceDevice;
    _captureQueue = [resourceDevice
        newCommandQueueWithMaxCommandBufferCount:FP_CAPTURE_MAX_IN_FLIGHT];
    _displayQueue = [resourceDevice newCommandQueueWithMaxCommandBufferCount:
        FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT];
    NSError *libraryError = nil;
    _compositionLibrary = [resourceDevice
        newLibraryWithSource:FPFrameGenerationCompositionShaderSource()
        options:nil
        error:&libraryError];
    _compositionPipelines = [NSMutableDictionary dictionary];
    if (!_captureQueue || !_displayQueue || !_compositionLibrary ||
        !_compositionPipelines)
    {
        [self releaseDemandMetalResourcesOnMain];
        return NO;
    }
    NSError *midpointPipelineError = nil;
    _midpointPipeline = [self
        compositionPipelineForPixelFormat:_sourceLayer.pixelFormat
        currentOnly:NO
        error:&midpointPipelineError];
    NSError *currentPipelineError = nil;
    _currentPipeline = [self
        compositionPipelineForPixelFormat:_sourceLayer.pixelFormat
        currentOnly:YES
        error:&currentPipelineError];
    if (!_currentPipeline)
    {
        [self releaseDemandMetalResourcesOnMain];
        return NO;
    }
    /* Observe only dynamically returned public Metal protocol objects. The
     * queue hooks preserve every factory call and install command-buffer
     * hooks on the concrete class before returning it to its caller. */
    (void)FPInstallCommandQueueObservationHooks(_captureQueue);
    return YES;
}

- (void)releaseDemandMetalResourcesOnMain
{
    NSAssert(NSThread.isMainThread, @"%@", @"demand Metal teardown is main-thread bound");
    _midpointPipeline = nil;
    _currentPipeline = nil;
    [_compositionPipelines removeAllObjects];
    _compositionPipelines = nil;
    _compositionLibrary = nil;
    _displayQueue = nil;
    _captureQueue = nil;
    _resourceDevice = nil;
}

- (nullable instancetype)initWithOwningMetalView:(NSView *)owningMetalView
                                     device:(id<MTLDevice>)device
                            targetFrameRate:(uint32_t)targetFrameRate
                          frameCheckEnabled:(BOOL)frameCheckEnabled
                              failureReason:(char *)failureReason
                     failureReasonCapacity:(size_t)failureReasonCapacity
{
    self = [super init];
    if (!self) return nil;
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _telemetryWriteLock = OS_UNFAIR_LOCK_INIT;
    atomic_init(&_invalidated, false);
    atomic_init(&_failed, false);
    atomic_init(&_sourceCaptureEnabled, false);
    atomic_init(&_surfaceUpdatePending, false);
    atomic_init(&_captureRecoveryPending, false);
    atomic_init(&_displayLinkResumePending, false);
    atomic_init(&_presentationWatchdogPending, false);
    atomic_init(&_displayLinkPausedForWork, false);
    atomic_init(&_retainedOutputPending, false);
    atomic_init(&_frameCheckUpdatePending, false);
    _sessionIdentifier = (uint64_t)atomic_fetch_add_explicit(
        &FPNextFrameGenerationSessionIdentifier,
        1,
        memory_order_relaxed
    );
    if (!_sessionIdentifier)
    {
        _sessionIdentifier = (uint64_t)atomic_fetch_add_explicit(
            &FPNextFrameGenerationSessionIdentifier,
            1,
            memory_order_relaxed
        );
        if (!_sessionIdentifier) _sessionIdentifier = 1;
    }
    _historySlot = FPInvalidCaptureTextureSlot;
    _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
    _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
    _queuedPairedCurrentSlot = FPInvalidCaptureTextureSlot;
    _targetFrameRate = targetFrameRate;
    _frameCheckEnabled = frameCheckEnabled;
    _owningMetalView = owningMetalView;
    _device = device;
    if (![owningMetalView.layer isKindOfClass:CAMetalLayer.class])
    {
        FPCopyFailureReason(
            failureReason,
            failureReasonCapacity,
            "source-metal-layer-invalid"
        );
        return nil;
    }
    /* Preserve Wine's retained-view / borrowed-backing-layer contract. The
     * renderer continues to own and configure this exact layer; ForgePlay
     * observes its drawables without substituting a session-owned child. */
    _sourceLayer = (CAMetalLayer *)owningMetalView.layer;
    _sourceFramebufferOnlyBeforeSession = _sourceLayer.framebufferOnly;
    if (FPFrameGenerationSessionForSourceLayer(_sourceLayer))
    {
        FPCopyFailureReason(
            failureReason,
            failureReasonCapacity,
            "source-metal-layer-already-bound"
        );
        return nil;
    }
    _state = FPFrameGenerationStateCreate(true, targetFrameRate);
    if (!_state)
    {
        FPCopyFailureReason(
            failureReason,
            failureReasonCapacity,
            "state-initialization-failed"
        );
        return nil;
    }

    _hostView = [[FPFrameGenerationHostView alloc]
        initWithFrame:owningMetalView.bounds];
    _hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _hostView.wantsLayer = YES;
    _hostView.layer.backgroundColor = NSColor.clearColor.CGColor;
    _hostView.frameGenerationSession = self;

    /* The owning view is Wine's original WineMetalView. Keeping that view in
     * Wine's normal NSWindowBelow position preserves its resize, Retina and
     * window-drawn lifecycle; this transparent child owns only ForgePlay's
     * generated-output and Frame Check layers. */
    [owningMetalView addSubview:_hostView positioned:NSWindowAbove relativeTo:nil];
    [self layoutOwnedLayers];
    if (_frameCheckEnabled)
    {
        CATextLayer *frameCheckLayer = [self ensureFrameCheckLayerOnMain];
        frameCheckLayer.string = [NSString stringWithFormat:
            @"Target      %6u Hz\n"
             "Final          -- FPS\n"
             "Original       -- FPS\n"
             "Generated     0.0 FPS",
            _targetFrameRate];
    }
    if (!FPRegisterFrameGenerationSourceLayer(_sourceLayer, self))
    {
        FPCopyFailureReason(
            failureReason,
            failureReasonCapacity,
            "source-metal-layer-already-bound"
        );
        [self invalidate];
        return nil;
    }
    [self emitTelemetryForced:YES];
    return self;
}

- (void)activateSourceObservation
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed)) return;
    if (!FPInstallSourceDrawableObservationHook())
    {
        [self failWithReason:"source-observation-hook-unavailable"];
        return;
    }
    [self emitTelemetryForced:YES];
}

- (void)layoutOwnedLayers
{
    if (atomic_load(&_invalidated) || !_hostView.layer) return;
    CGRect bounds = _hostView.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _outputLayer.frame = bounds;
    _retainedOutputLayer.frame = bounds;
    _outputLayer.contentsScale = _sourceLayer.contentsScale;
    _outputLayer.minificationFilter = _sourceLayer.minificationFilter;
    _outputLayer.magnificationFilter = _sourceLayer.magnificationFilter;
    _outputLayer.contentsGravity = _sourceLayer.contentsGravity;
    _outputLayer.colorspace = _sourceLayer.colorspace;
    _outputLayer.wantsExtendedDynamicRangeContent =
        _sourceLayer.wantsExtendedDynamicRangeContent;
    _outputLayer.displaySyncEnabled = _sourceLayer.displaySyncEnabled;
    _outputLayer.presentsWithTransaction = NO;
    _outputLayer.allowsNextDrawableTimeout =
        _sourceLayer.allowsNextDrawableTimeout;
    if (_frameCheckLayer)
    {
        const CGFloat maximumWidth = 360.0;
        const CGFloat minimumWidth = 220.0;
        const CGFloat height = 108.0;
        CGFloat availableWidth = fmax(
            minimumWidth,
            CGRectGetWidth(bounds) - 24.0
        );
        CGFloat width = fmin(maximumWidth, availableWidth);
        _frameCheckLayer.contentsScale = _sourceLayer.contentsScale;
        CGFloat originX = CGRectGetWidth(bounds) - width - 12.0;
        if (originX < 12.0) originX = 12.0;
        _frameCheckLayer.frame = CGRectMake(
            originX,
            12.0,
            width,
            height
        );
    }
    [CATransaction commit];
    id<MTLDevice> currentSourceDevice = _sourceLayer.device
        ? _sourceLayer.device : _device;
    if (_outputLayer &&
        (_outputLayer.device != currentSourceDevice ||
         _outputLayer.pixelFormat != _sourceLayer.pixelFormat ||
         fabs(_outputLayer.drawableSize.width -
              _sourceLayer.drawableSize.width) > 0.5 ||
         fabs(_outputLayer.drawableSize.height -
              _sourceLayer.drawableSize.height) > 0.5))
        [self sourceSurfaceConfigurationDidChange];
}

- (void)installFrameCheckLayerIfNeeded
{
    if (!_frameCheckEnabled)
    {
        [_frameCheckLayer removeFromSuperlayer];
        _frameCheckLayer = nil;
        return;
    }
    /* Preserve the monitoring/priming/active label while moving the HUD above
     * a replacement output surface. The next timestamp or output callback
     * refreshes its values from the authoritative state snapshot. */
    if (!_frameCheckLayer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_frameCheckLayer removeFromSuperlayer];
    [_hostView.layer addSublayer:_frameCheckLayer];
    [self layoutOwnedLayers];
    [CATransaction commit];
}

- (CATextLayer *)ensureFrameCheckLayerOnMain
{
    NSAssert(NSThread.isMainThread, @"%@", @"Frame Check is main-thread bound");
    if (_frameCheckLayer) return _frameCheckLayer;
    if (!_frameCheckEnabled || !_hostView.layer) return nil;
    CATextLayer *layer = [CATextLayer layer];
    layer.opaque = NO;
    layer.backgroundColor = NSColor.clearColor.CGColor;
    layer.foregroundColor = NSColor.whiteColor.CGColor;
    layer.alignmentMode = kCAAlignmentRight;
    layer.font = (__bridge CFTypeRef)@"Menlo";
    layer.fontSize = 16.0;
    layer.wrapped = YES;
    layer.shadowColor = NSColor.blackColor.CGColor;
    layer.shadowOpacity = 0.85f;
    layer.shadowRadius = 2.0;
    layer.shadowOffset = CGSizeZero;
    _frameCheckLayer = layer;
    [_hostView.layer addSublayer:layer];
    [self layoutOwnedLayers];
    return layer;
}

- (void)resetTextureBookkeepingLocked
{
    ++_surfaceGeneration;
    if (!_surfaceGeneration) ++_surfaceGeneration;
    if (_captureTextures.count == FP_CAPTURE_TEXTURE_POOL_CAPACITY)
        ++_capturePoolReleases;
    _captureTextures = nil;
    memset(_captureSlotInFlight, 0, sizeof(_captureSlotInFlight));
    memset(_captureSubmissions, 0, sizeof(_captureSubmissions));
    memset(_sourceDrawableTickets, 0, sizeof(_sourceDrawableTickets));
    _consecutiveSourcePresentUncovered = 0;
    /* Once a surface is detached or retained as a last-good image it owns no
     * live submissions. Committed command buffers retain their encoded Metal
     * resources until completion, while clearing this native ledger lets stale
     * callbacks no-op and keeps the three-slot bound scoped to the current live
     * output surface instead of permanently blocking reacquisition. */
    memset(_textureSubmissions, 0, sizeof(_textureSubmissions));
    memset(_presentationReceipts, 0, sizeof(_presentationReceipts));
    _historySlot = FPInvalidCaptureTextureSlot;
    _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
    _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
    _queuedPairedCurrentSlot = FPInvalidCaptureTextureSlot;
    _readyCurrentTextureCount = 0;
    memset(_readyCurrentTextures, 0, sizeof(_readyCurrentTextures));
    _readyPairEpoch = 0;
    _queuedPairedCurrentEpoch = 0;
    _captureInFlight = 0;
    _captureBusyEpisode = 0;
    _captureOutstandingStartTime = 0.0;
    _lastOutputProgressTime = 0.0;
    _consecutiveEmptyDisplayUpdates = 0;
    _presentationStallChecks = 0;
}

- (BOOL)captureSlotIsReferencedLocked:(NSInteger)slot
{
    if (slot < 0 || slot >= FP_CAPTURE_TEXTURE_POOL_CAPACITY) return YES;
    if (_captureSlotInFlight[slot] || slot == _historySlot ||
        slot == _readyPairPreviousSlot ||
        slot == _readyPairCurrentSlot || slot == _queuedPairedCurrentSlot)
        return YES;
    for (uint32_t index = 0; index < _readyCurrentTextureCount; ++index)
        if (_readyCurrentTextures[index].slot == slot) return YES;
    for (uint32_t index = 0;
         index < FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT;
         ++index)
    {
        if (!_textureSubmissions[index].candidate.submissionID) continue;
        if (_textureSubmissions[index].surfaceGeneration != _surfaceGeneration)
            continue;
        if (_textureSubmissions[index].previousSlot == slot ||
            _textureSubmissions[index].currentSlot == slot)
            return YES;
    }
    return NO;
}

- (BOOL)enqueueReadyCurrentSlotLocked:(NSInteger)slot epoch:(uint64_t)epoch
{
    if (slot < 0 || slot >= FP_CAPTURE_TEXTURE_POOL_CAPACITY || !epoch ||
        _readyCurrentTextureCount >=
            FP_FRAME_GENERATION_READY_CURRENT_CAPACITY)
        return NO;
    for (uint32_t index = 0; index < _readyCurrentTextureCount; ++index)
        if (_readyCurrentTextures[index].epoch == epoch) return NO;
    _readyCurrentTextures[_readyCurrentTextureCount++] =
        (FPFrameGenerationReadyCurrentTexture){
            .epoch = epoch,
            .slot = slot,
        };
    return YES;
}

- (NSInteger)takeReadyCurrentSlotLockedForEpoch:(uint64_t)epoch
{
    if (!epoch) return FPInvalidCaptureTextureSlot;
    for (uint32_t index = 0; index < _readyCurrentTextureCount; ++index)
    {
        if (_readyCurrentTextures[index].epoch != epoch) continue;
        NSInteger slot = _readyCurrentTextures[index].slot;
        if (index + 1 < _readyCurrentTextureCount)
        {
            memmove(
                &_readyCurrentTextures[index],
                &_readyCurrentTextures[index + 1],
                (_readyCurrentTextureCount - index - 1) *
                    sizeof(_readyCurrentTextures[0])
            );
        }
        --_readyCurrentTextureCount;
        memset(
            &_readyCurrentTextures[_readyCurrentTextureCount],
            0,
            sizeof(_readyCurrentTextures[0])
        );
        return slot;
    }
    return FPInvalidCaptureTextureSlot;
}

- (NSInteger)freeCaptureSlotLocked
{
    if (_captureTextures.count != FP_CAPTURE_TEXTURE_POOL_CAPACITY)
        return FPInvalidCaptureTextureSlot;
    for (NSInteger slot = 0;
         slot < FP_CAPTURE_TEXTURE_POOL_CAPACITY;
         ++slot)
        if (![self captureSlotIsReferencedLocked:slot]) return slot;
    return FPInvalidCaptureTextureSlot;
}

- (void)retireCaptureSlotLocked:(NSInteger)slot
{
    if (slot < 0 || slot >= FP_CAPTURE_TEXTURE_POOL_CAPACITY ||
        !_captureSlotInFlight[slot])
        return;
    _captureSlotInFlight[slot] = NO;
    memset(
        &_captureSubmissions[slot],
        0,
        sizeof(_captureSubmissions[slot])
    );
    if (_captureInFlight > 0) --_captureInFlight;

    _captureOutstandingStartTime = 0.0;
    _captureBusyEpisode = 0;
    for (NSInteger candidate = 0;
         candidate < FP_CAPTURE_TEXTURE_POOL_CAPACITY;
         ++candidate)
    {
        FPFrameGenerationCaptureSubmission submission =
            _captureSubmissions[candidate];
        if (!_captureSlotInFlight[candidate] || !submission.sequence ||
            !isfinite(submission.submittedAtTime) ||
            submission.submittedAtTime <= 0.0)
            continue;
        if (_captureOutstandingStartTime <= 0.0 ||
            submission.submittedAtTime < _captureOutstandingStartTime)
            _captureOutstandingStartTime = submission.submittedAtTime;
        _captureBusyEpisode = MAX(
            _captureBusyEpisode,
            submission.busyObservations
        );
    }
}

- (BOOL)retireCaptureCompletionLockedForSlot:(NSInteger)slot
                            surfaceGeneration:(uint64_t)surfaceGeneration
{
    if (slot < 0 || slot >= FP_CAPTURE_TEXTURE_POOL_CAPACITY ||
        !surfaceGeneration)
        return NO;
    if (surfaceGeneration == _surfaceGeneration &&
        _captureSlotInFlight[slot])
    {
        [self retireCaptureSlotLocked:slot];
        return YES;
    }
    uint32_t slotBit = 1u << (uint32_t)slot;
    if (surfaceGeneration == _retiredCaptureSurfaceGeneration &&
        (_retiredCaptureSlotMask & slotBit) != 0)
    {
        _retiredCaptureSlotMask &= ~slotBit;
        if (_retiredCaptureCommandBufferCount > 0)
            --_retiredCaptureCommandBufferCount;
        if (!_retiredCaptureCommandBufferCount)
        {
            _retiredCaptureSurfaceGeneration = 0;
            _retiredCaptureSlotMask = 0;
        }
    }
    return NO;
}

- (BOOL)stageRetiredCaptureGenerationLocked
{
    if (!_captureInFlight) return YES;
    if (_retiredCaptureCommandBufferCount ||
        _retiredCaptureSurfaceGeneration || _retiredCaptureSlotMask)
        return NO;
    uint32_t slotMask = 0;
    uint32_t commandBufferCount = 0;
    for (NSInteger slot = 0;
         slot < FP_CAPTURE_TEXTURE_POOL_CAPACITY;
         ++slot)
    {
        if (!_captureSlotInFlight[slot] ||
            !_captureSubmissions[slot].sequence)
            continue;
        slotMask |= 1u << (uint32_t)slot;
        ++commandBufferCount;
    }
    if (!commandBufferCount || commandBufferCount != _captureInFlight)
        return NO;
    _retiredCaptureSurfaceGeneration = _surfaceGeneration;
    _retiredCaptureSlotMask = slotMask;
    _retiredCaptureCommandBufferCount = commandBufferCount;
    return YES;
}

- (BOOL)recordCaptureBusyLockedAtTime:(CFTimeInterval)now
                            telemetry:(FPFrameGenerationTelemetry)telemetry
{
    ++_captureSkippedBusy;
    CFTimeInterval oldestSubmissionTime = 0.0;
    uint32_t maximumBusyObservations = 0;
    if (!_captureInFlight || !isfinite(now) || now <= 0.0)
    {
        _captureBusyEpisode = 0;
        _captureOutstandingStartTime = 0.0;
        return NO;
    }
    for (NSInteger slot = 0;
         slot < FP_CAPTURE_TEXTURE_POOL_CAPACITY;
         ++slot)
    {
        FPFrameGenerationCaptureSubmission *submission =
            &_captureSubmissions[slot];
        if (!_captureSlotInFlight[slot] || !submission->sequence ||
            !isfinite(submission->submittedAtTime) ||
            submission->submittedAtTime <= 0.0)
            continue;
        if (submission->busyObservations < UINT32_MAX)
            ++submission->busyObservations;
        maximumBusyObservations = MAX(
            maximumBusyObservations,
            submission->busyObservations
        );
        if (oldestSubmissionTime <= 0.0 ||
            submission->submittedAtTime < oldestSubmissionTime)
            oldestSubmissionTime = submission->submittedAtTime;
    }
    _captureBusyEpisode = maximumBusyObservations;
    _captureOutstandingStartTime = oldestSubmissionTime;
    if (oldestSubmissionTime <= 0.0) return NO;
    double slot = telemetry.effectiveDisplaySlotDuration;
    if (!isfinite(slot) || slot <= 0.0)
        return NO;
    double budget = FPCaptureBackpressureSlotMultiplier * slot;
    if (_captureBusyEpisode < FP_CAPTURE_BUSY_EPISODE_MINIMUM_SAMPLES ||
        now - oldestSubmissionTime <= budget)
        return NO;
    if (!telemetry.outputActive) return YES;
    return isfinite(_lastOutputProgressTime) &&
        _lastOutputProgressTime > 0.0 &&
        now - _lastOutputProgressTime > budget;
}

- (BOOL)createCaptureTexturePoolForDevice:(id<MTLDevice>)device
                              drawableSize:(CGSize)drawableSize
                               pixelFormat:(MTLPixelFormat)pixelFormat
{
    if (!device || pixelFormat == MTLPixelFormatInvalid ||
        drawableSize.width <= 0.0 || drawableSize.height <= 0.0)
        return NO;
    NSUInteger width = (NSUInteger)ceil(drawableSize.width);
    NSUInteger height = (NSUInteger)ceil(drawableSize.height);
    if (!width || !height) return NO;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:pixelFormat
        width:width
        height:height
        mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead;
    NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray
        arrayWithCapacity:FP_CAPTURE_TEXTURE_POOL_CAPACITY];
    for (NSUInteger index = 0;
         index < FP_CAPTURE_TEXTURE_POOL_CAPACITY;
         ++index)
    {
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (!texture) return NO;
        [textures addObject:texture];
    }
    os_unfair_lock_lock(&_stateLock);
    if (![self callbackStateIsUsableLocked])
    {
        os_unfair_lock_unlock(&_stateLock);
        return NO;
    }
    _captureTextures = [textures copy];
    ++_capturePoolAllocations;
    os_unfair_lock_unlock(&_stateLock);
    return YES;
}

- (void)scheduleCaptureResourceRecovery
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed) ||
        atomic_exchange(&_captureRecoveryPending, true))
        return;
    /* Stop admitting source textures before retiring the stalled queue. The
     * output layer keeps its last positive current and remains the sole visual
     * owner throughout this capture-only recovery. */
    atomic_store(&_sourceCaptureEnabled, false);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load(&self->_invalidated) || atomic_load(&self->_failed))
        {
            atomic_store(&self->_captureRecoveryPending, false);
            return;
        }

        id<MTLDevice> device = self->_sourceLayer.device
            ? self->_sourceLayer.device : self->_device;
        CGSize drawableSize = self->_sourceLayer.drawableSize;
        MTLPixelFormat pixelFormat = self->_sourceLayer.pixelFormat;
        id<MTLCommandQueue> replacementQueue = [device
            newCommandQueueWithMaxCommandBufferCount:FP_CAPTURE_MAX_IN_FLIGHT];
        if (!replacementQueue || drawableSize.width <= 0.0 ||
            drawableSize.height <= 0.0 ||
            pixelFormat == MTLPixelFormatInvalid)
        {
            atomic_store(&self->_captureRecoveryPending, false);
            [self failWithReason:"capture-resource-recovery-failed"];
            return;
        }

        os_unfair_lock_lock(&self->_stateLock);
        if (![self callbackStateIsUsableLocked])
        {
            os_unfair_lock_unlock(&self->_stateLock);
            atomic_store(&self->_captureRecoveryPending, false);
            return;
        }
        if (self->_captureRecoveryAwaitingProgress ||
            ![self stageRetiredCaptureGenerationLocked])
        {
            os_unfair_lock_unlock(&self->_stateLock);
            atomic_store(&self->_captureRecoveryPending, false);
            [self failWithReason:"capture-resource-recovery-exhausted"];
            return;
        }
        self->_captureRecoveryAwaitingProgress = YES;
        ++self->_captureResourceRecoveryCount;
        FPFrameGenerationRecoverCapturePipeline(
            self->_state,
            "capture-resource-recovery"
        );
        [self resetTextureBookkeepingLocked];
        self->_captureQueue = replacementQueue;
        self->_surfaceDevice = device;
        self->_surfacePixelFormat = pixelFormat;
        self->_surfaceDrawableSize = drawableSize;
        self->_lastFrameCheckUpdateTime = 0.0;
        os_unfair_lock_unlock(&self->_stateLock);

        BOOL recovered = [self createCaptureTexturePoolForDevice:device
                                                    drawableSize:drawableSize
                                                     pixelFormat:pixelFormat];
        if (recovered && !atomic_load(&self->_invalidated) &&
            !atomic_load(&self->_failed))
        {
            self->_sourceLayer.framebufferOnly = NO;
            atomic_store(&self->_sourceCaptureEnabled, true);
        }
        atomic_store(&self->_captureRecoveryPending, false);
        if (!recovered)
        {
            [self failWithReason:"capture-resource-recovery-failed"];
            return;
        }
        [self scheduleDisplayLinkResume];
        [self emitTelemetryForced:YES];
    });
}

- (void)scheduleCapturePrimingOutputSurface
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed))
        return;
    if (atomic_exchange(&_surfaceUpdatePending, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_load(&self->_invalidated) &&
            !atomic_load(&self->_failed))
        {
            BOOL demandStillActive = NO;
            os_unfair_lock_lock(&self->_stateLock);
            if ([self callbackStateIsUsableLocked])
            {
                FPFrameGenerationTelemetry current =
                    FPFrameGenerationTelemetrySnapshot(self->_state);
                demandStillActive =
                    strcmp(current.state, "priming") == 0 ||
                    strcmp(current.state, "active") == 0;
            }
            os_unfair_lock_unlock(&self->_stateLock);
            if (!demandStillActive)
            {
                atomic_store(&self->_surfaceUpdatePending, false);
                return;
            }
            if (![self prepareDemandMetalResourcesOnMain])
            {
                atomic_store(&self->_surfaceUpdatePending, false);
                [self failWithReason:"metal-resource-initialization-failed"];
                return;
            }
            [self rebuildOutputSurfaceResettingState:NO];
            BOOL outputPrepared = self->_outputLayer != nil &&
                self->_displayLink != nil;
            FPFrameGenerationTelemetry telemetry = {0};
            os_unfair_lock_lock(&self->_stateLock);
            if ([self callbackStateIsUsableLocked])
            {
                outputPrepared = outputPrepared &&
                    self->_captureTextures.count ==
                        FP_CAPTURE_TEXTURE_POOL_CAPACITY;
                telemetry = FPFrameGenerationTelemetrySnapshot(self->_state);
                demandStillActive =
                    strcmp(telemetry.state, "priming") == 0 ||
                    strcmp(telemetry.state, "active") == 0;
            }
            os_unfair_lock_unlock(&self->_stateLock);
            if (outputPrepared && demandStillActive &&
                !atomic_load(&self->_invalidated) &&
                !atomic_load(&self->_failed))
            {
                /* Arm only after every demand-owned resource exists. A source
                 * drawable acquired before this point remains direct output. */
                self->_sourceLayer.framebufferOnly = NO;
                atomic_store(&self->_sourceCaptureEnabled, true);
            }
            else if (!atomic_load(&self->_failed))
            {
                [self->_displayLink invalidate];
                self->_displayLink.delegate = nil;
                self->_displayLink = nil;
                [self->_outputLayer removeFromSuperlayer];
                self->_outputLayer = nil;
            }
            [self updateFrameCheckWithTelemetry:telemetry];
            [self emitTelemetryForced:YES];
        }
        atomic_store(&self->_surfaceUpdatePending, false);
    });
}

- (void)rebuildOutputSurfaceResettingState:(BOOL)resetState
{
    NSAssert(
        NSThread.isMainThread,
        @"%@",
        @"output surface ownership is main-thread bound"
    );
    if (atomic_load(&_invalidated) || atomic_load(&_failed)) return;
    [_displayLink invalidate];
    _displayLink.delegate = nil;
    _displayLink = nil;
    atomic_store(&_displayLinkPausedForWork, true);
    atomic_store(&_displayLinkResumePending, false);

    BOOL currentOutputWasActive = NO;
    if (_outputLayer)
    {
        os_unfair_lock_lock(&_stateLock);
        if ([self callbackStateIsUsableLocked])
            currentOutputWasActive =
                FPFrameGenerationTelemetrySnapshot(_state).outputActive;
        os_unfair_lock_unlock(&_stateLock);
    }
    if (currentOutputWasActive)
    {
        [_retainedOutputLayer removeFromSuperlayer];
        _retainedOutputLayer = _outputLayer;
        atomic_store(&_retainedOutputPending, true);
    }
    else
    {
        [_outputLayer removeFromSuperlayer];
        /* A second reset before reacquisition must not orphan the prior
         * last-good surface. Keep its retirement token live until a replacement
         * drawable is positively presented. */
        atomic_store(
            &_retainedOutputPending,
            _retainedOutputLayer != nil
        );
    }
    _outputLayer = nil;

    os_unfair_lock_lock(&_stateLock);
    if ([self callbackStateIsUsableLocked])
    {
        if (resetState)
        {
            FPFrameGenerationResetForSurfaceChange(_state, "surface-change");
            _lastFrameCheckUpdateTime = 0.0;
        }
        [self resetTextureBookkeepingLocked];
    }
    os_unfair_lock_unlock(&_stateLock);
    if (atomic_load(&_invalidated) || atomic_load(&_failed)) return;

    id<MTLDevice> surfaceDevice = _sourceLayer.device
        ? _sourceLayer.device : _device;
    MTLPixelFormat surfacePixelFormat = _sourceLayer.pixelFormat;
    CGSize surfaceDrawableSize = _sourceLayer.drawableSize;
    CGFloat surfaceContentsScale = _sourceLayer.contentsScale;
    CALayerContentsFilter surfaceMinificationFilter =
        _sourceLayer.minificationFilter;
    CALayerContentsFilter surfaceMagnificationFilter =
        _sourceLayer.magnificationFilter;
    CALayerContentsGravity surfaceContentsGravity =
        _sourceLayer.contentsGravity;
    CGColorSpaceRef surfaceColorspace = _sourceLayer.colorspace;
    BOOL surfaceEDR = _sourceLayer.wantsExtendedDynamicRangeContent;
    BOOL surfaceDisplaySyncEnabled = _sourceLayer.displaySyncEnabled;
    BOOL surfaceAllowsNextDrawableTimeout =
        _sourceLayer.allowsNextDrawableTimeout;
    if (_resourceDevice != surfaceDevice &&
        ![self prepareDemandMetalResourcesOnMain])
    {
        [self failWithReason:"metal-resource-initialization-failed"];
        return;
    }
    NSError *midpointPipelineError = nil;
    id<MTLRenderPipelineState> midpointPipeline = [self
        compositionPipelineForPixelFormat:surfacePixelFormat
        currentOnly:NO
        error:&midpointPipelineError];
    NSError *currentPipelineError = nil;
    id<MTLRenderPipelineState> currentPipeline = [self
        compositionPipelineForPixelFormat:surfacePixelFormat
        currentOnly:YES
        error:&currentPipelineError];
    if (!currentPipeline)
    {
        [self failWithReason:"metal-output-pipeline-unavailable"];
        return;
    }
    os_unfair_lock_lock(&_stateLock);
    if (![self callbackStateIsUsableLocked])
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _surfaceDevice = surfaceDevice;
    _surfacePixelFormat = surfacePixelFormat;
    _surfaceDrawableSize = surfaceDrawableSize;
    _midpointPipeline = midpointPipeline;
    _currentPipeline = currentPipeline;
    os_unfair_lock_unlock(&_stateLock);

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = surfaceDevice;
    layer.pixelFormat = surfacePixelFormat;
    layer.framebufferOnly = YES;
    layer.contentsScale = surfaceContentsScale;
    layer.minificationFilter = surfaceMinificationFilter;
    layer.magnificationFilter = surfaceMagnificationFilter;
    layer.contentsGravity = surfaceContentsGravity;
    layer.drawableSize = surfaceDrawableSize;
    layer.colorspace = surfaceColorspace;
    layer.wantsExtendedDynamicRangeContent = surfaceEDR;
    layer.displaySyncEnabled = surfaceDisplaySyncEnabled;
    layer.presentsWithTransaction = NO;
    layer.allowsNextDrawableTimeout = surfaceAllowsNextDrawableTimeout;
    layer.maximumDrawableCount =
        FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT;
    /* Keep opacity at its visible default and keep the layer non-opaque.  A
     * fully transparent output layer can be culled with its display link, but
     * declaring it opaque after activation can cull the source layer whose
     * presented handlers supply the next captures.  The presented drawable
     * itself provides visual ownership while both producer lifecycles remain
     * observable. */
    layer.opaque = NO;
    layer.backgroundColor = NSColor.clearColor.CGColor;
    _outputLayer = layer;
    [_hostView.layer addSublayer:layer];
    [self installFrameCheckLayerIfNeeded];
    [self layoutOwnedLayers];

    // A zero-sized/temporarily resized source has no displayable output.
    // Keep the clear owning layer installed, but do not ask Core Animation for
    // an empty drawable (which some compositors resolve as a black frame).
    if (layer.drawableSize.width <= 0.0 || layer.drawableSize.height <= 0.0)
        return;
    if (![self createCaptureTexturePoolForDevice:surfaceDevice
                                    drawableSize:surfaceDrawableSize
                                     pixelFormat:surfacePixelFormat])
    {
        [self failWithReason:"capture-pool-allocation-failed"];
        return;
    }

    CAMetalDisplayLink *displayLink =
        [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
    displayLink.delegate = self;
    displayLink.preferredFrameLatency = 1.0f;
    /* This is a variable-rate hint derived only from the selected N. It does
     * not force 60 Hz: 120 requests 60...120, 144 requests 72...144, and 240
     * requests 120...240 while Core Animation and the display retain final
     * cadence control. */
    const float targetRate = (float)_targetFrameRate;
    displayLink.preferredFrameRateRange = CAFrameRateRangeMake(
        targetRate / 2.0f,
        targetRate,
        targetRate
    );
    displayLink.paused = YES;
    [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _displayLink = displayLink;
}

- (BOOL)sourceTextureRequiresOutputSurfaceUpdate:(id<MTLTexture>)texture
{
    if (!texture) return YES;
    os_unfair_lock_lock(&_stateLock);
    BOOL requiresUpdate =
        _captureTextures.count != FP_CAPTURE_TEXTURE_POOL_CAPACITY ||
        _surfaceDevice != texture.device ||
        _surfacePixelFormat != texture.pixelFormat ||
        fabs(_surfaceDrawableSize.width - (CGFloat)texture.width) > 0.5 ||
        fabs(_surfaceDrawableSize.height - (CGFloat)texture.height) > 0.5;
    os_unfair_lock_unlock(&_stateLock);
    return requiresUpdate;
}

- (void)sourceSurfaceConfigurationDidChange
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed) ||
        ![self sourceCaptureIsEnabled]) return;
    if (atomic_exchange(&_surfaceUpdatePending, true)) return;
    dispatch_block_t update = ^{
        if (!atomic_load(&self->_invalidated) &&
            !atomic_load(&self->_failed) &&
            [self sourceCaptureIsEnabled])
        {
            [self rebuildOutputSurfaceResettingState:YES];
            [self emitTelemetryForced:YES];
        }
        atomic_store(&self->_surfaceUpdatePending, false);
    };
    dispatch_async(dispatch_get_main_queue(), update);
}

- (NSInteger)sourceDrawableTicketIndexLocked:(uint64_t)ticketID
{
    if (!ticketID) return -1;
    for (uint32_t index = 0;
         index < FP_SOURCE_DRAWABLE_TICKET_CAPACITY;
         ++index)
        if (_sourceDrawableTickets[index].ticketID == ticketID)
            return (NSInteger)index;
    return -1;
}

- (uint64_t)trackSourceDrawable:(id<CAMetalDrawable>)drawable
{
    if (!drawable || ![self sourceCaptureIsEnabled]) return 0;
    id<MTLTexture> sourceTexture = drawable.texture;
    if (!sourceTexture) return 0;
    if ([self sourceTextureRequiresOutputSurfaceUpdate:sourceTexture])
    {
        [self sourceSurfaceConfigurationDidChange];
        return 0;
    }
    uint64_t ticketID = 0;
    os_unfair_lock_lock(&_stateLock);
    if ([self callbackStateIsUsableLocked] &&
        [self sourceCaptureIsEnabled])
    {
        for (uint32_t index = 0;
             index < FP_SOURCE_DRAWABLE_TICKET_CAPACITY;
             ++index)
        {
            FPFrameGenerationSourceDrawableTicket *ticket =
                &_sourceDrawableTickets[index];
            if (ticket->ticketID) continue;
            ++_nextSourceDrawableTicketID;
            if (!_nextSourceDrawableTicketID)
                ++_nextSourceDrawableTicketID;
            ticketID = _nextSourceDrawableTicketID;
            *ticket = (FPFrameGenerationSourceDrawableTicket){
                .ticketID = ticketID,
                .surfaceGeneration = _surfaceGeneration,
                .drawableID = (uint64_t)drawable.drawableID,
                .drawableIdentity = (__bridge const void *)drawable,
                .sourceTextureIdentity = (__bridge const void *)sourceTexture,
                .captureSlot = FPInvalidCaptureTextureSlot,
            };
            break;
        }
    }
    os_unfair_lock_unlock(&_stateLock);
    return ticketID;
}

- (BOOL)bindSourceDrawable:(id<CAMetalDrawable>)drawable
           toCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    if (!drawable || !commandBuffer || ![self sourceCaptureIsEnabled])
        return NO;
    uint64_t drawableID = (uint64_t)drawable.drawableID;
    const void *drawableIdentity = (__bridge const void *)drawable;
    const void *commandBufferIdentity =
        (__bridge const void *)commandBuffer;
    BOOL bound = NO;
    os_unfair_lock_lock(&_stateLock);
    if ([self callbackStateIsUsableLocked])
    {
        for (uint32_t index = 0;
             index < FP_SOURCE_DRAWABLE_TICKET_CAPACITY;
             ++index)
        {
            FPFrameGenerationSourceDrawableTicket *ticket =
                &_sourceDrawableTickets[index];
            if (!ticket->ticketID ||
                ticket->surfaceGeneration != _surfaceGeneration ||
                ticket->drawableIdentity != drawableIdentity ||
                ticket->drawableID != drawableID)
                continue;
            id<MTLTexture> sourceTexture =
                (__bridge id<MTLTexture>)ticket->sourceTextureIdentity;
            if (!sourceTexture || sourceTexture.device != commandBuffer.device)
                break;
            if (!ticket->commandBufferBound)
            {
                ticket->commandBufferIdentity = commandBufferIdentity;
                ticket->commandBufferBound = YES;
                ++_sourcePresentCommandBufferBound;
            }
            bound = ticket->commandBufferIdentity == commandBufferIdentity;
            break;
        }
    }
    os_unfair_lock_unlock(&_stateLock);
    return bound;
}

- (void)prepareSourceCaptureBeforeCommit:
    (id<MTLCommandBuffer>)commandBuffer
{
    if (!commandBuffer || ![self sourceCaptureIsEnabled]) return;
    for (uint32_t index = 0;
         index < FP_SOURCE_DRAWABLE_TICKET_CAPACITY;
         ++index)
        if (![self prepareNextSourceCaptureBeforeCommit:commandBuffer])
            break;
}

- (BOOL)prepareNextSourceCaptureBeforeCommit:
    (id<MTLCommandBuffer>)commandBuffer
{
    if (!commandBuffer || ![self sourceCaptureIsEnabled]) return NO;
    const void *commandBufferIdentity =
        (__bridge const void *)commandBuffer;
    uint64_t ticketID = 0;
    uint64_t surfaceGeneration = 0;
    NSInteger slot = FPInvalidCaptureTextureSlot;
    id<MTLTexture> sourceTexture = nil;
    id<MTLTexture> capturedTexture = nil;
    BOOL shouldScheduleCaptureRecovery = NO;

    os_unfair_lock_lock(&_stateLock);
    if ([self callbackStateIsUsableLocked])
    {
        for (uint32_t index = 0;
             index < FP_SOURCE_DRAWABLE_TICKET_CAPACITY;
             ++index)
        {
            FPFrameGenerationSourceDrawableTicket *ticket =
                &_sourceDrawableTickets[index];
            if (!ticket->ticketID || !ticket->commandBufferBound ||
                ticket->commandBufferIdentity != commandBufferIdentity ||
                ticket->commitSeen)
                continue;
            ticket->commitSeen = YES;
            ticketID = ticket->ticketID;
            surfaceGeneration = ticket->surfaceGeneration;
            sourceTexture =
                (__bridge id<MTLTexture>)ticket->sourceTextureIdentity;
            FPFrameGenerationTelemetry telemetry =
                FPFrameGenerationTelemetrySnapshot(_state);
            BOOL preactivationCurrentOwned = !telemetry.outputActive &&
                (_captureInFlight > 0 ||
                 telemetry.presentationsInFlight > 0 ||
                 telemetry.presentationReceiptsPending > 0 ||
                 _queuedPairedCurrentEpoch != 0);
            BOOL capacityAvailable =
                !preactivationCurrentOwned &&
                _captureInFlight < FP_CAPTURE_MAX_IN_FLIGHT &&
                _readyCurrentTextureCount + _captureInFlight +
                    (_queuedPairedCurrentEpoch ? 1u : 0u) <
                    FP_FRAME_GENERATION_READY_CURRENT_CAPACITY;
            if (ticket->surfaceGeneration == _surfaceGeneration &&
                capacityAvailable)
            {
                slot = [self freeCaptureSlotLocked];
                if (slot == FPInvalidCaptureTextureSlot)
                {
                    /* A ready optional pair can pin one old history texture.
                     * Evict that midpoint once, keep every Current in FIFO,
                     * and retry the fixed pool lookup exactly once. */
                    uint64_t evictedMidpointEpoch =
                        FPFrameGenerationEvictReadyMidpointForCaptureCapacity(
                            _state
                        );
                    if (evictedMidpointEpoch)
                    {
                        [self retireNativeReadyMidpointLockedForEpoch:
                            evictedMidpointEpoch];
                        slot = [self freeCaptureSlotLocked];
                    }
                }
                if (slot != FPInvalidCaptureTextureSlot)
                {
                    capturedTexture = _captureTextures[(NSUInteger)slot];
                    ticket->captureSlot = slot;
                    _captureSlotInFlight[slot] = YES;
                    ++_captureInFlight;
                    ++_nextCaptureSequence;
                    if (!_nextCaptureSequence) ++_nextCaptureSequence;
                    CFTimeInterval submittedAt = CACurrentMediaTime();
                    _captureSubmissions[slot] =
                        (FPFrameGenerationCaptureSubmission){
                            .sequence = _nextCaptureSequence,
                            .submittedAtTime = submittedAt,
                        };
                    if (_captureOutstandingStartTime <= 0.0 ||
                        submittedAt < _captureOutstandingStartTime)
                        _captureOutstandingStartTime = submittedAt;
                    if (_maximumCaptureInFlight < _captureInFlight)
                        _maximumCaptureInFlight = _captureInFlight;
                }
            }
            if (slot == FPInvalidCaptureTextureSlot)
            {
                FPFrameGenerationSourceCaptureJoinMarkUnavailable(
                    &ticket->join
                );
                if (!preactivationCurrentOwned && _captureInFlight > 0)
                {
                    shouldScheduleCaptureRecovery = [self
                        recordCaptureBusyLockedAtTime:CACurrentMediaTime()
                        telemetry:telemetry];
                }
                else
                {
                    ++_captureSkippedBusy;
                }
            }
            break;
        }
    }
    os_unfair_lock_unlock(&_stateLock);
    if (!ticketID) return NO;
    if (slot == FPInvalidCaptureTextureSlot ||
        !sourceTexture || !capturedTexture)
    {
        if (shouldScheduleCaptureRecovery)
            [self scheduleCaptureResourceRecovery];
        return YES;
    }

    BOOL validTextures = sourceTexture.device == commandBuffer.device &&
        capturedTexture.device == commandBuffer.device &&
        sourceTexture.width == capturedTexture.width &&
        sourceTexture.height == capturedTexture.height &&
        sourceTexture.pixelFormat == capturedTexture.pixelFormat;
    id<MTLBlitCommandEncoder> encoder = validTextures
        ? [commandBuffer blitCommandEncoder] : nil;
    if (!encoder)
    {
        os_unfair_lock_lock(&_stateLock);
        NSInteger ticketIndex = [self
            sourceDrawableTicketIndexLocked:ticketID];
        if (ticketIndex >= 0 &&
            _sourceDrawableTickets[ticketIndex].surfaceGeneration ==
                surfaceGeneration)
        {
            [self retireCaptureSlotLocked:slot];
            _sourceDrawableTickets[ticketIndex].captureSlot =
                FPInvalidCaptureTextureSlot;
            FPFrameGenerationSourceCaptureJoinMarkUnavailable(
                &_sourceDrawableTickets[ticketIndex].join
            );
        }
        os_unfair_lock_unlock(&_stateLock);
        [self scheduleCaptureResourceRecovery];
        return YES;
    }
    [encoder copyFromTexture:sourceTexture
                 sourceSlice:0
                 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(
                      sourceTexture.width,
                      sourceTexture.height,
                      1
                  )
                   toTexture:capturedTexture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder endEncoding];

    os_unfair_lock_lock(&_stateLock);
    NSInteger ticketIndex = [self sourceDrawableTicketIndexLocked:ticketID];
    if (ticketIndex >= 0 &&
        _sourceDrawableTickets[ticketIndex].surfaceGeneration ==
            surfaceGeneration &&
        _sourceDrawableTickets[ticketIndex].captureSlot == slot)
    {
        FPFrameGenerationSourceCaptureJoinMarkEncoded(
            &_sourceDrawableTickets[ticketIndex].join
        );
        ++_sourceCaptureEncodedOnSourceCB;
    }
    os_unfair_lock_unlock(&_stateLock);

    __weak FPD3DMetalFrameGenerationSession *weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        /* commandBufferWithUnretainedReferences does not retain encoded
         * resources. Keep ForgePlay's private destination alive explicitly
         * through this source command buffer's completion callback. */
        (void)capturedTexture;
        FPD3DMetalFrameGenerationSession *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf sourceCaptureCommandBufferCompletedForTicket:ticketID
                                                surfaceGeneration:
                                                    surfaceGeneration
                                                             slot:slot
                                                           status:
                                                               completed.status];
    }];
    return YES;
}

- (void)sourceDrawableTicket:(uint64_t)ticketID
             captureWasArmed:(BOOL)captureWasArmed
         wasPresentedAtTime:(CFTimeInterval)presentedTime
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed)) return;
    BOOL positivePresentation = isfinite(presentedTime) && presentedTime > 0.0;
    BOOL shouldBeginCapturePriming = NO;
    BOOL shouldFailBoundary = NO;
    BOOL shouldAcceptCapture = NO;
    NSInteger acceptSlot = FPInvalidCaptureTextureSlot;
    uint64_t acceptSurfaceGeneration = 0;
    uint64_t sourceSequence = 0;
    FPFrameGenerationTelemetry sourceTelemetry = {0};

    os_unfair_lock_lock(&_stateLock);
    if (![self callbackStateIsUsableLocked])
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    FPFrameGenerationSourceObservation observation = {0};
    if (positivePresentation)
        observation = FPFrameGenerationObserveSourcePresent(
            _state,
            presentedTime
        );
    shouldBeginCapturePriming = observation.shouldBeginCapturePriming;
    sourceSequence = observation.sourceSequence;
    sourceTelemetry = FPFrameGenerationTelemetrySnapshot(_state);

    NSInteger ticketIndex = [self sourceDrawableTicketIndexLocked:ticketID];
    FPFrameGenerationSourceDrawableTicket *ticket = ticketIndex >= 0
        ? &_sourceDrawableTickets[ticketIndex] : NULL;
    if (captureWasArmed && positivePresentation)
    {
        BOOL surfaceTransitionPending =
            atomic_load(&_surfaceUpdatePending) ||
            atomic_load(&_captureRecoveryPending);
        if ((!ticketID && !surfaceTransitionPending) ||
            (ticket &&
             (!ticket->commandBufferBound || !ticket->commitSeen)))
        {
            ++_sourcePresentUncovered;
            if (_consecutiveSourcePresentUncovered < UINT32_MAX)
                ++_consecutiveSourcePresentUncovered;
            shouldFailBoundary =
                _consecutiveSourcePresentUncovered >=
                    FP_SOURCE_BOUNDARY_FAILURE_PRESENTS;
        }
        else if (ticket)
        {
            _consecutiveSourcePresentUncovered = 0;
        }
        /* A nonzero missing ticket belongs to a retired surface and is a
         * stale callback, not evidence against the current hook boundary. */
    }
    if (ticket)
    {
        if (!ticket->commandBufferBound || !ticket->commitSeen)
        {
            memset(ticket, 0, sizeof(*ticket));
        }
        else
        {
            FPFrameGenerationSourceCaptureJoinDisposition disposition =
                FPFrameGenerationSourceCaptureJoinRecordPresented(
                    &ticket->join,
                    observation.accepted ? sourceSequence : 0,
                    positivePresentation ? presentedTime : 0.0
                );
            if (disposition == FPFrameGenerationSourceCaptureJoinAccept)
            {
                shouldAcceptCapture = YES;
                acceptSlot = ticket->captureSlot;
                acceptSurfaceGeneration = ticket->surfaceGeneration;
                ++_sourceCaptureJoined;
                memset(ticket, 0, sizeof(*ticket));
            }
            else if (disposition == FPFrameGenerationSourceCaptureJoinRetire)
            {
                if (ticket->captureSlot != FPInvalidCaptureTextureSlot)
                    [self retireCaptureSlotLocked:ticket->captureSlot];
                memset(ticket, 0, sizeof(*ticket));
            }
        }
    }
    os_unfair_lock_unlock(&_stateLock);

    if (shouldFailBoundary)
    {
        [self failWithReason:"source-present-boundary-unavailable"];
        return;
    }
    if (shouldBeginCapturePriming)
        [self scheduleCapturePrimingOutputSurface];
    if (shouldAcceptCapture)
        [self acceptCapturedSlot:acceptSlot
                  sourceSequence:sourceSequence
                   presentedTime:presentedTime
                surfaceGeneration:acceptSurfaceGeneration];
    [self updateFrameCheckWithTelemetry:sourceTelemetry];
    [self emitTelemetryForced:shouldBeginCapturePriming];
}

- (void)sourceCaptureCommandBufferCompletedForTicket:(uint64_t)ticketID
                                    surfaceGeneration:
                                        (uint64_t)surfaceGeneration
                                                 slot:(NSInteger)slot
                                               status:(MTLCommandBufferStatus)status
{
    if (!ticketID) return;
    BOOL shouldAcceptCapture = NO;
    uint64_t sourceSequence = 0;
    CFTimeInterval presentedTime = 0.0;
    os_unfair_lock_lock(&_stateLock);
    NSInteger ticketIndex = [self sourceDrawableTicketIndexLocked:ticketID];
    BOOL matchedTicket = NO;
    if ([self callbackStateIsUsableLocked] && ticketIndex >= 0)
    {
        FPFrameGenerationSourceDrawableTicket *ticket =
            &_sourceDrawableTickets[ticketIndex];
        if (ticket->surfaceGeneration == surfaceGeneration &&
            ticket->captureSlot == slot && ticket->join.captureEncoded)
        {
            matchedTicket = YES;
            BOOL succeeded = status == MTLCommandBufferStatusCompleted;
            FPFrameGenerationSourceCaptureJoinDisposition disposition =
                FPFrameGenerationSourceCaptureJoinRecordCompleted(
                    &ticket->join,
                    succeeded
                );
            if (!succeeded)
            {
                [self retireCaptureCompletionLockedForSlot:slot
                                         surfaceGeneration:surfaceGeneration];
                ticket->captureSlot = FPInvalidCaptureTextureSlot;
            }
            if (disposition == FPFrameGenerationSourceCaptureJoinAccept)
            {
                shouldAcceptCapture = YES;
                sourceSequence = ticket->join.sourceSequence;
                presentedTime = ticket->join.presentedTime;
                ++_sourceCaptureJoined;
                memset(ticket, 0, sizeof(*ticket));
            }
            else if (disposition == FPFrameGenerationSourceCaptureJoinRetire)
            {
                if (ticket->captureSlot != FPInvalidCaptureTextureSlot)
                    [self retireCaptureSlotLocked:ticket->captureSlot];
                memset(ticket, 0, sizeof(*ticket));
            }
        }
    }
    if (!matchedTicket)
        (void)[self retireCaptureCompletionLockedForSlot:slot
                                      surfaceGeneration:surfaceGeneration];
    os_unfair_lock_unlock(&_stateLock);
    if (shouldAcceptCapture)
        [self acceptCapturedSlot:slot
                  sourceSequence:sourceSequence
                   presentedTime:presentedTime
                surfaceGeneration:surfaceGeneration];
    [self emitTelemetryForced:NO];
}

- (void)retireNativePreactivationSeedLockedForEpoch:(uint64_t)epoch
{
    if (!epoch) return;
    NSInteger slot = [self takeReadyCurrentSlotLockedForEpoch:epoch];
    if (_readyPairEpoch == epoch)
    {
        _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
        _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
        _readyPairEpoch = 0;
    }
    if (_queuedPairedCurrentEpoch == epoch)
    {
        _queuedPairedCurrentSlot = FPInvalidCaptureTextureSlot;
        _queuedPairedCurrentEpoch = 0;
    }
    if (_historySlot == slot)
        _historySlot = FPInvalidCaptureTextureSlot;
}

- (void)retireNativeReadyMidpointLockedForEpoch:(uint64_t)epoch
{
    if (!epoch || _readyPairEpoch != epoch) return;
    _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
    _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
    _readyPairEpoch = 0;
}

- (void)acceptCapturedSlot:(NSInteger)slot
             sourceSequence:(uint64_t)sourceSequence
             presentedTime:(CFTimeInterval)presentedTime
          surfaceGeneration:(uint64_t)surfaceGeneration
{
    FPFrameGenerationCapturePlan plan;
    FPFrameGenerationTelemetry enqueueTelemetry = {0};
    NSInteger previousSlot;
    BOOL currentQueued = NO;
    BOOL captureAdmissionInvariantFailed = NO;

    os_unfair_lock_lock(&_stateLock);
    if (![self
            retireCaptureCompletionLockedForSlot:slot
            surfaceGeneration:surfaceGeneration])
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    if (![self callbackStateIsUsableLocked] ||
        ![self sourceCaptureIsEnabled])
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    uint64_t supersededSeedEpoch =
        FPFrameGenerationDiscardStalePreactivationSeed(_state);
    [self retireNativePreactivationSeedLockedForEpoch:supersededSeedEpoch];
    plan = FPFrameGenerationRecordCaptureReady(
        _state,
        sourceSequence,
        presentedTime
    );
    if (!plan.accepted)
    {
        enqueueTelemetry = FPFrameGenerationTelemetrySnapshot(_state);
        os_unfair_lock_unlock(&_stateLock);
        [self updateFrameCheckWithTelemetry:enqueueTelemetry];
        [self scheduleDisplayLinkResume];
        [self emitTelemetryForced:NO];
        return;
    }
    previousSlot = _historySlot;
    if (plan.shouldGenerateMidpoint &&
        previousSlot == FPInvalidCaptureTextureSlot)
    {
        (void)FPFrameGenerationCancelAcceptedCapture(_state, plan.epoch);
        captureAdmissionInvariantFailed = YES;
    }
    else
    {
        currentQueued = [self enqueueReadyCurrentSlotLocked:slot
                                                      epoch:plan.epoch];
        if (currentQueued)
        {
            currentQueued = plan.shouldGenerateMidpoint
                ? FPFrameGenerationRecordGeneratedPairReady(
                    _state,
                    plan.epoch
                )
                : FPFrameGenerationRecordCurrentReady(
                    _state,
                    plan.epoch,
                    presentedTime
                );
        }
        if (!currentQueued)
        {
            (void)[self takeReadyCurrentSlotLockedForEpoch:plan.epoch];
            (void)FPFrameGenerationCancelAcceptedCapture(_state, plan.epoch);
            captureAdmissionInvariantFailed = YES;
        }
        else
        {
            _historySlot = slot;
            _captureRecoveryAwaitingProgress = NO;
            if (plan.shouldGenerateMidpoint)
            {
                _readyPairPreviousSlot = previousSlot;
                _readyPairCurrentSlot = slot;
                _readyPairEpoch = plan.epoch;
            }
        }
    }
    if (!currentQueued)
        enqueueTelemetry = FPFrameGenerationTelemetrySnapshot(_state);
    os_unfair_lock_unlock(&_stateLock);
    if (!currentQueued)
    {
        [self updateFrameCheckWithTelemetry:enqueueTelemetry];
        [self emitTelemetryForced:NO];
        if (captureAdmissionInvariantFailed)
            [self scheduleCaptureResourceRecovery];
        [self scheduleDisplayLinkResume];
        return;
    }
    [self scheduleDisplayLinkResume];
    [self emitTelemetryForced:NO];
}

- (NSInteger)freeTextureSubmissionIndexLocked
{
    for (NSInteger index = 0;
         index < FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT;
         ++index)
        if (!_textureSubmissions[index].candidate.submissionID) return index;
    return -1;
}

- (NSInteger)freePresentationReceiptIndexLocked
{
    for (NSInteger index = 0;
         index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
         ++index)
        if (!_presentationReceipts[index].candidate.submissionID) return index;
    return -1;
}

- (NSInteger)presentationReceiptIndexLockedForCandidate:
    (FPFrameGenerationDisplayCandidate)candidate
                                     surfaceGeneration:
                                         (uint64_t)surfaceGeneration
{
    if (!candidate.submissionID || !surfaceGeneration) return -1;
    for (NSInteger index = 0;
         index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
         ++index)
    {
        FPFrameGenerationPresentationReceipt receipt =
            _presentationReceipts[index];
        if (receipt.surfaceGeneration == surfaceGeneration &&
            FPDisplayCandidateIdentityMatches(receipt.candidate, candidate))
            return index;
    }
    return -1;
}

- (void)refreshPresentationStallChecksLocked
{
    _presentationStallChecks = 0;
    for (NSInteger index = 0;
         index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
         ++index)
    {
        FPFrameGenerationPresentationReceipt receipt =
            _presentationReceipts[index];
        if (!receipt.candidate.submissionID ||
            receipt.surfaceGeneration != _surfaceGeneration)
            continue;
        _presentationStallChecks = MAX(
            _presentationStallChecks,
            receipt.presentationStallChecks
        );
    }
}

- (BOOL)removeTextureSubmissionLockedForCandidate:
    (FPFrameGenerationDisplayCandidate)candidate
                                        surfaceGeneration:
                                            (uint64_t)surfaceGeneration
{
    if (!candidate.submissionID || !surfaceGeneration) return NO;
    for (NSInteger index = 0;
         index < FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT;
         ++index)
    {
        FPFrameGenerationTextureSubmission submission =
            _textureSubmissions[index];
        if (submission.surfaceGeneration != surfaceGeneration ||
            !FPDisplayCandidateIdentityMatches(submission.candidate, candidate))
            continue;
        BOOL belongsToCurrentSurface =
            submission.surfaceGeneration == _surfaceGeneration;
        memset(&_textureSubmissions[index], 0, sizeof(_textureSubmissions[index]));
        return belongsToCurrentSurface;
    }
    return NO;
}

- (BOOL)removePresentationReceiptLockedForCandidate:
    (FPFrameGenerationDisplayCandidate)candidate
                                          surfaceGeneration:
                                              (uint64_t)surfaceGeneration
{
    NSInteger index = [self presentationReceiptIndexLockedForCandidate:candidate
                                                     surfaceGeneration:
                                                         surfaceGeneration];
    if (index < 0) return NO;
    BOOL belongsToCurrentSurface =
        _presentationReceipts[index].surfaceGeneration == _surfaceGeneration;
    memset(
        &_presentationReceipts[index],
        0,
        sizeof(_presentationReceipts[index])
    );
    [self refreshPresentationStallChecksLocked];
    return belongsToCurrentSurface;
}

- (BOOL)owningWindowIsActiveAndVisible
{
    __block BOOL activeAndVisible = NO;
    dispatch_block_t inspect = ^{
        NSWindow *window = self->_owningMetalView.window;
        activeAndVisible = NSApp.isActive && window.isVisible &&
            (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    };
    if (NSThread.isMainThread)
        inspect();
    else
        dispatch_sync(dispatch_get_main_queue(), inspect);
    return activeAndVisible;
}

- (void)schedulePresentationWatchdog
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed) ||
        ![self sourceCaptureIsEnabled] ||
        atomic_exchange(&_presentationWatchdogPending, true))
        return;

    CFTimeInterval earliestSubmissionTime = 0.0;
    CFTimeInterval slotDuration = 0.0;
    os_unfair_lock_lock(&_stateLock);
    if ([self callbackStateIsUsableLocked])
    {
        slotDuration = FPFrameGenerationEffectiveDisplaySlotDuration(_state);
        for (NSInteger index = 0;
             index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
             ++index)
        {
            FPFrameGenerationPresentationReceipt receipt =
                _presentationReceipts[index];
            if (!receipt.candidate.submissionID ||
                receipt.surfaceGeneration != _surfaceGeneration ||
                !isfinite(receipt.submittedAtTime) ||
                receipt.submittedAtTime <= 0.0)
                continue;
            if (earliestSubmissionTime <= 0.0 ||
                receipt.submittedAtTime < earliestSubmissionTime)
                earliestSubmissionTime = receipt.submittedAtTime;
        }
    }
    os_unfair_lock_unlock(&_stateLock);
    if (earliestSubmissionTime <= 0.0 || !isfinite(slotDuration) ||
        slotDuration <= 0.0)
    {
        atomic_store(&_presentationWatchdogPending, false);
        /* Close the only lost-wakeup window: a submission may have arrived
         * after the empty scan while the pending gate was still true. */
        BOOL submissionArrived = NO;
        os_unfair_lock_lock(&_stateLock);
        if ([self callbackStateIsUsableLocked])
        {
            for (NSInteger index = 0;
                 index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
                 ++index)
            {
                FPFrameGenerationPresentationReceipt receipt =
                    _presentationReceipts[index];
                if (receipt.candidate.submissionID &&
                    receipt.surfaceGeneration == _surfaceGeneration &&
                    receipt.submittedAtTime > 0.0)
                {
                    submissionArrived = YES;
                    break;
                }
            }
        }
        os_unfair_lock_unlock(&_stateLock);
        if (submissionArrived) [self schedulePresentationWatchdog];
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval watchdogPeriod =
        FPPresentationWatchdogSlotMultiplier * slotDuration;
    CFTimeInterval maturityTime = earliestSubmissionTime + watchdogPeriod;
    CFTimeInterval delay = fmax(maturityTime - now, watchdogPeriod);
    int64_t delayNanoseconds = (int64_t)llround(
        delay * (double)NSEC_PER_SEC
    );
    if (delayNanoseconds <= 0) delayNanoseconds = 1;
    __weak FPD3DMetalFrameGenerationSession *weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            FPD3DMetalFrameGenerationSession *strongSelf = weakSelf;
            if (!strongSelf || atomic_load(&strongSelf->_invalidated) ||
                atomic_load(&strongSelf->_failed) ||
                ![strongSelf sourceCaptureIsEnabled])
            {
                if (strongSelf)
                    atomic_store(
                        &strongSelf->_presentationWatchdogPending,
                        false
                    );
                return;
            }

            CFTimeInterval checkTime = CACurrentMediaTime();
            BOOL hasMatureSubmission = NO;
            os_unfair_lock_lock(&strongSelf->_stateLock);
            if ([strongSelf callbackStateIsUsableLocked])
            {
                CFTimeInterval currentSlot =
                    FPFrameGenerationEffectiveDisplaySlotDuration(
                        strongSelf->_state
                    );
                CFTimeInterval maturityBudget =
                    FPPresentationWatchdogSlotMultiplier * currentSlot;
                for (NSInteger index = 0;
                     index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
                     ++index)
                {
                    FPFrameGenerationPresentationReceipt receipt =
                        strongSelf->_presentationReceipts[index];
                    if (!receipt.candidate.submissionID ||
                        receipt.surfaceGeneration !=
                            strongSelf->_surfaceGeneration ||
                        !isfinite(receipt.submittedAtTime) ||
                        receipt.submittedAtTime <= 0.0)
                        continue;
                    if (checkTime - receipt.submittedAtTime >=
                        maturityBudget)
                    {
                        hasMatureSubmission = YES;
                        break;
                    }
                }
            }
            os_unfair_lock_unlock(&strongSelf->_stateLock);

            /* Completed entries leave the ledger before reaching this point.
             * AppKit visibility is consulted only for an actually overdue
             * drawable, never once per successfully displayed frame. */
            BOOL surfaceLifecycleChanging =
                atomic_load(&strongSelf->_surfaceUpdatePending) ||
                atomic_load(&strongSelf->_captureRecoveryPending);
            BOOL activeAndVisible = surfaceLifecycleChanging ||
                !hasMatureSubmission ||
                [strongSelf owningWindowIsActiveAndVisible];
            BOOL shouldFail = NO;
            BOOL midpointCommandStalled = NO;
            BOOL currentWriterStalled = NO;
            BOOL droppedStalledMidpoint = NO;
            FPFrameGenerationTelemetry watchdogTelemetry = {0};
            os_unfair_lock_lock(&strongSelf->_stateLock);
            if ([strongSelf callbackStateIsUsableLocked])
            {
                CFTimeInterval currentSlot =
                    FPFrameGenerationEffectiveDisplaySlotDuration(
                        strongSelf->_state
                    );
                CFTimeInterval maturityBudget =
                    FPPresentationWatchdogSlotMultiplier * currentSlot;
                for (NSInteger index = 0;
                     index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY;
                     ++index)
                {
                    FPFrameGenerationPresentationReceipt *receipt =
                        &strongSelf->_presentationReceipts[index];
                    if (!receipt->candidate.submissionID ||
                        receipt->surfaceGeneration !=
                            strongSelf->_surfaceGeneration ||
                        !isfinite(receipt->submittedAtTime) ||
                        receipt->submittedAtTime <= 0.0 ||
                        checkTime - receipt->submittedAtTime <
                            maturityBudget)
                        continue;
                    if (surfaceLifecycleChanging || !activeAndVisible)
                    {
                        receipt->presentationStallChecks = 0;
                    }
                    else if (receipt->presentationStallChecks < UINT32_MAX)
                    {
                        ++receipt->presentationStallChecks;
                        if (receipt->presentationStallChecks >=
                            FP_PRESENTATION_STALL_FAILURE_CHECKS)
                        {
                            if (!receipt->writerCompleted)
                            {
                                midpointCommandStalled =
                                    receipt->candidate.kind ==
                                        FPFrameGenerationOutputMidpoint;
                                currentWriterStalled =
                                    receipt->candidate.kind ==
                                        FPFrameGenerationOutputCurrent;
                                shouldFail = YES;
                            }
                            else if (!receipt->presentationSeen &&
                                     receipt->candidate.kind ==
                                         FPFrameGenerationOutputCurrent)
                            {
                                shouldFail = YES;
                            }
                            else if (!receipt->presentationSeen &&
                                     receipt->candidate.kind ==
                                         FPFrameGenerationOutputMidpoint &&
                                     FPFrameGenerationDropStalledMidpoint(
                                         strongSelf->_state,
                                         receipt->candidate
                                     ))
                            {
                                memset(receipt, 0, sizeof(*receipt));
                                droppedStalledMidpoint = YES;
                            }
                        }
                    }
                }
                [strongSelf refreshPresentationStallChecksLocked];
                if (droppedStalledMidpoint)
                    watchdogTelemetry = FPFrameGenerationTelemetrySnapshot(
                        strongSelf->_state
                    );
            }
            os_unfair_lock_unlock(&strongSelf->_stateLock);
            atomic_store(&strongSelf->_presentationWatchdogPending, false);
            if (shouldFail)
            {
                [strongSelf failWithReason:
                    midpointCommandStalled
                        ? "midpoint-command-stalled"
                        : (currentWriterStalled
                            ? "current-output-writer-stalled"
                            : "presentation-stalled")];
                return;
            }
            if (droppedStalledMidpoint)
            {
                [strongSelf scheduleDisplayLinkResume];
                [strongSelf updateFrameCheckWithTelemetry:watchdogTelemetry];
                [strongSelf emitTelemetryForced:NO];
            }
            /* Closing the pending gate before rearming lets a concurrent new
             * submission win; either caller then owns the one session timer. */
            [strongSelf schedulePresentationWatchdog];
        }
    );
}

- (void)scheduleDisplayLinkRebaseAfterLateUpdate:
    (CAMetalDisplayLink *)displayLink
{
    if (!displayLink || atomic_load(&_invalidated) || atomic_load(&_failed) ||
        ![self sourceCaptureIsEnabled] ||
        atomic_exchange(&_displayLinkResumePending, true))
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load(&self->_invalidated) || atomic_load(&self->_failed) ||
            ![self sourceCaptureIsEnabled] ||
            self->_displayLink != displayLink)
        {
            atomic_store(&self->_displayLinkResumePending, false);
            [self scheduleDisplayLinkResume];
            return;
        }
        /* Restart the same output-owned link once so a queued mandatory current
         * receives a fresh callback deadline. This is a timing rebase, not a
         * source handback, retry timer, or output-surface replacement. */
        displayLink.paused = YES;
        atomic_store(&self->_displayLinkPausedForWork, true);
        os_unfair_lock_lock(&self->_stateLock);
        if ([self callbackStateIsUsableLocked])
        {
            FPFrameGenerationRebaseDisplayTargetObservation(self->_state);
            self->_consecutiveEmptyDisplayUpdates = 0;
            ++self->_displayResumeCount;
        }
        os_unfair_lock_unlock(&self->_stateLock);
        atomic_store(&self->_displayLinkPausedForWork, false);
        displayLink.paused = NO;
        atomic_store(&self->_displayLinkResumePending, false);
    });
}

- (void)scheduleDisplayLinkResume
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed) ||
        ![self sourceCaptureIsEnabled]) return;
    if (!atomic_load(&_displayLinkPausedForWork)) return;
    if (atomic_exchange(&_displayLinkResumePending, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&self->_displayLinkResumePending, false);
        if (atomic_load(&self->_invalidated) || atomic_load(&self->_failed) ||
            ![self sourceCaptureIsEnabled] || !self->_displayLink)
            return;
        if (!atomic_exchange(&self->_displayLinkPausedForWork, false)) return;
        os_unfair_lock_lock(&self->_stateLock);
        if ([self callbackStateIsUsableLocked])
        {
            FPFrameGenerationRebaseDisplayTargetObservation(self->_state);
            self->_consecutiveEmptyDisplayUpdates = 0;
            ++self->_displayResumeCount;
        }
        os_unfair_lock_unlock(&self->_stateLock);
        self->_displayLink.paused = NO;
    });
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link
             needsUpdate:(CAMetalDisplayLinkUpdate *)update
{
    FPFrameGenerationDisplayCandidate candidate = {0};
    id<MTLTexture> previousTexture = nil;
    id<MTLTexture> currentTexture = nil;
    id<MTLRenderPipelineState> pipeline = nil;
    id<MTLCommandQueue> displayQueue = nil;
    NSInteger previousSlot = FPInvalidCaptureTextureSlot;
    NSInteger currentSlot = FPInvalidCaptureTextureSlot;
    NSInteger submissionIndex = -1;
    NSInteger receiptIndex = -1;
    uint64_t surfaceGeneration = 0;
    id<CAMetalDrawable> drawable = update.drawable;
    id<MTLTexture> destination = drawable.texture;

    if (!link || link != _displayLink || atomic_load(&_invalidated) ||
        atomic_load(&_failed) ||
        ![self sourceCaptureIsEnabled]) return;
    os_unfair_lock_lock(&_stateLock);
    if (![self callbackStateIsUsableLocked])
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    /* CAMetalDisplayLink requires present() before targetTimestamp.  Do not pop
     * an ordered current from the queue when this callback is already late;
     * the same current remains first for the next valid display update. */
    CFTimeInterval callbackDeadline = update.targetTimestamp;
    if (isfinite(callbackDeadline) && callbackDeadline > 0.0 &&
        CACurrentMediaTime() >= callbackDeadline)
    {
        uint64_t discardedMidpointEpoch =
            FPFrameGenerationHandleLateDisplayUpdate(_state);
        if (discardedMidpointEpoch &&
            _readyPairEpoch == discardedMidpointEpoch)
        {
            _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
            _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
            _readyPairEpoch = 0;
        }
        os_unfair_lock_unlock(&_stateLock);
        [self scheduleDisplayLinkRebaseAfterLateUpdate:link];
        [self emitTelemetryForced:NO];
        return;
    }
    FPFrameGenerationRecordDisplayUpdate(
        _state,
        update.targetPresentationTimestamp
    );
    if (!drawable || !destination)
    {
        FPFrameGenerationTelemetry drawableTelemetry =
            FPFrameGenerationTelemetrySnapshot(_state);
        if (_consecutiveEmptyDisplayUpdates < UINT32_MAX)
            ++_consecutiveEmptyDisplayUpdates;
        os_unfair_lock_unlock(&_stateLock);
        [self updateFrameCheckWithTelemetry:drawableTelemetry];
        [self emitTelemetryForced:NO];
        return;
    }
    submissionIndex = [self freeTextureSubmissionIndexLocked];
    receiptIndex = [self freePresentationReceiptIndexLocked];
    if (submissionIndex < 0 || receiptIndex < 0)
    {
        os_unfair_lock_unlock(&_stateLock);
        [self schedulePresentationWatchdog];
        [self emitTelemetryForced:NO];
        return;
    }
    candidate = FPFrameGenerationAcquireDisplayCandidate(_state);
    if (candidate.kind == FPFrameGenerationOutputNone)
    {
        FPFrameGenerationTelemetry waitingTelemetry =
            FPFrameGenerationTelemetrySnapshot(_state);
        if (_readyPairEpoch &&
            waitingTelemetry.readyMidpointSourceTime <= 0.0)
        {
            _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
            _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
            _readyPairEpoch = 0;
        }
        if (_consecutiveEmptyDisplayUpdates < UINT32_MAX)
            ++_consecutiveEmptyDisplayUpdates;
        os_unfair_lock_unlock(&_stateLock);
        [self updateFrameCheckWithTelemetry:waitingTelemetry];
        [self emitTelemetryForced:NO];
        return;
    }
    _consecutiveEmptyDisplayUpdates = 0;

    if (_readyPairEpoch &&
        !(candidate.kind == FPFrameGenerationOutputMidpoint &&
          candidate.epoch == _readyPairEpoch))
    {
        /* An older FIFO Current may drain before the singleton optional pair.
         * Keep its texture mapping until the C owner actually retires it. */
        FPFrameGenerationTelemetry acquiredTelemetry =
            FPFrameGenerationTelemetrySnapshot(_state);
        if (acquiredTelemetry.readyMidpointSourceTime <= 0.0)
            [self retireNativeReadyMidpointLockedForEpoch:_readyPairEpoch];
    }
    if (candidate.kind == FPFrameGenerationOutputMidpoint &&
        candidate.epoch == _readyPairEpoch)
    {
        previousSlot = _readyPairPreviousSlot;
        currentSlot = [self takeReadyCurrentSlotLockedForEpoch:candidate.epoch];
        if (currentSlot != _readyPairCurrentSlot)
            currentSlot = FPInvalidCaptureTextureSlot;
        _queuedPairedCurrentSlot = currentSlot;
        _queuedPairedCurrentEpoch = candidate.epoch;
        _readyPairPreviousSlot = FPInvalidCaptureTextureSlot;
        _readyPairCurrentSlot = FPInvalidCaptureTextureSlot;
        _readyPairEpoch = 0;
    }
    else if (candidate.kind == FPFrameGenerationOutputCurrent &&
             candidate.pairedCurrent &&
             candidate.epoch == _queuedPairedCurrentEpoch)
    {
        currentSlot = _queuedPairedCurrentSlot;
        previousSlot = currentSlot;
        _queuedPairedCurrentSlot = FPInvalidCaptureTextureSlot;
        _queuedPairedCurrentEpoch = 0;
    }
    else if (candidate.kind == FPFrameGenerationOutputCurrent)
    {
        currentSlot = [self takeReadyCurrentSlotLockedForEpoch:candidate.epoch];
        previousSlot = currentSlot;
    }

    if (previousSlot >= 0 && currentSlot >= 0 &&
        previousSlot < (NSInteger)_captureTextures.count &&
        currentSlot < (NSInteger)_captureTextures.count)
    {
        previousTexture = _captureTextures[(NSUInteger)previousSlot];
        currentTexture = _captureTextures[(NSUInteger)currentSlot];
    }
    displayQueue = _displayQueue;
    surfaceGeneration = _surfaceGeneration;
    BOOL currentPathAvailable = currentTexture != nil &&
        _currentPipeline != nil && displayQueue != nil;
    BOOL midpointPathAvailable = currentPathAvailable &&
        previousTexture != nil && _midpointPipeline != nil;
    if ((candidate.kind == FPFrameGenerationOutputMidpoint &&
         !midpointPathAvailable) ||
        (candidate.kind == FPFrameGenerationOutputCurrent &&
         !currentPathAvailable))
    {
        BOOL optionalMidpointFailure =
            candidate.kind == FPFrameGenerationOutputMidpoint &&
            currentPathAvailable;
        if (candidate.kind == FPFrameGenerationOutputMidpoint)
            FPFrameGenerationRecordGeneratedFailed(_state, candidate.epoch);
        FPFrameGenerationRecordPresentationSkipped(_state, candidate);
        os_unfair_lock_unlock(&_stateLock);
        [self scheduleDisplayLinkResume];
        if (!optionalMidpointFailure)
            [self failWithReason:"current-output-mapping-unavailable"];
        else
            [self emitTelemetryForced:NO];
        return;
    }
    pipeline = candidate.kind == FPFrameGenerationOutputMidpoint
        ? _midpointPipeline : _currentPipeline;
    _textureSubmissions[submissionIndex] =
        (FPFrameGenerationTextureSubmission){
            .candidate = candidate,
            .surfaceGeneration = surfaceGeneration,
            .previousSlot = previousSlot,
            .currentSlot = currentSlot,
        };
    _presentationReceipts[receiptIndex] =
        (FPFrameGenerationPresentationReceipt){
            .candidate = candidate,
            .surfaceGeneration = surfaceGeneration,
        };
    os_unfair_lock_unlock(&_stateLock);

    if (
        previousTexture.device != displayQueue.device ||
        currentTexture.device != displayQueue.device ||
        destination.device != displayQueue.device ||
        previousTexture.width != destination.width ||
        previousTexture.height != destination.height ||
        previousTexture.pixelFormat != destination.pixelFormat ||
        currentTexture.width != destination.width ||
        currentTexture.height != destination.height ||
        currentTexture.pixelFormat != destination.pixelFormat)
    {
        BOOL belongsToCurrentSurface = NO;
        os_unfair_lock_lock(&_stateLock);
        belongsToCurrentSurface =
            [self removeTextureSubmissionLockedForCandidate:candidate
                                           surfaceGeneration:
                                               surfaceGeneration];
        (void)[self removePresentationReceiptLockedForCandidate:candidate
                                              surfaceGeneration:
                                                  surfaceGeneration];
        if (belongsToCurrentSurface && [self callbackStateIsUsableLocked])
        {
            if (candidate.kind == FPFrameGenerationOutputMidpoint)
                FPFrameGenerationRecordGeneratedFailed(
                    _state,
                    candidate.epoch
                );
            FPFrameGenerationRecordPresentationSkipped(_state, candidate);
        }
        os_unfair_lock_unlock(&_stateLock);
        [self scheduleDisplayLinkResume];
        if (belongsToCurrentSurface &&
            candidate.kind == FPFrameGenerationOutputCurrent)
            [self sourceSurfaceConfigurationDidChange];
        else if (belongsToCurrentSurface)
            [self emitTelemetryForced:NO];
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [displayQueue commandBuffer];
    MTLRenderPassDescriptor *renderPass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    renderPass.colorAttachments[0].texture = destination;
    renderPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    if (!commandBuffer || !encoder)
    {
        BOOL belongsToCurrentSurface = NO;
        os_unfair_lock_lock(&_stateLock);
        belongsToCurrentSurface =
            [self removeTextureSubmissionLockedForCandidate:candidate
                                           surfaceGeneration:
                                               surfaceGeneration];
        (void)[self removePresentationReceiptLockedForCandidate:candidate
                                              surfaceGeneration:
                                                  surfaceGeneration];
        if (belongsToCurrentSurface && [self callbackStateIsUsableLocked])
        {
            if (candidate.kind == FPFrameGenerationOutputMidpoint)
                FPFrameGenerationRecordGeneratedFailed(
                    _state,
                    candidate.epoch
                );
            FPFrameGenerationRecordPresentationSkipped(_state, candidate);
        }
        os_unfair_lock_unlock(&_stateLock);
        [self scheduleDisplayLinkResume];
        if (belongsToCurrentSurface &&
            candidate.kind == FPFrameGenerationOutputCurrent)
            [self failWithReason:"current-output-writer-unavailable"];
        else if (belongsToCurrentSurface)
            [self emitTelemetryForced:NO];
        return;
    }
    [encoder setRenderPipelineState:pipeline];
    if (candidate.kind == FPFrameGenerationOutputMidpoint)
    {
        [encoder setFragmentTexture:previousTexture atIndex:0];
        [encoder setFragmentTexture:currentTexture atIndex:1];
    }
    else
    {
        [encoder setFragmentTexture:currentTexture atIndex:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    [encoder endEncoding];

    /* The single ordered _displayQueue is the midpoint -> matching-current
     * ordering authority. Three writer entries own capture textures only until
     * GPU completion. Six fixed metadata receipts independently await actual
     * WindowServer presentation, so that delayed presented callbacks cannot
     * throttle otherwise-complete Current replay or retain full-size textures. */

    if (candidate.kind == FPFrameGenerationOutputMidpoint)
    {
        os_unfair_lock_lock(&_stateLock);
        if ([self callbackStateIsUsableLocked])
            FPFrameGenerationRecordGeneratedSubmitted(_state, candidate.epoch);
        os_unfair_lock_unlock(&_stateLock);
    }

    __weak FPD3DMetalFrameGenerationSession *weakSelf = self;
    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
        FPD3DMetalFrameGenerationSession *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf sourceCaptureIsEnabled]) return;
        CFTimeInterval positivePresentedTime = presentedDrawable.presentedTime;
        FPFrameGenerationTelemetry beforePresentation = {0};
        FPFrameGenerationTelemetry telemetry = {0};
        BOOL reachedDiagnosticMilestone = NO;
        os_unfair_lock_lock(&strongSelf->_stateLock);
        if (![strongSelf callbackStateIsUsableLocked])
        {
            os_unfair_lock_unlock(&strongSelf->_stateLock);
            return;
        }
        NSInteger receiptIndex = [strongSelf
            presentationReceiptIndexLockedForCandidate:candidate
            surfaceGeneration:surfaceGeneration];
        if (receiptIndex < 0)
        {
            os_unfair_lock_unlock(&strongSelf->_stateLock);
            return;
        }
        FPFrameGenerationPresentationReceipt *receipt =
            &strongSelf->_presentationReceipts[receiptIndex];
        beforePresentation =
            FPFrameGenerationTelemetrySnapshot(strongSelf->_state);
        FPFrameGenerationOutputCallbackResult result =
            FPFrameGenerationRecordPresentationReceipt(
                strongSelf->_state,
                candidate,
                positivePresentedTime
            );
        if (result.duplicate || !result.matched)
        {
            os_unfair_lock_unlock(&strongSelf->_stateLock);
            return;
        }
        receipt->presentationSeen = YES;
        if (result.joinRetired)
            (void)[strongSelf removePresentationReceiptLockedForCandidate:
                candidate
                surfaceGeneration:surfaceGeneration];
        telemetry = FPFrameGenerationTelemetrySnapshot(strongSelf->_state);
        CFTimeInterval progressNow = CACurrentMediaTime();
        if (result.positivePresentationRecorded)
            strongSelf->_lastOutputProgressTime = progressNow;
        reachedDiagnosticMilestone =
            (!beforePresentation.outputActive && telemetry.outputActive) ||
            (beforePresentation.midpointPresented == 0 &&
             telemetry.midpointPresented > 0);
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        [strongSelf scheduleDisplayLinkResume];
        [strongSelf updateFrameCheckWithTelemetry:telemetry];
        if (telemetry.outputActive)
            [strongSelf retireHeldOutputAfterActivation];
        [strongSelf emitTelemetryForced:reachedDiagnosticMilestone];
    }];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        FPD3DMetalFrameGenerationSession *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf sourceCaptureIsEnabled]) return;
        BOOL succeeded = completed.status == MTLCommandBufferStatusCompleted;
        BOOL shouldFailCurrentWriter = NO;
        BOOL matched = NO;
        os_unfair_lock_lock(&strongSelf->_stateLock);
        if ([strongSelf callbackStateIsUsableLocked])
        {
            FPFrameGenerationOutputCallbackResult result =
                FPFrameGenerationRecordWriterCompleted(
                    strongSelf->_state,
                    candidate,
                    succeeded
                );
            if (result.matched && result.writerRetired)
            {
                NSInteger receiptIndex = [strongSelf
                    presentationReceiptIndexLockedForCandidate:candidate
                    surfaceGeneration:surfaceGeneration];
                matched = [strongSelf
                    removeTextureSubmissionLockedForCandidate:candidate
                    surfaceGeneration:surfaceGeneration];
                if (receiptIndex >= 0)
                {
                    strongSelf->_presentationReceipts[receiptIndex].writerCompleted =
                        YES;
                    if (result.joinRetired)
                        (void)[strongSelf
                            removePresentationReceiptLockedForCandidate:
                                candidate
                            surfaceGeneration:surfaceGeneration];
                }
            }
            shouldFailCurrentWriter = matched && !succeeded &&
                candidate.kind == FPFrameGenerationOutputCurrent;
        }
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        if (!matched) return;
        [strongSelf scheduleDisplayLinkResume];
        if (shouldFailCurrentWriter)
        {
            [strongSelf failWithReason:"current-output-writer-failed"];
            return;
        }
        if (candidate.kind == FPFrameGenerationOutputMidpoint)
            [strongSelf emitTelemetryForced:NO];
    }];

    os_unfair_lock_lock(&_stateLock);
    CFTimeInterval submittedAtTime = CACurrentMediaTime();
    for (NSInteger index = 0;
         index < FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT;
         ++index)
    {
        FPFrameGenerationTextureSubmission *submission =
            &_textureSubmissions[index];
        if (!FPDisplayCandidateIdentityMatches(submission->candidate, candidate) ||
            submission->surfaceGeneration != surfaceGeneration)
            continue;
        submission->submittedAtTime = submittedAtTime;
        break;
    }
    NSInteger submittedReceiptIndex = [self
        presentationReceiptIndexLockedForCandidate:candidate
        surfaceGeneration:surfaceGeneration];
    if (submittedReceiptIndex >= 0)
        _presentationReceipts[submittedReceiptIndex].submittedAtTime =
            submittedAtTime;
    os_unfair_lock_unlock(&_stateLock);

    // CAMetalDisplayLink owns this drawable contract: finish encoding, commit
    // the writer, and only then request presentation on the update drawable.
    [commandBuffer commit];
    [drawable present];
    [self schedulePresentationWatchdog];
}

- (void)retireHeldOutputAfterActivation
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed) ||
        !atomic_exchange(&_retainedOutputPending, false)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load(&self->_invalidated) || atomic_load(&self->_failed))
            return;
        os_unfair_lock_lock(&self->_stateLock);
        BOOL outputActive = NO;
        if ([self callbackStateIsUsableLocked])
            outputActive =
                FPFrameGenerationTelemetrySnapshot(self->_state).outputActive;
        os_unfair_lock_unlock(&self->_stateLock);
        if (!outputActive)
        {
            if (self->_retainedOutputLayer)
                atomic_store(&self->_retainedOutputPending, true);
            return;
        }
        [self->_retainedOutputLayer removeFromSuperlayer];
        self->_retainedOutputLayer = nil;
    });
}

- (void)updateFrameCheckWithTelemetry:(FPFrameGenerationTelemetry)telemetry
{
    (void)telemetry;
    if (!_frameCheckEnabled || atomic_load(&_invalidated) ||
        atomic_load(&_failed)) return;
    CFTimeInterval now = CACurrentMediaTime();
    os_unfair_lock_lock(&_stateLock);
    if (now - _lastFrameCheckUpdateTime < FPFrameCheckMinimumInterval ||
        atomic_exchange(&_frameCheckUpdatePending, true))
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _lastFrameCheckUpdateTime = now;
    os_unfair_lock_unlock(&_stateLock);
    __weak FPD3DMetalFrameGenerationSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FPD3DMetalFrameGenerationSession *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!atomic_load(&strongSelf->_invalidated) &&
            !atomic_load(&strongSelf->_failed) &&
            strongSelf->_hostView.layer)
        {
            FPFrameGenerationTelemetry currentTelemetry = {0};
            os_unfair_lock_lock(&strongSelf->_stateLock);
            if ([strongSelf callbackStateIsUsableLocked])
            {
                currentTelemetry = FPFrameGenerationTelemetrySnapshotAtTime(
                    strongSelf->_state,
                    CACurrentMediaTime()
                );
            }
            os_unfair_lock_unlock(&strongSelf->_stateLock);
            CATextLayer *layer = [strongSelf ensureFrameCheckLayerOnMain];
            if (layer)
            {
                BOOL monitoring =
                    strcmp(currentTelemetry.state, "monitoring") == 0;
                BOOL priming = strcmp(currentTelemetry.state, "priming") == 0;
                if (monitoring || priming)
                {
                    double sourceCadence = currentTelemetry.sourceCadenceHz;
                    NSString *suffix = priming ? @" · Priming" : @"";
                    if (sourceCadence > 0.0)
                        layer.string = [NSString stringWithFormat:
                            @"Target      %6u Hz%@\n"
                             "Final       %6.1f FPS\n"
                             "Original    %6.1f FPS\n"
                             "Generated   %6.1f FPS",
                            currentTelemetry.targetFrameRate,
                            suffix,
                            sourceCadence,
                            sourceCadence,
                            0.0];
                    else
                        layer.string = [NSString stringWithFormat:
                            @"Target      %6u Hz%@\n"
                             "Final           -- FPS\n"
                             "Original        -- FPS\n"
                             "Generated      0.0 FPS",
                            currentTelemetry.targetFrameRate,
                            suffix];
                }
                else if (currentTelemetry.outputActive &&
                         currentTelemetry.finalCadenceHz > 0.0)
                    layer.string = [NSString stringWithFormat:
                        @"Target      %6u Hz\n"
                         "Final       %6.1f FPS\n"
                         "Original    %6.1f FPS\n"
                         "Generated   %6.1f FPS",
                        currentTelemetry.targetFrameRate,
                        currentTelemetry.finalCadenceHz,
                        currentTelemetry.sourceCadenceHz,
                        currentTelemetry.generatedCadenceHz];
                else if (currentTelemetry.outputActive)
                    layer.string = [NSString stringWithFormat:
                        @"Target      %6u Hz\n"
                         "Final           -- FPS\n"
                         "Original    %6.1f FPS\n"
                         "Generated   %6.1f FPS",
                        currentTelemetry.targetFrameRate,
                        currentTelemetry.sourceCadenceHz,
                        currentTelemetry.generatedCadenceHz];
            }
        }
        atomic_store(&strongSelf->_frameCheckUpdatePending, false);
    });
}

- (void)emitTelemetryForced:(BOOL)forced
{
    FPFrameGenerationTelemetry telemetry;
    FPFrameGenerationRuntimeCounters runtimeCounters = {0};
    CFTimeInterval now;

    if (atomic_load(&_invalidated)) return;
    os_unfair_lock_lock(&_telemetryWriteLock);
    if (atomic_load(&_invalidated))
    {
        os_unfair_lock_unlock(&_telemetryWriteLock);
        return;
    }
    now = CACurrentMediaTime();
    os_unfair_lock_lock(&_stateLock);
    if (![self telemetryStateIsUsableLocked])
    {
        os_unfair_lock_unlock(&_stateLock);
        os_unfair_lock_unlock(&_telemetryWriteLock);
        return;
    }
    if (!forced && now - _lastTelemetryTime < FPTelemetryMinimumInterval)
    {
        os_unfair_lock_unlock(&_stateLock);
        os_unfair_lock_unlock(&_telemetryWriteLock);
        return;
    }
    _lastTelemetryTime = now;
    telemetry = FPFrameGenerationTelemetrySnapshotAtTime(_state, now);
    runtimeCounters.captureSkippedBusy = _captureSkippedBusy;
    runtimeCounters.captureInFlight = _captureInFlight;
    runtimeCounters.maximumCaptureInFlight = _maximumCaptureInFlight;
    runtimeCounters.captureBusyEpisode = _captureBusyEpisode;
    if (_captureInFlight && _captureOutstandingStartTime > 0.0 &&
        now > _captureOutstandingStartTime)
        runtimeCounters.captureOutstandingMilliseconds =
            (now - _captureOutstandingStartTime) * 1000.0;
    runtimeCounters.consecutiveEmptyDisplayUpdates =
        _consecutiveEmptyDisplayUpdates;
    runtimeCounters.displayResumeCount = _displayResumeCount;
    runtimeCounters.sourceCadenceHz = telemetry.sourceCadenceHz;
    runtimeCounters.currentOutputCadenceHz =
        telemetry.currentOutputCadenceHz;
    runtimeCounters.generatedCadenceHz = telemetry.generatedCadenceHz;
    if (telemetry.sourceCadenceHz > 0.0 &&
        isfinite(telemetry.sourceCadenceHz))
    {
        runtimeCounters.outputSourceRatio =
            fmin(
                1000.0,
                fmax(0.0, telemetry.finalCadenceHz / telemetry.sourceCadenceHz)
            );
        runtimeCounters.currentSourceRatio =
            fmin(
                1000.0,
                fmax(
                    0.0,
                    telemetry.currentOutputCadenceHz /
                        telemetry.sourceCadenceHz
                )
            );
    }
    runtimeCounters.sourceCadenceRatio = telemetry.sourceCadenceRatio;
    runtimeCounters.sourceCadenceLower95 = telemetry.sourceCadenceLower95;
    runtimeCounters.sourceCadenceUpper95 = telemetry.sourceCadenceUpper95;
    runtimeCounters.captureCommandBuffersOutstanding = _captureInFlight;
    runtimeCounters.displayCommandBuffersOutstanding =
        telemetry.presentationsInFlight;
    runtimeCounters.presentationReceiptsPending =
        telemetry.presentationReceiptsPending;
    runtimeCounters.maximumPresentationReceiptsPending =
        telemetry.maximumPresentationReceiptsPending;
    runtimeCounters.writerCompleted = telemetry.writerCompleted;
    runtimeCounters.currentWriterCompleted = telemetry.currentWriterCompleted;
    runtimeCounters.capturePoolAllocations = _capturePoolAllocations;
    runtimeCounters.capturePoolReleases = _capturePoolReleases;
    runtimeCounters.capturePoolTextureCount = (uint32_t)_captureTextures.count;
    runtimeCounters.sessionIdentifier = _sessionIdentifier;
    runtimeCounters.recordMonotonicTime = now;
    runtimeCounters.presentationStallChecks = _presentationStallChecks;
    runtimeCounters.sourcePresentCommandBufferBound =
        _sourcePresentCommandBufferBound;
    runtimeCounters.sourceCaptureEncodedOnSourceCB =
        _sourceCaptureEncodedOnSourceCB;
    runtimeCounters.sourceCaptureJoined = _sourceCaptureJoined;
    runtimeCounters.sourcePresentUncovered = _sourcePresentUncovered;
    os_unfair_lock_unlock(&_stateLock);
    FPWriteTelemetryRecord(telemetry, runtimeCounters);
    os_unfair_lock_unlock(&_telemetryWriteLock);
}

- (void)failWithReason:(const char *)reason
{
    if (atomic_load(&_invalidated) || atomic_exchange(&_failed, true)) return;
    NSString *failureReason = [NSString stringWithUTF8String:
        reason && reason[0] ? reason : "runtime-error"];
    os_unfair_lock_lock(&_stateLock);
    if (_state == NULL || atomic_load(&_invalidated))
    {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    uint32_t failureBusyEpisode = _captureBusyEpisode;
    uint32_t failurePresentationStallChecks = _presentationStallChecks;
    FPFrameGenerationSetError(_state, reason);
    [self resetTextureBookkeepingLocked];
    _captureBusyEpisode = failureBusyEpisode;
    _presentationStallChecks = failurePresentationStallChecks;
    os_unfair_lock_unlock(&_stateLock);
    [self emitTelemetryForced:YES];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load(&self->_invalidated)) return;
        [self->_displayLink invalidate];
        self->_displayLink.delegate = nil;
        self->_displayLink = nil;
        atomic_store(&self->_displayLinkPausedForWork, true);
        atomic_store(&self->_sourceCaptureEnabled, false);
        /* Terminal frame-generation failure is fail-open to the live source,
         * never a frozen last-generated frame. Keep only the transparent host
         * and optional error HUD; telemetry continues to report the failure. */
        [self->_outputLayer removeFromSuperlayer];
        self->_outputLayer = nil;
        [self->_retainedOutputLayer removeFromSuperlayer];
        self->_retainedOutputLayer = nil;
        atomic_store(&self->_retainedOutputPending, false);
        self->_sourceLayer.framebufferOnly =
            self->_sourceFramebufferOnlyBeforeSession;
        [self releaseDemandMetalResourcesOnMain];
        if (self->_frameCheckEnabled)
        {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            CATextLayer *layer = [self ensureFrameCheckLayerOnMain];
            layer.string = [NSString stringWithFormat:
                @"Frame Generation inactive: %@",
                failureReason ? failureReason : @"runtime-error"];
            [CATransaction commit];
        }
        else
        {
            [self->_frameCheckLayer removeFromSuperlayer];
            self->_frameCheckLayer = nil;
        }
    });
}

- (void)invalidate
{
    if (atomic_exchange(&_invalidated, true)) return;
    __unsafe_unretained FPD3DMetalFrameGenerationSession *unsafeSelf = self;
    void (^cleanup)(void) = ^{
        FPUnregisterFrameGenerationSourceLayer(
            unsafeSelf->_sourceLayer,
            unsafeSelf
        );
        [unsafeSelf->_displayLink invalidate];
        unsafeSelf->_displayLink.delegate = nil;
        unsafeSelf->_displayLink = nil;
        [unsafeSelf->_hostView removeFromSuperview];
        unsafeSelf->_hostView.frameGenerationSession = nil;
        unsafeSelf->_frameCheckLayer = nil;
        unsafeSelf->_outputLayer = nil;
        unsafeSelf->_retainedOutputLayer = nil;
        atomic_store(&unsafeSelf->_retainedOutputPending, false);
        [unsafeSelf releaseDemandMetalResourcesOnMain];
        unsafeSelf->_sourceLayer.framebufferOnly =
            unsafeSelf->_sourceFramebufferOnlyBeforeSession;
        unsafeSelf->_sourceLayer = nil;
    };
    if (NSThread.isMainThread)
        cleanup();
    else
        dispatch_sync(dispatch_get_main_queue(), cleanup);
    os_unfair_lock_lock(&_stateLock);
    [self resetTextureBookkeepingLocked];
    os_unfair_lock_unlock(&_stateLock);
}

- (void)dealloc
{
    [self invalidate];
    os_unfair_lock_lock(&_stateLock);
    FPFrameGenerationState *stateToDestroy = _state;
    _state = NULL;
    os_unfair_lock_unlock(&_stateLock);
    FPFrameGenerationStateDestroy(stateToDestroy);
}

@end

static void *FPCreateSessionV1(
    void *owningMetalView,
    void *metalDevice,
    const FPD3DMetalFrameGenerationConfigurationV1 *configuration,
    void **sourceMetalLayer,
    char *failureReason,
    size_t failureReasonCapacity
)
{
    if (sourceMetalLayer) *sourceMetalLayer = NULL;
    if (!configuration ||
        configuration->structureSize != sizeof(*configuration) ||
        configuration->abiVersion !=
            FP_D3DMETAL_FRAME_GENERATION_PROXY_ABI_VERSION ||
        (configuration->targetFrameRate != 120 &&
         configuration->targetFrameRate != 144 &&
         configuration->targetFrameRate != 240) ||
        configuration->frameCheckEnabled > 1)
    {
        FPCopyFailureReason(
            failureReason,
            failureReasonCapacity,
            "configuration-invalid"
        );
        FPWriteStandaloneErrorTelemetry(
            configuration ? configuration->targetFrameRate : 0,
            "configuration-invalid"
        );
        return NULL;
    }
    if (!owningMetalView || !metalDevice || !sourceMetalLayer)
    {
        FPCopyFailureReason(
            failureReason,
            failureReasonCapacity,
            "surface-input-missing"
        );
        FPWriteStandaloneErrorTelemetry(
            configuration->targetFrameRate,
            "surface-input-missing"
        );
        return NULL;
    }
    __block FPD3DMetalFrameGenerationSession *session;
    __block const char *validationFailure = NULL;
    dispatch_block_t create = ^{
        id owningViewObject = (__bridge id)owningMetalView;
        id deviceObject = (__bridge id)metalDevice;
        if (![owningViewObject isKindOfClass:NSView.class])
        {
            validationFailure = "client-view-invalid";
            return;
        }
        if (![deviceObject conformsToProtocol:@protocol(MTLDevice)])
        {
            validationFailure = "metal-device-invalid";
            return;
        }
        session = [[FPD3DMetalFrameGenerationSession alloc]
            initWithOwningMetalView:(NSView *)owningViewObject
            device:(id<MTLDevice>)deviceObject
            targetFrameRate:configuration->targetFrameRate
            frameCheckEnabled:configuration->frameCheckEnabled == 1
            failureReason:failureReason
            failureReasonCapacity:failureReasonCapacity];
    };
    if (NSThread.isMainThread)
        create();
    else
        dispatch_sync(dispatch_get_main_queue(), create);
    if (!session)
    {
        if (validationFailure)
            FPCopyFailureReason(
                failureReason,
                failureReasonCapacity,
                validationFailure
            );
        FPWriteStandaloneErrorTelemetry(
            configuration->targetFrameRate,
            validationFailure ? validationFailure : "session-create-failed"
        );
        return NULL;
    }
    *sourceMetalLayer = (__bridge void *)session.sourceLayer;
    /* The create callback can run inside D3DMetal/libd3dshared initialization.
     * Never realize and exchange CAMetalLayer methods synchronously on that
     * callback stack. Queue activation on the main executor; this is secondary
     * hardening, while Wine's original-view ABI identity remains the primary
     * lifecycle guarantee. Source frames stay on Wine's original path until
     * the hook becomes active. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [session activateSourceObservation];
    });
    return (__bridge_retained void *)session;
}

static void FPDestroySessionV1(void *opaqueSession)
{
    if (!opaqueSession) return;
    FPD3DMetalFrameGenerationSession *session =
        CFBridgingRelease(opaqueSession);
    [session invalidate];
}

const FPD3DMetalFrameGenerationProxyAPIV1 *
FPD3DMetalFrameGenerationProxyGetAPIV1(void)
{
    static const FPD3DMetalFrameGenerationProxyAPIV1 api = {
        .structureSize = sizeof(FPD3DMetalFrameGenerationProxyAPIV1),
        .abiVersion = FP_D3DMETAL_FRAME_GENERATION_PROXY_ABI_VERSION,
        .createSession = FPCreateSessionV1,
        .destroySession = FPDestroySessionV1,
    };
    return &api;
}
