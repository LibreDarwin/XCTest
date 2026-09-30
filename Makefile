# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Open-source reimplementation of the developer tools in Apple's XCTest repo:
# xccov and xcresulttool, plus the vendored zstd decompressor they share, and
# the XCTest.framework the test code itself is compiled and linked against.
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
# XCTest.framework's objects are kept apart from the C tools' so that no .o is
# ever shared between a -std=c11 translation unit and an ObjC one.
XCTEST_OBJDIR := $(BUILD_DIR)/obj-xctest

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

# XCTest.framework's sources are Objective-C, so they cannot share CFLAGS: the
# -std=c11 above is a hard error for an ObjC translation unit.  -fobjc-arc is
# what the whole framework is written under.  The public headers are found
# through <XCTest/...>, so src/xctest/include is the include root, and
# src/xctest is on the path for the private headers that sit next to the .m
# files.  No -Werror here, matching CFLAGS: the C tools do not use it either,
# and a warning in a vendored tree should not stop the build.
OBJCFLAGS := $(OPT) -fobjc-arc -fobjc-exceptions -fblocks -isysroot "$(SDK)" \
	  -Isrc/xctest/include -Isrc/xctest -Wall -Wextra

# Apple's xccov links XCTHarness, DVTFoundation and IDEFoundation; its
# xcresulttool links CoreServices, UniformTypeIdentifiers and OSAnalytics.
# Ours read the bundle format directly -- an NSKeyedArchiver plist plus a
# content-addressed object store -- so CoreFoundation is the only framework
# either tool needs, and neither links XCTest.framework.
FW := -framework CoreFoundation

# XCTest.framework is a versioned bundle: the binary, the public headers, the
# module map and the Info.plist all live under Versions/A, and the top level
# names are symlinks through Versions/Current.  That is the shape clients
# expect from a framework, and the shape the -install_name below advertises.
#
# The binary is linked as a dylib with an @rpath install name rather than an
# absolute one, so the same build works from build/ or from $(PREFIX)/lib.  It
# links Foundation and nothing else: no dylib dependency on Apple's own
# XCTest.framework, which is the whole point of building this.
XCTEST_FW_DIR  := $(BUILD_DIR)/XCTest.framework
XCTEST_FW_VER  := $(XCTEST_FW_DIR)/Versions/A
XCTEST_FW      := $(XCTEST_FW_VER)/XCTest
XCTEST_FW_STAMP := $(XCTEST_FW_DIR)/.stamp
XCTEST_FW_LDFLAGS := -dynamiclib -install_name "@rpath/XCTest.framework/Versions/A/XCTest" -framework Foundation

# Every public header is installed, not just the ones a given object happens to
# include: a framework that ships a binary but not its full header set is
# broken for any client that imports the umbrella.  The same list doubles as the
# bundle's rebuild dependency, so editing any public header restages it.
#
# The five private headers (XCTestInternal.h, XCTestFoundationCompat.h,
# XCTestObservationInternal.h, XCTestExpectationInternal.h and
# XCTestAssertionFormats.h) are deliberately not installed: they sit in
# src/xctest rather than include/XCTest because they are not part of the
# public API, and a client that needs one of them is a client we cannot
# support the same way twice.
XCTEST_FW_HEADERS := src/xctest/include/XCTest/XCAbstractTest.h \
	src/xctest/include/XCTest/XCTActivity.h \
	src/xctest/include/XCTest/XCTAttachment.h \
	src/xctest/include/XCTest/XCTAttachmentLifetime.h \
	src/xctest/include/XCTest/XCTContext.h \
	src/xctest/include/XCTest/XCTDarwinNotificationExpectation.h \
	src/xctest/include/XCTest/XCTExpectedFailure.h \
	src/xctest/include/XCTest/XCTIssue.h \
	src/xctest/include/XCTest/XCTKVOExpectation.h \
	src/xctest/include/XCTest/XCTMeasureOptions.h \
	src/xctest/include/XCTest/XCTMetric.h \
	src/xctest/include/XCTest/XCTNSNotificationExpectation.h \
	src/xctest/include/XCTest/XCTNSPredicateExpectation.h \
	src/xctest/include/XCTest/XCTSourceCodeContext.h \
	src/xctest/include/XCTest/XCTWaiter.h \
	src/xctest/include/XCTest/XCTest.h \
	src/xctest/include/XCTest/XCTestAssertions.h \
	src/xctest/include/XCTest/XCTestAssertionsImpl.h \
	src/xctest/include/XCTest/XCTestCase.h \
	src/xctest/include/XCTest/XCTestCaseRun.h \
	src/xctest/include/XCTest/XCTestDefines.h \
	src/xctest/include/XCTest/XCTestErrors.h \
	src/xctest/include/XCTest/XCTestExpectation.h \
	src/xctest/include/XCTest/XCTestObservation.h \
	src/xctest/include/XCTest/XCTestObservationCenter.h \
	src/xctest/include/XCTest/XCTestObserver.h \
	src/xctest/include/XCTest/XCTestRun.h \
	src/xctest/include/XCTest/XCTestSkipping.h \
	src/xctest/include/XCTest/XCTestSkippingImpl.h \
	src/xctest/include/XCTest/XCTestSuite.h \
	src/xctest/include/XCTest/XCTestSuiteRun.h

XCTEST_PRIV_HDRS := src/xctest/XCTestAssertionFormats.h \
	src/xctest/XCTestExpectationInternal.h \
	src/xctest/XCTestFoundationCompat.h \
	src/xctest/XCTestInternal.h \
	src/xctest/XCTestObservationInternal.h

XCTEST_FW_OBJS := $(XCTEST_OBJDIR)/XCTest.o $(XCTEST_OBJDIR)/XCTestSuite.o \
	$(XCTEST_OBJDIR)/XCTestCase.o $(XCTEST_OBJDIR)/XCTestRun.o \
	$(XCTEST_OBJDIR)/XCTestObservation.o $(XCTEST_OBJDIR)/XCTestAssertions.o \
	$(XCTEST_OBJDIR)/XCTestInternal.o $(XCTEST_OBJDIR)/XCTestSupportTypes.o \
	$(XCTEST_OBJDIR)/XCTestMetrics.o \
	$(XCTEST_OBJDIR)/XCTestExpectation.o $(XCTEST_OBJDIR)/XCTWaiter.o \
	$(XCTEST_OBJDIR)/XCTNSNotificationExpectation.o \
	$(XCTEST_OBJDIR)/XCTNSPredicateExpectation.o \
	$(XCTEST_OBJDIR)/XCTKVOExpectation.o \
	$(XCTEST_OBJDIR)/XCTDarwinNotificationExpectation.o \
	$(XCTEST_OBJDIR)/XCTExpectedFailure.o

# XCTestCore.framework is Apple's private half of a test run: it holds the value
# that describes a run and the driver that executes it, and no test author ever
# compiles against it. It is a separate framework rather than part of XCTest
# because that separation is load-bearing -- see the note on the dependency
# direction in the module map.
#
# It gets its own object directory for the same reason XCTest.framework does: the
# two are built from a different include root, and sharing a .o between them
# would mean a header edit on one side silently deciding the other's build.
XCTESTCORE_OBJDIR := $(BUILD_DIR)/obj-xctestcore
XCTESTCORE_OBJCFLAGS := $(OPT) -fobjc-arc -fobjc-exceptions -fblocks -isysroot "$(SDK)" \
	  -Isrc/xctestcore/include -Isrc/xctestcore -Wall -Wextra

# The same versioned-bundle shape as XCTest.framework, with an @rpath install
# name for the same reason. Foundation is the only link: this slice is value
# types, so there is nothing here to justify a dependency on the public
# XCTest.framework, and adding one would make the private framework look like
# something a test bundle could load.
XCTESTCORE_FW_DIR  := $(BUILD_DIR)/XCTestCore.framework
XCTESTCORE_FW_VER  := $(XCTESTCORE_FW_DIR)/Versions/A
XCTESTCORE_FW      := $(XCTESTCORE_FW_VER)/XCTestCore
XCTESTCORE_FW_STAMP := $(XCTESTCORE_FW_DIR)/.stamp
XCTESTCORE_FW_LDFLAGS := -dynamiclib -install_name "@rpath/XCTestCore.framework/Versions/A/XCTestCore" -framework Foundation

