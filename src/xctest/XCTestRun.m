// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestRun, XCTestCaseRun and XCTestSuiteRun.
//
// A run is the record of one execution: its wall-clock span, how many leaf tests
// it covered, and the issues it produced. -recordIssue: is the single funnel for
// every problem the runner can report, so counter bookkeeping and observer
// notification happen in exactly one place.

#import <XCTest/XCTestRun.h>
#import <XCTest/XCTestCaseRun.h>
#import <XCTest/XCTestSuiteRun.h>
#import <XCTest/XCTestCase.h>
#import <XCTest/XCTestSuite.h>

#import "XCTestObservationInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"

@implementation XCTestRun {
    XCTest *_test;
    NSDate *_startDate;
    NSDate *_stopDate;
    NSUInteger _testCaseCount;
    NSUInteger _executionCount;
    NSUInteger _skipCount;
    NSUInteger _failureCount;
    NSUInteger _unexpectedExceptionCount;
    BOOL _hasBeenSkipped;
    BOOL _hasStarted;
    BOOL _hasStopped;
}

+ (instancetype)testRunWithTest:(XCTest *)test
{
    return [[self alloc] initWithTest:test];
}

- (instancetype)initWithTest:(XCTest *)test
{
    self = [super init];
    if (self != nil) {
        _test = test;
    }
    return self;
}

- (XCTest *)test
{
    return _test;
}

#pragma mark - Private readwrite accessors
//
// The public header exposes these read-only; the internal category declares
// them readwrite so the runner can fill in results. A category cannot declare
// the storage, so the accessors are written out here.

- (NSDate *)startDate
{
    return _startDate;
}

- (void)setStartDate:(NSDate *)startDate
{
    _startDate = [startDate copy];
}

- (NSDate *)stopDate
{
    return _stopDate;
}

- (void)setStopDate:(NSDate *)stopDate
{
    _stopDate = [stopDate copy];
}

- (NSUInteger)testCaseCount
{
    return _testCaseCount;
}

- (void)setTestCaseCount:(NSUInteger)testCaseCount
{
    _testCaseCount = testCaseCount;
}

- (NSUInteger)executionCount
{
    return _executionCount;
}

- (void)setExecutionCount:(NSUInteger)executionCount
{
    _executionCount = executionCount;
}

- (NSUInteger)skipCount
{
    return _skipCount;
}

- (void)setSkipCount:(NSUInteger)skipCount
{
    _skipCount = skipCount;
}

- (NSUInteger)failureCount
{
    return _failureCount;
}

- (void)setFailureCount:(NSUInteger)failureCount
{
    _failureCount = failureCount;
}

- (NSUInteger)unexpectedExceptionCount
{
    return _unexpectedExceptionCount;
}

- (void)setUnexpectedExceptionCount:(NSUInteger)unexpectedExceptionCount
{
    _unexpectedExceptionCount = unexpectedExceptionCount;
}

- (BOOL)hasBeenSkipped
{
    return _hasBeenSkipped;
}

- (void)setHasBeenSkipped:(BOOL)hasBeenSkipped
{
    _hasBeenSkipped = hasBeenSkipped;
}

#pragma mark - Lifecycle

- (void)start
{
    if (_hasStarted) {
        return;
    }
    _hasStarted = YES;
    self.startDate = [NSDate date];
}

- (void)stop
{
    if (_hasStopped || !_hasStarted) {
        return;
    }
    self.stopDate = [NSDate date];
    _hasStopped = YES;
}

#pragma mark - Duration

- (NSTimeInterval)totalDuration
{
    NSDate *startDate = self.startDate;
    NSDate *stopDate = self.stopDate;
    if (startDate == nil || stopDate == nil) {
        return 0.0;
    }
    return [stopDate timeIntervalSinceDate:startDate];
}

- (NSTimeInterval)testDuration
{
    // A run that cannot attribute time to the test body separately reports the
    // whole span; XCTestCase narrows this once setUp and tearDown are timed
    // independently.
    return self.totalDuration;
}

#pragma mark - Results

- (NSUInteger)totalFailureCount
{
    return self.failureCount + self.unexpectedExceptionCount;
}

- (BOOL)hasSucceeded
{
    // A run that never started, or never stopped, has not produced a verdict.
    if (!_hasStarted || !_hasStopped) {
        return NO;
    }
    return self.totalFailureCount == 0;
}

- (void)recordIssue:(XCTIssue *)issue
{
    (void)[self _xct_recordIssue:issue];
}

/// The single funnel every recorded issue passes through.
///
/// Returns YES when an XCTExpectFailure declaration absorbed the issue, which
/// is the answer -XCTestCase needs before it decides whether to unwind the test:
/// an absorbed issue is the outcome the test asked for, so it must neither be
/// counted nor stop the test.
- (BOOL)_xct_recordIssue:(XCTIssue *)issue
{
    if (issue == nil) {
        return NO;
    }

    NSString *absorbedReason = [self _xct_absorbedReasonForIssue:issue];
    if (absorbedReason != nil) {
        // Still reported as the issue it genuinely is, so a reporter that
        // wants every recorded problem sees it, and additionally as the
        // declaration that swallowed it. Counted in neither.
        [self _notifyObserversOfIssue:issue];
        [self _notifyObserversOfExpectedFailure:issue reason:absorbedReason];
        return YES;
    }

    switch (issue.type) {
        case XCTIssueTypeSkippedTest:
            self.skipCount++;
            self.hasBeenSkipped = YES;
            break;

        case XCTIssueTypeUncaughtException:
            // Counted apart from failureCount so that totalFailureCount does not
            // double-count an exception that was also recorded as a failure.
            self.unexpectedExceptionCount++;
            break;

        default:
            // Everything else that carries error severity fails the run,
            // including a declaration that matched nothing: a known bug that
            // has been fixed has to stop looking like a passing test.
            if (issue.isFailure) {
                self.failureCount++;
            }
            break;
    }

    [self _notifyObserversOfIssue:issue];
    return NO;
}

