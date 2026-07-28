#ifndef FORGEPLAY_EXTERNAL_STORAGE_ACCESS_BRIDGE_H
#define FORGEPLAY_EXTERNAL_STORAGE_ACCESS_BRIDGE_H

#include <stddef.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(__GNUC__)
#define FP_EXTERNAL_STORAGE_ACCESS_BRIDGE_EXPORT __attribute__((visibility("default")))
#else
#define FP_EXTERNAL_STORAGE_ACCESS_BRIDGE_EXPORT
#endif

enum {
    FPExternalStorageGrantActivationSucceeded = 0,
    FPExternalStorageGrantActivationFailed = 1,
};

/// Activates the bounded external-storage grant manifest carried by the
/// ForgePlay launch environment.
///
/// A return value of `FPExternalStorageGrantActivationSucceeded` means either
/// that no grant environment was present or that every bookmark was validated
/// and retained. Any nonzero result is fail-closed. `reasonBuffer`, when
/// supplied, receives only a bounded reason code and never manifest or bookmark
/// content.
FP_EXTERNAL_STORAGE_ACCESS_BRIDGE_EXPORT
int FPActivateExternalStorageGrantManifest(char *reasonBuffer, size_t reasonCapacity);

#if defined(__cplusplus)
}
#endif

#endif
