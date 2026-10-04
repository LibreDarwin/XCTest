// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Private plumbing shared between the XCTest implementation files. Not
// installed into the framework and not part of the public contract.

#ifndef XCTEST_XCTESTINTERNAL_H
#define XCTEST_XCTESTINTERNAL_H

#import <XCTest/XCTest.h>

// The activity record and the stack a context runs them in. The record header
// is a public XCTestCore header; the stack is private to the framework.
#import <XCTestCore/XCActivityRecord.h>
#import <XCTestCore/XCTestConfiguration.h>
#import "XCTActivityRecordStack.h"

// The Internal SDK ships no <execinfo.h>: backtrace() and
// backtrace_symbols() live in libSystem, but their declarations ride along in
// that header, which is absent. They are ordinary BSD functions and are
// present in the library (verified against libSystem.tbd and by calling them),
// so declare them here rather than dropping backtraces from the framework.
// dlfcn.h is present in the SDK and is what supplies Dl_info/dladdr.
#include <dlfcn.h>
#include <stdbool.h>

// Annotated explicitly rather than relying on an assume_nonnull region: these
// sit outside one, and -Wnullability-completeness is enabled.
extern int backtrace(void *_Nonnull *_Nonnull buffer, int size);
extern char *_Nonnull *_Nullable backtrace_symbols(void *_Nonnull const *_Nonnull buffer, int size);

NS_ASSUME_NONNULL_BEGIN

// A private libobjc predicate: YES when a class is defined in Swift. It is not
// in the SDK's <objc/runtime.h>, but libobjc exports it (verified against
// libobjc.tbd), and it is the only way to tell a Swift class from an
// Objective-C one whose name merely looks like one -- which is exactly the
// decision class discovery has to make about the `_TtGC...` names the Swift
// runtime gives generic classes.
XCT_EXPORT bool _class_isSwift(Class cls);

// The class name with its Swift module stripped: `MyTests.MyTestsCase` becomes
// `MyTestsCase`, and a name with no dot is returned unchanged. Only the first
// component goes, because only the first is the module: a type nested inside
// another type still needs its outer type spelled to be found.
//
// A pair of C functions rather than a category on NSString because the two
// callers share nothing else: selection builds an identifier from a string
// name, and class discovery orders classes by theirs.
XCT_EXPORT NSString *_XCTClassNameWithoutModuleFromClassName(NSString *className);
XCT_EXPORT NSString *_XCTClassNameWithoutModuleFromClass(Class cls);

@class XCTIssue;
@class XCTExpectedFailure;
@class XCTExpectedFailureOptions;
@class XCTIdentifier;
@class XCTTestIdentifier;
@class XCTTestIdentifierSet;
@class XCTestCase;
@class XCTestObservationCenter;

/// A source of arbitrary unsigned numbers, supplied by the runner so a run can
/// be made reproducible from a seed. A block rather than an object because the
/// only thing the shuffle loop needs is "the next number" and the reference
/// spells it as one too; the default generator is `arc4random`.
typedef NSUInteger (^XCTRandomNumberGenerator)(void);

/// The mutable-array primitives the ordering machinery is built from. Private
/// because they are not a general array API -- each one exists for exactly one
/// caller in XCTestSuite -- and putting them on the public NSMutableArray would
/// be a contract Apple does not have.
@interface NSMutableArray<ObjectType> (XCTestAdditions)

/// Shuffles in place with a default generator. A Fisher-Yates walk from the
/// front, which the reference implements as the generator form below and this
/// forwards to, so there is one shuffle and not two.
- (void)xct_shuffle;

/// Shuffles in place by Fisher-Yates, drawing `j` from `[i, count)` for each
/// `i` from 0. `generator` is invoked once per position, including the last,
/// where `count - i` is 1 and the draw is necessarily a no-op.
- (void)xct_shuffleWithRandomNumberGenerator:(XCTRandomNumberGenerator)generator;

/// Removes every element for which `test` answers YES, keeping the elements it
/// answers NO for in their original relative order.
- (void)xct_removeObjectsPassingTest:(BOOL (^)(ObjectType object))test;

/// Gathers every element for which `block` answers NO at the front, keeps those
/// in their relative order, and returns how many there are. The elements that
/// answer YES end up after that boundary and are otherwise unordered.
- (NSUInteger)xct_halfStablePartitionUsingBlock:(BOOL (^)(ObjectType object))block;

@end

/// The exception name used for the internal unwind exceptions. Matches what the
/// shipping implementation uses, so a debugger or a crash reporter that
/// inspects exception names sees the familiar value.
///
/// The two exception types themselves are declared where they are raised:
/// _XCTSkipFailureException in XCTestSkippingImpl.h, and
/// _XCTestCaseInterruptionException in XCTestAssertionsImpl.h. Both are
/// private, and neither needs a payload -- the issue is recorded on the run
/// before the raise, so the runner only has to recognise the type to know
/// whether the test stopped deliberately.
XCT_EXPORT NSExceptionName const _XCTInternalUnwindExceptionName;

/// Installs the current test case for the duration of a test body, so helpers
/// invoked without a receiver (expectation fulfillers, async teardown) can
/// still attribute issues to the right run. Thread-local rather than global:
/// XCTest cases may run concurrently in separate processes, and a global here
/// would cross-contaminate them.
XCT_EXPORT void _XCTSetCurrentTestCase(XCTestCase *_Nullable testCase);
XCT_EXPORT XCTestCase *_Nullable _XCTCurrentTestCase(void);

