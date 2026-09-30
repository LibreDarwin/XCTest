// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The XCTExpectFailure family: declaring that a test is known to fail, so the
// failure is documented without turning the suite red.
//
// All four entry points are thin. The decision of whether a recorded issue is
// absorbed belongs to the run, which is the single funnel every issue passes
// through, and the declarations themselves live on the running test. What is
// left here is turning a call into a push, a pop, or both.

#import <XCTest/XCTestCase.h>
#import <XCTest/XCTExpectedFailure.h>

#import "XCTestInternal.h"

/// The defaults a declaration gets when the caller passes no options: enabled,
/// matching every issue, and strict.
static XCTExpectedFailureOptions *_XCTDefaultExpectedFailureOptions(void)
{
    return [[XCTExpectedFailureOptions alloc] init];
}

/// The test the declaration belongs to. Outside a running test there is nothing
/// to attach a declaration to, so it is recorded nowhere and the test's issues
/// are left alone; an expectation with no run cannot suppress anything.
static XCTestCase *_XCTTestCaseForDeclaration(void)
{
    return _XCTCurrentTestCase();
}

XCT_EXPORT void XCTExpectFailure(NSString *failureReason)
{
    [_XCTTestCaseForDeclaration() _xct_pushExpectedFailureWithReason:failureReason
                                                              options:nil];
}

XCT_EXPORT void XCTExpectFailureWithOptions(NSString *failureReason,
                                            XCTExpectedFailureOptions *options)
{
    [_XCTTestCaseForDeclaration()
        _xct_pushExpectedFailureWithReason:failureReason
                                    options:options ?: _XCTDefaultExpectedFailureOptions()];
}

XCT_EXPORT void XCTExpectFailureInBlock(NSString *failureReason,
                                        void (^failingBlock)(void))
{
    XCTestCase *testCase = _XCTTestCaseForDeclaration();
    id scope = [testCase _xct_pushExpectedFailureWithReason:failureReason options:nil];
    @try {
        failingBlock();
    } @finally {
        // Withdrawn however the block is left, including a throw. A block that
        // raises would otherwise leave the declaration standing for the rest of
        // the test, silently absorbing the next real failure.
        [testCase _xct_removeExpectedFailureScope:scope];
    }
}

XCT_EXPORT void XCTExpectFailureWithOptionsInBlock(NSString *failureReason,
                                                   XCTExpectedFailureOptions *options,
                                                   void (^failingBlock)(void))
{
    XCTestCase *testCase = _XCTTestCaseForDeclaration();
    id scope = [testCase _xct_pushExpectedFailureWithReason:failureReason
                                                    options:options ?: _XCTDefaultExpectedFailureOptions()];
    @try {
        failingBlock();
    } @finally {
        [testCase _xct_removeExpectedFailureScope:scope];
    }
}
