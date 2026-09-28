// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A file or in-memory blob attached to a test result.

#ifndef XCTEST_XCTATTACHMENT_H
#define XCTEST_XCTATTACHMENT_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTAttachmentLifetime.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTAttachment : NSObject <NSSecureCoding>

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithUniformTypeIdentifier:(nullable NSString *)identifier NS_DESIGNATED_INITIALIZER;
+ (instancetype)attachmentWithUniformTypeIdentifier:(nullable NSString *)identifier;

/// Uniform type identifier of the payload, e.g. "public.png". Nil means the
/// consumer should sniff the contents.
@property (readonly, copy) NSString *uniformTypeIdentifier;

/// Human-readable label shown alongside the attachment in result bundles.
@property (copy, nullable) NSString *name;

/// Free-form metadata passed through to the result consumer.
@property (copy, nullable) NSDictionary *userInfo;

@property XCTAttachmentLifetime lifetime;

@end

@interface XCTAttachment (ConvenienceInitializers)

+ (instancetype)attachmentWithData:(NSData *)payload;
+ (instancetype)attachmentWithData:(NSData *)payload uniformTypeIdentifier:(nullable NSString *)identifier;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTATTACHMENT_H */
