/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 *
 * App-group and redacted evidence boundary for the fixed process host.
 */

#import "GameModeApplicationGroup.h"

#import "GameModeBuildIdentity.h"
#import "GameModeRuntimeIdentity.h"

#import <sys/file.h>
#import <sys/stat.h>
#import <libproc.h>
#import <pwd.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>

static NSError *FPApplicationGroupError(NSString *reasonCode)
{
    return [NSError errorWithDomain:FPGameModeHostErrorDomain
                               code:FPGameModeHostErrorInvalidApplicationGroup
                           userInfo:@{NSLocalizedFailureReasonErrorKey: reasonCode}];
}

static NSNumber *FPCurrentProcessStartedAtUnixMicroseconds(void)
{
    struct proc_bsdinfo info = {0};
    const int expectedSize = (int)sizeof(info);
    int copied = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0,
                              &info, expectedSize);
    if (copied != expectedSize || info.pbi_start_tvusec >= 1000000) return nil;
    uint64_t seconds = (uint64_t)info.pbi_start_tvsec;
    uint64_t microseconds = (uint64_t)info.pbi_start_tvusec;
    if (seconds > (UINT64_MAX - microseconds) / 1000000ULL) return nil;
    return @(seconds * 1000000ULL + microseconds);
}

static NSString *FPCanonicalGroupPath(NSString *path)
{
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *result = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:resolved
                                    length:strlen(resolved)];
    free(resolved);
    return result;
}

static NSURL *FPInheritedApplicationGroupContainerURL(NSString *identifier)
{
    NSURL *containerURL = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:identifier];
    if (containerURL) return containerURL;

    /*
     * containerURLForSecurityApplicationGroupIdentifier can consult the
     * executable's own code-signature dictionary even when the effective
     * sandbox was inherited. Resolve the same fixed macOS group-container
     * location from the kernel account home as a fallback, then rely on
     * canonical-path, owner, mode, and descriptor checks below. Do not trust
     * HOME or any inherited path value.
     */
    long suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX);
    if (suggestedSize < 1024 || suggestedSize > 1024 * 1024) {
        suggestedSize = 16 * 1024;
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)suggestedSize];
    struct passwd account = {0};
    struct passwd *result = NULL;
    if (getpwuid_r(geteuid(),
                   &account,
                   buffer.mutableBytes,
                   buffer.length,
                   &result) != 0 ||
        !result || !account.pw_dir || account.pw_dir[0] != '/') {
        return nil;
    }
    NSString *home = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:account.pw_dir
                                    length:strlen(account.pw_dir)];
    return [NSURL fileURLWithPath:
        [[home stringByAppendingPathComponent:@"Library/Group Containers"]
            stringByAppendingPathComponent:identifier]
                     isDirectory:YES];
}

