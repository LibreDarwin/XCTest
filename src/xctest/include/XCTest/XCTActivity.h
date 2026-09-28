// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A named, nestable region of a test, reported to observers as a start/end
// pair. Used for high-level steps without imposing a logging API.

#ifndef XCTEST_XCTACTIVITY_H
#define XCTEST_XCTACTIVITY_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

@protocol XCTActivity <NSObject>
@optional
- (void)addActivity:(id<XCTActivity>)activity;
@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTACTIVITY_H */
