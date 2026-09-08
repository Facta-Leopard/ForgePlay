/*
 * SPDX-FileCopyrightText: 2000 Alexandre Julliard
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Wine loader-compatible fixed Game Mode process host.
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 *
 * The address reservations, exported wine_main_preload_info contract, and
 * same-process __wine_main transition are derived from Wine 11.12
 * loader/main.c. Copyright 2000 Alexandre Julliard. This copy was converted
 * from LGPL-2.1-or-later to GPL-3.0-only under LGPL 2.1 section 3.
 * ForgePlay-specific identity, app-group, lease, and evidence code is
 * independently authored.
 */

#import "GameModeApplicationGroup.h"
#import "GameModeInheritedExecution.h"
#import "GameModeRuntimeIdentity.h"
#import "PrefixExecutionLease.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/mman.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#if !defined(__APPLE__) || !defined(__x86_64__)
#error "GameModeProcessHost is an x86_64 Rosetta component for Apple Silicon only"
#endif

/*
 * These zero-fill segments must be fixed by the linker before any framework
 * initializer runs. The explicit mmap in main then matches Wine's loader.
 */
__asm__(".zerofill WINE_RESERVE,WINE_RESERVE");
static char fp_wine_reserve[0x1fffff000]
    __attribute__((section("WINE_RESERVE, WINE_RESERVE")));

__asm__(".zerofill WINE_TOP_DOWN,WINE_TOP_DOWN");
static char fp_wine_top_down[0x001ff0000]
    __attribute__((section("WINE_TOP_DOWN, WINE_TOP_DOWN")));

struct wine_preload_info {
    void *addr;
    size_t size;
};

static const struct wine_preload_info fp_preload_info[] = {
    {fp_wine_reserve, sizeof(fp_wine_reserve)},
    {fp_wine_top_down, sizeof(fp_wine_top_down)},
    {NULL, 0},
};

const __attribute__((visibility("default"), used)) struct wine_preload_info
    *wine_main_preload_info = fp_preload_info;

static BOOL FPBuildIdentityAllowsExecution(void)
{
    return FORGEPLAY_GAME_MODE_HOST_RUNNABLE == 1;
}

static BOOL FPInitializeWineReservedAreas(void)
{
    /*
     * The zero-fill symbols are more than 2 GB away from __TEXT. Never
     * reference them directly from code: x86_64 RIP-relative fixups cannot
     * span that distance. The exported pointer lives beside __TEXT and its
     * table contains the linker-resolved absolute segment addresses, matching
     * Wine 11.12's loader contract.
     */
    const struct wine_preload_info *preloadInfo = wine_main_preload_info;
    if (!preloadInfo ||
        preloadInfo[0].addr != (void *)(uintptr_t)UINT64_C(0x1000) ||
        preloadInfo[0].size != (size_t)UINT64_C(0x1fffff000) ||
        preloadInfo[1].addr != (void *)(uintptr_t)UINT64_C(0x7ff000000000) ||
        preloadInfo[1].size != (size_t)UINT64_C(0x001ff0000) ||
        preloadInfo[2].addr != NULL || preloadInfo[2].size != 0) {
        return NO;
    }
    for (NSUInteger index = 0; preloadInfo[index].size != 0; index++) {
        void *mapped = mmap(preloadInfo[index].addr,
                            preloadInfo[index].size,
                            PROT_NONE,
                            MAP_FIXED | MAP_NORESERVE | MAP_PRIVATE | MAP_ANON,
                            -1,
                            0);
        if (mapped == MAP_FAILED || mapped != preloadInfo[index].addr) return NO;
    }
    return YES;
}

static NSString *FPFailureReasonCode(NSError *error, NSString *fallback)
{
    NSString *reason = error.userInfo[NSLocalizedFailureReasonErrorKey];
    if (![reason isKindOfClass:[NSString class]] || reason.length == 0) return fallback;
    return reason;
}

static int FPFail(FPGameModeApplicationGroup *group,
                  NSString *runIdentifier,
                  NSString *eventCode,
                  int exitCode)
{
    (void)[group recordEventCode:eventCode runID:runIdentifier];
    fprintf(stderr, "ForgePlay Game Mode process host: %s\n", eventCode.UTF8String);
    return exitCode;
}

static BOOL FPValidateInheritedArguments(int argc,
                                         char *argv[],
                                         NSURL *hostExecutableURL)
{
    if (argc < 2 || argc > 4096 || !argv) return NO;
    const char *expectedArgumentZero = hostExecutableURL.path.fileSystemRepresentation;
    if (!expectedArgumentZero || !argv[0] || strcmp(argv[0], expectedArgumentZero) != 0) {
        return NO;
    }
    for (int index = 0; index < argc; index++) {
        if (!argv[index] || strnlen(argv[index], 1024U * 1024U + 1U) > 1024U * 1024U) {
            return NO;
        }
    }
    return argv[argc] == NULL;
}

