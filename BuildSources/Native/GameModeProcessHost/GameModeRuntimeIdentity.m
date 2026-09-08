/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 *
 * This file is part of the ForgePlay Wine 11.12 loader-compatible process
 * host. See SOURCE-CONTRACT.md for the exact corresponding-source boundary.
 */

#import "GameModeRuntimeIdentity.h"

#import "GameModeBuildIdentity.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

NSString *const FPGameModeHostErrorDomain = @"com.forgeplay.GameModeProcessHost";

extern const struct mach_header_64 _mh_execute_header;

static const NSUInteger FPMaximumManifestBytes = 2U * 1024U * 1024U;
static const uint64_t FPMaximumCorePayloadBytes = UINT64_C(512) * 1024U * 1024U;

static NSError *FPHostError(FPGameModeHostErrorCode code, NSString *reasonCode)
{
    return [NSError errorWithDomain:FPGameModeHostErrorDomain
                               code:code
                           userInfo:@{NSLocalizedFailureReasonErrorKey: reasonCode}];
}

static BOOL FPIsLowercaseSHA256(id value)
{
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *string = value;
    if (string.length != 64) return NO;
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        invalidCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]
            invertedSet];
    });
    return [string rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static BOOL FPNumberIsInteger(id value)
{
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const char *type = [value objCType];
    return type && strchr("cislqCISLQ", type[0]) != NULL;
}

static BOOL FPStringMatches(id value, NSString *expected)
{
    return [value isKindOfClass:[NSString class]] &&
        [(NSString *)value isEqualToString:expected];
}

static BOOL FPObjectsMatchIncludingNil(id first, id second)
{
    return first == second || (first != nil && [first isEqual:second]);
}

static NSString *FPCanonicalPath(NSString *path)
{
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *result = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:resolved
                                    length:strlen(resolved)];
    free(resolved);
    return result;
}

static int FPOpenFileRelativeToDirectory(int rootDescriptor,
                                         NSString *relativePath,
                                         int finalFlags)
{
    NSArray<NSString *> *components = [relativePath pathComponents];
    if (components.count == 0 || [relativePath hasPrefix:@"/"]) {
        errno = EINVAL;
        return -1;
    }

    int directoryDescriptor = dup(rootDescriptor);
    if (directoryDescriptor < 0) return -1;

    for (NSUInteger index = 0; index < components.count; index++) {
        NSString *component = components[index];
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."] || [component containsString:@"/"]) {
            close(directoryDescriptor);
            errno = EINVAL;
            return -1;
        }

        BOOL isLast = index + 1 == components.count;
        int flags = isLast
            ? finalFlags | O_CLOEXEC | O_NOFOLLOW
            : O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW;
        int nextDescriptor = openat(directoryDescriptor, component.fileSystemRepresentation, flags);
        int savedError = errno;
        close(directoryDescriptor);
        if (nextDescriptor < 0) {
            errno = savedError;
            return -1;
        }
        directoryDescriptor = nextDescriptor;
    }
    return directoryDescriptor;
}

static BOOL FPValidateImmutableRegularFileStatus(const struct stat *status)
{
    return (status->st_mode & S_IFMT) == S_IFREG &&
        status->st_nlink == 1 &&
        (status->st_mode & (S_IWGRP | S_IWOTH)) == 0 &&
        status->st_size >= 0;
}

static BOOL FPStatusesIdentifyUnchangedFile(const struct stat *initial,
                                            const struct stat *final)
{
    return initial->st_dev == final->st_dev &&
        initial->st_ino == final->st_ino &&
        initial->st_size == final->st_size &&
        initial->st_mtimespec.tv_sec == final->st_mtimespec.tv_sec &&
        initial->st_mtimespec.tv_nsec == final->st_mtimespec.tv_nsec;
}

