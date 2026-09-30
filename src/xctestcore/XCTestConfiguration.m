// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestConfiguration, implemented from the shipped XCTestCore binary.
//
// The coding keys and their order are the ones the reference actually writes
// and reads, recovered from -encodeWithCoder: and -initWithCoder:. Order
// matters only for the writer, but the key *names* are the interface: a config
// written by one and read by the other has to agree on them, and an
// .xctestrun plist in the wild is nothing but these keys.
//
// Three keys are read but never written, and two are written under a name that
// does not match the property:
//
//   traceCollectionEnabled_v2, EnablePerformanceTestsDiagnostics,
//   ApplicationBundleInfos
//     The encoding always writes the "_v2"/capitalised spelling. Reading falls
//     back to the older lowercase spelling, so a plist written by an older tool
//     still round-trips.
//   XCTestConfiguration_initializeForMultiDevice,
//   XCTestConfiguration_shouldExtractMultiDeviceRequirements,
//   XCTestConfiguration_multiDeviceRequirementsFilePath
//     Renamed keys. Finding a value under an old name *is* the answer -- the
//     decoder short-circuits to YES for the two flags, and to the old key's own
//     value for the path -- and only reads the current name when it finds
//     nothing. The reference probes with -objectForKeyedSubscript:, which is not
//     public Foundation; -containsValueForKey: is used here instead and answers
//     the same question for a keyed archive. It also calls
//     -containsValueForKey: directly, for the two keys whose zero value is the
//     default (see below).
//
// Only two keys are presence-guarded, and both are guarded for the same reason:
// their -init default is non-zero, so decoding an absent key as zero would
// silently override it. Every other key decodes unconditionally, which is why a
// configuration decoded from an archive that omits reportActivities or
// sessionIdentifier has neither, rather than falling back to what -init would
// have set.

#import <XCTestCore/XCTestConfiguration.h>

#import <Foundation/Foundation.h>

#import "XCTestCoreFoundationCompat.h"

NSInteger const XCTestConfigurationFormatVersion = 1;

#pragma mark - Test execution ordering

NSString *XCTTestExecutionOrderingToString(XCTTestExecutionOrdering ordering)
{
    switch (ordering) {
    case XCTTestExecutionOrderingDefault:
        return @"default";
    case XCTTestExecutionOrderingRandom:
        return @"random";
    }
    // The reference reaches its assertion handler here rather than returning a
    // placeholder, and an unrecognised value is a corrupt or hand-edited config
    // rather than something to paper over. This SDK declares NSAssertionFailure
    // but does not export the symbol, so the exception that handler would have
    // raised is raised here instead: same name, same reason text. The return
    // below is a formality for the compiler, not a fallback any caller can reach.
    [[NSException exceptionWithName:NSInternalInconsistencyException
                              reason:[NSString stringWithFormat:
                                          @"Encountered unexpected XCTTestExecutionOrdering value: %ld",
                                          (long)ordering]
                            userInfo:nil] raise];
    return @"default";
}

XCTTestExecutionOrdering XCTTestExecutionOrderingFromString(NSString *string)
{
    return [string isEqualToString:@"random"] ? XCTTestExecutionOrderingRandom
                                              : XCTTestExecutionOrderingDefault;
}

BOOL XCTTestExecutionOrderingIsDefault(XCTTestExecutionOrdering ordering)
{
    return ordering != XCTTestExecutionOrderingDefault;
}

#pragma mark - Random execution ordering seed

/// Draws a seed for a shuffled test order. Seeded from the system so two
/// configurations that never set -randomExecutionOrderingSeed get different
/// orders, which is the whole point of shuffling: a run that reproduces the
/// previous run's order hides exactly the ordering bug it was asked to find.
///
/// The draw is 32 bits wide, not pointer-wide: -randomExecutionOrderingSeed is
/// an NSNumber the value is stored in, and arc4random_uniform rejects a bound
/// above UINT32_MAX rather than silently reducing it.
static NSInteger XCTSeedableRandomNumberGenerator(void)
{
    return (NSInteger)arc4random_uniform(UINT32_MAX);
}

#pragma mark - XCTestConfiguration

@implementation XCTestConfiguration

/// A configuration's own defaults. A fresh one already has a session and an
/// ordering, so a run that only ever reads them behaves; a run that wants a
/// selection has to be given one.
- (instancetype)init
{
    self = [super init];
    if (!self) {
        return nil;
    }
    // Copied rather than assigned: the UUID is a value, and handing out the same
    // object twice would let one configuration's session be mutated out from
    // under another that shares it. +[NSUUID UUID] is the reference's constructor
    // for this, recovered from -init's own call.
    _sessionIdentifier = [[NSUUID UUID] copy];
    // Activities are reported unless a client says otherwise, and in-process
    // parallelization is on unless a client says otherwise. Both are opt-out,
    // which is why they are set here rather than left zeroed: a NO here means
    // "this run asked for no activities", not "this run never had an opinion".
    _reportActivities = YES;
    _inProcessParallelizationEnabled = YES;
    // An empty selection, not a nil one. A synthesized configuration is
    // complete, and completeness here means "runs everything" -- so the
    // selection has to exist and have to be empty rather than being absent. A
    // driver then never has to ask whether there is a selection before asking
    // what it contains, and an archive that omits the key decodes to the same
    // thing a client that never set one gets.
    _testSelection = [[XCTTestSelection alloc] init];
    // Held as a block because that is what the property is: a client replaces
    // the generator to get a reproducible order without faking a seed, and a C
    // function pointer is not substitutable for one.
    _randomNumberGenerator = ^NSInteger {
        return XCTSeedableRandomNumberGenerator();
    };
    return self;
}