int main(int argc, char *argv[])
{
    if (!FPBuildIdentityAllowsExecution()) {
        fprintf(stderr, "ForgePlay Game Mode process host: compile_only_identity\n");
        return 78;
    }
    BOOL wineReservedAreasReady = FPInitializeWineReservedAreas();
    BOOL mainThreadReady = pthread_main_np();

    @autoreleasepool {
        NSError *runtimeError = nil;
        FPGameModeRuntimeIdentity * __attribute__((objc_precise_lifetime)) runtime =
            [FPGameModeRuntimeIdentity validatedIdentityWithError:&runtimeError];
        if (!runtime) {
            return FPFail(
                nil,
                nil,
                FPFailureReasonCode(runtimeError, @"runtime_validation_failed"),
                78
            );
        }
        if (!FPValidateInheritedArguments(argc, argv, runtime.hostExecutableURL)) {
            return FPFail(nil, nil, @"inherited_arguments_invalid", 64);
        }

        NSError *groupError = nil;
        FPGameModeApplicationGroup * __attribute__((objc_precise_lifetime)) group =
            [FPGameModeApplicationGroup validatedGroupWithError:&groupError];
        if (!group) {
            return FPFail(
                nil,
                nil,
                FPFailureReasonCode(groupError,
                                    @"application_group_validation_failed"),
                78
            );
        }
        BOOL hostStartedRecorded = [group recordEventCode:@"host_started" runID:nil];
        if (!hostStartedRecorded) {
            return FPFail(group, nil, @"evidence_write_failed", 74);
        }
        if (![group recordEventCode:@"runtime_identity_verified" runID:nil]) {
            return FPFail(group, nil, @"evidence_write_failed", 74);
        }
        if (!wineReservedAreasReady) {
            return FPFail(group, nil, @"wine_reservation_failed", 70);
        }
        if (!mainThreadReady) {
            return FPFail(group, nil, @"main_thread_required", 70);
        }

        NSError *executionError = nil;
        FPGameModeInheritedExecution * __attribute__((objc_precise_lifetime)) execution =
            [FPGameModeInheritedExecution validatedExecutionForRuntime:runtime
                                                      applicationGroup:group
                                                                 error:&executionError];
        if (!execution) {
            return FPFail(
                group,
                nil,
                FPFailureReasonCode(executionError,
                                    @"inherited_environment_invalid"),
                78
            );
        }
        if (![group recordEventCode:@"inherited_execution_verified"
                              runID:execution.runIdentifier]) {
            return FPFail(group,
                          execution.runIdentifier,
                          @"evidence_write_failed",
                          74);
        }

        NSError *leaseError = nil;
        FPPrefixExecutionLease * __attribute__((objc_precise_lifetime)) lease =
            [FPPrefixExecutionLease
                acquireInheritedSharedLeaseForPrefixURL:execution.prefixURL
                                     allowedContainerURL:group.containerURL
                                                  error:&leaseError];
        if (!lease) {
            return FPFail(
                group,
                execution.runIdentifier,
                FPFailureReasonCode(leaseError,
                                    @"prefix_execution_lock_failed"),
                75
            );
        }
        if (![group recordEventCode:@"prefix_execution_lease_acquired"
                              runID:execution.runIdentifier]) {
            return FPFail(group,
                          execution.runIdentifier,
                          @"evidence_write_failed",
                          74);
        }

        void *ntdll = dlopen(runtime.ntdllURL.path.fileSystemRepresentation, RTLD_NOW);
        if (!ntdll) {
            return FPFail(group,
                          execution.runIdentifier,
                          @"exact_ntdll_load_failed",
                          78);
        }
        void *wineMainSymbol = dlsym(ntdll, "__wine_main");
        void (*wineMain)(int, char **) = NULL;
        _Static_assert(sizeof(wineMain) == sizeof(wineMainSymbol),
                       "Wine function and data pointers must have equal size");
        memcpy(&wineMain, &wineMainSymbol, sizeof(wineMain));
        if (!wineMainSymbol || !wineMain) {
            return FPFail(group,
                          execution.runIdentifier,
                          @"wine_main_symbol_unavailable",
                          78);
        }

        if (![group recordEventCode:@"wine_main_entered"
                              runID:execution.runIdentifier]) {
            return FPFail(group,
                          execution.runIdentifier,
                          @"evidence_write_failed",
                          74);
        }
        wineMain(argc, argv);
        return FPFail(group,
                      execution.runIdentifier,
                      @"wine_main_returned_unexpectedly",
                      70);
    }
}
