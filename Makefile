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
# XCTestCore.framework's objects are kept apart from the C tools' so that no .o is
# ever shared between a -std=c11 translation unit and an ObjC one.  XCTest.framework
# links no objects of its own -- it re-exports XCTestCore -- so there is no third
# directory to keep separate.
XCTESTCORE_OBJDIR := $(BUILD_DIR)/obj-xctestcore

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

# Every implementation in both XCTest.framework and XCTestCore.framework is
# Objective-C, so neither can share CFLAGS: the -std=c11 above is a hard error
# for an ObjC translation unit.  -fobjc-arc is what the whole tree is written
# under.  No -Werror here, matching CFLAGS: the C tools do not use it either,
# and a warning in a vendored tree should not stop the build.
#
# XCTestCore.framework is where the test machinery is implemented, so this is
# the flags the .m files are built with: src/xctestcore/include is its own
# include root, src/xctestcore is on the path for the private headers that sit
# next to the .m files, and src/xctest/include is on it because the machinery
# declares itself in the public headers and imports them as <XCTest/...>.
# A header directory being on two include roots is not a link dependency: the
# dependency between the two frameworks is XCTestCore first, XCTest re-exporting
# it (see the note on XCTEST_FW_LDFLAGS).
OBJCFLAGS := $(OPT) -fobjc-arc -fobjc-exceptions -fblocks -isysroot "$(SDK)" \
	  -Isrc/xctestcore/include -Isrc/xctestcore -Isrc/xctest/include \
	  -Wall -Wextra

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
# absolute one, so the same build works from build/ or from $(PREFIX)/lib.
#
# Apple's XCTest.framework is 110 KB and exports exactly one symbol of its own
# (_XCUIEnableUIAutomation); the whole public API reaches the client by
# re-exporting XCTestCore.  Verified against the reference with
# `otool -arch arm64 -L`, which reports
#
#     @rpath/XCTestCore.framework/Versions/A/XCTestCore (reexport)
#
# for the public framework, and against the symbol tables, where XCTestCase,
# XCTestSuite, XCTestRun, XCTest, XCTestObservationCenter, XCTestExpectation,
# XCTWaiter, XCTIssue, XCTAttachment and every metric class are all *defined*
# in XCTestCore and defined nowhere in XCTest.  So the implementation lives in
# src/xctestcore and this framework is a shim: -reexport_framework is what makes
# `-framework XCTest` still satisfy a client that links the public name.
#
# Foundation is the only real link.  XCTestCore is found through -F and the
# install name is @rpath, so there is still no dependency on Apple's own
# XCTest.framework, which is the whole point of building this.
XCTEST_FW_DIR  := $(BUILD_DIR)/XCTest.framework
XCTEST_FW_VER  := $(XCTEST_FW_DIR)/Versions/A
XCTEST_FW      := $(XCTEST_FW_VER)/XCTest
XCTEST_FW_STAMP := $(XCTEST_FW_DIR)/.stamp
XCTEST_FW_LDFLAGS := -dynamiclib -install_name "@rpath/XCTest.framework/Versions/A/XCTest" \
	  -F"$(BUILD_DIR)" -framework Foundation -Wl,-reexport_framework,XCTestCore

# Every public header is installed, not just the ones a given object happens to
# include: a framework that ships a binary but not its full header set is
# broken for any client that imports the umbrella.  The same list doubles as the
# bundle's rebuild dependency, so editing any public header restages it.
#
# The five private headers (XCTestInternal.h, XCTestFoundationCompat.h,
# XCTestObservationInternal.h, XCTestExpectationInternal.h and
# XCTestAssertionFormats.h) are deliberately not installed: they sit in
# src/xctestcore rather than include/XCTest because they are not part of the
# public API, and a client that needs one of them is a client we cannot
# support the same way twice.  They moved to src/xctestcore with the
# implementation that includes them.
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

XCTEST_FW_OBJS :=

