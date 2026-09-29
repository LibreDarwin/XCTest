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

Two things are deliberately absent.

There is no PBXTargetDependency from XCTest to XCTestCore, and no
PBXContainerItemProxy. Nothing in XCTest.framework links XCTestCore yet: the
public XCTestCore.h is only an aggregator, and the value type in XCTestCore
references no XCTest class. The dependency is added in the direction that
matters, when the driver lands -- a test bundle links XCTest, XCTest links
XCTestCore, and nothing ever links back. Adding it now would be a target that
builds nothing and a direction nothing enforces.

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

SOURCES = [("XCTestConfiguration.m", "1A2B3C4E0000000000000075", "1A2B3C4E0000000000000081")]
HEADERS = ["XCTestConfiguration.h"]
header_refs = ["1A2B3C4E00000000000000C0"]
header_buildfiles = ["1A2B3C4E00000000000000E0"]

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
] + [(r, "source %s" % s[0]) for s in SOURCES for r in (s[1], s[2])] + [
    (r, "header %s" % n) for n, r in zip(HEADERS, header_refs + header_buildfiles)
]:
    if text.count(required) < 2:
        sys.exit("dangling %s (%s): defined but never referenced" % (what, required))

with open(PBX, "w") as f:
    f.write(text)

print("added XCTestCore framework target: %s" % TARGET)
print("  %d source, %d public header" % (len(SOURCES), len(HEADERS)))
