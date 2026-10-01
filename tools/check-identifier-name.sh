#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/identifier-name-test.m against the built framework.
#
# Same reasoning as check-class-discovery.sh: the unit compiles on its own, but
# what is worth checking -- that a suffix-stripped name, a renamed name and an
# identifier all agree with each other -- is a property of a real test case at
# runtime, not of any single function. The harness supplies cases whose selectors
# spell the same test three ways and asserts on all three spellings at once.
#
# It links the installed framework rather than the object files, so it also
# covers installation and the private declarations in XCTestInternal.h, which is
# where these methods would drift if they drifted anywhere. It reaches the
# class-and-method identifier type through XCTestCore's own header, because the
# identifier is the join of the two names this file checks.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"
: "${FRAMEWORK:?FRAMEWORK must be set to the built XCTest.framework}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
framework=$(cd "$(dirname "$FRAMEWORK")" && pwd)/$(basename "$FRAMEWORK")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -I"$root/src/xctestcore" \
    -I"$root/src/xctestcore/include" \
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/identifier-name-test" \
    "$here/identifier-name-test.m"

"$tmp/identifier-name-test"