# XCTestCore.framework is Apple's private half of a test run, and it is where the
# whole test machinery is implemented: XCTest, XCTestCase, XCTestSuite,
# XCTestRun, the observation center, the expectations, the assertions and the
# metrics.  The public framework holds the headers and re-exports this one.
#
# The symbol tables are the authority for that split, not the class lists: the
# class dump for the public framework names XCTestCase, XCTestSuite and
# XCTMemoryMetric because they are *referenced* there, but every one of them has
# its `T` definitions in XCTestCore and none in XCTest.  The public framework's
# own 63 defined methods are the XCTestCase UI-testing categories
# (MemoryLeakTesting, XCUIAlertMonitoring, XCUIInterruptionMonitoring) and a
# handful of XCUIAutomation metric categories, none of which this port
# reimplements -- there is no XCUIAutomation.framework to put them in.
#
# It gets its own object directory for the same reason XCTest.framework does: the
# two are built from a different include root, and sharing a .o between them
# would mean a header edit on one side silently deciding the other's build.
XCTESTCORE_OBJDIR := $(BUILD_DIR)/obj-xctestcore

# The same versioned-bundle shape as XCTest.framework, with an @rpath install
# name for the same reason. Foundation is the only link: this is the bottom of
# the pair, and adding a dependency on the public XCTest.framework would invert
# the reference's own direction and make the private framework look like
# something a test bundle could load.
XCTESTCORE_FW_DIR  := $(BUILD_DIR)/XCTestCore.framework
XCTESTCORE_FW_VER  := $(XCTESTCORE_FW_DIR)/Versions/A
XCTESTCORE_FW      := $(XCTESTCORE_FW_VER)/XCTestCore
XCTESTCORE_FW_STAMP := $(XCTESTCORE_FW_DIR)/.stamp
XCTESTCORE_FW_LDFLAGS := -dynamiclib -install_name "@rpath/XCTestCore.framework/Versions/A/XCTestCore" -framework Foundation

# The installed headers, and the module map's umbrella. The umbrella is listed
# after the headers it imports, which is the order a reader wants but not the
# order anything depends on -- make does not care, and the header guard does
# the rest. The private headers stay in src/xctestcore: they declare Foundation
# members and the machinery's own internals for this implementation's use, and a
# client that needs one is a client we cannot support the same way twice.
XCTESTCORE_API_HDRS := src/xctestcore/include/XCTestCore/XCTestConfiguration.h \
	src/xctestcore/include/XCTestCore/XCTestConfigurationLoader.h \
	src/xctestcore/include/XCTestCore/XCActivityRecord.h \
	src/xctestcore/include/XCTestCore/XCTTestSelection.h \
	src/xctestcore/include/XCTestCore/XCTTestRunSession.h
XCTESTCORE_FW_HEADERS := $(XCTESTCORE_API_HDRS) src/xctestcore/include/XCTestCore/XCTestCore.h
XCTESTCORE_PRIV_HDRS := src/xctestcore/XCTestCoreFoundationCompat.h \
	src/xctestcore/XCTestAssertionFormats.h \
	src/xctestcore/XCTestExpectationInternal.h \
	src/xctestcore/XCTestFoundationCompat.h \
	src/xctestcore/XCTestInternal.h \
	src/xctestcore/XCTestObservationInternal.h \
	src/xctestcore/XCTActivityRecordStack.h

# One object per source, spelled out. A pattern rule would be shorter and would
# not build under bmake, and the whole reason this project builds under both is
# that nothing here depends on a GNU extension.
XCTESTCORE_FW_OBJS := $(XCTESTCORE_OBJDIR)/XCTest.o $(XCTESTCORE_OBJDIR)/XCTestSuite.o \
	$(XCTESTCORE_OBJDIR)/XCTestCase.o $(XCTESTCORE_OBJDIR)/XCTestRun.o \
	$(XCTESTCORE_OBJDIR)/XCTestCasePlaceholder.o \
	$(XCTESTCORE_OBJDIR)/XCTestObservation.o $(XCTESTCORE_OBJDIR)/XCTestAssertions.o \
	$(XCTESTCORE_OBJDIR)/XCActivityRecord.o \
	$(XCTESTCORE_OBJDIR)/XCTActivityRecordStack.o \
	$(XCTESTCORE_OBJDIR)/XCTContext.o \
	$(XCTESTCORE_OBJDIR)/XCTestInternal.o $(XCTESTCORE_OBJDIR)/XCTestSupportTypes.o \
	$(XCTESTCORE_OBJDIR)/XCTTestInvocationDescriptor.o \
	$(XCTESTCORE_OBJDIR)/XCTestMetrics.o \
	$(XCTESTCORE_OBJDIR)/XCTestExpectation.o $(XCTESTCORE_OBJDIR)/XCTWaiter.o \
	$(XCTESTCORE_OBJDIR)/XCTNSNotificationExpectation.o \
	$(XCTESTCORE_OBJDIR)/XCTNSPredicateExpectation.o \
	$(XCTESTCORE_OBJDIR)/XCTKVOExpectation.o \
	$(XCTESTCORE_OBJDIR)/XCTDarwinNotificationExpectation.o \
	$(XCTESTCORE_OBJDIR)/XCTExpectedFailure.o \
	$(XCTESTCORE_OBJDIR)/XCTestConfiguration.o \
	$(XCTESTCORE_OBJDIR)/XCTestConfigurationLoader.o \
	$(XCTESTCORE_OBJDIR)/XCTTestSelection.o \
	$(XCTESTCORE_OBJDIR)/XCTTestRunSession.o

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

