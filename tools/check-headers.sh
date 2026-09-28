#!/bin/bash
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Compiles every public XCTest header on its own, twice.
#
# The point of "on its own" is to catch missing imports: our headers are
# consumed as <XCTest/Foo.h> directly, and a header that only compiles because
# something else happened to be imported first is broken for the client that
# imports just that one.
#
# The second pass compiles the umbrella, which is what catches the inverse: a
# header the umbrella forgets, or one that cannot be included after the others
# in the same translation unit.
#
# The compiler is the source of truth for this project, not editor
# diagnostics: see src/xctest/.clangd for why editor-side checking needs the
# Internal SDK pointed out to it explicitly.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${SDK:-/Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.Internal.sdk}"
CC="${CC:-/Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang}"
INC="$ROOT/src/xctest/include"

if [ ! -d "$SDK" ]; then
	echo "check-headers: SDK not found: $SDK" >&2
	echo "  pass SDK=/path/to/MacOSX.Internal.sdk" >&2
	exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FLAGS="-fsyntax-only -fobjc-arc -Wall -Wextra -Werror -isysroot $SDK -I$INC"

failures=0
checked=0

for header in "$INC"/XCTest/*.h; do
	name="$(basename "$header")"
	printf '#import <XCTest/%s>\n' "$name" > "$TMP/probe.m"
	if ! $CC $FLAGS "$TMP/probe.m" 2> "$TMP/err.txt"; then
		echo "FAIL (standalone) $name"
		sed -n '1,12p' "$TMP/err.txt"
		failures=$((failures + 1))
	fi
	checked=$((checked + 1))
done

# Umbrella pass: every public header in one translation unit, umbrella last,
# so ordering problems and duplicate-definition problems both surface.
{
	echo '#import <XCTest/XCTest.h>'
	printf 'int main(void) { return 0; }\n'
} > "$TMP/umbrella.m"
if ! $CC $FLAGS "$TMP/umbrella.m" 2> "$TMP/err.txt"; then
	echo "FAIL (umbrella) XCTest.h"
	sed -n '1,20p' "$TMP/err.txt"
	failures=$((failures + 1))
fi
checked=$((checked + 1))

if [ "$failures" -ne 0 ]; then
	echo "check-headers: $failures of $checked failed"
	exit 1
fi

echo "check-headers: $checked headers OK (standalone + umbrella)"
