// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Private plumbing shared between the XCTest implementation files. Not
// installed into the framework and not part of the public contract.

#import "XCTestInternal.h"

NS_ASSUME_NONNULL_BEGIN

NSExceptionName const _XCTInternalUnwindExceptionName =
    @"XCTestInternalUnwindException";

/// The test case currently running on this thread.
///
/// Thread-local rather than global or a property on the suite. A test's helper
/// methods, expectation callbacks and teardown blocks all need to know which
/// test they belong to, and none of them have the case in hand; passing it
/// through every signature would be a large, permanent tax on the public API.
/// A global would be wrong in the other direction, because parallel test
/// execution would cross-contaminate.
static __thread __unsafe_unretained XCTestCase *_XCTCurrentTestCaseStorage = nil;

XCT_EXPORT void _XCTSetCurrentTestCase(XCTestCase *_Nullable testCase)
{
    _XCTCurrentTestCaseStorage = testCase;
}

XCT_EXPORT XCTestCase *_Nullable _XCTCurrentTestCase(void)
{
    return _XCTCurrentTestCaseStorage;
}

XCT_EXPORT XCTSourceCodeContext *_XCTSourceCodeContextAtLocation(const char *filePath,
                                                                 NSUInteger lineNumber)
{
    return [XCTSourceCodeContext xct_contextWithFilePath:[NSString stringWithUTF8String:filePath ?: "?"]
                                               lineNumber:lineNumber];
}

XCT_EXPORT void _XCTRecordIssueOnTestCase(XCTestCase *_Nullable testCase,
                                          XCTIssue *issue)
{
    if (testCase == nil) {
        return;
    }
    [testCase recordIssue:issue];
}

NS_ASSUME_NONNULL_END
