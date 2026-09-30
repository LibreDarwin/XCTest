#!/bin/sh
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Builds tools/loader-test.m against the built framework and runs every scenario.
#
# Two things about the run are this script's job and not the harness's, and both
# are about isolation.
#
#   The binary is copied into a per-scenario directory. Source 4 reads
#   NSBundle.mainBundle.builtInPlugInsURL, and for a plain executable mainBundle is
#   the directory holding it -- so where the binary sits decides which PlugIns
#   directory source 4 sees. One copy per scenario means a scenario that fills
#   PlugIns cannot fill another's.
#
#   The temporary directory is swept afterwards. NSTemporaryDirectory() answers
#   confstr(_CS_DARWIN_USER_TEMP_DIR), which ignores $TMPDIR, so a scenario that
#   exercises source 3 has to write into the account's real temporary directory.
#   The harness removes what it wrote on the way out; this is here for the case
#   where it could not, which is a scenario that died on a signal.
set -eu

: "${SDK:?SDK must be set}"
: "${CC:=clang}"
: "${FRAMEWORK:?FRAMEWORK must be set to the built XCTestCore.framework}"

here=$(cd "$(dirname "$0")" && pwd)
framework=$(cd "$(dirname "$FRAMEWORK")" && pwd)/$(basename "$FRAMEWORK")

tmp=$(mktemp -d)
# Where NSTemporaryDirectory() actually points. Not $TMPDIR: Foundation answers
# confstr(_CS_DARWIN_USER_TEMP_DIR) and ignores it, so sweeping $TMPDIR would sweep
# a directory nothing ever wrote to and leave the real one as it was found. getconf
# asks the same libc the harness reaches through, so the two agree by construction.
user_temp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || user_temp=""
if [ -z "$user_temp" ]; then
    echo "check-loader: cannot determine the temporary directory" >&2
    exit 1
fi
# Sweeps the harness's prefix out of it. Uses the shell's own globs rather than the
# harness's bookkeeping so that it also catches a file written by a scenario that
# was killed before its atexit handler ran, and a directory left behind holding one.
cleanup() {
    rm -rf "$tmp"
    for stale in "$user_temp"/"$run_prefix"*; do
        [ -e "$stale" ] && rm -rf "$stale"
    done
}
# One prefix for the whole run, unique to it. Two runs must not be able to read each
# other's fixtures out of a directory they share.
run_prefix="xctcore-loader-$$-$(date +%s)"
trap cleanup EXIT

"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -F"$(dirname "$framework")" \
    -framework XCTestCore \
    -framework Foundation \
    -Xlinker -rpath -Xlinker "$(dirname "$framework")" \
    -o "$tmp/loader-test" \
    "$here/loader-test.m"

# The whole set of scenarios, listed rather than switched: a scenario not named
# here is a scenario nobody runs, and a scenario here that needs an environment
# this script cannot provide should skip rather than fail.
scenarios="encoded path relative precedence discovery-order discovery-none reporting \
init identifiers scope-defaults scope-file command-line settings-discovery"

# Source 4 and the scope checks read the standard defaults domain, which the harness
# cannot replace, and RegisterScope() reaches it with -registerDefaults:. Nothing to
# clean up afterwards: registration is per-process and is not written to disk. The
# cost is the one that cannot be cleaned up either -- a registered value stays in
# the registration domain for the life of the process, so a second scope case sees
# the first case's XCTestInvertScope still set. Each scenario is one process for
# that reason as much as for its temporary files.

failed=""
for scenario in $scenarios; do
    scratch="$tmp/$scenario"
    mkdir -p "$scratch/bin" "$scratch/fixtures"
    cp "$tmp/loader-test" "$scratch/bin/loader-test"
    # TMPDIR is deliberately not set. It does not steer NSTemporaryDirectory() and
    # setting it would suggest that it did, which is the mistake this runner
    # exists to not make twice.
    if ! "$scratch/bin/loader-test" "$scenario" "$scratch/fixtures" "$run_prefix"; then
        failed="$failed $scenario"
    fi
done

if [ -n "$failed" ]; then
    echo "check-loader: FAILED scenarios:$failed" >&2
    exit 1
fi

echo "check-loader: all scenarios passed"
