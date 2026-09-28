// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The XCTAssert* family.
//
// Each macro forwards to a primitive in XCTestAssertionsImpl.h, passing the
// stringified source text of its operands alongside their values. That text
// cannot be recovered at runtime, so it has to be captured here, at the call
// site, or the failure message can only say "assertion failed".
//
// The first argument to every primitive is nil, not self. The framework tracks
// the test case currently executing on this thread and resolves it inside the
// failure handler. That is what lets an assertion inside a helper method -- or
// inside a category on XCTestCase -- still attach its issue to the right test,
// which a self-based scheme could not do without the caller threading the case
// through by hand.

#import <XCTest/XCTestAssertionsImpl.h>

XCT_HEADER_AUDIT_BEGIN

/*!
 * @function XCTFail(...)
 * Records a failure unconditionally.
 * @param ... An optional supplementary message. A literal NSString, optionally
 * with string format specifiers. May be omitted entirely.
 */
#define XCTFail(...) \
    _XCTPrimitiveFail(nil, __VA_ARGS__)

/*!
 * @function XCTAssertNil(expression, ...)
 * Fails if `expression` is not nil.
 * @param expression An expression of object type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNil(expression, ...) \
    _XCTPrimitiveAssertNil(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssertNotNil(expression, ...)
 * Fails if `expression` is nil.
 * @param expression An expression of object type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNotNil(expression, ...) \
    _XCTPrimitiveAssertNotNil(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssert(expression, ...)
 * Fails if `expression` is false. Equivalent to XCTAssertTrue.
 * @param expression An expression of boolean type.
 * @param ... An optional supplementary message.
 */
