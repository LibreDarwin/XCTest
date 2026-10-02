// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A named, nestable region of a test, reported to observers as a start/end
// pair. Used for high-level steps without imposing a logging API.

#ifndef XCTEST_XCTACTIVITY_H
#define XCTEST_XCTACTIVITY_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTAttachment;

@protocol XCTActivity <NSObject>

/// Human-readable name of the activity, given at creation time.
@property (readonly, copy) NSString *name;

/// Adds an attachment which is always kept by Xcode, regardless of the test
/// result. Thread-safe, attachments can be added from any thread, and are
/// reported in the order they are added.
- (void)addAttachment:(XCTAttachment *)attachment;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTACTIVITY_H */