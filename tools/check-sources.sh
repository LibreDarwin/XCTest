#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Compile-check every XCTest implementation file and confirm the framework's
# internal link contract holds.
#
# tools/check-headers.sh proves the declarations are well-formed and
# tools/check-macros.sh proves every macro expands. Neither of them compiles the
# implementation, and an implementation that does not compile is invisible to
# both. The symbol diff at the end closes the remaining gap: a function declared
# in a header but never defined would link only once a caller happened to use
# it, which for a rarely-taken path can be never.

set -e

: "${SDK:?SDK must be set}"
: "${CC:=clang}"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

CFLAGS="-c -fobjc-arc -Wall -Wextra -Werror -Wno-unused-function
        -isysroot $SDK -I$root/src/xctest/include -I$root/src/xctest"

status=0
objects=""
for source in "$root"/src/xctest/*.m; do
    name=$(basename "$source" .m)
    # shellcheck disable=SC2086
    if "$CC" $CFLAGS -o "$tmp/$name.o" "$source" 2> "$tmp/$name.log"; then
        printf '  %-28s compiles\n' "$name"
        objects="$objects $tmp/$name.o"
    else
        printf '  %-28s FAILED\n' "$name"
        cat "$tmp/$name.log"
        status=1
    fi
done

[ "$status" -eq 0 ] || exit "$status"

# The link contract: every XCT_EXPORT'd function in the private and internal
# headers must have a definition. Macros, include guards and enum names are
# filtered out by only looking at XCT_EXPORT declarations.
rtk grep -oh "XCT_EXPORT[^;]*" \
    "$root/src/xctest/XCTestInternal.h" \
    "$root/src/xctest/include/XCTest/XCTestAssertionsImpl.h" \
    "$root/src/xctest/include/XCTest/XCTestSkippingImpl.h" \
    | rtk grep -o "_XCT[A-Za-z]*(" | tr -d '(' | sort -u > "$tmp/want"

# shellcheck disable=SC2086
nm -gU $objects | rtk grep -o " T _[A-Za-z_]*" | tr -d ' T' | sort -u > "$tmp/have"

missing=$(rtk grep -vxF -f "$tmp/have" "$tmp/want" || true)
if [ -n "$missing" ]; then
    echo "check-sources: declared but never defined:"
    echo "$missing" | sed 's/^/  /'
    exit 1
fi

extra=$(rtk grep -vxF -f "$tmp/want" "$tmp/have" | rtk grep "^_XCT" || true)
if [ -n "$extra" ]; then
    echo "check-sources: defined but not declared:"
    echo "$extra" | sed 's/^/  /'
    exit 1
fi

echo "check-sources: all implementation files compile; internal link contract holds"
