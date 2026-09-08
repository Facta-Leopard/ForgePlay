/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 *
 * Strict inherited environment boundary for a Steam-created Wine child that
 * execs the fixed host before mapping its PE image.
 */

#import "GameModeInheritedExecution.h"

#import "GameModeApplicationGroup.h"
#import "GameModeBuildIdentity.h"
#import "GameModeRuntimeIdentity.h"

#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>

static NSError *FPInheritedExecutionError(NSString *reasonCode)
{
    return [NSError errorWithDomain:FPGameModeHostErrorDomain
                               code:FPGameModeHostErrorEnvironmentFailed
                           userInfo:@{NSLocalizedFailureReasonErrorKey: reasonCode}];
}

static NSString *FPRequiredEnvironmentValue(const char *key, NSUInteger maximumBytes)
{
    const char *value = getenv(key);
    if (!value) return nil;
    size_t length = strnlen(value, maximumBytes + 1U);
    if (length == 0 || length > maximumBytes) return nil;
    return [[NSString alloc] initWithBytes:value
                                   length:length
                                 encoding:NSUTF8StringEncoding];
}

static NSString *FPCanonicalInheritedPath(NSString *path)
{
    if (![path hasPrefix:@"/"]) return nil;
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *result = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:resolved
                                    length:strlen(resolved)];
    free(resolved);
    return result;
}

static BOOL FPValidateCanonicalDirectory(NSString *path)
{
    NSString *canonical = FPCanonicalInheritedPath(path);
    if (!canonical || ![canonical isEqualToString:path]) return NO;
    struct stat status = {0};
    return lstat(path.fileSystemRepresentation, &status) == 0 &&
        (status.st_mode & S_IFMT) == S_IFDIR;
}

static BOOL FPValidateExactCanonicalPathEnvironment(const char *key,
                                                    NSURL *expectedURL)
{
    NSString *value = FPRequiredEnvironmentValue(key, PATH_MAX);
    NSString *canonical = value ? FPCanonicalInheritedPath(value) : nil;
    return canonical && [value isEqualToString:canonical] &&
        [canonical isEqualToString:expectedURL.path];
}

static NSString *FPPrefixScopeIdentifier(NSString *canonicalPrefixPath)
{
    NSData *data = [canonicalPrefixPath dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:16];
    for (NSUInteger index = 0; index < 8; index++) {
        [value appendFormat:@"%02x", digest[index]];
    }
    return value;
}

static BOOL FPValidateRunIdentifier(NSString *value)
{
    if (!value) return NO;
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:value];
    return identifier && [identifier.UUIDString.lowercaseString isEqualToString:value];
}

@interface FPGameModeInheritedExecution ()

@property(nonatomic, strong, readwrite) NSURL *prefixURL;
@property(nonatomic, strong, readwrite) NSURL *wineServerRootURL;
@property(nonatomic, strong, readwrite) NSString *wineMachServiceName;
@property(nonatomic, strong, readwrite) NSString *runIdentifier;

@end


@implementation FPGameModeInheritedExecution