/// The stack of XCTExpectFailure declarations made by a running test.
///
/// A stack because declarations nest, and a failure is absorbed by the closest
/// matching one. The stack lives on the test case rather than in a thread local:
/// a __thread variable cannot hold an object under ARC, and the state belongs to
/// the test being run anyway.
@interface XCTestCase (XCTInternalExpectedFailure)
/// Pushes a declaration and returns the scope standing for it. `options` is
/// copied, so the caller may reuse its own.
- (id)_xct_pushExpectedFailureWithReason:(nullable NSString *)reason
                                  options:(nullable XCTExpectedFailureOptions *)options;
/// Discards one specific declaration, for the block forms, where a declaration
/// never outlives its block.
///
/// Takes the scope rather than popping the top of the stack: a nested block's
/// failure may already have consumed its own declaration, and popping the top
/// then would discard the enclosing one that is still waiting to match.
- (void)_xct_removeExpectedFailureScope:(id)scope;
/// Consumes and returns the reason of the closest declaration that absorbs
/// `issue`, or nil if none does. Consuming is what makes two consecutive
/// declarations require two distinct failures to clear them.
- (nullable NSString *)_xct_matchExpectedFailureForIssue:(XCTIssue *)issue;
/// Reports every declaration still standing at the end of the test as
/// XCTIssueTypeUnmatchedExpectedFailure, then clears the stack.
- (void)_xct_finishExpectedFailures;
/// Records the thread the test body runs on, which is the only thread whose
/// declarations are allowed to absorb issues recorded on any thread.
- (void)_xct_markPrimaryThread;
/// Whether the caller is running on the thread the test body runs on. Only that
/// thread can be unwound by a failed assertion, so a failure recorded anywhere
/// else must not try.
- (BOOL)_xct_isOnPrimaryThread;
/// Records an issue without unwinding the test, for failures that are not part
/// of the test body's own control flow: an expectation over-fulfilled or left
/// unfulfilled by a callback, an async teardown, or another thread. Unwinding
/// would abandon assertions that are still meaningful, and off the test's own
/// thread there is no handler for the unwind at all.
- (void)_xct_recordIssueWithoutUnwinding:(XCTIssue *)issue;
@end

@class XCTExpectedFailure;

/// Records an issue and reports whether a declaration absorbed it.
///
/// The public -recordIssue: is the same funnel with the answer discarded; a test
/// case needs it in order to decide whether to unwind after the failure.
@interface XCTestRun (XCTInternalExpectedFailure)
- (BOOL)_xct_recordIssue:(XCTIssue *)issue;
@end

/// The one way to build an XCTExpectedFailure, which is not constructible by
/// callers: a declaration is only meaningful as the framework's record of a
/// specific issue being absorbed by a specific declaration.
@interface XCTExpectedFailure (XCTInternalConstruction)
- (instancetype)initWithIssue:(XCTIssue *)issue
                failureReason:(nullable NSString *)failureReason;
@end

/// Builds an XCTSourceCodeContext for a call site whose file and line the
/// caller already knows.
@interface XCTSourceCodeContext (XCTInternal)
+ (instancetype)xct_contextWithFilePath:(NSString *)filePath
                             lineNumber:(NSUInteger)lineNumber;
@end

/// Builds an XCTSourceCodeContext for a call site whose file and line the
/// caller already knows: the assertion macros have __FILE__ and __LINE__ as
/// literals, so there is nothing to resolve from a stack address.
XCT_EXPORT XCTSourceCodeContext *_XCTSourceCodeContextAtLocation(const char *filePath,
                                                                 NSUInteger lineNumber);

/// One measure block's results: every measurement every metric reported, across
/// every measured iteration.
///
/// Private because the public API has no way to read measurements back, and
/// adding one would be a contract Apple does not have. This is what the runner
/// and the result writer consume.
@interface XCTPerformanceActivityRecord : NSObject
- (instancetype)initWithName:(NSString *)name
                measurements:(NSArray<XCTPerformanceMeasurement *> *)measurements
               iterationCount:(NSUInteger)iterationCount NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (readonly, copy) NSString *name;
@property (readonly, copy) NSArray<XCTPerformanceMeasurement *> *measurements;
@property (readonly) NSUInteger iterationCount;
@end

@interface XCTestCase (XCTInternalPerformance)
/// Every measure block run so far by this test case, in order. The discarded
/// warm-up iteration contributes nothing.
///
/// Readwrite privately so the measure loop can append without asking the public
/// API for a mutation contract it does not have. The accessors live in
/// XCTestCase.m next to the other per-test state, because a category cannot
/// declare the ivar that backs it.
@property (readwrite, copy) NSArray<XCTPerformanceActivityRecord *> *xct_performanceRecords;

/// The measure block currently being run, or nil outside one. `id` rather than
/// its class so the state class stays private to the implementation file; the
/// public -startMeasuring and -stopMeasuring reach it only through this.
@property (nullable, strong) id xct_measureInvocation;
@end

