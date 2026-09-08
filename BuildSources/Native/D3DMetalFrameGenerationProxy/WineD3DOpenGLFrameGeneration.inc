/* ForgePlay's optional WineD3D OpenGL source adapter. This implementation uses
 * only public CGL, IOSurface and Metal APIs; Wine retains its original swap.
 * Included here to share the existing bounded telemetry writer, not its Metal
 * source hooks. No class interception or global GL hook is installed. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#define GL_SILENCE_DEPRECATION
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <IOSurface/IOSurface.h>

#define FP_GL_SURFACE_CAPACITY 6u
#define FP_GL_PENDING_CAPACITY 3u
static const uint64_t FPGLMaximumPoolBytes = 512ull * 1024 * 1024;

@interface FPGLCaptureSlot : NSObject
@property(nonatomic) GLuint name;
@property(nonatomic) GLsync fence;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic) CGLContextObj cleanupContext;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) NSUInteger users;
@property(nonatomic) double contentTime;
@end
@implementation FPGLCaptureSlot
- (void)dealloc
{
    /* All objects here are share-group objects (no context-local FBO/VAO).
     * Teardown may run on another thread, after Metal's last reader retires. */
    if (_cleanupContext)
    {
        CGLLockContext(_cleanupContext);
        CGLContextObj saved = CGLGetCurrentContext();
        if (CGLSetCurrentContext(_cleanupContext) == kCGLNoError)
        {
            if (_fence) glDeleteSync(_fence);
            if (_name) glDeleteTextures(1, &_name);
            CGLSetCurrentContext(saved);
        }
        CGLUnlockContext(_cleanupContext);
        CGLReleaseContext(_cleanupContext);
    }
    if (_surface) CFRelease(_surface);
}
@end

@class FPWineD3DGLSession;
@interface FPWineD3DGLOverlayView : NSView
@property(nonatomic, weak) FPWineD3DGLSession *session;
@end

@interface FPWineD3DGLSession : NSObject <CAMetalDisplayLinkDelegate>
{
    os_unfair_lock _lock;
    atomic_bool _invalidated;
    atomic_bool _ready;
    atomic_bool _failed;
    atomic_bool _surfaceRefreshPending;
    atomic_bool _exposePending;
    atomic_bool _suspended;
    atomic_uint_fast64_t _lifecycleGeneration;
    CGLContextObj _sourceContext;
    CGLContextObj _pollContext;
    __weak NSView *_sourceView;
    __weak NSWindow *_observedWindow;
    BOOL _visibilityTransition;
    FPWineD3DGLOverlayView *_view;
    CAMetalLayer *_layer;
    CATextLayer *_hud;
    CAMetalDisplayLink *_link;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _currentPipeline;
    id<MTLRenderPipelineState> _midpointPipeline;
    NSArray<FPGLCaptureSlot *> *_pool;
    NSMutableArray<FPGLCaptureSlot *> *_pending;
    NSMutableDictionary<NSNumber *, FPGLCaptureSlot *> *_currents;
    FPGLCaptureSlot *_history;
    FPGLCaptureSlot *_pairPrevious;
    uint64_t _pairEpoch;
    FPFrameGenerationState *_state;
    uint32_t _width, _height, _target;
    uint32_t _writers;
    uint32_t _maximumCaptureInFlight;
    FPFrameGenerationPresentationReceipt _receipts[FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY];
    BOOL _frameCheck;
    BOOL _visible;
    uint64_t _sessionIdentifier;
    double _minimumCaptureContentTime;
    double _maximumCaptureToOutputMilliseconds;
    double _lastCaptureTime;
    double _lastPositiveOutput;
    double _lastHudTime;
    double _lastTelemetryTime;
    uint64_t _captureSkipped;
    uint64_t _poolAllocations;
    uint64_t _poolReleases;
}
- (instancetype)initWithView:(NSView *)view context:(CGLContextObj)context
               configuration:(const FPD3DMetalFrameGenerationConfigurationV1 *)configuration;
- (int)beforeSwapWidth:(uint32_t)width height:(uint32_t)height;
- (void)invalidate;
- (void)layoutOverlay;
- (void)windowVisibilityChanged:(NSNotification *)notification;
@end

@implementation FPWineD3DGLOverlayView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)isOpaque { return NO; }
- (void)layout { [super layout]; [self.session layoutOverlay]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.session layoutOverlay]; }
- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self.session layoutOverlay];
}
@end

