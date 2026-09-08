/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 *
 * Cross-exec shared prefix lease. The descriptor intentionally does not carry
 * FD_CLOEXEC: it must survive Wine's same-session process transitions.
 */

#import "PrefixExecutionLease.h"

#import "GameModeApplicationGroup.h"
#import "GameModeRuntimeIdentity.h"

#import <CommonCrypto/CommonDigest.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

NSString *const FPGameModePrefixExecutionLockEnvironmentKey =
    @"FORGEPLAY_PREFIX_EXECUTION_LOCK";

static const NSUInteger FPMaximumLeaseMetadataBytes = 1024;

static NSError *FPLeaseError(NSString *reasonCode)
{
    return [NSError errorWithDomain:FPGameModeHostErrorDomain
                               code:FPGameModeHostErrorEnvironmentFailed
                           userInfo:@{NSLocalizedFailureReasonErrorKey: reasonCode}];
}

static NSString *FPCanonicalLeasePath(NSString *path)
{
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *result = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:resolved
                                    length:strlen(resolved)];
    free(resolved);
    return result;
}

static BOOL FPLeaseStatusesMatch(const struct stat *initial, const struct stat *final)
{
    return initial->st_dev == final->st_dev &&
        initial->st_ino == final->st_ino &&
        initial->st_size == final->st_size &&
        initial->st_mtimespec.tv_sec == final->st_mtimespec.tv_sec &&
        initial->st_mtimespec.tv_nsec == final->st_mtimespec.tv_nsec;
}

static NSString *FPExpectedLeasePath(NSString *canonicalPrefixPath,
                                     NSString *canonicalContainerPath)
{
    NSString *normalizedPrefix = [[canonicalPrefixPath
        precomposedStringWithCanonicalMapping]
        lowercaseStringWithLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSData *identityData = [[@"prefix=" stringByAppendingString:normalizedPrefix]
        dataUsingEncoding:NSUTF8StringEncoding];
    if (!identityData) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(identityData.bytes, (CC_LONG)identityData.length, digest);
    NSMutableString *digestString =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [digestString appendFormat:@"%02x", digest[index]];
    }
    NSString *fileName = [NSString stringWithFormat:
        @"prefix-execution-%@.lock", digestString];
    return [[canonicalContainerPath
        stringByAppendingPathComponent:@"Library/Application Support/ForgePlay/OperationLocks"]
        stringByAppendingPathComponent:fileName];
}

@interface FPPrefixExecutionLease ()

@property(nonatomic, strong, readwrite) NSURL *lockURL;
@property(nonatomic) int descriptor;

@end


@implementation FPPrefixExecutionLease

