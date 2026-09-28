// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Mutable record of one test (or suite) execution and its results.

#ifndef XCTEST_XCTESTRUN_H
#define XCTEST_XCTESTRUN_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTIssue.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTest;

@interface XCTestRun : NSObject

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)testRunWithTest:(XCTest *)test;
- (instancetype)initWithTest:(XCTest *)test NS_DESIGNATED_INITIALIZER;

/// The test this run belongs to.
@property (readonly, strong) XCTest *test;

- (void)start;
- (void)stop;

@property (readonly, copy, nullable) NSDate *startDate;
@property (readonly, copy, nullable) NSDate *stopDate;

/// Wall-clock seconds from -start to -stop.
@property (readonly) NSTimeInterval totalDuration;

/// Wall-clock seconds attributed to the test body itself, excluding
/// setUp/tearDown when the run can tell them apart.
@property (readonly) NSTimeInterval testDuration;

@property (readonly) NSUInteger testCaseCount;
@property (readonly) NSUInteger executionCount;

/// Tests that ended in XCTIssueTypeSkippedTest.
@property (readonly) NSUInteger skipCount;

/// Recorded issues whose severity is XCTIssueSeverityError.
@property (readonly) NSUInteger failureCount;

/// Uncaught exceptions seen while running.
@property (readonly) NSUInteger unexpectedExceptionCount;

/// failureCount + unexpectedExceptionCount.
@property (readonly) NSUInteger totalFailureCount;

/// YES when the run produced no errors: it started, stopped, and recorded
/// nothing worse than a warning.
@property (readonly) BOOL hasSucceeded;

/// YES when the run was skipped, via XCTSkip or the test bundle configuration.
@property (readonly) BOOL hasBeenSkipped;

/// Records an issue against this run, updating the counters and notifying
/// observers. Issues are the single funnel for every failure path, including
/// assertion macros, XCTSkip and expected-failure handling.
- (void)recordIssue:(XCTIssue *)issue;

@end

/// Deprecated pre-XCTIssue reporting, retained for source compatibility.
@interface XCTestRun (XCTDeprecated)
- (void)recordFailureWithDescription:(NSString *)description
                              inFile:(nullable NSString *)filePath
                              atLine:(NSUInteger)lineNumber
                            expected:(BOOL)expected;
@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTRUN_H */
