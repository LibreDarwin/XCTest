// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Abstract base of everything runnable: XCTestCase and XCTestSuite.

#ifndef XCTEST_XCABSTRACTTEST_H
#define XCTEST_XCABSTRACTTEST_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestRun.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTest : NSObject

/// Number of leaf test cases this test will execute. For a suite this is the
/// sum over its children, so it is known before the run starts.
@property (readonly) NSUInteger testCaseCount;

/// Display name: the method name for a case, the suite name otherwise.
@property (readonly, copy) NSString *name;

/// XCTestCaseRun or XCTestSuiteRun, depending on the subclass. Read before the
/// run starts, it is nil; the run assigns itself here once created.
@property (readonly, nullable) Class testRunClass;

@property (readonly, nullable) XCTestRun *testRun;

/// Runs this test against `run`, creating it if it does not have one yet.
/// Subclasses implement the actual work here.
- (void)performTest:(XCTestRun *)run;

/// Convenience for [self performTest:[self.class testRunWithTest:self]].
- (void)runTest;

- (void)setUp;
- (void)tearDown;

/// Async-capable lifecycle hooks. The default implementations call the void
/// variants, so subclasses may override either form.
- (void)setUpWithCompletionHandler:(void (^)(NSError *_Nullable error))completion;
- (BOOL)setUpWithError:(NSError **)error;
- (void)tearDownWithCompletionHandler:(void (^)(NSError *_Nullable error))completion;
- (BOOL)tearDownWithError:(NSError **)error;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCABSTRACTTEST_H */
