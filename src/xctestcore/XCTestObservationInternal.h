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

@end

/// Private observers and the dispatch they are called through.
@interface XCTestObservationCenter (XCTInternalPrivateObservers)

/// Observers registered for the private protocol, kept apart from the public
/// ones so that a public reporter never has to implement -- or filter out -- a
/// callback it has no use for.
- (NSArray<id<_XCTestObservationPrivate>> *)privateObservers;

/// Suppresses every broadcast, public and private, while set. The runner
/// suspends observation while it tears down and re-arms the reporter stack, so
/// that teardown is not itself reported as activity.
- (BOOL)suspended;
- (void)setSuspended:(BOOL)suspended;

@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTOBSERVATIONINTERNAL_H */
