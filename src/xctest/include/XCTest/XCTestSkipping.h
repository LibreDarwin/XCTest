// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Skip a test conditionally. A skipped test is reported separately from a
// failing one and does not fail the run.
//
// Like the assertion macros, these pass their condition's source text down to
// the runtime so the recorded skip issue can name the expression. Unlike the
// assertion macros, they take no XCTestCase: a skip has to be attributed to
// whichever test is running, which the framework already knows, and there is
// nothing useful for a caller to supply.

#ifndef XCTEST_XCTESTSKIPPING_H
#define XCTEST_XCTESTSKIPPING_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestSkippingImpl.h>

XCT_HEADER_AUDIT_BEGIN

/*!
 * @function XCTSkip(...)
 * Stops executing the current test and records it as skipped. Execution does
 * not continue past this point.
 * @param ... An optional description of why the test is being skipped. A
 * literal NSString, optionally with string format specifiers. May be omitted
 * entirely.
 */
#define XCTSkip(...) \
    _XCTPrimitiveSkip(__VA_ARGS__)

/*!
 * @function XCTSkipIf(expression, ...)
 * Stops executing the current test and records it as skipped when `expression`
 * is true.
 * @param expression An expression of boolean type.
 * @param ... An optional description of why the test is being skipped.
 */
#define XCTSkipIf(expression, ...) \
    _XCTPrimitiveSkipIfEqual(expression, YES, @#expression, __VA_ARGS__)

/*!
 * @function XCTSkipUnless(expression, ...)
 * Stops executing the current test and records it as skipped when `expression`
 * is false.
 * @param expression An expression of boolean type.
 * @param ... An optional description of why the test is being skipped.
 */
#define XCTSkipUnless(expression, ...) \
    _XCTPrimitiveSkipIfEqual(expression, NO, @#expression, __VA_ARGS__)

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTSKIPPING_H */
