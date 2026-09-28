#!/usr/bin/env python3
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
"""Add a real XCTest.framework native target to the Xcode project.

The 11 source file references and 11 Sources build files added in 0a9c5b0 are
orphans: nothing in the project lists them. This adds the missing half --
product reference, header/resource references, the four build phases, build
configurations, the target itself, and the group tree that makes it visible.

The four specialized expectations came after that, so the target this script
generates has 15 sources and 29 public headers rather than 11 and 25. SOURCES
and HEADERS above are the single place either list is written down: a new
public expectation header is picked up automatically, and a new implementation
has to be added to SOURCES by hand so it also gets an entry in the Makefile
that a reviewer can check it against.

This is a one-shot: the project file is committed with the result, so the script
exists to document how the target was generated rather than to be re-run. It
refuses to run again once a framework target is present rather than producing a
second one. To regenerate after editing SOURCES or HEADERS, check out the
revision of project.pbxproj from before the target was added, run this over it,
and commit the result -- a plain re-run would append a duplicate set of build
files.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "XCTest.xcodeproj", "project.pbxproj")

with open(PBX) as f:
    text = f.read()

if "com.apple.product-type.framework" in text:
    sys.exit("framework target already present; refusing to double-add")

# ---------------------------------------------------------------- identifiers
# 0x100+ is free: 0xF2 (the Foundation build file) is the highest currently used.
PRODUCT_REF = "1A2B3C4D0000000000000090"
MODULEMAP_REF = "1A2B3C4D0000000000000091"
PLIST_REF = "1A2B3C4D0000000000000092"
FOUNDATION_REF = "1A2B3C4D0000000000000093"
XCTEST_GROUP = "1A2B3C4D0000000000000094"
INCLUDE_GROUP = "1A2B3C4D0000000000000095"
UMBRELLA_GROUP = "1A2B3C4D0000000000000096"

HEADERS_PHASE = "1A2B3C4D00000000000000A0"
SOURCES_PHASE = "1A2B3C4D00000000000000A1"
FRAMEWORKS_PHASE = "1A2B3C4D00000000000000A2"
RESOURCES_PHASE = "1A2B3C4D00000000000000A3"

DEBUG_CONFIG = "1A2B3C4D00000000000000B0"
RELEASE_CONFIG = "1A2B3C4D00000000000000B1"
CONFIG_LIST = "1A2B3C4D00000000000000B2"
TARGET = "1A2B3C4D00000000000000B3"

# Info.plist and module.modulemap are deliberately NOT build-file members of any
# phase. INFOPLIST_FILE and MODULEMAP_FILE already make the build system process
# them, and adding them to Resources/Sources as well makes it emit two commands
# for one output ("multiple commands produce .../Info.plist") or, for the
# modulemap, no rule at all.

# Sources already have file refs (0x75-0x7F) and build files (0x81-0x8B) from
# 0a9c5b0. Reuse them rather than minting a second set. The four expectations
# added later have no such pair, so they mint theirs above the ranges already
# in use: refs 0x100-0x103, build files 0x110-0x113. Keeping them out of
# 0x75-0x7F/0x81-0x8B is what lets the rewrite below stay exact.
SOURCES = [
    ("XCTest.m", "1A2B3C4D0000000000000075", "1A2B3C4D0000000000000081"),
    ("XCTestSuite.m", "1A2B3C4D0000000000000076", "1A2B3C4D0000000000000082"),
    ("XCTestCase.m", "1A2B3C4D0000000000000077", "1A2B3C4D0000000000000083"),
    ("XCTestRun.m", "1A2B3C4D0000000000000078", "1A2B3C4D0000000000000084"),
    ("XCTestObservation.m", "1A2B3C4D0000000000000079", "1A2B3C4D0000000000000085"),
    ("XCTestAssertions.m", "1A2B3C4D000000000000007A", "1A2B3C4D0000000000000086"),
    ("XCTestInternal.m", "1A2B3C4D000000000000007B", "1A2B3C4D0000000000000087"),
    ("XCTestSupportTypes.m", "1A2B3C4D000000000000007C", "1A2B3C4D0000000000000088"),
    ("XCTestExpectation.m", "1A2B3C4D000000000000007D", "1A2B3C4D0000000000000089"),
    ("XCTWaiter.m", "1A2B3C4D000000000000007E", "1A2B3C4D000000000000008A"),
    ("XCTExpectedFailure.m", "1A2B3C4D000000000000007F", "1A2B3C4D000000000000008B"),
    ("XCTNSNotificationExpectation.m", "1A2B3C4D0000000000000100", "1A2B3C4D0000000000000110"),
    ("XCTNSPredicateExpectation.m", "1A2B3C4D0000000000000101", "1A2B3C4D0000000000000111"),
    ("XCTKVOExpectation.m", "1A2B3C4D0000000000000102", "1A2B3C4D0000000000000112"),
    ("XCTDarwinNotificationExpectation.m", "1A2B3C4D0000000000000103", "1A2B3C4D0000000000000113"),
]

public_dir = os.path.join(ROOT, "src", "xctest", "include", "XCTest")
HEADERS = sorted(f for f in os.listdir(public_dir) if f.endswith(".h"))
if len(HEADERS) != 29:
    sys.exit("expected 29 public headers, found %d" % len(HEADERS))

# Header refs 0xC0.., header build files 0xE0.., so both stay readable in the file.
header_refs, header_buildfiles = [], []
for i, name in enumerate(HEADERS):
    header_refs.append("1A2B3C4D00000000000000C%02X" % i)
    header_buildfiles.append("1A2B3C4D00000000000000E%02X" % i)

FOUNDATION_BF = "1A2B3C4D00000000000000F2"


def section(name):
    return "/* Begin %s section */" % name, "/* End %s section */" % name


def insert_in_section(text, name, body):
    begin, end = section(name)
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

# The 11 pre-existing Sources build files have no name comment on their fileRef.
# Rewrite them in place so the section reads consistently, then append the rest.
old_source_bf = re.findall(
    r"^\t\t1A2B3C4D000000000000008[1-9AB] /\* .*? in Sources \*/ = \{isa = PBXBuildFile; fileRef = 1A2B3C4D000000000000007[5-9ABCDEF]; \};$",
    text,
    re.M,
)
if len(old_source_bf) != 11:
    sys.exit("expected 11 pre-existing Sources build files, found %d" % len(old_source_bf))
for line in old_source_bf:
    text = text.replace(line + "\n", "")

text = insert_in_section(text, "PBXBuildFile", "\n".join(buildfiles))

# --------------------------------------------------------- PBXFileReference
refs = [
    "\t\t%s /* XCTest.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; "
    "includeInIndex = 0; path = XCTest.framework; sourceTree = BUILT_PRODUCTS_DIR; };" % PRODUCT_REF,
    "\t\t%s /* module.modulemap */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.module-map; "
    "path = module.modulemap; sourceTree = \"<group>\"; };" % MODULEMAP_REF,
    "\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
    "path = Info.plist; sourceTree = \"<group>\"; };" % PLIST_REF,
    "\t\t%s /* Foundation.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; "
    "name = Foundation.framework; path = System/Library/Frameworks/Foundation.framework; sourceTree = SDKROOT; };"
    % FOUNDATION_REF,
]
for name, ref in zip(HEADERS, header_refs):
    refs.append(
        "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; "
        "path = %s; sourceTree = \"<group>\"; };" % (ref, name, name)
    )

# A source file reference is needed for every entry in SOURCES, and 0a9c5b0 only
# left 11 of them behind. Emitting a build file and a group child for a reference
# that does not exist produces a project that still builds -- xcodebuild drops the
# unknown reference instead of complaining, so the target simply compiles 11
# sources and every other check passes -- which is why the four expectations were
# missing from the Xcode binary while the Makefile's copy was complete. Emit the
# ones that are missing rather than trusting the list to be a subset of the file.
existing_refs = set(re.findall(r"\t\t(1A2B3C4D[0-9A-F]{16}) /\* .*? \*/ = \{isa = PBXFileReference;", text))
for name, ref, _ in SOURCES:
    if ref in existing_refs:
        continue
    refs.append(
        "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; "
        "path = %s; sourceTree = \"<group>\"; };" % (ref, name, name)
    )
text = insert_in_section(text, "PBXFileReference", "\n".join(refs))

# Now that every reference exists, a dangling fileRef would still be silently
# dropped rather than diagnosed, so check the one invariant that is not visible
# from the build log: each source's build file must resolve to a real reference.
for name, ref, bf in SOURCES:
    if not re.search(r"%s /\* %s \*/ = \{isa = PBXFileReference;" % (re.escape(ref), re.escape(name)), text):
        sys.exit("%s: file reference %s was not emitted" % (name, ref))
    if "fileRef = %s /* %s */" % (ref, name) not in text:
        sys.exit("%s: build file %s does not point at its reference" % (name, bf))

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
# Deliberately empty: the framework has no loose resources. Info.plist and the
# modulemap are handled by INFOPLIST_FILE and MODULEMAP_FILE, not copied here.
resources_phase = phase(RESOURCES_PHASE, "PBXResourcesBuildPhase", [])

# Headers and Resources have no section yet, so create them. Xcode expects
# Headers first in the file, Resources last among the build phases.
text = insert_in_section(text, "PBXFrameworksBuildPhase", frameworks_phase)
text = insert_in_section(text, "PBXSourcesBuildPhase", sources_phase)

frameworks_anchor = section("PBXFrameworksBuildPhase")[0]
text = text.replace(
    frameworks_anchor,
    section("PBXHeadersBuildPhase")[0] + headers_phase + section("PBXHeadersBuildPhase")[1] + "\n\n" + frameworks_anchor,
    1,
)
resources_anchor = section("PBXSourcesBuildPhase")[1]
text = text.replace(
    resources_anchor,
    resources_anchor + "\n\n" + section("PBXResourcesBuildPhase")[0] + resources_phase + section("PBXResourcesBuildPhase")[1],
    1,
)

# ------------------------------------------------------------ build settings
# Mirrors the Makefile: ARC + exceptions + blocks, no Apple XCTest, and the
# same include roots. INFOPLIST_FILE and MODULEMAP_FILE point at the same files
# the Makefile installs, so the two build systems cannot drift on bundle
# metadata without it being visible in review.
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
\t\t\t\t\t"$(SRCROOT)/src/xctest",
\t\t\t\t\t"$(SRCROOT)/src/xctest/include",
\t\t\t\t);
\t\t\t\tINFOPLIST_FILE = "$(SRCROOT)/src/xctest/Info.plist";
\t\t\t\tINSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;
\t\t\t\tMODULEMAP_FILE = "$(SRCROOT)/src/xctest/module.modulemap";
\t\t\t\tOTHER_CFLAGS = (
\t\t\t\t\t-Wall,
\t\t\t\t\t-Wextra,
\t\t\t\t);
				PRODUCT_BUNDLE_IDENTIFIER = "com.apple.dt.xctest";
				PRODUCT_NAME = XCTest;
				SKIP_INSTALL = YES;
\t\t\t\tVERSIONING_SYSTEM = "apple-generic";
\t\t\t\tVERSION_INFO_PREFIX = "";"""

