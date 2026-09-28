// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Private plumbing shared between the XCTest implementation files. Not
// installed into the framework and not part of the public contract.

#ifndef XCTEST_XCTESTINTERNAL_H
#define XCTEST_XCTESTINTERNAL_H

#import <XCTest/XCTest.h>

// The Internal SDK ships no <execinfo.h>: backtrace() and
// backtrace_symbols() live in libSystem, but their declarations ride along in
// that header, which is absent. They are ordinary BSD functions and are
// present in the library (verified against libSystem.tbd and by calling them),
// so declare them here rather than dropping backtraces from the framework.
// dlfcn.h is present in the SDK and is what supplies Dl_info/dladdr.
#include <dlfcn.h>

// Annotated explicitly rather than relying on an assume_nonnull region: these
// sit outside one, and -Wnullability-completeness is enabled.
extern int backtrace(void *_Nonnull *_Nonnull buffer, int size);
extern char *_Nonnull *_Nullable backtrace_symbols(void *_Nonnull const *_Nonnull buffer, int size);

NS_ASSUME_NONNULL_BEGIN

@class XCTIssue;
@class XCTExpectedFailure;
@class XCTExpectedFailureOptions;

/// The exception name used for the internal unwind exceptions. Matches what the
/// shipping implementation uses, so a debugger or a crash reporter that
/// inspects exception names sees the familiar value.
///
/// The two exception types themselves are declared where they are raised:
/// _XCTSkipFailureException in XCTestSkippingImpl.h, and
/// _XCTestCaseInterruptionException in XCTestAssertionsImpl.h. Both are
/// private, and neither needs a payload -- the issue is recorded on the run
/// before the raise, so the runner only has to recognise the type to know
/// whether the test stopped deliberately.
XCT_EXPORT NSExceptionName const _XCTInternalUnwindExceptionName;

/// Installs the current test case for the duration of a test body, so helpers
/// invoked without a receiver (expectation fulfillers, async teardown) can
/// still attribute issues to the right run. Thread-local rather than global:
/// XCTest cases may run concurrently in separate processes, and a global here
/// would cross-contaminate them.
XCT_EXPORT void _XCTSetCurrentTestCase(XCTestCase *_Nullable testCase);
XCT_EXPORT XCTestCase *_Nullable _XCTCurrentTestCase(void);

/// The stack of XCTExpectFailure declarations made by a running test.
///
/// A stack because declarations nest, and a failure is absorbed by the closest
/// matching one. The stack lives on the test case rather than in a thread local:
/// a __thread variable cannot hold an object under ARC, and the state belongs to
/// the test being run anyway.
@interface XCTestCase (XCTInternalExpectedFailure)
/// Pushes a declaration and returns the scope standing for it. `options` is
/// copied, so the caller may reuse its own.
- (id)_xct_pushExpectedFailureWithReason:(nullable NSString *)reason
                                  options:(nullable XCTExpectedFailureOptions *)options;
/// Discards one specific declaration, for the block forms, where a declaration
/// never outlives its block.
///
/// Takes the scope rather than popping the top of the stack: a nested block's
/// failure may already have consumed its own declaration, and popping the top
/// then would discard the enclosing one that is still waiting to match.
- (void)_xct_removeExpectedFailureScope:(id)scope;
/// Consumes and returns the reason of the closest declaration that absorbs
/// `issue`, or nil if none does. Consuming is what makes two consecutive
/// declarations require two distinct failures to clear them.
- (nullable NSString *)_xct_matchExpectedFailureForIssue:(XCTIssue *)issue;
/// Reports every declaration still standing at the end of the test as
/// XCTIssueTypeUnmatchedExpectedFailure, then clears the stack.
- (void)_xct_finishExpectedFailures;
/// Records the thread the test body runs on, which is the only thread whose
/// declarations are allowed to absorb issues recorded on any thread.
- (void)_xct_markPrimaryThread;
@end

@class XCTExpectedFailure;

/// Records an issue and reports whether a declaration absorbed it.
///
/// The public -recordIssue: is the same funnel with the answer discarded; a test
/// case needs it in order to decide whether to unwind after the failure.
@interface XCTestRun (XCTInternalExpectedFailure)
- (BOOL)_xct_recordIssue:(XCTIssue *)issue;
@end

/// The one way to build an XCTExpectedFailure, which is not constructible by
/// callers: a declaration is only meaningful as the framework's record of a
/// specific issue being absorbed by a specific declaration.
@interface XCTExpectedFailure (XCTInternalConstruction)
- (instancetype)initWithIssue:(XCTIssue *)issue
                failureReason:(nullable NSString *)failureReason;
@end

/// Builds an XCTSourceCodeContext for a call site whose file and line the
/// caller already knows.
@interface XCTSourceCodeContext (XCTInternal)
+ (instancetype)xct_contextWithFilePath:(NSString *)filePath
                             lineNumber:(NSUInteger)lineNumber;
@end

/// Builds an XCTSourceCodeContext for a call site whose file and line the
/// caller already knows: the assertion macros have __FILE__ and __LINE__ as
/// literals, so there is nothing to resolve from a stack address.
XCT_EXPORT XCTSourceCodeContext *_XCTSourceCodeContextAtLocation(const char *filePath,
                                                                 NSUInteger lineNumber);

/// The source context for wherever the runner is now -- used by failure paths
/// that have no call-site file and line of their own, such as an exception
/// escaping a test body.
XCT_EXPORT XCTSourceCodeContext *_XCTCurrentSourceCodeContext(void);

/// Records an issue on `testCase` (or, when nil, on the current test case),
/// applying the continueAfterFailure unwind policy. The one place an issue
/// enters the system, so every failure path gets identical treatment.
XCT_EXPORT void _XCTRecordIssueOnTestCase(XCTestCase *_Nullable testCase,
                                          XCTIssue *issue);

/// Read-write access to a run's bookkeeping. The public API exposes these as
/// readonly because a run is meant to be changed by driving it, not by poking at
/// it; the runner is the driver.
@interface XCTestRun (XCTInternal)
@property (readwrite, copy, nullable) NSDate *startDate;
@property (readwrite, copy, nullable) NSDate *stopDate;
@property (readwrite) NSUInteger testCaseCount;
@property (readwrite) NSUInteger executionCount;
@property (readwrite) NSUInteger skipCount;
@property (readwrite) NSUInteger failureCount;
@property (readwrite) NSUInteger unexpectedExceptionCount;
@property (readwrite) BOOL hasBeenSkipped;
@end

/// A test adopts the run it is performed against, which is what -performTest:
/// takes; the setter is private for the same reason as XCTestRun's above.
@interface XCTest (XCTInternal)
@property (readwrite, strong, nullable) XCTestRun *testRun;
@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTINTERNAL_H */
