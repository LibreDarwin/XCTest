// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Runs a block as a named activity, so observers can see the structure of a
// long-running test.

#ifndef XCTEST_XCTCONTEXT_H
#define XCTEST_XCTCONTEXT_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTActivity.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTContext : NSObject

- (instancetype)init XCT_UNAVAILABLE("XCTContext is not to be instantiated directly, use +[XCTContext runActivityNamed:block:] to run an activity.");
+ (instancetype)new XCT_UNAVAILABLE("XCTContext is not to be instantiated directly, use +[XCTContext runActivityNamed:block:] to run an activity.");

+ (void)runActivityNamed:(NSString *)name
                   block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTCONTEXT_H */