@implementation FPWineD3DGLSession
- (instancetype)initWithView:(NSView *)view context:(CGLContextObj)context
               configuration:(const FPD3DMetalFrameGenerationConfigurationV1 *)configuration
{
    if (!(self = [super init])) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    atomic_init(&_invalidated, false);
    atomic_init(&_ready, false);
    atomic_init(&_failed, false);
    atomic_init(&_surfaceRefreshPending, false);
    atomic_init(&_exposePending, false);
    atomic_init(&_suspended, false);
    atomic_init(&_lifecycleGeneration, 1);
    _sourceContext = CGLRetainContext(context);
    if (CGLCreateContext(CGLGetPixelFormat(context), context, &_pollContext) != kCGLNoError)
        return nil;
    _sourceView = view;
    _target = configuration->targetFrameRate;
    _frameCheck = configuration->frameCheckEnabled;
    _state = FPFrameGenerationStateCreateForCapturedSource(true, _target);
    _device = MTLCreateSystemDefaultDevice();
    if (!_state || !_device) return nil;
    _sessionIdentifier = atomic_fetch_add(&FPNextFrameGenerationSessionIdentifier, 1);
    _pending = [NSMutableArray arrayWithCapacity:FP_GL_PENDING_CAPACITY];
    _currents = [NSMutableDictionary dictionaryWithCapacity:FP_FRAME_GENERATION_READY_CURRENT_CAPACITY];
    __weak FPWineD3DGLSession *weakSelf = self;
    id<MTLDevice> device = _device;
    dispatch_async(FPMetalPreparationQueue(), ^{
        /* GL rows start at the bottom; flip at composition without CPU copies. */
        NSString *source = [FPFrameGenerationCompositionShaderSource()
            stringByReplacingOccurrencesOfString:@"uint2 coordinate = uint2(input.position.xy);"
            withString:@"uint2 coordinate = uint2(input.position.x, current.get_height() - 1 - uint(input.position.y));"];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLRenderPipelineState> current = nil, midpoint = nil;
        for (NSUInteger index = 0; index < 2 && library; ++index)
        {
            MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = [library newFunctionWithName:@"fp_frame_generation_vertex"];
            descriptor.fragmentFunction = [library newFunctionWithName:index ? @"fp_frame_generation_midpoint" : @"fp_frame_generation_current"];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
            if (index) midpoint = pipeline; else current = pipeline;
        }
        id<MTLCommandQueue> queue = [device newCommandQueueWithMaxCommandBufferCount:3];
        dispatch_async(dispatch_get_main_queue(), ^{
            FPWineD3DGLSession *session = weakSelf;
            if (!session || atomic_load(&session->_invalidated)) return;
            if (!current || !midpoint || !queue || !session->_sourceView)
            {
                [session fail:"gl-metal-resource-unavailable"];
                return;
            }
            session->_queue = queue;
            session->_currentPipeline = current;
            session->_midpointPipeline = midpoint;
            [session installOverlay];
            atomic_store(&session->_ready, true);
        });
    });
    return self;
}

- (void)dealloc
{
    FPFrameGenerationStateDestroy(_state);
    if (_sourceContext) CGLReleaseContext(_sourceContext);
    if (_pollContext) CGLReleaseContext(_pollContext);
}

- (void)installOverlay
{
    NSView *source = _sourceView;
    _view = [[FPWineD3DGLOverlayView alloc] initWithFrame:source.bounds];
    _view.session = self;
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.wantsLayer = YES;
    _view.layer.backgroundColor = NSColor.clearColor.CGColor;
    _layer = [CAMetalLayer layer];
    _layer.device = _device;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    /* An empty non-opaque layer has no pixels until its first real drawable.
     * Hiding it here would let Core Animation cull the link before activation. */
    _layer.opaque = NO;
    _layer.backgroundColor = NSColor.clearColor.CGColor;
    _layer.framebufferOnly = YES;
    _layer.maximumDrawableCount = 3;
    _layer.hidden = NO;
    [_view.layer addSublayer:_layer];
    if (_frameCheck)
    {
        _hud = [CATextLayer layer];
        _hud.font = (__bridge CFTypeRef)[NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium];
        _hud.fontSize = 13;
        _hud.foregroundColor = NSColor.whiteColor.CGColor;
        _hud.backgroundColor = [NSColor colorWithWhite:0 alpha:0.7].CGColor;
        _hud.string = @"Original        -- FPS\nGenerated      0.0 FPS\nDisplayed       -- FPS";
        [_view.layer addSublayer:_hud];
    }
    [source addSubview:_view positioned:NSWindowAbove relativeTo:nil];
    _link = [[CAMetalDisplayLink alloc] initWithMetalLayer:_layer];
    _link.delegate = self;
    _link.preferredFrameRateRange = CAFrameRateRangeMake(_target, _target, _target);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self layoutOverlay];
}

