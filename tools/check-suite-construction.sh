#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/suite-construction-test.m against the built framework.
#
# The units compile on their own, but what is worth checking -- that a class is
# recognised as customising its suite only when the implementation is its own,
# and that a selection in one spelling gains the identifiers of the other -- is
# a property of real classes at runtime, not of any single method.
#
# It links the installed framework rather than the object files, so it also
# covers installation and the private declarations in XCTestInternal.h. It
# reaches the identifier types through XCTestCore's own header, because the
# counterpart checks build selections out of those types.

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
    -o "$tmp/suite-construction-test" \
    "$here/suite-construction-test.m"

"$tmp/suite-construction-test"
