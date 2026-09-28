// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTNSPredicateExpectation, an expectation satisfied by a predicate.
//
// A predicate is state, not an event, so this expectation cannot be satisfied by
// a callback the way the notification and KVO expectations are. It is instead
// re-evaluated by the waiter's poll loop through -xct_poll, which is why the
// waiter calls that hook before re-reading the expectations' state.

#import <XCTest/XCTIssue.h>
#import <XCTest/XCTNSPredicateExpectation.h>
#import <XCTest/XCTestCase.h>

#import "XCTestExpectationInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"

@implementation XCTNSPredicateExpectation {
    NSPredicate *_predicate;
    id _object;
    XCPredicateExpectationHandler _handler;

    // Guards the handler, which the poll loop reads on the waiter's thread
    // while a test may install one from another.
    NSLock *_lock;
}

// Unavailable for a predicate: the wait ends when the predicate first holds, so
// a count other than one has nothing to wait for. Implemented by the
// superclass, which still needs it to settle the wait.
@dynamic expectedFulfillmentCount;

- (instancetype)initWithPredicate:(NSPredicate *)predicate object:(nullable id)object
{
    self = [super initWithDescription:[NSString stringWithFormat:@"predicate %@ on %@",
                                                                 predicate,
                                                                 object ?: @"nil"]];
    if (self != nil) {
        _predicate = [predicate copy];
        _object = object;
        _lock = [NSLock new];
    }
    return self;
}

#pragma mark - Configuration

- (NSPredicate *)predicate
{
    return _predicate;
}

- (id)object
{
    return _object;
}

- (XCPredicateExpectationHandler)handler
{
    [_lock lock];
    XCPredicateExpectationHandler handler = _handler;
    [_lock unlock];
    return handler;
}

- (void)setHandler:(XCPredicateExpectationHandler)handler
{
    [_lock lock];
    _handler = [handler copy];
    [_lock unlock];
}

#pragma mark - Evaluation

- (void)xct_poll
{
    // An inverted expectation is proven by the predicate *never* holding, so
    // evaluating it here must stay silent. A fulfillment is the failure signal
    // the waiter looks for, and raising one here would report a pass as a
    // violation.
    if (self.isInverted) {
        return;
    }

    // A handler can express a completion the predicate cannot, such as a
    // deadline of its own, so it takes precedence.
    XCPredicateExpectationHandler handler = self.handler;
    if (handler != nil) {
        if (handler()) {
            [self fulfill];
        }
        return;
    }

    // Predicates raise on a malformed key path, and a test that watches an
    // object whose keys are still absent would otherwise crash inside the
    // waiter's poll loop, far from the test that caused it.
    @try {
        if ([_predicate evaluateWithObject:_object]) {
            [self fulfill];
        }
    } @catch (NSException *exception) {
        // Report rather than swallow: a predicate that cannot be evaluated is a
        // test failure. Attributed to the test that created the expectation
        // rather than to the thread running the wait, which is the same rule
        // the base class uses for its own failures.
        XCTestCase *testCase = [self _xct_issueReportingTestCase];
        [testCase _xct_recordIssueWithoutUnwinding:[[XCTIssue alloc]
                                                      initWithType:XCTIssueTypeTestFailure
                                             compactDescription:[NSString stringWithFormat:
                                                                       @"Predicate %@ could not be evaluated: %@",
                                                                       _predicate,
                                                                       [exception reason] ?: [exception name]]
                                                        severity:XCTIssueSeverityError]];
        // Fulfilled so the wait ends now rather than spinning until its timeout
        // with the predicate still unevaluated.
        [self fulfill];
    }
}

@end