- (void)exposeOriginal
{
    if (!NSThread.isMainThread)
    {
        if (atomic_exchange(&_exposePending, true)) return;
        __weak FPWineD3DGLSession *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            FPWineD3DGLSession *session = weakSelf;
            if (!session) return;
            atomic_store(&session->_exposePending, false);
            [session exposeOriginal];
        });
        return;
    }
    _visible = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.hidden = YES;
    [CATransaction commit];
}

- (void)replaceOverlayForFreshOutput
{
    [_link invalidate];
    _link.delegate = nil;
    [_layer removeFromSuperlayer];
    _view.session = nil;
    [_view removeFromSuperview];
    [self installOverlay];
}

- (void)windowVisibilityChanged:(NSNotification *)notification
{
    (void)notification;
    if (_visibilityTransition || atomic_load(&_invalidated) || atomic_load(&_failed)) return;
    NSWindow *window = _sourceView.window;
    BOOL available = window && window.visible && !window.miniaturized &&
        (window.occlusionState & NSWindowOcclusionStateVisible);
    if (!available)
    {
        if (atomic_exchange(&_suspended, true)) return;
        _link.paused = YES;
        [self exposeOriginal];
        os_unfair_lock_lock(&_lock);
        atomic_fetch_add(&_lifecycleGeneration, 1);
        FPFrameGenerationResetForSurfaceChange(_state, "gl-window-inactive");
        for (FPGLCaptureSlot *slot in _currents.allValues) --slot.users;
        [_currents removeAllObjects];
        if (_history) --_history.users;
        _history = nil;
        if (_pairPrevious) --_pairPrevious.users;
        _pairPrevious = nil;
        _pairEpoch = 0;
        _lastCaptureTime = _lastPositiveOutput = 0;
        memset(_receipts, 0, sizeof(_receipts));
        /* Pending GL fences and real Metal writers still own their slots.
         * Resume retires those old captures without admitting stale content. */
        os_unfair_lock_unlock(&_lock);
    }
    else if (atomic_load(&_suspended))
    {
        os_unfair_lock_lock(&_lock);
        _minimumCaptureContentTime = CACurrentMediaTime();
        os_unfair_lock_unlock(&_lock);
        atomic_store(&_suspended, false);
        _visibilityTransition = YES;
        [self replaceOverlayForFreshOutput];
        _visibilityTransition = NO;
        _link.paused = NO;
    }
}

- (void)layoutOverlay
{
    if (atomic_load(&_invalidated)) return;
    NSWindow *window = _sourceView.window;
    if (window != _observedWindow)
    {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification,
            NSWindowDidDeminiaturizeNotification, NSWindowDidChangeOcclusionStateNotification])
        {
            if (_observedWindow) [center removeObserver:self name:name object:_observedWindow];
            if (window) [center addObserver:self selector:@selector(windowVisibilityChanged:) name:name object:window];
        }
        _observedWindow = window;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.frame = _view.bounds;
    _layer.contentsScale = _view.window.backingScaleFactor > 0 ? _view.window.backingScaleFactor : 1.0;
    os_unfair_lock_lock(&_lock);
    uint32_t width = _width, height = _height;
    os_unfair_lock_unlock(&_lock);
    if (width && height) _layer.drawableSize = CGSizeMake(width, height);
    _hud.contentsScale = _layer.contentsScale;
    _hud.frame = CGRectMake(12, MAX(0.0, _view.bounds.size.height - 88), 256, 76);
    [CATransaction commit];
    [self windowVisibilityChanged:nil];
}

- (void)fail:(const char *)reason
{
    if (atomic_exchange(&_failed, true)) return;
    os_unfair_lock_lock(&_lock);
    FPFrameGenerationSetError(_state, reason);
    os_unfair_lock_unlock(&_lock);
    [self exposeOriginal];
    [self report];
}

