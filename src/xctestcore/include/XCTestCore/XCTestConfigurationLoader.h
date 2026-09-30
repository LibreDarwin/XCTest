// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestConfigurationLoader: where a run's configuration comes from.
//
// This is a *private* header, which is where it lives in Apple's tree too. A
// test configuration is written by whoever starts the run -- an IDE, or the
// xctest(1) agent this framework also ships -- and read back by the framework
// the run executes in. The reading half is this class, and it is what makes a
// run reproducible: the bytes a run was started with are on disk, and this is
// the only thing that decides where to find them and how to interpret what is
// there.
//
// Everything here is derived from the shipped XCTestCore binary rather than
// from a header, because no header for it exists to derive from. What the
// binary does not contain is left out rather than declared: the discovery
// order below is derived, the five environment variables it reads are derived
// (their names are, from the CFStrings the reference indexes), and the parts of
// the reference's own plumbing that this framework does not have -- its
// XCTestFailureHandler, its XCTDefaultLog -- are reproduced locally and named
// as such in the implementation.
//
// Layering: this is the third header, and it sits above the other two. The
// value types are imported rather than forward-declared, because without them
// -loadTestConfiguration's return value and
// +testIdentifierSetForIdentifiers:outError:'s would be pointers to nothing a
// client can name, and a client holding a configuration could not ask it what
// runs. Same reasoning as XCTestConfiguration.h importing XCTTestSelection.h:
// a run is a configuration plus a selection, and both halves have to be
// reachable from either one.

#import <Foundation/Foundation.h>

#import <XCTestCore/XCTestConfiguration.h>
#import <XCTestCore/XCTTestSelection.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads a test run's configuration.
///
/// A loader holds the two things the environment told it -- a URL and a base64
/// blob -- and nothing else. Everything else it works out at the moment it is
/// asked: which of those two sources to believe, what to synthesize when
/// neither has anything usable, and which file in a directory is the one a run
/// was started from.
///
/// The order in which -loadTestConfiguration consults its sources is the whole
/// contract, and it is a fallback chain rather than a preference list. The
/// environment is consulted first because a run that was told exactly what to
/// do must not be second-guessed by whatever happens to be lying around in the
/// temporary directory. Only when nobody said anything does the loader go
/// looking, and only then does it fall back to building a configuration out of
/// the test bundle it can find. The chain is tried in order and stops at the
/// first source that yields a configuration; a source that was asked and
/// answered "nothing" is not an error, because that is how a run that is meant
/// to be discovered rather than told gets discovered.
@interface XCTestConfigurationLoader : NSObject

/// Where the run's configuration was written, if the environment said so.
///
/// Read from the `XCTestConfigurationFilePath` environment variable by -init,
/// which is a *path* and not a URL, and is turned into a file URL there. Kept
/// as a URL rather than a string because that is the form every consumer wants
/// and the form the relative-path resolution below operates on.
///
/// Settable so that a client which was handed a configuration somewhere other
/// than the environment -- a test, a tool, the driver itself -- can be pointed
/// at it without going through the process environment, which is shared state
/// and a bad place for anything a test needs to vary.
///
/// Atomic rather than nonatomic, and that is recovered from the reference's
/// accessors rather than chosen: both setters are -copy, and ARC emits the
/// unlocked ivar read for a nonatomic copy, while the reference guards them.
/// Nothing in this class is shared across threads on purpose, so the property
/// costs more than it buys here; it is kept because the header is installed and
/// a client's compilation should not depend on which storage qualifier this
/// reimplementation happens to use.
@property (nullable, atomic, copy) NSURL *testConfigurationURLFromEnvironment;

/// The run's configuration, base64-encoded, if the environment said so.
///
/// Read from the `XCTestConfigurationEncodedValueEnvironmentKey` environment
/// variable by -init. Base64 rather than a path because this is the one source
/// that has to survive being handed to a process that has no opinion about the
/// file system: an xctest bundle launched by a multi-device runner inherits it
/// through the environment, and the runner is on another machine.
///
/// Nullability is load-bearing here and not symmetric with the URL above. Both
/// are "did the environment name a source", but only one of them is a name:
/// the URL is a path this process can open, and the encoded value is a string
/// that has to survive being wrong. See -loadTestConfiguration for how a
/// present-but-unusable one is treated, which is the same as absent -- and
/// deliberately so.
///
/// Atomic for the reason given on the property above.
@property (nullable, atomic, copy) NSString *testConfigurationEncodedValueFromEnvironment;