#pragma mark - Detaching from an IDE

/// Three assignments, in the order the reference makes them.
///
/// The order is not observable -- nothing here reads what it just wrote -- but
/// the set is. What comes off is exactly the reporting relationship: the
/// session that named the run, and the flag saying to report it to somebody.
/// What goes on is the flag saying to log instead, because a run that is no
/// longer being watched still has to be able to say what it did. Everything a
/// run needs in order to execute is untouched, which is the point: this is how
/// a configuration that was serialized by an IDE becomes usable again by
/// whoever deserialized it.
- (void)clearXcodeReportingConfiguration
{
    self.reportResultsToIDE = NO;
    self.sessionIdentifier = nil;
    self.emitOSLogs = YES;
}

#pragma mark - Derived properties

- (XCTTestIdentifierSet *)testIdentifiersToRun
{
    return self.testSelection.identifiersToRun;
}

- (XCTTestIdentifierSet *)testIdentifiersToSkip
{
    return self.testSelection.identifiersToSkip;
}

- (NSString *)testBundleName
{
    NSString *name = self.testBundleURL.lastPathComponent;
    if (name.length > 0) {
        return name;
    }
    name = self.testBundleRelativePath.lastPathComponent;
    if (name.length > 0) {
        return name;
    }
    // Nothing addressed the bundle at all, so the run is testing the process
    // that is running it. This mirrors the reference's fallthrough to
    // +[NSBundle xct_bundlePathForTestSuite], which is the same lookup against
    // the main bundle.
    return [self.class bundlePathForTestSuite:[NSBundle mainBundle].bundlePath].lastPathComponent;
}

- (XCTTestMode)testMode
{
    return self.initializeForUITesting ? XCTTestModeUITests : XCTTestModeUnitTests;
}

#pragma mark - Test bundle resolution

+ (NSString *)defaultBasePathForTestBundleResolution
{
    return [self defaultBasePathForTestBundleResolutionForMainBundlePath:[NSBundle mainBundle].bundlePath];
}

+ (NSString *)defaultBasePathForTestBundleResolutionForMainBundlePath:(NSString *)path
{
    return path.stringByDeletingLastPathComponent;
}

+ (NSString *)bundlePathForTestSuite:(NSString *)path
{
    if (path.length == 0) {
        return nil;
    }
    return path;
}

#pragma mark - Active configuration

static XCTestConfiguration *XCTActiveTestConfiguration = nil;

+ (XCTestConfiguration *)activeTestConfiguration
{
    return XCTActiveTestConfiguration;
}