- (void)invalidate
{
    if (atomic_exchange(&_invalidated, true)) return;
    atomic_store(&_ready, false);
    dispatch_block_t detach = ^{
        [NSNotificationCenter.defaultCenter removeObserver:self];
        self->_observedWindow = nil;
        [self->_link invalidate];
        self->_link.delegate = nil;
        self->_link = nil;
        [self->_view removeFromSuperview];
        self->_view.session = nil;
        self->_view = nil;
        self->_layer = nil;
        self->_hud = nil;
    };
    if (NSThread.isMainThread) detach();
    else dispatch_async(dispatch_get_main_queue(), detach);
    os_unfair_lock_lock(&_lock);
    [_pending removeAllObjects];
    [_currents removeAllObjects];
    _history = nil;
    _pairPrevious = nil;
    if (_pool) ++_poolReleases;
    _pool = nil;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)allocatePoolWidth:(uint32_t)width height:(uint32_t)height
{
    /* Called only on the original current context, with _lock held. Shared
     * textures are written by GL and read by Metal only after a signaled fence. */
    NSMutableArray *pool = [NSMutableArray arrayWithCapacity:FP_GL_SURFACE_CAPACITY];
    GLint binding = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &binding);
    for (NSUInteger index = 0; index < FP_GL_SURFACE_CAPACITY; ++index)
    {
        FPGLCaptureSlot *slot = [FPGLCaptureSlot new];
        slot.cleanupContext = CGLRetainContext(_pollContext);
        NSDictionary *properties = @{
            (id)kIOSurfaceWidth: @(width), (id)kIOSurfaceHeight: @(height),
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfaceBytesPerRow: @((uint64_t)width * 4),
            (id)kIOSurfacePixelFormat: @(0x42475241u)
        };
        slot.surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!slot.surface) break;
        GLuint name = 0;
        glGenTextures(1, &name);
        slot.name = name;
        glBindTexture(GL_TEXTURE_RECTANGLE, name);
        CGLError result = CGLTexImageIOSurface2D(_sourceContext, GL_TEXTURE_RECTANGLE,
            GL_RGBA8, width, height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, slot.surface, 0);
        if (result != kCGLNoError) break;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        slot.texture = [_device newTextureWithDescriptor:descriptor iosurface:slot.surface plane:0];
        if (!slot.texture) break;
        [pool addObject:slot];
    }
    glBindTexture(GL_TEXTURE_RECTANGLE, binding);
    if (pool.count != FP_GL_SURFACE_CAPACITY) return NO;
    _pool = pool;
    ++_poolAllocations;
    return YES;
}

- (int)beforeSwapWidth:(uint32_t)width height:(uint32_t)height
{
    if (atomic_load(&_invalidated) || atomic_load(&_failed)) return 0;
    if (!atomic_load(&_ready) || atomic_load(&_suspended)) return 1;
    /* A foreign current context must never access the source backbuffer. */
    if (CGLGetCurrentContext() != _sourceContext || !width || !height ||
        (uint64_t)width * height > FPGLMaximumPoolBytes / (4 * FP_GL_SURFACE_CAPACITY))
    {
        [self fail:"gl-source-context-or-size-invalid"];
        return 0;
    }
    os_unfair_lock_lock(&_lock);
    if (_width != width || _height != height)
    {
        /* Do not allocate another generation while old Metal readers exist. */
        if (_writers)
        {
            os_unfair_lock_unlock(&_lock);
            [self exposeOriginal];
            return 1;
        }
        atomic_fetch_add(&_lifecycleGeneration, 1);
        FPFrameGenerationResetForSurfaceChange(_state, "gl-surface-change");
        [_pending removeAllObjects];
        [_currents removeAllObjects];
        _history = nil;
        _pairPrevious = nil;
        _pairEpoch = 0;
        if (_pool) ++_poolReleases;
        _pool = nil;
        _width = width;
        _height = height;
        _lastCaptureTime = _lastPositiveOutput = 0;
        memset(_receipts, 0, sizeof(_receipts));
        if (![self allocatePoolWidth:width height:height])
        {
            os_unfair_lock_unlock(&_lock);
            [self fail:"gl-iosurface-allocation-failed"];
            return 0;
        }
        if (!atomic_exchange(&_surfaceRefreshPending, true))
        dispatch_async(dispatch_get_main_queue(), ^{
            /* At most one refresh can be queued while one is executing. */
            atomic_store(&self->_surfaceRefreshPending, false);
            if (atomic_load(&self->_invalidated) || atomic_load(&self->_failed)) return;
            /* Replacement starts empty; it never carries a stale old drawable
             * across a resize/fullscreen backing-size transition. */
            [self replaceOverlayForFreshOutput];
        });
    }
    FPGLCaptureSlot *slot = nil;
    if (_pending.count < FP_GL_PENDING_CAPACITY)
        for (FPGLCaptureSlot *candidate in _pool)
            if (!candidate.users && !candidate.fence) { slot = candidate; break; }
    if (!slot)
    {
        ++_captureSkipped;
        os_unfair_lock_unlock(&_lock);
        return 1;
    }
    GLint readFramebuffer = 0, readBuffer = 0, texture = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    glGetIntegerv(GL_READ_BUFFER, &readBuffer);
    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &texture);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    GLint defaultReadBuffer = 0;
    glGetIntegerv(GL_READ_BUFFER, &defaultReadBuffer);
    glReadBuffer(GL_BACK);
    glBindTexture(GL_TEXTURE_RECTANGLE, slot.name);
    /* This is an explicitly labelled capture content clock, never a claimed
     * GL swap completion or physical source presentedTime. */
    slot.contentTime = CACurrentMediaTime();
    glCopyTexSubImage2D(GL_TEXTURE_RECTANGLE, 0, 0, 0, 0, 0, width, height);
    slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE, texture);
    glReadBuffer(defaultReadBuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFramebuffer);
    glReadBuffer(readBuffer);
    if (!slot.fence)
    {
        os_unfair_lock_unlock(&_lock);
        [self fail:"gl-capture-fence-unavailable"];
        return 0;
    }
    slot.users = 1;
    [_pending addObject:slot];
    _maximumCaptureInFlight = MAX(_maximumCaptureInFlight, (uint32_t)_pending.count);
    /* Flush submits the fence; it never waits for execution. Wine still calls
     * its normal flushBuffer immediately after this optional adapter returns. */
    glFlush();
    os_unfair_lock_unlock(&_lock);
    return 1;
}