configs = (
    "\t\t%s /* Debug */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n%s\n"
    "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n"
    "\t\t\t\tONLY_ACTIVE_ARCH = YES;\n"
    "\t\t\t};\n"
    "\t\t\tname = Debug;\n"
    "\t\t};\n"
    "\t\t%s /* Release */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n%s\n"
    "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 3;\n"
    "\t\t\t};\n"
    "\t\t\tname = Release;\n"
    "\t\t};"
) % (DEBUG_CONFIG, common, RELEASE_CONFIG, common)

config_lists = """
\t\t%s /* Build configuration list for PBXNativeTarget "XCTest" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t%s /* Debug */,
\t\t\t\t%s /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};""" % (CONFIG_LIST, DEBUG_CONFIG, RELEASE_CONFIG)

target = """
\t\t%s /* XCTest */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "XCTest" */;
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
\t\t\tname = XCTest;
\t\t\tproductName = XCTest;
\t\t\tproductReference = %s /* XCTest.framework */;
\t\t\tproductType = "com.apple.product-type.framework";
\t\t};""" % (TARGET, CONFIG_LIST, HEADERS_PHASE, SOURCES_PHASE, FRAMEWORKS_PHASE, RESOURCES_PHASE, PRODUCT_REF)

text = insert_in_section(text, "PBXNativeTarget", target)
text = insert_in_section(text, "XCConfigurationList", config_lists)
text = insert_in_section(text, "XCBuildConfiguration", configs)

