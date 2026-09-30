// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestConfiguration: the value that a test run is configured with.
//
// This is a *private* header, which is where it lives in Apple's tree too. The
// public <XCTest/XCTest.h> never mentions a test configuration: the thing that
// describes a run is written by whoever starts the run -- the IDE, or the
// xctest(1) agent this framework also ships -- and read back by the framework
// the run executes in. Putting it in the public framework would make it part of
// the surface every test author compiles against, and Apple's own headers
// deliberately keep it out of that surface.
//
// Everything here is derived from the shipped XCTestCore binary rather than
// from a header, because no header for it exists to derive from. The parts that
// have not been derived yet are listed at the bottom of the interface and are
// simply absent: a property declared but not defined is a link error waiting
// for a caller, which is a worse failure than a property that is not there yet.

#import <Foundation/Foundation.h>

// The selection, because -testSelection below is typed as one. Imported rather
// than forward-declared: a forward declaration would leave -testIdentifiersToRun
// uncallable from outside the framework, since a client holding an
// XCTTestSelection could not ask it what it holds either. This is the layering
// the umbrella header describes -- a run is a configuration plus a selection --
// and it is why importing this header alone is enough to read a run's selection.
#import <XCTestCore/XCTTestSelection.h>

// NSUUID is declared inside the audited region below rather than here, because a
// declaration outside it has to spell out nullability at every pointer to satisfy
// -Wnullability-completeness, and this header is compiled with that warning as an
// error. The import above cannot move inside the region, which is the only reason
// it sits alone out here.

NS_ASSUME_NONNULL_BEGIN

// NSUUID, declared here rather than forward-declared: -sessionIdentifier below
// hands one back, and a client that wants to print or compare a run identifier
// needs -UUIDString, so a @class would make a public property uncallable from
// outside the framework.
//
// The reduced Internal SDK's Foundation has no <Foundation/NSUUID.h> at all, so
// the class itself has to be reintroduced. A full SDK ships the header, and
// redeclaring a class is a hard error, so the whole block is conditional.
#if !__has_include(<Foundation/NSUUID.h>)
@interface NSUUID : NSObject <NSCopying, NSSecureCoding>
+ (instancetype)UUID;
- (nullable instancetype)initWithUUIDString:(NSString *)string;
/// The canonical 8-4-4-4-12 uppercase form. This is the identity of the value:
/// two UUIDs are equal when this string matches, which is why it is also the
/// form a run identifier takes when it is logged or compared across processes.
@property (readonly, copy) NSString *UUIDString;
@end
#endif /* !__has_include(<Foundation/NSUUID.h>) */

/// Whether a run is driving unit tests or UI tests.
///
/// -[XCTestConfiguration testMode] is exactly this flag: the configuration
/// carries no separate mode, it derives the answer from -initializeForUITesting.
typedef NS_ENUM(NSInteger, XCTTestMode) {
    XCTTestModeUnitTests = 0,
    XCTTestModeUITests = 1,
};

/// How a run walks its test list.
typedef NS_ENUM(NSInteger, XCTTestExecutionOrdering) {
    /// The order the test list was built in. This is the default, and the only
    /// value a configuration starts out with.
    XCTTestExecutionOrderingDefault = 0,
    /// Shuffle the list, seeded by -randomExecutionOrderingSeed so a failing
    /// seed reproduces the same order.
    XCTTestExecutionOrderingRandom = 1,
};

/// The reference maps a raw ordering value to and from the string that appears
/// in a serialized configuration, and treats zero as "not set". An out-of-range
/// value raises NSInternalInconsistencyException -- which is what the reference's
/// NSAssertionHandler does with it -- rather than silently reading as default: a
/// typo in a hand-written config should be loud, not quiet.
FOUNDATION_EXPORT NSString *_Nonnull
XCTTestExecutionOrderingToString(XCTTestExecutionOrdering ordering);
FOUNDATION_EXPORT XCTTestExecutionOrdering
XCTTestExecutionOrderingFromString(NSString *_Nullable string);
FOUNDATION_EXPORT BOOL
XCTTestExecutionOrderingIsDefault(XCTTestExecutionOrdering ordering);

/// The serialized form of a configuration carries a version marker under the
/// "formatVersion" key. Nothing in the reference reads it back -- the only
/// reference to the key in the whole binary is the encode below -- so it exists
/// for tooling outside XCTestCore to recognise a blob it cannot otherwise
/// parse, and the value is therefore not observable from XCTest's own
/// behaviour. It is pinned here so the value written does not drift between
/// builds of ours, and will be replaced with the reference's constant if that
/// constant is ever recovered.
FOUNDATION_EXPORT NSInteger const XCTestConfigurationFormatVersion;

