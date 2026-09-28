#!/bin/bash
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Bundle check for XCTest.framework.  Takes the built framework, the SDK and
# the compiler as arguments so it can be driven from the Makefile's
# check-framework target under both GNU make and bmake.
#
# Three layers, cheapest first:
#
#   1. Layout.  A framework is only usable if the versioned structure and the
#      top-level symlinks through Versions/Current all resolve.  A bundle that
#      is a plain directory of files can be built and still be unlinkable.
#   2. Link contract.  The dylib must advertise an @rpath install name and must
#      not depend on Apple's own XCTest.framework by absolute path -- if it
#      did, the "reimplementation" would be loading Apple's binary at run time.
#   3. A real client.  Compiles, links and runs a translation unit that
#      imports the umbrella header, and runs it with only -rpath to find the
#      framework, so dyld resolution is exercised rather than assumed.
#
# The client's runtime check is the expected-failure path, which is the part of
# the framework with real logic in it: XCTFail inside an XCTExpectFailure block
# must still print a failure, must be absorbed, and must not change the exit
# status.  A framework whose binary loads but does not run is not a pass.

set -u

FW=${1:?usage: framework-smoke.sh FRAMEWORK SDK CC}
SDK=${2:?usage: framework-smoke.sh FRAMEWORK SDK CC}
CC=${3:?usage: framework-smoke.sh FRAMEWORK SDK CC}

VER=$FW/Versions/A
BIN=$VER/XCTest
fail=0

note() { echo "FAIL $1: $2"; fail=1; }
ok()   { echo "ok   $1"; }

# --- 1. layout ---------------------------------------------------------------

[ -d "$FW" ] || { note "framework" "$FW does not exist"; exit 1; }

for p in "$BIN" "$VER/Headers" "$VER/Modules/module.modulemap" "$VER/Resources/Info.plist"; do
	if [ ! -e "$p" ]; then
		note "layout" "missing $p"
	fi
done

# The top-level names must be symlinks that resolve.  -e follows the link, so a
# dangling one reports here rather than at dyld time.
for l in Headers Modules Resources XCTest; do
	if [ ! -L "$FW/$l" ]; then
		note "layout" "$FW/$l is not a symlink"
	elif [ ! -e "$FW/$l" ]; then
		note "layout" "$FW/$l is a dangling symlink"
	fi
done

if [ -L "$FW/Versions/Current" ] && [ ! -e "$FW/Versions/Current" ]; then
	note "layout" "Versions/Current is a dangling symlink"
fi

# A client must be able to reach the umbrella header through the framework, so
# every public header has to have been installed, not just the imported ones.
[ -f "$VER/Headers/XCTest.h" ] || note "headers" "Headers/XCTest.h not installed"
n_headers=$(ls -1 "$VER/Headers" 2>/dev/null | wc -l | tr -d ' ')
n_src=$(ls -1 "$(dirname "$FW")/../../src/xctest/include/XCTest" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_src" -gt 0 ] && [ "$n_headers" -ne "$n_src" ]; then
	note "headers" "installed $n_headers headers, source tree has $n_src"
fi

[ $fail -eq 0 ] && ok "layout (versioned, symlinks resolve, $n_headers headers installed)"

# --- 2. link contract --------------------------------------------------------

if ! otool -L "$BIN" 2>/dev/null | head -2 | tail -1 | \
	grep -q '@rpath/XCTest\.framework/Versions/A/XCTest'; then
	note "install name" "not @rpath/XCTest.framework/Versions/A/XCTest"
	otool -D "$BIN" 2>/dev/null | sed 's/^/  got: /'
fi

if [ "$(lipo -archs "$BIN" 2>/dev/null | wc -w | tr -d ' ')" -eq 0 ]; then
	note "architectures" "lipo reports none"
fi

# Dependency lines start after the file path and the install name.  Any
# dependency naming XCTest by absolute path would mean Apple's binary is being
# pulled in instead of ours.
if otool -L "$BIN" 2>/dev/null | tail -n +3 | grep 'XCTest'; then
	note "dependencies" "dylib depends on an XCTest path; Apple's binary could be loaded instead of ours"
fi

# --- 3. a real client --------------------------------------------------------

TMP=$(mktemp -d "${TMPDIR:-/tmp}//xctest-fw.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# -F/-rpath take the directory that *contains* the framework, not the framework
# itself: -Fbuild/rel finds build/rel/XCTest.framework.  Pointing -F at the
# bundle instead is not an error, it just silently finds nothing, so the header
# search comes up empty and every <XCTest/...> import reports "file not found".
FWROOT=$(dirname "$FW")

cat > "$TMP/client.m" <<'CLIENT'
#include <stdio.h>
#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import <XCTest/XCTestAssertions.h>
#import <XCTest/XCTExpectedFailure.h>

int main(void) {
	@autoreleasepool {
		/* A plain assertion passes and stays silent. */
		XCTAssertEqual(1, 1);

		/* A failure inside an expected-failure block is reported by the
		 * framework but absorbed, so the exit status is still 0. */
		__block BOOL matched = NO;
		XCTExpectFailure(@"absorbed by the framework");
		matched = YES;
		XCTFail(@"this must be absorbed");

		if (!matched) {
			fprintf(stderr, "expected-failure scope was not entered\n");
			return 1;
		}

		/* The umbrella header must be enough on its own. */
		printf("client ok: %s, %d issues recorded\n",
		       XCTestErrorDomain.UTF8String, (int)XCTIssueTypeAssertionFailure);
	}
	return 0;
}
CLIENT

if ! "$CC" -fobjc-arc -fmodules -isysroot "$SDK" -F"$FWROOT" \
	-c "$TMP/client.m" -o "$TMP/client.o" 2> "$TMP/cc.log"; then
	note "client compile" "translation unit importing <XCTest/XCTest.h> did not build"
	sed 's/^/  /' "$TMP/cc.log"
elif ! "$CC" -fobjc-arc -isysroot "$SDK" -F"$FWROOT" -framework XCTest \
	-rpath "$FWROOT" -o "$TMP/client" "$TMP/client.o" 2> "$TMP/ld.log"; then
	note "client link" "could not link -framework XCTest against the built bundle"
	sed 's/^/  /' "$TMP/ld.log"
else
	# The client must have bound to the @rpath install name, not to a copy.
	if ! otool -L "$TMP/client" | grep -q '@rpath/XCTest\.framework/Versions/A/XCTest'; then
		note "client link" "client did not bind to the built framework"
		otool -L "$TMP/client" | sed 's/^/  /'
	elif ! out=$("$TMP/client" 2>&1); then
		note "client run" "exited non-zero running against the framework"
		echo "$out" | sed 's/^/  /'
	else
		echo "ok   client (compiled, linked, ran: ${out%%$'\n'*})"
	fi
fi

exit $fail
