// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The observer registry and the broadcast helpers the runner uses to talk to
// it.
//
// Broadcast lives here rather than at each call site for two reasons: the
// observation protocol is entirely @optional, so every call site would
// otherwise repeat the same respondsToSelector dance; and the two-argument
// callbacks would each need their own hand-written loop. Keeping the registry
// in one place is also what makes the isolation rule enforceable -- an observer
// that throws must not be able to take down a run that would otherwise pass.

#import <XCTest/XCTestObservationCenter.h>
#import <XCTest/XCTestObservation.h>

// The broadcast entry points implemented below are declared for the runner in
// one shared place so the two sides cannot drift.
#import "XCTestObservationInternal.h"

// The SDK's Foundation headers omit -removeObjectIdenticalTo:; the runtime has
// it. See the header for how that was established.
#import "XCTestFoundationCompat.h"

#import <objc/message.h>

NS_ASSUME_NONNULL_BEGIN

@implementation XCTestObservationCenter
{
    // Guarded by _lock. Enumeration always runs over a snapshot taken under the
    // lock, so an observer that adds or removes observers from inside a callback
    // -- legal, if unusual -- cannot mutate the collection mid-broadcast.
    NSMutableArray<id<XCTestObservation>> *_observers;
    NSLock *_lock;
}

+ (XCTestObservationCenter *)sharedTestObservationCenter
{
    static XCTestObservationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        center = [[XCTestObservationCenter alloc] init];
    });
    return center;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        _observers = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark - Registry

- (void)addTestObserver:(id<XCTestObservation>)testObserver
{
    if (testObserver == nil) {
        return;
    }

    [_lock lock];
    [_observers addObject:testObserver];
    [_lock unlock];
}

- (void)removeTestObserver:(id<XCTestObservation>)testObserver
{
    if (testObserver == nil) {
        return;
    }

    [_lock lock];
    // Identity, not equality: two distinct observers may compare equal, and
    // removing the wrong one would silently stop a reporter from being called.
    [_observers removeObjectIdenticalTo:testObserver];
    [_lock unlock];
}

#pragma mark - Broadcast

/// Sends a one-argument selector to every observer implementing it.
///
/// The argument is the subject of the callback -- the suite, case or bundle --
/// so this covers the whole one-argument half of the protocol. A conforming
/// observer is required to tolerate being called from whichever thread is
/// running the test, so nothing here hops threads.
- (void)_broadcast:(SEL)selector subject:(id)subject
{
    for (id<XCTestObservation> observer in [self _snapshotObservers]) {
        if (![observer respondsToSelector:selector]) {
            continue;
        }

        // An observer that throws is isolated rather than propagated. A broken
        // reporter is a bug in the reporting layer, and letting it escape would
        // turn it into a spurious failure of the test under it, or worse, abort
        // the run. The test's own assertions are what decide the outcome.
        @try {
            // The cast below is the standard objc_msgSend idiom and is correct.
            // The selector is a parameter here, so the callee's real signature
            // is not known at compile time and msgSend has to be called through
            // a pointer typed to the call. -Wcast-function-type-mismatch fires
            // because that pointer's type is not formally identical to
            // objc_msgSend's own variadic signature, once per architecture.
            //
            // It is suppressed rather than worked around. Retyping the pointer
            // as id (*)(id, SEL, ...) to match objc_msgSend and silence the
            // warning was tried and regressed at runtime: observers were handed
            // a garbage subject pointer and the first test to start segfaulted
            // in objc_retain. The exact mechanism was not pinned down, but the
            // result was reproduced against both a static and a dynamic link,
            // so the cast below stands and the warning is suppressed narrowly
            // rather than papered over file-wide.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
#endif
            void (*send)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            send(observer, selector, subject);
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
}

/// Sends the pair of issue-recording callbacks, which are the only
/// two-argument entries in the protocol.
- (void)_broadcastIssue:(XCTIssue *)issue
                 toCase:(nullable XCTestCase *)testCase
                toSuite:(nullable XCTestSuite *)testSuite
{
    for (id<XCTestObservation> observer in [self _snapshotObservers]) {
        @try {
            if (testCase != nil &&
                [observer respondsToSelector:@selector(testCase:didRecordIssue:)]) {
                [observer testCase:testCase didRecordIssue:issue];
            }
            if (testSuite != nil &&
                [observer respondsToSelector:@selector(testSuite:didRecordIssue:)]) {
                [observer testSuite:testSuite didRecordIssue:issue];
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
}

/// Sends the pair of expected-failure callbacks, which mirror the issue pair
/// above. Kept separate rather than folded into _broadcastIssue: so that a
/// reporter which tracks expected failures is not handed every assertion.
- (void)_broadcastExpectedFailure:(XCTExpectedFailure *)expectedFailure
                          toCase:(nullable XCTestCase *)testCase
                         toSuite:(nullable XCTestSuite *)testSuite
{
    for (id<XCTestObservation> observer in [self _snapshotObservers]) {
        @try {
            if (testCase != nil &&
                [observer respondsToSelector:@selector(testCase:didRecordExpectedFailure:)]) {
                [observer testCase:testCase didRecordExpectedFailure:expectedFailure];
            }
            if (testSuite != nil &&
                [observer respondsToSelector:@selector(testSuite:didRecordExpectedFailure:)]) {
                [observer testSuite:testSuite didRecordExpectedFailure:expectedFailure];
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
}

/// A snapshot of the registered observers, safe to enumerate without the lock.
- (NSArray<id<XCTestObservation>> *)_snapshotObservers{
    [_lock lock];
    NSArray<id<XCTestObservation>> *snapshot = [_observers copy];
    [_lock unlock];
    return snapshot;
}

- (void)testBundleWillStart:(NSBundle *)testBundle
{
    [self _broadcast:@selector(testBundleWillStart:) subject:testBundle];
}

- (void)testBundleDidFinish:(NSBundle *)testBundle
{
    [self _broadcast:@selector(testBundleDidFinish:) subject:testBundle];
}

- (void)testSuiteWillStart:(XCTestSuite *)testSuite
{
    [self _broadcast:@selector(testSuiteWillStart:) subject:testSuite];
}

- (void)testSuiteDidFinish:(XCTestSuite *)testSuite
{
    [self _broadcast:@selector(testSuiteDidFinish:) subject:testSuite];
}

- (void)testCaseWillStart:(XCTestCase *)testCase
{
    [self _broadcast:@selector(testCaseWillStart:) subject:testCase];
}

- (void)testCaseDidFinish:(XCTestCase *)testCase
{
    [self _broadcast:@selector(testCaseDidFinish:) subject:testCase];
}

- (void)testCase:(XCTestCase *)testCase didRecordIssue:(XCTIssue *)issue
{
    [self _broadcastIssue:issue toCase:testCase toSuite:nil];
}

- (void)testSuite:(XCTestSuite *)testSuite didRecordIssue:(XCTIssue *)issue
{
    [self _broadcastIssue:issue toCase:nil toSuite:testSuite];
}

- (void)testCase:(XCTestCase *)testCase
    didRecordExpectedFailure:(XCTExpectedFailure *)expectedFailure
{
    [self _broadcastExpectedFailure:expectedFailure toCase:testCase toSuite:nil];
}

- (void)testSuite:(XCTestSuite *)testSuite
    didRecordExpectedFailure:(XCTExpectedFailure *)expectedFailure
{
    [self _broadcastExpectedFailure:expectedFailure toCase:nil toSuite:testSuite];
}

@end

NS_ASSUME_NONNULL_END
