#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/run-session-test.m against the built framework.
#
# Same reasoning as check-selection.sh, applied to the enumeration value types
# and the execution protocol, with one addition: this harness reads the archives
# as property lists rather than only through a coder, because the one thing it
# most needs to check -- that a flag is stored as a plist boolean rather than a
# plist integer -- is invisible to -decodeBoolForKey:, which accepts either.
#
# The partial-archive checks are the ones worth the file. The options type
# refuses an archive in which neither flag is set, so the value its own -init
# produces cannot be archived; the result type keeps the same empty value and
# does archive it. That one-bit asymmetry decides whether "no such request" can
# be represented, and no round-trip test observes it, because this process
# writes every key it then reads back.
#
# It links the installed framework rather than the object files, so it also covers
# installation, umbrella visibility, and the reduced SDK's missing Foundation
# declarations for the keyed-coding and property-list classes it needs.

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
    -framework CoreFoundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/run-session-test" \
    "$here/run-session-test.m"

"$tmp/run-session-test"