+ (void)setActiveTestConfiguration:(XCTestConfiguration *)activeTestConfiguration
{
    // Held unretained-by-ARC-assignment through a strong static, so a
    // configuration that is still running cannot be torn down underneath the
    // tests reading it, and a run that has finished does not keep its whole
    // configuration alive for the life of the process.
    XCTActiveTestConfiguration = activeTestConfiguration;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // [self init], not [super init]. This is what the reference does -- a plain
    // objc_msgSend$init on self, with no msgSendSuper2 -- and it is load-bearing:
    // an archive is a *partial* description of a run, so every key the writer
    // chose to omit has to come back with the value -init would have given it. A
    // decoded configuration with no "sessionIdentifier" key would otherwise come
    // back with no session at all, and no way to tell such a run from any other.
    self = [self init];
    if (!self) {
        return nil;
    }

    NSSet *stringClasses = [NSSet setWithObjects:[NSString class], nil];
    NSSet *stringCollectionClasses = [NSSet setWithObjects:[NSString class], [NSArray class],
                                                        [NSDictionary class], nil];
    // A set of strings needs NSSet itself in the allowed classes, or the archive
    // this framework writes is one it cannot read: the unarchiver rejects the
    // value for being of a class the decoder did not permit, and the property
    // stays nil. The three NSSet properties below all decode through this.
    NSSet *setCollectionClasses = [NSSet setWithObjects:[NSString class], [NSSet class],
                                                       [NSArray class], [NSDictionary class], nil];

    // The selection, and the classes inside it. Not optional: the key is always
    // written, and an archive from a tool that predates it has to decode into a
    // run that executes everything rather than into one with no selection at all.
    // The whole set is named rather than just XCTTestSelection, because the
    // decoder is only permitted the classes it may actually find in the value --
    // a selection holds identifier sets, identifiers, and tag selections, each of
    // which holds NSSet and NSData, and naming only the outer class would leave
    // every one of them rejected.
    NSSet *selectionClasses = [NSSet setWithObjects:[XCTTestSelection class], [XCTTestIdentifierSet class],
                                                      [XCTTestIdentifier class], [XCTTagSelection class],
                                                      [XCTTag class], [NSSet class], [NSArray class],
                                                      [NSData class], [NSString class], nil];
    XCTTestSelection *testSelection = [coder decodeObjectOfClasses:selectionClasses forKey:@"testSelection"];
    if (testSelection) {
        self.testSelection = testSelection;
    }

    NSURL *testBundleURL = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSURL class], nil]
                                                forKey:@"testBundleURL"];
    if (testBundleURL) {
        self.testBundleURL = testBundleURL;
    }
    self.testBundleRelativePath = [coder decodeObjectOfClasses:stringClasses
                                                       forKey:@"testBundleRelativePath"];

    // Arguments and environment come before the reporting flags, and before the
    // session, because a configuration read from a plist is overwritten wholesale
    // by its caller anyway; the order here is kept to the reference's so a diff
    // between two dumps of the same key is readable.
    NSArray *targetApplicationArguments = [coder decodeObjectOfClasses:stringCollectionClasses
                                                               forKey:@"targetApplicationArguments"];
    if (targetApplicationArguments) {
        self.targetApplicationArguments = targetApplicationArguments;
    }
    NSDictionary *targetApplicationEnvironment = [coder decodeObjectOfClasses:stringCollectionClasses
                                                                      forKey:@"targetApplicationEnvironment"];
    if (targetApplicationEnvironment) {
        self.targetApplicationEnvironment = targetApplicationEnvironment;
    }

    self.reportResultsToIDE = [coder decodeBoolForKey:@"reportResultsToIDE"];
    self.testsDrivenByIDE = [coder decodeBoolForKey:@"testsDrivenByIDE"];
    // Absent from archives written before the flag existed, and the default is
    // YES, so this one is only taken when the key is actually there: decoding a
    // missing key as NO would silently turn parallelization off for every run
    // that did not know about the option.
    if ([coder containsValueForKey:@"inProcessParallelizationEnabled"]) {
        self.inProcessParallelizationEnabled = [coder decodeBoolForKey:@"inProcessParallelizationEnabled"];
    }
    // Not guarded, unlike the two keys above it. The reference decodes the
    // session unconditionally, so an archive that carries no session decodes to a
    // configuration with *no* session rather than one that quietly acquires -init's
    // UUID: a fabricated session would be indistinguishable from a real one, and
    // a session is what a report is filed under.
    self.sessionIdentifier = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSUUID class], nil]
                                                 forKey:@"sessionIdentifier"];
    self.disablePerformanceMetrics = [coder decodeBoolForKey:@"disablePerformanceMetrics"];
    self.treatMissingBaselinesAsFailures = [coder decodeBoolForKey:@"treatMissingBaselinesAsFailures"];

    NSURL *baselineFileURL = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSURL class], nil]
                                                 forKey:@"baselineFileURL"];
    if (baselineFileURL) {
        self.baselineFileURL = baselineFileURL;
    }
    self.baselineFileRelativePath = [coder decodeObjectOfClasses:stringClasses
                                                         forKey:@"baselineFileRelativePath"];
    self.targetApplicationPath = [coder decodeObjectOfClasses:stringClasses
                                                      forKey:@"targetApplicationPath"];
    self.targetApplicationBundleID = [coder decodeObjectOfClasses:stringClasses
                                                          forKey:@"targetApplicationBundleID"];

    NSDictionary *testApplicationDependencies = [coder decodeObjectOfClasses:stringCollectionClasses
                                                                      forKey:@"testApplicationDependencies"];
    if (testApplicationDependencies) {
        self.testApplicationDependencies = testApplicationDependencies;
    }
    NSSet *bundleIDsForCrashReportEmphasis = [coder decodeObjectOfClasses:setCollectionClasses
                                                                  forKey:@"bundleIDsForCrashReportEmphasis"];
    if (bundleIDsForCrashReportEmphasis) {
        self.bundleIDsForCrashReportEmphasis = bundleIDsForCrashReportEmphasis;
    }
    NSDictionary *testApplicationUserOverrides = [coder decodeObjectOfClasses:stringCollectionClasses
                                                                      forKey:@"testApplicationUserOverrides"];
    if (testApplicationUserOverrides) {
        self.testApplicationUserOverrides = testApplicationUserOverrides;
    }
    self.productModuleName = [coder decodeObjectOfClasses:stringClasses
                                                forKey:@"productModuleName"];
    self.reportActivities = [coder decodeBoolForKey:@"reportActivities"];
    self.testsMustRunOnMainThread = [coder decodeBoolForKey:@"testsMustRunOnMainThread"];
    self.initializeForUITesting = [coder decodeBoolForKey:@"initializeForUITesting"];

    // The three renamed multi-device keys. The old name is not an alias that gets
    // decoded; finding a value under it *is* the answer. Recovered from
    // -initWithCoder: -- each of the three is guarded by a probe of the old name
    // whose non-nil result short-circuits the read of the current name:
    //
    //   probe old name -> found ? YES : -decodeBoolForKey: with the current name
    //   probe old name -> found ? that value : -decodeObjectOfClass: current name
    //
    // So an archive written by the current encoder round-trips through the current
    // names, and an archive from before the rename is read through the old one.
    // -containsValueForKey: stands in for the reference's private
    // -objectForKeyedSubscript: probe. It answers about presence where the
    // reference answered about the value being non-nil, and the two differ only
    // for an archive carrying the old key explicitly set to NO -- which no writer
    // produces, since the reference never writes these keys at all.
    if ([coder containsValueForKey:@"XCTestConfiguration_initializeForMultiDevice"]) {
        self.initializeForMultiDevice = YES;
    } else {
        self.initializeForMultiDevice = [coder decodeBoolForKey:@"initializeForMultiDevice"];
    }
    if ([coder containsValueForKey:@"XCTestConfiguration_shouldExtractMultiDeviceRequirements"]) {
        self.shouldExtractMultiDeviceRequirements = YES;
    } else {
        self.shouldExtractMultiDeviceRequirements =
            [coder decodeBoolForKey:@"shouldExtractMultiDeviceRequirements"];
    }
    if ([coder containsValueForKey:@"XCTestConfiguration_multiDeviceRequirementsFilePath"]) {
        self.multiDeviceRequirementsFilePath =
            [coder decodeObjectOfClasses:stringClasses
                                  forKey:@"XCTestConfiguration_multiDeviceRequirementsFilePath"];
    } else {
        self.multiDeviceRequirementsFilePath = [coder decodeObjectOfClasses:stringClasses
                                                                    forKey:@"multiDeviceRequirementsFilePath"];
    }
    NSDictionary *multiDevicePlatformVersionMap = [coder decodeObjectOfClasses:stringCollectionClasses
                                                                        forKey:@"multiDevicePlatformVersionMap"];
    if (multiDevicePlatformVersionMap) {
        self.multiDevicePlatformVersionMap = multiDevicePlatformVersionMap;
    }
    self.gatherLocalizableStringsData = [coder decodeBoolForKey:@"gatherLocalizableStringsData"];
    self.automationFrameworkPath = [coder decodeObjectOfClasses:stringClasses
                                                      forKey:@"automationFrameworkPath"];
    self.emitOSLogs = [coder decodeBoolForKey:@"emitOSLogs"];
    self.systemAttachmentLifetime = [coder decodeIntegerForKey:@"systemAttachmentLifetime"];
    self.userAttachmentLifetime = [coder decodeIntegerForKey:@"userAttachmentLifetime"];
    self.preferredScreenCaptureFormat = [coder decodeIntegerForKey:@"preferredScreenCaptureFormat"];
    self.testExecutionOrdering = (XCTTestExecutionOrdering)[coder decodeIntegerForKey:@"testExecutionOrdering"];
    // Same reasoning as -inProcessParallelizationEnabled: zero is the default,
    // so an absent key has to stay zero rather than being read as "present".
    if ([coder containsValueForKey:@"leaksCheckingMode"]) {
        self.leaksCheckingMode = [coder decodeIntegerForKey:@"leaksCheckingMode"];
    }
    self.randomExecutionOrderingSeed = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSNumber class], nil]
                                                             forKey:@"randomExecutionOrderingSeed"];
    self.testTimeoutsEnabled = [coder decodeBoolForKey:@"testTimeoutsEnabled"];
    self.maximumTestExecutionTimeAllowance =
        [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSNumber class], nil]
                              forKey:@"maximumTestExecutionTimeAllowance"];
    self.defaultTestExecutionTimeAllowance =
        [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSNumber class], nil]
                              forKey:@"defaultTestExecutionTimeAllowance"];
    self.runAsMultiDeviceRemoteRunner = [coder decodeBoolForKey:@"runAsMultiDeviceRemoteRunner"];
    NSDictionary *multiDeviceRemoteRunnerPlatformMap =
        [coder decodeObjectOfClasses:stringCollectionClasses forKey:@"multiDeviceRemoteRunnerPlatformMap"];
    if (multiDeviceRemoteRunnerPlatformMap) {
        self.multiDeviceRemoteRunnerPlatformMap = multiDeviceRemoteRunnerPlatformMap;
    }
    NSSet *testInstructionsSet = [coder decodeObjectOfClasses:setCollectionClasses
                                                       forKey:@"testInstructionsSet"];
    if (testInstructionsSet) {
        self.testInstructionsSet = testInstructionsSet;
    }
    NSSet *symbolicationImageNames = [coder decodeObjectOfClasses:setCollectionClasses
                                                           forKey:@"symbolicationImageNames"];
    if (symbolicationImageNames) {
        self.symbolicationImageNames = symbolicationImageNames;
    }
    NSDictionary *applicationBundleInfos = [coder decodeObjectOfClasses:stringCollectionClasses
                                                                 forKey:@"ApplicationBundleInfos"];
    if (applicationBundleInfos) {
        self.applicationBundleInfos = applicationBundleInfos;
    }
    NSDictionary *performanceTestConfiguration = [coder decodeObjectOfClasses:stringCollectionClasses
                                                                       forKey:@"performanceTestConfiguration"];
    if (performanceTestConfiguration) {
        self.performanceTestConfiguration = performanceTestConfiguration;
    }
    self.enablePerformanceTestsDiagnostics =
        [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSNumber class], nil]
                              forKey:@"EnablePerformanceTestsDiagnostics"];
    // Traces used to be written under the property's own name. Read the new
    // spelling first and fall back, so neither an old plist nor a new one is
    // left with tracing silently off.
    NSNumber *traceCollectionEnabled =
        [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSNumber class], nil]
                              forKey:@"traceCollectionEnabled_v2"];
    if (!traceCollectionEnabled) {
        traceCollectionEnabled = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSNumber class], nil]
                                                        forKey:@"traceCollectionEnabled"];
    }
    self.traceCollectionEnabled = traceCollectionEnabled;

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    // The version marker is written first and read by nothing in the reference;
    // see the note on XCTestConfigurationFormatVersion in the header.
    [coder encodeObject:@(XCTestConfigurationFormatVersion) forKey:@"formatVersion"];

    [coder encodeObject:self.testBundleURL forKey:@"testBundleURL"];
    [coder encodeObject:self.testBundleRelativePath forKey:@"testBundleRelativePath"];
    [coder encodeObject:self.targetApplicationArguments forKey:@"targetApplicationArguments"];
    [coder encodeObject:self.targetApplicationEnvironment forKey:@"targetApplicationEnvironment"];
    [coder encodeBool:self.reportResultsToIDE forKey:@"reportResultsToIDE"];
    [coder encodeBool:self.testsDrivenByIDE forKey:@"testsDrivenByIDE"];
    [coder encodeBool:self.inProcessParallelizationEnabled forKey:@"inProcessParallelizationEnabled"];
    [coder encodeObject:self.sessionIdentifier forKey:@"sessionIdentifier"];
    [coder encodeBool:self.disablePerformanceMetrics forKey:@"disablePerformanceMetrics"];
    [coder encodeBool:self.treatMissingBaselinesAsFailures forKey:@"treatMissingBaselinesAsFailures"];
    [coder encodeObject:self.baselineFileURL forKey:@"baselineFileURL"];
    [coder encodeObject:self.baselineFileRelativePath forKey:@"baselineFileRelativePath"];
    [coder encodeObject:self.targetApplicationPath forKey:@"targetApplicationPath"];
    [coder encodeObject:self.targetApplicationBundleID forKey:@"targetApplicationBundleID"];
    [coder encodeObject:self.testApplicationDependencies forKey:@"testApplicationDependencies"];
    [coder encodeObject:self.bundleIDsForCrashReportEmphasis forKey:@"bundleIDsForCrashReportEmphasis"];
    [coder encodeObject:self.testApplicationUserOverrides forKey:@"testApplicationUserOverrides"];
    [coder encodeObject:self.productModuleName forKey:@"productModuleName"];
    [coder encodeBool:self.reportActivities forKey:@"reportActivities"];
    [coder encodeBool:self.testsMustRunOnMainThread forKey:@"testsMustRunOnMainThread"];
    [coder encodeBool:self.initializeForUITesting forKey:@"initializeForUITesting"];
    [coder encodeBool:self.initializeForMultiDevice forKey:@"initializeForMultiDevice"];
    [coder encodeBool:self.shouldExtractMultiDeviceRequirements forKey:@"shouldExtractMultiDeviceRequirements"];
    [coder encodeObject:self.multiDeviceRequirementsFilePath forKey:@"multiDeviceRequirementsFilePath"];
    [coder encodeObject:self.multiDevicePlatformVersionMap forKey:@"multiDevicePlatformVersionMap"];
    [coder encodeBool:self.gatherLocalizableStringsData forKey:@"gatherLocalizableStringsData"];
    [coder encodeObject:self.automationFrameworkPath forKey:@"automationFrameworkPath"];
    [coder encodeBool:self.emitOSLogs forKey:@"emitOSLogs"];
    [coder encodeInteger:self.systemAttachmentLifetime forKey:@"systemAttachmentLifetime"];
    [coder encodeInteger:self.userAttachmentLifetime forKey:@"userAttachmentLifetime"];
    [coder encodeInteger:self.preferredScreenCaptureFormat forKey:@"preferredScreenCaptureFormat"];
    [coder encodeInteger:self.testExecutionOrdering forKey:@"testExecutionOrdering"];
    [coder encodeInteger:self.leaksCheckingMode forKey:@"leaksCheckingMode"];
    // Written unconditionally, including when the selection is empty. An absent
    // key and a present-but-empty value are different instructions, and an
    // encoder that skipped the empty case would make "this run asked for no
    // tests in particular" and "this run was configured before selections
    // existed" encode to the same bytes.
    [coder encodeObject:self.testSelection forKey:@"testSelection"];
    [coder encodeObject:self.randomExecutionOrderingSeed forKey:@"randomExecutionOrderingSeed"];
    [coder encodeBool:self.testTimeoutsEnabled forKey:@"testTimeoutsEnabled"];
    [coder encodeObject:self.maximumTestExecutionTimeAllowance forKey:@"maximumTestExecutionTimeAllowance"];
    [coder encodeObject:self.defaultTestExecutionTimeAllowance forKey:@"defaultTestExecutionTimeAllowance"];
    [coder encodeBool:self.runAsMultiDeviceRemoteRunner forKey:@"runAsMultiDeviceRemoteRunner"];
    [coder encodeObject:self.multiDeviceRemoteRunnerPlatformMap forKey:@"multiDeviceRemoteRunnerPlatformMap"];
    [coder encodeObject:self.testInstructionsSet forKey:@"testInstructionsSet"];
    [coder encodeObject:self.symbolicationImageNames forKey:@"symbolicationImageNames"];
    [coder encodeObject:self.applicationBundleInfos forKey:@"ApplicationBundleInfos"];
    [coder encodeObject:self.performanceTestConfiguration forKey:@"performanceTestConfiguration"];
    [coder encodeObject:self.enablePerformanceTestsDiagnostics forKey:@"EnablePerformanceTestsDiagnostics"];
    [coder encodeObject:self.traceCollectionEnabled forKey:@"traceCollectionEnabled_v2"];

    // The run's base path is not part of the archive: it is where this process
    // happens to be, which is not a property of the run.
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    // A copy is a distinct configuration that says the same thing, so every
    // value is copied rather than the object graph being shared. A client that
    // narrows a copy's selection or changes its ordering must not change the
    // configuration the driver is holding.
    XCTestConfiguration *copy = [[XCTestConfiguration allocWithZone:zone] init];
    copy->_testSelection = [_testSelection copy];
    copy->_testBundleURL = [_testBundleURL copy];
    copy->_testBundleRelativePath = [_testBundleRelativePath copy];
    copy->_basePathForTestBundleResolution = [_basePathForTestBundleResolution copy];
    copy->_sessionIdentifier = [_sessionIdentifier copy];
    copy->_reportResultsToIDE = _reportResultsToIDE;
    copy->_testsDrivenByIDE = _testsDrivenByIDE;
    copy->_inProcessParallelizationEnabled = _inProcessParallelizationEnabled;
    copy->_reportActivities = _reportActivities;
    copy->_emitOSLogs = _emitOSLogs;
    copy->_gatherLocalizableStringsData = _gatherLocalizableStringsData;
    copy->_disablePerformanceMetrics = _disablePerformanceMetrics;
    copy->_treatMissingBaselinesAsFailures = _treatMissingBaselinesAsFailures;
    copy->_baselineFileURL = [_baselineFileURL copy];
    copy->_baselineFileRelativePath = [_baselineFileRelativePath copy];
    copy->_performanceTestConfiguration = [_performanceTestConfiguration copy];
    copy->_enablePerformanceTestsDiagnostics = _enablePerformanceTestsDiagnostics;
    copy->_targetApplicationPath = [_targetApplicationPath copy];
    copy->_targetApplicationBundleID = [_targetApplicationBundleID copy];
    copy->_targetApplicationArguments = [_targetApplicationArguments copy];
    copy->_targetApplicationEnvironment = [_targetApplicationEnvironment copy];
    copy->_testApplicationDependencies = [_testApplicationDependencies copy];
    copy->_testApplicationUserOverrides = [_testApplicationUserOverrides copy];
    copy->_bundleIDsForCrashReportEmphasis = [_bundleIDsForCrashReportEmphasis copy];
    copy->_productModuleName = [_productModuleName copy];
    copy->_initializeForUITesting = _initializeForUITesting;
    copy->_automationFrameworkPath = [_automationFrameworkPath copy];
    copy->_systemAttachmentLifetime = _systemAttachmentLifetime;
    copy->_userAttachmentLifetime = _userAttachmentLifetime;
    copy->_preferredScreenCaptureFormat = _preferredScreenCaptureFormat;
    copy->_testExecutionOrdering = _testExecutionOrdering;
    copy->_randomExecutionOrderingSeed = _randomExecutionOrderingSeed;
    copy->_randomNumberGenerator = [_randomNumberGenerator copy];
    copy->_leaksCheckingMode = _leaksCheckingMode;
    copy->_testTimeoutsEnabled = _testTimeoutsEnabled;
    copy->_defaultTestExecutionTimeAllowance = _defaultTestExecutionTimeAllowance;
    copy->_maximumTestExecutionTimeAllowance = _maximumTestExecutionTimeAllowance;
    copy->_traceCollectionEnabled = _traceCollectionEnabled;
    copy->_symbolicationImageNames = [_symbolicationImageNames copy];
    copy->_initializeForMultiDevice = _initializeForMultiDevice;
    copy->_shouldExtractMultiDeviceRequirements = _shouldExtractMultiDeviceRequirements;
    copy->_runAsMultiDeviceRemoteRunner = _runAsMultiDeviceRemoteRunner;
    copy->_multiDeviceRequirementsFilePath = [_multiDeviceRequirementsFilePath copy];
    copy->_multiDevicePlatformVersionMap = [_multiDevicePlatformVersionMap copy];
    copy->_multiDeviceRemoteRunnerPlatformMap = [_multiDeviceRemoteRunnerPlatformMap copy];
    copy->_testInstructionsSet = [_testInstructionsSet copy];
    copy->_applicationBundleInfos = [_applicationBundleInfos copy];
    return copy;
}