# $(XCTEST_FW_OBJS) is empty, so this links no object at all: the binary exists to
# carry the install name and the re-export, which is the whole of what Apple's
# 110 KB shim adds over XCTestCore.  The XCTestCore stamp is a prerequisite, not
# the binary itself, because -F only has to find the bundle on disk at link time
# and the install name is @rpath -- the shim must not embed a build path.
$(XCTEST_FW): $(XCTEST_FW_OBJS) $(XCTESTCORE_FW_STAMP)
	@mkdir -p $(XCTEST_FW_VER)
	$(CC) $(OBJCFLAGS) $(XCTEST_FW_LDFLAGS) -o $@ $(XCTEST_FW_OBJS)

# Every machinery object depends on the whole public header set, because the
# umbrella header XCTest.h includes all of it and most translation units import
# the umbrella: a header reached through the umbrella is still a header the
# object was compiled against, and listing only the directly-imported ones would
# let make keep a stale .o after an edit to a header two levels down.  That
# over-approximates for the two or three units that import a narrow subset
# directly (XCTWaiter.m, XCTestObservation.m), which costs an occasional
# redundant recompile and never a wrong one.  The private headers are listed
# per unit because those genuinely differ, and that is where the discrimination
# is worth having.
$(XCTESTCORE_OBJDIR)/XCTest.o: src/xctestcore/XCTest.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTest.m

$(XCTESTCORE_OBJDIR)/XCTestSuite.o: src/xctestcore/XCTestSuite.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestObservationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestSuite.m

$(XCTESTCORE_OBJDIR)/XCTestCase.o: src/xctestcore/XCTestCase.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestObservationInternal.h src/xctestcore/XCTestExpectationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestCase.m

$(XCTESTCORE_OBJDIR)/XCTestRun.o: src/xctestcore/XCTestRun.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestObservationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestRun.m

$(XCTESTCORE_OBJDIR)/XCTestCasePlaceholder.o: src/xctestcore/XCTestCasePlaceholder.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/include/XCTestCore/XCTTestSelection.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestCasePlaceholder.m

$(XCTESTCORE_OBJDIR)/XCTestObservation.o: src/xctestcore/XCTestObservation.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestObservationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestObservation.m


$(XCTESTCORE_OBJDIR)/XCActivityRecord.o: src/xctestcore/XCActivityRecord.m $(XCTEST_FW_HEADERS) src/xctestcore/include/XCTestCore/XCActivityRecord.h
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCActivityRecord.m

$(XCTESTCORE_OBJDIR)/XCTActivityRecordStack.o: src/xctestcore/XCTActivityRecordStack.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTActivityRecordStack.h src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestObservationInternal.h
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTActivityRecordStack.m

$(XCTESTCORE_OBJDIR)/XCTContext.o: src/xctestcore/XCTContext.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTActivityRecordStack.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestObservationInternal.h
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTContext.m
$(XCTESTCORE_OBJDIR)/XCTestAssertions.o: src/xctestcore/XCTestAssertions.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestAssertionFormats.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestAssertions.m

$(XCTESTCORE_OBJDIR)/XCTestInternal.o: src/xctestcore/XCTestInternal.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestInternal.m

