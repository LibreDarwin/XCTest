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

@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTOBSERVATIONINTERNAL_H */
