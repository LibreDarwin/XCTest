// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestExpectation, a condition a test intends to satisfy.

#import <XCTest/XCTestExpectation.h>
#import <XCTest/XCTIssue.h>

#import "XCTestExpectationInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"

#import <stdatomic.h>

// Ordering has to be comparable across expectations, so the counter is process
// wide rather than per-expectation.
static _Atomic(uint64_t) _XCTFulfillmentSequence = 0;

XCT_EXPORT uint64_t _XCTNextFulfillmentSequence(void)
{
    // Wrapping would only matter after 2^64 fulfillments; a saturated counter
    // degrades ordering detection rather than corrupting anything.
    return atomic_fetch_add(&_XCTFulfillmentSequence, 1) + 1;
}

@implementation XCTestExpectation {
    NSString *_expectationDescription;
    BOOL _inverted;
    NSUInteger _expectedFulfillmentCount;
    BOOL _assertForOverFulfill;

    __weak XCTestCase *_owningTestCase;

    NSLock *_lock;
    NSUInteger _fulfillmentCount;
    uint64_t _satisfactionSequence;
    BOOL _reportedOverFulfill;
    BOOL _reportedUnderFulfill;
    BOOL _reportsAutomaticFailures;
}

- (instancetype)initWithDescription:(NSString *)description
{
    self = [super init];
    if (self != nil) {
        _expectationDescription = [description copy];
        _expectedFulfillmentCount = 1;
        _assertForOverFulfill = YES;
        _reportsAutomaticFailures = YES;
        _lock = [NSLock new];
        // Remember who created the expectation. A duplicate or missing callback
        // is a bug in the test that owns the expectation, and the thread that
        // happens to make the call is often a background queue that has no
        // current test case of its own.
        _owningTestCase = _XCTCurrentTestCase();
    }
    return self;
}

#pragma mark - Configuration

- (NSString *)expectationDescription
{
    [_lock lock];
    NSString *description = _expectationDescription;
    [_lock unlock];
    return description;
}

- (void)setExpectationDescription:(NSString *)description
{
    [_lock lock];
    _expectationDescription = [description copy];
    [_lock unlock];
}

- (BOOL)isInverted
{
    [_lock lock];
    BOOL inverted = _inverted;
    [_lock unlock];
    return inverted;
}

- (void)setInverted:(BOOL)inverted
{
    [_lock lock];
    _inverted = inverted;
    [_lock unlock];
}

- (NSUInteger)expectedFulfillmentCount
{
    [_lock lock];
    NSUInteger count = _expectedFulfillmentCount;
    [_lock unlock];
    return count;
}

- (void)setExpectedFulfillmentCount:(NSUInteger)count
{
    [_lock lock];
    _expectedFulfillmentCount = count;
    [_lock unlock];
}

- (BOOL)assertForOverFulfill
{
    [_lock lock];
    BOOL asserts = _assertForOverFulfill;
    [_lock unlock];
    return asserts;
}

- (void)setAssertForOverFulfill:(BOOL)assertForOverFulfill
{
    [_lock lock];
    _assertForOverFulfill = assertForOverFulfill;
    [_lock unlock];
}

#pragma mark - Fulfillment

- (void)fulfill
{
    [_lock lock];
    _fulfillmentCount++;
    NSUInteger count = _fulfillmentCount;
    NSUInteger expected = _expectedFulfillmentCount;
    BOOL becameSatisfied = (count == expected && _satisfactionSequence == 0);
    if (becameSatisfied) {
        _satisfactionSequence = _XCTNextFulfillmentSequence();
    }
    BOOL overFulfilled = count > expected;
    BOOL shouldReportOverFulfill = overFulfilled && _assertForOverFulfill && _reportsAutomaticFailures
                                   && !_reportedOverFulfill;
    if (shouldReportOverFulfill) {
        _reportedOverFulfill = YES;
    }
    [_lock unlock];

    if (shouldReportOverFulfill) {
        [self _reportOverFulfillment];
    }
}

- (void)_reportOverFulfillment
{
    // An over-fulfillment usually means a duplicate callback, so it is the kind
    // of bug worth reporting even though the wait itself will succeed.
    XCTestCase *testCase = [self _issueReportingTestCase];
    if (testCase == nil) {
        return;
    }
    // No unwind: the duplicate came from a callback, so there is no assertion
    // on this thread to abandon, and the callback may well be on a thread that
    // has no handler for an unwind at all.
    [testCase _xct_recordIssueWithoutUnwinding:[[XCTIssue alloc]
                                                  initWithType:XCTIssueTypeTestFailure
                                             compactDescription:@"API violation - multiple calls to -fulfill"
                                                        severity:XCTIssueSeverityError]];
}

// The test that a problem with this expectation belongs to. The owner wins over
// the thread's current test case, because -fulfill and the expiry of a wait are
// both routinely called from background queues that have no current test case,
// and a bug that vanishes when it happens off the test thread is not reported.
- (XCTestCase *)_issueReportingTestCase
{
    XCTestCase *owning = _owningTestCase;
    if (owning != nil) {
        return owning;
    }
    return _XCTCurrentTestCase();
}

#pragma mark - Waiter view

- (NSUInteger)xct_fulfillmentCount
{
    [_lock lock];
    NSUInteger count = _fulfillmentCount;
    [_lock unlock];
    return count;
}

- (uint64_t)xct_satisfactionSequence
{
    [_lock lock];
    uint64_t sequence = _satisfactionSequence;
    [_lock unlock];
    return sequence;
}

- (BOOL)xct_isSettled
{
    [_lock lock];
    // A normal expectation is settled once it has been fulfilled the expected
    // number of times. An inverted one is settled only while untouched, so the
    // waiter has to keep waiting to prove it stays that way.
    BOOL settled = _inverted ? _fulfillmentCount == 0 : _fulfillmentCount >= _expectedFulfillmentCount;
    [_lock unlock];
    return settled;
}

- (BOOL)xct_reportsAutomaticFailures
{
    [_lock lock];
    BOOL reports = _reportsAutomaticFailures;
    [_lock unlock];
    return reports;
}

- (void)setXct_reportsAutomaticFailures:(BOOL)reportsAutomaticFailures
{
    [_lock lock];
    _reportsAutomaticFailures = reportsAutomaticFailures;
    [_lock unlock];
}

/// Recorded so an under-fulfillment is reported once even if the same
/// expectation is reused across waits.
- (void)xct_noteUnderFulfillment
{
    [_lock lock];
    BOOL shouldReport = _reportsAutomaticFailures && !_reportedUnderFulfill;
    _reportedUnderFulfill = YES;
    [_lock unlock];
    if (!shouldReport) {
        return;
    }
    XCTestCase *testCase = [self _issueReportingTestCase];
    if (testCase == nil) {
        return;
    }
    [testCase _xct_recordIssueWithoutUnwinding:[[XCTIssue alloc]
                                                  initWithType:XCTIssueTypeTestFailure
                                             compactDescription:[NSString stringWithFormat:
                                                                   @"Asynchronous wait failed: %@",
                                                                   self.expectationDescription ?: @"(no description)"]
                                                severity:XCTIssueSeverityError]];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p description=%@ fulfilled=%lu/%lu%@>",
                                      NSStringFromClass([self class]), (void *)self,
                                      self.expectationDescription,
                                      (unsigned long)self.xct_fulfillmentCount,
                                      (unsigned long)self.expectedFulfillmentCount,
                                      self.isInverted ? @" inverted" : @""];
}

@end
