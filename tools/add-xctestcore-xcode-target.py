#!/usr/bin/env python3
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
"""Add the XCTestCore.framework native target to the Xcode project.

XCTestCore is a second framework: the private half of a test run, where
XCTest.framework is the public half. The Makefile has built it since the
configuration slice landed, and 'make check-configuration' runs its harness
against that product -- but the Xcode project has no target for it, so the same
source builds through one build system and not the other. The project's rule is
that the two build systems are held to one standard, so the second target goes
here.

This is a one-shot in the same sense as add-xctest-xcode-target.py, and for the
same reason: the project file is committed with the result, so the script exists
to document how the target was generated rather than to be re-run. It refuses to
run if XCTestCore is already present rather than producing a second target. To
regenerate, check out the revision from before the target was added, run this
over it, and commit the result.

The identifiers are minted with an 1A2B3C4E prefix rather than reusing
add-xctest-xcode-target.py's 1A2B3C4D, so that which script minted which object
is readable from the project file alone.

This framework holds every implementation file in the port. XCTest.framework is
the public half: it installs the headers and the umbrella, compiles nothing, and
re-exports this dylib, so a client links -framework XCTest and every public
symbol resolves at run time. SOURCES below is therefore the whole of the project's
implementation membership, and a new .m has to be added here by hand so it also
gets an entry in the Makefile that a reviewer can check it against.

Three things are deliberately absent from SOURCES.

The five private headers -- XCTestInternal.h, XCTestFoundationCompat.h,
XCTestObservationInternal.h, XCTestExpectationInternal.h, and
XCTestAssertionFormats.h -- are not Headers build phase members. They are not
installed, so putting them in the phase would put them in the product, and they
were not project members before the move either. HEADER_SEARCH_PATHS already
reaches them at src/xctestcore, which is how every .m in the target imports them.

XCTest.framework is not named in this target's Frameworks phase. The dependency
runs the other way: the other target links this one. Adding it here would make
the private framework depend on the public one and invert Apple's arrangement.

The Foundation.framework file reference is reused rather than minted again, for
the reason given below.

This script also wires XCTest to depend on XCTestCore, which is the one thing it
does that is not about its own target. It has to: add-xctest-xcode-target.py runs
first, and at that point XCTestCore's file reference does not exist, so the other
script has nothing to point a PBXTargetDependency at. Without the dependency
xcodebuild would link XCTest against an XCTestCore that had not been built yet,
and with a shared CONFIGURATION_BUILD_DIR the result is either a hard failure or
-- worse -- a silent link against the previous run's product.

The target gets its own OBJROOT but shares CONFIGURATION_BUILD_DIR with XCTest.
Two products with different names in one directory is ordinary Xcode output and is
what 'make check-xcode' wants, since it looks for both frameworks side by side.
OBJROOT is not shared because it is where xcodebuild keeps a per-target build
database, and two targets sharing one would have to be trusted never to collide.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "XCTest.xcodeproj", "project.pbxproj")

with open(PBX) as f:
    text = f.read()

if "XCTestCore.framework" in text:
    sys.exit("XCTestCore target already present; refusing to double-add")
if "com.apple.product-type.framework" not in text:
    sys.exit("XCTest framework target missing; run add-xctest-xcode-target.py first")

# ---------------------------------------------------------------- identifiers
PRODUCT_REF = "1A2B3C4E0000000000000090"
MODULEMAP_REF = "1A2B3C4E0000000000000091"
PLIST_REF = "1A2B3C4E0000000000000092"
XCTESTCORE_GROUP = "1A2B3C4E0000000000000094"
INCLUDE_GROUP = "1A2B3C4E0000000000000095"
UMBRELLA_GROUP = "1A2B3C4E0000000000000096"

HEADERS_PHASE = "1A2B3C4E00000000000000A0"
SOURCES_PHASE = "1A2B3C4E00000000000000A1"
FRAMEWORKS_PHASE = "1A2B3C4E00000000000000A2"
RESOURCES_PHASE = "1A2B3C4E00000000000000A3"

DEBUG_CONFIG = "1A2B3C4E00000000000000B0"
RELEASE_CONFIG = "1A2B3C4E00000000000000B1"
CONFIG_LIST = "1A2B3C4E00000000000000B2"
TARGET = "1A2B3C4E00000000000000B3"

# Info.plist and module.modulemap are deliberately NOT build-file members of any
# phase, for the reason given in add-xctest-xcode-target.py: INFOPLIST_FILE and
# MODULEMAP_FILE already make the build system process them, and listing them twice
# makes it emit two commands for one output.

# Every implementation file in the port. XCTestConfiguration.m and
# XCTTestSelection.m keep the identifiers minted when this target was first
# added; the 17 that arrived with the move take refs 0x100-0x110 and build files
# 0x120-0x130, clear of the ranges already in use. The order is the Makefile's
# link order, so the two build systems list the same objects in the same sequence
# and a reviewer can diff the two lists line for line.
SOURCES = [
    ("XCTestConfiguration.m", "1A2B3C4E0000000000000075", "1A2B3C4E0000000000000081"),
    ("XCTTestSelection.m", "1A2B3C4E0000000000000076", "1A2B3C4E0000000000000082"),
    ("XCTest.m", "1A2B3C4E0000000000000100", "1A2B3C4E0000000000000120"),
    ("XCTestSuite.m", "1A2B3C4E0000000000000101", "1A2B3C4E0000000000000121"),
    ("XCTestCase.m", "1A2B3C4E0000000000000102", "1A2B3C4E0000000000000122"),
    ("XCTestRun.m", "1A2B3C4E0000000000000103", "1A2B3C4E0000000000000123"),
    ("XCTestObservation.m", "1A2B3C4E0000000000000104", "1A2B3C4E0000000000000124"),
    ("XCTestAssertions.m", "1A2B3C4E0000000000000105", "1A2B3C4E0000000000000125"),
    ("XCTestInternal.m", "1A2B3C4E0000000000000106", "1A2B3C4E0000000000000126"),
    ("XCTestSupportTypes.m", "1A2B3C4E0000000000000107", "1A2B3C4E0000000000000127"),
    ("XCTestMetrics.m", "1A2B3C4E0000000000000108", "1A2B3C4E0000000000000128"),
    ("XCTestExpectation.m", "1A2B3C4E0000000000000109", "1A2B3C4E0000000000000129"),
    ("XCTWaiter.m", "1A2B3C4E000000000000010A", "1A2B3C4E000000000000012A"),
    ("XCTNSNotificationExpectation.m", "1A2B3C4E000000000000010B", "1A2B3C4E000000000000012B"),
    ("XCTNSPredicateExpectation.m", "1A2B3C4E000000000000010C", "1A2B3C4E000000000000012C"),
    ("XCTKVOExpectation.m", "1A2B3C4E000000000000010D", "1A2B3C4E000000000000012D"),
    ("XCTDarwinNotificationExpectation.m", "1A2B3C4E000000000000010E", "1A2B3C4E000000000000012E"),
    ("XCTExpectedFailure.m", "1A2B3C4E000000000000010F", "1A2B3C4E000000000000012F"),
    ("XCTestConfigurationLoader.m", "1A2B3C4E0000000000000110", "1A2B3C4E0000000000000130"),
]

# The loader's header is here because the Makefile installs it and the project is
# held to the Makefile's install set; it was missing from the project until this
# regeneration, so a header count check against the Makefile would have caught it.
#
# All four are Public: this is a private framework, so "public" here means
# reachable from inside the module rather than from outside it. The order is the
# one the generated project lists them in -- value headers, then the umbrella
# that imports them. Header install order carries no meaning to a compiler, so
# it is kept in step with the project rather than chosen on aesthetics.
HEADERS = [
    "XCTestConfiguration.h",
    "XCTestConfigurationLoader.h",
    "XCTTestSelection.h",
    "XCTestCore.h",
]
header_refs = [
    "1A2B3C4E00000000000000C0",
    "1A2B3C4E00000000000000C1",
    "1A2B3C4E00000000000000C2",
    "1A2B3C4E00000000000000C3",
]
header_buildfiles = [
    "1A2B3C4E00000000000000E0",
    "1A2B3C4E00000000000000E1",
    "1A2B3C4E00000000000000E2",
    "1A2B3C4E00000000000000E3",
]

# XCTest.framework is linked here, not from the other direction. The Frameworks
# phase is where a framework is supposed to be named, and the entry is what gets
# the search path and the -framework flag; the reexport flag itself is a string in
# the other target's OTHER_LDFLAGS, added by add-xctest-xcode-target.py, which ran
# before this reference existed.
XCTESTCORE_BF = "1A2B3C4E00000000000000F3"
# The Foundation build file in the *XCTest* target, which is the anchor this
# script's insertion hangs off. It is a different object from FOUNDATION_BF above:
# a PBXBuildFile belongs to exactly one phase, so two targets linking Foundation
# need two of them, and they are not interchangeable.
XCTEST_FOUNDATION_BF = "1A2B3C4D00000000000000F2"
XCTEST_FRAMEWORKS_PHASE = "1A2B3C4D00000000000000A2"
XCTEST_TARGET = "1A2B3C4D00000000000000B3"
DEPENDENCY = "1A2B3C4E00000000000000D0"
CONTAINER_PROXY = "1A2B3C4E00000000000000D1"

# The project object, for the container proxy. It is the one identifier in this
# file that is neither minted nor reused by name, so it is looked up rather than
# assumed.
PROJECT_OBJECT = re.search(r"^\t\t([0-9A-F]{24}) /\* Project object \*/ = \{$", text, re.M).group(1)

# The Foundation.framework file reference already exists from the XCTest target and
# is reused: two references for one SDK framework would be a second object with a
# second path, and the first script already documented that a dangling or duplicate
# reference is dropped silently rather than diagnosed. The *build file* has to be
# new, because a PBXBuildFile belongs to exactly one phase.
FOUNDATION_REF = "1A2B3C4D0000000000000093"
FOUNDATION_BF = "1A2B3C4E00000000000000F2"

if not re.search(r"%s /\* Foundation\.framework \*/ = \{isa = PBXFileReference;" % FOUNDATION_REF, text):
    sys.exit("expected to reuse the XCTest target's Foundation.framework reference")


def section(name):
    return "/* Begin %s section */" % name, "/* End %s section */" % name


def insert_in_section(text, name, body):
    begin, end = section(name)
    if begin not in text or end not in text:
        sys.exit("missing %s section" % name)
    i = text.index(begin) + len(begin)
    j = text.index(end)
    return text[:i] + "\n" + body + text[i:j] + text[j:]


# ------------------------------------------------------------ PBXBuildFile
buildfiles = []
for name, ref, bf in SOURCES:
    buildfiles.append(
        "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
        % (bf, name, ref, name)
    )
for name, ref, bf in zip(HEADERS, header_refs, header_buildfiles):
    buildfiles.append(
        "\t\t%s /* %s in Headers */ = {isa = PBXBuildFile; fileRef = %s /* %s */; "
        "settings = {ATTRIBUTES = (Public, ); }; };" % (bf, name, ref, name)
    )
buildfiles.append(
    "\t\t%s /* Foundation.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* Foundation.framework */; };"
    % (FOUNDATION_BF, FOUNDATION_REF)
)
buildfiles.append(
    "\t\t%s /* XCTestCore.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* XCTestCore.framework */; };"
    % (XCTESTCORE_BF, PRODUCT_REF)
)
text = insert_in_section(text, "PBXBuildFile", "\n".join(buildfiles))

# --------------------------------------------------------- PBXFileReference
refs = [
    "\t\t%s /* XCTestCore.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; "
    "includeInIndex = 0; path = XCTestCore.framework; sourceTree = BUILT_PRODUCTS_DIR; };" % PRODUCT_REF,
    "\t\t%s /* module.modulemap */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.module-map; "
    "path = module.modulemap; sourceTree = \"<group>\"; };" % MODULEMAP_REF,
    "\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
    "path = Info.plist; sourceTree = \"<group>\"; };" % PLIST_REF,
]
for name, ref, _ in SOURCES:
    refs.append(
        "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; "
        "path = %s; sourceTree = \"<group>\"; };" % (ref, name, name)
    )
for name, ref in zip(HEADERS, header_refs):
    refs.append(
        "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; "
        "path = %s; sourceTree = \"<group>\"; };" % (ref, name, name)
    )
text = insert_in_section(text, "PBXFileReference", "\n".join(refs))

# A dangling reference is dropped silently by xcodebuild rather than reported, so
# the target would build with no sources and the smoke test would still pass. Check
# the invariant that the build log does not show.
for name, ref, bf in SOURCES:
    if not re.search(r"%s /\* %s \*/ = \{isa = PBXFileReference;" % (re.escape(ref), re.escape(name)), text):
        sys.exit("%s: file reference %s was not emitted" % (name, ref))
    if "fileRef = %s /* %s */" % (ref, name) not in text:
        sys.exit("%s: build file %s does not point at its reference" % (name, bf))
for name, ref, bf in zip(HEADERS, header_refs, header_buildfiles):
    if "fileRef = %s /* %s */" % (ref, name) not in text:
        sys.exit("%s: header build file %s does not point at its reference" % (name, bf))

# --------------------------------------------------------------- new phases
def phase(ident, isa, files):
    return """
