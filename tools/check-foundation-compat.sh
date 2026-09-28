#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/foundation-compat-test.m against the Internal SDK.
#
# src/xctest/XCTestFoundationCompat.h declares Foundation API that the SDK's
# headers omit but its runtime provides. Nothing in the compiler validates such a
# declaration: a wrong signature still builds, then misbehaves inside the runner
# with the cause far away. This check turns that promise into something the build
# actually tests.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Both include roots, because the header under test imports <XCTest/XCTestDefines.h>
# like every other public header does. Dropping the public root used to work
# because nothing in this header needed it, and the check then failed on a
# missing include rather than on a wrong declaration -- which is the one failure
# mode this file exists to rule out.
"$CC" -fobjc-arc -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -I"$root/src/xctest" \
    -I"$root/src/xctest/include" \
    -framework Foundation \
    -o "$tmp/foundation-compat-test" \
    "$here/foundation-compat-test.m"

"$tmp/foundation-compat-test"