+ (instancetype)validatedExecutionForRuntime:(FPGameModeRuntimeIdentity *)runtime
                             applicationGroup:(FPGameModeApplicationGroup *)applicationGroup
                                        error:(NSError **)error
{
    NSString *enabled = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_ENABLED", 8);
    NSString *mode = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_MODE", 32);
    NSString *steamGameProcess = FPRequiredEnvironmentValue(
        "FORGEPLAY_STEAM_GAME_PROCESS", 8);
    NSString *eligibleGameTarget = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_DIRECT_TARGET", 8);
    NSString *hostRouted = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_ROUTED", 8);
    NSString *wineLoaderNoExec = FPRequiredEnvironmentValue(
        "WINELOADERNOEXEC", 8);
    if (![enabled isEqualToString:@"1"] || ![mode isEqualToString:@"steam-child"]) {
        if (error) *error = FPInheritedExecutionError(
            @"launchservices_stage0a_request_execution_unsupported");
        return nil;
    }
    if (![steamGameProcess isEqualToString:@"1"] ||
        ![eligibleGameTarget isEqualToString:@"1"] ||
        ![hostRouted isEqualToString:@"1"]) {
        if (error) *error = FPInheritedExecutionError(
            @"game_mode_target_environment_invalid");
        return nil;
    }
    if (![wineLoaderNoExec isEqualToString:@"1"]) {
        if (error) *error = FPInheritedExecutionError(
            @"wine_loader_noexec_environment_invalid");
        return nil;
    }

    NSString *bundleIdentifier = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER", 255);
    NSString *hostExecutableSHA256 = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_EXECUTABLE_SHA256", 64);
    NSString *runIdentifier = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_RUN_ID", 64);
    NSString *evidencePath = FPRequiredEnvironmentValue(
        "FORGEPLAY_GAME_MODE_HOST_EVIDENCE_FILE", PATH_MAX);
    if (![bundleIdentifier isEqualToString:@FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER] ||
        ![hostExecutableSHA256 isEqualToString:runtime.hostExecutableSHA256] ||
        !FPValidateRunIdentifier(runIdentifier) ||
        ![evidencePath isEqualToString:applicationGroup.evidenceFileURL.path] ||
        ![evidencePath hasPrefix:@"/"]) {
        if (error) *error = FPInheritedExecutionError(@"host_environment_identity_mismatch");
        return nil;
    }

    if (!FPValidateExactCanonicalPathEnvironment(
            "FORGEPLAY_GAME_MODE_HOST_EXECUTABLE", runtime.hostExecutableURL) ||
        !FPValidateExactCanonicalPathEnvironment(
            "FORGEPLAY_GAME_MODE_HOST_NTDLL", runtime.ntdllURL) ||
        !FPValidateExactCanonicalPathEnvironment("WINELOADER", runtime.wineLoaderURL) ||
        !FPValidateExactCanonicalPathEnvironment("WINESERVER", runtime.wineServerURL)) {
        if (error) *error = FPInheritedExecutionError(@"host_runtime_path_environment_mismatch");
        return nil;
    }

    NSString *prefixPath = FPRequiredEnvironmentValue("WINEPREFIX", PATH_MAX);
    NSString *canonicalPrefixPath = prefixPath
        ? FPCanonicalInheritedPath(prefixPath)
        : nil;
    if (!canonicalPrefixPath || ![prefixPath isEqualToString:canonicalPrefixPath] ||
        !FPValidateCanonicalDirectory(canonicalPrefixPath)) {
        if (error) *error = FPInheritedExecutionError(@"wineprefix_environment_invalid");
        return nil;
    }

    NSString *scopeIdentifier = FPPrefixScopeIdentifier(canonicalPrefixPath);
    NSError *serverRootError = nil;
    NSURL *expectedWineServerRoot = [applicationGroup
        prepareWineServerRootWithScopeIdentifier:scopeIdentifier
                                           error:&serverRootError];
    NSString *wineServerRoot = FPRequiredEnvironmentValue("WINE_SERVER_ROOT", PATH_MAX);
    NSString *canonicalWineServerRoot = wineServerRoot
        ? FPCanonicalInheritedPath(wineServerRoot)
        : nil;
    NSString *expectedMachServiceName = [NSString stringWithFormat:
        @"%@.wineserver.%@", applicationGroup.identifier, scopeIdentifier];
    NSString *machServiceName = FPRequiredEnvironmentValue(
        "WINE_MACH_SERVICE_NAME", 255);
    if (!expectedWineServerRoot ||
        ![wineServerRoot isEqualToString:canonicalWineServerRoot] ||
        ![canonicalWineServerRoot isEqualToString:expectedWineServerRoot.path] ||
        ![machServiceName isEqualToString:expectedMachServiceName]) {
        if (error) {
            *error = serverRootError ? serverRootError : FPInheritedExecutionError(
                @"wine_server_environment_mismatch");
        }
        return nil;
    }

    FPGameModeInheritedExecution *execution = [[self alloc] init];
    execution.prefixURL = [NSURL fileURLWithPath:canonicalPrefixPath isDirectory:YES];
    execution.wineServerRootURL = expectedWineServerRoot;
    execution.wineMachServiceName = expectedMachServiceName;
    execution.runIdentifier = runIdentifier;
    return execution;
}

@end