\t\t%s /* %s */ = {
\t\t\tisa = %s;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
%s
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};""" % (
        ident,
        isa.split("BuildPhase")[0],
        isa,
        "\n".join("\t\t\t\t%s /* %s */," % (bf, label) for bf, label in files),
    )


headers_phase = phase(
    HEADERS_PHASE,
    "PBXHeadersBuildPhase",
    [(bf, "%s in Headers" % n) for n, bf in zip(HEADERS, header_buildfiles)],
)
sources_phase = phase(
    SOURCES_PHASE,
    "PBXSourcesBuildPhase",
    [(bf, "%s in Sources" % n) for n, _, bf in SOURCES],
)
frameworks_phase = phase(
    FRAMEWORKS_PHASE,
    "PBXFrameworksBuildPhase",
    [(FOUNDATION_BF, "Foundation.framework in Frameworks")],
)
# Deliberately empty, for the reason in add-xctest-xcode-target.py.
resources_phase = phase(RESOURCES_PHASE, "PBXResourcesBuildPhase", [])

# XCTestCore.framework joins the *other* target's Frameworks phase. The phase
# object already exists -- add-xctest-xcode-target.py created it -- so this is an
# insertion into its file list rather than a new phase. The anchor is the one entry
# that script always writes there, which makes the insertion exact.
xctest_frameworks_anchor = "\t\t\t\t%s /* Foundation.framework in Frameworks */," % XCTEST_FOUNDATION_BF
if text.count(xctest_frameworks_anchor) != 1:
    sys.exit("expected one Foundation entry in the XCTest Frameworks phase, found %d"
             % text.count(xctest_frameworks_anchor))
text = text.replace(
    xctest_frameworks_anchor,
    xctest_frameworks_anchor + "\n\t\t\t\t%s /* XCTestCore.framework in Frameworks */," % XCTESTCORE_BF,
    1,
)

# These four sections already exist -- the XCTest target created them -- so they are
# inserted into rather than created. The order the sections appear in the file is
# Xcode's, not this script's, and inserting does not move anything.
text = insert_in_section(text, "PBXHeadersBuildPhase", headers_phase)
text = insert_in_section(text, "PBXFrameworksBuildPhase", frameworks_phase)
text = insert_in_section(text, "PBXSourcesBuildPhase", sources_phase)
text = insert_in_section(text, "PBXResourcesBuildPhase", resources_phase)

# ------------------------------------------------------------ build settings
# Mirrors the Makefile: ARC + exceptions + blocks, no Apple XCTest, the same include
# roots, and the same bundle identifier the installed Info.plist declares, so the two
# build systems cannot drift on metadata without it being visible in review.
common = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_EXCEPTIONS = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEFINES_MODULE = YES;
\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;
\t\t\t\tDYLIB_CURRENT_VERSION = 1;
\t\t\t\tDYLIB_INSTALL_NAME_BASE = "@rpath";
\t\t\t\tFRAMEWORK_VERSION = A;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = c11;
\t\t\t\tHEADER_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(SRCROOT)/src/xctestcore",
\t\t\t\t\t"$(SRCROOT)/src/xctestcore/include",
\t\t\t\t);
\t\t\t\tINFOPLIST_FILE = "$(SRCROOT)/src/xctestcore/Info.plist";
\t\t\t\tINSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;
\t\t\t\tMODULEMAP_FILE = "$(SRCROOT)/src/xctestcore/module.modulemap";
\t\t\t\tOTHER_CFLAGS = (
\t\t\t\t\t-Wall,
\t\t\t\t\t-Wextra,
\t\t\t\t);
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.apple.dt.xctestcore";
\t\t\t\tPRODUCT_NAME = XCTestCore;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tVERSIONING_SYSTEM = "apple-generic";
\t\t\t\tVERSION_INFO_PREFIX = "";"""

# CONFIGURATION_BUILD_DIR is shared with the XCTest target on purpose: two products
# with different names in one directory is ordinary, and it is what 'make
# check-xcode' reads both frameworks from. OBJROOT is not shared, because it is
# where xcodebuild keeps its build database and that is per target.
debug_paths = (
    "\t\t\t\tCONFIGURATION_BUILD_DIR = \"$(SRCROOT)/build/xcode-debug\";\n"
    "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n"
    "\t\t\t\tOBJROOT = \"$(SRCROOT)/build/xcode-obj/debug-xctestcore\";\n"
    "\t\t\t\tONLY_ACTIVE_ARCH = YES;\n"
)
release_paths = (
    "\t\t\t\tCONFIGURATION_BUILD_DIR = \"$(SRCROOT)/build/xcode-release\";\n"
    "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 3;\n"
    "\t\t\t\tOBJROOT = \"$(SRCROOT)/build/xcode-obj/release-xctestcore\";\n"
)

configs = (
    "\t\t%s /* Debug */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n%s\n"
    "\t\t};\n"
    "\t\t\tname = Debug;\n"
    "\t\t};\n"
    "\t\t%s /* Release */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n%s\n"
    "\t\t};\n"
    "\t\t\tname = Release;\n"
    "\t\t};"
) % (DEBUG_CONFIG, common + "\n" + debug_paths, RELEASE_CONFIG, common + "\n" + release_paths)