- (void)consumeReadyCapturesLocked
{
    CGLLockContext(_pollContext);
    CGLContextObj saved = CGLGetCurrentContext();
    if (CGLSetCurrentContext(_pollContext) != kCGLNoError)
    {
        CGLUnlockContext(_pollContext);
        return;
    }
    while (_pending.count)
    {
        FPGLCaptureSlot *slot = _pending.firstObject;
        GLenum result = glClientWaitSync(slot.fence, 0, 0);
        if (result != GL_ALREADY_SIGNALED && result != GL_CONDITION_SATISFIED) break;
        glDeleteSync(slot.fence);
        slot.fence = NULL;
        [_pending removeObjectAtIndex:0];
        --slot.users;
        if (slot.contentTime < _minimumCaptureContentTime) continue;
        _lastCaptureTime = slot.contentTime;
        FPFrameGenerationSourceObservation observation =
            FPFrameGenerationObserveSourceCaptureAvailable(_state, slot.contentTime);
        if (!observation.accepted) continue;
        uint64_t staleSeed = FPFrameGenerationDiscardStalePreactivationSeed(_state);
        if (staleSeed)
        {
            FPGLCaptureSlot *seed = _currents[@(staleSeed)];
            if (seed) --seed.users;
            [_currents removeObjectForKey:@(staleSeed)];
            if (_history == seed) { --_history.users; _history = nil; }
        }
        FPFrameGenerationCapturePlan plan = FPFrameGenerationRecordCaptureReadyAtTime(
            _state, observation.sourceSequence, slot.contentTime, CACurrentMediaTime());
        if (!plan.accepted) continue;
        if (plan.shouldGenerateMidpoint && !_history)
        {
            FPFrameGenerationCancelAcceptedCapture(_state, plan.epoch);
            continue;
        }
        _currents[@(plan.epoch)] = slot;
        ++slot.users;
        if (plan.shouldGenerateMidpoint)
        {
            _pairPrevious = _history;
            ++_pairPrevious.users;
            _pairEpoch = plan.epoch;
            FPFrameGenerationRecordGeneratedPairReady(_state, plan.epoch);
        }
        else FPFrameGenerationRecordCurrentReady(_state, plan.epoch, slot.contentTime);
        if (_history) --_history.users;
        _history = slot;
        ++_history.users;
    }
    CGLSetCurrentContext(saved);
    CGLUnlockContext(_pollContext);
}

