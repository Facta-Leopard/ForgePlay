#import "ExternalStorageAccessBridge.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "ExternalStorageAccessBridge is an x86_64 Rosetta/Wine process component"
#endif

static NSString *const FPGrantFileEnvironmentKey =
    @"FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE";
static NSString *const FPGrantSHA256EnvironmentKey =
    @"FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256";
static NSString *const FPGrantRunIdentifierEnvironmentKey =
    @"FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID";
static NSString *const FPGrantBridgeEnvironmentKey =
    @"FORGEPLAY_EXTERNAL_STORAGE_BRIDGE";
static NSString *const FPGrantProducer = @"forgeplay-external-storage-grant";

static const NSUInteger FPMaximumManifestBytes = 512U * 1024U;
static const NSUInteger FPMaximumGrantEntries = 32U;
static const char FPImageAddressAnchor = 0;

static NSLock *FPActivationLock;
static NSMutableArray<NSURL *> *FPRetainedGrantURLs;
static NSString *FPActivatedRunIdentifier;
static NSData *FPActivatedManifestDigest;

static void FPInitializeActivationState(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FPActivationLock = [[NSLock alloc] init];
        FPRetainedGrantURLs = [[NSMutableArray alloc] initWithCapacity:FPMaximumGrantEntries];
    });
}

static void FPSetReason(char *buffer, size_t capacity, const char *reason)
{
    if (!buffer || capacity == 0) {
        return;
    }

    const char *safeReason = reason ? reason : "activation_failed";
    size_t sourceLength = strlen(safeReason);
    size_t copyLength = sourceLength < capacity - 1 ? sourceLength : capacity - 1;
    if (copyLength > 0) {
        memcpy(buffer, safeReason, copyLength);
    }
    buffer[copyLength] = '\0';
}

static int FPFail(char *reasonBuffer, size_t reasonCapacity, const char *reason)
{
    FPSetReason(reasonBuffer, reasonCapacity, reason);
    return FPExternalStorageGrantActivationFailed;
}

static BOOL FPDictionaryHasExactKeys(NSDictionary *dictionary, NSArray<NSString *> *keys)
{
    if (dictionary.count != keys.count) {
        return NO;
    }
    NSSet *actualKeys = [NSSet setWithArray:dictionary.allKeys];
    NSSet *expectedKeys = [NSSet setWithArray:keys];
    return [actualKeys isEqualToSet:expectedKeys];
}

static BOOL FPJSONInteger(id value, long long *result)
{
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }

    CFNumberRef number = (__bridge CFNumberRef)value;
    if (CFGetTypeID(number) == CFBooleanGetTypeID() || CFNumberIsFloatType(number)) {
        return NO;
    }

    long long converted = 0;
    if (!CFNumberGetValue(number, kCFNumberLongLongType, &converted)) {
        return NO;
    }
    if (result) {
        *result = converted;
    }
    return YES;
}

static BOOL FPPathFitsFileSystemRepresentation(NSString *path)
{
    const char *representation = path.fileSystemRepresentation;
    return representation && strnlen(representation, PATH_MAX) < PATH_MAX;
}

static NSString *FPCanonicalExistingPath(NSString *path,
                                         mode_t requiredType,
                                         BOOL requireCanonicalInput,
                                         struct stat *status,
                                         const char **reason)
{
    if (![path isKindOfClass:[NSString class]] ||
        path.length == 0 ||
        !path.isAbsolutePath ||
        !FPPathFitsFileSystemRepresentation(path)) {
        if (reason) *reason = "path_invalid";
        return nil;
    }

    const char *fileSystemPath = path.fileSystemRepresentation;
    struct stat originalStatus = {0};
    if (lstat(fileSystemPath, &originalStatus) != 0) {
        if (reason) *reason = "path_unavailable";
        return nil;
    }
    if (S_ISLNK(originalStatus.st_mode) ||
        (originalStatus.st_mode & S_IFMT) != requiredType) {
        if (reason) *reason = "path_type_invalid";
        return nil;
    }

    char resolvedPath[PATH_MAX] = {0};
    if (!realpath(fileSystemPath, resolvedPath)) {
        if (reason) *reason = "path_canonicalization_failed";
        return nil;
    }
    NSString *canonicalPath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:resolvedPath
                                    length:strlen(resolvedPath)];
    if (!canonicalPath || canonicalPath.length == 0) {
        if (reason) *reason = "path_canonicalization_failed";
        return nil;
    }
    if (requireCanonicalInput && ![path isEqualToString:canonicalPath]) {
        if (reason) *reason = "path_not_canonical";
        return nil;
    }

    struct stat canonicalStatus = {0};
    if (lstat(resolvedPath, &canonicalStatus) != 0 ||
        S_ISLNK(canonicalStatus.st_mode) ||
        (canonicalStatus.st_mode & S_IFMT) != requiredType ||
        canonicalStatus.st_dev != originalStatus.st_dev ||
        canonicalStatus.st_ino != originalStatus.st_ino) {
        if (reason) *reason = "path_identity_changed";
        return nil;
    }
    if (status) {
        *status = canonicalStatus;
    }
    return canonicalPath;
}