/// The designated initializer, and the only one that stores anything.
///
/// Both arguments are nullable and neither is validated, which is the point:
/// a loader is constructed before anything has been read, and the values it is
/// given are the environment's, which is not a source anyone curates. A nil
/// here is not a malformed loader, it is the normal case for a run that was
/// started without being told anything -- and the discovery chain below is
/// written on the assumption that it happens.
- (instancetype)initWithTestConfigurationURLFromEnvironment:(nullable NSURL *)testConfigurationURL
                                  encodedEnvironmentValue:(nullable NSString *)encodedValue;

/// Reads both environment variables and forwards to the designated
/// initializer.
///
/// The URL variable is a path, and is turned into a file URL with
/// +[NSURL fileURLWithPath:]. Nothing is validated here, and one thing is worth
/// knowing about that: an empty path is stored as *no* URL at all, because
/// Foundation answers nil for it rather than a URL naming the working directory.
/// So an empty `XCTestConfigurationFilePath` is indistinguishable from an unset
/// one, and a load falls through to discovery exactly as if the variable had never
/// been there. The reference makes the same call, and the alternative -- keeping
/// the empty string as a URL that cannot be read -- would be a distinction with no
/// consequence behind it.
- (instancetype)init;

/// Loads the run's configuration, consulting every source in order.
///
/// The chain, in order:
///
///   1. -testConfigurationEncodedValueFromEnvironment, if it is set.
///   2. -testConfigurationURLFromEnvironment, if it is set.
///   3. The most recently modified `.xctestconfiguration` in NSTemporaryDirectory.
///   4. The most recently modified `.xctest` bundle in the main bundle's PlugIns
///      directory, configured from that bundle -- from a
///      `.xctestconfiguration` inside it if it has one, and synthesized if not.
///
/// The first two sources produce a configuration that a run was *started* with,
/// so they are returned exactly as they came. The last two are found rather than
/// handed over, and a found configuration is
/// -clearXcodeReportingConfiguration'd first: whatever left that file or that
/// bundle lying around was not necessarily running, and a configuration nobody
/// is driving must not report to a driver that is not there. The reset is
/// applied only once a configuration has actually been read -- except in the
/// bundle case, where it is applied to the bundle's configuration whether or not
/// one could be read, so that a bundle which carries a configuration nobody can
/// decode still ends up reporting to nobody.
///
/// Once one of the last two sources has produced a configuration, the user's
/// defaults and the (empty) command line are applied to it, so that a scope
/// written into a defaults domain or a `-only-testing:` argument narrows what a
/// discovered run will execute. Sources 1 and 2 are not given the settings: the
/// process that handed them over is still running and is still the authority on
/// what runs. A run that found nothing returns nil without applying them: there
/// is nothing to apply them to, and a configuration invented to hold the
/// settings would be worse than no configuration.
- (nullable XCTestConfiguration *)loadTestConfiguration;

/// Loads only what the environment named, for a caller that needs to know
/// whether it was told anything.
///
/// -didSpecify is set to whether -testConfigurationURLFromEnvironment is
/// non-nil, and is the whole reason this method exists: a driver that was
/// handed a URL has to be able to report "you gave me a configuration and it
/// did not load" separately from "you gave me nothing", and only the first is
/// worth failing over. Nullable out-parameter, because the common caller does
/// not care and asking it to pass a BOOL it will ignore is noise.
///
/// This is source 2's method and reads only the URL. It does not consult
/// -testConfigurationEncodedValueFromEnvironment, which belongs to source 1 and
/// is reached by -loadTestConfiguration alone: asking this method about a blob
/// is a question it does not answer, and that is worth knowing before reading a
/// nil as "the blob was unusable".
///
/// Unlike -loadTestConfiguration this does not fall back: a run told to load
/// from the environment and given nothing usable gets nil, not a guess.
- (nullable XCTestConfiguration *)loadTestConfigurationFromEnvironmentWithDidSpecify:(nullable BOOL *)didSpecify;