#pragma mark - Equality

/// -isEqual: treats nil and an empty collection as different, because they
/// answer different questions: "unset" and "set to nothing" are not the same
/// instruction to a run.
static BOOL XCTEqualObjects(id lhs, id rhs)
{
    if (lhs == rhs) {
        return YES;
    }
    if (lhs == nil || rhs == nil) {
        return NO;
    }
    return [lhs isEqual:rhs];
}

- (NSUInteger)hash
{
    // Three values, XORed, and deliberately fewer than -isEqual: compares. A
    // hash is a bucket selector, and a configuration is looked up by what it
    // runs and which session it is, not by every option it happens to carry.
    // Two equal configurations always produce the same value, which is the only
    // property the hash contract actually requires.
    //
    // The middle term is the test selection, which is the one of the three that
    // says which tests run -- so a cache keyed on this does not hand back the
    // results of a different selection. -testExecutionOrdering is *not* a
    // substitute for it and no longer appears here: a run that reorders the same
    // tests is a different configuration as far as -isEqual: is concerned, but it
    // is not a different set of results, and folding ordering into the hash would
    // make two identical runs land in different buckets for no gain.
    return self.testBundleURL.hash ^ self.sessionIdentifier.hash ^ self.testSelection.hash;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTestConfiguration class]]) {
        return NO;
    }
    XCTestConfiguration *other = object;
    // Every value that describes the run is compared, not just the ones that
    // pick a test: two configurations that would produce different results are
    // different configurations, and a caller comparing them to decide whether a
    // cached result is reusable has to be told no.
    // Both sides are read as ivars rather than through the accessors. Within the
    // class's own implementation -isEqual: is allowed to see another instance's
    // storage, and reading it directly keeps the comparison from re-entering
    // property machinery on a value that is already in hand.
