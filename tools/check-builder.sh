#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/builder-test.m against the built framework.
#
# The same reasoning as check-configuration.sh, applied to the part of selection
# that reads a string rather than an archive, so with the emphasis inverted: a
# parser cannot be checked by round-tripping, because the string that comes back
# out looking right can have been assembled from the wrong components. So the
# checks here are on the components and the option bits, which is where a wrong
# parse hides, and on the two-identifier case, which is the whole reason a
# selection needs a builder rather than a set.
#
# It links the installed framework rather than the object files, so it also covers
# installation and umbrella visibility of the builder and the creation category.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"
: "${FRAMEWORK:?FRAMEWORK must be set to the built XCTestCore.framework}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
framework=$(cd "$(dirname "$FRAMEWORK")" && pwd)/$(basename "$FRAMEWORK")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -F"$(dirname "$framework")" \
    -framework XCTestCore \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/builder-test" \
    "$here/builder-test.m"

"$tmp/builder-test"