# ------------------------------------------------------------------ groups
groups = """
\t\t%s /* xctest */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
%s
\t\t\t\t%s /* include */,
\t\t\t\t%s /* module.modulemap */,
\t\t\t\t%s /* Info.plist */,
\t\t\t);
\t\t\tpath = xctest;
\t\t\tsourceTree = "<group>";
\t\t};
\t\t%s /* include */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t%s /* XCTest */,
\t\t\t);
\t\t\tpath = include;
\t\t\tsourceTree = "<group>";
\t\t};
\t\t%s /* XCTest */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
%s
\t\t\t);
\t\t\tpath = XCTest;
\t\t\tsourceTree = "<group>";
\t\t};""" % (
    XCTEST_GROUP,
    "\n".join("\t\t\t\t%s /* %s */," % (ref, n) for n, ref in zip([s[0] for s in SOURCES], [s[1] for s in SOURCES])),
    INCLUDE_GROUP,
    MODULEMAP_REF,
    PLIST_REF,
    INCLUDE_GROUP,
    UMBRELLA_GROUP,
    UMBRELLA_GROUP,
    "\n".join("\t\t\t\t%s /* %s */," % (ref, n) for n, ref in zip(HEADERS, header_refs)),
)
text = insert_in_section(text, "PBXGroup", groups)