static BOOL FPValidateLoadedBridgePath(NSString *declaredBridgePath,
                                       const char **reason)
{
    Dl_info imageInfo = {0};
    if (dladdr(&FPImageAddressAnchor, &imageInfo) == 0 || !imageInfo.dli_fname) {
        if (reason) *reason = "bridge_image_unavailable";
        return NO;
    }

    NSString *loadedBridgePath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:imageInfo.dli_fname
                                    length:strlen(imageInfo.dli_fname)];
    if (!loadedBridgePath ||
        ![[declaredBridgePath stringByStandardizingPath]
            isEqualToString:[loadedBridgePath stringByStandardizingPath]]) {
        if (reason) *reason = "bridge_path_mismatch";
        return NO;
    }

    struct stat declaredStatus = {0};
    struct stat loadedStatus = {0};
    NSString *declaredCanonicalPath = FPCanonicalExistingPath(
        declaredBridgePath,
        S_IFREG,
        NO,
        &declaredStatus,
        reason
    );
    NSString *loadedCanonicalPath = FPCanonicalExistingPath(
        loadedBridgePath,
        S_IFREG,
        NO,
        &loadedStatus,
        reason
    );
    if (!declaredCanonicalPath ||
        !loadedCanonicalPath ||
        ![declaredCanonicalPath isEqualToString:loadedCanonicalPath] ||
        declaredStatus.st_dev != loadedStatus.st_dev ||
        declaredStatus.st_ino != loadedStatus.st_ino) {
        if (reason && !*reason) *reason = "bridge_identity_mismatch";
        return NO;
    }
    return YES;
}

static BOOL FPManifestStatusIsSafe(const struct stat *status)
{
    static const mode_t expectedPermissions = S_IRUSR | S_IWUSR;
    static const mode_t permissionMask = S_IRWXU | S_IRWXG | S_IRWXO;
    return status &&
        S_ISREG(status->st_mode) &&
        !S_ISLNK(status->st_mode) &&
        status->st_uid == geteuid() &&
        (status->st_mode & permissionMask) == expectedPermissions &&
        status->st_nlink == 1;
}