/// The source context for wherever the runner is now -- used by failure paths
/// that have no call-site file and line of their own, such as an exception
/// escaping a test body.
XCT_EXPORT XCTSourceCodeContext *_XCTCurrentSourceCodeContext(void);

/// Records an issue on `testCase` (or, when nil, on the current test case),
/// applying the continueAfterFailure unwind policy. The one place an issue
/// enters the system, so every failure path gets identical treatment.
XCT_EXPORT void _XCTRecordIssueOnTestCase(XCTestCase *_Nullable testCase,
                                          XCTIssue *issue);

/// Read-write access to a run's bookkeeping. The public API exposes these as
/// readonly because a run is meant to be changed by driving it, not by poking at
/// it; the runner is the driver.
@interface XCTestRun (XCTInternal)
@property (readwrite, copy, nullable) NSDate *startDate;
@property (readwrite, copy, nullable) NSDate *stopDate;
@property (readwrite) NSUInteger testCaseCount;
@property (readwrite) NSUInteger executionCount;
@property (readwrite) NSUInteger skipCount;
@property (readwrite) NSUInteger failureCount;
@property (readwrite) NSUInteger unexpectedExceptionCount;
@property (readwrite) BOOL hasBeenSkipped;
@end

/// A test adopts the run it is performed against, which is what -performTest:
/// takes; the setter is private for the same reason as XCTestRun's above.
@interface XCTest (XCTInternal)
@property (readwrite, strong, nullable) XCTestRun *testRun;
@end

/// Class discovery: which classes in this process are test cases.
///
/// Private, and deliberately not on the public XCTestCase header. A client has
/// no business enumerating every XCTestCase subclass in the process; the runner
/// is the only caller, and it uses this to build a test tree from the classes a
/// test bundle has already loaded.
@interface XCTestCase (XCTRuntimeUtilities)

/// Every discoverable subclass of the receiver, ordered by class name with the
/// Swift module stripped. The order is what makes a run reproducible across
/// processes, where the runtime's class list is not.
+ (NSArray *)allSubclasses;

/// Every discoverable subclass whose image is not the one XCTestCase itself
/// lives in. The framework's own test-case subclasses are machinery, not tests,
/// and this is the filter that keeps them out of a run.
+ (NSSet *)allSubclassesOutsideXCTest;

/// Whether the receiver may be treated as a test class at all. NO for the
/// subclasses the runtime synthesises for key-value observing, and for Swift
/// generic classes, which cannot be instantiated by name.
+ (BOOL)_isDiscoverable;

/// Whether the receiver supplies its own +defaultTestSuite, rather than
/// inheriting XCTestCase's. Every test case inherits the method, so this is
/// not a -respondsToSelector: question: it is whether this class's answer is
/// its own, which is what decides whether an empty suite is still worth
/// including.
+ (BOOL)overridesDefaultTestSuite;

/// Whether the receiver supplies its own +testInvocations, rather than
/// inheriting XCTestCase's runtime selector scan. A class that overrides it is
/// asked for the invocations a selection is filtering, one test at a time.
+ (BOOL)overridesTestInvocations;

@end

/// Whether this OS can run this test class at all.
///
/// Asked of the class rather than the instance because the answer gates a suite
/// tree, which is built before any case exists: a class that cannot run here is
/// represented by a plain suite rather than by a case suite. See
/// _XCTTestCaseClassIsAvailable for what the answer is used for.
///
/// The reference answers by comparing +minimumOperatingSystemVersion -- a
/// version the test class declares, defaulting to 0.0.0 -- against the running
/// OS. That comparison is not ported, and the reason is worth stating rather
/// than working around: it needs NSOperatingSystemVersion, which the reduced
/// Foundation headers in this SDK do not declare, and adding it would mean
/// re-declaring a Foundation member with a type of our own choosing, which is
/// the one thing XCTestCoreFoundationCompat.h exists not to do -- a category
/// re-declaration is only safe while its type matches. The hook is what
/// survives: a class that does know it cannot run overrides the method below,
/// and the caller asks the class rather than assuming, so the deferred
/// comparison is a refinement of an answer that is already correct for every
/// class that does not override it.
@interface XCTestCase (XCTInternalAvailability)

/// The default answer is yes: with nothing declared to fail against, there is
/// no way to say a class is unavailable, and the reference reaches NO only
/// through a subclass. Naming the hook is the point -- the caller checks for it
/// rather than asking every class.
+ (BOOL)_isAvailable;

@end

/// Whether `testCaseClass` is a test case this OS can run.
///
/// The -respondsToSelector: test is the reference's and is the whole of it: a
/// class that is not a test case, or that has no answer to give, is NO rather
/// than being sent a question it does not implement.
XCT_EXPORT BOOL _XCTTestCaseClassIsAvailable(Class testCaseClass);

/// The test case class a name refers to, or Nil when the name is not one.
///
/// Three lookups, in the reference's order, because each rescues a case the one
/// before it cannot see. -NSClassFromString answers for names the runtime can
/// resolve as written. A name from a Swift or Objective-C test target usually
/// cannot be resolved that way, because the class is really called
/// "Module.Class"; prefixing the run's product module name and asking again
/// finds it. Failing that, the run's registry of discovered test classes is
/// asked, which is keyed by name with the module stripped -- the same spelling
/// the configuration uses to name a test class, so it is the lookup that
/// actually matches.
///
/// Not every class found is returned. A class that is XCTestCase or descends
/// from it is a test case by definition. Any other class is accepted only if it
/// answers +defaultTestSuite, which is the same evidence XCTest uses to decide a
/// named class is worth building a case suite for. A name that resolves to
/// neither is not a test class and is reported as absent rather than returned
/// and failed later.
XCT_EXPORT Class _XCTTestCaseClassFromString(NSString *className);