#define XCTAssert(expression, ...) \
    _XCTPrimitiveAssertTrue(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssertTrue(expression, ...)
 * Fails if `expression` is false.
 * @param expression An expression of boolean type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertTrue(expression, ...) \
    _XCTPrimitiveAssertTrue(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssertFalse(expression, ...)
 * Fails if `expression` is true.
 * @param expression An expression of boolean type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertFalse(expression, ...) \
    _XCTPrimitiveAssertFalse(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssertEqualObjects(expression1, expression2, ...)
 * Fails if the two objects are not equal by -isEqual:.
 * @param expression1 An expression of object type.
 * @param expression2 An expression of object type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertEqualObjects(expression1, expression2, ...) \
    _XCTPrimitiveAssertEqualObjects(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertNotEqualObjects(expression1, expression2, ...)
 * Fails if the two objects are equal by -isEqual:.
 * @param expression1 An expression of object type.
 * @param expression2 An expression of object type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNotEqualObjects(expression1, expression2, ...) \
    _XCTPrimitiveAssertNotEqualObjects(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertEqual(expression1, expression2, ...)
 * Fails if the two scalars are not equal. Neither operand may be an object; use
 * XCTAssertEqualObjects for those.
 * @param expression1 A scalar expression.
 * @param expression2 A scalar expression, of a type comparable to the first.
 * @param ... An optional supplementary message.
 */
#define XCTAssertEqual(expression1, expression2, ...) \
    _XCTPrimitiveAssertEqual(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertNotEqual(expression1, expression2, ...)
 * Fails if the two scalars are equal.
 * @param expression1 A scalar expression.
 * @param expression2 A scalar expression, of a type comparable to the first.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNotEqual(expression1, expression2, ...) \
    _XCTPrimitiveAssertNotEqual(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertIdentical(expression1, expression2, ...)
 * Fails unless the two objects are the same instance.
 * @param expression1 An expression of object type.
 * @param expression2 An expression of object type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertIdentical(expression1, expression2, ...) \
    _XCTPrimitiveAssertIdentical(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertNotIdentical(expression1, expression2, ...)
 * Fails if the two objects are the same instance.
 * @param expression1 An expression of object type.
 * @param expression2 An expression of object type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNotIdentical(expression1, expression2, ...) \
    _XCTPrimitiveAssertNotIdentical(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertEqualWithAccuracy(expression1, expression2, accuracy, ...)
 * Fails if the two floating-point values differ by more than `accuracy`. A NaN
 * operand always fails: NaN is unordered, so no tolerance can make it compare
 * equal to anything.
 * @param expression1 A floating-point expression.
 * @param expression2 A floating-point expression.
 * @param accuracy A non-negative floating-point tolerance.
 * @param ... An optional supplementary message.
 */
#define XCTAssertEqualWithAccuracy(expression1, expression2, accuracy, ...) \
    _XCTPrimitiveAssertEqualWithAccuracy(nil, expression1, @#expression1, expression2, @#expression2, accuracy, @#accuracy, __VA_ARGS__)

/*!
 * @function XCTAssertNotEqualWithAccuracy(expression1, expression2, accuracy, ...)
 * Fails if the two floating-point values differ by no more than `accuracy`.
 * @param expression1 A floating-point expression.
 * @param expression2 A floating-point expression.
 * @param accuracy A non-negative floating-point tolerance.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNotEqualWithAccuracy(expression1, expression2, accuracy, ...) \
    _XCTPrimitiveAssertNotEqualWithAccuracy(nil, expression1, @#expression1, expression2, @#expression2, accuracy, @#accuracy, __VA_ARGS__)

/*!
 * @function XCTAssertGreaterThan(expression1, expression2, ...)
 * Fails unless expression1 > expression2.
 * @param expression1 A scalar expression.
 * @param expression2 A scalar expression, of a type comparable to the first.
 * @param ... An optional supplementary message.
 */
#define XCTAssertGreaterThan(expression1, expression2, ...) \
    _XCTPrimitiveAssertGreaterThan(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertGreaterThanOrEqual(expression1, expression2, ...)
 * Fails unless expression1 >= expression2.
 * @param expression1 A scalar expression.
 * @param expression2 A scalar expression, of a type comparable to the first.
 * @param ... An optional supplementary message.
 */
#define XCTAssertGreaterThanOrEqual(expression1, expression2, ...) \
    _XCTPrimitiveAssertGreaterThanOrEqual(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertLessThan(expression1, expression2, ...)
 * Fails unless expression1 < expression2.
 * @param expression1 A scalar expression.
 * @param expression2 A scalar expression, of a type comparable to the first.
 * @param ... An optional supplementary message.
 */
#define XCTAssertLessThan(expression1, expression2, ...) \
    _XCTPrimitiveAssertLessThan(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertLessThanOrEqual(expression1, expression2, ...)
 * Fails unless expression1 <= expression2.
 * @param expression1 A scalar expression.
 * @param expression2 A scalar expression, of a type comparable to the first.
 * @param ... An optional supplementary message.
 */
#define XCTAssertLessThanOrEqual(expression1, expression2, ...) \
    _XCTPrimitiveAssertLessThanOrEqual(nil, expression1, @#expression1, expression2, @#expression2, __VA_ARGS__)

/*!
 * @function XCTAssertThrows(expression, ...)
 * Fails unless `expression` raises some exception.
 * @param expression An expression of any type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertThrows(expression, ...) \
    _XCTPrimitiveAssertThrows(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssertThrowsSpecific(expression, exception_class, ...)
 * Fails unless `expression` raises an exception of exactly `exception_class`, or
 * a subclass of it. A different exception class is itself a failure.
 * @param expression An expression of any type.
 * @param exception_class The expected exception class.
 * @param ... An optional supplementary message.
 */
#define XCTAssertThrowsSpecific(expression, exception_class, ...) \
    _XCTPrimitiveAssertThrowsSpecific(nil, expression, @#expression, exception_class, __VA_ARGS__)

/*!
 * @function XCTAssertThrowsSpecificNamed(expression, exception_class, exception_name, ...)
 * Fails unless `expression` raises `exception_class` whose -name equals
 * `exception_name`.
 * @param expression An expression of any type.
 * @param exception_class The expected exception class.
 * @param exception_name The expected exception name, as an NSString expression.
 * @param ... An optional supplementary message.
 */
#define XCTAssertThrowsSpecificNamed(expression, exception_class, exception_name, ...) \
    _XCTPrimitiveAssertThrowsSpecificNamed(nil, expression, @#expression, exception_class, exception_name, __VA_ARGS__)

/*!
 * @function XCTAssertNoThrow(expression, ...)
 * Fails if `expression` raises any exception.
 * @param expression An expression of any type.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNoThrow(expression, ...) \
    _XCTPrimitiveAssertNoThrow(nil, expression, @#expression, __VA_ARGS__)

/*!
 * @function XCTAssertNoThrowSpecific(expression, exception_class, ...)
 * Fails if `expression` raises an exception of `exception_class` or a subclass.
 * Any other exception is ignored: it is not the one under test.
 * @param expression An expression of any type.
 * @param exception_class The exception class that must not be raised.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNoThrowSpecific(expression, exception_class, ...) \
    _XCTPrimitiveAssertNoThrowSpecific(nil, expression, @#expression, exception_class, __VA_ARGS__)

/*!
 * @function XCTAssertNoThrowSpecificNamed(expression, exception_class, exception_name, ...)
 * Fails if `expression` raises `exception_class` whose -name equals
 * `exception_name`.
 * @param expression An expression of any type.
 * @param exception_class The exception class that must not be raised.
 * @param exception_name The forbidden exception name, as an NSString expression.
 * @param ... An optional supplementary message.
 */
#define XCTAssertNoThrowSpecificNamed(expression, exception_class, exception_name, ...) \
    _XCTPrimitiveAssertNoThrowSpecificNamed(nil, expression, @#expression, exception_class, exception_name, __VA_ARGS__)

XCT_HEADER_AUDIT_END
