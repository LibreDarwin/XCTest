// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestConfigurationLoader: the discovery chain that decides where a run's
// configuration comes from.
//
// Derived from the shipped XCTestCore binary rather than from a header, because
// the reference ships no header for this class. That constrains two things and
// both are visible below.
//
// The order of the sources is a fallback chain, and it is the whole contract:
//   1. XCTestConfigurationEncodedValueEnvironmentKey
//   2. XCTestConfigurationFilePath
//   3. the newest .xctestconfiguration directly in NSTemporaryDirectory()
//   4. the newest .xctest bundle under the main bundle's PlugIns, configured
//      from a .xctestconfiguration inside it or synthesized if it has none
// The environment is asked first because a run that was told exactly what to do
// must not be second-guessed by whatever a previous run left lying around. A
// source that answers "nothing" is not an error; it is how a run that was meant
// to be discovered gets discovered.
//
// What the loader does with what it finds differs by source, and the difference
// is the second thing the binary settles. Sources 1 and 2 were handed to this
// process, so their configuration is returned untouched. Sources 3 and 4 were
// found rather than given, so -clearXcodeReportingConfiguration runs first: a
// configuration nobody is driving must not report to a driver that is not there.
// Source 3 does that only once it has something to clear, and source 4 does it
// unconditionally, so a bundle carrying a configuration that cannot be decoded
// still ends up reporting to nobody.
//
// The reference's own plumbing is not reproduced, it is replaced. It asserts
// through XCTestFailureHandler, logs through XCTDefaultLog, and reads the
// current exception's reason through __XCTGetCurrentExceptionReasonWithFallback.
// None of those are reachable from a framework that links Foundation and nothing
// else, so the two that can be had locally are named for what they are (see
// below) and the assertion handler becomes the exception the handler would have
// raised. That last substitution is the one place where a reader should expect a
// difference from the reference rather than a bug: the reduced SDK declares
// NSAssertionFailure but does not export the symbol, so calling it compiles and
// then fails to link, and raising the exception directly is what that handler's
// own implementation does.

#import <XCTestCore/XCTestConfigurationLoader.h>

#import <Foundation/Foundation.h>
// Not pulled in by the reduced <Foundation/Foundation.h>, and both of the
// archive readers below are keyed-coding calls.
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSPropertyList.h>

#import <dispatch/dispatch.h>
#import <os/log.h>
#import <stdio.h>

#import "XCTestCoreFoundationCompat.h"

#pragma mark - Local plumbing for what this slice does not have

/// The reference's XCTDefaultLog, reproduced rather than imported: one lazily
/// created os_log under the same subsystem and category, so a run traced with
/// `log stream --predicate 'subsystem == "com.apple.dt.xctest"'` sees this
/// slice's lines in the same stream and the same category as the reference's.
///
/// The dispatch_once is not premature. os_log_create is a runtime lookup and
/// this runs on every load, including the once-per-process loads; the token is
/// file-static because a zeroed dispatch_once_t is what makes the "already done"
/// test work, and a global here would be something the loader had to zero.
static os_log_t _XCTLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.apple.dt.xctest", "Default");
    });
    return log;
}