- (void)retirePairIfUnownedLocked
{
    if (_pairPrevious && FPFrameGenerationGetProgress(_state).readyMidpointSourceTime <= 0)
    {
        --_pairPrevious.users;
        _pairPrevious = nil;
        _pairEpoch = 0;
    }
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update
{
    if (link != _link || atomic_load(&_invalidated) || atomic_load(&_failed) || !atomic_load(&_ready)) return;
    [self windowVisibilityChanged:nil];
    if (atomic_load(&_suspended) || link != _link) return;
    double now = CACurrentMediaTime();
    os_unfair_lock_lock(&_lock);
    [self consumeReadyCapturesLocked];
    /* A frozen optional output must reveal the still-running raw GL surface.
     * The 250 ms bound also covers a stalled GPU fence or output receipt. */
    BOOL stale = (_lastCaptureTime > 0 && now - _lastCaptureTime > 0.25) ||
        (_writers && _lastPositiveOutput > 0 && now - _lastPositiveOutput > 0.25);
    for (NSUInteger index = 0; index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY; ++index)
        if (_receipts[index].candidate.submissionID &&
            now - _receipts[index].submittedAtTime > 0.25) stale = YES;
    if (stale)
    {
        os_unfair_lock_unlock(&_lock);
        [self fail:"gl-output-progress-stalled"];
        return;
    }
    if (!_width || !_height || !update.drawable || !_sourceView.window.visible || _sourceView.window.miniaturized)
    {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    if (update.drawable.texture.width != _width || update.drawable.texture.height != _height)
    {
        os_unfair_lock_unlock(&_lock);
        [self exposeOriginal];
        return;
    }
    if (update.targetTimestamp > 0 && now >= update.targetTimestamp)
    {
        FPFrameGenerationHandleLateDisplayUpdate(_state);
        [self retirePairIfUnownedLocked];
        os_unfair_lock_unlock(&_lock);
        return;
    }
    FPFrameGenerationRecordDisplayUpdate(_state, update.targetPresentationTimestamp);
    /* A visibility reset retires scheduling metadata, not GPU writer ownership. */
    if (_writers >= FP_FRAME_GENERATION_MAX_PRESENTATIONS_IN_FLIGHT)
    {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    uint64_t lifecycleGeneration = atomic_load(&_lifecycleGeneration);
    FPFrameGenerationDisplayCandidate candidate = FPFrameGenerationAcquireDisplayCandidateAtTime(_state, now);
    FPGLCaptureSlot *current = _currents[@(candidate.epoch)];
    FPGLCaptureSlot *previous = candidate.kind == FPFrameGenerationOutputMidpoint && candidate.epoch == _pairEpoch ? _pairPrevious : current;
    if (candidate.kind == FPFrameGenerationOutputNone)
    {
        [self retirePairIfUnownedLocked];
        os_unfair_lock_unlock(&_lock);
        [self report];
        return;
    }
    if (!current || !previous)
    {
        FPFrameGenerationRecordPresentationSkipped(_state, candidate);
        os_unfair_lock_unlock(&_lock);
        [self fail:"gl-output-content-unavailable"];
        return;
    }
    if (now - candidate.sourcePresentedTime > 0.25)
    {
        FPFrameGenerationRecordPresentationSkipped(_state, candidate);
        os_unfair_lock_unlock(&_lock);
        [self fail:"gl-output-content-stale"];
        return;
    }
    for (NSUInteger index = 0; index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY; ++index)
        if (!_receipts[index].candidate.submissionID)
        {
            _receipts[index].candidate = candidate;
            _receipts[index].submittedAtTime = now;
            break;
        }
    ++current.users;
    ++previous.users;
    ++_writers;
    if (candidate.kind == FPFrameGenerationOutputCurrent)
    {
        [_currents removeObjectForKey:@(candidate.epoch)];
        --current.users;
    }
    else
    {
        FPFrameGenerationRecordGeneratedSubmitted(_state, candidate.epoch);
    }
    [self retirePairIfUnownedLocked];
    /* Never hold our state lock while entering Metal/QuartzCore. A drawable
     * may dispatch an older presentation callback while holding its own lock. */
    os_unfair_lock_unlock(&_lock);
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = update.drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (!buffer || !encoder)
    {
        os_unfair_lock_lock(&_lock);
        --current.users;
        --previous.users;
        --_writers;
        FPFrameGenerationRecordWriterCompleted(_state, candidate, false);
        FPFrameGenerationRecordPresentationReceipt(_state, candidate, 0);
        os_unfair_lock_unlock(&_lock);
        [self fail:"gl-output-encode-failed"];
        return;
    }
    BOOL midpoint = candidate.kind == FPFrameGenerationOutputMidpoint;
    [encoder setRenderPipelineState:midpoint ? _midpointPipeline : _currentPipeline];
    [encoder setFragmentTexture:midpoint ? previous.texture : current.texture atIndex:0];
    if (midpoint) [encoder setFragmentTexture:current.texture atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    id<CAMetalDrawable> drawable = update.drawable;
    __weak FPWineD3DGLSession *weakSelf = self;
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        FPWineD3DGLSession *session = weakSelf;
        if (!session || atomic_load(&session->_invalidated)) return;
        os_unfair_lock_lock(&session->_lock);
        if (lifecycleGeneration != atomic_load(&session->_lifecycleGeneration) ||
            atomic_load(&session->_suspended))
        {
            os_unfair_lock_unlock(&session->_lock);
            return;
        }
        FPFrameGenerationOutputCallbackResult receipt = FPFrameGenerationRecordPresentationReceipt(
            session->_state, candidate, presented.presentedTime);
        for (NSUInteger index = 0; index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY; ++index)
            if (session->_receipts[index].candidate.submissionID == candidate.submissionID)
            {
                session->_receipts[index].presentationSeen = YES;
                if (session->_receipts[index].writerCompleted)
                    memset(&session->_receipts[index], 0, sizeof(session->_receipts[index]));
                break;
            }
        BOOL positive = receipt.positivePresentationRecorded;
        if (positive)
        {
            session->_lastPositiveOutput = presented.presentedTime;
            session->_maximumCaptureToOutputMilliseconds = fmax(
                session->_maximumCaptureToOutputMilliseconds,
                fmax(0, (presented.presentedTime - candidate.sourcePresentedTime) * 1000));
        }
        os_unfair_lock_unlock(&session->_lock);
        if (positive && candidate.kind == FPFrameGenerationOutputCurrent)
            dispatch_async(dispatch_get_main_queue(), ^{
                if (atomic_load(&session->_invalidated) || atomic_load(&session->_failed) ||
                    atomic_load(&session->_suspended) ||
                    lifecycleGeneration != atomic_load(&session->_lifecycleGeneration)) return;
                session->_visible = YES;
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                session->_layer.hidden = NO;
                [CATransaction commit];
            });
    }];
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        /* Strong slot references keep IOSurfaces alive until the GPU has
         * finished even when the Wine context/session is already destroyed. */
        (void)previous.texture;
        (void)current.texture;
        FPWineD3DGLSession *session = weakSelf;
        if (!session) return;
        BOOL success = completed.status == MTLCommandBufferStatusCompleted;
        os_unfair_lock_lock(&session->_lock);
        --current.users;
        --previous.users;
        if (session->_writers) --session->_writers;
        FPFrameGenerationOutputCallbackResult writer =
            FPFrameGenerationRecordWriterCompleted(session->_state, candidate, success);
        for (NSUInteger index = 0; index < FP_FRAME_GENERATION_OUTPUT_JOIN_CAPACITY; ++index)
            if (session->_receipts[index].candidate.submissionID == candidate.submissionID)
            {
                session->_receipts[index].writerCompleted = YES;
                if (session->_receipts[index].presentationSeen)
                    memset(&session->_receipts[index], 0, sizeof(session->_receipts[index]));
                break;
            }
        if (midpoint)
        {
            if (success) FPFrameGenerationRecordGeneratedCompleted(session->_state, candidate.epoch);
            else FPFrameGenerationRecordGeneratedFailed(session->_state, candidate.epoch);
        }
        os_unfair_lock_unlock(&session->_lock);
        if (!success && writer.matched && !atomic_load(&session->_suspended) &&
            lifecycleGeneration == atomic_load(&session->_lifecycleGeneration))
            [session fail:"gl-output-command-failed"];
    }];
    [buffer presentDrawable:drawable];
    [buffer commit];
    [self report];
}

