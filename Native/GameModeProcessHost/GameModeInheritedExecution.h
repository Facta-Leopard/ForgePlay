/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 */

#import <Foundation/Foundation.h>

@class FPGameModeApplicationGroup;
@class FPGameModeRuntimeIdentity;

NS_ASSUME_NONNULL_BEGIN

@interface FPGameModeInheritedExecution : NSObject

@property(nonatomic, strong, readonly) NSURL *prefixURL;
@property(nonatomic, strong, readonly) NSURL *wineServerRootURL;
@property(nonatomic, strong, readonly) NSString *wineMachServiceName;
@property(nonatomic, strong, readonly) NSString *runIdentifier;

+ (nullable instancetype)validatedExecutionForRuntime:(FPGameModeRuntimeIdentity *)runtime
                                     applicationGroup:(FPGameModeApplicationGroup *)applicationGroup
                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