static NSData *FPReadBoundedFileRelativeToDirectory(int rootDescriptor,
                                                     NSString *relativePath,
                                                     NSUInteger maximumBytes,
                                                     NSError **error)
{
    int descriptor = FPOpenFileRelativeToDirectory(rootDescriptor, relativePath, O_RDONLY);
    if (descriptor < 0) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_file_open_failed");
        return nil;
    }

    struct stat initialStatus = {0};
    if (fstat(descriptor, &initialStatus) != 0 ||
        !FPValidateImmutableRegularFileStatus(&initialStatus) ||
        (uint64_t)initialStatus.st_size > (uint64_t)maximumBytes) {
        close(descriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_file_policy_failed");
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)initialStatus.st_size];
    NSUInteger totalRead = 0;
    while (totalRead < data.length) {
        ssize_t count = pread(descriptor,
                              (uint8_t *)data.mutableBytes + totalRead,
                              data.length - totalRead,
                              (off_t)totalRead);
        if (count > 0) {
            totalRead += (NSUInteger)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }

    struct stat finalStatus = {0};
    BOOL unchanged = fstat(descriptor, &finalStatus) == 0 &&
        FPStatusesIdentifyUnchangedFile(&initialStatus, &finalStatus);
    close(descriptor);

    if (totalRead != data.length || !unchanged) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_file_changed_during_read");
        return nil;
    }
    return data;
}

static NSString *FPSHA256ForData(NSData *data)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [value appendFormat:@"%02x", digest[index]];
    }
    return value;
}

static BOOL FPReadLittleEndianUInt32(NSData *data,
                                     NSUInteger offset,
                                     uint32_t *value)
{
    if (!value || offset > data.length ||
        sizeof(uint32_t) > data.length - offset) {
        return NO;
    }
    uint32_t encoded = 0;
    memcpy(&encoded, (const uint8_t *)data.bytes + offset, sizeof(encoded));
    *value = CFSwapInt32LittleToHost(encoded);
    return YES;
}

static NSString *FPSignatureIndependentSHA256ForFileRelativeToDirectory(
    int rootDescriptor,
    NSString *relativePath,
    NSError **error)
{
    NSMutableData *data = [FPReadBoundedFileRelativeToDirectory(
        rootDescriptor,
        relativePath,
        (NSUInteger)FPMaximumCorePayloadBytes,
        error) mutableCopy];
    if (!data) return nil;

    uint32_t magic = 0;
    if (data.length < sizeof(struct mach_header_64) ||
        !FPReadLittleEndianUInt32(data, 0, &magic) ||
        magic != MH_MAGIC_64) {
        return FPSHA256ForData(data);
    }

    uint32_t commandCount = 0;
    uint32_t commandBytes = 0;
    if (!FPReadLittleEndianUInt32(data, 16, &commandCount) ||
        !FPReadLittleEndianUInt32(data, 20, &commandBytes) ||
        commandCount > commandBytes / sizeof(struct load_command) ||
        commandBytes > data.length - sizeof(struct mach_header_64)) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_macho_commands_invalid");
        return nil;
    }

    NSUInteger commandOffset = sizeof(struct mach_header_64);
    NSUInteger commandLimit = commandOffset + commandBytes;
    NSUInteger signatureOffset = NSNotFound;
    BOOL linkEditFound = NO;
    for (uint32_t index = 0; index < commandCount; index++) {
        uint32_t command = 0;
        uint32_t commandSize = 0;
        if (commandOffset > commandLimit ||
            sizeof(struct load_command) > commandLimit - commandOffset ||
            !FPReadLittleEndianUInt32(data, commandOffset, &command) ||
            !FPReadLittleEndianUInt32(data, commandOffset + 4, &commandSize) ||
            commandSize < sizeof(struct load_command) ||
            commandSize > commandLimit - commandOffset) {
            if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                            @"runtime_macho_command_invalid");
            return nil;
        }

        if (command == LC_SEGMENT_64) {
            if (commandSize < sizeof(struct segment_command_64)) {
                if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                                @"runtime_macho_segment_invalid");
                return nil;
            }
            const uint8_t *bytes = data.bytes;
            const char *segmentName = (const char *)(bytes + commandOffset + 8);
            if (strncmp(segmentName, SEG_LINKEDIT, sizeof(((struct segment_command_64 *)0)->segname))
                == 0) {
                if (linkEditFound) {
                    if (error) *error = FPHostError(
                        FPGameModeHostErrorInvalidRuntimePayload,
                        @"runtime_macho_linkedit_duplicate");
                    return nil;
                }
                linkEditFound = YES;
                uint8_t *mutableBytes = data.mutableBytes;
                memset(mutableBytes + commandOffset + 32, 0, sizeof(uint64_t));
                memset(mutableBytes + commandOffset + 48, 0, sizeof(uint64_t));
            }
        } else if (command == LC_CODE_SIGNATURE) {
            uint32_t dataOffset = 0;
            uint32_t dataSize = 0;
            if (commandSize != sizeof(struct linkedit_data_command) ||
                signatureOffset != NSNotFound ||
                !FPReadLittleEndianUInt32(data, commandOffset + 8, &dataOffset) ||
                !FPReadLittleEndianUInt32(data, commandOffset + 12, &dataSize) ||
                dataOffset < commandLimit ||
                dataOffset > data.length ||
                dataSize == 0 ||
                dataSize > data.length - dataOffset ||
                (NSUInteger)dataOffset + dataSize != data.length) {
                if (error) *error = FPHostError(
                    FPGameModeHostErrorInvalidRuntimePayload,
                    @"runtime_macho_code_signature_invalid");
                return nil;
            }
            signatureOffset = dataOffset;
            uint8_t *mutableBytes = data.mutableBytes;
            memset(mutableBytes + commandOffset + 8, 0, 2 * sizeof(uint32_t));
        }
        commandOffset += commandSize;
    }

    if (commandOffset != commandLimit ||
        signatureOffset == NSNotFound ||
        !linkEditFound) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_macho_signature_contract_missing");
        return nil;
    }
    return FPSHA256ForData([data subdataWithRange:NSMakeRange(0, signatureOffset)]);
}

