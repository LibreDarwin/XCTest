#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Expand every public XCT macro.
#
# tools/check-headers.sh compiles each header standalone, which proves the
# declarations are well-formed but says nothing about the macros: a macro that
# references a function nobody declared still "compiles" when nobody invokes it.
# That is how an entire assertion layer can be missing and still pass.
#
# This script invokes every macro, with and without a trailing message, and with
# message arguments so the variadic and format paths are both exercised. Each
# case is instantiated in a function that is never called, so nothing runs.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/macros.m" <<'EOF'
#import <XCTest/XCTest.h>

// Every macro is invoked from a never-called method on an XCTestCase subclass,
// so the whole set is checked in the context callers actually use. The assertion
// macros deliberately do NOT reference `self` -- they pass nil and let the
// framework resolve the running test case -- so these would also expand inside a
// free function. Keeping them in a method is still the honest test: that is
// where they are used, and it keeps XCTestCase itself required by the header.
@interface XCTExpandProbe : XCTestCase
@end

@implementation XCTExpandProbe
- (void)testEveryMacroExpands:(id)object
                     number:(int)number
                     second:(double)second
                  accuracy:(double)accuracy
{
    XCTFail();
    XCTFail(@"plain");
    XCTFail(@"value %d", number);

    XCTAssert(YES);
    XCTAssert(NO, @"was %d", number);
    XCTAssertTrue(YES);
    XCTAssertTrue(NO, @"was %d", number);
    XCTAssertFalse(NO);
    XCTAssertFalse(YES, @"was %d", number);
    XCTAssertNil(nil);
    XCTAssertNil(object, @"was %@", object);
    XCTAssertNotNil(object);
    XCTAssertNotNil(nil, @"was nil");

    XCTAssertEqualObjects(object, object);
    XCTAssertEqualObjects(object, nil, @"differs");
    XCTAssertNotEqualObjects(object, nil);
    XCTAssertNotEqualObjects(object, object, @"same");

    XCTAssertEqual(number, 1);
    XCTAssertEqual(number, 2, @"differs");
    XCTAssertNotEqual(number, 1);
    XCTAssertNotEqual(number, 2, @"same");
    XCTAssertIdentical(object, object);
    XCTAssertIdentical(object, nil, @"differs");
    XCTAssertNotIdentical(object, nil);
    XCTAssertNotIdentical(object, object, @"same");

    XCTAssertGreaterThan(number, 0);
    XCTAssertGreaterThan(0, 1, @"not greater");
    XCTAssertGreaterThanOrEqual(number, 0);
    XCTAssertGreaterThanOrEqual(0, 1, @"less");
    XCTAssertLessThan(0, 1);
    XCTAssertLessThan(1, 0, @"not less");
    XCTAssertLessThanOrEqual(0, 1);
    XCTAssertLessThanOrEqual(1, 0, @"greater");

    XCTAssertEqualWithAccuracy(second, 1.0, 0.01);
    XCTAssertEqualWithAccuracy(second, 2.0, 0.01, @"differs");
    XCTAssertNotEqualWithAccuracy(second, 1.0, 0.01);
    XCTAssertNotEqualWithAccuracy(second, 2.0, 0.01, @"same");

    XCTAssertThrowsSpecificNamed([object description], NSException, NSRangeException,
                                 @"name %@", object);
    XCTAssertThrowsSpecificNamed([object description], NSException, NSRangeException);
    XCTAssertThrowsSpecific([object description], NSException);
    XCTAssertThrowsSpecific([object description], NSException, @"msg");
    XCTAssertThrows([object description]);
    XCTAssertThrows([object description], @"msg");
    XCTAssertNoThrowSpecificNamed([object description], NSException, NSRangeException);
    XCTAssertNoThrowSpecificNamed([object description], NSException, NSRangeException, @"msg");
    XCTAssertNoThrowSpecific([object description], NSException);
    XCTAssertNoThrowSpecific([object description], NSException, @"msg");
    XCTAssertNoThrow([object description]);
    XCTAssertNoThrow([object description], @"msg");

    XCTSkip();
    XCTSkip(@"plain");
    XCTSkip(@"value %d", number);
    XCTSkipIf(YES);
    XCTSkipIf(NO, @"was %d", number);
    XCTSkipUnless(NO);
    XCTSkipUnless(YES, @"was %d", number);
}
@end
EOF

"$CC" -fsyntax-only -fobjc-arc -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -I"$root/src/xctest/include" \
    "$tmp/macros.m"

echo "check-macros: all XCT macros expand cleanly"