/// The two log levels this slice uses, spelled so a call site keeps its format
/// string a literal.
///
/// os_log's own macros are the reason this is a macro and not a variadic
/// function. os_log_with_type _Static_asserts that its format is constant, and
/// that assertion is the feature: a format built at runtime is not a format, and
/// os_log encodes the format string into the binary so `log show` can decode a
/// message without re-deriving it. A variadic wrapper would have to hand
/// os_log_with_type a runtime NSString, which does not compile -- so the check
/// and the format both have to happen at the call site, and the only thing left
/// to wrap is the level check.
///
/// The reference reaches for the same shape from the other side: it has an
/// XCTDefaultLog for the normal level and a second entry point for failures,
/// where this has one macro per level.
#define _XCTDefaultLog(format, ...)                                             \
    do {                                                                        \
        os_log_t _xctLog = _XCTLog();                                           \
        if (os_log_type_enabled(_xctLog, OS_LOG_TYPE_DEFAULT)) {                \
            os_log(_xctLog, format, ##__VA_ARGS__);                             \
        }                                                                       \
    } while (0)

/// %public throughout, deliberately. The reference logs the configurations it
/// is handed, and a configuration names the bundle under test, its arguments and
/// its paths. Matching the reference's visibility is what makes a run traced
/// this way show the same information it showed there; a private-by-default
/// choice here would look more careful and be strictly less useful.
#define _XCTErrorLog(format, ...)                                              \
    do {                                                                        \
        os_log_t _xctLog = _XCTLog();                                           \
        if (os_log_type_enabled(_xctLog, OS_LOG_TYPE_ERROR)) {                  \
            os_log_error(_xctLog, format, ##__VA_ARGS__);                       \
        }                                                                       \
    } while (0)

/// The reason of the exception currently being handled.
///
/// The reference calls __XCTGetCurrentExceptionReasonWithFallback, which is
/// private to XCTest's assertion plumbing and not exported to a framework that
/// does not link XCTest. Every call site here is inside a @catch and only logs
/// the result, so a fallback would only ever have been an empty string;
/// +[NSException currentExceptionPointer] is the public spelling underneath that
/// helper, and -reason is what the helper goes on to read.
static NSString *_XCTCurrentExceptionReason(void)
{
    return [[NSException currentExceptionPointer] reason];
}

/// XCTestFailureHandler, locally.
///
/// The reference's -handleFailure: records the reason and raises
/// NSInternalInconsistencyException carrying it. What is reproduced here is the
/// raise, with the reason text passed through unchanged -- including the leading
/// space the reference's descriptions carry, since those strings end up in
/// diagnostics and a reason that has been trimmed is a reason that no longer
/// matches what the reference reported.
///
/// Apple's implementation prefixes the source location onto the reason. This one
/// does not, and cannot: the description is built by its caller, so there is no
/// line number to prefix it with, and inventing one would produce a diagnostic
/// pointing at a location the failure did not come from. The name and the text
/// are the parts a caller can observe.
static void _XCTFailureHandler(NSString *description)
{
    [[NSException exceptionWithName:NSInternalInconsistencyException
                              reason:description
                            userInfo:nil] raise];
}

/// The reference's parameter assertions, which go through the same handler and a
/// description naming the expression that failed.
///
/// Spelled out rather than inherited from NSParameterAssert for the reason the
/// handler is: NSAssert needs the symbol this SDK does not export, and
/// NSParameterAssert needs NSAssertionHandler, which the reduced
/// <Foundation/NSException.h> omits and which upstream declares inside
/// NSException.h rather than in a header of its own -- so no __has_include test
/// can tell the two SDKs apart. Raising the exception is what that handler would
/// have done.
///
/// A function rather than a macro wrapping one, because the reason is a full
/// expression at both call sites -- one interpolates a path, one is a bare nil
/// test -- and a macro would evaluate it twice.
#define _XCTParameterAssert(expression, description)                             \
    do {                                                                        \
        if (!(expression)) {                                                    \
            _XCTFailureHandler([NSString stringWithFormat:                        \
                                  @"Invalid parameter not satisfying: "          \
                                  description]);                                \
        }                                                                       \
    } while (0)

#pragma mark - Environment keys

/// The names the reference indexes into the process environment. The loader
/// reads five of them and they are not peers:
///
///   XCTestConfigurationEncodedValueEnvironmentKey, XCTestConfigurationFilePath
///     The two sources a run can be told about. Named here rather than in a
///     header because no header names them: they are the interface between this
///     process and whatever started it, and a client reproducing a run has to
///     spell them exactly as the reference does.
///
///   XCTestConfiguration_initializeForMultiDevice,
///   XCTestConfiguration_shouldExtractMultiDeviceRequirements,
///   XCTestConfiguration_multiDeviceRequirementsFilePath
///     Read while synthesizing, and read from the environment rather than from
///     the bundle: these describe the *runner's* circumstances, which a bundle on
///     disk knows nothing about. The names are the reference's, including its
///     lowerCamelCase, because they are looked up as strings and a tidier
///     spelling would find nothing.
static NSString *const XCTestConfigurationEncodedValueEnvironmentKey =
    @"XCTestConfigurationEncodedValueEnvironmentKey";
static NSString *const XCTestConfigurationFilePath = @"XCTestConfigurationFilePath";
static NSString *const XCTestConfigurationInitializeForMultiDeviceKey =
    @"XCTestConfiguration_initializeForMultiDevice";
static NSString *const XCTestConfigurationShouldExtractMultiDeviceRequirementsKey =
    @"XCTestConfiguration_shouldExtractMultiDeviceRequirements";
static NSString *const XCTestConfigurationMultiDeviceRequirementsFilePathKey =
    @"XCTestConfiguration_multiDeviceRequirementsFilePath";

/// The one multi-device-adjacent input that does come from the bundle: whether
/// this bundle holds UI tests is a fact about what is inside it, so it is read
/// out of the Info.plist rather than out of the environment.
static NSString *const XCTContainsUITestsInfoDictionaryKey = @"XCTContainsUITests";

/// NSDataReadingUncached, spelled as its value because the reduced SDK omits
/// NSDataReadingOptions. 2 is the value upstream gives it and the value has not
/// moved: NSDataReadingMutableContainers is 1, so the cached read is 0 and
/// uncached is 1 << 1.
///
/// Uncached is right on its own terms before worrying about matching the
/// reference. The file is read once, by the process that is about to obey it,
/// and there is no second reader to save a syscall for. It also cannot go stale,
/// which is the argument that actually settles it: a cached read is a read of
/// whatever was there when the entry was made, and that is not a question this
/// process can answer about a file it has not read yet.
static const NSUInteger XCTDataReadingUncached = 2;

#pragma mark - Identifier parsing

/// The error a scope that does not parse produces, in the reference's own domain
/// and code.
///
/// The domain and the code are what a client switches on, so they are recovered
/// rather than chosen: a caller written against the reference to filter out its
/// own typos has to keep working, and a new domain would turn every such check
/// into a silent pass.
static NSString *const XCTestErrorDomain = @"com.apple.XCTestErrorDomain";
static const NSInteger XCTestInvalidTestIdentifierErrorCode = -500;

#pragma mark - XCTestConfigurationLoader

@implementation XCTestConfigurationLoader

#pragma mark - Scope parsing

/// Builds the selection a scope names.
///
/// An empty collection is not an error and produces an empty set, which is what
/// a scope file with no XCTestScope key means. That falls out of the loop rather
/// than being checked for: the reference hands the value straight to the builder,
/// and a nil or empty collection enumerates as no iterations.
+ (nullable XCTTestIdentifierSet *)testIdentifierSetForIdentifiers:(NSArray<NSString *> *)identifiers
                                                            outError:(NSError **)outError
{
    XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
    for (NSString *identifier in identifiers) {
        // includingSwiftCounterpart:NO, and this is not a simplification. A Swift
        // Testing test and the Objective-C test it corresponds to are one name
        // spelled two ways, and a selection that reached here has already been
        // narrowed to one runner by whatever wrote it. Adding both would put two
        // identifiers in a set that asked for one, and a run would execute a
        // test the caller did not name.
        if (![builder addTestIdentifiersForStringRepresentation:identifier
                                       includingSwiftCounterpart:NO]) {
            if (outError) {
                *outError = [NSError errorWithDomain:XCTestErrorDomain
                                                 code:XCTestInvalidTestIdentifierErrorCode
                                             userInfo:@{
                                                 NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Invalid test identifier: %@",
                                                                                identifier]
                                             }];
            }
            return nil;
        }
    }
    return builder.testIdentifierSet;
}

/// The keys a scope can be named by, in one place because the two spellings of
/// each are not interchangeable and the callers below mix them freely.
static NSString *const XCTestScopeFileKey = @"XCTestScopeFile";
static NSString *const XCTestScopeKey = @"XCTestScope";
static NSString *const XCTestInvertScopeKey = @"XCTestInvertScope";
/// The scope in a defaults domain is named `XCTest`, not `XCTestScope`. The two
/// keys are one character apart, `XCTestScope` belongs to the *plist inside* a
/// scope file, and confusing them is silent: a defaults value of `All` becomes a
/// key nothing reads, so a run ignores the scope it was given and runs
/// everything. Hence the separate constant rather than a reused one.
static NSString *const XCTestScopeDefaultsKey = @"XCTest";

/// The error an unexpected command line produces. The reference's domain and
/// code are recovered, for the reason given on XCTestErrorDomain above: a caller
/// filtering on them has to keep working.
static NSString *const XCTCommandLineToolDomain = @"XCTCommandLineToolDomain";
static const NSInteger XCTUnrecognizedArgumentErrorCode = 3;

/// Applies the scope settings a run's start-up arguments and defaults asked for.
///
/// The two real sources are not the same shape, and that is the thing most likely
/// to be got wrong by anyone reading only one of them. A scope *file* names its
/// identifiers as an array, handed to the builder element by element -- it is not
/// split on commas. The `XCTest` defaults value is one string and *is* split. The
/// two spellings converge at +testIdentifierSetForIdentifiers:outError:, which is
/// why a file's array is not split a second time on its way there.
///
/// A file wins over a defaults value because a file is a deliberate act and a
/// defaults value is a leftover, and the inversion is read from the same place as
/// the scope: a scope file with no XCTestInvertScope key is *not* inverted by a
/// defaults key that happens to be set. Reading the inversion from both would let
/// a leftover override a deliberate act, which is the whole reason the file wins.
+ (BOOL)applySettingsFromUserDefaultsIfApplicable:(NSUserDefaults *)userDefaults
                             commandLineArguments:(NSArray<NSString *> *)commandLineArguments
                               testConfiguration:(XCTestConfiguration *)testConfiguration
                                        outError:(NSError **)outError
{
    // Which of the two lists is being filled in. Inverted is decided per source
    // below rather than once here, because a file and a defaults value can
    // disagree about it and the source that supplied the scope supplies the
    // inversion.
    XCTTestIdentifierSet *identifiersToRun = nil;
    XCTTestIdentifierSet *identifiersToSkip = nil;
    BOOL didApplyAnyScope = NO;

    NSString *scopeFilePath = [userDefaults stringForKey:XCTestScopeFileKey];
    if (scopeFilePath) {
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:scopeFilePath
                                              options:XCTDataReadingUncached
                                                error:&error];
        if (!data) {
            _XCTFailureHandler([NSString stringWithFormat:
                                    @" Failed to read data from path '%@', error: %@",
                                    scopeFilePath, error.localizedDescription]);
            return NO;
        }
        NSPropertyListFormat format = 0;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                            options:0
                                                             format:&format
                                                              error:&error];
        if (!plist) {
            _XCTFailureHandler([NSString stringWithFormat:
                                    @" Failed to deserialize data from path '%@' as a property list, "
                                    @"error: %@",
                                    scopeFilePath, error.localizedDescription]);
            return NO;
        }
        if (![plist isKindOfClass:[NSDictionary class]]) {
            _XCTFailureHandler([NSString stringWithFormat:
                                    @" Invalid (non-NSDictionary) class %@ for property list at path '%@'",
                                    NSStringFromClass([plist class]), scopeFilePath]);
            return NO;
        }
        // The array, passed through whole. No split, no All/None/Self special
        // case: a scope file is a different spelling of a scope, not a different
        // kind of scope, and a file that wants every test says so with an
        // identifier that matches them all.
        XCTTestIdentifierSet *identifiers = [self testIdentifierSetForIdentifiers:plist[XCTestScopeKey]
                                                                          outError:outError];
        if (!identifiers) {
            return NO;
        }
        if ([plist[XCTestInvertScopeKey] boolValue]) {
            identifiersToSkip = identifiers;
        } else {
            identifiersToRun = identifiers;
        }
        didApplyAnyScope = YES;
    } else {
        NSString *scope = [userDefaults stringForKey:XCTestScopeDefaultsKey];
        if (scope) {
            // An empty string is present and is not absent. It falls through to
            // the split below and produces one empty component, which the
            // builder rejects -- and that is the right answer: a defaults domain
            // with XCTest set to nothing named a scope and named it wrong, which
            // is a different bug from having no opinion at all.
            if ([scope isEqualToString:@"All"]) {
                didApplyAnyScope = YES;
            } else if ([scope isEqualToString:@"None"] || [scope isEqualToString:@"Self"]) {
                // stderr rather than the log, because what is deprecated is
                // something a person typed into a defaults domain or a command
                // line, and the person who typed it is the one who can fix it.
                // The reference's text, including the trailing blank line: it is
                // two sentences, and the second is what a reader needs.
                fprintf(stderr, "'%s' is a deprecated scope option; falling back to 'All' behavior.\n\n",
                        scope.UTF8String);
                didApplyAnyScope = YES;
            } else {
                XCTTestIdentifierSet *identifiers =
                    [self testIdentifierSetForIdentifiers:[scope componentsSeparatedByString:@","]
                                                  outError:outError];
                if (!identifiers) {
                    return NO;
                }
                if ([userDefaults boolForKey:XCTestInvertScopeKey]) {
                    identifiersToSkip = identifiers;
                } else {
                    identifiersToRun = identifiers;
                }
                didApplyAnyScope = YES;
            }
        }
    }

    // Only consulted when neither source named a scope. A process started with
    // more arguments than the loader expects reports the extra one rather than
    // running everything, because the extra argument was almost certainly meant
    // to narrow the run and silently ignoring it is how a suite runs green by
    // accident. The argument array is 0-based, so element 0 is the program and
    // element 1 is the first real argument -- but the threshold is three, meaning
    // two real arguments, and it is element 1 that gets reported. Both of those
    // are the reference's, and a caller filtering on the error has to see the
    // same message the runs it reproduces produced.
    if (!didApplyAnyScope && commandLineArguments.count >= 3) {
        if (outError) {
            *outError = [NSError errorWithDomain:XCTCommandLineToolDomain
                                             code:XCTUnrecognizedArgumentErrorCode
                                         userInfo:@{
                                             NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"Unrecognized argument: %@",
                                                                            commandLineArguments[1]]
                                         }];
        }
        return NO;
    }

    // Through the selection rather than through -testIdentifiersToRun, which is
    // a read-only forwarder onto it. The selection is non-null on any
    // configuration that came out of -init or a decoder, so this is not a nil
    // check; the nil guards above are the ones that matter, and they are there
    // because "no scope was named" and "the scope named nothing" are different
    // runs. Assigning only what was actually parsed is what leaves the other
    // list alone: an inverted scope sets the skip list and must not clear the run
    // list the configuration arrived with.
    if (identifiersToRun) {
        testConfiguration.testSelection.identifiersToRun = identifiersToRun;
    }
    if (identifiersToSkip) {
        testConfiguration.testSelection.identifiersToSkip = identifiersToSkip;
    }
    return YES;
}

- (instancetype)initWithTestConfigurationURLFromEnvironment:(nullable NSURL *)testConfigurationURL
                                  encodedEnvironmentValue:(nullable NSString *)encodedValue
{
    self = [super init];
    if (!self) {
        return nil;
    }
    // Through the properties rather than the ivars, because they are atomic copy
    // properties and a direct ivar write would skip both the copy and the lock.
    // The values are the environment's, and an environment value is a string
    // somebody else may still be holding: copying is what makes the loader's copy
    // independent of that.
    self.testConfigurationURLFromEnvironment = testConfigurationURL;
    self.testConfigurationEncodedValueFromEnvironment = encodedValue;
    return self;
}

- (instancetype)init
{
    // The environment is read once, because it is a snapshot: this cannot
    // observe a change between two lookups, so reading it once says something
    // true and reading it twice would only cost a dictionary copy.
    NSDictionary<NSString *, NSString *> *environment = [NSProcessInfo processInfo].environment;
    // Encoded value first, file path second, which is the reference's order and
    // is not alphabetical.
    NSString *encodedValue = environment[XCTestConfigurationEncodedValueEnvironmentKey];
    NSString *path = environment[XCTestConfigurationFilePath];
    // No validation, and specifically no empty-string check. +fileURLWithPath:
    // answers nil for an empty path rather than a URL naming the working
    // directory, so an empty XCTestConfigurationFilePath stores no URL and this
    // loader is back to having no source named -- the same state as an unset
    // variable. That is what the reference does, and the alternative would be to
    // keep the empty string as a URL that cannot be read, a distinction with no
    // consequence behind it.
    NSURL *url = path ? [NSURL fileURLWithPath:path] : nil;
    return [self initWithTestConfigurationURLFromEnvironment:url
                                     encodedEnvironmentValue:encodedValue];
}