static NSString *FPSHA256ForFileRelativeToDirectory(int rootDescriptor,
                                                     NSString *relativePath,
                                                     NSError **error)
{
    int descriptor = FPOpenFileRelativeToDirectory(rootDescriptor, relativePath, O_RDONLY);
    if (descriptor < 0) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_payload_open_failed");
        return nil;
    }

    struct stat initialStatus = {0};
    if (fstat(descriptor, &initialStatus) != 0 ||
        !FPValidateImmutableRegularFileStatus(&initialStatus) ||
        (uint64_t)initialStatus.st_size > FPMaximumCorePayloadBytes) {
        close(descriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_payload_policy_failed");
        return nil;
    }

    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t bytes[64U * 1024U];
    off_t offset = 0;
    BOOL complete = YES;
    while (offset < initialStatus.st_size) {
        off_t remaining = initialStatus.st_size - offset;
        size_t requested = remaining < (off_t)sizeof(bytes)
            ? (size_t)remaining
            : sizeof(bytes);
        ssize_t count = pread(descriptor, bytes, requested, offset);
        if (count > 0) {
            CC_SHA256_Update(&context, bytes, (CC_LONG)count);
            offset += count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        complete = NO;
        break;
    }

    struct stat finalStatus = {0};
    BOOL unchanged = fstat(descriptor, &finalStatus) == 0 &&
        FPStatusesIdentifyUnchangedFile(&initialStatus, &finalStatus);
    close(descriptor);
    if (!complete || offset != initialStatus.st_size || !unchanged) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_payload_changed_during_hash");
        return nil;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256_Final(digest, &context);
    NSMutableString *value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [value appendFormat:@"%02x", digest[index]];
    }
    return value;
}

static NSArray<NSString *> *FPRequiredExecutionPayloadPaths(void)
{
    static NSArray<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = [[NSArray arrayWithObjects:
            @"wine/bin/wine",
            @"wine/bin/wine.bin",
            @"wine/bin/wineserver",
            @"wine/bin/wineserver.bin",
            @"wine/lib/wine/x86_64-unix/wine",
            @"wine/lib/wine/x86_64-unix/ntdll.so",
            @"wine/lib/wine/i386-windows/ntdll.dll",
            @"wine/lib/wine/i386-windows/kernelbase.dll",
            @"wine/lib/wine/x86_64-windows/ntdll.dll",
            @"wine/lib/wine/x86_64-windows/kernelbase.dll",
            @"wine/lib/wine/x86_64-unix/winemac.so",
            @"wine/lib/wine/i386-windows/winemac.drv",
            @"wine/lib/wine/x86_64-windows/winemac.drv",
            @"wine/lib/wine/x86_64-unix/winevulkan.so",
            @"wine/lib/wine/i386-windows/winevulkan.dll",
            @"wine/lib/wine/x86_64-windows/winevulkan.dll",
            @"wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe",
            nil] sortedArrayUsingSelector:@selector(compare:)];
    });
    return paths;
}

