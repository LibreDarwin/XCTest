// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Runtime entry points behind the XCTAssert* macros. Not part of the public
// contract: it exists so the macros in XCTestAssertions.h can stay
// expression-shaped while the actual issue recording happens in one place.
//
// The public macros pass four things that cannot be recovered at runtime: the
// enclosing XCTestCase, the file and line, and the stringified source text of
// the expression. Those come from __FILE__, __LINE__ and @#expression, so they
// are baked in at the call site by _XCTRegisterFailure below. That is why the
// primitives take a `test` argument and a description of each operand rather
// than just a boolean result.

#ifndef XCTEST_XCTESTASSERTIONSIMPL_H
#define XCTEST_XCTESTASSERTIONSIMPL_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTIssue.h>

// isnan/MAX/MIN appear in the generated accuracy primitives.
#include <math.h>

@class XCTestCase;

XCT_HEADER_AUDIT_BEGIN

/// Thrown to unwind a test that has been interrupted -- for example because a
/// timeout elapsed. The primitives re-raise it rather than treating it as a
/// failure, so an interruption is never silently reported as a wrong answer.
@interface _XCTestCaseInterruptionException : NSException
@end

/// The single funnel every failing assertion goes through.
///
/// `test` is the enclosing XCTestCase, or nil when an assertion is evaluated
/// outside a test; the issue then goes to stderr instead. `expected` marks a
/// failure that XCTExpectFailure declared, which makes it non-fatal.
XCT_EXPORT void _XCTFailureHandler(XCTestCase *_Nullable test,
                                   BOOL expected,
                                   const char *filePath,
                                   NSUInteger lineNumber,
                                   NSString *condition,
                                   NSString *_Nullable format, ...)
    NS_FORMAT_FUNCTION(6, 7);

/// As _XCTFailureHandler, but for callers that have already built the
/// description string and must not pay for varargs formatting twice.
XCT_EXPORT void _XCTPreformattedFailureHandler(XCTestCase *_Nullable test,
                                               BOOL expected,
                                               NSString *filePath,
                                               NSUInteger lineNumber,
                                               NSString *condition,
                                               NSString *message);

/// Records a failure at the call site. `condition` is the already-rendered
/// description; the trailing varargs are the caller's optional supplementary
/// message.
///
/// The `@"" __VA_ARGS__` idiom is what makes that message optional. With no
/// argument the expansion is a bare `@""`, a valid empty format. With arguments
/// the leading `@""` concatenates with the literal at compile time, so
/// `@"was %d", n` still produces exactly one format string and one argument.
#define _XCTRegisterFailure(test, condition, ...) \
    _XCTFailureHandler(test, YES, __FILE__, __LINE__, condition, @"" __VA_ARGS__)

/// As _XCTRegisterFailure, but for a failure caused by the test raising an
/// exception rather than by an assertion not holding. These are reported as
/// unexpected even inside an XCTExpectFailure block, because an exception
/// usually means the code under test is broken rather than merely wrong.
#define _XCTRegisterUnexpectedFailure(test, condition, ...) \
    _XCTFailureHandler(test, NO, __FILE__, __LINE__, condition, @"" __VA_ARGS__)

#pragma mark - Failure descriptions

typedef NS_ENUM(NSUInteger, _XCTAssertionType) {
    _XCTAssertion_Fail,
    _XCTAssertion_Nil,
    _XCTAssertion_NotNil,
    _XCTAssertion_EqualObjects,
    _XCTAssertion_NotEqualObjects,
    _XCTAssertion_Equal,
    _XCTAssertion_NotEqual,
    _XCTAssertion_EqualWithAccuracy,
    _XCTAssertion_NotEqualWithAccuracy,
    _XCTAssertion_GreaterThan,
    _XCTAssertion_GreaterThanOrEqual,
    _XCTAssertion_LessThan,
    _XCTAssertion_LessThanOrEqual,
    _XCTAssertion_True,
    _XCTAssertion_False,
    _XCTAssertion_Throws,
    _XCTAssertion_ThrowsSpecific,
    _XCTAssertion_ThrowsSpecificNamed,
    _XCTAssertion_NoThrow,
    _XCTAssertion_NoThrowSpecific,
    _XCTAssertion_NoThrowSpecificNamed,
    _XCTAssertion_Unwrap,
    _XCTAssertion_Identical,
    _XCTAssertion_NotIdentical,
};

