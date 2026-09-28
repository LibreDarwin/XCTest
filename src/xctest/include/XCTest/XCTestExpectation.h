// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A condition a test intends to satisfy, checked by XCTWaiter.

#ifndef XCTEST_XCTESTEXPECTATION_H
#define XCTEST_XCTESTEXPECTATION_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTestExpectation : NSObject

- (instancetype)initWithDescription:(NSString *)description NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Label reported if this expectation is what fails or times out.
@property (copy) NSString *expectationDescription;

/// When YES, fulfilling this expectation is itself a failure. Use to assert
/// that something never happens within the wait.
@property (getter=isInverted) BOOL inverted;

/// How many times -fulfill must be called for the wait to consider this
/// expectation satisfied. Defaults to 1.
@property (nonatomic) NSUInteger expectedFulfillmentCount;

/// When YES (the default) a second, unexpected fulfillment is a failure.
@property (nonatomic) BOOL assertForOverFulfill;

/// Marks one unit of progress. Thread-safe.
- (void)fulfill;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTEXPECTATION_H */
