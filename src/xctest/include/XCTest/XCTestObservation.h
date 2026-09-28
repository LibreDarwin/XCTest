// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Observer callbacks fired as a test run progresses.

#ifndef XCTEST_XCTESTOBSERVATION_H
#define XCTEST_XCTESTOBSERVATION_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTIssue.h>
#import <XCTest/XCTExpectedFailure.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTestSuite;
@class XCTestCase;

@protocol XCTestObservation <NSObject>
@optional

- (void)testBundleWillStart:(NSBundle *)testBundle;
- (void)testBundleDidFinish:(NSBundle *)testBundle;

- (void)testSuiteWillStart:(XCTestSuite *)testSuite;
- (void)testSuite:(XCTestSuite *)testSuite didRecordIssue:(XCTIssue *)issue;
- (void)testSuite:(XCTestSuite *)testSuite
    didRecordExpectedFailure:(XCTExpectedFailure *)expectedFailure;
- (void)testSuiteDidFinish:(XCTestSuite *)testSuite;

- (void)testCaseWillStart:(XCTestCase *)testCase;
- (void)testCase:(XCTestCase *)testCase didRecordIssue:(XCTIssue *)issue;
- (void)testCase:(XCTestCase *)testCase
    didRecordExpectedFailure:(XCTExpectedFailure *)expectedFailure;
- (void)testCaseDidFinish:(XCTestCase *)testCase;

/// Deprecated pre-XCTIssue reporting.
- (void)testSuite:(XCTestSuite *)testSuite
    didFailWithDescription:(NSString *)description
                     inFile:(nullable NSString *)filePath
                     atLine:(NSUInteger)lineNumber;
- (void)testCase:(XCTestCase *)testCase
    didFailWithDescription:(NSString *)description
                    inFile:(nullable NSString *)filePath
                    atLine:(NSUInteger)lineNumber;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTOBSERVATION_H */
