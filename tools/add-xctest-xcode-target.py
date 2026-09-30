#!/usr/bin/env python3
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
"""Add a real XCTest.framework native target to the Xcode project.

The 11 source file references and 11 Sources build files added in 0a9c5b0 are
orphans: nothing in the project lists them. This adds the missing half --
product reference, header/resource references, the four build phases, build
configurations, the target itself, and the group tree that makes it visible.

The four specialized expectations and the performance measurement types came
after that, so the target this script generates installed 31 public headers
rather than the 25 the skeleton had.

That count is now the whole of it. This framework has no sources. Every
implementation file is built into XCTestCore.framework and reached through the
@rpath/XCTestCore re-export this dylib records, so a client links
-framework XCTest and resolves every public symbol at run time. That is Apple's
arrangement rather than an approximation of it: Apple's XCTest.framework is a
110KB shim whose only exported symbol is _XCUIEnableUIAutomation, and whose one
re-export is XCTestCore. HEADERS below is therefore the single place either list
is written down -- a new public header is picked up automatically, and an
implementation file has to be added to add-xctestcore-xcode-target.py's SOURCES
so it also gets an entry in the Makefile that a reviewer can check it against.

The 11 source references and 11 Sources build files that 0a9c5b0 left behind are
deleted rather than left orphaned. The files they name are in src/xctestcore now,
so a reference to src/xctest/XCTest.m is a reference to nothing, and an
unresolvable path is exactly the failure this project's checks exist to catch.

Header identifiers are numbered by position in the sorted list, so adding a
header renumbers the ones after it. The churn in the project file is mechanical:
every moved line keeps its name and its Public attribute and only changes the
number it is keyed by.

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

# 0a9c5b0 left 11 file references (0x75-0x7F) and 11 Sources build files
# (0x81-0x8B) for files that have since moved to src/xctestcore. They are deleted
# below, and SOURCES is empty because this target compiles nothing. Two things
# depend on that being true rather than merely intended: the Sources build phase
# has to come out empty, or xcodebuild would look for the old paths, and the
# re-export flag has to be on the link line, or the dylib would load with nothing
# in it to re-export. Both are checked below.
SOURCES = []

# The 11 orphans name files that no longer exist at that path, so their build files
# and their file references are both removed. Removing only the build files would
# leave 11 references to nothing in the navigator, which xcodebuild drops silently.
# The build files are matched with and without the fileRef name comment, because
# 0a9c5b0 wrote them without one.
removed_bf = 0
for line in re.findall(
    r"^\t\t1A2B3C4D000000000000008[1-9AB] /\* .*? in Sources \*/ = \{isa = PBXBuildFile; fileRef = 1A2B3C4D000000000000007[5-9ABCDEF](?: /\* .*? \*/)?; \};$",
    text,
    re.M,
):
    text = text.replace(line + "\n", "")
    removed_bf += 1
if removed_bf != 11:
    sys.exit("expected to remove 11 orphaned Sources build files, removed %d" % removed_bf)

removed_refs = 0
for line in re.findall(
    r"^\t\t1A2B3C4D000000000000007[5-9ABCDEF] /\* .*? \*/ = \{isa = PBXFileReference;[^\n]*path = [A-Za-z]+\.m;[^\n]*$",
    text,
    re.M,
):
    text = text.replace(line + "\n", "")
    removed_refs += 1
if removed_refs != 11:
    sys.exit("expected to remove 11 orphaned source references, removed %d" % removed_refs)


public_dir = os.path.join(ROOT, "src", "xctest", "include", "XCTest")
HEADERS = sorted(f for f in os.listdir(public_dir) if f.endswith(".h"))
if len(HEADERS) != 31:
    sys.exit("expected 31 public headers, found %d" % len(HEADERS))

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

text = insert_in_section(text, "PBXFileReference", "\n".join(refs))

# A dangling fileRef would be silently dropped rather than diagnosed, so check the
# one invariant that is not visible from the build log: each header's build file
# must resolve to a real reference.
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
# Empty, and that emptiness is the point: this target compiles nothing. A phase
# with entries would make xcodebuild look for src/xctest/*.m, which is where those
# files used to be and where they are not any more. Xcode expects a target to
# have the phase even when it has nothing to put in it.
sources_phase = phase(SOURCES_PHASE, "PBXSourcesBuildPhase", [])
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
#
# OTHER_LDFLAGS is the only thing that makes this a re-exporting shim rather than
# an empty dylib: -reexport_framework,XCTestCore records XCTestCore in the load
# commands with the reexport flag, which is what lets a client that linked only
# -framework XCTest resolve every public symbol. The Makefile passes the same flag
# to the same linker. XCTestCore.framework itself is not named here -- it is added
# to this target's Frameworks phase by add-xctestcore-xcode-target.py, which is
# the script that can mint the file reference, and putting the path in two places
# is how a link line and a phase end up disagreeing about which one wins.
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
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"-Wl,-reexport_framework,XCTestCore",
\t\t\t\t);
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.apple.dt.xctest";
\t\t\t\tPRODUCT_NAME = XCTest;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tVERSIONING_SYSTEM = "apple-generic";
\t\t\t\tVERSION_INFO_PREFIX = "";"""