static NSData *FPReadManifest(NSString *manifestPath, const char **reason)
{
    if (![manifestPath isKindOfClass:[NSString class]] ||
        manifestPath.length == 0 ||
        !manifestPath.isAbsolutePath ||
        !FPPathFitsFileSystemRepresentation(manifestPath)) {
        if (reason) *reason = "manifest_path_invalid";
        return nil;
    }

    const char *fileSystemPath = manifestPath.fileSystemRepresentation;
    struct stat pathStatus = {0};
    if (lstat(fileSystemPath, &pathStatus) != 0) {
        if (reason) *reason = "manifest_unavailable";
        return nil;
    }
    if (!FPManifestStatusIsSafe(&pathStatus)) {
        if (reason) *reason = "manifest_metadata_invalid";
        return nil;
    }
    if (pathStatus.st_size < 0 ||
        (uint64_t)pathStatus.st_size > (uint64_t)FPMaximumManifestBytes) {
        if (reason) *reason = "manifest_size_invalid";
        return nil;
    }

    int descriptor = open(fileSystemPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        if (reason) *reason = "manifest_open_failed";
        return nil;
    }

    NSData *result = nil;
    struct stat openedStatus = {0};
    if (fstat(descriptor, &openedStatus) != 0 ||
        !FPManifestStatusIsSafe(&openedStatus) ||
        openedStatus.st_dev != pathStatus.st_dev ||
        openedStatus.st_ino != pathStatus.st_ino ||
        openedStatus.st_size != pathStatus.st_size) {
        if (reason) *reason = "manifest_identity_changed";
        close(descriptor);
        return nil;
    }

    NSMutableData *manifestData =
        [NSMutableData dataWithLength:(NSUInteger)openedStatus.st_size];
    uint8_t *destination = manifestData.mutableBytes;
    size_t remaining = manifestData.length;
    while (remaining > 0) {
        ssize_t readCount = read(descriptor, destination, remaining);
        if (readCount < 0 && errno == EINTR) {
            continue;
        }
        if (readCount <= 0) {
            if (reason) *reason = "manifest_read_failed";
            close(descriptor);
            return nil;
        }
        destination += (size_t)readCount;
        remaining -= (size_t)readCount;
    }

    uint8_t trailingByte = 0;
    ssize_t trailingCount;
    do {
        trailingCount = read(descriptor, &trailingByte, sizeof(trailingByte));
    } while (trailingCount < 0 && errno == EINTR);

    struct stat finalStatus = {0};
    struct stat finalPathStatus = {0};
    if (trailingCount != 0 ||
        fstat(descriptor, &finalStatus) != 0 ||
        lstat(fileSystemPath, &finalPathStatus) != 0 ||
        !FPManifestStatusIsSafe(&finalStatus) ||
        !FPManifestStatusIsSafe(&finalPathStatus) ||
        finalStatus.st_dev != openedStatus.st_dev ||
        finalStatus.st_ino != openedStatus.st_ino ||
        finalStatus.st_size != openedStatus.st_size ||
        finalPathStatus.st_dev != openedStatus.st_dev ||
        finalPathStatus.st_ino != openedStatus.st_ino ||
        finalPathStatus.st_size != openedStatus.st_size) {
        if (reason) *reason = "manifest_changed_during_read";
        close(descriptor);
        return nil;
    }

    result = [manifestData copy];
    close(descriptor);
    return result;
}

static int FPHexNibble(unichar character)
{
    if (character >= '0' && character <= '9') return (int)(character - '0');
    if (character >= 'a' && character <= 'f') return (int)(character - 'a' + 10);
    if (character >= 'A' && character <= 'F') return (int)(character - 'A' + 10);
    return -1;
}

static NSData *FPVerifiedManifestDigest(NSData *manifestData,
                                        NSString *expectedHexDigest,
                                        const char **reason)
{
    if (![expectedHexDigest isKindOfClass:[NSString class]] ||
        expectedHexDigest.length != CC_SHA256_DIGEST_LENGTH * 2U) {
        if (reason) *reason = "manifest_sha256_invalid";
        return nil;
    }

    uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        int high = FPHexNibble([expectedHexDigest characterAtIndex:index * 2U]);
        int low = FPHexNibble([expectedHexDigest characterAtIndex:index * 2U + 1U]);
        if (high < 0 || low < 0) {
            if (reason) *reason = "manifest_sha256_invalid";
            return nil;
        }
        expectedDigest[index] = (uint8_t)((high << 4) | low);
    }

    uint8_t actualDigest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(manifestData.bytes, (CC_LONG)manifestData.length, actualDigest);

    uint8_t difference = 0;
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        difference |= (uint8_t)(expectedDigest[index] ^ actualDigest[index]);
    }
    if (difference != 0) {
        if (reason) *reason = "manifest_sha256_mismatch";
        return nil;
    }
    return [NSData dataWithBytes:actualDigest length:sizeof(actualDigest)];
}

