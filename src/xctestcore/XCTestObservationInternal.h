// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Broadcast entry points on XCTestObservationCenter that the runner drives.
//
// The public header only exposes observer registration, so these live in a
// private header shared by the observation center and the run/suite/case
// implementations. Everything here must stay optional: an observer only
// implements the subset of XCTestObservation it cares about.

#ifndef XCTEST_XCTESTOBSERVATIONINTERNAL_H
#define XCTEST_XCTESTOBSERVATIONINTERNAL_H

#import <XCTest/XCTestObservationCenter.h>

NS_ASSUME_NONNULL_BEGIN

@class XCTestCase;
@class XCTestSuite;
@class XCTIssue;
@class XCTExpectedFailure;
// Private classes, so only ever named as an argument that is forwarded to an
// observer; a forward declaration is enough and keeps this header free of the
// private header that defines them.
@class XCTestCasePlaceholder;
@class XCTestCasePlaceholderRun;
// Defined by the later activity increments. Both are only ever forwarded to an
// observer, so the observation center never needs to know their layout and a
// forward declaration is enough to keep the hooks compiling here.
@class XCTContext;
@class XCActivityRecord;

/// The private, Apple-internal half of the observation protocol.
///
/// Activity start and finish are not part of the public XCTestObservation
/// protocol: they are reported through a private protocol layered on top of it,
/// so an observer opts in by conforming to this rather than by implementing a
/// public callback. Every method is optional.
@protocol _XCTestObservationPrivate <XCTestObservation>

@optional

- (void)_context:(XCTContext *)context
    willStartActivity:(XCActivityRecord *)activity;
- (void)_context:(XCTContext *)context
    didFinishActivity:(XCActivityRecord *)activity;

/// Declared for completeness: the reference declares it on the same protocol.
/// Nothing reports a skip yet, so there is no sender for it here.
- (void)testCase:(XCTestCase *)testCase
    didRecordSkipWithDescription:(NSString *)description
                 sourceCodeContext:(nullable XCTSourceCodeContext *)sourceCodeContext;

@end

/// The reporting layer above _XCTestObservationPrivate: callbacks the runner
/// wants told about but that are not part of the activity contract. It inherits
/// _XCTestObservationPrivate so that a reporter declaring interest in one level
/// is routed into both lists -- the reference's -_addTestObserver:atStart: adds
/// an observer to every list whose protocol it conforms to, never to exactly
/// one, so conforming here costs an observer nothing it was receiving before.
@protocol _XCTestObservationInternal <_XCTestObservationPrivate>

@optional

/// Declared for completeness: the reference declares it on this protocol, above
/// the case-level skip it inherits. Nothing reports a suite skip yet, so there
/// is no sender for it here.
- (void)testSuite:(XCTestSuite *)testSuite
    didRecordSkipWithDescription:(NSString *)description
                 sourceCodeContext:(nullable XCTSourceCodeContext *)sourceCodeContext;

/// Handed the placeholder and the reason its run recorded a skip, after the run
/// set -hasBeenSkipped. This is the one reporter-facing word that an unavailable
/// test exists: -[XCTestCase performTest:] has nothing to report because there
/// is no invocation to run.
- (void)testCasePlaceholder:(XCTestCasePlaceholder *)placeholder
       isUnavailableWithReason:(NSString *)reason;

@end

@interface XCTestObservationCenter (XCTInternalBroadcast)

- (void)testBundleWillStart:(NSBundle *)testBundle;
- (void)testBundleDidFinish:(NSBundle *)testBundle;

- (void)testSuiteWillStart:(XCTestSuite *)testSuite;
- (void)testSuiteDidFinish:(XCTestSuite *)testSuite;
- (void)testSuite:(XCTestSuite *)testSuite didRecordIssue:(XCTIssue *)issue;
- (void)testSuite:(XCTestSuite *)testSuite
    didRecordExpectedFailure:(XCTExpectedFailure *)expectedFailure;

- (void)testCaseWillStart:(XCTestCase *)testCase;
- (void)testCaseDidFinish:(XCTestCase *)testCase;
- (void)testCase:(XCTestCase *)testCase didRecordIssue:(XCTIssue *)issue;
- (void)testCase:(XCTestCase *)testCase
    didRecordExpectedFailure:(XCTExpectedFailure *)expectedFailure;

/// The activity half of the observation protocol. Both are driven by
/// XCTContext as an activity starts and unwinds, and are delivered only to
/// observers conforming to _XCTestObservationPrivate.
- (void)_context:(XCTContext *)context
    willStartActivity:(XCActivityRecord *)activity;
- (void)_context:(XCTContext *)context
    didFinishActivity:(XCActivityRecord *)activity;

/// The reporting protocol's placeholder callback. `run`'s test being a
/// placeholder is what makes this event coherent; anything else is the runner
/// reporting an event for a test that does not produce one, which the
/// reference answers with an assertion before broadcasting anyway.
- (void)_testCasePlaceholderRun:(XCTestCasePlaceholderRun *)run
       isUnavailableWithReason:(NSString *)reason;

@end

/// Private observers and the dispatch they are called through.
@interface XCTestObservationCenter (XCTInternalPrivateObservers)

/// Observers registered for the private protocol. Registration is additive:
/// an observer conforming to _XCTestObservationPrivate is in this list *and*
/// in the public one, so declaring interest in activity does not cost a
/// reporter its public callbacks. What keeps the two apart is conformance,
/// not membership -- a reporter that never implemented an activity callback
/// never conforms and so is never handed a context and a record it has no
/// way to interpret.
- (NSArray<id<_XCTestObservationPrivate>> *)privateObservers;

/// The same snapshot for the reporting protocol one level above it, which
/// _XCTestObservationInternal inherits. Both getters copy before returning,
/// so a broadcast cannot be handed a list it is concurrently mutating.
- (NSArray<id<_XCTestObservationInternal>> *)internalObservers;

/// Suppresses every broadcast, public and private, while set. The runner
/// suspends observation while it tears down and re-arms the reporter stack, so
/// that teardown is not itself reported as activity.
- (BOOL)suspended;
- (void)setSuspended:(BOOL)suspended;

@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTOBSERVATIONINTERNAL_H */
