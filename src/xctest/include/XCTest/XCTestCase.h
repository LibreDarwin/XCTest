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
#import <XCTest/XCTMetric.h>
#import <XCTest/XCTMeasureOptions.h>

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

/// Performance measurement: invoke a block repeatedly and report what it cost.
///
/// There are two generations of this API in one category, and they are not
/// interchangeable. The `XCTPerformanceMetric` string family predates the
/// `XCTMetric` object family; both are here because test bundles in the wild use
/// both, and a runner that implemented only the new one would silently measure
/// nothing for the old one. `measureBlock:` is the old entry point and routes
/// through to the same machinery, so a test that uses it gets the same
/// iteration count, the same discarded warm-up, and the same results.
@interface XCTestCase (XCTPerformanceAnalysis)

/// The name of a metric the string-based API can measure.
typedef NSString * XCTPerformanceMetric NS_TYPED_EXTENSIBLE_ENUM;

/// Wall clock seconds between -startMeasuring and -stopMeasuring.
XCT_EXPORT XCTPerformanceMetric const XCTPerformanceMetric_WallClockTime;

/// The string metrics -measureBlock: measures. Defaults to just
/// XCTPerformanceMetric_WallClockTime. Override to change what -measureBlock:
/// does, which is the supported way to add a metric without rewriting the call
/// site.
@property (class, readonly, copy) NSArray<XCTPerformanceMetric> *defaultPerformanceMetrics;

/// Measure `block` with +defaultPerformanceMetrics.
- (void)measureBlock:(XCT_NOESCAPE void (^)(void))block;

/// Measure `block` with the named metrics.
///
/// Passing NO for `automaticallyStartMeasuring` means the block must call
/// -startMeasuring itself. A block that never calls it is a test failure rather
/// than a measurement of nothing, since the alternative is a number that looks
/// real and means nothing. A block that calls it anyway is also a failure.
/// An unrecognized metric name is a test failure.
- (void)measureMetrics:(NSArray<XCTPerformanceMetric> *)metrics
    automaticallyStartMeasuring:(BOOL)automaticallyStartMeasuring
                     forBlock:(XCT_NOESCAPE void (^)(void))block;

/// Mark the start of the measured region, from inside a measure block.
- (void)startMeasuring;

/// Mark the end of the measured region, from inside a measure block. Calling
/// this more than once per iteration is a test failure.
- (void)stopMeasuring;

/// The object metrics -measureWithMetrics:block: and friends use by default.
/// Defaults to a single XCTClockMetric.
@property (class, readonly, copy) NSArray<id<XCTMetric>> *defaultMetrics;

/// A fresh copy of the recommended measure options. Override to change the
/// iteration count or the invocation options for every measurement in a class.
@property (class, readonly, copy) XCTMeasureOptions *defaultMeasureOptions;

/// Measure `block` with `metrics` and +defaultMeasureOptions.
- (void)measureWithMetrics:(NSArray<id<XCTMetric>> *)metrics
                     block:(XCT_NOESCAPE void (^)(void))block;

/// Measure `block` with +defaultMetrics and `options`.
- (void)measureWithOptions:(XCTMeasureOptions *)options
                     block:(XCT_NOESCAPE void (^)(void))block;

/// Measure `block` with `metrics` and `options`.
- (void)measureWithMetrics:(NSArray<id<XCTMetric>> *)metrics
                   options:(XCTMeasureOptions *)options
                     block:(XCT_NOESCAPE void (^)(void))block;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTCASE_H */