/// The reason of the closest declaration that absorbs `issue`, or nil.
///
/// Matching is deliberately not offered for a skip or for a report that a
/// declaration went unmatched. Absorbing a skip would erase the fact that the
/// test never ran its assertions, and letting a declaration absorb the report
/// that another declaration went unmatched would let a test declare its way out
/// of the one diagnostic that catches stale declarations.
- (nullable NSString *)_xct_absorbedReasonForIssue:(XCTIssue *)issue
{
    if (issue.type == XCTIssueTypeSkippedTest ||
        issue.type == XCTIssueTypeUnmatchedExpectedFailure) {
        return nil;
    }
    if (![_test isKindOfClass:[XCTestCase class]]) {
        return nil;
    }
    return [(XCTestCase *)_test _xct_matchExpectedFailureForIssue:issue];
}

- (void)recordFailureWithDescription:(NSString *)description
                              inFile:(nullable NSString *)filePath
                              atLine:(NSUInteger)lineNumber
                            expected:(BOOL)expected
{
    // `expected` selects the pre-XCTIssue reporting path's assertion-failure
    // type. It has never meant "the test expected this": a declaration made with
    // XCTExpectFailure is what suppresses a failure, and that decision is made in
    // -_xct_recordIssue: above.
    XCTIssue *issue =
        [[XCTIssue alloc] initWithType:(expected ? XCTIssueTypeAssertionFailure
                                                  : XCTIssueTypeTestFailure)
                   compactDescription:description ?: @"Test failed"
                  detailedDescription:nil
                    sourceCodeContext:_XCTSourceCodeContextAtLocation(filePath.UTF8String, lineNumber)
                      associatedError:nil
                          attachments:@[]
                             severity:XCTIssueSeverityError];
    [self recordIssue:issue];
}

#pragma mark - Observation

- (void)_notifyObserversOfIssue:(XCTIssue *)issue
{
    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    if ([_test isKindOfClass:[XCTestCase class]]) {
        [center testCase:(XCTestCase *)_test didRecordIssue:issue];
    } else if ([_test isKindOfClass:[XCTestSuite class]]) {
        [center testSuite:(XCTestSuite *)_test didRecordIssue:issue];
    }
}

/// Broadcasts the legacy expected-failure callback alongside the XCTIssue one.
///
/// The reason was captured by -_xct_recordIssue: while the declaration that
/// matched was still on the test's stack, which is the only point at which it is
/// reachable.
- (void)_notifyObserversOfExpectedFailure:(XCTIssue *)issue reason:(NSString *)reason
{
    if (![_test isKindOfClass:[XCTestCase class]]) {
        return;
    }

    XCTestCase *testCase = (XCTestCase *)_test;
    XCTExpectedFailure *expectedFailure =
        [[XCTExpectedFailure alloc] initWithIssue:issue failureReason:reason];

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    [center testCase:testCase didRecordExpectedFailure:expectedFailure];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p test=%@ cases=%lu executed=%lu "
                                      @"failures=%lu exceptions=%lu skipped=%lu>",
                                      NSStringFromClass([self class]), (void *)self,
                                      NSStringFromClass([_test class]),
                                      (unsigned long)self.testCaseCount,
                                      (unsigned long)self.executionCount,
                                      (unsigned long)self.failureCount,
                                      (unsigned long)self.unexpectedExceptionCount,
                                      (unsigned long)self.skipCount];
}

@end

#pragma mark - XCTestCaseRun

@implementation XCTestCaseRun

- (instancetype)initWithTest:(XCTest *)test
{
    self = [super initWithTest:test];
    if (self != nil) {
        // A case run always covers exactly one leaf test; executionCount stays 0
        // until the runner marks the test as having actually been entered.
        self.testCaseCount = 1;
    }
    return self;
}

@end

#pragma mark - XCTestSuiteRun

@implementation XCTestSuiteRun {
    NSMutableArray<XCTestRun *> *_mutableTestRuns;
}

- (instancetype)initWithTest:(XCTest *)test
{
    self = [super initWithTest:test];
    if (self != nil) {
        _mutableTestRuns = [NSMutableArray array];
    }
    return self;
}

- (NSArray<XCTestRun *> *)testRuns
{
    return [_mutableTestRuns copy];
}

- (void)addTestRun:(XCTestRun *)testRun
{
    if (testRun == nil) {
        return;
    }
    [_mutableTestRuns addObject:testRun];

    // A suite's own numbers are its children's, recomputed on every addition so
    // a partially built suite still reports a coherent snapshot.
    NSUInteger testCaseCount = 0;
    NSUInteger executionCount = 0;
    NSUInteger skipCount = 0;
    NSUInteger failureCount = 0;
    NSUInteger unexpectedExceptionCount = 0;
    BOOL hasBeenSkipped = NO;
    for (XCTestRun *child in _mutableTestRuns) {
        testCaseCount += child.testCaseCount;
        executionCount += child.executionCount;
        skipCount += child.skipCount;
        failureCount += child.failureCount;
        unexpectedExceptionCount += child.unexpectedExceptionCount;
        hasBeenSkipped = hasBeenSkipped || child.hasBeenSkipped;
    }
    self.testCaseCount = testCaseCount;
    self.executionCount = executionCount;
    self.skipCount = skipCount;
    self.failureCount = failureCount;
    self.unexpectedExceptionCount = unexpectedExceptionCount;
    self.hasBeenSkipped = hasBeenSkipped;
}

@end
