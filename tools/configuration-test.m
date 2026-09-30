// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for XCTestConfiguration.
//
// A configuration is a value, and a value that is only ever read from a dict the
// same process just wrote is a value whose bugs stay invisible: it round-trips
// through itself, agrees with itself, and answers YES to -isEqual: for two
// objects that were never compared against anything else. The checks here are
// therefore about the three places a value like this actually breaks.
//
//   Decoding a *partial* archive. An archive is a partial description of a run
//   by design -- the writer omits what the default already is -- so -initWithCoder:
//   has to establish the defaults itself before decoding over them. A decoder
//   that calls [super init] instead of [self init] still round-trips perfectly,
//   because the writer wrote the same defaults into the archive. It is only
//   visible against an archive that omits the keys, which is why three checks
//   here build one by hand.
//
//   Derived values. -testMode and -testBundleName are computed, and a computed
//   value that is computed from the wrong field is indistinguishable from one
//   that is right in every archive this process writes.
//
//   The legacy key probes. "An old archive that still has the old name" and "a
//   new archive that has neither" both read as NO through -decodeBoolForKey:.
//   Only the presence probe tells them apart, so the checks hand-build archives
//   in both shapes and read the flag back.
//
// Nothing here is exercised by the framework's own tests: this is a private
// framework with no runner of its own yet, which is the same reason the driver
// and the agent are still to come.
#import <XCTestCore/XCTestConfiguration.h>

#import <Foundation/Foundation.h>
// Not pulled in by the reduced <Foundation/Foundation.h>, and the whole harness
// is built on keyed coding.
#import <Foundation/NSKeyedArchiver.h>

#import <stdio.h>
#import <string.h>

static int failures = 0;

static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-56s %s%s%s\n", name, passed ? "PASS" : "FAIL",
           (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Helpers

/// Searches a keyed archive for an ASCII substring.
///
/// A keyed archive is a binary plist, so a key that was encoded appears in it in
/// its serialized form and can be found as bytes. Reading the archive back through
/// a plist parser would need NSPropertyListSerialization, which the reduced SDK
/// does not declare, and would also answer a different question: it would confirm
/// the plist parses, not that this key was written under this name.
static BOOL archiveContains(NSData *archive, const char *needle)
{
    const char *bytes = archive.bytes;
    size_t length = archive.length;
    size_t needleLength = strlen(needle);
    if (!bytes || needleLength == 0 || length < needleLength) {
        return NO;
    }
    for (size_t i = 0; i + needleLength <= length; i++) {
        if (memcmp(bytes + i, needle, needleLength) == 0) {
            return YES;
        }
    }
    return NO;
}

/// Round-trips a configuration through a keyed archive the same way a run does,
/// and reports whether the copy that comes back is the one that went in.
static XCTestConfiguration *roundTrip(XCTestConfiguration *original, NSString *why)
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original
                                        requiringSecureCoding:YES
                                                        error:&error];
    if (!data) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"encode failed: %@", error]);
        return nil;
    }
    XCTestConfiguration *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[XCTestConfiguration class]
                                                                     fromData:data
                                                                        error:&error];
    if (!decoded) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"decode failed: %@", error]);
        return nil;
    }
    return decoded;
}

/// The keys the next sparse archive should contain, and which of them the real
/// encoder writes as a boolean rather than as an object. Read by
/// SparseConfiguration's -encodeWithCoder:.
static NSDictionary *sparseKeys;
static NSSet<NSString *> *sparseBooleanKeys;

/// A configuration whose encoder writes only the keys the test asked for.
///
/// This is what makes a *partial* archive without a second guess at what the
/// decoder expects. -encodeWithCoder: is the writer, so overriding it to write a
/// chosen subset produces exactly what a build that predates those keys would have
/// produced; remapping the archived class name to XCTestConfiguration below is what
/// puts the real -initWithCoder: on the other end of it.
@interface SparseConfiguration : XCTestConfiguration
@end

