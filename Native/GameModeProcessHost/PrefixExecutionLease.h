/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FPGameModePrefixExecutionLockEnvironmentKey;

@interface FPPrefixExecutionLease : NSObject

@property(nonatomic, strong, readonly) NSURL *lockURL;

+ (nullable instancetype)acquireInheritedSharedLeaseForPrefixURL:(NSURL *)prefixURL
                                              allowedContainerURL:(NSURL *)containerURL
                                                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