/// Applies the scope settings a run's start-up arguments and defaults asked
/// for, to a configuration that has already been loaded.
///
/// Returns whether the settings were understood. A NO means an argument or a
/// defaults value was not recognized, and -outError says which; a nil
/// -outError is permitted and means the caller only wants the answer, which is
/// what -loadTestConfiguration asks for since it has no one to report to.
///
/// The scope can be named three ways, and the three are not peers:
///
///   `XCTestScopeFile`  A path, read as a plist. Takes precedence over the
///                      plain scope when both are present, because a file is a
///                      deliberate act and a defaults value is a leftover.
///   `XCTest`           A scope string. An absent value means "no opinion"; a
///                      value that is present is taken as a list of identifiers,
///                      and the empty string is present.
///   `All`              Every test. The default, and a value that is also what
///                      two deprecated scope values fall back to.
///
/// The two real forms are not the same shape, which is the one thing here that
/// is easy to get wrong. `XCTestScope` in a scope file is an *array* of
/// identifier strings, and is passed to
/// +testIdentifierSetForIdentifiers:outError: element by element -- it is not a
/// comma-separated string and is not split. The `XCTest` defaults value is a
/// single string and *is* split on commas. The file is read with
/// `NSDataReadingUncached`, because a scope written for this run is not
/// something to serve out of a cache that a previous run also wrote to.
///
/// A file's `XCTestInvertScope` key and the `XCTestInvertScope` defaults key
/// both mean "the other list", and the two spellings do not compose: whichever
/// source provided the scope also provided the inversion, so a scope file with
/// no inversion key is not inverted by a defaults key that is set.
///
/// The only entry the builder refuses is the empty one, so the only way to get
/// an error here is an empty component: a present-but-empty `XCTest` value, or
/// a list -- comma-separated or in a scope-file array -- with an empty element,
/// such as one left by a trailing comma. Every non-empty string is given a
/// reading, including one that names nothing real, so a
/// `-only-testing:` argument with a typo parses and runs whatever it matches
/// rather than failing. Empty is singled out because it is the one spelling that
/// cannot be intended: an empty element is a list that was assembled wrong, and
/// treating it as "everything" is the worst outcome available.
///
/// `None` and `Self` are the two deprecated scope values. They are accepted,
/// with a warning, and behave as `All` -- which is what a pre-Swift-Testing
/// reader means by them, and is why they are not simply rejected: rejecting
/// them would break a defaults domain written years ago, on a machine that is
/// only trying to run some tests. The warning goes to stderr rather than to the
/// log, because the thing being deprecated is something a person typed.
///
/// When neither source names a scope, the command line gets a look: a process
/// started with more than two arguments that the loader did not expect reports
/// an error rather than running everything, since the extra argument was almost
/// certainly meant to narrow the run.
+ (BOOL)applySettingsFromUserDefaultsIfApplicable:(NSUserDefaults *)userDefaults
                             commandLineArguments:(NSArray<NSString *> *)commandLineArguments
                               testConfiguration:(XCTestConfiguration *)testConfiguration
                                        outError:(NSError **)outError;

/// Builds the selection a scope names, and reports which entry it could not
/// parse.
///
/// Each element is one selection string, so a scope file's array is taken
/// element by element and a comma-separated defaults value is split before it
/// gets here. The two spellings converge at this method rather than at the
/// caller, which is why a scope file's array is not split a second time.
///
/// The loop is the whole reason -XCTTestIdentifierSetBuilder exists: a scope is
/// a list, so it has to be accumulated, and a set that is being filled in while
/// it is being read is a different thing from a finished one.
///
/// Each string is added without its Swift counterpart, because a selection that
/// reached here has already been narrowed to one runner by whatever wrote it,
/// and adding the Swift Testing spelling of a name as well would put two
/// identifiers in a set that asked for one. The first identifier that does not
/// parse stops the loop and is the error: the rest of the list is not examined,
/// because a list whose beginning is wrong cannot be trusted to have a correct
/// end.
+ (nullable XCTTestIdentifierSet *)testIdentifierSetForIdentifiers:(NSArray<NSString *> *)identifiers
                                                            outError:(NSError **)outError;

@end

NS_ASSUME_NONNULL_END
