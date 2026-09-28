# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Open-source reimplementation of the developer tools in Apple's XCTest repo:
# xccov and xcresulttool, plus the vendored zstd decompressor they share.
#
# Build layout: every artifact lives under build/; final tools go to
# build/release/ or build/debug/ per CONFIG.
#
# Portable to both GNU make and BSD make (bmake): no pattern rules, no
# ifeq/ifdef/.if conditionals and no $(if)/$(shell) functions.  Per-config
# flags come from make/<CONFIG>.mk so both make variants behave identically.

CONFIG ?= release
SDK    ?= /Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.Internal.sdk
CC     := /Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
AR     := /Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar

-include make/$(CONFIG).mk

BUILD_DIR := build/$(CONFIG)
OBJDIR    := $(BUILD_DIR)/obj
LIBDIR    := $(BUILD_DIR)/lib

# -Isrc/zstd is in the tool flags as well as the library's: xcresult.c reaches
# zstd.h with angle brackets, so the header directory has to be on the search
# path of the translation units that call the decoder, not just the ones that
# implement it.
CFLAGS := $(OPT) -std=c11 -D_DARWIN_C_SOURCE -isysroot "$(SDK)" \
	  -Isrc -Isrc/common -Isrc/xccov -Isrc/zstd -Wall -Wextra

# zstd is vendored under src/zstd rather than linked from the system, for the
# same reason Apple bundles it into XCResultKit: neither the MacOSX SDK nor
# MacOSX.Internal.sdk ships a zstd, and Apple's xcresulttool has no zstd
# dylib dependency of its own -- the decoder is in the binary.
#
# Only the decompression half is vendored (lib/common + lib/decompress), which
# is all a .xcresult reader needs: an object is either stored raw or compressed
# with a current-frame zstd stream.  ZSTD_LEGACY_SUPPORT=0 drops the v01-v07
# decoders, which no bundle can contain; it already defaults to 0 upstream, and
# is spelled out so a future zstd bump cannot silently pull them back in.
ZSTD_CFLAGS := $(OPT) -std=c11 -D_DARWIN_C_SOURCE -isysroot "$(SDK)" \
	  -Isrc/zstd -Isrc/zstd/common -Isrc/zstd/decompress \
	  -DZSTD_LEGACY_SUPPORT=0 -Wall -Wextra -Wno-unused-parameter

# Apple's xccov links XCTHarness, DVTFoundation and IDEFoundation; its
# xcresulttool links CoreServices, UniformTypeIdentifiers and OSAnalytics.
# Ours read the bundle format directly -- an NSKeyedArchiver plist plus a
# content-addressed object store -- so CoreFoundation is the only framework
# either tool needs, and neither links XCTest.framework.
FW := -framework CoreFoundation

XCCOV        := $(BUILD_DIR)/xccov
XCCOV_OBJS   := $(OBJDIR)/xcresult.o $(OBJDIR)/bkeyed.o $(OBJDIR)/xccov.o

XCRESULTTOOL        := $(BUILD_DIR)/xcresulttool
XCRESULTTOOL_OBJS   := $(OBJDIR)/xcresult.o $(OBJDIR)/xcresulttool.o

LIBZSTD      := $(LIBDIR)/libzstd.a
# huf_decompress_amd64.S is the x86-64 HUF assembly loop that huf_decompress.c
# calls when ZSTD_ENABLE_ASM_X86_64_BMI2 is on. It assembles to an empty object
# on arm64, so it is listed unconditionally and the archive stays identical
# across architectures without a make conditional.
LIBZSTD_OBJS := $(OBJDIR)/zstd_debug.o $(OBJDIR)/zstd_entropy_common.o \
	$(OBJDIR)/zstd_error_private.o $(OBJDIR)/zstd_fse_decompress.o \
	$(OBJDIR)/zstd_pool.o $(OBJDIR)/zstd_threading.o \
	$(OBJDIR)/zstd_xxhash.o $(OBJDIR)/zstd_zstd_common.o \
	$(OBJDIR)/zstd_huf_decompress.o $(OBJDIR)/zstd_huf_decompress_amd64.o \
	$(OBJDIR)/zstd_zstd_ddict.o \
	$(OBJDIR)/zstd_zstd_decompress.o \
	$(OBJDIR)/zstd_zstd_decompress_block.o

