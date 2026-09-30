#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/selection-test.m against the built framework.
#
# Same reasoning as check-configuration.sh, applied to the selection classes, and
# the emphasis is the same: the interesting checks are the ones against archives
# this process did not write. A selection that only ever round-trips through its
# own writer proves that the writer and the reader agree, which they were built to
# do and which is not the same as agreeing with every other writer of the format.
#
# The sparse-archive checks are the ones worth the file. XCTTagSelection's mode
# decodes to 1 when the key is absent and to 0 when the key is present with a
# zero; those two archives differ by one bit and select opposite sets of tests,
# and only the presence probe tells them apart. That is a property of the decoder
# that no round trip can observe, because this process writes the key every time.
#
# It links the installed framework rather than the object files, so it also covers
# installation, umbrella visibility, and the reduced SDK's missing Foundation
# declarations for the types a selection is built out of.

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
    -o "$tmp/selection-test" \
    "$here/selection-test.m"

"$tmp/selection-test"