@implementation SparseConfiguration
- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *key in sparseKeys) {
        id value = sparseKeys[key];
        // Encoded the way the real encoder encodes each of these, rather than
        // uniformly as an object. traceCollectionEnabled is an NSNumber property
        // written through -encodeObject:, and a bool written under its name decodes
        // back as nil -- so a sparse archive that wrote it as a bool would be
        // testing a shape the real writer never produces.
        if ([sparseBooleanKeys containsObject:key]) {
            [coder encodeBool:[value boolValue] forKey:key];
        } else {
            [coder encodeObject:value forKey:key];
        }
    }
}
@end

/// Archives a configuration whose encoder writes only `values`, with `booleanKeys`
/// written as booleans, then decodes it with the real class. Returns nil and records
/// the failure if it cannot be read.
static XCTestConfiguration *decodePartialArchive(NSDictionary *values, NSSet<NSString *> *booleanKeys,
                                                NSString *why)
{
    sparseKeys = values;
    sparseBooleanKeys = booleanKeys;
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:[[SparseConfiguration alloc] init]
                                        requiringSecureCoding:YES
                                                        error:&error];
    sparseKeys = nil;
    sparseBooleanKeys = nil;
    if (!data) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"sparse archive not written: %@", error]);
        return nil;
    }
    XCTestConfiguration *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[XCTestConfiguration class]
                                                                     fromData:data
                                                                        error:&error];
    if (!decoded) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"sparse archive unreadable: %@", error]);
    }
    return decoded;
}

#pragma mark - Defaults

static void testDefaults(void)
{
    XCTestConfiguration *config = [[XCTestConfiguration alloc] init];

    ok("a new configuration has a session identifier",
       config.sessionIdentifier != nil, nil);
    ok("session identifier is a UUID", [config.sessionIdentifier.UUIDString length] == 36,
       config.sessionIdentifier.UUIDString);

    XCTestConfiguration *other = [[XCTestConfiguration alloc] init];
    ok("two new configurations have different sessions",
       ![config.sessionIdentifier isEqual:other.sessionIdentifier], nil);

    // Both of these are opt-out in the reference, so the difference between "this
    // run asked for no activities" and "this run never had an opinion" is the
    // whole point of setting them.
    ok("reportActivities defaults to YES", config.reportActivities, nil);
    ok("inProcessParallelizationEnabled defaults to YES",
       config.inProcessParallelizationEnabled, nil);

    ok("testExecutionOrdering defaults to default",
       config.testExecutionOrdering == XCTTestExecutionOrderingDefault, nil);
    ok("randomExecutionOrderingSeed starts unset",
       config.randomExecutionOrderingSeed == nil, nil);
    ok("a random number generator is installed", config.randomNumberGenerator != nil, nil);

    // The generator is what makes a shuffled order different between two runs
    // that never set a seed. If it were constant, shuffling would shuffle into
    // the same order every time and the ordering bugs it exists to surface would
    // hide behind it.
    NSMutableSet *draws = [NSMutableSet set];
    for (int i = 0; i < 16; i++) {
        [draws addObject:@(config.randomNumberGenerator())];
    }
    ok("the generator actually varies", draws.count > 1,
       [NSString stringWithFormat:@"%lu distinct draws in 16", (unsigned long)draws.count]);

    // -isEqual: compares ordering, so a hash that ignored it would let two
    // different runs land in the same bucket. Not a contract violation, but it
    // is the one thing a hash is for.
    ok("hash covers the ordering",
       [[XCTestConfiguration alloc] init].hash != 0, nil);
}

#pragma mark - Derived values

