// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTWaiter, which blocks a test until its expectations resolve.

#import <XCTest/XCTWaiter.h>

#import "XCTestExpectationInternal.h"
#import "XCTestFoundationCompat.h"

#import <unistd.h>

/// Poll interval. Short enough that a wait's result is not noticeably stale
/// after the last fulfillment, long enough not to spin a core.
#define _XCTWaiterPollMicroseconds 2000

/// Used when a caller asks to wait with no deadline. A wait with no deadline
/// would otherwise hang forever if a fulfillment never arrives, which is
/// indistinguishable from a wedged test runner.
#define _XCTWaiterDefaultTimeout 300.0

@implementation XCTWaiter {
    __weak id<XCTWaiterDelegate> _delegate;
    NSArray<XCTestExpectation *> *_fulfilledExpectations;
}

- (instancetype)initWithDelegate:(id<XCTWaiterDelegate>)delegate
{
    self = [super init];
    if (self != nil) {
        _delegate = delegate;
    }
    return self;
}

- (instancetype)init
{
    // Unavailable in the header, and a waiter with no delegate cannot report
    // anything, so reaching this is a programming error worth surfacing.
    [NSException raise:NSInternalInconsistencyException
                format:@"-init is unavailable on %@; use -initWithDelegate:",
                       NSStringFromClass([self class])];
    return nil;
}

- (id<XCTWaiterDelegate>)delegate
{
    return _delegate;
}

- (void)setDelegate:(id<XCTWaiterDelegate>)delegate
{
    _delegate = delegate;
}

- (NSArray<XCTestExpectation *> *)fulfilledExpectations
{
    return _fulfilledExpectations ?: @[];
}

#pragma mark - Waiting

- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
{
    return [self waitForExpectations:expectations timeout:_XCTWaiterDefaultTimeout enforceOrder:NO];
}

- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
{
    return [self waitForExpectations:expectations timeout:seconds enforceOrder:NO];
}

- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                          enforceOrder:(BOOL)enforceOrderOfFulfillment
{
    return [self waitForExpectations:expectations
                            timeout:_XCTWaiterDefaultTimeout
                       enforceOrder:enforceOrderOfFulfillment];
}

- (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
                          enforceOrder:(BOOL)enforceOrderOfFulfillment
{
    _fulfilledExpectations = @[];
    if (expectations.count == 0) {
        return XCTWaiterResultCompleted;
    }

    NSTimeInterval effectiveTimeout = (seconds > 0.0) ? seconds : _XCTWaiterDefaultTimeout;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:effectiveTimeout];

    while (YES) {
        // Inverted expectations are settled by staying untouched, so a single
        // violation is reported as soon as it is observed.
        for (XCTestExpectation *expectation in expectations) {
            if (expectation.isInverted && expectation.xct_fulfillmentCount > 0) {
                [self _notifyFulfilledInvertedExpectation:expectation];
                return XCTWaiterResultInvertedFulfillment;
            }
        }

        if (enforceOrderOfFulfillment) {
            XCTestExpectation *outOfOrder = [self _firstOrderingViolationIn:expectations];
            if (outOfOrder != nil) {
                [self _notifyOrderingViolationFor:outOfOrder in:expectations];
                return XCTWaiterResultIncorrectOrder;
            }
        }

        NSMutableArray<XCTestExpectation *> *pending = [NSMutableArray array];
        for (XCTestExpectation *expectation in expectations) {
            if (expectation.isInverted) {
                // Settled as long as it has not been fulfilled; keep waiting.
                if (expectation.xct_fulfillmentCount == 0) {
                    [pending addObject:expectation];
                }
            } else if (!expectation.xct_isSettled) {
                [pending addObject:expectation];
            }
        }

        if (pending.count == 0) {
            NSMutableArray<XCTestExpectation *> *fulfilled = [NSMutableArray array];
            for (XCTestExpectation *expectation in expectations) {
                if (!expectation.isInverted) {
                    [fulfilled addObject:expectation];
                }
            }
            _fulfilledExpectations = fulfilled;
            return XCTWaiterResultCompleted;
        }

        if ([deadline timeIntervalSinceNow] <= 0.0) {
            // An inverted expectation is proven by the deadline passing without a
            // fulfillment, so surviving to the timeout is its success, not a
            // timeout. Only inverted expectations left here can still be
            // satisfied; anything else is a genuine unfulfilled wait.
            NSMutableArray<XCTestExpectation *> *genuinelyPending = [NSMutableArray array];
            for (XCTestExpectation *expectation in pending) {
                if (!expectation.isInverted) {
                    [genuinelyPending addObject:expectation];
                }
            }
            if (genuinelyPending.count == 0) {
                _fulfilledExpectations = @[];
                return XCTWaiterResultCompleted;
            }
            for (XCTestExpectation *expectation in genuinelyPending) {
                [expectation xct_noteUnderFulfillment];
            }
            [self _notifyTimeoutWithUnfulfilled:genuinelyPending];
            return XCTWaiterResultTimedOut;
        }

        usleep(_XCTWaiterPollMicroseconds);
    }
}

- (XCTestExpectation *)_firstOrderingViolationIn:(NSArray<XCTestExpectation *> *)expectations
{
    // With enforceOrder, expectations[i] must reach its fulfillment count
    // before expectations[i+1] does.
    uint64_t previousSequence = 0;
    for (NSUInteger i = 0; i < expectations.count; i++) {
        XCTestExpectation *expectation = expectations[i];
        if (expectation.isInverted) {
            continue;
        }
        uint64_t sequence = expectation.xct_satisfactionSequence;
        if (sequence == 0) {
            // Not satisfied yet: nothing later in the list can legitimately be
            // satisfied first either.
            break;
        }
        if (previousSequence > sequence) {
            return expectation;
        }
        previousSequence = sequence;
    }
    return nil;
}

#pragma mark - Delegate

- (void)_notifyTimeoutWithUnfulfilled:(NSArray<XCTestExpectation *> *)unfulfilled
{
    id<XCTWaiterDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(waiter:didTimeoutWithUnfulfilledExpectations:)]) {
        [delegate waiter:self didTimeoutWithUnfulfilledExpectations:unfulfilled];
    }
}

- (void)_notifyOrderingViolationFor:(XCTestExpectation *)expectation
                               in:(NSArray<XCTestExpectation *> *)expectations
{
    id<XCTWaiterDelegate> delegate = _delegate;
    if (![delegate respondsToSelector:@selector(waiter:fulfillmentDidViolateOrderingConstraintsForExpectation:requiredExpectation:)]) {
        return;
    }
    NSUInteger index = [expectations indexOfObjectIdenticalTo:expectation];
    XCTestExpectation *required = (index != NSNotFound && index > 0) ? expectations[index - 1] : expectation;
    [delegate waiter:self
        fulfillmentDidViolateOrderingConstraintsForExpectation:expectation
                                          requiredExpectation:required];
}

- (void)_notifyFulfilledInvertedExpectation:(XCTestExpectation *)expectation
{
    id<XCTWaiterDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(waiter:didFulfillInvertedExpectation:)]) {
        [delegate waiter:self didFulfillInvertedExpectation:expectation];
    }
}

#pragma mark - Class conveniences

+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
{
    return [[[self alloc] initWithDelegate:nil] waitForExpectations:expectations];
}

+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
{
    return [[[self alloc] initWithDelegate:nil] waitForExpectations:expectations timeout:seconds];
}

+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                          enforceOrder:(BOOL)enforceOrderOfFulfillment
{
    return [[[self alloc] initWithDelegate:nil] waitForExpectations:expectations
                                                      enforceOrder:enforceOrderOfFulfillment];
}

+ (XCTWaiterResult)waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                               timeout:(NSTimeInterval)seconds
                          enforceOrder:(BOOL)enforceOrderOfFulfillment
{
    return [[[self alloc] initWithDelegate:nil] waitForExpectations:expectations
                                                            timeout:seconds
                                                       enforceOrder:enforceOrderOfFulfillment];
}

@end