- (nullable XCTestConfiguration *)loadTestConfiguration
{
    XCTestConfiguration *configuration = nil;

    // 1. The encoded value. Decoded before the path, so a run handed a blob
    //    somewhere with no filesystem -- a multi-device runner on another
    //    machine -- never consults a path it cannot have.
    NSString *encodedValue = self.testConfigurationEncodedValueFromEnvironment;
    if (encodedValue) {
        configuration = [self _testConfigurationFromEncodedValue:encodedValue];
        if (configuration) {
            // Returned exactly as it came. No settings and no reporting reset: the
            // process that wrote this blob is still running and is still the
            // authority on what runs, so narrowing it here would fight whoever
            // handed it over. Sources 3 and 4 are the opposite case -- nobody is
            // left to object -- which is why the difference is drawn here and not
            // in a shared helper.
            _XCTDefaultLog("Running with discovered configuration %{public}@", configuration);
            return configuration;
        }
    }

    // 2. The path. A separate if and not an else-if, and that is the load-bearing
    //    detail of the whole chain: a value that was present and did not decode
    //    falls through to the next source rather than ending it. Anything else
    //    would turn a truncated environment into a run that quietly uses
    //    whatever a previous run left behind.
    NSURL *url = self.testConfigurationURLFromEnvironment;
    if (url) {
        configuration = [self _testConfigurationFromEnvironmentURL:url];
        if (configuration) {
            // Untouched for the same reason as source 1 above.
            _XCTDefaultLog("Running with discovered configuration %{public}@", configuration);
            return configuration;
        }
    }

    // 3. The newest configuration a previous run left in the temporary
    //    directory. This is what makes an interrupted run resumable, and it is
    //    also the source that most deserves distrust: nothing guarantees the
    //    file there belongs to a run that is still happening.
    NSURL *temporaryDirectory = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSURL *temporaryConfigurationURL =
        [self _mostRecentFileInDirectory:temporaryDirectory withExtension:@"xctestconfiguration"];
    if (temporaryConfigurationURL) {
        configuration = [self _testConfigurationFromURL:temporaryConfigurationURL];
        if (configuration) {
            // Reset only now, and only because there is something to reset.
            [configuration clearXcodeReportingConfiguration];
            _XCTDefaultLog("Found most recent test configuration at %{public}@:\n%{public}@",
                           temporaryConfigurationURL, configuration);
            [self _applyDiscoveredSettingsToConfiguration:configuration];
            return configuration;
        }
    }

    // 4. The newest test bundle installed into this process, and whatever
    //    configuration it carries. The clear below is unconditional, which
    //    differs from source 3 on purpose: a bundle carrying a configuration
    //    nobody can decode has still been found rather than told, so it must
    //    still not report. Sending the message to nil is what the reference's
    //    message to a nil configuration does.
    NSBundle *bundle = [self _mostRecentTestBundle];
    if (bundle) {
        _XCTDefaultLog("Found most recent test bundle at %{public}@", bundle.bundleURL);
        configuration = [self _configurationForTestBundle:bundle];
        [configuration clearXcodeReportingConfiguration];
        if (configuration) {
            _XCTDefaultLog("Running with configuration %{public}@", configuration);
            [self _applyDiscoveredSettingsToConfiguration:configuration];
        }
    }

    return configuration;
}

/// Applies the settings to a configuration that was found rather than handed
/// over, and deliberately ignores the answer.
///
/// Two things are being decided and only the first is interesting. The settings
/// are applied so that a scope written into a defaults domain, or left in a
/// file, narrows a discovered run -- otherwise a run that found its
/// configuration by looking would ignore everything the person who started it
/// asked for. The result is discarded because there is nobody to report a
/// failure to: this method returns a configuration or nil, and conflating "the
/// settings were not understood" with "there was no configuration" would make an
/// unparseable scope look like a failed run.
- (void)_applyDiscoveredSettingsToConfiguration:(XCTestConfiguration *)configuration
{
    (void)[XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                                          commandLineArguments:@[]
                                                            testConfiguration:configuration
                                                                     outError:NULL];
}

- (nullable XCTestConfiguration *)loadTestConfigurationFromEnvironmentWithDidSpecify:(nullable BOOL *)didSpecify
{
    if (didSpecify) {
        // Whether the environment *named* a source, not whether that source
        // produced anything. The distinction is the point of the out-parameter: a
        // driver handed a configuration URL has to be able to report "the one you
        // gave me did not load" separately from "you gave me nothing", and only
        // the first is worth failing over.
        *didSpecify = self.testConfigurationURLFromEnvironment != nil;
    }
    NSURL *url = self.testConfigurationURLFromEnvironment;
    if (!url) {
        return nil;
    }
    // No fallback and no settings, unlike -loadTestConfiguration. A caller that
    // asked for the environment specifically already knows what it wants, and
    // giving it a guess would be a guess it has no way to check.
    return [self _testConfigurationFromEnvironmentURL:url];
}