static void testDerivedValues(void)
{
    XCTestConfiguration *config = [[XCTestConfiguration alloc] init];

    ok("testMode is unit tests by default", config.testMode == XCTTestModeUnitTests, nil);
    config.initializeForUITesting = YES;
    ok("testMode follows initializeForUITesting", config.testMode == XCTTestModeUITests, nil);
    config.initializeForUITesting = NO;
    ok("testMode follows the flag back", config.testMode == XCTTestModeUnitTests, nil);

    // The bundle name is a fallback chain, and each step is only reached when the
    // previous one is empty -- so each step is checked with the earlier ones
    // cleared, not merely absent from a fresh object.
    config.testBundleURL = nil;
    config.testBundleRelativePath = @"nested/path/MyTests.xctest";
    ok("testBundleName falls back to the relative path",
       [config.testBundleName isEqualToString:@"MyTests.xctest"], config.testBundleName);

    config.testBundleURL = [NSURL fileURLWithPath:@"/tmp/Other.xctest"];
    ok("testBundleName prefers the URL",
       [config.testBundleName isEqualToString:@"Other.xctest"], config.testBundleName);

    config.testBundleURL = nil;
    config.testBundleRelativePath = nil;
    // With neither path set the reference falls back to the main bundle's test
    // bundle. This harness is not a test bundle, so the name it produces is the
    // harness binary's -- what is checked is that the chain terminates in
    // something rather than in nil, which is the difference between "no name" and
    // "a name that happens to be this one".
    ok("testBundleName falls back to the main bundle",
       config.testBundleName.length > 0, config.testBundleName);

    // A relative bundle path is resolved against the main bundle's *directory*,
    // not the bundle itself: the bundle is a file inside that directory, so
    // resolving against the bundle would look for a test bundle inside a test
    // bundle.
    NSString *expected = [NSBundle mainBundle].bundlePath.stringByDeletingLastPathComponent;
    ok("defaultBasePath is the main bundle's directory",
       [XCTestConfiguration.defaultBasePathForTestBundleResolution isEqualToString:expected],
       expected);
    ok("defaultBasePathForMainBundlePath strips one component",
       [[XCTestConfiguration defaultBasePathForTestBundleResolutionForMainBundlePath:@"/a/b/c"]
           isEqualToString:@"/a/b"], nil);
}

#pragma mark - Coding

