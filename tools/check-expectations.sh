#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/expectations-test.m against the built framework.
#
# tools/check-headers.sh proves the four specialized expectation headers are
# well-formed and tools/framework-smoke.sh proves the bundle installs and
# links. Neither says anything about what the expectations do: a subclass that
# registers the wrong observer, fulfils without its condition holding, or
# leaves its registration behind after deallocation all link cleanly and pass
# both. This is the check that would notice.
#
# It links the installed framework rather than the object files, so it is the
# one check that would also catch a header left out of the bundle or a source
# left out of the link.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"
: "${FRAMEWORK:?FRAMEWORK must be the built XCTest.framework}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
framework=$(cd "$(dirname "$FRAMEWORK")" && pwd)/$(basename "$FRAMEWORK")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# -Wno-deprecated-declarations: the harness deliberately exercises the
# deprecated XCTKVOExpectation, which is the API it is testing. -Wno-unused-parameter:
# the KVO and notification callback signatures are fixed by the framework.
"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -Wno-unused-parameter \
    -isysroot "$SDK" \
    -I"$root/src/xctest" \
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/expectations-test" \
    "$here/expectations-test.m"

"$tmp/expectations-test"
