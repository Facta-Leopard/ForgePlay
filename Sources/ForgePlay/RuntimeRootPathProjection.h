#ifndef FORGEPLAY_RUNTIME_ROOT_PATH_PROJECTION_H
#define FORGEPLAY_RUNTIME_ROOT_PATH_PROJECTION_H

#include <stddef.h>

// Returns zero on success or an errno value on failure.
int ForgePlayRuntimeRootPathProjectionCopyCurrentPath(
    int descriptor,
    char *destination,
    size_t capacity
);

#endif