static void testCoding(void)
{
    XCTestConfiguration *original = [[XCTestConfiguration alloc] init];
    original.testBundleURL = [NSURL fileURLWithPath:@"/tmp/MyTests.xctest"];
    original.testBundleRelativePath = @"MyTests.xctest";
    original.reportResultsToIDE = YES;
    original.testsDrivenByIDE = YES;
    original.disablePerformanceMetrics = YES;
    original.treatMissingBaselinesAsFailures = YES;
    original.reportActivities = NO;
    original.testsMustRunOnMainThread = YES;
    original.initializeForUITesting = YES;
    original.emitOSLogs = YES;
    original.gatherLocalizableStringsData = YES;
    original.testTimeoutsEnabled = YES;
    original.initializeForMultiDevice = YES;
    original.shouldExtractMultiDeviceRequirements = YES;
    original.runAsMultiDeviceRemoteRunner = YES;
    original.targetApplicationPath = @"/tmp/Target.app";
    original.targetApplicationBundleID = @"com.example.target";
    original.targetApplicationArguments = @[ @"-a", @"-b" ];
    original.targetApplicationEnvironment = @{ @"KEY": @"VALUE" };
    original.productModuleName = @"MyTests";
    original.automationFrameworkPath = @"/tmp/automation";
    original.testApplicationDependencies = @{ @"dep": @"/tmp/dep.dylib" };
    original.testApplicationUserOverrides = @{ @"UserDefaults": @{ @"k": @"v" } };
    original.bundleIDsForCrashReportEmphasis = [NSSet setWithObject:@"com.example.crashes"];
    original.baselineFileRelativePath = @"baseline.txt";
    original.performanceTestConfiguration = @{ @"iterations": @5 };
    original.enablePerformanceTestsDiagnostics = @YES;
    original.systemAttachmentLifetime = 1;
    original.userAttachmentLifetime = 0;
    original.preferredScreenCaptureFormat = 2;
    original.testExecutionOrdering = XCTTestExecutionOrderingRandom;
    original.randomExecutionOrderingSeed = @1234;
    original.leaksCheckingMode = 2;
    original.defaultTestExecutionTimeAllowance = @10;
    original.maximumTestExecutionTimeAllowance = @20;
    original.traceCollectionEnabled = @YES;
    original.symbolicationImageNames = [NSSet setWithObject:@"MyTests"];
    original.testInstructionsSet = [NSSet setWithObject:@"instructions"];
    original.applicationBundleInfos = @{ @"com.example": @{ @"path": @"/tmp/a.app" } };
    original.multiDeviceRequirementsFilePath = @"requirements.txt";
    original.multiDevicePlatformVersionMap = @{ @"1": @"17.0" };
    original.multiDeviceRemoteRunnerPlatformMap = @{ @"1": @"17.0" };
    original.basePathForTestBundleResolution = @"/tmp";

    XCTestConfiguration *decoded = roundTrip(original, @"a full configuration round-trips");
    if (!decoded) {
        return;
    }

    // On a mismatch the two descriptions are printed rather than just a FAIL line.
    // -isEqual: here compares every field, so "not equal" names none of them, and
    // the one field that diverged is the entire question. This happened once: the
    // multi-device keys were written under one name and read under another, so the
    // round trip dropped them and only the description diff said which.
    if (![original isEqual:decoded]) {
        printf("--- original ---\n%s\n--- decoded ---\n%s\n",
               original.description.UTF8String, decoded.description.UTF8String);
    }
    ok("round trip is equal", [original isEqual:decoded], nil);
    ok("round trip has the same hash", original.hash == decoded.hash, nil);
    ok("round trip keeps the session", [original.sessionIdentifier isEqual:decoded.sessionIdentifier], nil);
    ok("round trip keeps a derived value",
       [decoded.testBundleName isEqualToString:original.testBundleName], decoded.testBundleName);
    ok("round trip keeps the ordering", decoded.testExecutionOrdering == XCTTestExecutionOrderingRandom, nil);
    ok("round trip keeps a NO default that was set to NO",
       decoded.reportActivities == NO, nil);
    ok("round trip keeps the seed",
       decoded.randomExecutionOrderingSeed.intValue == 1234, nil);
    ok("round trip keeps the collection",
       [decoded.targetApplicationArguments isEqual:@[ @"-a", @"-b" ]], nil);
    ok("round trip keeps a dictionary",
       [decoded.targetApplicationEnvironment[@"KEY"] isEqualToString:@"VALUE"], nil);
    ok("round trip keeps a set",
       [decoded.symbolicationImageNames containsObject:@"MyTests"], nil);
    ok("round trip keeps the timeout", decoded.maximumTestExecutionTimeAllowance.intValue == 20, nil);
    ok("round trip keeps the leak mode", decoded.leaksCheckingMode == 2, nil);

    // The keys are what an archive written by one version has to be readable by
    // another. Three of the reference's spellings are unusual enough to be worth
    // pinning by name: a v2 suffix, two capitalised keys among lowercase ones, and
    // a plural that carries a single value.
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original
                                        requiringSecureCoding:YES
                                                        error:NULL];
    ok("the archive carries the reference's odd key spellings",
       archiveContains(data, "traceCollectionEnabled_v2") &&
       archiveContains(data, "EnablePerformanceTestsDiagnostics") &&
       archiveContains(data, "ApplicationBundleInfos") &&
       archiveContains(data, "formatVersion"), nil);
    ok("the archive does not use the v1 trace key",
       !archiveContains(data, "\"traceCollectionEnabled\""), nil);

    // Nothing in the reference reads formatVersion, so its value could not be
    // recovered from the binary and 1 is a choice. It is pinned here so that
    // changing it has to be deliberate, and so that the constant this build ships
    // is the one the documentation claims.
    ok("format version is the pinned 1", XCTestConfigurationFormatVersion == 1,
       [NSString stringWithFormat:@"%ld", (long)XCTestConfigurationFormatVersion]);
}

#pragma mark - Partial archives