# The installed headers, and the module map's umbrella. The umbrella is listed
# after the headers it imports, which is the order a reader wants but not the
# order anything depends on -- make does not care, and the header guard does
# the rest. The private header stays in src/xctestcore: it declares Foundation
# members for this implementation's own use, and a client that needs one is a
# client we cannot support the same way twice.
XCTESTCORE_API_HDRS := src/xctestcore/include/XCTestCore/XCTestConfiguration.h \
	src/xctestcore/include/XCTestCore/XCTestConfigurationLoader.h \
	src/xctestcore/include/XCTestCore/XCTTestSelection.h
XCTESTCORE_FW_HEADERS := $(XCTESTCORE_API_HDRS) src/xctestcore/include/XCTestCore/XCTestCore.h
XCTESTCORE_PRIV_HDRS := src/xctestcore/XCTestCoreFoundationCompat.h

# One object per source, spelled out. A pattern rule would be shorter and would
# not build under bmake, and the whole reason this project builds under both is
# that nothing here depends on a GNU extension.
XCTESTCORE_FW_OBJS := $(XCTESTCORE_OBJDIR)/XCTestConfiguration.o $(XCTESTCORE_OBJDIR)/XCTestConfigurationLoader.o $(XCTESTCORE_OBJDIR)/XCTTestSelection.o

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

all: $(XCCOV) $(XCRESULTTOOL) $(XCTEST_FW_STAMP) $(XCTESTCORE_FW_STAMP)

# The bundle is assembled into a stamp file rather than being a make target in
# its own right: a framework is a directory, and every make variant treats a
# directory's timestamp as meaningless, so depending on one directly would
# either rebuild forever or never rebuild.  The stamp depends on the binary and
# on every installed file, so it goes stale exactly when the bundle does.
$(XCTEST_FW_STAMP): $(XCTEST_FW) src/xctest/module.modulemap src/xctest/Info.plist $(XCTEST_FW_HEADERS)
	@mkdir -p $(XCTEST_FW_VER)/Headers $(XCTEST_FW_VER)/Modules $(XCTEST_FW_VER)/Resources
	cp $(XCTEST_FW_HEADERS) $(XCTEST_FW_VER)/Headers
	cp src/xctest/module.modulemap $(XCTEST_FW_VER)/Modules/module.modulemap
	cp src/xctest/Info.plist $(XCTEST_FW_VER)/Resources/Info.plist
	rm -f $(XCTEST_FW_DIR)/Versions/Current
	ln -s A $(XCTEST_FW_DIR)/Versions/Current
	rm -f $(XCTEST_FW_DIR)/Headers $(XCTEST_FW_DIR)/Modules \
		$(XCTEST_FW_DIR)/Resources $(XCTEST_FW_DIR)/XCTest
	ln -s Versions/Current/Headers $(XCTEST_FW_DIR)/Headers
	ln -s Versions/Current/Modules $(XCTEST_FW_DIR)/Modules
	ln -s Versions/Current/Resources $(XCTEST_FW_DIR)/Resources
	ln -s Versions/Current/XCTest $(XCTEST_FW_DIR)/XCTest
	@touch $@

$(XCTEST_FW): $(XCTEST_FW_OBJS)
	@mkdir -p $(XCTEST_FW_VER)
	$(CC) $(OBJCFLAGS) $(XCTEST_FW_LDFLAGS) -o $@ $(XCTEST_FW_OBJS)

# Every object depends on the whole public header set, because the umbrella
# header XCTest.h includes all of it and most translation units import the
# umbrella: a header reached through the umbrella is still a header the object
# was compiled against, and listing only the directly-imported ones would let
# make keep a stale .o after an edit to a header two levels down.  That
# over-approximates for the two or three units that import a narrow subset
# directly (XCTWaiter.m, XCTestObservation.m), which costs an occasional
# redundant recompile and never a wrong one.  The private headers are listed
# per unit because those genuinely differ, and that is where the discrimination
# is worth having.
$(XCTEST_OBJDIR)/XCTest.o: src/xctest/XCTest.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestFoundationCompat.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTest.m

