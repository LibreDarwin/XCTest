#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/class-discovery-test.m against the built framework.
#
# Same reasoning as check-metrics.sh, applied to class discovery: the unit links
# and compiles on its own, but the parts worth checking -- which subclasses are
# accepted and which are rejected -- are only observable once a process has a
# population of real classes to filter. The harness supplies that population
# and asserts on the result.
#
# It links the installed framework rather than the object files, so it also
# covers installation and umbrella visibility, and it is the only check that
# reaches libobjc's private _class_isSwift through XCTestInternal.h.

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
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/class-discovery-test" \
    "$here/class-discovery-test.m"

"$tmp/class-discovery-test"