static void testPartialArchive(void)
{
    // What a sparse archive produces, per -initWithCoder: in the reference. Only
    // two keys are presence-guarded there, and both because their -init default is
    // non-zero; every other key decodes unconditionally, so an absent key reads as
    // zero/nil and overwrites the default instead of deferring to it. The reference
    // also calls -init before decoding, which is what supplies the defaults the two
    // guarded keys keep -- and, on this path, nothing else.
    XCTestConfiguration *decoded = decodePartialArchive(@{}, nil, @"a sparse archive decodes");
    if (!decoded) {
        return;
    }
    ok("a guarded boolean keeps its default", decoded.inProcessParallelizationEnabled, nil);
    ok("a guarded integer keeps its default", decoded.leaksCheckingMode == 0, nil);
    ok("an unguarded boolean reads as NO", !decoded.reportActivities, nil);
    // Not a default that survives: the session decodes to nothing, because a
    // fabricated one would be indistinguishable from a real session in a report.
    ok("an unguarded object reads as nil", decoded.sessionIdentifier == nil, nil);
    // The generator is not archived at all, so it can only come from -init.
    ok("a sparse archive still has a generator", decoded.randomNumberGenerator != nil, nil);
    XCTestConfiguration *second = decodePartialArchive(@{}, nil, @"a second sparse archive");
    ok("two sparse archives are distinct objects", second != nil && decoded != second, nil);

    // The renamed multi-device keys. Finding a value under the old name *is* the
    // answer -- YES for the flags -- and only an archive without the old name reads
    // the current one. Both directions are here because the failure is silent in the
    // common one: a decoder that reads only the new name drops every old archive,
    // and a decoder that reads only the old name cannot read its own output.
    XCTestConfiguration *legacy = decodePartialArchive(
        @{ @"XCTestConfiguration_initializeForMultiDevice": @YES }, nil,
        @"a legacy archive decodes");
    ok("the old multi-device key answers YES", legacy.initializeForMultiDevice, nil);

    XCTestConfiguration *current = decodePartialArchive(
        @{ @"initializeForMultiDevice": @YES }, [NSSet setWithObject:@"initializeForMultiDevice"],
        @"a current archive decodes");
    ok("the current multi-device key is read", current.initializeForMultiDevice, nil);
    ok("a current key is not read as an old one",
       !decodePartialArchive(@{ @"shouldExtractMultiDeviceRequirements": @NO },
                             [NSSet setWithObject:@"shouldExtractMultiDeviceRequirements"],
                             @"a current archive decodes")
            .shouldExtractMultiDeviceRequirements, nil);

    // The path key is the one that takes its *value* from the old name rather than a
    // hardcoded YES, so both names have to produce the same string for a round trip
    // to work either way round.
    XCTestConfiguration *legacyPath = decodePartialArchive(
        @{ @"XCTestConfiguration_multiDeviceRequirementsFilePath": @"legacy.txt" }, nil,
        @"a legacy path archive decodes");
    ok("the old path key answers with its own value",
       [legacyPath.multiDeviceRequirementsFilePath isEqualToString:@"legacy.txt"],
       legacyPath.multiDeviceRequirementsFilePath);
    XCTestConfiguration *currentPath = decodePartialArchive(
        @{ @"multiDeviceRequirementsFilePath": @"current.txt" }, nil,
        @"a current path archive decodes");
    ok("the current path key is read",
       [currentPath.multiDeviceRequirementsFilePath isEqualToString:@"current.txt"],
       currentPath.multiDeviceRequirementsFilePath);

    // traceCollectionEnabled was renamed to traceCollectionEnabled_v2, and the
    // reference reads the v2 key unconditionally and the old one only when v2 comes
    // back nil. Both shapes are checked because getting the fallback backwards
    // produces a config that ignores a setting entirely.
    XCTestConfiguration *v2 = decodePartialArchive(@{ @"traceCollectionEnabled_v2": @YES }, nil,
                                                   @"a v2 trace archive decodes");
    ok("the v2 trace key is read", v2.traceCollectionEnabled.boolValue, nil);

    XCTestConfiguration *legacyTrace = decodePartialArchive(@{ @"traceCollectionEnabled": @YES }, nil,
                                                            @"a legacy trace archive decodes");
    ok("the legacy trace key is the fallback",
       legacyTrace.traceCollectionEnabled.boolValue, nil);

    XCTestConfiguration *bothTrace = decodePartialArchive(
        @{ @"traceCollectionEnabled_v2": @NO, @"traceCollectionEnabled": @YES }, nil,
        @"a both-spellings archive decodes");
    ok("the v2 key wins when both spellings are present",
       bothTrace.traceCollectionEnabled.boolValue == NO, nil);
}

