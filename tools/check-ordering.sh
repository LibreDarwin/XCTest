#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/ordering-test.m against the built framework.
#
# Same reasoning as check-identifier-name.sh: the units compile on their own, but
# what is worth checking -- that a shuffle matches the reference's permutation at
# every draw, that cases order by name and suites by name and the two agree on a
# mixed container, that an argument-bearing selection prunes a case by its
# parent -- is a property of a real suite at runtime, not of any single method.
#
# It links the installed framework rather than the object files, so it also
# covers installation and the private declarations in XCTestInternal.h. It
# reaches the identifier types through XCTestCore's own header, because the
# removal checks build selections out of those types.

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
    -o "$tmp/ordering-test" \
    "$here/ordering-test.m"

"$tmp/ordering-test"
