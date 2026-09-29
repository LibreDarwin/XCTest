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

# XCTestCore is a second framework with its own include roots, and it needs
# exceptions: the reference reaches an assertion handler rather than returning a
# placeholder for an unrecognised ordering, and raising is how that is reproduced
# here.
CORE_CFLAGS="-c -fobjc-arc -fobjc-exceptions -fblocks
        -Wall -Wextra -Werror -Wno-unused-function
        -isysroot $SDK -I$root/src/xctestcore/include -I$root/src/xctestcore"

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

core_objects=""
for source in "$root"/src/xctestcore/*.m; do
    name=$(basename "$source" .m)
    # shellcheck disable=SC2086
    if "$CC" $CORE_CFLAGS -o "$tmp/core-$name.o" "$source" 2> "$tmp/core-$name.log"; then
        printf '  %-28s compiles\n' "core/$name"
        core_objects="$core_objects $tmp/core-$name.o"
    else
        printf '  %-28s FAILED\n' "core/$name"
        cat "$tmp/core-$name.log"
        status=1
    fi
done

[ "$status" -eq 0 ] || exit "$status"

# The link contract: every exported function in the project's own headers must have
# a definition. Macros, include guards and enum names are filtered out by only
# looking at export declarations.
#
# All of src/xctest's headers are scanned, and both export macros are matched, rather
# than a hand-listed set of files and one macro name. Both of those narrowings were
# wrong: XCTestExpectationInternal.h declares _XCTNextFulfillmentSequence, and
# XCTestAssertionsImpl.h declares _XCTReasonForException with XCT_WEAK_EXPORT, so a
# fixed file list and a literal "XCT_EXPORT" reported both as "defined but not
# declared" -- and would have stopped noticing anything added to a new header.
# Newlines are flattened because `[^;]*` cannot cross a line, and a declaration
# written with its name on the next line would otherwise be dropped.
#
# The set difference uses plain grep, not `rtk grep`, and that is deliberate rather
# than an oversight. rtk's grep wrapper does not implement -f: `rtk grep -vxF -f
# patterns file` prints nothing and exits 1 even when the difference is non-empty,
# which under `|| true` reads as "no differences found". This check was written
# that way and therefore never reported anything; the negative controls are what
# caught it. Single-pattern extraction with `rtk grep -o` does work, so it is still
# used below.
find "$root/src/xctest" -name '*.h' | xargs cat | tr '\n' ' ' \
    | rtk grep -o "XCT_\(WEAK_\)\?EXPORT[^;]*" \
    | rtk grep -o "_XCT[A-Za-z0-9_]*(" | tr -d '(' | sort -u > "$tmp/want"

# nm spells a C function `_XCTFoo` as `__XCTFoo`: the leading underscore in the
# source name is there on top of the one the toolchain adds. Exactly one underscore
# is stripped so the symbol set can be compared against the header names verbatim.
#
# This is done with sed rather than `tr -d ' T'`, which was here first and was wrong
# twice over: it removes every `T` in the line, not just the type letter, so
# `_XCTTestCase` came out as `XCCurrenesCase` and could never match the header; and
# it left the doubled underscore in place. Both bugs were invisible while the
# comparison above was a no-op.
# shellcheck disable=SC2086
nm -gU $objects \
    | rtk grep -o " T _[A-Za-z_]*" \
    | sed -e 's/^ T //' -e 's/^_//' \
    | sort -u > "$tmp/have"

missing=$(grep -vxF -f "$tmp/have" "$tmp/want" || true)
if [ -n "$missing" ]; then
    echo "check-sources: declared but never defined:"
    echo "$missing" | sed 's/^/  /'
    exit 1
fi

extra=$(grep -vxF -f "$tmp/want" "$tmp/have" | rtk grep "^_XCT" || true)
if [ -n "$extra" ]; then
    echo "check-sources: defined but not declared:"
    echo "$extra" | sed 's/^/  /'
    exit 1
fi

# The same contract for XCTestCore, with three deliberate differences.
#
# Newlines are flattened first. This header writes the return type and the function
# name on separate lines ("FOUNDATION_EXPORT NSString *_Nonnull" then the name), and
# grep's `[^;]*` does not cross a line boundary, so a line-scoped match drops every
# one of them -- silently, and on exactly the set of names this check exists to
# police.
#
# Names are taken as the token before "(" for functions and the trailing token for
# the constant, rather than by stripping a leading underscore off a broad match. A
# prefix match also catches the return type, which is a typedef with no symbol, and
# would report it missing forever.
#
# Text and data symbols are both accepted, because the header also exports a
# constant and a declared-but-undefined constant is the same defect as a missing
# function. The first `nm` on an empty object list still succeeds on this platform,
# so the empty case is handled explicitly rather than producing a false pass.
core_declarations() {
    tr '\n' ' ' <"$root/src/xctestcore/include/XCTestCore/XCTestConfiguration.h" \
        | rtk grep -o "FOUNDATION_EXPORT[^;]*"
}

{ core_declarations | rtk grep -o "XCT[A-Za-z0-9_]*(" | tr -d '('
  core_declarations | rtk grep -o "XCT[A-Za-z0-9_]*$"; } | sort -u > "$tmp/core-want"

if [ -n "$core_objects" ]; then
    # shellcheck disable=SC2086
    nm -gU $core_objects \
        | rtk grep -o " [TDS] _XCT[A-Za-z0-9_]*" \
        | sed 's/^ [TDS] _//' \
        | rtk grep -v "^__" \
        | sort -u > "$tmp/core-have"
else
    : > "$tmp/core-have"
fi

core_missing=$(grep -vxF -f "$tmp/core-have" "$tmp/core-want" || true)
if [ -n "$core_missing" ]; then
    echo "check-sources: XCTestCore declared but never defined:"
    echo "$core_missing" | sed 's/^/  /'
    exit 1
fi

echo "check-sources: all implementation files compile; internal link contract holds"