#define XCT_CONFIG_MATCHES(flag, field) \
    do { if ((flag) != other->field) { return NO; } } while (0)
#define XCT_CONFIG_MATCHES_OBJECT(flag, field) \
    do { if (!XCTEqualObjects((flag), other->field)) { return NO; } } while (0)

    XCT_CONFIG_MATCHES_OBJECT(_testSelection, _testSelection);
    XCT_CONFIG_MATCHES_OBJECT(_testBundleURL, _testBundleURL);
    XCT_CONFIG_MATCHES_OBJECT(_testBundleRelativePath, _testBundleRelativePath);
    XCT_CONFIG_MATCHES_OBJECT(_sessionIdentifier, _sessionIdentifier);
    XCT_CONFIG_MATCHES_OBJECT(_baselineFileURL, _baselineFileURL);
    XCT_CONFIG_MATCHES_OBJECT(_baselineFileRelativePath, _baselineFileRelativePath);
    XCT_CONFIG_MATCHES_OBJECT(_targetApplicationPath, _targetApplicationPath);
    XCT_CONFIG_MATCHES_OBJECT(_targetApplicationBundleID, _targetApplicationBundleID);
    XCT_CONFIG_MATCHES_OBJECT(_testApplicationDependencies, _testApplicationDependencies);
    XCT_CONFIG_MATCHES_OBJECT(_bundleIDsForCrashReportEmphasis, _bundleIDsForCrashReportEmphasis);
    XCT_CONFIG_MATCHES_OBJECT(_testApplicationUserOverrides, _testApplicationUserOverrides);
    XCT_CONFIG_MATCHES_OBJECT(_productModuleName, _productModuleName);
    XCT_CONFIG_MATCHES_OBJECT(_targetApplicationArguments, _targetApplicationArguments);
    XCT_CONFIG_MATCHES_OBJECT(_targetApplicationEnvironment, _targetApplicationEnvironment);
    XCT_CONFIG_MATCHES_OBJECT(_performanceTestConfiguration, _performanceTestConfiguration);
    XCT_CONFIG_MATCHES_OBJECT(_enablePerformanceTestsDiagnostics, _enablePerformanceTestsDiagnostics);
    XCT_CONFIG_MATCHES_OBJECT(_traceCollectionEnabled, _traceCollectionEnabled);
    XCT_CONFIG_MATCHES_OBJECT(_symbolicationImageNames, _symbolicationImageNames);
    XCT_CONFIG_MATCHES_OBJECT(_testInstructionsSet, _testInstructionsSet);
    XCT_CONFIG_MATCHES_OBJECT(_applicationBundleInfos, _applicationBundleInfos);
    XCT_CONFIG_MATCHES_OBJECT(_multiDevicePlatformVersionMap, _multiDevicePlatformVersionMap);
    XCT_CONFIG_MATCHES_OBJECT(_multiDeviceRemoteRunnerPlatformMap, _multiDeviceRemoteRunnerPlatformMap);
    XCT_CONFIG_MATCHES_OBJECT(_multiDeviceRequirementsFilePath, _multiDeviceRequirementsFilePath);
    XCT_CONFIG_MATCHES_OBJECT(_automationFrameworkPath, _automationFrameworkPath);
    XCT_CONFIG_MATCHES_OBJECT(_randomExecutionOrderingSeed, _randomExecutionOrderingSeed);
    XCT_CONFIG_MATCHES_OBJECT(_defaultTestExecutionTimeAllowance, _defaultTestExecutionTimeAllowance);
    XCT_CONFIG_MATCHES_OBJECT(_maximumTestExecutionTimeAllowance, _maximumTestExecutionTimeAllowance);

    XCT_CONFIG_MATCHES(_reportResultsToIDE, _reportResultsToIDE);
    XCT_CONFIG_MATCHES(_testsDrivenByIDE, _testsDrivenByIDE);
    XCT_CONFIG_MATCHES(_inProcessParallelizationEnabled, _inProcessParallelizationEnabled);
    XCT_CONFIG_MATCHES(_reportActivities, _reportActivities);
    XCT_CONFIG_MATCHES(_emitOSLogs, _emitOSLogs);
    XCT_CONFIG_MATCHES(_gatherLocalizableStringsData, _gatherLocalizableStringsData);
    XCT_CONFIG_MATCHES(_disablePerformanceMetrics, _disablePerformanceMetrics);
    XCT_CONFIG_MATCHES(_treatMissingBaselinesAsFailures, _treatMissingBaselinesAsFailures);
    XCT_CONFIG_MATCHES(_testsMustRunOnMainThread, _testsMustRunOnMainThread);
    XCT_CONFIG_MATCHES(_initializeForUITesting, _initializeForUITesting);
    XCT_CONFIG_MATCHES(_initializeForMultiDevice, _initializeForMultiDevice);
    XCT_CONFIG_MATCHES(_shouldExtractMultiDeviceRequirements, _shouldExtractMultiDeviceRequirements);
    XCT_CONFIG_MATCHES(_runAsMultiDeviceRemoteRunner, _runAsMultiDeviceRemoteRunner);
    XCT_CONFIG_MATCHES(_testTimeoutsEnabled, _testTimeoutsEnabled);
    XCT_CONFIG_MATCHES(_systemAttachmentLifetime, _systemAttachmentLifetime);
    XCT_CONFIG_MATCHES(_userAttachmentLifetime, _userAttachmentLifetime);
    XCT_CONFIG_MATCHES(_preferredScreenCaptureFormat, _preferredScreenCaptureFormat);
    XCT_CONFIG_MATCHES(_testExecutionOrdering, _testExecutionOrdering);
    XCT_CONFIG_MATCHES(_leaksCheckingMode, _leaksCheckingMode);