/// Reads the URL the environment named, resolving a relative one first.
///
/// Relative resolution is not decoration. The reference's XCTestConfigurationFilePath
/// is written as a path relative to whatever directory the run was started from,
/// and a run started somewhere else would otherwise look in the wrong place and
/// find nothing -- which is indistinguishable, from the outside, from a
/// configuration that was never written.
- (nullable XCTestConfiguration *)_testConfigurationFromEnvironmentURL:(NSURL *)URL
{
    // The reference names the caller's variable here, not this method's parameter:
    // the assertion text is part of the contract, and a failure message saying
    // "URL != nil" tells the reader nothing about which of the four sources failed
    // to name itself.
    _XCTParameterAssert(URL != nil, @"configurationFileURLFromEnvironment != nil");
    // The question is whether -path is already a filesystem path from the root, and
    // not whether the URL looks absolute, because +[NSURL fileURLWithPath:] has
    // already resolved a relative path against the working directory. All that is
    // left is a URL built some other way -- URLWithString:, most often -- whose
    // -path is whatever the caller wrote.
    NSString *path = URL.path;
    if (path != nil && ![path isAbsolutePath]) {
        URL = [NSURL fileURLWithPath:[NSFileManager.defaultManager.currentDirectoryPath
                                       stringByAppendingPathComponent:path]];
        path = URL.path;
    }
    if (path == nil || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        _XCTErrorLog("Unable to read test configuration file %{public}@", URL);
        return nil;
    }
    return [self _testConfigurationFromURL:URL];
}

/// Decodes a base64 configuration blob.
///
/// The base64 step is separate from the unarchive step, and the split is what
/// makes the two failures distinguishable: a blob that is not base64 never
/// reaches the unarchiver, and saying so is more useful than a decode error
/// about bytes that were never an archive.
- (nullable XCTestConfiguration *)_testConfigurationFromEncodedValue:(NSString *)value
{
    _XCTParameterAssert(value != nil, @"value != nil");
    // Options 0 rather than NSDataBase64DecodingIgnoreUnknownCharacters: a
    // configuration that needs forgiving was not produced by the reference, and
    // silently skipping the character that is wrong would decode a different
    // configuration than the one that was encoded.
    NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:0];
    if (!data) {
        // The error slot is nil, and the reference logs it as one: the base64
        // initializer's failure has no NSError to hand back. The log is still
        // worth having -- it names the value that failed, which is the only thing
        // that identifies the run.
        _XCTErrorLog("Unable to load configuration data from specified environment value %{public}@; error: %{public}@",
                     value, nil);
        return nil;
    }
    return [self _testConfigurationFromData:data source:nil];
}