BOOL FPPathIsContainedByDirectory(NSString *path, NSString *directoryPath)
{
    if ([path isEqualToString:directoryPath]) return YES;
    NSString *prefix = [directoryPath hasSuffix:@"/"]
        ? directoryPath
        : [directoryPath stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static BOOL FPValidateDirectoryDescriptor(int descriptor, BOOL privateDirectory)
{
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0 ||
        (status.st_mode & S_IFMT) != S_IFDIR ||
        status.st_uid != geteuid() ||
        (status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return NO;
    }
    return !privateDirectory || (status.st_mode & (S_IRWXG | S_IRWXO)) == 0;
}

static int FPOpenOrCreateDirectoryAt(int parentDescriptor,
                                     const char *name,
                                     BOOL privateDirectory)
{
    if (mkdirat(parentDescriptor, name, S_IRWXU) != 0 && errno != EEXIST) return -1;
    int descriptor = openat(parentDescriptor,
                            name,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return -1;
    if (!FPValidateDirectoryDescriptor(descriptor, privateDirectory)) {
        close(descriptor);
        errno = EPERM;
        return -1;
    }
    return descriptor;
}

static int FPOpenFixedDirectoryTree(int rootDescriptor,
                                    NSArray<NSString *> *components,
                                    BOOL finalDirectoryIsPrivate)
{
    int descriptor = dup(rootDescriptor);
    if (descriptor < 0) return -1;
    for (NSUInteger index = 0; index < components.count; index++) {
        NSString *component = components[index];
        BOOL privateDirectory = index + 1 == components.count
            ? finalDirectoryIsPrivate
            : NO;
        int child = FPOpenOrCreateDirectoryAt(descriptor,
                                              component.fileSystemRepresentation,
                                              privateDirectory);
        int savedError = errno;
        close(descriptor);
        if (child < 0) {
            errno = savedError;
            return -1;
        }
        descriptor = child;
    }
    return descriptor;
}

static BOOL FPValidateEventCode(NSString *eventCode)
{
    if (eventCode.length == 0 || eventCode.length > 96) return NO;
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        invalidCharacters = [[NSCharacterSet
            characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_-"]
            invertedSet];
    });
    return [eventCode rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static BOOL FPValidateScopeIdentifier(NSString *scopeIdentifier)
{
    if (scopeIdentifier.length != 16) return NO;
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        invalidCharacters = [[NSCharacterSet
            characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    });
    return [scopeIdentifier rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

@interface FPGameModeApplicationGroup ()

@property(nonatomic, strong, readwrite) NSString *identifier;
@property(nonatomic, strong, readwrite) NSURL *containerURL;
@property(nonatomic, strong, readwrite) NSURL *launchRequestStoreURL;
@property(nonatomic, strong, readwrite) NSURL *wineServerBaseURL;
@property(nonatomic, strong, readwrite) NSURL *evidenceFileURL;
@property(nonatomic) int evidenceDirectoryDescriptor;

@end

@implementation FPGameModeApplicationGroup

+ (instancetype)validatedGroupWithError:(NSError **)error
{
    NSString *expectedIdentifier = @FORGEPLAY_GAME_MODE_APPLICATION_GROUP;
    /*
     * Sandboxed hosts inherit ForgePlay's App Group while the non-sandboxed
     * direct Release host carries that one group in its own signature. The
     * fixed compiled identifier and a successful lookup prove access to the
     * intended narrow coordination container; descriptor checks below then
     * validate its on-disk identity. Product data remains outside this scope
     * for the direct Release profile.
     */
    NSURL *containerURL =
        FPInheritedApplicationGroupContainerURL(expectedIdentifier);
    NSString *canonicalContainer = FPCanonicalGroupPath(containerURL.path);
    if (!canonicalContainer) {
        if (error) *error = FPApplicationGroupError(@"application_group_container_unavailable");
        return nil;
    }

    int rootDescriptor = open(canonicalContainer.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rootDescriptor < 0 || !FPValidateDirectoryDescriptor(rootDescriptor, NO)) {
        if (rootDescriptor >= 0) close(rootDescriptor);
        if (error) *error = FPApplicationGroupError(@"application_group_container_unsafe");
        return nil;
    }

    NSArray<NSString *> *supportComponents = @[
        @"Library", @"Application Support", @"ForgePlay"
    ];
    int supportDescriptor = FPOpenFixedDirectoryTree(rootDescriptor,
                                                     supportComponents,
                                                     NO);
    if (supportDescriptor < 0) {
        close(rootDescriptor);
        if (error) *error = FPApplicationGroupError(@"application_group_support_root_failed");
        return nil;
    }
    int requestDescriptor = FPOpenOrCreateDirectoryAt(supportDescriptor,
                                                       "GameModeLaunchRequests",
                                                       YES);
    int evidenceDescriptor = FPOpenOrCreateDirectoryAt(supportDescriptor,
                                                        "GameModeProcessHostEvidence",
                                                        YES);
    close(supportDescriptor);

    NSArray<NSString *> *cacheComponents = @[
        @"Library", @"Caches", @"ForgePlay"
    ];
    int cacheDescriptor = FPOpenFixedDirectoryTree(rootDescriptor,
                                                   cacheComponents,
                                                   NO);
    int wineServerDescriptor = cacheDescriptor >= 0
        ? FPOpenOrCreateDirectoryAt(cacheDescriptor, "WineServer", YES)
        : -1;
    if (cacheDescriptor >= 0) close(cacheDescriptor);
    close(rootDescriptor);

    if (requestDescriptor < 0 || evidenceDescriptor < 0 || wineServerDescriptor < 0) {
        if (requestDescriptor >= 0) close(requestDescriptor);
        if (evidenceDescriptor >= 0) close(evidenceDescriptor);
        if (wineServerDescriptor >= 0) close(wineServerDescriptor);
        if (error) *error = FPApplicationGroupError(@"application_group_layout_failed");
        return nil;
    }
    close(requestDescriptor);
    close(wineServerDescriptor);

    FPGameModeApplicationGroup *group = [[self alloc] init];
    group.identifier = expectedIdentifier;
    group.containerURL = [NSURL fileURLWithPath:canonicalContainer isDirectory:YES];
    group.launchRequestStoreURL = [group.containerURL
        URLByAppendingPathComponent:
            @"Library/Application Support/ForgePlay/GameModeLaunchRequests"
                        isDirectory:YES];
    group.wineServerBaseURL = [group.containerURL
        URLByAppendingPathComponent:@"Library/Caches/ForgePlay/WineServer"
                        isDirectory:YES];
    group.evidenceFileURL = [group.containerURL
        URLByAppendingPathComponent:
            @"Library/Application Support/ForgePlay/GameModeProcessHostEvidence/GameModeProcessHost-v1.jsonl"
                        isDirectory:NO];
    group.evidenceDirectoryDescriptor = evidenceDescriptor;
    return group;
}

- (instancetype)init
{
    self = [super init];
    if (self) _evidenceDirectoryDescriptor = -1;
    return self;
}

- (void)dealloc
{
    if (_evidenceDirectoryDescriptor >= 0) close(_evidenceDirectoryDescriptor);
}

- (NSURL *)prepareWineServerRootWithScopeIdentifier:(NSString *)scopeIdentifier
                                               error:(NSError **)error
{
    if (!FPValidateScopeIdentifier(scopeIdentifier)) {
        if (error) *error = FPApplicationGroupError(@"wine_server_scope_invalid");
        return nil;
    }
    int baseDescriptor = open(self.wineServerBaseURL.path.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (baseDescriptor < 0 || !FPValidateDirectoryDescriptor(baseDescriptor, YES)) {
        if (baseDescriptor >= 0) close(baseDescriptor);
        if (error) *error = FPApplicationGroupError(@"wine_server_root_unsafe");
        return nil;
    }
    int scopeDescriptor = FPOpenOrCreateDirectoryAt(baseDescriptor,
                                                     scopeIdentifier.fileSystemRepresentation,
                                                     YES);
    close(baseDescriptor);
    if (scopeDescriptor < 0) {
        if (error) *error = FPApplicationGroupError(@"wine_server_scope_unavailable");
        return nil;
    }
    close(scopeDescriptor);
    return [self.wineServerBaseURL URLByAppendingPathComponent:scopeIdentifier
                                                   isDirectory:YES];
}

- (BOOL)recordEventCode:(NSString *)eventCode runID:(NSString *)runIdentifier
{
    if (_evidenceDirectoryDescriptor < 0 || !FPValidateEventCode(eventCode)) return NO;
    int descriptor = openat(_evidenceDirectoryDescriptor,
                            "GameModeProcessHost-v1.jsonl",
                            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                            S_IRUSR | S_IWUSR);
    if (descriptor < 0) return NO;
    if (flock(descriptor, LOCK_EX) != 0) {
        close(descriptor);
        return NO;
    }

    struct stat status = {0};
    if (fstat(descriptor, &status) != 0 ||
        (status.st_mode & S_IFMT) != S_IFREG || status.st_nlink != 1 ||
        status.st_uid != geteuid() ||
        (status.st_mode & 0777) != (S_IRUSR | S_IWUSR)) {
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        return NO;
    }

    NSNumber *processStartedAt = FPCurrentProcessStartedAtUnixMicroseconds();
    if (!processStartedAt) {
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        return NO;
    }
    NSMutableDictionary *record = [@{
        @"schema_version": @1,
        @"producer": @"game-mode-process-host",
        @"event_code": eventCode,
        @"recorded_at_unix_milliseconds":
            @((long long)([NSDate date].timeIntervalSince1970 * 1000.0)),
        @"darwin_pid": @(getpid()),
        @"process_started_at_unix_microseconds": processStartedAt,
        @"bound_runtime_identifier": @FORGEPLAY_GAME_MODE_RUNTIME_IDENTIFIER,
        @"bound_runtime_build_fingerprint":
            @FORGEPLAY_GAME_MODE_RUNTIME_BUILD_FINGERPRINT,
    } mutableCopy];
    if (runIdentifier.length > 0) record[@"run_identifier"] = runIdentifier;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json || json.length > 2048) {
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        return NO;
    }

    NSMutableData *line = [json mutableCopy];
    const char newline = '\n';
    [line appendBytes:&newline length:1];
    const uint8_t *bytes = line.bytes;
    NSUInteger written = 0;
    while (written < line.length) {
        ssize_t count = write(descriptor, bytes + written, line.length - written);
        if (count > 0) {
            written += (NSUInteger)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }
    BOOL completed = written == line.length && fsync(descriptor) == 0;
    (void)flock(descriptor, LOCK_UN);
    close(descriptor);
    return completed;
}

@end