# The product and the intermediates get their own directories, separate from the
# ones the Makefile uses. The project's own configurations still point at
# build/<config> and build/obj/<config>, which is what the Makefile builds into,
# and 'make check-xcode' cleans only what it is about to rebuild -- so with
# shared paths a framework left over from a previous make could satisfy the
# smoke test after xcodebuild had done nothing at all. This is set here rather
# than by editing the generated project because the documented way to regenerate
# is to run this over the pre-target revision, which has the shared paths.
debug_paths = (
    "\t\t\t\tCONFIGURATION_BUILD_DIR = \"$(SRCROOT)/build/xcode-debug\";\n"
    "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n"
    "\t\t\t\tOBJROOT = \"$(SRCROOT)/build/xcode-obj/debug\";\n"
    "\t\t\t\tONLY_ACTIVE_ARCH = YES;\n"
)
release_paths = (
    "\t\t\t\tCONFIGURATION_BUILD_DIR = \"$(SRCROOT)/build/xcode-release\";\n"
    "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 3;\n"
    "\t\t\t\tOBJROOT = \"$(SRCROOT)/build/xcode-obj/release\";\n"
)

configs = (
    "\t\t%s /* Debug */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n%s\n"
    "\t\t\t};\n"
    "\t\t\tname = Debug;\n"
    "\t\t};\n"
    "\t\t%s /* Release */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n%s\n"
    "\t\t\t};\n"
    "\t\t\tname = Release;\n"
    "\t\t};"
) % (DEBUG_CONFIG, common + "\n" + debug_paths, RELEASE_CONFIG, common + "\n" + release_paths)

# xcodebuild writes its incremental build database under the *project* level
# OBJROOT even when it is building a single target, so redirecting only the
# target's settings still left build/obj/<config>/XCBuildData behind in the
# Makefile's tree. The project level keeps its own CONFIGURATION_BUILD_DIR,
# which the other targets in this project and the Makefile both rely on, and
# moves only OBJROOT.
text = text.replace(
    'OBJROOT = "$(SRCROOT)/build/obj/debug";',
    'OBJROOT = "$(SRCROOT)/build/xcode-obj/debug";',
)
text = text.replace(
    'OBJROOT = "$(SRCROOT)/build/obj/release";',
    'OBJROOT = "$(SRCROOT)/build/xcode-obj/release";',
)
if 'build/obj/' in text:
    sys.exit("project still builds into build/obj; the OBJROOT redirect did not apply")

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

# The re-export flag is a string in a build setting, not an object, so nothing
# above notices if it is lost: the project still loads, the target still links,
# and the smoke test fails at the client because no symbol resolves. Check it
# here, where a mistake is still a one-line fix. It appears once per
# configuration, so two is the count that means both are covered.
if text.count("reexport_framework,XCTestCore") != 2:
    sys.exit("expected -reexport_framework,XCTestCore in both configurations, found %d"
             % text.count("reexport_framework,XCTestCore"))
# src/xctest still legitimately holds Info.plist, module.modulemap, and the public
# headers, so the invariant is narrower than "no path under src/xctest": nothing in
# the project may name an implementation file there, because none exists.
stale = re.findall(r"src/xctest/[^\"'\s]*\.[mh]\b", text)
if stale:
    sys.exit("the project still names implementation files under src/xctest: %s" % stale)

# The Sources phase has to be empty. Checking "no build file says in Sources" would
# be wrong -- every other target in this project has one, and they are all minted
# from the same 1A2B3C4D prefix -- so the check is on this phase's own file list.
# The comment on the phase object is the isa with "BuildPhase" cut off, which is
# why it reads PBXSources here and Sources in the target's buildPhases list.
sources_files = re.search(
    r"%s /\* PBXSources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
    r"\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n(.*?)\t\t\t\);\n" % SOURCES_PHASE,
    text,
    re.S,
)
if sources_files is None:
    sys.exit("could not find the XCTest Sources phase to check")
if sources_files.group(1).strip():
    sys.exit("the XCTest Sources phase is not empty:\n%s" % sources_files.group(1))

with open(PBX, "w") as f:
    f.write(text)

print("added XCTest framework target: %s" % TARGET)
print("  %d sources (this framework is a re-exporting shim), %d public headers"
      % (len(SOURCES), len(HEADERS)))