/// Every discovered test case class, keyed by name with the module stripped.
///
/// The fallback _XCTTestCaseClassFromString consults when a name does not
/// resolve directly. The key spelling is the reason it is worth having: a
/// configuration names a class the way the user wrote it, so a Swift test class
/// is registered as "MyTests" even though its runtime name is "MyApp.MyTests".
@interface XCTTestCaseClassesByString : NSObject
@property (class, nonatomic, readonly) NSDictionary<NSString *, Class> *testCaseClassesByString;
@end

/// How a test method asks to be called.
///
/// Not every test is a void method taking no arguments. The async and throws
/// support a test runner builds for Swift compiles down to shapes that take a
/// completion handler, and a method that reports failure the way the
/// pre-Swift idiom does takes an NSError ** out-parameter. Discovery that
/// recognized only `void` would drop all of them, so the shape is named and
/// recorded with the invocation, and the invoker acts on which one it has.
///
/// The values are the reference's. They are written into descriptors other code
/// compares against, so renumbering them changes meaning rather than tidying.
typedef NS_ENUM(NSUInteger, XCTTestMethodConvention) {
    /// - (void)testFoo -- no result to wait for and nowhere to report failure.
    XCTTestMethodConventionStandard = 0,
    /// - (id)testFoo:(NSError **)error -- reports through an out-parameter.
    XCTTestMethodConventionError = 1,
    /// Takes a completion handler and can throw.
    XCTTestMethodConventionAsyncThrowing = 2,
    /// Takes a completion handler and cannot throw.
    XCTTestMethodConventionAsyncNonThrowing = 3,
};

/// Decides which convention a method signature is written in.
///
/// The argument count and type characters are what a discovery pass has already
/// read out of the signature, so these take the pieces rather than the
/// signature itself. They are separate predicates because the caller has to know
/// which one matched -- the convention is the answer, not a yes.
@interface XCTestCase (XCTTestMethodConventions)
+ (BOOL)isValidTestMethodUsingStandardConventionWithArgumentCount:(NSUInteger)argumentCount
                                                       returnType:(char)returnType;
+ (BOOL)isValidTestMethodUsingErrorConventionWithArgumentCount:(NSUInteger)argumentCount
                                                     returnType:(char)returnType
                                             firstArgumentType:(const char *)firstArgumentType;
+ (BOOL)isValidTestMethodUsingAsyncConventionWithArgumentCount:(NSUInteger)argumentCount
                                                    returnType:(char)returnType
                                          blockArgumentCount:(NSUInteger)blockArgumentCount
                                               blockReturnType:(char)blockReturnType
                                     blockFirstArgumentClass:(Class _Nullable)blockFirstArgumentClass
                                                    isThrowing:(nullable BOOL *)isThrowing;
+ (BOOL)isValidTestMethodUsingAsyncConventionWithArgumentCount:(NSUInteger)argumentCount
                                                    returnType:(char)returnType
                                      firstBlockArgumentSignature:(nullable NSMethodSignature *)firstBlockArgumentSignature
                                                    isThrowing:(nullable BOOL *)isThrowing;
@end

/// A discovered test method, as the pieces needed to run it.
///
/// Discovery cannot return a bare NSInvocation. An invocation says which method
/// to call but not how it wants to be called, and a method that reports through
/// an NSError ** or a completion handler is called wrongly -- or crashes -- if
/// the caller treats it as one that returns void. Carrying the convention beside
/// the invocation is what lets the same list be both the set of tests and the
/// instruction for running each one.
@interface XCTTestInvocationDescriptor : NSObject

/// The method's name as a user would write it, without the class.
@property (nonatomic, readonly, copy) NSString *selectorString;

/// Which convention the method is written in, or nil if the caller did not say.
///
/// A number rather than an XCTTestMethodConvention so that "not decided yet" is
/// expressible. Zero is the standard convention, so substituting it for nil
/// would report a decision that was never made.
@property (nonatomic, readonly, strong, nullable) NSNumber *convention;

/// Already targeted at the test case, so the invoker does not have to guess.
@property (nonatomic, readonly, strong) NSInvocation *invocation;

/// What to say if this test turns out not to be runnable.
@property (nonatomic, readonly, copy) NSString *customErrorMessage;

- (instancetype)initWithSelectorString:(NSString *)selectorString
                        conventionNumber:(nullable NSNumber *)conventionNumber
                             invocation:(NSInvocation *)invocation
                     customErrorMessage:(NSString *)customErrorMessage;
- (instancetype)initWithSelectorString:(NSString *)selectorString
                            invocation:(NSInvocation *)invocation
                     customErrorMessage:(NSString *)customErrorMessage;
- (instancetype)initWithSelectorString:(NSString *)selectorString
                            convention:(XCTTestMethodConvention)convention
                            invocation:(NSInvocation *)invocation
                     customErrorMessage:(NSString *)customErrorMessage;
