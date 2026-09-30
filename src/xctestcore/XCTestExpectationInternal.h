// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The bookkeeping XCTWaiter needs from an expectation, and the counter that
// orders fulfillments across expectations within one process.
//
// Not installed and not part of the public contract: callers outside the
// framework must go through -fulfill and the waiter.

#ifndef XCTEST_XCTESTEXPECTATIONINTERNAL_H
#define XCTEST_XCTESTEXPECTATIONINTERNAL_H

#import <XCTest/XCTestCase.h>
#import <XCTest/XCTestExpectation.h>

NS_ASSUME_NONNULL_BEGIN

/// Monotonic across all fulfillments in the process, so two expectations can be
/// compared for which was satisfied first.
XCT_EXPORT uint64_t _XCTNextFulfillmentSequence(void);

@interface XCTestExpectation (XCTInternal)

/// How many times -fulfill has been called.
@property (atomic, readonly) NSUInteger xct_fulfillmentCount;

/// The sequence number of the fulfillment that took this expectation from
/// unsatisfied to satisfied, or 0 if it has never been satisfied.
@property (atomic, readonly) uint64_t xct_satisfactionSequence;

/// YES once the expectation can no longer change its verdict: satisfied for a
/// normal expectation, or still untouched for an inverted one.
@property (atomic, readonly) BOOL xct_isSettled;

/// Whether -xct_noteUnderFulfillment and -fulfill report a problem through the
/// current test case. YES by default. Set to NO when the caller already reports
/// the same problem itself, so one failure is not reported twice.
@property (atomic) BOOL xct_reportsAutomaticFailures;

/// Reports that the wait expired with this expectation unfulfilled, at most
/// once per expectation even if it is reused across waits.
- (void)xct_noteUnderFulfillment;

/// The test that a problem with this expectation belongs to. The test that
/// created it wins over the thread's current test case, because a callback and
/// the expiry of a wait are both routinely reached from background queues that
/// have no current test case of their own. Subclasses use this when they detect
/// a problem of their own, so a subclass failure is attributed the same way a
/// base-class one is.
- (nullable XCTestCase *)_xct_issueReportingTestCase;

/// Called by the waiter once per poll iteration, before it re-reads the
/// expectations' state.
///
/// Most expectations are satisfied by an external callback that calls -fulfill
/// directly. A few cannot be, because their condition is state rather than an
/// event: a predicate, for instance, is re-evaluated until it holds rather than
/// announced once. Those subclasses override this and call -fulfill when their
/// condition is met. The base implementation does nothing.
- (void)xct_poll;

@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTEXPECTATIONINTERNAL_H */
