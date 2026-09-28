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

/// The waits that are currently blocked, outermost first. When one of them
/// times out, every wait nested inside it is abandoned rather than left to run
/// until its own deadline, which would keep the outer wait from ever returning.
static NSLock *_XCTActiveWaitersLock = nil;
static NSMutableArray<XCTWaiter *> *_XCTActiveWaiters = nil;

@implementation XCTWaiter {
    __weak id<XCTWaiterDelegate> _delegate;
    NSArray<XCTestExpectation *> *_fulfilledExpectations;
    BOOL _interrupted;
}

+ (void)initialize
{
    if (self != [XCTWaiter class]) {
        return;
    }
    _XCTActiveWaitersLock = [[NSLock alloc] init];
    _XCTActiveWaiters = [NSMutableArray array];
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
    _interrupted = NO;
    if (expectations.count == 0) {
        return XCTWaiterResultCompleted;
    }

    [self _pushActiveWaiter];
    @try {
        return [self _waitForExpectations:expectations
                                  timeout:seconds
                             enforceOrder:enforceOrderOfFulfillment];
    } @finally {
        [self _popActiveWaiter];
    }
}

- (XCTWaiterResult)_waitForExpectations:(NSArray<XCTestExpectation *> *)expectations
                                timeout:(NSTimeInterval)seconds
                           enforceOrder:(BOOL)enforceOrderOfFulfillment
{
    NSTimeInterval effectiveTimeout = (seconds > 0.0) ? seconds : _XCTWaiterDefaultTimeout;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:effectiveTimeout];

    while (YES) {
        // An enclosing wait that already timed out no longer cares about this
        // one, so stop instead of blocking until this wait's own deadline.
        if ([self _isInterrupted]) {
            [self _recordFulfilledExpectationsIn:expectations];
            return XCTWaiterResultInterrupted;
        }

        // Inverted expectations are settled by staying untouched, so a single
        // violation is reported as soon as it is observed.
        for (XCTestExpectation *expectation in expectations) {
            if (expectation.isInverted && expectation.xct_fulfillmentCount > 0) {
                [self _recordFulfilledExpectationsIn:expectations];
                [self _notifyFulfilledInvertedExpectation:expectation];
                return XCTWaiterResultInvertedFulfillment;
            }
        }

        if (enforceOrderOfFulfillment) {
            XCTestExpectation *outOfOrder = [self _firstOrderingViolationIn:expectations];
            if (outOfOrder != nil) {
                [self _recordFulfilledExpectationsIn:expectations];
                [self _notifyOrderingViolationFor:outOfOrder in:expectations];
                return XCTWaiterResultIncorrectOrder;
            }
        }

        NSMutableArray<XCTestExpectation *> *pending = [NSMutableArray array];
        for (XCTestExpectation *expectation in expectations) {
            // A condition that is state rather than an event, such as a
            // predicate, re-checks itself here and calls -fulfill when it holds.
            // Done before the settled test below so a fulfillment raised by this
            // iteration is seen in the same pass.
            [expectation xct_poll];

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
            [self _recordFulfilledExpectationsIn:expectations];
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
                [self _recordFulfilledExpectationsIn:expectations];
                return XCTWaiterResultCompleted;
            }
            for (XCTestExpectation *expectation in genuinelyPending) {
                [expectation xct_noteUnderFulfillment];
            }
            [self _recordFulfilledExpectationsIn:expectations];
            [self _interruptNestedWaiters];
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

#pragma mark - Nested waits

- (void)_pushActiveWaiter
{
    [_XCTActiveWaitersLock lock];
    [_XCTActiveWaiters addObject:self];
    [_XCTActiveWaitersLock unlock];
}

- (void)_popActiveWaiter
{
    [_XCTActiveWaitersLock lock];
    // Identity-based: the same waiter may legitimately be re-entered, and only
    // its own frame should be removed.
    NSUInteger index = [_XCTActiveWaiters indexOfObjectIdenticalTo:self];
    if (index != NSNotFound) {
        [_XCTActiveWaiters removeObjectAtIndex:index];
    }
    [_XCTActiveWaitersLock unlock];
}

// Marks every wait nested inside this one as interrupted and tells each one's
// delegate. The snapshot is taken under the lock but notified outside it, so a
// delegate that starts or ends a wait cannot deadlock against the registry.
- (void)_interruptNestedWaiters
{
    [_XCTActiveWaitersLock lock];
    NSUInteger outer = [_XCTActiveWaiters indexOfObjectIdenticalTo:self];
    NSMutableArray<XCTWaiter *> *nested = [NSMutableArray array];
    // Not finding self means this wait is not on the stack, and NSNotFound + 1
    // would wrap to 0 and make it look like the outermost of every wait.
    if (outer != NSNotFound) {
        for (NSUInteger i = outer + 1; i < _XCTActiveWaiters.count; i++) {
            [nested addObject:[_XCTActiveWaiters objectAtIndex:i]];
        }
    }
    [_XCTActiveWaitersLock unlock];

    for (XCTWaiter *waiter in nested) {
        [waiter _markInterruptedByWaiter:self];
    }
}

- (BOOL)_isInterrupted
{
    // Read under the same lock the flag is written under: the interrupting wait
    // runs on another thread, and the poll loop reads it every 2ms.
    @synchronized(self) {
        return _interrupted;
    }
}

- (void)_markInterruptedByWaiter:(XCTWaiter *)outerWaiter
{
    @synchronized(self) {
        if (_interrupted) {
            return;
        }
        _interrupted = YES;
    }
    id<XCTWaiterDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(nestedWaiter:wasInterruptedByTimedOutWaiter:)]) {
        [delegate nestedWaiter:self wasInterruptedByTimedOutWaiter:outerWaiter];
    }
}

#pragma mark - Delegate

// Records which expectations reached their fulfillment count, so a wait that
// ends in a timeout, an ordering violation, or an inverted fulfillment still
// reports the subset that did succeed. Inverted expectations are excluded:
// fulfilling one is a failure, and reporting it as fulfilled would hide that.
- (void)_recordFulfilledExpectationsIn:(NSArray<XCTestExpectation *> *)expectations
{
    NSMutableArray<XCTestExpectation *> *fulfilled = [NSMutableArray array];
    for (XCTestExpectation *expectation in expectations) {
        if (!expectation.isInverted && expectation.xct_isSettled) {
            [fulfilled addObject:expectation];
        }
    }
    _fulfilledExpectations = fulfilled;
}

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