- (void)report
{
    double now = CACurrentMediaTime();
    os_unfair_lock_lock(&_lock);
    FPFrameGenerationTelemetry telemetry = FPFrameGenerationTelemetrySnapshotAtTime(_state, now);
    FPFrameGenerationRuntimeCounters counters = {0};
    counters.sessionIdentifier = _sessionIdentifier;
    counters.recordMonotonicTime = now;
    counters.captureSkippedBusy = _captureSkipped;
    counters.captureInFlight = (uint32_t)_pending.count;
    counters.maximumCaptureInFlight = _maximumCaptureInFlight;
    counters.capturePoolTextureCount = (uint32_t)_pool.count;
    counters.capturePoolAllocations = _poolAllocations;
    counters.capturePoolReleases = _poolReleases;
    counters.displayCommandBuffersOutstanding = _writers;
    counters.currentOutputCadenceHz = telemetry.currentOutputCadenceHz;
    counters.generatedCadenceHz = telemetry.generatedCadenceHz;
    BOOL write = now - _lastTelemetryTime >= FPTelemetryMinimumInterval;
    if (write) _lastTelemetryTime = now;
    BOOL hud = _frameCheck && now - _lastHudTime >= FPFrameCheckMinimumInterval;
    if (hud) _lastHudTime = now;
    os_unfair_lock_unlock(&_lock);
    if (write) FPEnqueueTelemetryRecord(telemetry, counters);
    if (hud) dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load(&self->_invalidated)) return;
        /* OpenGL has no public physical original-present callback. All three
         * displayed FPS labels below count actual Metal output receipts only. */
        self->_hud.string = telemetry.outputActive ? [NSString stringWithFormat:
            @"Original    %6.1f FPS\nGenerated   %6.1f FPS\nDisplayed   %6.1f FPS",
            telemetry.currentOutputCadenceHz, telemetry.generatedCadenceHz, telemetry.finalCadenceHz]
            : @"Original        -- FPS\nGenerated      0.0 FPS\nDisplayed       -- FPS";
    });
}
@end