config_lists = """
\t\t%s /* Build configuration list for PBXNativeTarget "XCTestCore" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t%s /* Debug */,
\t\t\t\t%s /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};""" % (CONFIG_LIST, DEBUG_CONFIG, RELEASE_CONFIG)

target = """
\t\t%s /* XCTestCore */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "XCTestCore" */;
\t\t\tbuildPhases = (
\t\t\t\t%s /* Headers */,
\t\t\t\t%s /* Sources */,
\t\t\t\t%s /* Frameworks */,
\t\t\t\t%s /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = XCTestCore;
\t\t\tproductName = XCTestCore;
\t\t\tproductReference = %s /* XCTestCore.framework */;
\t\t\tproductType = "com.apple.product-type.framework";
\t\t};""" % (TARGET, CONFIG_LIST, HEADERS_PHASE, SOURCES_PHASE, FRAMEWORKS_PHASE, RESOURCES_PHASE, PRODUCT_REF)

text = insert_in_section(text, "PBXNativeTarget", target)
text = insert_in_section(text, "XCConfigurationList", config_lists)
text = insert_in_section(text, "XCBuildConfiguration", configs)

# ------------------------------------------------- XCTest depends on XCTestCore
# A PBXTargetDependency on its own is not enough: it names a proxy, and the proxy
# is what says which target and which product, so all three objects have to be
# written. remoteGlobalIDString is the dependency's target, and the proxy's
# containerPortal is the project, which is this file.
container_proxy = """
\t\t%s /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = %s /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = %s;
\t\t\tremoteInfo = XCTestCore;
\t\t};""" % (CONTAINER_PROXY, PROJECT_OBJECT, TARGET)