static NSArray<NSURL *> *FPValidateManifest(NSData *manifestData,
                                            NSString *expectedRunIdentifier,
                                            const char **reason)
{
    NSError *JSONError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:manifestData
                                                options:0
                                                  error:&JSONError];
    if (!object || JSONError || ![object isKindOfClass:[NSDictionary class]]) {
        if (reason) *reason = "manifest_json_invalid";
        return nil;
    }

    NSDictionary *manifest = object;
    NSArray<NSString *> *topLevelKeys = @[
        @"schema_version",
        @"producer",
        @"run_identifier",
        @"created_at_unix_milliseconds",
        @"entries",
    ];
    if (!FPDictionaryHasExactKeys(manifest, topLevelKeys)) {
        if (reason) *reason = "manifest_keys_invalid";
        return nil;
    }

    long long schemaVersion = 0;
    if (!FPJSONInteger(manifest[@"schema_version"], &schemaVersion) ||
        schemaVersion != 1) {
        if (reason) *reason = "manifest_schema_invalid";
        return nil;
    }
    if (![manifest[@"producer"] isKindOfClass:[NSString class]] ||
        ![manifest[@"producer"] isEqualToString:FPGrantProducer]) {
        if (reason) *reason = "manifest_producer_invalid";
        return nil;
    }

    NSString *manifestRunIdentifier = manifest[@"run_identifier"];
    if (![manifestRunIdentifier isKindOfClass:[NSString class]] ||
        ![manifestRunIdentifier isEqualToString:expectedRunIdentifier] ||
        ![[NSUUID alloc] initWithUUIDString:manifestRunIdentifier]) {
        if (reason) *reason = "manifest_run_identifier_invalid";
        return nil;
    }

    long long createdAtMilliseconds = 0;
    if (!FPJSONInteger(manifest[@"created_at_unix_milliseconds"],
                       &createdAtMilliseconds) ||
        createdAtMilliseconds <= 0) {
        if (reason) *reason = "manifest_timestamp_invalid";
        return nil;
    }

    NSArray *entries = manifest[@"entries"];
    if (![entries isKindOfClass:[NSArray class]] ||
        entries.count == 0 ||
        entries.count > FPMaximumGrantEntries) {
        if (reason) *reason = "manifest_entries_invalid";
        return nil;
    }

    NSMutableArray<NSURL *> *resolvedURLs =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableSet<NSString *> *seenCanonicalPaths =
        [NSMutableSet setWithCapacity:entries.count];
    NSArray<NSString *> *entryKeys = @[@"canonical_path", @"bookmark_base64"];

    for (id entryObject in entries) {
        if (![entryObject isKindOfClass:[NSDictionary class]] ||
            !FPDictionaryHasExactKeys(entryObject, entryKeys)) {
            if (reason) *reason = "manifest_entry_keys_invalid";
            return nil;
        }

        NSDictionary *entry = entryObject;
        NSString *declaredPath = entry[@"canonical_path"];
        NSString *bookmarkBase64 = entry[@"bookmark_base64"];
        if (![declaredPath isKindOfClass:[NSString class]] ||
            ![bookmarkBase64 isKindOfClass:[NSString class]] ||
            bookmarkBase64.length == 0) {
            if (reason) *reason = "manifest_entry_values_invalid";
            return nil;
        }

        NSData *bookmarkData =
            [[NSData alloc] initWithBase64EncodedString:bookmarkBase64 options:0];
        if (!bookmarkData ||
            bookmarkData.length == 0 ||
            ![[bookmarkData base64EncodedStringWithOptions:0]
                isEqualToString:bookmarkBase64]) {
            if (reason) *reason = "bookmark_base64_invalid";
            return nil;
        }

        // The publisher creates this implicit bookmark with `options: []`.
        // Resolve it with `options: 0`, without opting out of implicit
        // activation, before touching the declared external path. Retaining the
        // returned NSURL keeps that activation alive for this process.
        BOOL bookmarkIsStale = NO;
        NSError *bookmarkError = nil;
        NSURL *resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                      options:0
                                                relativeToURL:nil
                                          bookmarkDataIsStale:&bookmarkIsStale
                                                        error:&bookmarkError];
        if (!resolvedURL ||
            bookmarkError ||
            bookmarkIsStale ||
            !resolvedURL.isFileURL) {
            if (reason) *reason = bookmarkIsStale
                ? "bookmark_stale"
                : "bookmark_resolution_failed";
            return nil;
        }

        const char *pathReason = nil;
        NSString *canonicalDeclaredPath = FPCanonicalExistingPath(
            declaredPath,
            S_IFDIR,
            YES,
            NULL,
            &pathReason
        );
        if (!canonicalDeclaredPath) {
            if (reason) *reason = pathReason ? pathReason : "entry_path_invalid";
            return nil;
        }
        if ([seenCanonicalPaths containsObject:canonicalDeclaredPath]) {
            if (reason) *reason = "manifest_entry_duplicate";
            return nil;
        }

        NSString *resolvedPath = resolvedURL.path;
        const char *resolvedPathReason = nil;
        NSString *canonicalResolvedPath = FPCanonicalExistingPath(
            resolvedPath,
            S_IFDIR,
            NO,
            NULL,
            &resolvedPathReason
        );
        if (!canonicalResolvedPath ||
            ![canonicalResolvedPath isEqualToString:canonicalDeclaredPath]) {
            if (reason) *reason = canonicalResolvedPath
                ? "bookmark_path_mismatch"
                : (resolvedPathReason ? resolvedPathReason : "bookmark_path_invalid");
            return nil;
        }

        [seenCanonicalPaths addObject:canonicalDeclaredPath];
        [resolvedURLs addObject:resolvedURL];
    }

    return [resolvedURLs copy];
}

