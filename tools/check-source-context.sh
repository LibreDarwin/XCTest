#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/source-context-test.m against the built framework.
#
# XCTSourceCodeContext is the one value type every failure passes through: the
# assertion macros build one, XCTIssue carries one, and anything reading a result
# reads one. The redesign split it into a location, a symbol and a frame, and
# nothing else in the tree notices when that mapping is wrong -- the types
# compile, the framework links, an issue still arrives with a context attached,
# and the file and line of every failure are quietly gone. This is the check
# that would notice.
#
# It links the installed framework rather than the object files, so it also
# covers installation and umbrella visibility.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"
: "${FRAMEWORK:?FRAMEWORK must be set to the built XCTest.framework}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
framework=$(cd "$(dirname "$FRAMEWORK")" && pwd)/$(basename "$FRAMEWORK")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# -Wno-unused-parameter: the stub coder overrides NSCoder's primitives, and most
# of them name parameters they have no use for.
"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -isysroot "$SDK" \
    -I"$root/src/xctestcore" \
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/source-context-test" \
    "$here/source-context-test.m"

"$tmp/source-context-test"
