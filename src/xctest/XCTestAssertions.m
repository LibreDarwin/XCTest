// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The runtime behind the XCTAssert* and XCTSkip families.
//
// The generated macros reduce every assertion to the same shape: a description
// string plus a call to _XCTRegisterFailure, which lands here. Keeping the
// interesting decisions in this file rather than in the macros is what makes
// them uniform -- a failure recorded from a macro and one recorded by the
// runner itself go through identical code, so they cannot drift apart.

#import "XCTestInternal.h"

#import <XCTest/XCTestAssertionsImpl.h>
#import <XCTest/XCTestSkippingImpl.h>

#import "XCTestAssertionFormats.h"

#include <stdio.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Internal exceptions

@implementation _XCTestCaseInterruptionException
@end

@implementation _XCTSkipFailureException
@end

#pragma mark - Exception reason

XCT_WEAK_EXPORT NSString *_XCTReasonForException(NSException *exception)
{
    if (exception.reason.length > 0) {
        return exception.reason;
    }
    if (exception.name.length > 0) {
        return exception.name;
    }
    return @"an exception with no reason";
}

#pragma mark - Value rendering

XCT_EXPORT NSString *_Nullable _XCTDescriptionForValue(NSValue *_Nullable value)
{
    if (value == nil) {
        return @"(null)";
    }

    // -description on a boxed scalar gives the value in a readable form, and
    // for the object case gives something better than a bare pointer. It can
    // throw if a custom -description misbehaves, and a failure message must
    // never be the thing that crashes the run.
    @try {
        NSString *description = value.description;
        if (description.length > 0) {
            return description;
        }
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"<unprintable value: %@>",
                exception.name ?: @"NSException"];
    } @catch (...) {
        return @"<unprintable value>";
    }

    return @"<empty description>";
}

#pragma mark - Failure recording

/// Builds the issue for a failure and hands it to the running test.
///
/// `expected` is YES for an assertion failure and NO for something the test did
/// not anticipate. It selects only between an assertion failure and an escaped
/// exception, because an escaped exception is a signal that the code under test
/// is broken rather than merely wrong.
///
/// An XCTExpectFailure declaration does not change the type here. The issue
/// keeps the type it really has, and the run decides afterwards whether a
/// declaration absorbed it; a declaration that did not match leaves a genuine
/// assertion failure behind, which is what makes a fixed known bug show up.
static void _XCTRecordFailure(XCTestCase *_Nullable test,
                              BOOL expected,
                              const char *filePath,
                              NSUInteger lineNumber,
                              NSString *condition,
                              NSString *_Nullable message)
{
    XCTestCase *testCase = test ?: _XCTCurrentTestCase();

    XCTIssueType type = expected ? XCTIssueTypeAssertionFailure
                                 : XCTIssueTypeUncaughtException;

    // The compact description is the one-line summary shown in the failure
    // list, so it stays short; everything the user wrote goes in the detailed
    // description, which is where the full text is rendered.
    NSString *compact = condition;
    NSString *detailed = message;

    XCTSourceCodeContext *context = _XCTSourceCodeContextAtLocation(filePath, lineNumber);

    XCTIssue *issue = [[XCTIssue alloc] initWithType:type
                                 compactDescription:compact
                                detailedDescription:detailed
                                  sourceCodeContext:context
                                    associatedError:nil
                                        attachments:@[]];

    if (testCase == nil) {
        // An assertion outside any test has no run to attach to. Reporting it
        // to stderr is the only way it can be seen at all, and staying silent
        // would let a broken helper look like a passing run.
        fprintf(stderr, "%s:%lu: %s%s%s\n",
                filePath ?: "?", (unsigned long)lineNumber,
                compact.UTF8String ?: "",
                (detailed.length > 0 ? " -- " : ""),
                detailed.UTF8String ?: "");
        fflush(stderr);
        return;
    }

    _XCTRecordIssueOnTestCase(testCase, issue);
}

