/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FPGameModeHostErrorDomain;

typedef NS_ENUM(NSInteger, FPGameModeHostErrorCode) {
    FPGameModeHostErrorInvalidPlatform = 1,
    FPGameModeHostErrorInvalidHostIdentity,
    FPGameModeHostErrorInvalidApplicationGroup,
    FPGameModeHostErrorInvalidRuntimeLayout,
    FPGameModeHostErrorInvalidRuntimeManifest,
    FPGameModeHostErrorInvalidRuntimePayload,
    FPGameModeHostErrorEnvironmentFailed,
};

@interface FPGameModeRuntimeIdentity : NSObject

@property(nonatomic, strong, readonly) NSURL *hostExecutableURL;
@property(nonatomic, strong, readonly) NSString *hostExecutableSHA256;
@property(nonatomic, strong, readonly) NSURL *outerContentsURL;
@property(nonatomic, strong, readonly) NSURL *runtimeRootURL;
@property(nonatomic, strong, readonly) NSURL *wineLoaderURL;
@property(nonatomic, strong, readonly) NSURL *wineServerURL;
@property(nonatomic, strong, readonly) NSURL *ntdllURL;
@property(nonatomic, strong, readonly) NSString *runtimeIdentifier;
@property(nonatomic, strong, readonly) NSString *runtimeManifestSHA256;
@property(nonatomic, strong, readonly) NSString *runtimeBuildFingerprint;
@property(nonatomic, strong, readonly) NSString *runtimeCoreFingerprint;

+ (nullable instancetype)validatedIdentityWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