static void *FPCreateOpenGLSessionV1(void *view, void *context,
    const FPD3DMetalFrameGenerationConfigurationV1 *configuration,
    char *failureReason, size_t failureReasonCapacity)
{
    if (!configuration || configuration->structureSize != sizeof(*configuration) ||
        configuration->abiVersion != 1 || configuration->frameCheckEnabled > 1 ||
        (configuration->targetFrameRate != 120 && configuration->targetFrameRate != 144 && configuration->targetFrameRate != 240) ||
        !view || !context || CGLGetCurrentContext() != context)
    {
        FPCopyFailureReason(failureReason, failureReasonCapacity, "gl-configuration-or-context-invalid");
        FPWriteStandaloneErrorTelemetry(configuration ? configuration->targetFrameRate : 0,
            "gl-configuration-or-context-invalid");
        return NULL;
    }
    if (![(__bridge id)view isKindOfClass:NSView.class])
    {
        FPCopyFailureReason(failureReason, failureReasonCapacity, "gl-source-view-invalid");
        return NULL;
    }
    GLint major = 0, minor = 0;
    /* WineD3D requests a core context. Query the version string first so a
     * legacy context does not receive invalid GL_MAJOR_VERSION queries. */
    const char *version = (const char *)glGetString(GL_VERSION);
    if (!version || sscanf(version, "%d.%d", &major, &minor) != 2 || major < 3 || (major == 3 && minor < 2))
    {
        FPCopyFailureReason(failureReason, failureReasonCapacity, "gl-3.2-sync-required");
        FPWriteStandaloneErrorTelemetry(configuration->targetFrameRate, "gl-3.2-sync-required");
        return NULL;
    }
    FPWineD3DGLSession *session = [[FPWineD3DGLSession alloc]
        initWithView:(__bridge NSView *)view context:context configuration:configuration];
    if (!session) FPCopyFailureReason(failureReason, failureReasonCapacity, "gl-session-create-failed");
    return (__bridge_retained void *)session;
}
static int FPBeforeOpenGLSwapV1(void *opaque, uint32_t width, uint32_t height)
{
    if (!opaque) return 0;
    @autoreleasepool { return [(__bridge FPWineD3DGLSession *)opaque beforeSwapWidth:width height:height]; }
}
static void FPDestroyOpenGLSessionV1(void *opaque)
{
    if (!opaque) return;
    FPWineD3DGLSession *session = CFBridgingRelease(opaque);
    [session invalidate];
}
const FPWineD3DOpenGLFrameGenerationProxyAPIV1 *FPWineD3DOpenGLFrameGenerationProxyGetAPIV1(void)
{
    static const FPWineD3DOpenGLFrameGenerationProxyAPIV1 api = {
        sizeof(FPWineD3DOpenGLFrameGenerationProxyAPIV1), 1,
        FPCreateOpenGLSessionV1, FPBeforeOpenGLSwapV1, FPDestroyOpenGLSessionV1
    };
    return &api;
}

#pragma clang diagnostic pop