PREFIX  ?= /usr/local
DESTDIR ?=

all: $(XCCOV) $(XCRESULTTOOL)

$(XCCOV): $(XCCOV_OBJS) $(LIBZSTD)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $(XCCOV_OBJS) $(LIBZSTD) $(FW)

$(XCRESULTTOOL): $(XCRESULTTOOL_OBJS) $(LIBZSTD)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $(XCRESULTTOOL_OBJS) $(LIBZSTD) $(FW)

# -rcs: replace, create, and write a symbol index, so no separate ranlib pass
# is needed and both make variants produce the same archive.
$(LIBZSTD): $(LIBZSTD_OBJS)
	@mkdir -p $(LIBDIR)
	rm -f $@
	$(AR) rcs $@ $(LIBZSTD_OBJS)

$(OBJDIR)/xcresult.o: src/common/xcresult.c src/common/xcresult.h src/zstd/zstd.h
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ src/common/xcresult.c

$(OBJDIR)/bkeyed.o: src/xccov/bkeyed.c src/xccov/bkeyed.h
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ src/xccov/bkeyed.c

$(OBJDIR)/xccov.o: src/xccov/xccov.c src/xccov/bkeyed.h src/common/xcresult.h
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ src/xccov/xccov.c

$(OBJDIR)/xcresulttool.o: src/xcresulttool/xcresulttool.c src/common/xcresult.h
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ src/xcresulttool/xcresulttool.c

$(OBJDIR)/zstd_debug.o: src/zstd/common/debug.c src/zstd/common/debug.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/debug.c

$(OBJDIR)/zstd_entropy_common.o: src/zstd/common/entropy_common.c src/zstd/common/mem.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/common/debug.h src/zstd/common/zstd_deps.h src/zstd/common/error_private.h src/zstd/zstd_errors.h src/zstd/common/fse.h src/zstd/common/bitstream.h src/zstd/common/bits.h src/zstd/common/huf.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/entropy_common.c

$(OBJDIR)/zstd_error_private.o: src/zstd/common/error_private.c src/zstd/common/error_private.h src/zstd/zstd_errors.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/common/debug.h src/zstd/common/zstd_deps.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/error_private.c

$(OBJDIR)/zstd_fse_decompress.o: src/zstd/common/fse_decompress.c src/zstd/common/debug.h src/zstd/common/bitstream.h src/zstd/common/mem.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/common/zstd_deps.h src/zstd/common/error_private.h src/zstd/zstd_errors.h src/zstd/common/bits.h src/zstd/common/fse.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/fse_decompress.c

$(OBJDIR)/zstd_pool.o: src/zstd/common/pool.c src/zstd/common/allocations.h src/zstd/common/zstd_deps.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/zstd.h src/zstd/zstd_errors.h src/zstd/common/debug.h src/zstd/common/pool.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/pool.c

$(OBJDIR)/zstd_threading.o: src/zstd/common/threading.c src/zstd/common/threading.h src/zstd/common/debug.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/threading.c

$(OBJDIR)/zstd_xxhash.o: src/zstd/common/xxhash.c src/zstd/common/xxhash.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/xxhash.c

$(OBJDIR)/zstd_zstd_common.o: src/zstd/common/zstd_common.c src/zstd/common/error_private.h src/zstd/zstd_errors.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/common/debug.h src/zstd/common/zstd_deps.h src/zstd/common/zstd_internal.h src/zstd/common/cpu.h src/zstd/common/mem.h src/zstd/zstd.h src/zstd/common/fse.h src/zstd/common/bitstream.h src/zstd/common/bits.h src/zstd/common/huf.h src/zstd/common/xxhash.h src/zstd/common/zstd_trace.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/common/zstd_common.c

$(OBJDIR)/zstd_huf_decompress.o: src/zstd/decompress/huf_decompress.c src/zstd/common/zstd_deps.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/common/bitstream.h src/zstd/common/mem.h src/zstd/common/debug.h src/zstd/common/error_private.h src/zstd/zstd_errors.h src/zstd/common/bits.h src/zstd/common/fse.h src/zstd/common/huf.h src/zstd/common/zstd_internal.h src/zstd/common/cpu.h src/zstd/zstd.h src/zstd/common/xxhash.h src/zstd/common/zstd_trace.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/decompress/huf_decompress.c