dependency = """
\t\t%s /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = %s /* XCTestCore */;
\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;
\t\t};""" % (DEPENDENCY, TARGET, CONTAINER_PROXY)

text = insert_in_section(text, "PBXContainerItemProxy", container_proxy)
text = insert_in_section(text, "PBXTargetDependency", dependency)

# The XCTest target's dependencies list is written by the other script, so the
# entry goes in by replacing its empty list. An empty list is a two-line shape and
# the anchor names the target it belongs to, so the match is exact.
xctest_dependency_anchor = (
    "\t\t\tdependencies = (\n\t\t\t);\n"
    "\t\t\tname = XCTest;\n"
)
if text.count(xctest_dependency_anchor) != 1:
    sys.exit("expected one empty dependencies list on the XCTest target, found %d"
             % text.count(xctest_dependency_anchor))
text = text.replace(
    xctest_dependency_anchor,
    "\t\t\tdependencies = (\n\t\t\t\t%s /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = XCTest;\n" % DEPENDENCY,
    1,
)

# ------------------------------------------------------------------ groups
groups = """
\t\t%s /* xctestcore */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
%s
\t\t\t\t%s /* include */,
\t\t\t\t%s /* module.modulemap */,
\t\t\t\t%s /* Info.plist */,
\t\t\t);
\t\t\tpath = xctestcore;
\t\t\tsourceTree = "<group>";
\t\t};
\t\t%s /* include */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t%s /* XCTestCore */,
\t\t\t);
\t\t\tpath = include;
\t\t\tsourceTree = "<group>";
\t\t};
\t\t%s /* XCTestCore */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
%s
\t\t\t);
\t\t\tpath = XCTestCore;
\t\t\tsourceTree = "<group>";
\t\t};""" % (
    XCTESTCORE_GROUP,
    "\n".join("\t\t\t\t%s /* %s */," % (s[1], s[0]) for s in SOURCES),
    INCLUDE_GROUP,
    MODULEMAP_REF,
    PLIST_REF,
    INCLUDE_GROUP,
    UMBRELLA_GROUP,
    UMBRELLA_GROUP,
    "\n".join("\t\t\t\t%s /* %s */," % (ref, n) for n, ref in zip(HEADERS, header_refs)),
)
text = insert_in_section(text, "PBXGroup", groups)

