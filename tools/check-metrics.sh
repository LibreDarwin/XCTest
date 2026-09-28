#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/metrics-test.m against the built framework.
#
# The measure loop is the failure mode this catches. The value types link, the
# category compiles, -measureBlock: returns, and a loop that ran the block once
# or that reported its cold first run would still attach a plausible number to a
# passing test. Nothing else in the tree can tell those apart.
#
# It links the installed framework rather than the object files, so it also
# covers installation, umbrella visibility, and the reduced SDK's missing
# NSUnit/NSMeasurement declarations.

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
    -I"$root/src/xctest" \
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/metrics-test" \
    "$here/metrics-test.m"

"$tmp/metrics-test"
