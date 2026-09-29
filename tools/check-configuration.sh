#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Build and run tools/configuration-test.m against the built framework.
#
# A test configuration is a plain value, so nothing about it is observable from
# the framework that owns it: it has no behaviour to call and nothing hands it
# back. The failure this catches is a value that disagrees with itself -- one that
# round-trips because it was written by the same code that reads it, and derives
# the right answer from the field it happens to be given.
#
# It links the installed framework rather than the object files, so it also
# covers installation, umbrella visibility, and the reduced SDK's missing
# Foundation declarations for the types a configuration is built out of.

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
    -o "$tmp/configuration-test" \
    "$here/configuration-test.m"

"$tmp/configuration-test"

# The harness reaches the private header by path. A module import is a separate
# mechanism over the same bundle -- the module map, the umbrella header name, and
# the framework search path all have to agree -- and a module map that is present
# but wrong fails at the client, not in the framework, so it is compiled here
# rather than discovered by whoever imports this next.
#
# Modules are off by default in this toolchain, and -Wno-#warnings is there for the
# SDK's own sake: building the Darwin module pulls in headers the Internal SDK marks
# obsolete, and -Werror would otherwise turn a third-party warning into a failure
# of this check. Everything from this project is still an error.
cat >"$tmp/module-import.m" <<'EOF'
@import XCTestCore;

int main(void)
{
    XCTestConfiguration *config = [[XCTestConfiguration alloc] init];
    return config.sessionIdentifier != nil ? 0 : 1;
}
EOF

"$CC" -fobjc-arc -fblocks -fmodules -fmodules-cache-path="$tmp/modules" \
    -Wall -Wextra -Werror -Wno-#warnings \
    -isysroot "$SDK" \
    -F"$(dirname "$framework")" \
    -framework XCTestCore \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/module-import" \
    "$tmp/module-import.m"

"$tmp/module-import"

echo "module import: PASS"