$(XCTEST_OBJDIR)/XCTestSuite.o: src/xctest/XCTestSuite.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestFoundationCompat.h src/xctest/XCTestObservationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestSuite.m

$(XCTEST_OBJDIR)/XCTestCase.o: src/xctest/XCTestCase.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestFoundationCompat.h src/xctest/XCTestObservationInternal.h src/xctest/XCTestExpectationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestCase.m

$(XCTEST_OBJDIR)/XCTestRun.o: src/xctest/XCTestRun.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestFoundationCompat.h src/xctest/XCTestObservationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestRun.m

$(XCTEST_OBJDIR)/XCTestObservation.o: src/xctest/XCTestObservation.m $(XCTEST_FW_HEADERS) src/xctest/XCTestFoundationCompat.h src/xctest/XCTestObservationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestObservation.m

$(XCTEST_OBJDIR)/XCTestAssertions.o: src/xctest/XCTestAssertions.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestAssertionFormats.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestAssertions.m

$(XCTEST_OBJDIR)/XCTestInternal.o: src/xctest/XCTestInternal.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestInternal.m

$(XCTEST_OBJDIR)/XCTestSupportTypes.o: src/xctest/XCTestSupportTypes.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestSupportTypes.m

# The performance category adds a category on XCTestCase and reaches the
# test case's private ivars through accessors, so it depends on XCTestCase.m's
# interface as well as the compat header it calls -componentsJoinedByString: on.
$(XCTEST_OBJDIR)/XCTestMetrics.o: src/xctest/XCTestMetrics.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestFoundationCompat.h src/xctest/XCTestCase.m
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestMetrics.m

$(XCTEST_OBJDIR)/XCTestExpectation.o: src/xctest/XCTestExpectation.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h src/xctest/XCTestFoundationCompat.h src/xctest/XCTestExpectationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTestExpectation.m

$(XCTEST_OBJDIR)/XCTWaiter.o: src/xctest/XCTWaiter.m $(XCTEST_FW_HEADERS) src/xctest/XCTestFoundationCompat.h src/xctest/XCTestExpectationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTWaiter.m

# The four subclass units share a dependency set: each is a subclass of
# XCTestExpectation, so each needs the base class's private header for the poll
# hook and the issue-attribution helper, plus the compatibility header for the
# Foundation or notify(3) API its own feature is missing from the reduced SDK.
$(XCTEST_OBJDIR)/XCTNSNotificationExpectation.o: src/xctest/XCTNSNotificationExpectation.m $(XCTEST_FW_HEADERS) src/xctest/XCTestFoundationCompat.h src/xctest/XCTestExpectationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTNSNotificationExpectation.m

$(XCTEST_OBJDIR)/XCTNSPredicateExpectation.o: src/xctest/XCTNSPredicateExpectation.m $(XCTEST_FW_HEADERS) src/xctest/XCTestFoundationCompat.h src/xctest/XCTestExpectationInternal.h src/xctest/XCTestInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTNSPredicateExpectation.m

$(XCTEST_OBJDIR)/XCTKVOExpectation.o: src/xctest/XCTKVOExpectation.m $(XCTEST_FW_HEADERS) src/xctest/XCTestFoundationCompat.h src/xctest/XCTestExpectationInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTKVOExpectation.m

$(XCTEST_OBJDIR)/XCTDarwinNotificationExpectation.o: src/xctest/XCTDarwinNotificationExpectation.m $(XCTEST_FW_HEADERS) src/xctest/XCTestFoundationCompat.h src/xctest/XCTestExpectationInternal.h src/xctest/XCTestInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTDarwinNotificationExpectation.m

$(XCTEST_OBJDIR)/XCTExpectedFailure.o: src/xctest/XCTExpectedFailure.m $(XCTEST_FW_HEADERS) src/xctest/XCTestInternal.h
	@mkdir -p $(XCTEST_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctest/XCTExpectedFailure.m

# XCTestCore.framework is assembled the same way, for the same reason a
# framework cannot be a make target in its own right: its stamp goes stale
# exactly when the bundle does.
$(XCTESTCORE_FW_STAMP): $(XCTESTCORE_FW) src/xctestcore/module.modulemap src/xctestcore/Info.plist $(XCTESTCORE_FW_HEADERS)
	@mkdir -p $(XCTESTCORE_FW_VER)/Headers $(XCTESTCORE_FW_VER)/Modules $(XCTESTCORE_FW_VER)/Resources
	cp $(XCTESTCORE_FW_HEADERS) $(XCTESTCORE_FW_VER)/Headers
	cp src/xctestcore/module.modulemap $(XCTESTCORE_FW_VER)/Modules/module.modulemap
	cp src/xctestcore/Info.plist $(XCTESTCORE_FW_VER)/Resources/Info.plist
	rm -f $(XCTESTCORE_FW_DIR)/Versions/Current
	ln -s A $(XCTESTCORE_FW_DIR)/Versions/Current
	rm -f $(XCTESTCORE_FW_DIR)/Headers $(XCTESTCORE_FW_DIR)/Modules \
		$(XCTESTCORE_FW_DIR)/Resources $(XCTESTCORE_FW_DIR)/XCTestCore
	ln -s Versions/Current/Headers $(XCTESTCORE_FW_DIR)/Headers
	ln -s Versions/Current/Modules $(XCTESTCORE_FW_DIR)/Modules
	ln -s Versions/Current/Resources $(XCTESTCORE_FW_DIR)/Resources
	ln -s Versions/Current/XCTestCore $(XCTESTCORE_FW_DIR)/XCTestCore
	@touch $@

$(XCTESTCORE_FW): $(XCTESTCORE_FW_OBJS)
	@mkdir -p $(XCTESTCORE_FW_VER)
	$(CC) $(XCTESTCORE_OBJCFLAGS) $(XCTESTCORE_FW_LDFLAGS) -o $@ $(XCTESTCORE_FW_OBJS)

$(XCTESTCORE_OBJDIR)/XCTestConfiguration.o: src/xctestcore/XCTestConfiguration.m $(XCTESTCORE_FW_HEADERS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(XCTESTCORE_OBJCFLAGS) -c -o $@ src/xctestcore/XCTestConfiguration.m

# Depends on the API headers rather than on $(XCTESTCORE_FW_HEADERS): the
# umbrella imports all of them, so a rule that named it as a prerequisite would
# claim this object changes when only the umbrella's comment does. Cheap to be
# wrong about in the other direction, not in this one.
$(XCTESTCORE_OBJDIR)/XCTTestSelection.o: src/xctestcore/XCTTestSelection.m $(XCTESTCORE_API_HDRS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(XCTESTCORE_OBJCFLAGS) -c -o $@ src/xctestcore/XCTTestSelection.m

# The loader is the one XCTestCore unit that reaches for os_log and dispatch, so
# it is also the one whose header dependency is worth naming exactly: it imports
# the loader header, which imports both value headers, so the API list covers it
# without the umbrella being dragged in.
$(XCTESTCORE_OBJDIR)/XCTestConfigurationLoader.o: src/xctestcore/XCTestConfigurationLoader.m $(XCTESTCORE_API_HDRS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(XCTESTCORE_OBJCFLAGS) -c -o $@ src/xctestcore/XCTestConfigurationLoader.m

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

# XCTest.framework gets its own check, in a script for the same reason as above:
# it is long, and it has to run identically under both make variants.  Four
# layers -- the bundle layout, the dylib's link contract, a client that compiles,
# links and runs against the built framework with nothing but -rpath to find it,
# and the expectation subclasses driven for real.  The last two are what would
# catch a bundle that builds but cannot be loaded, and a subclass that links but
# does not deliver.
check-framework: $(XCTEST_FW_STAMP)
	@bash tools/framework-smoke.sh "$(XCTEST_FW_DIR)" "$(SDK)" "$(CC)"

check-expectations: $(XCTEST_FW_STAMP)
	@FRAMEWORK="$(XCTEST_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-expectations.sh

# The source context is the value type every failure passes through, and a
# broken one still compiles, still links, and still leaves an issue with a
# context attached -- just without the file and line of the failure. Nothing
# else in the tree would notice.
check-source-context: $(XCTEST_FW_STAMP)
	@FRAMEWORK="$(XCTEST_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-source-context.sh

# The measure loop is the only part of XCTest whose result the framework never
# hands back to the caller, so a harness is the only way to see it work: it
# drives the block, the options, the manual bounds and a client metric of its own,
# and reads the private records to check what was measured. Everything else
# about the measurement API is plain value types that check-link already covers.
check-metrics: $(XCTEST_FW_STAMP)
	@FRAMEWORK="$(XCTEST_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-metrics.sh

# A test configuration is a value that crosses a process boundary as a plist and
# is then read back to decide what runs, so nothing about it is observable from
# this process: a harness is the only way to see it work. It drives the derived
# values (-testMode, -testBundleName), the secure-coding round trip including the
# partial-archive fallback, -isEqual:/copy and the ordering helpers.
check-configuration: $(XCTESTCORE_FW_STAMP)
	@FRAMEWORK="$(XCTESTCORE_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-configuration.sh

# A selection is a value that crosses a process boundary the same way a
# configuration does, and its interesting behaviour is almost entirely in the
# decoder: an absent mode key and an explicit zero key are one bit apart in the
# archive and select opposite sets of tests. A harness is the only way to see
# any of it work. It probes the archives rather than the objects, so the key
# names -- the interface with the IDE, an .xctestrun, and the shipped
# framework -- are checked rather than assumed.
check-selection: $(XCTESTCORE_FW_STAMP)
	@FRAMEWORK="$(XCTESTCORE_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-selection.sh

# The builder and the string parsers, which check-selection cannot reach: a
# selection read from a -only-testing: argument is a string, and no archive
# carries one.
check-builder: $(XCTESTCORE_FW_STAMP)
	@FRAMEWORK="$(XCTESTCORE_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-builder.sh

# The loader is the first XCTestCore unit with behaviour, and the only one whose
# interesting cases are decisions rather than values. Everything it does is
# invisible from the framework: it reads the process environment, a temporary
# directory and a plug-in directory, and answers with a configuration or nil. A
# harness is the only way to see any of it, and it has to own where the binary
# sits -- NSBundle.mainBundle decides source 4 -- which is why the runner copies
# the binary per scenario and sweeps the account's temporary directory afterwards.
check-loader: $(XCTESTCORE_FW_STAMP)
	@FRAMEWORK="$(XCTESTCORE_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-loader.sh

# The implementation has to compile on its own terms, and every function the headers
# export has to exist, or a caller only reaches it by luck. check-headers and
# check-macros prove the declarations are well-formed; this proves the definitions
# are there, for both XCTest and XCTestCore. It needs no framework, since it
# compiles from source, and it used to be run by hand only -- which is how a
# dead check survived: its set comparison was a no-op, so it passed for months
# without ever comparing anything.
check-sources:
	@SDK="$(SDK)" CC="$(CC)" bash tools/check-sources.sh

test: check-link smoke check-framework check-expectations check-source-context check-metrics check-configuration check-selection check-builder check-loader check-sources

# Editor configuration, not build output. Not in `all` and not in `test`: the
# committed src/xctest/.clangd is already usable, and regenerating it is only
# needed when the SDK above changes. Kept out of `all` so a plain build never
# rewrites a tracked file.
clangd-config:
	@SDK="$(SDK)" bash tools/gen-clangd-config.sh

# Builds the XCTest framework through Xcode instead of the Makefile, then runs
# the same framework smoke against that product, so the two build systems are
# held to one standard. Not part of `test`: it needs an Xcode install and takes
# far longer than the Makefile path, so it is opt-in and fails loudly when
# xcodebuild is absent rather than silently skipping.
#
# The Makefile has three configurations (release/debug/asan) and the Xcode
# project has two, named Release and Debug with capitals. CONFIG=debug does not
# match "Debug", and asan has no Xcode counterpart at all -- adding one would
# mean inventing flags with no make/asan.mk to agree with, which is a bigger
# decision than this target should make on its own. So the mapping is a shell
# case statement in the recipe: both make flavours pass it through unchanged,
# which a make-level conditional assignment could not do here.
#
# CONFIGURATION_BUILD_DIR in the project points at build/xcode-<config>, and its
# OBJROOT at build/xcode-obj/<config>, neither of which the Makefile uses.
# Sharing those directories with the Makefile is what made this check
# untrustworthy: the Xcode product and the make product sat in the same tree, so
# a stale framework from a previous make could satisfy the smoke test after a
# failed or skipped xcodebuild. A separate directory plus a clean makes the
# smoke test describe the binary xcodebuild just produced and nothing else.
#
# The intermediates are removed too, not just the product. Cleaning the product
# alone is what made this check unreliable in the other direction: an object
# tree that outlived the project edit that should have invalidated it is reused
# silently, and a source dropped from the target keeps its .o. The build
# directory is rebuilt from nothing, which is slower and is the point.
#
# The three checks after the build are &&-chained, not ;-chained. With a ';' the
# recipe's exit status is the last command's, so a failing check-expectations.sh
# followed by a passing check-source-context.sh would report success.
check-xcode:
	@command -v xcodebuild >/dev/null 2>&1 || \
		{ echo "check-xcode: xcodebuild not found; install Xcode or use 'make test'"; exit 1; }
	@case "$(CONFIG)" in \
		release) xc=Release; dir=release ;; \
		debug)   xc=Debug;   dir=debug ;; \
		*)       xc=Release; dir=release; \
		         echo "check-xcode: CONFIG=$(CONFIG) has no Xcode configuration, using Release" ;; \
	esac; \
	echo "check-xcode: building XCTest.framework and XCTestCore.framework ($$xc) via xcodebuild"; \
	rm -rf "build/xcode-$$dir" "build/xcode-obj/$$dir" "build/xcode-obj/$$dir-xctestcore"; \
	for t in XCTest XCTestCore; do \
		xcodebuild -project XCTest.xcodeproj -target $$t -configuration "$$xc" build \
			| grep -E '^(error|warning):|^\*\* BUILD' || { echo "check-xcode: xcodebuild failed for $$t"; exit 1; }; \
	done; \
	bash tools/framework-smoke.sh "build/xcode-$$dir/XCTest.framework" "$(SDK)" "$(CC)" && \
	FRAMEWORK="build/xcode-$$dir/XCTest.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-expectations.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTest.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-source-context.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTest.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-metrics.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-configuration.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-selection.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-builder.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-loader.sh

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(XCCOV) $(DESTDIR)$(PREFIX)/bin/xccov
	install -m 0755 $(XCRESULTTOOL) $(DESTDIR)$(PREFIX)/bin/xcresulttool
	# cp -R, not install: the bundle is a directory tree full of relative
	# symlinks, and install has no way to reproduce that layout.
	rm -rf $(DESTDIR)$(PREFIX)/lib/XCTest.framework
	install -d $(DESTDIR)$(PREFIX)/lib
	cp -R $(XCTEST_FW_DIR) $(DESTDIR)$(PREFIX)/lib/XCTest.framework
	# Both frameworks, in one cp -R each, for the reason noted above: the trees
	# are made of relative symlinks that install cannot reproduce.
	rm -rf $(DESTDIR)$(PREFIX)/lib/XCTestCore.framework
	cp -R $(XCTESTCORE_FW_DIR) $(DESTDIR)$(PREFIX)/lib/XCTestCore.framework

clean:
	rm -rf build

.PHONY: all check-link smoke check-framework check-expectations check-source-context check-metrics check-configuration check-selection check-builder check-loader check-sources test clangd-config check-xcode install clean