@end

/// How a test names itself, and the identifier that names it to the selection
/// machinery.
///
/// Only -name is public. The rest spell out how the name is derived -- which
/// Swift module to strip, which trailing selector suffixes are signature
/// plumbing rather than part of the method -- and a client that leaned on any
/// of them would break the moment the derivation changed. The report writer and
/// the selection machinery are the only callers.
@interface XCTest (XCTInternalIdentity)

/// The class name with its Swift module stripped: `MyTests.MyTestsCase` is
/// displayed as `MyTestsCase`, because the module is noise in a report that is
/// already scoped to one bundle.
@property (nonatomic, readonly) NSString *languageAgnosticTestClassName;

/// The same derivation for a class, for the caller that has a class and no
/// instance -- which is the state a suite tree is built in, since the name that
/// identifies a class is needed before any case of it exists. A thunk to the
/// same C helper the accessor above uses, because the two spellings have to
/// agree: one class is named by the suite that holds it and by the cases inside
/// it, and a report that disagreed with itself would be worse than either
/// spelling being wrong alone.
+ (NSString *)languageAgnosticTestClassNameForTestClass:(Class)testCaseClass;

/// The test method name, or nil for an object that is not a single method. The
/// base answers nil; a case derives it from its invocation.
@property (nonatomic, readonly, nullable) NSString *languageAgnosticTestMethodName;

/// The display name in the form the legacy log parser expects. The base
/// forwards to -name; a case spells out its class and method with the module
/// still attached, because that is the spelling the Objective-C runtime, and so
/// a crash log, uses.
@property (nonatomic, readonly) NSString *nameForLegacyLogging;

/// The method name alone, for a report that has already named the class. A case
/// answers with its own method; anything else, including a suite, names itself
/// so the report never prints an empty subject.
@property (nonatomic, readonly) NSString *_methodNameForReporting;

/// The identifier the selection machinery addresses this object by. Declared on
/// the base so a suite can ask the same question of every child in one pass --
/// the removal loops call it on each test without knowing whether the child is a
/// case or a suite. The base does not answer it; XCTestCase and XCTestSuite do.
- (nullable XCTTestIdentifier *)_xctTestIdentifier;

@end

/// Adopted by a test class that wants to report a name other than the one its
/// selector implies -- XCTestCastMethodNamesUIAutomationDelegate is the only
/// in-tree example. Both selectors are optional and are probed with
/// -respondsToSelector:, never required.
@protocol XCTestMethodNameOverriding <NSObject>
@optional
/// Whether -overriddenTestMethodName should be consulted.
- (BOOL)overridesTestMethodName;
/// The name to report in place of the selector-derived one.
- (NSString *)overriddenTestMethodName;
@end

@interface XCTestCase (XCTInternalIdentity)

@property (nonatomic, readonly) NSString *nameForLegacyLogging;
@property (nonatomic, readonly, nullable) NSString *languageAgnosticTestMethodName;

/// The class name including its Swift module, which is what an identifier
/// carries: an identifier has to survive a process restart and be matched back
/// to a class by name, so it cannot drop the part that disambiguates two
/// same-named classes in different modules.
@property (nonatomic, readonly) NSString *languageSpecificTestClassName;

/// The method name spelled the way its source language spells it. For
/// Objective-C this is the same skeleton -languageAgnosticTestMethodName
/// returns; for Swift it carries the argument-list spelling -- `testFoo()` --
/// because that is the name the source wrote and a report should read back.
@property (nonatomic, readonly, nullable) NSString *languageSpecificTestMethodName;

/// The name this class means to report, when it renames itself through the
/// XCTestMethodNameOverriding hooks. The leading underscore is Apple's; a
/// subclass is not meant to call it.
@property (nonatomic, readonly, nullable) NSString *overridden_languageAgnosticTestMethodName;

/// Whether this class is compiled from Swift. The answer decides how a method
/// name is spelled, not whether the test runs.
+ (BOOL)mayBeSwift;

/// Whether this class overrides a name-related method, which decides whether
/// the slower name-derivation path is worth taking at all.
+ (BOOL)customizesTestMethodNameViaOverrides;

/// The method name for `selector`, with the harness suffixes stripped and, for
/// a Swift class, carrying the argument-arity suffix a Swift spelling has.
+ (nullable NSString *)_languageSpecificTestMethodNameForSelector:(SEL)selector;

/// The identifier, built without consulting the cache. Split out because the
/// cache's initializer runs under @synchronized and must not re-enter the
/// getter.
- (XCTTestIdentifier *)_uncachedIdentifierWithClassName:(NSString *)className;

/// The cached identifier. Private: the identifier is an internal name, and the
/// public face of a test is its -name.
- (XCTTestIdentifier *)_xctTestIdentifier;

@end

/// Execution ordering: the sequence in which a container performs its tests.
///
/// A run is ordered one of two ways, never both. Left alone, tests sort by
/// -defaultExecutionOrderCompare:, which is stable and comparable across
/// processes so a failure can be reproduced; asked to randomize, the same list
/// is shuffled instead, and the ordering methods are what the runner reaches
/// for. Private because neither is a contract a client may rely on -- order is
/// the runner's business, and -defaultExecutionOrderCompare: only exists so
/// -sortUsingSelector: has a receiver method.
@interface XCTest (XCTInternalOrdering)