#undef XCT_CONFIG_MATCHES
#undef XCT_CONFIG_MATCHES_OBJECT

    return YES;
}

#pragma mark - Description

- (NSString *)description
{
    NSMutableString *out = [NSMutableString stringWithFormat:@"<%@: %p", NSStringFromClass(self.class), self];
    // One field per line, the way the reference lays it out. A configuration is
    // dumped into a test log more often than it is read in a debugger, and a
    // run that is doing the wrong thing is usually a run with one surprising
    // field in it.
    [out appendFormat:@"\n\ttestBundleURL: %@", self.testBundleURL];
    [out appendFormat:@"\n\ttestBundleRelativePath: %@", self.testBundleRelativePath];
    [out appendFormat:@"\n\tproductModuleName: %@", self.productModuleName];
    [out appendFormat:@"\n\treportResultsToIDE: %@", self.reportResultsToIDE ? @"YES" : @"NO"];
    [out appendFormat:@"\n\ttestsDrivenByIDE: %@", self.testsDrivenByIDE ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tinProcessParallelizationEnabled: %@", self.inProcessParallelizationEnabled ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tsessionIdentifier: %@", self.sessionIdentifier];
    [out appendFormat:@"\n\tdisablePerformanceMetrics: %@", self.disablePerformanceMetrics ? @"YES" : @"NO"];
    [out appendFormat:@"\n\ttreatMissingBaselinesAsFailures: %@", self.treatMissingBaselinesAsFailures ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tbaselineFileURL: %@", self.baselineFileURL];
    [out appendFormat:@"\n\tbaselineFileRelativePath: %@", self.baselineFileRelativePath];
    [out appendFormat:@"\n\ttargetApplicationPath: %@", self.targetApplicationPath];
    [out appendFormat:@"\n\ttargetApplicationBundleID: %@", self.targetApplicationBundleID];
    [out appendFormat:@"\n\ttestApplicationDependencies: %@", self.testApplicationDependencies];
    [out appendFormat:@"\n\tbundleIDsForCrashReportEmphasis: %@", self.bundleIDsForCrashReportEmphasis];
    [out appendFormat:@"\n\ttestApplicationUserOverrides: %@", self.testApplicationUserOverrides];
    [out appendFormat:@"\n\ttargetApplicationArguments: %@",
                      [self.targetApplicationArguments componentsJoinedByString:@" "]];
    [out appendFormat:@"\n\ttargetApplicationEnvironment: %@", self.targetApplicationEnvironment];
    [out appendFormat:@"\n\treportActivities: %@", self.reportActivities ? @"YES" : @"NO"];
    [out appendFormat:@"\n\ttestsMustRunOnMainThread: %@", self.testsMustRunOnMainThread ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tinitializeForUITesting: %@", self.initializeForUITesting ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tinitializeForMultiDevice: %@", self.initializeForMultiDevice ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tshouldExtractMultiDeviceRequirements: %@",
                      self.shouldExtractMultiDeviceRequirements ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tmultiDevicePlatformVersionMap: %@", self.multiDevicePlatformVersionMap];
    [out appendFormat:@"\n\tmultiDeviceRequirementsFilePath: %@", self.multiDeviceRequirementsFilePath];
    [out appendFormat:@"\n\tgatherLocalizableStringsData: %@", self.gatherLocalizableStringsData ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tautomationFrameworkPath: %@", self.automationFrameworkPath];
    [out appendFormat:@"\n\temitOSLogs: %@", self.emitOSLogs ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tsystemAttachmentLifetime: %ld", (long)self.systemAttachmentLifetime];
    [out appendFormat:@"\n\tuserAttachmentLifetime: %ld", (long)self.userAttachmentLifetime];
    [out appendFormat:@"\n\tpreferredScreenCaptureFormat: %ld", (long)self.preferredScreenCaptureFormat];
    [out appendFormat:@"\n\ttestExecutionOrdering: %@", XCTTestExecutionOrderingToString(self.testExecutionOrdering)];
    [out appendFormat:@"\n\trandomExecutionOrderingSeed: %@", self.randomExecutionOrderingSeed];
    [out appendFormat:@"\n\tleaksCheckingMode: %@", @(self.leaksCheckingMode)];
    [out appendFormat:@"\n\ttestTimeoutsEnabled: %@", self.testTimeoutsEnabled ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tdefaultTestExecutionTimeAllowance: %@",
                      @(self.defaultTestExecutionTimeAllowance.doubleValue)];
    [out appendFormat:@"\n\tmaximumTestExecutionTimeAllowance: %@",
                      @(self.maximumTestExecutionTimeAllowance.doubleValue)];
    [out appendFormat:@"\n\ttraceCollectionEnabled: %@", self.traceCollectionEnabled];
    [out appendFormat:@"\n\tenablePerformanceTestsDiagnostics: %@", self.enablePerformanceTestsDiagnostics];
    [out appendFormat:@"\n\tsymbolicationImageNames: %@", [self.symbolicationImageNames allObjects]];
    [out appendFormat:@"\n\tapplicationBundleInfos: %@", self.applicationBundleInfos];
    [out appendFormat:@"\n\trunAsMultiDeviceRemoteRunner: %@", self.runAsMultiDeviceRemoteRunner ? @"YES" : @"NO"];
    [out appendFormat:@"\n\tmultiDeviceRemoteRunnerPlatformMap: %@", self.multiDeviceRemoteRunnerPlatformMap];
    [out appendFormat:@"\n\ttestInstructionsSet: %@", self.testInstructionsSet];
    // The selection, with a count rather than the whole list. A configuration is
    // often dumped with thousands of identifiers behind it, and the thing a
    // reader needs from a log line is whether the run was told to run anything
    // at all -- which the size answers and the list hides.
    [out appendFormat:@"\n\ttestSelection: %lu to run, %lu to skip",
                      (unsigned long)self.testIdentifiersToRun.count,
                      (unsigned long)self.testIdentifiersToSkip.count];
    [out appendString:@">"];
    return out;
}

@end