/// The format string for a given assertion and variant. Generated alongside the
/// macros that call it; see tools/xct-assertions.py.
XCT_EXPORT NSString *_Nullable _XCTFailureFormat(_XCTAssertionType assertionType,
                                                 NSUInteger formatIndex);

/// Renders the failure text. The format is chosen at runtime by index, so
/// stringWithFormat is handed a non-literal and clang would otherwise reject it.
#define _XCTFailureDescription(assertion_type, format_index, ...) \
    _Pragma("clang diagnostic push") \
    _Pragma("clang diagnostic ignored \"-Wformat-nonliteral\"") \
    [NSString stringWithFormat:_XCTFailureFormat(assertion_type, format_index), @"" __VA_ARGS__] \
    _Pragma("clang diagnostic pop")

/// Human-readable rendering of a boxed value, for use in failure messages.
XCT_EXPORT NSString *_Nullable _XCTDescriptionForValue(NSValue *_Nullable value);

#pragma mark - Exception plumbing

// The primitives are written once and used from both languages. C++ needs real
// try/catch and a reference type for the catch clause, because binding a
// thrown ObjC exception to an `NSException *` would not compile there.
#if defined(__cplusplus) && __has_feature(cxx_exceptions)
#define _XCT_TRY try
#define _XCT_CATCHABLE_TYPE(T) \
    typename std::conditional<std::is_convertible<T *, id>::value, T *, const T &>::type
#define _XCT_CATCH(T) catch (T)
#define _XCT_THROW throw
#else
#define _XCT_TRY @try
#define _XCT_CATCHABLE_TYPE(T) T *
#define _XCT_CATCH(T) @catch (T)
#define _XCT_THROW @throw
#endif

// Each primitive is a statement expression, so it can be used wherever an
// expression is expected and still declare the locals it needs to evaluate its
// operands exactly once. The pragmas keep the statement expression from
// warning at every use site; the diagnostic is suppressed only around the
// expansion, not for the rest of the translation unit.
#define _XCT_ASSERT_BEGIN \
    _Pragma("clang diagnostic push") \
    _Pragma("clang diagnostic ignored \"-Wgnu-statement-expression-from-macro-expansion\"") \
    ({ \
    _Pragma("clang diagnostic pop")
#define _XCT_ASSERT_END })

/// Renders a caught exception for a failure message.
///
/// Prefers -reason, because that is what the raising code meant to say. Falls
/// back to -name for an exception raised with no reason, and finally to a fixed
/// string: a message containing "(null)" is worse than one that admits it could
/// not tell.
XCT_WEAK_EXPORT NSString *_XCTReasonForException(NSException *exception);

XCT_HEADER_AUDIT_END

#pragma mark - Primitives

// BEGIN GENERATED ASSERTION PRIMITIVES
// Generated by tools/xct-assertions.py. Do not edit by hand:
// re-run the generator instead. See that file for why this is generated.

#define _XCTPrimitiveFail(test, ...) \
    _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_Fail, 0, ""), __VA_ARGS__)