static NSArray<NSString *> *FPCanonicalCorePayloadPaths(NSDictionary *corePayloads)
{
    if (corePayloads.count == 0 || corePayloads.count > 256) return nil;
    for (id relativePath in corePayloads) {
        if (![relativePath isKindOfClass:[NSString class]]) return nil;
    }
    return [corePayloads.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL FPValidateThinX8664MachO(int rootDescriptor,
                                    NSString *relativePath,
                                    uint32_t expectedFileType,
                                    NSError **error)
{
    int descriptor = FPOpenFileRelativeToDirectory(rootDescriptor, relativePath, O_RDONLY);
    if (descriptor < 0) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_macho_open_failed");
        return NO;
    }
    struct mach_header_64 header = {0};
    ssize_t count = pread(descriptor, &header, sizeof(header), 0);
    close(descriptor);
    if (count != (ssize_t)sizeof(header) || header.magic != MH_MAGIC_64 ||
        header.cputype != CPU_TYPE_X86_64 || header.filetype != expectedFileType) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimePayload,
                                        @"runtime_macho_identity_failed");
        return NO;
    }
    return YES;
}

static BOOL FPValidateRosettaOnAppleSilicon(NSError **error)
{
#if !defined(__x86_64__)
    if (error) *error = FPHostError(FPGameModeHostErrorInvalidPlatform,
                                    @"host_is_not_x86_64");
    return NO;
#else
    int appleSiliconAvailable = 0;
    size_t appleSiliconSize = sizeof(appleSiliconAvailable);
    int translated = 0;
    size_t translatedSize = sizeof(translated);
    if (sysctlbyname("hw.optional.arm64", &appleSiliconAvailable,
                     &appleSiliconSize, NULL, 0) != 0 ||
        sysctlbyname("sysctl.proc_translated", &translated,
                     &translatedSize, NULL, 0) != 0 ||
        appleSiliconAvailable != 1 || translated != 1) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidPlatform,
                                        @"rosetta_on_apple_silicon_required");
        return NO;
    }
    return YES;
#endif
}

static NSString *FPExecutablePath(NSError **error)
{
    uint32_t size = 0;
    (void)_NSGetExecutablePath(NULL, &size);
    if (size == 0) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"host_executable_path_unavailable");
        return nil;
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (_NSGetExecutablePath(buffer.mutableBytes, &size) != 0) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"host_executable_path_unavailable");
        return nil;
    }
    NSString *path = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:buffer.bytes
                                    length:strlen(buffer.bytes)];
    NSString *canonical = FPCanonicalPath(path);
    if (!canonical) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"host_executable_path_invalid");
    }
    return canonical;
}

static BOOL FPValidateHostPlistDictionary(NSDictionary *dictionary, NSError **error)
{
    NSDictionary<NSString *, id> *requiredValues = @{
        @"CFBundleExecutable": @"GameModeProcessHost",
        @"CFBundleIdentifier": @FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER,
        @"CFBundlePackageType": @"APPL",
        @"LSApplicationCategoryType": @"public.app-category.games",
        @"LSSupportsGameMode": @YES,
        @"NSPrincipalClass": @"WineApplication",
    };
    for (NSString *key in requiredValues) {
        if (![dictionary[key] isEqual:requiredValues[key]]) {
            if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                            @"host_plist_contract_failed");
            return NO;
        }
    }
    id iconName = dictionary[@"CFBundleIconName"];
    id iconFile = dictionary[@"CFBundleIconFile"];
    BOOL hasAssetCatalogIcon = [iconName isEqual:@"AppIcon"] &&
        (iconFile == nil || [iconFile isEqual:@"AppIcon"]);
    BOOL hasStandaloneIcon = [iconFile isEqual:@"AppIcon.icns"] && iconName == nil;
    if (!hasAssetCatalogIcon && !hasStandaloneIcon) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"host_icon_contract_failed");
        return NO;
    }
    if (dictionary[@"LSUIElement"] != nil ||
        dictionary[@"LSBackgroundOnly"] != nil ||
        dictionary[@"LSMultipleInstancesProhibited"] != nil) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"host_plist_agent_mode_forbidden");
        return NO;
    }
    return YES;
}