static int FPCommitActivatedURLs(NSArray<NSURL *> *resolvedURLs,
                                 NSString *runIdentifier,
                                 NSData *manifestDigest,
                                 char *reasonBuffer,
                                 size_t reasonCapacity)
{
    FPInitializeActivationState();
    [FPActivationLock lock];

    if (FPActivatedRunIdentifier) {
        BOOL matchesExistingActivation =
            [FPActivatedRunIdentifier isEqualToString:runIdentifier] &&
            [FPActivatedManifestDigest isEqualToData:manifestDigest];
        [FPActivationLock unlock];
        if (!matchesExistingActivation) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          "activation_already_committed");
        }
        FPSetReason(reasonBuffer, reasonCapacity, "");
        return FPExternalStorageGrantActivationSucceeded;
    }

    [FPRetainedGrantURLs addObjectsFromArray:resolvedURLs];
    FPActivatedRunIdentifier = [runIdentifier copy];
    FPActivatedManifestDigest = [manifestDigest copy];
    [FPActivationLock unlock];

    FPSetReason(reasonBuffer, reasonCapacity, "");
    return FPExternalStorageGrantActivationSucceeded;
}

int FPActivateExternalStorageGrantManifest(char *reasonBuffer, size_t reasonCapacity)
{
    @autoreleasepool {
        FPSetReason(reasonBuffer, reasonCapacity, "");

        NSDictionary<NSString *, NSString *> *environment =
            NSProcessInfo.processInfo.environment;
        NSArray<NSString *> *environmentKeys = @[
            FPGrantFileEnvironmentKey,
            FPGrantSHA256EnvironmentKey,
            FPGrantRunIdentifierEnvironmentKey,
            FPGrantBridgeEnvironmentKey,
        ];

        NSUInteger presentEnvironmentCount = 0;
        for (NSString *key in environmentKeys) {
            if (environment[key] != nil) {
                presentEnvironmentCount++;
            }
        }
        if (presentEnvironmentCount == 0) {
            return FPExternalStorageGrantActivationSucceeded;
        }
        if (presentEnvironmentCount != environmentKeys.count) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          "grant_environment_partial");
        }

        NSString *manifestPath = environment[FPGrantFileEnvironmentKey];
        NSString *expectedSHA256 = environment[FPGrantSHA256EnvironmentKey];
        NSString *runIdentifier = environment[FPGrantRunIdentifierEnvironmentKey];
        NSString *declaredBridgePath = environment[FPGrantBridgeEnvironmentKey];
        if (manifestPath.length == 0 ||
            expectedSHA256.length == 0 ||
            runIdentifier.length == 0 ||
            declaredBridgePath.length == 0) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          "grant_environment_empty");
        }
        if (![[NSUUID alloc] initWithUUIDString:runIdentifier]) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          "grant_run_identifier_invalid");
        }

        const char *validationReason = nil;
        if (!FPValidateLoadedBridgePath(declaredBridgePath, &validationReason)) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          validationReason ? validationReason
                                           : "bridge_validation_failed");
        }

        NSData *manifestData = FPReadManifest(manifestPath, &validationReason);
        if (!manifestData) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          validationReason ? validationReason
                                           : "manifest_read_failed");
        }

        NSData *manifestDigest = FPVerifiedManifestDigest(
            manifestData,
            expectedSHA256,
            &validationReason
        );
        if (!manifestDigest) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          validationReason ? validationReason
                                           : "manifest_sha256_invalid");
        }

        NSArray<NSURL *> *resolvedURLs = FPValidateManifest(
            manifestData,
            runIdentifier,
            &validationReason
        );
        if (!resolvedURLs) {
            return FPFail(reasonBuffer,
                          reasonCapacity,
                          validationReason ? validationReason
                                           : "manifest_validation_failed");
        }

        return FPCommitActivatedURLs(
            resolvedURLs,
            runIdentifier,
            manifestDigest,
            reasonBuffer,
            reasonCapacity
        );
    }
}
