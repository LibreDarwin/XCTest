// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Blocks a test until its expectations are fulfilled or the deadline passes.

#ifndef XCTEST_XCTWAITER_H
#define XCTEST_XCTWAITER_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestExpectation.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTWaiter;

typedef NS_ENUM(NSInteger, XCTWaiterResult) {
    /// Every expectation was fulfilled in time and in order.
    XCTWaiterResultCompleted = 1,
    /// The deadline expired with expectations still outstanding.
    XCTWaiterResultTimedOut,
    /// enforceOrder: was requested and expectations were fulfilled out of order.
    XCTWaiterResultIncorrectOrder,
    /// An inverted expectation was fulfilled.
    XCTWaiterResultInvertedFulfillment,
    /// The wait was abandoned, e.g. because an outer wait timed out.
    XCTWaiterResultInterrupted,
} NS_SWIFT_NAME(XCTWaiter.Result);

@protocol XCTWaiterDelegate <NSObject>
@optional
- (void)waiter:(XCTWaiter *)waiter
    didTimeoutWithUnfulfilledExpectations:(NSArray<XCTestExpectation *> *)unfulfilledExpectations;
- (void)waiter:(XCTWaiter *)waiter
    fulfillmentDidViolateOrderingConstraintsForExpectation:(XCTestExpectation *)expectation
                                      requiredExpectation:(XCTestExpectation *)requiredExpectation;
- (void)waiter:(XCTWaiter *)waiter didFulfillInvertedExpectation:(XCTestExpectation *)expectation;
- (void)nestedWaiter:(XCTWaiter *)waiter wasInterruptedByTimedOutWaiter:(XCTWaiter *)outerWaiter;
@end

@interface XCTWaiter : NSObject

- (instancetype)initWithDelegate:(nullable id<XCTWaiterDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nullable, weak) id<XCTWaiterDelegate> delegate;

/// Expectations that reached their fulfillment count during the last wait.
@property (readonly) NSArray<XCTestExpectation *> *fulfilledExpectations;

- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");
- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");
- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                          enforceOrder:(BOOL)enforceOrderOfFulfillment
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");
- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
                          enforceOrder:(BOOL)enforceOrderOfFulfillment
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");

+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations XCT_WARN_UNUSED
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");
+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds XCT_WARN_UNUSED
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");
+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                          enforceOrder:(BOOL)enforceOrderOfFulfillment XCT_WARN_UNUSED
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");
+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
                          enforceOrder:(BOOL)enforceOrderOfFulfillment XCT_WARN_UNUSED
    XCT_SWIFT_UNAVAILABLE_FROM_ASYNC("Use await fulfillment(of:timeout:) instead");

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTWAITER_H */
