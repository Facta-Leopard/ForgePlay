#ifndef FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY_H
#define FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FP_D3DMETAL_FRAME_GENERATION_PROXY_ABI_VERSION 1u

/* The V1 symbol and type names are retained for deployed Wine compatibility.
 * The interface itself accepts any explicitly enabled renderer using Wine's
 * owning NSView/CAMetalLayer and public MTLCommandBuffer presentation boundary.
 * Backend selection alone is never permission to create a session: callers
 * must retain the default-OFF configuration gate before invoking createSession.
 * A renderer that presents directly from a scheduled handler must first supply
 * a pre-commit drawable/command-buffer binding through its owning bridge. */
typedef struct FPD3DMetalFrameGenerationConfigurationV1
{
    uint32_t structureSize;
    uint32_t abiVersion;
    uint32_t targetFrameRate;
    uint32_t frameCheckEnabled;
} FPD3DMetalFrameGenerationConfigurationV1;

typedef struct FPD3DMetalFrameGenerationProxyAPIV1
{
    uint32_t structureSize;
    uint32_t abiVersion;
    void *(*createSession)(
        void *owningMetalView,
        void *metalDevice,
        const FPD3DMetalFrameGenerationConfigurationV1 *configuration,
        void **sourceMetalLayer,
        char *failureReason,
        size_t failureReasonCapacity
    );
    void (*destroySession)(void *session);
} FPD3DMetalFrameGenerationProxyAPIV1;

__attribute__((visibility("default")))
const FPD3DMetalFrameGenerationProxyAPIV1 *
FPD3DMetalFrameGenerationProxyGetAPIV1(void);

/* Optional pre-commit adapter for renderers whose original scheduled handler
 * calls MTLDrawable.present directly. Pass the exact CAMetalDrawable and its
 * uncommitted MTLCommandBuffer as borrowed Objective-C objects. A nonzero
 * result means an already-enabled session accepted the binding; it does not
 * mean capture, generation, or presentation succeeded. Zero is fail-open for
 * nil, unknown drawables, disabled sessions, committed buffers, or capacity.
 * This neither creates a session nor presents/commits the renderer's objects. */
__attribute__((visibility("default")))
int FPD3DMetalFrameGenerationProxyBindSourceDrawableV1(
    void *sourceDrawable,
    void *sourceCommandBuffer
);

/* Separate optional ABI: the caller retains its original OpenGL drawable and
 * always performs its ordinary swap. beforeSwap must run with that exact CGL
 * context current, immediately before the swap, with backing-pixel dimensions.
 * It never reports physical source presentation. A zero return exposes the
 * original GL surface; destruction is valid on any thread after swaps stop. */
typedef struct FPWineD3DOpenGLFrameGenerationProxyAPIV1
{
    uint32_t structureSize;
    uint32_t abiVersion;
    void *(*createSession)(void *owningGLView, void *cglContext,
        const FPD3DMetalFrameGenerationConfigurationV1 *configuration,
        char *failureReason, size_t failureReasonCapacity);
    int (*beforeSwap)(void *session, uint32_t width, uint32_t height);
    void (*destroySession)(void *session);
} FPWineD3DOpenGLFrameGenerationProxyAPIV1;

__attribute__((visibility("default")))
const FPWineD3DOpenGLFrameGenerationProxyAPIV1 *
FPWineD3DOpenGLFrameGenerationProxyGetAPIV1(void);

#ifdef __cplusplus
}
#endif

#endif