static BOOL FPValidateHostBundleIdentity(NSString *executablePath, NSError **error)
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleExecutable = FPCanonicalPath(bundle.executableURL.path);
    if (![bundle.bundleIdentifier isEqualToString:@FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER] ||
        ![bundleExecutable isEqualToString:executablePath] ||
        !FPValidateHostPlistDictionary(bundle.infoDictionary, error)) {
        if (error && !*error) {
            *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                 @"host_bundle_identity_failed");
        }
        return NO;
    }

    unsigned long embeddedSize = 0;
    const uint8_t *embeddedBytes = getsectiondata(&_mh_execute_header,
                                                  SEG_TEXT,
                                                  "__info_plist",
                                                  &embeddedSize);
    if (!embeddedBytes || embeddedSize == 0 || embeddedSize > FPMaximumManifestBytes) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"embedded_plist_unavailable");
        return NO;
    }
    NSData *embeddedData = [NSData dataWithBytes:embeddedBytes length:(NSUInteger)embeddedSize];
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    id propertyList = [NSPropertyListSerialization propertyListWithData:embeddedData
                                                                options:NSPropertyListImmutable
                                                                 format:&format
                                                                  error:nil];
    if (![propertyList isKindOfClass:[NSDictionary class]] ||
        !FPValidateHostPlistDictionary(propertyList, error)) {
        if (error && !*error) {
            *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                 @"embedded_plist_contract_failed");
        }
        return NO;
    }

    NSArray<NSString *> *identityKeys = @[
        @"CFBundleExecutable",
        @"CFBundleIdentifier",
        @"CFBundleIconName",
        @"CFBundleIconFile",
        @"CFBundlePackageType",
        @"LSApplicationCategoryType",
        @"LSSupportsGameMode",
        @"NSPrincipalClass",
    ];
    for (NSString *key in identityKeys) {
        if (!FPObjectsMatchIncludingNil(propertyList[key], bundle.infoDictionary[key])) {
            if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                            @"embedded_plist_identity_mismatch");
            return NO;
        }
    }
    return YES;
}

@interface FPGameModeRuntimeIdentity ()

@property(nonatomic, strong, readwrite) NSURL *hostExecutableURL;
@property(nonatomic, strong, readwrite) NSString *hostExecutableSHA256;
@property(nonatomic, strong, readwrite) NSURL *outerContentsURL;
@property(nonatomic, strong, readwrite) NSURL *runtimeRootURL;
@property(nonatomic, strong, readwrite) NSURL *wineLoaderURL;
@property(nonatomic, strong, readwrite) NSURL *wineServerURL;
@property(nonatomic, strong, readwrite) NSURL *ntdllURL;
@property(nonatomic, strong, readwrite) NSString *runtimeIdentifier;
@property(nonatomic, strong, readwrite) NSString *runtimeManifestSHA256;
@property(nonatomic, strong, readwrite) NSString *runtimeBuildFingerprint;
@property(nonatomic, strong, readwrite) NSString *runtimeCoreFingerprint;

@end

@implementation FPGameModeRuntimeIdentity