XCT_EXPORT void _XCTFailureHandler(XCTestCase *_Nullable test,
                                   BOOL expected,
                                   const char *filePath,
                                   NSUInteger lineNumber,
                                   NSString *condition,
                                   NSString *_Nullable format, ...)
{
    NSString *message = nil;
    if (format != nil) {
        va_list arguments;
        va_start(arguments, format);
        message = [[NSString alloc] initWithFormat:format arguments:arguments];
        va_end(arguments);
    }

    _XCTRecordFailure(test, expected, filePath, lineNumber, condition, message);
}

XCT_EXPORT void _XCTPreformattedFailureHandler(XCTestCase *_Nullable test,
                                               BOOL expected,
                                               NSString *filePath,
                                               NSUInteger lineNumber,
                                               NSString *condition,
                                               NSString *message)
{
    _XCTRecordFailure(test, expected, filePath.UTF8String, lineNumber,
                      condition, message);
}

#pragma mark - Skip recording

/// Records a skip and unwinds out of the test body.
///
/// The record happens before the raise on purpose. The runner catches
/// _XCTSkipFailureException to stop the test, and by then the skip issue has to
/// already be on the run, or a skipped test would be reported as having neither
/// passed nor skipped.
static void _XCTRecordSkipAndUnwind(NSString *condition,
                                    const char *filePath,
                                    NSUInteger lineNumber,
                                    NSString *message)
{
    XCTestCase *testCase = _XCTCurrentTestCase();
    XCTSourceCodeContext *context = _XCTSourceCodeContextAtLocation(filePath, lineNumber);

    if (testCase != nil) {
        XCTIssue *issue = [[XCTIssue alloc]
            initWithType:XCTIssueTypeSkippedTest
                compactDescription:condition
               detailedDescription:message
                 sourceCodeContext:context
                   associatedError:nil
                       attachments:@[]];
        _XCTRecordIssueOnTestCase(testCase, issue);
    }

    // One allocation, one raise. Building the exception separately from raising
    // it would be a second chance to leak it.
    [[[_XCTSkipFailureException alloc] initWithName:_XCTInternalUnwindExceptionName
                                             reason:condition
                                           userInfo:nil] raise];
}

XCT_EXPORT void _XCTSkipHandler(const char *filePath,
                                NSUInteger lineNumber,
                                NSString *format, ...)
{
    NSString *message = nil;
    if (format != nil) {
        va_list arguments;
        va_start(arguments, format);
        message = [[NSString alloc] initWithFormat:format arguments:arguments];
        va_end(arguments);
    }

    _XCTRecordSkipAndUnwind(@"Test skipped", filePath, lineNumber, message);
}

XCT_EXPORT void _XCTSkipHandlerForExpectedValue(NSString *condition,
                                                BOOL expectedValue,
                                                const char *filePath,
                                                NSUInteger lineNumber,
                                                NSString *format, ...)
{
    NSString *message = nil;
    if (format != nil) {
        va_list arguments;
        va_start(arguments, format);
        message = [[NSString alloc] initWithFormat:format arguments:arguments];
        va_end(arguments);
    }

    NSString *description = expectedValue
        ? [NSString stringWithFormat:@"Test skipped because (%@) was true", condition]
        : [NSString stringWithFormat:@"Test skipped because (%@) was false", condition];

    _XCTRecordSkipAndUnwind(description, filePath, lineNumber, message);
}

XCT_EXPORT void _XCTSkipHandlerForException(NSString *condition,
                                            NSException *_Nullable exception,
                                            const char *filePath,
                                            NSUInteger lineNumber,
                                            NSString *format, ...)
{
    NSString *message = nil;
    if (format != nil) {
        va_list arguments;
        va_start(arguments, format);
        message = [[NSString alloc] initWithFormat:format arguments:arguments];
        va_end(arguments);
    }

    // A skip request whose condition could not be evaluated is not a skip. The
    // test asked whether it was safe to continue and got no answer, so it is
    // recorded as a failure instead -- otherwise a crashing precondition would
    // quietly become a passing run.
    NSString *description = [NSString stringWithFormat:
        @"Could not evaluate skip condition (%@): %@", condition,
        exception ? (exception.reason ?: exception.name) : @"non-ObjC exception"];

    _XCTRecordFailure(nil, NO, filePath, lineNumber, description, message);
}

NS_ASSUME_NONNULL_END