/// The number a configuration starts with, before a loader or a client sets
/// anything. A synthesized configuration is complete: it has a session and a
/// test selection, so a driver can run from it without any further setup.
@interface XCTestConfiguration : NSObject <NSSecureCoding, NSCopying>

/// The process-wide configuration the currently running tests were started
/// with, if there is one. Set once by the driver during -run, and cleared when
/// the run finishes, so code reached from a test case can read the run's
/// settings without threading the configuration through every call.
@property (class, nullable, nonatomic, strong) XCTestConfiguration *activeTestConfiguration;

/// The bundle to run. -testBundleName is derived from it.
@property (nullable, nonatomic, copy) NSURL *testBundleURL;
/// The bundle's location relative to the run's base path, for a run whose
/// bundle is not addressed absolutely.
@property (nullable, nonatomic, copy) NSString *testBundleRelativePath;
/// The bundle's file name, derived: the URL's last path component, else the
/// relative path's, else the main bundle's.
@property (nullable, nonatomic, readonly) NSString *testBundleName;
/// Where -testBundleRelativePath is resolved from, when the caller has
/// something specific in mind. Defaults to -defaultBasePathForTestBundleResolution.
@property (nullable, nonatomic, copy) NSString *basePathForTestBundleResolution;

/// Identifies this run. Every configuration is born with one, so two
/// configurations that differ only in when they were made are still distinct.
///
/// Nullable, and not merely for symmetry: a configuration that was not built by
/// an IDE has no session to belong to, and -clearXcodeReportingConfiguration
/// takes it away again on purpose. A nil here means "nobody is driving this
/// from outside", which is a real state and not a malformed one.
@property (nullable, nonatomic, copy) NSUUID *sessionIdentifier;

/// Where results go, and whether anything is driving the run from outside.
@property (nonatomic) BOOL reportResultsToIDE;
@property (nonatomic) BOOL testsDrivenByIDE;
@property (nonatomic) BOOL inProcessParallelizationEnabled;
@property (nonatomic) BOOL reportActivities;
@property (nonatomic) BOOL emitOSLogs;
@property (nonatomic) BOOL gatherLocalizableStringsData;
/// Whether every test in the run has to execute on the main thread. Not a
/// scheduling hint: it is the difference between a bundle whose tests may touch
/// UI at all and one that may not, so a client that needs the main thread has to
/// say so before the run starts.
@property (nonatomic) BOOL testsMustRunOnMainThread;

/// Performance measurement, and the baseline a measured run is compared to.
@property (nonatomic) BOOL disablePerformanceMetrics;
@property (nonatomic) BOOL treatMissingBaselinesAsFailures;
@property (nullable, nonatomic, copy) NSURL *baselineFileURL;
@property (nullable, nonatomic, copy) NSString *baselineFileRelativePath;
@property (nullable, nonatomic, copy) NSDictionary *performanceTestConfiguration;
@property (nullable, nonatomic, strong) NSNumber *enablePerformanceTestsDiagnostics;

/// The application under test, for a run that is not testing itself. All four
/// are optional: a unit-test bundle has no target application.
@property (nullable, nonatomic, copy) NSString *targetApplicationPath;
@property (nullable, nonatomic, copy) NSString *targetApplicationBundleID;
@property (nullable, nonatomic, copy) NSArray *targetApplicationArguments;
@property (nullable, nonatomic, copy) NSDictionary *targetApplicationEnvironment;

/// Extra bundles the run depends on, and per-bundle overrides the client wants
/// applied to the target application.
@property (nullable, nonatomic, copy) NSDictionary *testApplicationDependencies;
@property (nullable, nonatomic, copy) NSDictionary *testApplicationUserOverrides;
/// Bundle identifiers whose crashes are worth calling out on their own.
@property (nullable, nonatomic, copy) NSSet *bundleIDsForCrashReportEmphasis;

/// The Swift module the bundle's tests are written in, for a mixed-language
/// bundle whose names have to be resolved at runtime.
@property (nullable, nonatomic, copy) NSString *productModuleName;

/// UI testing, and the automation framework the UI side of the run uses.
@property (nonatomic) BOOL initializeForUITesting;
@property (nullable, nonatomic, copy) NSString *automationFrameworkPath;

/// Attachments: the two lifetimes are XCTAttachmentLifetime, and the capture
/// format is a screenshot format. All three are stored raw because they are
/// values that crossed a process boundary in a plist.
@property (nonatomic) NSInteger systemAttachmentLifetime;
@property (nonatomic) NSInteger userAttachmentLifetime;
@property (nonatomic) NSInteger preferredScreenCaptureFormat;