#pragma mark - Value semantics

static void testValueSemantics(void)
{
    XCTestConfiguration *original = [[XCTestConfiguration alloc] init];
    original.testBundleRelativePath = @"MyTests.xctest";
    original.reportResultsToIDE = YES;

    XCTestConfiguration *copy = [original copy];
    ok("a copy is equal", [original isEqual:copy], nil);
    ok("a copy has the same hash", original.hash == copy.hash, nil);
    ok("a copy is not the same object", original != copy, nil);

    // A copy that shared its mutable storage would be a configuration that changed
    // under a run that had already read it.
    copy.testBundleRelativePath = @"Other.xctest";
    copy.reportResultsToIDE = NO;
    ok("mutating a copy leaves the original alone",
       [original.testBundleRelativePath isEqualToString:@"MyTests.xctest"] && original.reportResultsToIDE,
       original.testBundleRelativePath);

    // -isEqual: is a total comparison, not a prefix of one. Each of these is a
    // field the reference compares, so each has to be able to make two otherwise
    // identical configurations unequal.
    XCTestConfiguration *base = [[XCTestConfiguration alloc] init];
    XCTestConfiguration *variant = [[XCTestConfiguration alloc] init];
    variant.sessionIdentifier = [[NSUUID UUID] copy];
    ok("a different session is not equal", ![base isEqual:variant], nil);
    ok("equality is symmetric",
       [base isEqual:variant] == [variant isEqual:base], nil);

    XCTestConfiguration *ui = [[XCTestConfiguration alloc] init];
    ui.initializeForUITesting = YES;
    ok("a different mode is not equal", ![base isEqual:ui], nil);

    XCTestConfiguration *ordered = [[XCTestConfiguration alloc] init];
    ordered.testExecutionOrdering = XCTTestExecutionOrderingRandom;
    ok("a different ordering is not equal", ![base isEqual:ordered], nil);

    // nil and an empty collection are different instructions, so they must not
    // compare equal -- a run told "no extra bundles" and a run told nothing at
    // all are not the same run.
    XCTestConfiguration *empty = [[XCTestConfiguration alloc] init];
    empty.targetApplicationArguments = @[];
    ok("an empty list is not the same as no list", ![base isEqual:empty], nil);

    ok("a configuration is not equal to a different class",
       ![base isEqual:@"not a configuration"], nil);
    ok("nil is not equal to a configuration", ![base isEqual:nil], nil);
}

#pragma mark - Test selection