/// Orders two tests of the same container. The base answers NSOrderedSame -- an
/// object that is not a test has no natural place among tests -- and each
/// container subclass answers for its own kind. The comparisons are deliberately
/// not case-sensitive: a report's ordering should not turn on capitalization.
- (NSComparisonResult)defaultExecutionOrderCompare:(XCTest *)other;

/// Drops every test whose identifier is in `set`, and recurses into suites so a
/// nested suite is filtered by the same set. The base is a no-op, because a
/// single test has no children and is itself removed by its parent.
- (void)_removeTestsWithIdentifierInSet:(XCTTestIdentifierSet *)set;

/// The complement of the above: keeps only tests whose identifier is in `set`.
- (void)_removeTestsWithoutIdentifierInSet:(XCTTestIdentifierSet *)set;

@end

@interface XCTestCase (XCTInternalOrdering)

/// Whether this class should be ordered by its selector rather than by its
/// identifier. NO everywhere in the shipping framework; it exists because a
/// suite whose cases were built by hand, rather than discovered, may not have
/// identifiers yet and still needs a meaningful order.
+ (BOOL)shouldSortTestsBySelector;

@end

@interface XCTestSuite (XCTInternalOrdering)

/// Maps each identifier to the identifier of the selection it belongs to -- a
/// parameterized test to its parent -- and removes that mapped set, so asking to
/// remove `func(x: 1)` also removes its siblings. The public-ish spelling; the
/// runner's only entry point.
- (void)removeTestsWithIdentifierInSet:(XCTTestIdentifierSet *)set;

/// Whether this suite survives a run that was asked to include empty suites.
///
/// A suite with tests in it always does. Of the empty ones, only a plain
/// XCTestSuite does: that is the suite a class which cannot run here gets, and
/// naming it is the honest report -- the class is present, with nothing under
/// it. An XCTestCaseSuite is dropped, because a class that is runnable but
/// contributed no tests has nothing to show, and a subclass of XCTestSuite with
/// a setUp of its own is dropped too.
- (BOOL)shouldIncludeWhenIncludingEmptySuites;

/// Sorts this suite's tests by -defaultExecutionOrderCompare:, then does the
/// same for every child suite.
- (void)_sortTestsUsingDefaultExecutionOrdering;

/// Shuffles this suite's tests with `generator`, then does the same for every
/// child suite. One generator is threaded through the whole tree so a seeded run
/// is reproducible from the seed alone.
- (void)_applyRandomExecutionOrderingWithGenerator:(XCTRandomNumberGenerator)generator;

@end

/// A suite that stands for a test class, whether or not any of its tests have
/// been put in it yet.
///
/// Private because nothing outside the construction machinery makes one, and
/// because the class is the construction machinery's own: the only way to reach
/// one is to ask for a suite for a class, and the answer is a plain suite when
/// the class is not one this OS can run.
@interface XCTestCaseSuite : XCTestSuite

/// The class this suite stands for. That is the whole difference from a plain
/// suite, and it is what a later pass needs: a selection that named a class has
/// to get back to the class to build the tests that belong in here, and it
/// cannot do that from a name without a class lookup.
@property (nonatomic, readonly) Class testCaseClass;

/// Named for the class rather than for the file it came from, and given the
/// identifier a selection will match this suite by.
- (instancetype)initWithTestCaseClass:(Class)testCaseClass
                            identifier:(nullable XCTTestIdentifier *)identifier;

@end

/// How a suite is built when a selection asks for a class rather than for a
/// test.
@interface XCTestSuite (XCTInternalConstruction)

/// -initWithName: plus the identifier this suite is addressed by.
///
/// A convenience over the designated initializer rather than a second way to
/// make a suite, and the ordering matters: the name is what a report prints and
/// the identifier is what the removal loops match a child against, so a suite
/// given an identifier is filterable in a way one built through -initWithName:
/// alone is not. A nil identifier leaves the suite without one, which the loops
/// read as "not in the set" -- so a suite constructed without an identifier is
/// never dropped on its account, and stays.
- (instancetype)initWithName:(NSString *)name
                  identifier:(nullable XCTTestIdentifier *)identifier;

/// An empty suite for `testCaseClass`: a case suite when the class can run
/// here, a plain suite when it cannot.
///
/// The distinction is observable rather than cosmetic. A case suite carries the
/// class, so a pass that has only the suite can fill it with that class's tests;
/// a plain suite can only be filled by a caller that already knows what it
/// asked for. That is why a class that cannot run still gets a suite at all --
/// so a report can show the class was there and had nothing in it -- but not
/// one that claims to know the class.
+ (XCTestSuite *)emptyTestSuiteForTestCaseClass:(Class)testCaseClass;

@end

/// The part of XCTContext's interface that is private to the framework.
///
/// Deliberately a category rather than an addition to the public
/// <XCTest/XCTContext.h>: the reference does not publish this, and it is not
/// meaningful to a test author.
/// What a context answers to for questions it does not have an answer for.
///
/// Declared without any requirement on purpose. The reference names this
/// protocol on the ivar and nothing else in the framework is known to conform to
/// it, so it is empty there too: adding methods would be inventing a contract
/// that no one is known to implement, and a protocol that can be adopted without
/// promising anything is still better than one that lies about what it asks.
@protocol XCTContextDelegate <NSObject>
@end