#define _XCTPrimitiveAssertNil(test, expression, expressionStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            id expressionValue = (expression); \
            if (expressionValue != nil) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_Nil, 0, expressionStr, expressionValue), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_Nil, 1, expressionStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_Nil, 1, expressionStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNotNil(test, expression, expressionStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            id expressionValue = (expression); \
            if (expressionValue == nil) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NotNil, 0, expressionStr), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotNil, 1, expressionStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotNil, 1, expressionStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertTrue(test, expression, expressionStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            BOOL expressionValue = (expression) ? YES : NO; \
            if (!expressionValue) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_True, 0, expressionStr), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_True, 1, expressionStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_True, 1, expressionStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertFalse(test, expression, expressionStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            BOOL expressionValue = (expression) ? YES : NO; \
            if (expressionValue) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_False, 0, expressionStr), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_False, 1, expressionStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_False, 1, expressionStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertEqualObjects(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            id expression1Value = (expression1); \
            id expression2Value = (expression2); \
            if ((expression1Value != expression2Value) && ![(id<NSObject>)expression1Value isEqual:expression2Value]) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_EqualObjects, 0, expressionStr1, expressionStr2, expression1Value, expression2Value), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_EqualObjects, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_EqualObjects, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNotEqualObjects(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            id expression1Value = (expression1); \
            id expression2Value = (expression2); \
            if ((expression1Value == expression2Value) || [(id<NSObject>)expression1Value isEqual:expression2Value]) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqualObjects, 0, expressionStr1, expressionStr2, expression1Value, expression2Value), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqualObjects, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqualObjects, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertIdentical(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            id expression1Value = (expression1); \
            id expression2Value = (expression2); \
            if ((expression1Value != expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_Identical, 0, expressionStr1, expressionStr2), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_Identical, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_Identical, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNotIdentical(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            id expression1Value = (expression1); \
            id expression2Value = (expression2); \
            if ((expression1Value == expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NotIdentical, 0, expressionStr1, expressionStr2), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotIdentical, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotIdentical, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertEqual(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            if (!(expression1Value == expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_Equal, 0, expressionStr1, expressionStr2, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_Equal, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_Equal, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNotEqual(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            if ((expression1Value == expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqual, 0, expressionStr1, expressionStr2, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqual, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqual, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertGreaterThan(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            if (!(expression1Value > expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_GreaterThan, 0, expressionStr1, expressionStr2, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_GreaterThan, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_GreaterThan, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertGreaterThanOrEqual(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            if (!(expression1Value >= expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_GreaterThanOrEqual, 0, expressionStr1, expressionStr2, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_GreaterThanOrEqual, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_GreaterThanOrEqual, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertLessThan(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            if (!(expression1Value < expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_LessThan, 0, expressionStr1, expressionStr2, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_LessThan, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_LessThan, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertLessThanOrEqual(test, expression1, expressionStr1, expression2, expressionStr2, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            if (!(expression1Value <= expression2Value)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_LessThanOrEqual, 0, expressionStr1, expressionStr2, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_LessThanOrEqual, 1, expressionStr1, expressionStr2, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_LessThanOrEqual, 1, expressionStr1, expressionStr2, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertEqualWithAccuracy(test, expression1, expressionStr1, expression2, expressionStr2, accuracy, accuracyStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            __typeof__(accuracy) accuracyValue = (accuracy); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            NSValue *accuracyBox = [NSValue value:&accuracyValue withObjCType:@encode(__typeof__(accuracy))]; \
            if (isnan(expression1Value) || isnan(expression2Value) || ((MAX(expression1Value, expression2Value) - MIN(expression1Value, expression2Value)) > accuracyValue)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_EqualWithAccuracy, 0, expressionStr1, expressionStr2, accuracyStr, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box), _XCTDescriptionForValue(accuracyBox)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_EqualWithAccuracy, 1, expressionStr1, expressionStr2, accuracyStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_EqualWithAccuracy, 1, expressionStr1, expressionStr2, accuracyStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNotEqualWithAccuracy(test, expression1, expressionStr1, expression2, expressionStr2, accuracy, accuracyStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            __typeof__(expression1) expression1Value = (expression1); \
            __typeof__(expression2) expression2Value = (expression2); \
            __typeof__(accuracy) accuracyValue = (accuracy); \
            NSValue *expression1Box = [NSValue value:&expression1Value withObjCType:@encode(__typeof__(expression1))]; \
            NSValue *expression2Box = [NSValue value:&expression2Value withObjCType:@encode(__typeof__(expression2))]; \
            NSValue *accuracyBox = [NSValue value:&accuracyValue withObjCType:@encode(__typeof__(accuracy))]; \
            if (!isnan(expression1Value) && !isnan(expression2Value) && ((MAX(expression1Value, expression2Value) - MIN(expression1Value, expression2Value)) <= accuracyValue)) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqualWithAccuracy, 0, expressionStr1, expressionStr2, accuracyStr, _XCTDescriptionForValue(expression1Box), _XCTDescriptionForValue(expression2Box), _XCTDescriptionForValue(accuracyBox)), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (_XCTestCaseInterruptionException *interruption) { [interruption raise]; } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqualWithAccuracy, 1, expressionStr1, expressionStr2, accuracyStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterUnexpectedFailure(test, _XCTFailureDescription(_XCTAssertion_NotEqualWithAccuracy, 1, expressionStr1, expressionStr2, accuracyStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertThrows(test, expression, expressionStr, ...) \
    _XCT_ASSERT_BEGIN \
        BOOL _didThrow = NO; \
        _XCT_TRY { \
            (void)(expression); \
        } \
        _XCT_CATCH (...) { \
            _didThrow = YES; \
        } \
        if (!_didThrow) { \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_Throws, 0, expressionStr), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertThrowsSpecific(test, expression, expressionStr, exception_class, ...) \
    _XCT_ASSERT_BEGIN \
        BOOL _didThrow = NO; \
        _XCT_TRY { \
            (void)(expression); \
        } \
        _XCT_CATCH (_XCT_CATCHABLE_TYPE(exception_class)) { \
            _didThrow = YES; \
        } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _didThrow = YES; \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecific, 0, expressionStr, @#exception_class, @#exception_class, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _didThrow = YES; \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecific, 0, expressionStr, @#exception_class, @#exception_class, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
        if (!_didThrow) { \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecific, 1, expressionStr, @#exception_class), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertThrowsSpecificNamed(test, expression, expressionStr, exception_class, exception_name, ...) \
    _XCT_ASSERT_BEGIN \
        BOOL _didThrow = NO; \
        _XCT_TRY { \
            _XCT_TRY { \
                (void)(expression); \
            } \
            _XCT_CATCH (exception_class *exception) { \
                _didThrow = YES; \
                if (![exception_name isEqualToString:[exception name]]) { \
                    _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecificNamed, 0, expressionStr, @#exception_class, exception_name, @#exception_class, [exception name], [exception reason]), __VA_ARGS__); \
                } \
            } \
        } \
        _XCT_CATCH (NSException *exception) { \
            _didThrow = YES; \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecificNamed, 1, expressionStr, @#exception_class, exception_name, @#exception_class, [exception name], [exception reason]), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _didThrow = YES; \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecificNamed, 2, expressionStr, @#exception_class, exception_name), __VA_ARGS__); \
        } \
        if (!_didThrow) { \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_ThrowsSpecificNamed, 3, expressionStr, @#exception_class, exception_name), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNoThrow(test, expression, expressionStr, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            (void)(expression); \
        } \
        _XCT_CATCH (NSException *_xct_exception) { \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NoThrow, 0, expressionStr, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NoThrow, 0, expressionStr, @"a non-ObjC exception"), __VA_ARGS__); \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNoThrowSpecific(test, expression, expressionStr, exception_class, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            (void)(expression); \
        } \
        _XCT_CATCH (_XCT_CATCHABLE_TYPE(exception_class) _xct_caught) { \
            _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NoThrowSpecific, 0, expressionStr, @#exception_class, @#exception_class, _XCTReasonForException((NSException *)_xct_caught)), __VA_ARGS__); \
        } \
        _XCT_CATCH (...) { \
            ; \
        } \
    _XCT_ASSERT_END

#define _XCTPrimitiveAssertNoThrowSpecificNamed(test, expression, expressionStr, exception_class, exception_name, ...) \
    _XCT_ASSERT_BEGIN \
        _XCT_TRY { \
            (void)(expression); \
        } \
        _XCT_CATCH (exception_class *exception) { \
            if ([exception_name isEqualToString:[exception name]]) { \
                _XCTRegisterFailure(test, _XCTFailureDescription(_XCTAssertion_NoThrowSpecificNamed, 0, expressionStr, @#exception_class, exception_name, @#exception_class, [exception name], [exception reason]), __VA_ARGS__); \
            } \
        } \
        _XCT_CATCH (...) { \
            ; \
        } \
    _XCT_ASSERT_END

// END GENERATED ASSERTION PRIMITIVES

#endif /* XCTEST_XCTESTASSERTIONSIMPL_H */
