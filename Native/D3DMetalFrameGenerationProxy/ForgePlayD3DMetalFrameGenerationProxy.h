#ifndef FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY_H
#define FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FP_D3DMETAL_FRAME_GENERATION_PROXY_ABI_VERSION 1u

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

#ifdef __cplusplus
}
#endif

#endif