@interface XCTContext (XCTInternalContext)

/// YES when this context's activities exist only to carry something the reader
/// is expected to have -- an intermediate step, not a unit of work. Ancillary
/// activities are the ones a finish call may unwind implicitly, because
/// unwinding them cannot lose work that was meant to be reported.
@property (getter=isAncillaryContext) BOOL isAncillaryContext;

/// YES for the context that activities are reported against, rather than one
/// that exists only to nest inside another. A run has exactly one of these, and
/// aggregation is measured from it.
@property (getter=isReportingBase) BOOL isReportingBase;

/// Creates a context nested in `parent` and associated with `testCase`.
///
/// Both are nullable: a root context has no parent, and a context created
/// outside a test case -- the public +runActivityNamed:block: path -- has no
/// test case.
- (instancetype)initWithParent:(nullable XCTContext *)parent
                      testCase:(nullable XCTestCase *)testCase;

/// Ends the context's scope: runs the tear-down blocks that were added to it and
/// clears what it was carrying.
///
/// Idempotent, because a context that unwinds normally is often invalidated
/// again by the path that owns it.
- (void)invalidate;

/// The stack of activities running in this context. Owns it; nil only before
/// -init has run.
@property (readonly, strong) XCTActivityRecordStack *activityRecordStack;

/// The stack this context contributes to, reached through this context and every
/// context it is nested in.
///
/// Reported from the outermost context rather than the innermost so that a
/// consumer can tell how deep a run is overall, not just how deep this one part
/// of it is.
@property (readonly) NSUInteger transitiveActivityRecordStackDepth;

/// Every context this one is reachable from on the current thread, innermost
/// first: the contexts already running here, followed by this one's ancestors.
@property (readonly, copy) NSArray<XCTContext *> *associatedContexts;

/// YES when this context is running on the thread it was started on.
@property (readonly) BOOL isBoundToCurrentThread;

/// The nearest enclosing context marked as the reporting base, or nil when there
/// is none on this thread.
@property (readonly, nullable) XCTContext *reportingBaseContext;

/// Starts an activity in this context and returns the record for it.
- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type;
- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
                                       startTime:(nullable NSDate *)startTime;

/// Finishes an activity started in this context.
- (void)didFinishActivity:(XCActivityRecord *)activity;
- (void)didFinishActivity:(XCActivityRecord *)activity
               finishTime:(nullable NSDate *)finishTime;

/// Finishes everything still running in this context, innermost first.
- (void)unwindRemainingActivities;

/// How many activities are running in this context.
@property (readonly) NSUInteger activityRecordStackDepth;

/// The innermost activity running here, or nil.
@property (readonly, nullable) XCActivityRecord *topActivity;

/// Timing rolled up per aggregation group across everything this context has run.
@property (readonly, copy) NSDictionary<NSString *, id> *aggregationRecords;

/// Values the context carries for its own use, keyed by string.
- (nullable id)associatedObjectForKey:(NSString *)key;
- (void)setAssociatedObject:(nullable id)value forKey:(NSString *)key;

/// Blocks to run when the context is invalidated.
- (void)addTearDownBlock:(XCT_NOESCAPE void (^)(void))block;

/// The context this one is nested in, or nil for a root.
@property (readonly, nullable) XCTContext *parent;

/// YES until the context is invalidated.
///
/// A finished activity is what a reader normally asks about; this is the same
/// question one level up, asked about everything the context started.
@property (readonly) BOOL isValid;

/// When the context was created, which is what the outermost activity's duration
/// is measured from.
@property (readonly, copy) NSDate *startDate;

/// The test case this context belongs to, or nil when it was created outside one.
@property (readonly, weak, nullable) XCTestCase *testCase;

/// The observer registry to report this context's activities to.
@property (readonly) XCTestObservationCenter *observationCenter;

/// The object that decides where this context's activities end up.
///
/// Readwrite and weak. Weak because the relationship runs the other way from the
/// usual one -- a delegate does not own the object it speaks for, and a context
/// that kept its delegate alive would keep a whole runner graph alive behind it
/// for as long as anything held the context.
@property (weak, nullable) id<XCTContextDelegate> delegate;

/// The innermost context running on this thread, or nil.
///
/// On the main thread a root context is created and adopted when there is none,
/// because that is the normal state before any test has started. On any other
/// thread nil means what it says: nothing is running here.
+ (nullable XCTContext *)currentContextIfAvailable;

/// YES when a context is running on this thread.
+ (BOOL)hasCurrentContext;

/// Runs `block` in a new context that reports into whatever is running here.
///
/// This is how a test gets a context of its own to run asynchronous work in: the
/// child is pushed for the length of the block, so activities started inside it
/// unwind with it and cannot outlive it.
///
/// The child is unwound even if `block` throws -- its activities are closed, it is
/// taken off the stack, and it is invalidated, in that order -- because a context
/// left on the stack would go on accepting activities that nothing can report.
+ (void)runInContextForTestCase:(nullable XCTestCase *)testCase
                           block:(XCT_NOESCAPE void (^)(void))block;