+ (instancetype)acquireInheritedSharedLeaseForPrefixURL:(NSURL *)prefixURL
                                      allowedContainerURL:(NSURL *)containerURL
                                                   error:(NSError **)error
{
    const char *environmentValue = getenv(FPGameModePrefixExecutionLockEnvironmentKey.UTF8String);
    if (!environmentValue || environmentValue[0] != '/' ||
        strnlen(environmentValue, PATH_MAX + 1U) > PATH_MAX) {
        if (error) *error = FPLeaseError(@"prefix_execution_lock_missing_or_invalid");
        return nil;
    }

    NSString *suppliedPath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:environmentValue
                                    length:strlen(environmentValue)];
    if (!suppliedPath) {
        if (error) *error = FPLeaseError(@"prefix_execution_lock_missing_or_invalid");
        return nil;
    }
    NSString *canonicalLockPath = FPCanonicalLeasePath(suppliedPath);
    NSString *canonicalPrefixPath = FPCanonicalLeasePath(prefixURL.path);
    NSString *canonicalContainerPath = FPCanonicalLeasePath(containerURL.path);
    NSString *expectedLockPath = canonicalPrefixPath && canonicalContainerPath
        ? FPExpectedLeasePath(canonicalPrefixPath, canonicalContainerPath)
        : nil;
    if (!canonicalLockPath || !canonicalPrefixPath || !canonicalContainerPath ||
        ![canonicalLockPath isEqualToString:suppliedPath] ||
        !FPPathIsContainedByDirectory(canonicalLockPath, canonicalContainerPath) ||
        ![canonicalLockPath isEqualToString:expectedLockPath]) {
        if (error) *error = FPLeaseError(@"prefix_execution_lock_scope_invalid");
        return nil;
    }

    struct stat prefixStatus = {0};
    if (lstat(canonicalPrefixPath.fileSystemRepresentation, &prefixStatus) != 0 ||
        (prefixStatus.st_mode & S_IFMT) != S_IFDIR) {
        if (error) *error = FPLeaseError(@"prefix_execution_lock_prefix_invalid");
        return nil;
    }

    int descriptor = open(canonicalLockPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) {
        if (error) *error = FPLeaseError(@"prefix_execution_lock_open_failed");
        return nil;
    }

    int descriptorFlags = fcntl(descriptor, F_GETFD);
    if (descriptorFlags < 0 ||
        fcntl(descriptor, F_SETFD, descriptorFlags & ~FD_CLOEXEC) < 0) {
        close(descriptor);
        if (error) *error = FPLeaseError(@"prefix_execution_lock_inheritance_failed");
        return nil;
    }

    if (flock(descriptor, LOCK_SH | LOCK_NB) != 0) {
        int lockError = errno;
        close(descriptor);
        if (error) {
            *error = FPLeaseError(
                lockError == EWOULDBLOCK || lockError == EAGAIN
                    ? @"prefix_execution_lock_conflict"
                    : @"prefix_execution_lock_acquire_failed");
        }
        return nil;
    }

    struct stat initialStatus = {0};
    if (fstat(descriptor, &initialStatus) != 0 ||
        (initialStatus.st_mode & S_IFMT) != S_IFREG ||
        initialStatus.st_nlink != 1 || initialStatus.st_uid != geteuid() ||
        (initialStatus.st_mode & 0777) != (S_IRUSR | S_IWUSR) ||
        initialStatus.st_size <= 0 ||
        (uint64_t)initialStatus.st_size > FPMaximumLeaseMetadataBytes) {
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        if (error) *error = FPLeaseError(@"prefix_execution_lock_file_unsafe");
        return nil;
    }

    NSMutableData *metadata = [NSMutableData dataWithLength:(NSUInteger)initialStatus.st_size];
    NSUInteger totalRead = 0;
    while (totalRead < metadata.length) {
        ssize_t count = pread(descriptor,
                              (uint8_t *)metadata.mutableBytes + totalRead,
                              metadata.length - totalRead,
                              (off_t)totalRead);
        if (count > 0) {
            totalRead += (NSUInteger)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }

    struct stat finalStatus = {0};
    if (totalRead != metadata.length || fstat(descriptor, &finalStatus) != 0 ||
        !FPLeaseStatusesMatch(&initialStatus, &finalStatus)) {
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        if (error) *error = FPLeaseError(@"prefix_execution_lock_changed_during_read");
        return nil;
    }

    NSString *expectedMetadata = [NSString stringWithFormat:
        @"FORGEPLAY_PREFIX_EXECUTION_LEASE_V1\ndevice=%llu\ninode=%llu\n",
        (unsigned long long)prefixStatus.st_dev,
        (unsigned long long)prefixStatus.st_ino];
    NSData *expectedData = [expectedMetadata dataUsingEncoding:NSUTF8StringEncoding];
    struct stat finalPrefixStatus = {0};
    if (lstat(canonicalPrefixPath.fileSystemRepresentation, &finalPrefixStatus) != 0 ||
        (finalPrefixStatus.st_mode & S_IFMT) != S_IFDIR ||
        finalPrefixStatus.st_dev != prefixStatus.st_dev ||
        finalPrefixStatus.st_ino != prefixStatus.st_ino ||
        ![metadata isEqualToData:expectedData]) {
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        if (error) *error = FPLeaseError(@"prefix_execution_lock_metadata_mismatch");
        return nil;
    }

    FPPrefixExecutionLease *lease = [[self alloc] init];
    lease.lockURL = [NSURL fileURLWithPath:canonicalLockPath isDirectory:NO];
    lease.descriptor = descriptor;
    return lease;
}

- (instancetype)init
{
    self = [super init];
    if (self) _descriptor = -1;
    return self;
}

- (void)dealloc
{
    if (_descriptor >= 0) {
        (void)flock(_descriptor, LOCK_UN);
        close(_descriptor);
    }
}

@end
