# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Flags for an AddressSanitizer build.
#
# The compiler is Apple's, not the LibreDarwin toolchain: an ASan build is for
# finding memory errors in our own C, and the system clang ships the ASan
# runtime we link against.  Same reason as in BomCmds and AKCmds.
OPT := -O1 -g -fsanitize=address -fno-omit-frame-pointer
CC  := /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