/// The same, saying whether the child is the one activities should be reported
/// into directly rather than gathered under.
///
/// A reporting base is what -reportingBaseContext walks up to, so marking one
/// here is what lets a child's activities land in the report instead of under
/// whatever was already running.
+ (void)runInContextForTestCase:(nullable XCTestCase *)testCase
              markAsReportingBase:(BOOL)markAsReportingBase
                           block:(XCT_NOESCAPE void (^)(void))block;

/// The same, with the parent named rather than taken from the thread.
- (void)runInContextForTestCase:(nullable XCTestCase *)testCase
                           block:(XCT_NOESCAPE void (^)(void))block;

- (void)runInContextForTestCase:(nullable XCTestCase *)testCase
              markAsReportingBase:(BOOL)markAsReportingBase
                           block:(XCT_NOESCAPE void (^)(void))block;

/// The child context itself, which is what the two forms above are thin wrappers
/// around.
///
/// `context` may be nil, which makes the child a root. Split out because it is
/// the only place that pushes and pops, so a caller that wants to parent
/// somewhere other than the running context does not have to reimplement the
/// unwinding.
+ (void)_runInChildOfContext:(nullable XCTContext *)context
                  forTestCase:(nullable XCTestCase *)testCase
          markAsReportingBase:(BOOL)markAsReportingBase
                       block:(XCT_NOESCAPE void (^)(void))block;

/// The innermost context running on this thread. Raises rather than returning
/// nil: every caller needs one, and a nil here would only surface later, further
/// from the thread that lost it.
+ (XCTContext *)currentContext;

/// Starts a typed activity in this context and runs `block` inside it, handing
/// `block` the record so it can attach to the activity that is reporting it.
///
/// `activity` is nullable, and that is the contract rather than an oversight: a
/// run that does not report activities of this type still runs `block`, with
/// nothing to attach to. A block written against the public header may assume
/// nonnull, because the public path reports user-created activities and those are
/// always reported; only a caller naming a type of its own can be handed nil.
- (void)_runActivityNamed:(NSString *)name
                    type:(NSString *)type
                   block:(XCT_NOESCAPE void (^)(id<XCTActivity> _Nullable activity))block;

- (void)_runActivityNamed:(NSString *)name
                    block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block;

/// The same, reported as the framework's own activity rather than as one a test
/// author asked for by name.
///
/// This is how a suite's own setUp and tearDown show up in a report: the name is
/// the caller's to choose ("Suite Set Up"), but the type says the runner started
/// it, so it is not mistaken for something the test wanted to see.
+ (void)runInternalActivityNamed:(NSString *)name
                           block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block;

- (void)runInternalActivityNamed:(NSString *)name
                           block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block;

/// Writes a formatted note into the record, with no work attached to it.
///
/// The type is fixed at internal, so a reader can tell a note from something a
/// test asked for. This is for a fact worth recording that is not itself a piece
/// of work: an attachment was written, a screenshot was taken, a file went
/// missing. Those have nothing to wrap, so the activity spans no block and its
/// whole content is the message.
///
/// Both spellings report into the context running on this thread and ignore the
/// context they were called on. A note belongs to the run that is happening now,
/// so the instance form exists for callers that have a context to hand and would
/// rather say so than have it ignored.
+ (void)_recordActivityMessageWithFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

- (void)_recordActivityMessageWithFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// Reports a formatted message as an activity of `type` with no work attached,
/// into this context.
///
/// The same shape as a note, with both choices left to the caller: the type,
/// because the caller is the only one that knows what kind of thing happened,
/// and the destination, because a caller that already has a context should not be
/// made to look one up. There is no assertion for a missing context here -- the
/// destination was named, so a nil one reports nothing rather than being a fault.
- (void)_reportEmptyActivityWithType:(NSString *)type
                              format:(NSString *)format, ... NS_FORMAT_FUNCTION(2, 3);

/// Whether an activity of `type` is one a run in `inTestMode` reports.
///
/// Split from -_shouldReportActivityWithType: so the answer can be had without a
/// configuration in hand -- a caller that is only deciding what a mode implies
/// has no run to consult. A UI-test run reports every type; any other run reports
/// only the four that are results or containers.
+ (BOOL)shouldReportActivityWithType:(NSString *)type
                          inTestMode:(XCTTestMode)inTestMode;

/// Whether this run reports an activity of `type`, asking the active
/// configuration.
///
/// No configuration means no: there is no run to report to, so an activity
/// raised outside one has nowhere to land.
+ (BOOL)_shouldReportActivityWithType:(NSString *)type;

@end

/// The thread-local stack of contexts currently running on a thread.
///
/// This is what makes a context reachable from code that was handed only an
/// activity: the activity names the context, and the context names the thread.
@interface XCTest (XCTObservationCenterInternal)

/// The observation registry this run reports through.
///
/// Memoized rather than returning the shared center fresh each time, so a
/// context that asks on every activity resolves the same object every time and
/// an observer added mid-run is not seen through one call and missed through
/// another.
- (XCTestObservationCenter *)_xct_observationCenter;

@end

@interface NSThread (XCTContext)

/// The contexts running on this thread, outermost first.
@property (readonly, strong) NSMutableArray<XCTContext *> *xct_contextStack;

@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTINTERNAL_H */