# The assembly needs the C preprocessor (portability_macros.h gates the whole
# body), so it is assembled through clang rather than run through $(AS).
$(OBJDIR)/zstd_huf_decompress_amd64.o: src/zstd/decompress/huf_decompress_amd64.S src/zstd/common/portability_macros.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/decompress/huf_decompress_amd64.S

$(OBJDIR)/zstd_zstd_ddict.o: src/zstd/decompress/zstd_ddict.c src/zstd/common/allocations.h src/zstd/common/zstd_deps.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/zstd.h src/zstd/zstd_errors.h src/zstd/common/cpu.h src/zstd/common/mem.h src/zstd/common/debug.h src/zstd/common/fse.h src/zstd/common/bitstream.h src/zstd/common/error_private.h src/zstd/common/bits.h src/zstd/common/huf.h src/zstd/decompress/zstd_decompress_internal.h src/zstd/common/zstd_internal.h src/zstd/common/xxhash.h src/zstd/common/zstd_trace.h src/zstd/decompress/zstd_ddict.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/decompress/zstd_ddict.c

$(OBJDIR)/zstd_zstd_decompress.o: src/zstd/decompress/zstd_decompress.c src/zstd/common/zstd_deps.h src/zstd/common/allocations.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/zstd.h src/zstd/zstd_errors.h src/zstd/common/error_private.h src/zstd/common/debug.h src/zstd/common/zstd_internal.h src/zstd/common/cpu.h src/zstd/common/mem.h src/zstd/common/fse.h src/zstd/common/bitstream.h src/zstd/common/bits.h src/zstd/common/huf.h src/zstd/common/xxhash.h src/zstd/common/zstd_trace.h src/zstd/decompress/zstd_decompress_internal.h src/zstd/decompress/zstd_ddict.h src/zstd/decompress/zstd_decompress_block.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/decompress/zstd_decompress.c

$(OBJDIR)/zstd_zstd_decompress_block.o: src/zstd/decompress/zstd_decompress_block.c src/zstd/common/zstd_deps.h src/zstd/common/compiler.h src/zstd/common/portability_macros.h src/zstd/common/cpu.h src/zstd/common/mem.h src/zstd/common/fse.h src/zstd/common/bitstream.h src/zstd/common/error_private.h src/zstd/zstd_errors.h src/zstd/common/bits.h src/zstd/common/huf.h src/zstd/common/zstd_internal.h src/zstd/zstd.h src/zstd/common/xxhash.h src/zstd/common/zstd_trace.h src/zstd/decompress/zstd_decompress_internal.h src/zstd/decompress/zstd_ddict.h src/zstd/decompress/zstd_decompress_block.h
	@mkdir -p $(OBJDIR)
	$(CC) $(ZSTD_CFLAGS) -c -o $@ src/zstd/decompress/zstd_decompress_block.c

# Both tools must resolve CoreFoundation from the system, with no zstd dylib
# dependency: the decoder is linked in statically, the way Apple links it into
# XCResultKit.  This is the link-level half of that claim; `smoke` below is the
# run-level half.
check-link: all
	@for t in $(XCCOV) $(XCRESULTTOOL); do \
		if ! otool -l $$t | grep -q 'CoreFoundation'; then \
			echo "$$t: not linked to CoreFoundation"; exit 1; \
		fi; \
		if otool -L $$t | grep -qi 'zstd'; then \
			echo "$$t: has a zstd dylib dependency"; exit 1; \
		fi; \
	done
	@echo "xccov/xcresulttool -> CoreFoundation, zstd static OK"

# Usage output is the tools' only behaviour that needs no input bundle, so it
# is the smallest thing worth asserting on every build: both must print their
# synopsis and exit non-zero when given nothing to read.  Run as a script
# rather than inline so the same check runs under both make variants.
smoke: all
	@bash tools/smoke.sh "build/$(CONFIG)/xccov" "build/$(CONFIG)/xcresulttool"

test: check-link smoke

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(XCCOV) $(DESTDIR)$(PREFIX)/bin/xccov
	install -m 0755 $(XCRESULTTOOL) $(DESTDIR)$(PREFIX)/bin/xcresulttool

clean:
	rm -rf build

.PHONY: all check-link smoke test install clean