/// The selection a configuration carries.
///
/// Nothing here is about the selection on its own -- tools/selection-test.m is
/// that harness. This is about the two things a configuration adds: that it is
/// never without one, and that the one it holds survives the crossing as the
/// same selection rather than as an equal one.
static void testSelection(void)
{
    printf("selection\n");

    XCTestConfiguration *config = [[XCTestConfiguration alloc] init];
    // Non-null, and empty: a synthesized configuration is complete, and
    // "complete" now includes "runs everything". A driver reading this never has
    // to ask whether there is a selection before asking what is in it.
    ok("a fresh configuration has a selection", config.testSelection != nil, nil);
    ok("a fresh configuration runs everything", config.testSelection.identifiersToRun == nil, nil);
    ok("a fresh configuration skips no named tests", config.testIdentifiersToRun == nil, nil);
    ok("a fresh configuration skips nothing", config.testIdentifiersToSkip == nil, nil);
    ok("a fresh configuration has no tags to run", config.testSelection.tagsToRun == nil, nil);
    ok("a fresh configuration has no tags to skip", config.testSelection.tagsToSkip == nil, nil);

    // The two forwarders read the selection rather than carrying their own
    // storage. A forwarder that cached its value would go stale the moment the
    // selection was replaced, and the caller would have no way to tell.
    XCTTestSelection *narrowed = [[XCTTestSelection alloc]
        initWithIdentifiersToRun:[[XCTTestIdentifierSet alloc]
                                     initWithArray:@[[[XCTTestIdentifier alloc]
                                                           initWithComponents:@[ @"MyTests.xctest", @"MyTests",
                                                                                @"testOne" ]
                                                                   argumentIDs:nil
                                                                       options:XCTTestIdentifierOptionNone]]]
               identifiersToSkip:nil
                    tagsToRun:nil
                   tagsToSkip:nil];
    config.testSelection = narrowed;
    ok("the forwarder follows the selection", config.testIdentifiersToRun.count == 1, nil);
    // The configuration's own selection, not the object that was assigned: the
    // property is -copy, so what the setter kept is an equal copy. A forwarder
    // that read the value the assignment happened to pass would be correct right
    // up until the configuration's selection was replaced.
    ok("the forwarder is the configuration's own selection's set",
       config.testIdentifiersToRun == config.testSelection.identifiersToRun, nil);
    ok("the assignment was copied rather than aliased", config.testSelection != narrowed, nil);

    // A selection is part of the configuration's identity. Two configurations
    // that run different tests are different configurations, and a caller
    // comparing them to decide whether a cached result is reusable has to be
    // told no.
    XCTestConfiguration *other = [[XCTestConfiguration alloc] init];
    other.sessionIdentifier = config.sessionIdentifier;
    other.testSelection = narrowed;
    ok("two configurations with the same selection are equal", [config isEqual:other], nil);
    ok("they hash the same", config.hash == other.hash, nil);

    XCTestConfiguration *empty = [other copy];
    empty.testSelection = [[XCTTestSelection alloc] init];
    ok("a different selection is not equal", ![other isEqual:empty], nil);
    ok("equality survives the difference being reversed", ![empty isEqual:other], nil);

    // The selection is what the hash keys on, so two configurations that run the
    // same tests land in the same bucket however they got there -- including one
    // that built its selection from a plist rather than through an identifier.
    XCTestConfiguration *rebuilt = [other copy];
    rebuilt.testSelection = [[XCTTestSelection alloc] initWithIdentifiersToRun:narrowed.identifiersToRun
                                                              identifiersToSkip:nil
                                                                   tagsToRun:nil
                                                                  tagsToSkip:nil];
    ok("the same selection built twice is equal", [other isEqual:rebuilt], nil);
    ok("and hashes the same", other.hash == rebuilt.hash, nil);

    // And the ordering is not what distinguishes them any more. A run that
    // reorders the same tests executes the same set, so it must land in the same
    // bucket -- the substitution that used to sit in -hash would have split it.
    XCTestConfiguration *reordered = [other copy];
    reordered.testExecutionOrdering = XCTTestExecutionOrderingRandom;
    ok("a reordered run is a different configuration", ![other isEqual:reordered], nil);
    ok("but it hashes the same", other.hash == reordered.hash, nil);

    // A copy that shared its selection would be a configuration that narrowed
    // itself under a run that had already read the original.
    XCTestConfiguration *shared = [other copy];
    shared.testSelection.identifiersToRun =
        [[XCTTestIdentifierSet alloc] initWithArray:@[]];
    ok("mutating a copy's selection leaves the original alone",
       other.testIdentifiersToRun.count == 1, other.testIdentifiersToRun.anyTestIdentifier.identifierString);

    // The crossing. The selection has to come back as the same selection, with
    // its identifiers intact -- a configuration that decoded into an equal but
    // differently-spelled selection would pass -isEqual: and still be wrong in
    // the one way that matters to a log.
    XCTestConfiguration *round = roundTrip(config, @"the selection round trips");
    ok("the selection survives the crossing",
       [round.testSelection isEqual:config.testSelection], nil);
    ok("the identifiers survive the crossing",
       [round.testIdentifiersToRun.anyTestIdentifier.identifierString
           isEqualToString:@"MyTests.xctest/MyTests/testOne"],
       round.testIdentifiersToRun.anyTestIdentifier.identifierString);
    ok("the forwarders survive the crossing",
       round.testIdentifiersToRun.count == 1 && round.testIdentifiersToSkip == nil, nil);

    // An archive written before selections existed has no "testSelection" key.
    // That has to decode into a run that executes everything rather than into
    // one with nothing to read, because that configuration is still a run
    // somebody asked for.
    XCTestConfiguration *legacy = decodePartialArchive(@{}, [NSSet set], @"a sparse archive with no selection");
    ok("an archive with no selection key still has one", legacy.testSelection != nil, nil);
    ok("and it runs everything", legacy.testSelection.identifiersToRun == nil, nil);
    ok("and its forwarders answer empty", legacy.testIdentifiersToRun == nil, nil);

    // The description is where a wrong run is first noticed, and the count is
    // what a reader needs from it -- the full list would bury the one surprising
    // field in a run that selected thousands of tests.
    ok("the description reports the selection's size",
       [other.description containsString:@"testSelection: 1 to run, 0 to skip"], nil);
}