/// Test order, and the seed that makes a random order reproducible.
@property (nonatomic) XCTTestExecutionOrdering testExecutionOrdering;
@property (nullable, nonatomic, strong) NSNumber *randomExecutionOrderingSeed;
/// The generator -randomExecutionOrderingSeed is drawn from. Replaceable so a
/// client can get a reproducible order without a reproducible seed.
@property (nullable, nonatomic, copy) NSInteger (^randomNumberGenerator)(void);

/// Leak checking. The reference's own cases have not been recovered yet, so
/// this is the raw value: the reference stores it as an integer in the plist
/// and compares it against 1 and 2 when choosing a memory checker, and no
/// enumeration of it is derivable from the binary.
@property (nonatomic) NSInteger leaksCheckingMode;

/// Per-test time limits. -maximumTestExecutionTimeAllowance wins when both are
/// set; the other is what the whole run falls back to.
@property (nonatomic) BOOL testTimeoutsEnabled;
@property (nullable, nonatomic, copy) NSNumber *defaultTestExecutionTimeAllowance;
@property (nullable, nonatomic, copy) NSNumber *maximumTestExecutionTimeAllowance;

/// Tracing, and the images a crash has to be symbolicated against.
@property (nullable, nonatomic, strong) NSNumber *traceCollectionEnabled;
@property (nullable, nonatomic, copy) NSSet *symbolicationImageNames;

/// Multi-device, and the instruction bundles a distributed run is driven from.
@property (nonatomic) BOOL initializeForMultiDevice;
@property (nonatomic) BOOL shouldExtractMultiDeviceRequirements;
@property (nonatomic) BOOL runAsMultiDeviceRemoteRunner;
@property (nullable, nonatomic, copy) NSString *multiDeviceRequirementsFilePath;
@property (nullable, nonatomic, copy) NSDictionary *multiDevicePlatformVersionMap;
@property (nullable, nonatomic, copy) NSDictionary *multiDeviceRemoteRunnerPlatformMap;
@property (nullable, nonatomic, copy) NSSet *testInstructionsSet;
@property (nullable, nonatomic, copy) NSDictionary *applicationBundleInfos;

/// Unit tests or UI tests, decided by -initializeForUITesting.
@property (nonatomic, readonly) XCTTestMode testMode;

/// Which tests this run runs: the identifiers and tags to include, and the ones
/// to leave out. A synthesized configuration has one -- empty, meaning everything
/// -- so that "no selection was asked for" and "everything was asked for" are the
/// same run, and so a driver never has to test the property for nil first.
///
/// Non-null, and not merely because it is convenient: the loader hands this
/// across a process boundary, and an archive that omits the key has to decode
/// into a usable configuration rather than into one that crashes on first use.
@property (nonatomic, copy) XCTTestSelection *testSelection;

/// Forwarders onto -testSelection, because a caller deciding what runs almost
/// always wants the identifier lists on their own, and asking the selection
/// first costs two hops for an answer that is usually nil.
@property (nonatomic, readonly, copy) XCTTestIdentifierSet *testIdentifiersToRun;
@property (nonatomic, readonly, copy) XCTTestIdentifierSet *testIdentifiersToSkip;

/// Whether a configuration is complete enough to run from on its own.
@property (class, nonatomic, readonly) BOOL supportsSecureCoding;

/// The directory a relative test bundle path is resolved against by default:
/// the main bundle's own directory, so a run started from inside an
/// application finds its bundle next to itself.
@property (class, nonatomic, readonly) NSString *defaultBasePathForTestBundleResolution;
+ (nullable NSString *)defaultBasePathForTestBundleResolutionForMainBundlePath:(NSString *)path;

/// The name of a bundle sitting at -path, resolved the way a test run
/// resolves its own bundle.
+ (nullable NSString *)bundlePathForTestSuite:(NSString *)path;

/// Detaches the receiver from whatever IDE was driving the run that produced
/// it, and turns OS logging on.
///
/// This is what a configuration recovered from disk is given before it is used
/// on its own: the session it belonged to is over, results were being reported
/// to a client that is no longer there, and the only remaining audience for
/// what happens next is the log. It is a reset, not a query, and it is not
/// destructive -- everything the run needs to still work survives it.
- (void)clearXcodeReportingConfiguration;

// Not yet derived from the reference, and deliberately absent rather than
// declared and left undefined:
//
//   XCTRepetitionPolicy *repetitionPolicy     how many times to repeat a test.
//   XCTRuntimeDiagnosticsPolicy *runtimeDiagnosticsPolicy
//   XCTScreenCapturePolicy *effectiveScreenCapturePolicy
//   XCTAggregateSuiteRunStatistics *aggregateStatisticsBeforeCrash
//   XCTCapabilities *IDECapabilities
//
// A configuration built today starts with no selection, so it is not yet
// something a driver can run: the -run and -enumerate work that consumes it
// comes after this value type.

@end

NS_ASSUME_NONNULL_END
