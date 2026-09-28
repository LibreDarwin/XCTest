// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Runtime entry point behind XCTSkip. Internal.
//
// A skip is a control-flow decision, not a diagnostic. The primitives below
// therefore record the issue themselves and then raise, so the remainder of
// the test body never runs. A failure assertion instead records and returns,
// letting the test continue unless continueAfterFailure says otherwise; the two
// behaviours differ enough that sharing a primitive would be misleading.

#ifndef XCTEST_XCTESTSKIPPINGIMPL_H
#define XCTEST_XCTESTSKIPPINGIMPL_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

/// Raised to unwind out of a test body once a skip has been recorded. The
/// handler raises it, so control leaves the test immediately after the skip is
/// noted. It is deliberately a distinct type from the internal failure
/// exception: the runner must be able to tell "the test chose to stop" from
/// "the test failed and was told to stop".
@interface _XCTSkipFailureException : NSException
@end

/// Records XCTIssueTypeSkippedTest against the current test and unwinds.
XCT_EXPORT void _XCTSkipHandler(const char *filePath,
                                NSUInteger lineNumber,
                                NSString *format, ...)
    NS_FORMAT_FUNCTION(3, 4);

/// As _XCTSkipHandler, but reached from XCTSkipIf/XCTSkipUnless, which have a
/// condition to name in the recorded issue. `expectedValue` is the boolean the
/// condition was compared against -- YES for XCTSkipIf, NO for XCTSkipUnless --
/// so the message can say which of the two triggered it.
XCT_EXPORT void _XCTSkipHandlerForExpectedValue(NSString *condition,
                                                BOOL expectedValue,
                                                const char *filePath,
                                                NSUInteger lineNumber,
                                                NSString *format, ...)
    NS_FORMAT_FUNCTION(5, 6);

/// As _XCTSkipHandlerForExpectedValue, but for the case where evaluating the
/// condition itself raised. A skip request whose condition cannot be evaluated
/// cannot be honoured, so this is recorded as a failure instead: silently
/// skipping a test whose precondition crashed would hide a real defect.
XCT_EXPORT void _XCTSkipHandlerForException(NSString *condition,
                                            NSException *_Nullable exception,
                                            const char *filePath,
                                            NSUInteger lineNumber,
                                            NSString *format, ...)
    NS_FORMAT_FUNCTION(5, 6);

// The statement-expression form lets a skip be written where an expression is
// expected while still declaring the local it needs to hold the condition. The
// pragma keeps the warning from firing at every use site; it is scoped to this
// expansion and does not affect the rest of the translation unit.
#define _XCT_SKIP_BEGIN \
    _Pragma("clang diagnostic push") \
    _Pragma("clang diagnostic ignored \"-Wgnu-statement-expression-from-macro-expansion\"") \
    ({ \
    _Pragma("clang diagnostic pop")

#define _XCT_SKIP_END })

#define _XCTPrimitiveSkip(...) \
_XCT_SKIP_BEGIN \
    _XCTSkipHandler(__FILE__, __LINE__, @"" __VA_ARGS__); \
_XCT_SKIP_END

#define _XCTPrimitiveSkipIfEqual(expression, expectedValue, expressionStr, ...) \
_XCT_SKIP_BEGIN \
    @try { \
        BOOL expressionValue = !!(expression); \
        if (expressionValue == expectedValue) { \
            _XCTSkipHandlerForExpectedValue(expressionStr, expectedValue, __FILE__, __LINE__, @"" __VA_ARGS__); \
        } \
    } \
    @catch (_XCTSkipFailureException *exception) { [exception raise]; } \
    @catch (NSException *exception) { \
        _XCTSkipHandlerForException(expressionStr, exception, __FILE__, __LINE__, @"" __VA_ARGS__); \
    } \
    @catch (...) { \
        _XCTSkipHandlerForException(expressionStr, nil, __FILE__, __LINE__, @"" __VA_ARGS__); \
    } \
_XCT_SKIP_END

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTSKIPPINGIMPL_H */