+ (instancetype)validatedIdentityWithError:(NSError **)error
{
    if (!FPValidateRosettaOnAppleSilicon(error)) return nil;

    NSString *executablePath = FPExecutablePath(error);
    if (!executablePath) return nil;

    static NSString *const hostSuffix =
        @"/Helpers/GameModeProcessHost.app/Contents/MacOS/GameModeProcessHost";
    if (![executablePath hasSuffix:hostSuffix]) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidHostIdentity,
                                        @"fixed_host_bundle_location_required");
        return nil;
    }
    if (!FPValidateHostBundleIdentity(executablePath, error)) return nil;

    NSString *outerContentsPath =
        [executablePath substringToIndex:executablePath.length - hostSuffix.length];
    int outerContentsDescriptor = open(outerContentsPath.fileSystemRepresentation,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    NSError *hostHashError = nil;
    NSString *hostExecutableSHA256 = outerContentsDescriptor >= 0
        ? FPSHA256ForFileRelativeToDirectory(
            outerContentsDescriptor,
            @"Helpers/GameModeProcessHost.app/Contents/MacOS/GameModeProcessHost",
            &hostHashError)
        : nil;
    if (outerContentsDescriptor >= 0) close(outerContentsDescriptor);
    if (!hostExecutableSHA256) {
        if (error) {
            *error = hostHashError ? hostHashError : FPHostError(
                FPGameModeHostErrorInvalidHostIdentity,
                @"host_executable_hash_failed");
        }
        return nil;
    }
    NSString *runtimeRootPath = [outerContentsPath
        stringByAppendingPathComponent:@"Resources/Runners/ForgePlayRuntime"];
    NSString *canonicalRuntimeRoot = FPCanonicalPath(runtimeRootPath);
    if (!canonicalRuntimeRoot || ![canonicalRuntimeRoot isEqualToString:runtimeRootPath]) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeLayout,
                                        @"fixed_runtime_location_required");
        return nil;
    }

    int runtimeDescriptor = open(canonicalRuntimeRoot.fileSystemRepresentation,
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (runtimeDescriptor < 0) {
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeLayout,
                                        @"runtime_root_open_failed");
        return nil;
    }

    NSError *readError = nil;
    NSData *manifestData = FPReadBoundedFileRelativeToDirectory(runtimeDescriptor,
                                                                @"RuntimeManifest.json",
                                                                FPMaximumManifestBytes,
                                                                &readError);
    if (!manifestData) {
        close(runtimeDescriptor);
        if (error) *error = readError;
        return nil;
    }
    NSString *manifestSHA256 = FPSHA256ForData(manifestData);
    if (![manifestSHA256 isEqualToString:@FORGEPLAY_GAME_MODE_RUNTIME_MANIFEST_SHA256]) {
        close(runtimeDescriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeManifest,
                                        @"runtime_manifest_build_binding_failed");
        return nil;
    }

    id decoded = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        close(runtimeDescriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeManifest,
                                        @"runtime_manifest_decode_failed");
        return nil;
    }
    NSDictionary *manifest = decoded;
    NSNumber *schemaVersion = manifest[@"schemaVersion"];
    NSDictionary *corePayloads = manifest[@"corePayloadSHA256"];
    id runnerLauncherSHA256 = manifest[@"runnerLauncherSHA256"];
    if (!FPNumberIsInteger(schemaVersion) || schemaVersion.integerValue != 3 ||
        !FPStringMatches(manifest[@"runtimeIdentifier"],
                         @FORGEPLAY_GAME_MODE_RUNTIME_IDENTIFIER) ||
        !FPStringMatches(manifest[@"wineVersion"],
                         @FORGEPLAY_GAME_MODE_WINE_VERSION) ||
        !FPStringMatches(manifest[@"architecture"],
                         @FORGEPLAY_GAME_MODE_RUNTIME_ARCHITECTURE) ||
        !FPStringMatches(manifest[@"corePayloadHashAlgorithm"],
                         @"sha256-macho-signature-independent-v1") ||
        !FPStringMatches(manifest[@"runnerBuildFingerprint"],
                         @FORGEPLAY_GAME_MODE_RUNTIME_BUILD_FINGERPRINT) ||
        !FPStringMatches(manifest[@"corePayloadFingerprint"],
                         @FORGEPLAY_GAME_MODE_RUNTIME_CORE_FINGERPRINT) ||
        !FPStringMatches(manifest[@"sourceTreeSHA256"],
                         @FORGEPLAY_GAME_MODE_WINE_SOURCE_TREE_SHA256) ||
        !FPStringMatches(manifest[@"patchSetSHA256"],
                         @FORGEPLAY_GAME_MODE_WINE_PATCH_SET_SHA256) ||
        !FPIsLowercaseSHA256(runnerLauncherSHA256) ||
        ![corePayloads isKindOfClass:[NSDictionary class]]) {
        close(runtimeDescriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeManifest,
                                        @"runtime_manifest_identity_failed");
        return nil;
    }

    NSArray<NSString *> *corePayloadPaths = FPCanonicalCorePayloadPaths(corePayloads);
    NSSet<NSString *> *corePayloadSet = corePayloadPaths
        ? [NSSet setWithArray:corePayloadPaths]
        : nil;
    NSSet<NSString *> *requiredExecutionPayloadSet =
        [NSSet setWithArray:FPRequiredExecutionPayloadPaths()];
    if (!corePayloadSet ||
        ![requiredExecutionPayloadSet isSubsetOfSet:corePayloadSet]) {
        close(runtimeDescriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeManifest,
                                        @"runtime_core_payload_set_failed");
        return nil;
    }

    NSMutableString *coreIdentityInput =
        [NSMutableString stringWithString:@"forgeplay-runtime-core-payload-v2\n"];
    for (NSString *relativePath in corePayloadPaths) {
        NSString *expectedSHA256 = corePayloads[relativePath];
        if (!FPIsLowercaseSHA256(expectedSHA256)) {
            close(runtimeDescriptor);
            if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeManifest,
                                            @"runtime_core_payload_hash_invalid");
            return nil;
        }
        NSString *actualSHA256 =
            FPSignatureIndependentSHA256ForFileRelativeToDirectory(runtimeDescriptor,
                                                                   relativePath,
                                                                   &readError);
        if (!actualSHA256 || ![actualSHA256 isEqualToString:expectedSHA256]) {
            close(runtimeDescriptor);
            if (error) {
                *error = readError ? readError : FPHostError(
                    FPGameModeHostErrorInvalidRuntimePayload,
                    @"runtime_core_payload_hash_mismatch");
            }
            return nil;
        }
        [coreIdentityInput appendFormat:@"%@=%@\n", relativePath, expectedSHA256];
    }

    NSString *computedCoreFingerprint =
        FPSHA256ForData([coreIdentityInput dataUsingEncoding:NSUTF8StringEncoding]);
    if (!FPStringMatches(manifest[@"corePayloadFingerprint"], computedCoreFingerprint) ||
        ![corePayloads[@"wine/bin/wine"] isEqualToString:runnerLauncherSHA256]) {
        close(runtimeDescriptor);
        if (error) *error = FPHostError(FPGameModeHostErrorInvalidRuntimeManifest,
                                        @"runtime_core_fingerprint_failed");
        return nil;
    }

    if (!FPValidateThinX8664MachO(runtimeDescriptor,
                                 @"wine/bin/wine.bin",
                                 MH_EXECUTE,
                                 error) ||
        !FPValidateThinX8664MachO(runtimeDescriptor,
                                 @"wine/lib/wine/x86_64-unix/ntdll.so",
                                 MH_DYLIB,
                                 error)) {
        close(runtimeDescriptor);
        return nil;
    }
    close(runtimeDescriptor);

    FPGameModeRuntimeIdentity *identity = [[self alloc] init];
    identity.hostExecutableURL = [NSURL fileURLWithPath:executablePath isDirectory:NO];
    identity.hostExecutableSHA256 = hostExecutableSHA256;
    identity.outerContentsURL = [NSURL fileURLWithPath:outerContentsPath isDirectory:YES];
    identity.runtimeRootURL = [NSURL fileURLWithPath:canonicalRuntimeRoot isDirectory:YES];
    identity.wineLoaderURL =
        [identity.runtimeRootURL URLByAppendingPathComponent:@"wine/bin/wine.bin" isDirectory:NO];
    identity.wineServerURL =
        [identity.runtimeRootURL URLByAppendingPathComponent:@"wine/bin/wineserver" isDirectory:NO];
    identity.ntdllURL = [identity.runtimeRootURL
        URLByAppendingPathComponent:@"wine/lib/wine/x86_64-unix/ntdll.so"
                        isDirectory:NO];
    identity.runtimeIdentifier = manifest[@"runtimeIdentifier"];
    identity.runtimeManifestSHA256 = manifestSHA256;
    identity.runtimeBuildFingerprint = manifest[@"runnerBuildFingerprint"];
    identity.runtimeCoreFingerprint = computedCoreFingerprint;
    return identity;
}

@end
