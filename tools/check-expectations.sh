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
    -I"$root/src/xctestcore" \
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/expectations-test" \
    "$here/expectations-test.m"

"$tmp/expectations-test"

# The harness above compiles against the source tree, with -Isrc/xctestcore, so
# it can reach the private XCTestExpectationInternal.h and would still build if a
# public header failed to declare something its own API names. This second
# client sees nothing but the installed bundle, which is what a real caller
# gets, and names the Foundation symbols the KVO API forces its users to name.
# It is compiled, not run: the point is that the declarations are reachable.
#
# -Wno-deprecated-declarations: same reason as above, it is testing that API.
# -Wno-c23-extensions: the block signature omits a parameter name, as Apple's
# own header does.
"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -Wno-c23-extensions \
    -isysroot "$SDK" \
    -I"$(dirname "$framework")/Headers" \
    -F"$(dirname "$framework")" \
    -framework XCTest \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/public-client" \
    "$here/expectations-public-client.m"