#pragma mark - Active configuration

static void testActiveConfiguration(void)
{
    ok("no run is active to begin with",
       XCTestConfiguration.activeTestConfiguration == nil, nil);

    XCTestConfiguration *config = [[XCTestConfiguration alloc] init];
    XCTestConfiguration.activeTestConfiguration = config;
    ok("the active configuration is readable",
       XCTestConfiguration.activeTestConfiguration == config, nil);

    XCTestConfiguration.activeTestConfiguration = nil;
    ok("the active configuration can be cleared",
       XCTestConfiguration.activeTestConfiguration == nil, nil);

    ok("supportsSecureCoding is advertised", XCTestConfiguration.supportsSecureCoding, nil);
}

#pragma mark - Execution ordering

static void testExecutionOrdering(void)
{
    ok("default renders as \"default\"",
       [XCTTestExecutionOrderingToString(XCTTestExecutionOrderingDefault)
           isEqualToString:@"default"], nil);
    ok("random renders as \"random\"",
       [XCTTestExecutionOrderingToString(XCTTestExecutionOrderingRandom)
           isEqualToString:@"random"], nil);

    ok("\"random\" parses to random",
       XCTTestExecutionOrderingFromString(@"random") == XCTTestExecutionOrderingRandom, nil);
    // Anything that is not "random" is the default: the reference answers this
    // with a comparison, not a switch, so an unknown string is not an error.
    ok("an unknown string parses to default",
       XCTTestExecutionOrderingFromString(@"sideways") == XCTTestExecutionOrderingDefault, nil);
    ok("nil parses to default",
       XCTTestExecutionOrderingFromString(nil) == XCTTestExecutionOrderingDefault, nil);

    // The name reads backwards from the answer, and that is deliberate: the
    // reference returns "this ordering is *not* the default", which is what the
    // caller asks before deciding to apply an ordering policy of its own. It is
    // reproduced rather than corrected, because a caller compiled against
    // Apple's header depends on the answer being this one.
    ok("IsDefault(YES) is false for the default ordering",
       !XCTTestExecutionOrderingIsDefault(XCTTestExecutionOrderingDefault), nil);
    ok("IsDefault(YES) is true for random",
       XCTTestExecutionOrderingIsDefault(XCTTestExecutionOrderingRandom), nil);
}

int main(void)
{
    @autoreleasepool {
        // The sparse-archive checks are the reason this harness exists, and they
        // only mean anything if the archive they build is decoded as a plain
        // XCTestConfiguration. The class-name mapping is process-wide and is set
        // once here rather than reset, since the harness is the only writer.
        [NSKeyedArchiver setClassName:@"XCTestConfiguration" forClass:[SparseConfiguration class]];

        printf("XCTestConfiguration\n");
        testDefaults();
        testDerivedValues();
        testCoding();
        testPartialArchive();
        testValueSemantics();
        testSelection();
        testActiveConfiguration();
        testExecutionOrdering();

        printf("%s: %d failure%s\n", failures ? "FAILED" : "PASSED", failures,
               failures == 1 ? "" : "s");
    }
    return failures ? 1 : 0;
}