$(XCTESTCORE_OBJDIR)/XCTTestInvocationDescriptor.o: src/xctestcore/XCTTestInvocationDescriptor.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTTestInvocationDescriptor.m

$(XCTESTCORE_OBJDIR)/XCTestSupportTypes.o: src/xctestcore/XCTestSupportTypes.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestSupportTypes.m

# The performance category adds a category on XCTestCase and reaches the
# test case's private ivars through accessors, so it depends on XCTestCase.m's
# interface as well as the compat header it calls -componentsJoinedByString: on.
$(XCTESTCORE_OBJDIR)/XCTestMetrics.o: src/xctestcore/XCTestMetrics.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestCase.m
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestMetrics.m

$(XCTESTCORE_OBJDIR)/XCTestExpectation.o: src/xctestcore/XCTestExpectation.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestExpectationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestExpectation.m

$(XCTESTCORE_OBJDIR)/XCTWaiter.o: src/xctestcore/XCTWaiter.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestExpectationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTWaiter.m

$(XCTESTCORE_OBJDIR)/XCTNSNotificationExpectation.o: src/xctestcore/XCTNSNotificationExpectation.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestExpectationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTNSNotificationExpectation.m

$(XCTESTCORE_OBJDIR)/XCTNSPredicateExpectation.o: src/xctestcore/XCTNSPredicateExpectation.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestExpectationInternal.h src/xctestcore/XCTestInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTNSPredicateExpectation.m

$(XCTESTCORE_OBJDIR)/XCTKVOExpectation.o: src/xctestcore/XCTKVOExpectation.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestExpectationInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTKVOExpectation.m

$(XCTESTCORE_OBJDIR)/XCTDarwinNotificationExpectation.o: src/xctestcore/XCTDarwinNotificationExpectation.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestFoundationCompat.h src/xctestcore/XCTestExpectationInternal.h src/xctestcore/XCTestInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTDarwinNotificationExpectation.m

$(XCTESTCORE_OBJDIR)/XCTExpectedFailure.o: src/xctestcore/XCTExpectedFailure.m $(XCTEST_FW_HEADERS) src/xctestcore/XCTestInternal.h
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTExpectedFailure.m

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
	$(CC) $(OBJCFLAGS) $(XCTESTCORE_FW_LDFLAGS) -o $@ $(XCTESTCORE_FW_OBJS)

