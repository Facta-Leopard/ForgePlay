/*
 * SPDX-FileCopyrightText: 2026 Facta-Leopard
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * ForgePlay Game Mode
 * Original source: https://github.com/Facta-Leopard/ForgePlay
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FPGameModeApplicationGroup : NSObject

@property(nonatomic, strong, readonly) NSString *identifier;
@property(nonatomic, strong, readonly) NSURL *containerURL;
@property(nonatomic, strong, readonly) NSURL *launchRequestStoreURL;
@property(nonatomic, strong, readonly) NSURL *wineServerBaseURL;
@property(nonatomic, strong, readonly) NSURL *evidenceFileURL;

+ (nullable instancetype)validatedGroupWithError:(NSError **)error;

- (nullable NSURL *)prepareWineServerRootWithScopeIdentifier:(NSString *)scopeIdentifier
                                                        error:(NSError **)error;

- (BOOL)recordEventCode:(NSString *)eventCode
                  runID:(nullable NSString *)runIdentifier;

@end


FOUNDATION_EXPORT BOOL FPPathIsContainedByDirectory(NSString *path,
                                                    NSString *directoryPath);

NS_ASSUME_NONNULL_END