# Hook the new group and product into the existing tree.
text = text.replace(
    "\t\t\t\t1A2B3C4D0000000000000016 /* zstd */,\n",
    "\t\t\t\t1A2B3C4D0000000000000016 /* zstd */,\n\t\t\t\t%s /* xctest */,\n" % XCTEST_GROUP,
    1,
)
text = text.replace(
    "\t\t\t\t1A2B3C4D0000000000000044 /* libzstd.a */,\n",
    "\t\t\t\t1A2B3C4D0000000000000044 /* libzstd.a */,\n\t\t\t\t%s /* XCTest.framework */,\n" % PRODUCT_REF,
    1,
)
text = text.replace(
    "\t\t\t\t1A2B3C4D0000000000000054 /* libzstd */,\n",
    "\t\t\t\t1A2B3C4D0000000000000054 /* libzstd */,\n\t\t\t\t%s /* XCTest */,\n" % TARGET,
    1,
)

for required, what in [
    (PRODUCT_REF, "product reference"),
    (MODULEMAP_REF, "modulemap reference"),
    (HEADERS_PHASE, "headers phase"),
    (SOURCES_PHASE, "sources phase"),
    (FRAMEWORKS_PHASE, "frameworks phase"),
    (RESOURCES_PHASE, "resources phase"),
    (TARGET, "native target"),
    (CONFIG_LIST, "configuration list"),
    (DEBUG_CONFIG, "debug configuration"),
    (RELEASE_CONFIG, "release configuration"),
    (XCTEST_GROUP, "xctest group"),
    (INCLUDE_GROUP, "include group"),
    (UMBRELLA_GROUP, "umbrella group"),
] + [(r, "header %s" % n) for n, r in zip(HEADERS, header_refs)]:
    if text.count(required) < 2:
        sys.exit("dangling %s (%s): defined but never referenced" % (what, required))

with open(PBX, "w") as f:
    f.write(text)

print("added XCTest framework target: %s" % TARGET)
print("  %d sources, %d public headers" % (len(SOURCES), len(HEADERS)))
