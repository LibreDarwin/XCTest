// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A single test: one zero-argument, void-returning instance method.

#ifndef XCTEST_XCTESTCASE_H
#define XCTEST_XCTESTCASE_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCAbstractTest.h>
#import <XCTest/XCTestSuite.h>
#import <XCTest/XCTIssue.h>
#import <XCTest/XCTestAssertions.h>
#import <XCTest/XCTestSkipping.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTestCase : XCTest

+ (instancetype)testCaseWithInvocation:(nullable NSInvocation *)invocation;
- (instancetype)initWithInvocation:(nullable NSInvocation *)invocation NS_DESIGNATED_INITIALIZER;

/// Returns nil when the receiver's class has no method for `selector`.
+ (nullable instancetype)testCaseWithSelector:(SEL)selector;
- (instancetype)initWithSelector:(SEL)selector;

/// The method to run, with its target already set to this instance.
@property (strong, nullable) NSInvocation *invocation;

/// Invokes -invocation, translating an escaping exception into an unexpected
/// exception on the run rather than letting it cross the frame.
- (void)invokeTest;

/// When NO (the default) a failing assertion raises immediately, so later
/// assertions in the same method do not run. Set it in a test that needs to
/// report several independent problems.
@property BOOL continueAfterFailure;

/// Funnels an issue to this case's run, then to the observation center.
- (void)recordIssue:(XCTIssue *)issue;

/// Every zero-argument void method on the receiver whose name starts with
/// "test", sorted by name, as invocations targeting this class.
@property (class, readonly, copy) NSArray<NSInvocation *> *testInvocations;

/// Registers a block to run after the test body, in reverse registration
/// order, so teardown nests like a stack.
- (void)addTeardownBlock:(void (^)(void))block;

/// As -addTeardownBlock:, but the block is handed a completion callback it
/// must invoke exactly once. Runs after all synchronous teardown blocks.
- (void)addAsyncTeardownBlock:(void (^)(void (^completion)(NSError *_Nullable error)))block;

/// Seconds the test may run before the runner interrupts it. 0 disables.
@property NSTimeInterval executionTimeAllowance;

@end

/// Lifecycle hooks that run once per test case rather than once per test.
@interface XCTestCase (XCTestSuiteExtensions)
@property (class, readonly) XCTestSuite *defaultTestSuite;
+ (void)setUp;
+ (void)tearDown;
@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTCASE_H */