# Hook the group, the product and the target into the existing tree, each next to
# the XCTest one so the two frameworks are adjacent in the navigator and the
# Products group.
for anchor, addition, what in [
    ("\t\t\t\t1A2B3C4D0000000000000094 /* xctest */,\n", "%s /* xctestcore */,\n" % XCTESTCORE_GROUP, "main group"),
    ("\t\t\t\t1A2B3C4D0000000000000090 /* XCTest.framework */,\n", "%s /* XCTestCore.framework */,\n" % PRODUCT_REF, "Products group"),
    ("\t\t\t\t1A2B3C4D00000000000000B3 /* XCTest */,\n", "%s /* XCTestCore */,\n" % TARGET, "targets list"),
]:
    if text.count(anchor) != 1:
        sys.exit("expected exactly one %s anchor, found %d" % (what, text.count(anchor)))
    text = text.replace(anchor, anchor + "\t\t\t\t" + addition, 1)

# A reference that nothing reaches is dropped by xcodebuild rather than reported, so
# an unhooked object is invisible until something depends on it missing. Every
# identifier this script mints has to appear at least twice: once defined, once
# referenced.
for required, what in [
    (PRODUCT_REF, "product reference"),
    (MODULEMAP_REF, "modulemap reference"),
    (PLIST_REF, "plist reference"),
    (HEADERS_PHASE, "headers phase"),
    (SOURCES_PHASE, "sources phase"),
    (FRAMEWORKS_PHASE, "frameworks phase"),
    (RESOURCES_PHASE, "resources phase"),
    (TARGET, "native target"),
    (CONFIG_LIST, "configuration list"),
    (DEBUG_CONFIG, "debug configuration"),
    (RELEASE_CONFIG, "release configuration"),
    (XCTESTCORE_GROUP, "xctestcore group"),
    (INCLUDE_GROUP, "include group"),
    (UMBRELLA_GROUP, "umbrella group"),
    (FOUNDATION_BF, "Foundation build file"),
    (XCTESTCORE_BF, "XCTestCore build file"),
    (DEPENDENCY, "target dependency"),
    (CONTAINER_PROXY, "container proxy"),
] + [(r, "source %s" % s[0]) for s in SOURCES for r in (s[1], s[2])] + [
    (r, "header %s" % n) for n, r in zip(HEADERS, header_refs + header_buildfiles)
]:
    if text.count(required) < 2:
        sys.exit("dangling %s (%s): defined but never referenced" % (what, required))

# The dependency is the one wiring here that xcodebuild tolerates silently getting
# wrong: without it the link still resolves when a previous XCTestCore is sitting
# in the shared CONFIGURATION_BUILD_DIR, so the smoke test passes against a stale
# binary. Check that all three halves landed, each within the object it belongs to
# rather than anywhere in the file -- the project already has container proxies for
# its other targets, so an unscoped "containerPortal" search finds three of those
# plus this one.
for required, what in [
    ("%s /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n"
     "\t\t\tcontainerPortal = %s /* Project object */;" % (CONTAINER_PROXY, PROJECT_OBJECT),
     "proxy's container"),
    ("target = %s /* XCTestCore */;\n\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;"
     % (TARGET, CONTAINER_PROXY), "dependency's target and proxy"),
    ("remoteGlobalIDString = %s;\n\t\t\tremoteInfo = XCTestCore;" % TARGET, "proxy's remote target"),
    ("-Wl,-reexport_framework,XCTestCore", "XCTest reexport flag"),
]:
    found = text.count(required)
    if found != 1 and not (what == "XCTest reexport flag" and found == 2):
        sys.exit("expected one %s, found %d" % (what, found))

with open(PBX, "w") as f:
    f.write(text)

print("added XCTestCore framework target: %s" % TARGET)
print("  %d sources, %d public headers" % (len(SOURCES), len(HEADERS)))
print("  XCTest now depends on XCTestCore via %s" % DEPENDENCY)