$(XCTESTCORE_OBJDIR)/XCTestConfiguration.o: src/xctestcore/XCTestConfiguration.m $(XCTESTCORE_FW_HEADERS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestConfiguration.m

# Depends on the API headers rather than on $(XCTESTCORE_FW_HEADERS): the
# umbrella imports all of them, so a rule that named it as a prerequisite would
# claim this object changes when only the umbrella's comment does. Cheap to be
# wrong about in the other direction, not in this one.
$(XCTESTCORE_OBJDIR)/XCTTestSelection.o: src/xctestcore/XCTTestSelection.m $(XCTESTCORE_API_HDRS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTTestSelection.m

# The loader is the one XCTestCore unit that reaches for os_log and dispatch, so
# it is also the one whose header dependency is worth naming exactly: it imports
# the loader header, which imports both value headers, so the API list covers it
# without the umbrella being dragged in.
$(XCTESTCORE_OBJDIR)/XCTestConfigurationLoader.o: src/xctestcore/XCTestConfigurationLoader.m $(XCTESTCORE_API_HDRS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTestConfigurationLoader.m

# Depends on the API headers for the same reason as the other two value units,
# and not on $(XCTESTCORE_FW_HEADERS): this one imports the selection header
# directly rather than the umbrella, so naming the umbrella would claim it
# changes when a comment elsewhere does.
$(XCTESTCORE_OBJDIR)/XCTTestRunSession.o: src/xctestcore/XCTTestRunSession.m $(XCTESTCORE_API_HDRS) $(XCTESTCORE_PRIV_HDRS)
	@mkdir -p $(XCTESTCORE_OBJDIR)
	$(CC) $(OBJCFLAGS) -c -o $@ src/xctestcore/XCTTestRunSession.m

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

# The enumeration value types, whose interesting behaviour is entirely in their
# archives and their one string. Two of the checks here exist because the
# reference does something that a round trip cannot observe and a reviewer would
# otherwise read as a bug: -initWithCoder: rejects an all-false options archive,
# and -description leaves its parenthesis unclosed. Both are asserted against
# exact strings.
check-run-session: $(XCTESTCORE_FW_STAMP)
	@FRAMEWORK="$(XCTESTCORE_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-run-session.sh

# Class discovery is the one XCTestCore unit whose answer depends on the whole
# process rather than on its arguments: a test bundle registers its classes
# before the runner ever asks what they are, and nothing in the framework can
# supply that. A harness is the only way to see it work, and the only check that
# exercises libobjc's private _class_isSwift. The rejections are what matter --
# XCTestCase itself, and a key-value-observing subclass -- along with the trap
# that a `_TtGC...` name is accepted when the class is not Swift: a filter that
# got any of them wrong would still produce a plausible test tree.
check-class-discovery: $(XCTEST_FW_STAMP)
	@FRAMEWORK="$(XCTEST_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-class-discovery.sh

# A test's name is derived three ways from one selector, and no single check
# sees all of them: the display name, the language-specific name that keeps the
# trailing signature suffix, and the identifier the selection machinery
# addresses. The harness spells one base method three ways and requires them to
# agree, which is also the check that a rename hook and the identifier cache are
# honoured rather than re-derived on each call.
check-identifier-name: $(XCTEST_FW_STAMP)
	@FRAMEWORK="$(XCTEST_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-identifier-name.sh

# Ordering and removal decide which of two tests runs first and whether a test
# runs at all, so they are checked as decisions rather than as methods: a case
# orders by a case-insensitive method name, a suite by name and after every
# case, and a selection prunes by identifier with the empty-set asymmetry that
# an empty "in set" removes nothing while an empty "without set" removes
# everything. The shuffle is pinned against a fixed generator, because the
# failure that matters is a different Fisher-Yates variant, which still shuffles.
check-ordering: $(XCTEST_FW_STAMP)
	@FRAMEWORK="$(XCTEST_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-ordering.sh

# Reconstructing a suite tree from a flat selection asks two things the rest of
# the port cannot: whether a class customises +defaultTestSuite or
# +testInvocations -- which decides whether the class's own suite is used, its
# invocations are scanned, or an empty suite is built -- and whether a selection
# spelled one way gains the identifiers of the other. Both are answered by
# comparing implementations or by rewriting option bits, so they are checked as
# decisions on real classes rather than as methods.
check-suite-construction: $(XCTESTCORE_FW_STAMP)
	@FRAMEWORK="$(XCTESTCORE_FW_DIR)" SDK="$(SDK)" CC="$(CC)" bash tools/check-suite-construction.sh

# The implementation has to compile on its own terms, and every function the headers
# export has to exist, or a caller only reaches it by luck. check-headers and
# check-macros prove the declarations are well-formed; this proves the definitions
# are there, for both XCTest and XCTestCore. It needs no framework, since it
# compiles from source, and it used to be run by hand only -- which is how a
# dead check survived: its set comparison was a no-op, so it passed for months
# without ever comparing anything.
check-sources:
	@SDK="$(SDK)" CC="$(CC)" bash tools/check-sources.sh

test: check-link smoke check-framework check-expectations check-source-context check-metrics check-configuration check-selection check-builder check-loader check-run-session check-class-discovery check-identifier-name check-ordering check-suite-construction check-sources

# Editor configuration, not build output. Not in `all` and not in `test`: the
# committed src/xctest/.clangd and src/xctestcore/.clangd are already usable,
# and regenerating them is only needed when the SDK above changes. Kept out of
# `all` so a plain build never rewrites a tracked file.
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
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-loader.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-run-session.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTest.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-class-discovery.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTest.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-identifier-name.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTest.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-ordering.sh && \
	FRAMEWORK="build/xcode-$$dir/XCTestCore.framework" SDK="$(SDK)" CC="$(CC)" bash tools/check-suite-construction.sh

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

.PHONY: all check-link smoke check-framework check-expectations check-source-context check-metrics check-configuration check-selection check-builder check-loader check-run-session check-class-discovery check-identifier-name check-ordering check-suite-construction check-sources test clangd-config check-xcode install clean