/// Reads a configuration file.
///
/// @try is around the unarchive only, not around the file read: a file that
/// cannot be opened is an ordinary failure with an error to report, while a
/// malformed archive raises from inside NSKeyedUnarchiver and would otherwise
/// unwind out of a loader whose job is to answer "no configuration" for anything
/// it cannot use.
- (nullable XCTestConfiguration *)_testConfigurationFromURL:(NSURL *)URL
{
    _XCTParameterAssert(URL != nil, @"URL != nil");
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:&error];
    if (!data) {
        _XCTErrorLog("Unable to load configuration data from specified path %{public}@; error: %{public}@",
                     URL, error.localizedDescription);
        return nil;
    }
    return [self _testConfigurationFromData:data source:URL];
}

/// The unarchive, shared by the file and the blob paths.
///
/// The reference calls the two-argument +[NSKeyedUnarchiver
/// unarchivedObjectOfClass:fromData:] spelling, which returns nil and writes
/// nothing on failure. The public three-argument form is used here and its error
/// is ignored, which is the same observable behaviour: a configuration that
/// cannot be decoded is reported as no configuration at all, and no message is
/// written, because the reference writes none.
///
/// The two paths are told apart by `source`, which is the URL for a file and nil
/// for a blob. It exists only so the two catch handlers can name which one
/// happened; one unarchive serving both sources, with a message that had to
/// guess, would be less honest about a failure than two log lines.
- (nullable XCTestConfiguration *)_testConfigurationFromData:(NSData *)data
                                                      source:(nullable NSURL *)source
{
    XCTestConfiguration *configuration = nil;
    @try {
        NSError *error = nil;
        configuration = [NSKeyedUnarchiver unarchivedObjectOfClass:[XCTestConfiguration class]
                                                          fromData:data
                                                             error:&error];
        (void)error;
    } @catch (NSException *exception) {
        // The caught exception is unused: the reason is read back off the current
        // exception rather than taken from the binding, which is what the
        // reference's helper does and what makes this identical when the
        // unarchiver re-raises something of its own.
        (void)exception;
        if (source) {
            _XCTErrorLog("Exception decoding test configuration data: %{public}@",
                         _XCTCurrentExceptionReason());
        } else {
            _XCTErrorLog("Exception decoding environment test configuration data: %{public}@",
                         _XCTCurrentExceptionReason());
        }
        return nil;
    }
    return configuration;
}

/// The newest file with a given extension, directly inside a directory.
///
/// Directly, not recursively, and that is why both callers pass the directory
/// they mean rather than a search root: NSTemporaryDirectory is full of
/// directories holding configuration files that belong to *other* runs, and a
/// recursive search would hand this run someone else's configuration.
///
/// A fresh NSFileManager rather than +defaultManager. The reference does this
/// and there is no reason for it in a single-threaded read -- the manager is
/// stateless for this -- but a manager can carry delegate state, and a private one
/// cannot be pointed somewhere by a client that installed a delegate on the
/// shared one.
///
/// Errors are ignored, and a directory that cannot be listed is treated as one
/// with nothing in it. That is the same answer as a directory that is not there,
/// and both are ordinary: the temporary directory does not exist before anything
/// has written to it.
- (nullable NSURL *)_mostRecentFileInDirectory:(NSURL *)directory
                                 withExtension:(NSString *)extension
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSError *error = nil;
    NSArray<NSURL *> *contents = [fileManager contentsOfDirectoryAtURL:directory
                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                             options:0
                                                               error:&error];
    (void)error;
    if (!contents) {
        return nil;
    }

    // distantPast rather than nil, so the first candidate always wins. nil would
    // make the comparison below a comparison against nothing, and "newest of no
    // files" has to stay distinguishable from "newest of some files, none newer
    // than the start of time".
    NSDate *mostRecentDate = [NSDate distantPast];
    NSURL *mostRecentURL = nil;
    for (NSURL *URL in contents) {
        if (![URL.pathExtension isEqualToString:extension]) {
            continue;
        }
        // A date that could not be read is skipped rather than treated as
        // oldest. The reference checks for nil before comparing, and the
        // difference matters: a file whose date is unreadable is not evidence of
        // being recent, but it is not evidence of being stale either, so letting
        // it into the comparison would let a nil beat a real date.
        id value = nil;
        if (![URL getResourceValue:&value forKey:NSURLContentModificationDateKey error:NULL]) {
            continue;
        }
        if (![value isKindOfClass:[NSDate class]]) {
            continue;
        }
        NSDate *date = value;
        // Strictly descending, so two files with the same modification date keep
        // the one enumerated first. That tie-break is the reference's and it is
        // not arbitrary: directory enumeration order is stable for a directory
        // that is not being written to, so a tie resolves the same way twice and
        // a resumed run picks up the configuration it picked up last time.
        if ([date compare:mostRecentDate] == NSOrderedDescending) {
            mostRecentDate = date;
            mostRecentURL = URL;
        }
    }
    return mostRecentURL;
}

/// The newest test bundle installed into this process, if any.
- (nullable NSBundle *)_mostRecentTestBundle
{
    NSURL *plugInsURL = [NSBundle mainBundle].builtInPlugInsURL;
    if (!plugInsURL) {
        // A bundle with no PlugIns directory has no answer, and that is a normal
        // thing for a test bundle to be. A nil here is the difference between
        // "this process is not a test host" and "the directory could not be
        // read", and only the second is worth logging.
        return nil;
    }
    NSURL *bundleURL = [self _mostRecentFileInDirectory:plugInsURL withExtension:@"xctest"];
    if (!bundleURL) {
        return nil;
    }
    return [NSBundle bundleWithURL:bundleURL];
}

#pragma mark - Synthesizing a configuration

/// A bundle's configuration, from its file if it has one and synthesized if not.
///
/// The asymmetry is deliberate and is the one thing here worth reading twice. No
/// file is not a failure: a test bundle built by a plain `xcodebuild test` has no
/// .xctestconfiguration in it, because nothing wrote one, and refusing to
/// configure that bundle would mean the framework cannot run anything that was
/// not started by an IDE. A file that is there and cannot be decoded is a
/// different thing entirely -- something wrote a configuration, it is wrong, and
/// inventing a replacement would run the tests the writer of that file was
/// trying to exclude.
- (nullable XCTestConfiguration *)_configurationForTestBundle:(NSBundle *)bundle
{
    NSURL *configurationURL =
        [self _mostRecentFileInDirectory:bundle.resourceURL withExtension:@"xctestconfiguration"];
    if (configurationURL) {
        _XCTDefaultLog("Found most recent test configuration in bundle: %{public}@",
                       configurationURL);
        return [self _testConfigurationFromURL:configurationURL];
    }
    return [self _synthesizedConfigurationForTestBundle:bundle];
}

/// Builds the configuration for a bundle that carries none.
///
/// Everything here answers a question the bundle cannot answer about itself,
/// which is why the inputs come from two different places. Whether this bundle
/// holds UI tests is in its Info.plist, because that is a fact about the bundle.
/// Whether this run is part of a multi-device session is in the environment,
/// because that is a fact about the process that loaded it -- and the same bundle
/// is loaded by a runner that has a session and by a plain xctest that does not.
- (nullable XCTestConfiguration *)_synthesizedConfigurationForTestBundle:(NSBundle *)bundle
{
    XCTestConfiguration *configuration = [[XCTestConfiguration alloc] init];
    if (!configuration) {
        return nil;
    }
    configuration.testBundleURL = bundle.bundleURL;
    // YES, and this is a departure from the default. The configuration is
    // synthesized *because* nothing is driving this run, so the framework's own
    // activity logging would be log noise about a run nobody is following. The
    // log lines this slice writes are the record that anything happened at all.
    configuration.emitOSLogs = YES;

    NSDictionary *infoDictionary = bundle.infoDictionary;
    // Truthiness, not -boolForKey:, and the difference from the three environment
    // lookups below is not an inconsistency. This is a plist read, not a
    // defaults read. What is being asked is "does this bundle contain UI tests",
    // and a bundle that says nothing about it does not.
    if ([infoDictionary[XCTContainsUITestsInfoDictionaryKey] boolValue]) {
        configuration.reportActivities = YES;
        configuration.initializeForUITesting = YES;
    }

    NSDictionary<NSString *, NSString *> *environment = [NSProcessInfo processInfo].environment;
    // Presence rather than truthiness for all three. These are read as "did the
    // runner say anything", because a runner sets them in order to tell the
    // framework something, and the reference treats any presence -- even an empty
    // value -- as having been told. A runner that wanted to say no unsets the
    // variable.
    if (environment[XCTestConfigurationInitializeForMultiDeviceKey]) {
        configuration.initializeForMultiDevice = YES;
    }
    if (environment[XCTestConfigurationShouldExtractMultiDeviceRequirementsKey]) {
        configuration.shouldExtractMultiDeviceRequirements = YES;
    }
    NSString *requirementsPath = environment[XCTestConfigurationMultiDeviceRequirementsFilePathKey];
    if (requirementsPath) {
        configuration.multiDeviceRequirementsFilePath = requirementsPath;
    }

    _XCTDefaultLog("Synthesizing a test configuration for the test bundle");
    return configuration;
}

@end
