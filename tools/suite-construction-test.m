// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for reconstructing a suite tree from a selection. A run is
// handed a flat set of test identifiers and has to answer two questions: which
// classes those identifiers name, and, per class, what its suite should contain.
//
// It is grown one step at a time, alongside the increment it covers, so the
// checks here are only the ones that are true at this step:
//
//   - Runtime facts. Whether a class customises +defaultTestSuite or
//     +testInvocations decides which of three construction paths it takes: the
//     inherited empty suite, the class's own suite, or a scan of the class's
//     invocations. The answer has to be "is this implementation the class's
//     own", not "does the class respond", because every subclass inherits both.
//   - Swift counterparts. A selection can be spelled either way, so turning an
//     Objective-C method into its Swift reading is what lets one runner's
//     identifier match the other's tests.
//   - Naming and availability. A suite for a class is named after the class with
//     its module stripped, and is a case suite or a plain one depending on
//     whether the class can run here. The two names a class is known by -- the
//     one a suite carries and the one its cases carry -- have to be the same
//     string, or a selection written one way stops matching the tree built the
//     other.
//   - Identifiers from names. A selection carries method names rather than
//     invocations, so a name has to become the identifier the tree is filtered
//     by: through the signature suffixes the harness appends to a method, with
//     the class's own rename hooks honoured, and with no answer at all when the
//     class has no such method.
//   - Placeholders. A selection can name a test the class cannot supply, and the
//     tree that comes back has to contain it anyway -- named after the test it
//     stands for, counted as one test, and skipped with a reason when performed
//     -- rather than quietly missing the ones that failed to construct.
//   - Resolved suites. +testSuiteForTestCaseClass: builds a class's suite from
//     its discovered descriptors: one case per test, each built under a
//     recorded run configuration (the empty one when the class contributes no
//     variations), a placeholder standing in for a test whose class cannot run
//     here, and the whole list ordered the way the descriptor consumer orders
//     it -- without regard to case.
//   - Configuration construction. Turning a configuration into a suite tree:
//     grouping a flat selection back into classes, preparing a container from
//     it so a class selected two ways arrives once, sourcing one suite per test
//     bundle in the process, and which of the two run shapes -- everything, or
//     a selection -- a configuration asks for.
//
// It links the installed framework rather than the object files, so it also
// covers installation and the private declarations in XCTestInternal.h, which is
// where these methods would drift if they drifted anywhere.
#import <XCTest/XCTest.h>
#import <XCTestCore/XCTTestSelection.h>
#import <XCTestCore/XCActivityRecord.h>
#import <XCTestCore/XCTestConfiguration.h>

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestObservationInternal.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>
#import <string.h>

#import <stdio.h>

static int failures = 0;

static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-58s %s%s%s\n", name, passed ? "PASS" : "FAIL",
           (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Fixtures

// Declares neither override, so both runtime facts are the inherited ones.
@interface XCTSuiteConstructionPlainFixture : XCTestCase
- (void)testExample;
@end
@implementation XCTSuiteConstructionPlainFixture
- (void)testExample {}
@end

// Written in the error convention: an out-parameter carries the result, so the
// return type has to be able to. Discovery can recognize the shape but must not
// run it yet -- there is no way to hand a method an NSError ** and read a value
// back out of it, so reporting it as a test would mean calling it wrongly.
@interface XCTSuiteConstructionErrorConventionFixture : XCTestCase
- (id)testReportsThroughAnError:(NSError **)error;
@end
@implementation XCTSuiteConstructionErrorConventionFixture
- (id)testReportsThroughAnError:(NSError **)error
{
    *error = nil;
    return self;
}
@end

// An NSError subclass, to pin that the async predicate accepts only NSError
// itself and not anything shaped like it.
@interface XCTSuiteConstructionErrorSubclass : NSError
@end
@implementation XCTSuiteConstructionErrorSubclass
@end

// A test written with a completion handler, which is the async convention.
@interface XCTSuiteConstructionAsyncFixture : XCTestCase
- (void)testReportsThroughAHandler:(void (^)(void))handler;
@end
@implementation XCTSuiteConstructionAsyncFixture
- (void)testReportsThroughAHandler:(void (^)(void))handler
{
    handler();
}
@end

// Replaces the async lifecycle method with a handler-based one, which is the
// thing overridesAsyncSetUpOrTearDown exists to notice.
@interface XCTSuiteConstructionAsyncSetUpFixture : XCTestCase
@end
@implementation XCTSuiteConstructionAsyncSetUpFixture
- (void)setUpWithCompletionHandler:(void (^)(NSError *error))handler
{
    handler(nil);
}
@end

// The same, declared for tearDown only.
@interface XCTSuiteConstructionAsyncTearDownFixture : XCTestCase
@end
@implementation XCTSuiteConstructionAsyncTearDownFixture
- (void)tearDownWithCompletionHandler:(void (^)(NSError *error))handler
{
    handler(nil);
}
@end

// Declares the lifecycle method but not in the async shape, so it overrides the
// base without being driven asynchronously. A method that must be called but
// returns its outcome instead of taking a handler.
@interface XCTSuiteConstructionSyncSetUpFixture : XCTestCase
@end
@implementation XCTSuiteConstructionSyncSetUpFixture
- (void)setUpWithCompletionHandler:(void (^)(NSError *error))handler
{
    // Declared but never treated as a test's lifecycle: what matters here is
    // only that the class wrote the method.
    (void)handler;
}
@end

// Leaves both lifecycle methods alone.
@interface XCTSuiteConstructionNoLifecycleFixture : XCTestCase
- (void)testNothing;
@end
@implementation XCTSuiteConstructionNoLifecycleFixture
- (void)testNothing
{
}
@end

// Carries one method per shape discovery has to answer differently: the two
// conventions it can recognize here, and three that only look like tests. The
// helper is filtered by name, the two-argument method by having more arguments
// than any convention allows, and testReturnsWithoutAHandler by answering
// neither convention -- it returns a value with nothing to report through, which
// is the shape a test-prefixed convenience method usually has.
//
// Deliberately no async method. Telling a completion-handler test from a
// convenience method needs the handler's real signature, which
// -_signatureForBlockAtArgumentIndex: cannot supply on this platform, so such a
// method would be rejected here for a reason that has nothing to do with it.
// Asserting that would pin a known gap as though it were the contract; the gap
// is recorded in XCTestFoundationCompat.h where the stub is declared.
@interface XCTSuiteConstructionDiscoveryFixture : XCTestCase
- (void)testStandard;
- (BOOL)testReportsThroughAnError:(NSError **)error;
- (id)testReturnsWithoutAHandler;
- (void)testTakesTwoArguments:(NSInteger)first and:(NSInteger)second;
- (void)helperThatOnlyLooksLikeATest;
@end
@implementation XCTSuiteConstructionDiscoveryFixture
- (void)testStandard
{
}
- (BOOL)testReportsThroughAnError:(NSError **)error
{
    *error = nil;
    return YES;
}
- (id)testReturnsWithoutAHandler
{
    return self;
}
- (void)testTakesTwoArguments:(NSInteger)first and:(NSInteger)second
{
    (void)first;
    (void)second;
}
- (void)helperThatOnlyLooksLikeATest
{
}
@end

// Subclasses the fixture above, to tell "what this class declared" apart from
// "what may run here": discovery must report neither the inherited methods nor
// any shadowing, because resolving both belongs to the methods that walk the
// hierarchy -- +testInvocations, and _allTestMethodInvocationDescriptors.
@interface XCTSuiteConstructionDiscoverySubclass : XCTSuiteConstructionDiscoveryFixture
- (void)testStandard;
- (void)testOnlyOnTheSubclass;
@end
@implementation XCTSuiteConstructionDiscoverySubclass
- (void)testStandard
{
}
- (void)testOnlyOnTheSubclass
{
}
@end

// Two names whose order depends on whether case counts. "testZebra" precedes
// "testapple" when uppercase sorts below lowercase, and follows it when the
// comparison ignores case. Naming the pair this way is the only way to tell the
// two orders apart, since no two spellings of the same word can disagree.
@interface XCTSuiteConstructionCaseFixture : XCTestCase
- (void)testZebra;
- (void)testapple;
@end
@implementation XCTSuiteConstructionCaseFixture
- (void)testZebra
{
}
- (void)testapple
{
}
@end

// Declares no test at all, to pin that an empty result is an answer rather than
// a missing one.
@interface XCTSuiteConstructionNoTestsFixture : XCTestCase
- (void)helper;
@end
@implementation XCTSuiteConstructionNoTestsFixture
- (void)helper
{
}
@end

// Supplies its own +defaultTestSuite, the path that lets a class decide what its
// suite contains without the invocations being scanned.
@interface XCTSuiteConstructionDefaultSuiteFixture : XCTestCase
@end
@implementation XCTSuiteConstructionDefaultSuiteFixture
+ (XCTestSuite *)defaultTestSuite
{
    return [XCTestSuite testSuiteWithName:@"ConstructionDefaultSuite"];
}
@end

// Supplies its own +testInvocations, the path that filters a custom invocation
// list rather than the class's selectors.
@interface XCTSuiteConstructionInvocationsFixture : XCTestCase
@end
@implementation XCTSuiteConstructionInvocationsFixture
+ (NSArray<NSInvocation *> *)testInvocations
{
    return @[];
}
@end

// Supplies a real invocation list, so the construct entry point's middle leg
// has something to resolve and then filter. The list is deliberately not in
// method order, so a resolution that respects it is distinguishable from one
// that re-sorts. (Forward-declared: the helper lives with the identifier tests.)
static NSInvocation *identifierInvocation(Class cls, SEL selector);

@interface XCTSuiteConstructionInvocationsWithTestsFixture : XCTestCase
- (void)testFirst;
- (void)testSecond;
@end
@implementation XCTSuiteConstructionInvocationsWithTestsFixture
+ (NSArray<NSInvocation *> *)testInvocations
{
    return @[ identifierInvocation([self class], @selector(testSecond)),
              identifierInvocation([self class], @selector(testFirst)) ];
}
- (void)testFirst
{
}
- (void)testSecond
{
}
@end

// Carries its own test methods and a +defaultTestSuite that prebuilds cases for
// them, so the construct entry point's first leg has a populated suite to
// prune down to a selection.
@interface XCTSuiteConstructionDefaultWithTestsFixture : XCTestCase
- (void)testAlpha;
- (void)testBeta;
@end
@implementation XCTSuiteConstructionDefaultWithTestsFixture
+ (XCTestSuite *)defaultTestSuite
{
    XCTestSuite *suite = [XCTestSuite testSuiteWithName:@"ConstructionDefaultWithTests"];
    [suite addTest:[self testCaseWithSelector:@selector(testAlpha)
                 testRunConfiguration:@{}]];
    [suite addTest:[self testCaseWithSelector:@selector(testBeta)
                 testRunConfiguration:@{}]];
    return suite;
}
- (void)testAlpha
{
}
- (void)testBeta
{
}
@end

// Answers the availability hook with no. The reference reaches that answer by
// comparing a declared minimum OS version against the running one; a class that
// wants to be unavailable says so here instead.
// A suite subclass with a setUp of its own. It exists to be excluded: it matches
// neither XCTestSuite's stock setUp nor XCTestCaseSuite's.
@interface XCTSuiteConstructionSuiteWithSetUpFixture : XCTestSuite
@end

@implementation XCTSuiteConstructionSuiteWithSetUpFixture
- (void)setUp {}
@end

// A class with setup work of its own. The count is what lets the suite's setUp
// be observed without the harness having to guess whether it ran.
@interface XCTSuiteConstructionSetupFixture : XCTestCase
@property (class, nonatomic, readonly) NSUInteger setUpCount;
@property (class, nonatomic, readonly) NSUInteger tearDownCount;
@end

@implementation XCTSuiteConstructionSetupFixture
static NSUInteger XCTSuiteConstructionSetUpCount = 0;
static NSUInteger XCTSuiteConstructionTearDownCount = 0;

+ (NSUInteger)setUpCount { return XCTSuiteConstructionSetUpCount; }
+ (NSUInteger)tearDownCount { return XCTSuiteConstructionTearDownCount; }

+ (void)setUp
{
    XCTSuiteConstructionSetUpCount++;
}

+ (void)tearDown
{
    XCTSuiteConstructionTearDownCount++;
}

@end

@interface XCTSuiteConstructionUnavailableFixture : XCTestCase
@end
@implementation XCTSuiteConstructionUnavailableFixture
+ (BOOL)_isAvailable
{
    return NO;
}
@end

// Unavailable *and* carrying a test method. The fixture above has no tests, so
// its suite exercises only the empty-suite path; this one is what reaches the
// descriptor consumer's class-unavailable placeholder leg, where a discovered
// test cannot run because its class cannot run here.
@interface XCTSuiteConstructionUnavailableWithTestsFixture : XCTestCase
- (void)testUnavailable;
@end
@implementation XCTSuiteConstructionUnavailableWithTestsFixture
+ (BOOL)_isAvailable
{
    return NO;
}
- (void)testUnavailable
{
}
@end

// Named here because a class that is not a test case at all has to be refused
// too: the factory takes any Class, and asking one that has no hook is how the
// -respondsToSelector: guard is exercised.
@interface XCTSuiteConstructionNotATestCase : NSObject
@end
@implementation XCTSuiteConstructionNotATestCase
@end

// Not a test case, but knows how to describe itself as a suite. This is the
// evidence _XCTTestCaseClassFromString accepts in place of descending from
// XCTestCase, so the class has to exist for that branch to be exercised.
@interface XCTSuiteConstructionSuiteProvider : NSObject
@end
@implementation XCTSuiteConstructionSuiteProvider
+ (XCTestSuite *)defaultTestSuite
{
    return nil;
}
@end

#pragma mark - Activity observation fixtures

// Records the order callbacks arrive in, so that the start and finish
// dispatches can be told apart from delivery alone. A single shared counter
// rather than one per observer: the point is relative order between observers.
static NSUInteger ActivityObserverOrder = 0;

// Implements both private callbacks, which is what registration routes on.
@interface ActivityObserverFixture : NSObject <_XCTestObservationPrivate>
@property (nonatomic) NSUInteger order;
@property (nonatomic) NSUInteger startCount;
@property (nonatomic) NSUInteger finishCount;
@property (nonatomic) XCTContext *startContext;
@property (nonatomic) XCActivityRecord *startActivity;
@property (nonatomic) XCTContext *finishContext;
@property (nonatomic) XCActivityRecord *finishActivity;
@end

@implementation ActivityObserverFixture

- (void)_context:(XCTContext *)context
    willStartActivity:(XCActivityRecord *)activity
{
    self.order = ActivityObserverOrder++;
    self.startCount++;
    self.startContext = context;
    self.startActivity = activity;
}

- (void)_context:(XCTContext *)context
    didFinishActivity:(XCActivityRecord *)activity
{
    self.order = ActivityObserverOrder++;
    self.finishCount++;
    self.finishContext = context;
    self.finishActivity = activity;
}

- (BOOL)_sawStart
{
    return self.startCount > 0;
}

- (BOOL)_sawFinish
{
    return self.finishCount > 0;
}

@end

// The public protocol only, so registration must keep it out of the private
// list. A reporter that never declared interest in activity should not be
// handed a context and a record it has no way to interpret.
@interface PublicObserverFixture : NSObject <XCTestObservation>
@property (nonatomic) BOOL sawStart;
@property (nonatomic) BOOL sawFinish;
@end

@implementation PublicObserverFixture
- (void)_context:(XCTContext *)context
    willStartActivity:(XCActivityRecord *)activity
{
    self.sawStart = YES;
}
- (void)_context:(XCTContext *)context
    didFinishActivity:(XCActivityRecord *)activity
{
    self.sawFinish = YES;
}
@end

// Conforms to the private protocol but implements only the start callback.
// Every method on the protocol is optional, so the finish dispatch has to skip
// it rather than message a method that is not there.
@interface ActivityStartOnlyFixture : NSObject <_XCTestObservationPrivate>
@property (nonatomic) NSUInteger startCount;
@property (nonatomic) NSUInteger finishCount;
@end

@implementation ActivityStartOnlyFixture
- (void)_context:(XCTContext *)context
    willStartActivity:(XCActivityRecord *)activity
{
    self.startCount++;
}
- (BOOL)_sawStart
{
    return self.startCount > 0;
}
- (BOOL)_sawFinish
{
    return self.finishCount > 0;
}
@end

// Throws from inside the callback, to pin that a broken reporter is contained
// rather than propagated into the test that was running.
@interface ThrowingActivityObserverFixture : NSObject <_XCTestObservationPrivate>
@end

@implementation ThrowingActivityObserverFixture
- (void)_context:(XCTContext *)context
    willStartActivity:(XCActivityRecord *)activity
{
    [NSException raise:@"ActivityObserverFailure" format:@"deliberate"];
}
- (void)_context:(XCTContext *)context
    didFinishActivity:(XCActivityRecord *)activity
{
    [NSException raise:@"ActivityObserverFailure" format:@"deliberate"];
}
@end

// Conforms to the reporting protocol one level above _XCTestObservationPrivate,
// which inherits it -- so registration has to place this observer in the
// internal, the private and the public lists at once. Implements one public
// callback as well, to pin that the narrower protocols are additive rather
// than a replacement, and records the placeholder event it is sent.
@interface PlaceholderObserverFixture : NSObject <_XCTestObservationInternal>
@property (nonatomic) BOOL sawUnavailable;
@property (nonatomic) XCTestCasePlaceholder *unavailablePlaceholder;
@property (nonatomic) NSString *unavailableReason;
@property (nonatomic) BOOL sawPublicSuiteStart;
@end

@implementation PlaceholderObserverFixture
- (void)testCasePlaceholder:(XCTestCasePlaceholder *)placeholder
       isUnavailableWithReason:(NSString *)reason
{
    self.sawUnavailable = YES;
    self.unavailablePlaceholder = placeholder;
    self.unavailableReason = reason;
}
- (void)testSuiteWillStart:(XCTestSuite *)testSuite
{
    self.sawPublicSuiteStart = YES;
}
@end

// The one run shape the center lets through without checking: a run whose test
// is nil cannot be checked, so there is nothing to refuse.
@interface NilTestRun : NSObject
- (XCTest *)test;
@end

@implementation NilTestRun
- (XCTest *)test
{
    return nil;
}
@end

// Conforms to the reporting protocol one level above _XCTestObservationPrivate,
// so registration places it in the internal, the private and the public lists.
// It records both skip callbacks: the case-level one it inherits from the
// private protocol and the suite-level one declared directly on this protocol.
@interface SkipObserverFixture : NSObject <_XCTestObservationInternal>
@property (nonatomic) NSUInteger caseSkipCount;
@property (nonatomic) NSUInteger suiteSkipCount;
@property (nonatomic) XCTestCase *skippedCase;
@property (nonatomic) NSString *skippedCaseDescription;
@property (nonatomic) XCTSourceCodeContext *skippedCaseContext;
@property (nonatomic) XCTestSuite *skippedSuite;
@property (nonatomic) NSString *skippedSuiteDescription;
@property (nonatomic) XCTSourceCodeContext *skippedSuiteContext;
@end

@implementation SkipObserverFixture
- (void)testCase:(XCTestCase *)testCase
    didRecordSkipWithDescription:(NSString *)description
              sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
{
    self.caseSkipCount++;
    self.skippedCase = testCase;
    self.skippedCaseDescription = description;
    self.skippedCaseContext = sourceCodeContext;
}
- (void)testSuite:(XCTestSuite *)testSuite
    didRecordSkipWithDescription:(NSString *)description
              sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
{
    self.suiteSkipCount++;
    self.skippedSuite = testSuite;
    self.skippedSuiteDescription = description;
    self.skippedSuiteContext = sourceCodeContext;
}
@end

// Private protocol only: the case-level skip is declared on the protocol this
// conforms to, so it must arrive here; the suite-level one is declared above it,
// so it must not.
@interface PrivateSkipObserverFixture : NSObject <_XCTestObservationPrivate>
@property (nonatomic) NSUInteger caseSkipCount;
@end

@implementation PrivateSkipObserverFixture
- (void)testCase:(XCTestCase *)testCase
    didRecordSkipWithDescription:(NSString *)description
              sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
{
    self.caseSkipCount++;
}
@end

#pragma mark - Runtime facts

static void testRuntimeFacts(void)
{
    printf("runtime facts\n");

    // The base answers no by definition: its implementation is the one the
    // comparison is made against.
    ok("XCTestCase does not override +defaultTestSuite",
       ![XCTestCase overridesDefaultTestSuite], nil);
    ok("XCTestCase does not override +testInvocations",
       ![XCTestCase overridesTestInvocations], nil);

    // A subclass that inherits both answers no, even though it responds to both.
    ok("a plain subclass does not override +defaultTestSuite",
       ![XCTSuiteConstructionPlainFixture overridesDefaultTestSuite], nil);
    ok("a plain subclass does not override +testInvocations",
       ![XCTSuiteConstructionPlainFixture overridesTestInvocations], nil);
    ok("a plain subclass still responds to +defaultTestSuite",
       [XCTSuiteConstructionPlainFixture respondsToSelector:@selector(defaultTestSuite)], nil);
    ok("a plain subclass still responds to +testInvocations",
       [XCTSuiteConstructionPlainFixture respondsToSelector:@selector(testInvocations)], nil);

    // One override each, and they are independent of each other.
    ok("a class with its own +defaultTestSuite overrides it",
       [XCTSuiteConstructionDefaultSuiteFixture overridesDefaultTestSuite], nil);
    ok("a class with its own +defaultTestSuite does not override +testInvocations",
       ![XCTSuiteConstructionDefaultSuiteFixture overridesTestInvocations], nil);
    ok("a class with its own +testInvocations overrides them",
       [XCTSuiteConstructionInvocationsFixture overridesTestInvocations], nil);
    ok("a class with its own +testInvocations does not override +defaultTestSuite",
       ![XCTSuiteConstructionInvocationsFixture overridesDefaultTestSuite], nil);
}

#pragma mark - Swift counterparts

static void testSwiftCounterparts(void)
{
    printf("swift counterparts\n");

    // An Objective-C method gains its Swift reading, which names the same test
    // under the other spelling's option bit.
    XCTTestIdentifier *objc = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testFoo"];
    XCTTestIdentifierSet *one = [[XCTTestIdentifierSet alloc] initWithTestIdentifier:objc];
    XCTTestIdentifierSet *expanded = [one setByAddingSwiftCounterparts];
    ok("an Objective-C method's set grows to hold its Swift reading",
       expanded.count == 2, [NSString stringWithFormat:@"got %lu", (unsigned long)expanded.count]);
    ok("the original identifier is kept",
       [expanded containsTestIdentifier:objc], nil);
    ok("the Swift counterpart is added",
       [expanded containsTestIdentifier:objc.swiftMethodCounterpart], nil);

    // Applying the pass again is a no-op: every identifier is now either Swift
    // or paired with a copy already present.
    ok("the pass is idempotent",
       [expanded setByAddingSwiftCounterparts].count == 2, nil);

    // A suite is not a method, so it has no counterpart and the set is unchanged.
    XCTTestIdentifier *suite = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests"];
    XCTTestIdentifierSet *suiteSet = [[XCTTestIdentifierSet alloc] initWithTestIdentifier:suite];
    ok("a suite's set is unchanged",
       [suiteSet setByAddingSwiftCounterparts].count == 1, nil);

    // A method already spelled as Swift has no second Swift reading.
    XCTTestIdentifier *swift = [[XCTTestIdentifier alloc]
        initWithStringRepresentation:@"MyModule.MyTests/testFoo()"];
    ok("the fixture is read as a Swift method", swift.isSwiftMethod, nil);
    XCTTestIdentifierSet *swiftSet = [[XCTTestIdentifierSet alloc] initWithTestIdentifier:swift];
    ok("an already-Swift method's set is unchanged",
       [swiftSet setByAddingSwiftCounterparts].count == 1, nil);
}

#pragma mark - Naming

static void testNaming(void)
{
    printf("naming\n");

    // An Objective-C class name has no module to strip, so the derivation hands
    // it back unchanged. What is being checked is that the class-method form
    // exists and goes through the same derivation as the instance one.
    NSString *fromClass = [XCTest languageAgnosticTestClassNameForTestClass:
        [XCTSuiteConstructionPlainFixture class]];
    ok("a class name with no module is unchanged",
       [fromClass isEqualToString:@"XCTSuiteConstructionPlainFixture"], fromClass);

    // The point of the class method being a thunk: a suite names its class
    // before any case exists, and the cases inside name the same class through
    // the instance accessor. A selection can only be matched if they agree.
    XCTestCase *instance =
        [XCTSuiteConstructionPlainFixture testCaseWithSelector:@selector(testExample)];
    ok("the class and instance spellings agree",
       [fromClass isEqualToString:instance.languageAgnosticTestClassName],
       instance.languageAgnosticTestClassName);
}

#pragma mark - Availability

static void testAvailability(void)
{
    printf("availability\n");

    // The base cannot be unavailable: there is nothing declared to fail
    // against, so the answer is yes and only a subclass can change it.
    ok("XCTestCase itself is available", [XCTestCase _isAvailable], nil);

    // Asked of the class, and inherited answers count: every XCTestCase subclass
    // has the hook, so a plain subclass is available without saying anything.
    ok("a plain test class is available",
       _XCTTestCaseClassIsAvailable([XCTSuiteConstructionPlainFixture class]), nil);
    ok("a subclass that overrides the hook can refuse",
       !_XCTTestCaseClassIsAvailable([XCTSuiteConstructionUnavailableFixture class]), nil);
    ok("a class that is not a test case is unavailable",
       !_XCTTestCaseClassIsAvailable([XCTSuiteConstructionNotATestCase class]), nil);

    // The guard is the -respondsToSelector: one, not a kind-of test: the class
    // with no hook is sent nothing at all.
    ok("a class with no hook does not answer the question",
       ![XCTSuiteConstructionNotATestCase respondsToSelector:@selector(_isAvailable)], nil);
}

#pragma mark - Test method conventions

static void testConventionFromSignature(void)
{
    printf("convention from a signature\n");

    // The signatures here stand in for what a caller would hold. A standard test
    // takes no argument beyond self and _cmd.
    XCTTestMethodConvention convention = 99;
    ok("a method taking nothing is a standard test",
       [XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"v@:"]
                                        convention:&convention] && convention == XCTTestMethodConventionStandard, nil);

    // An NSError ** out-parameter with a return type that carries a value.
    convention = 99;
    ok("a method reporting through an NSError out-parameter is an error test",
       [XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"B@:^@"]
                                        convention:&convention] && convention == XCTTestMethodConventionError, nil);

    // More arguments than any convention allows, so not a test at all.
    convention = 99;
    ok("a method taking two arguments is not a test",
       ![XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"v@:@@"]
                                         convention:&convention], nil);
    // A rejected method must not have written a verdict.
    ok("a rejected method leaves the convention alone", convention == 99, nil);

    // No out-parameter supplied, which a caller that only wants yes/no does.
    ok("a caller wanting only the answer need not supply the out-parameter",
       [XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"v@:"]
                                        convention:NULL], nil);

    // The convention classifier agrees with the predicates it is built from,
    // rather than repeating their conditions: each of the three shapes is put
    // through both and compared.
    XCTTestMethodConvention standard = 99, errored = 99, async = 99;
    BOOL standardDirect = [XCTestCase isValidTestMethodUsingStandardConventionWithArgumentCount:2 returnType:'v'];
    BOOL standardViaSignature = [XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"v@:"]
                                                                convention:&standard];
    BOOL errorDirect = [XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                                               returnType:'B'
                                                                          firstArgumentType:"^@"];
    BOOL errorViaSignature = [XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"B@:^@"]
                                                             convention:&errored];
    ok("the standard shape classifies the same either way",
       standardDirect == standardViaSignature && standardViaSignature, nil);
    ok("the error shape classifies the same either way",
       errorDirect == errorViaSignature && errorViaSignature, nil);
    // A block in the third slot is what the async convention looks like in a
    // method's own encoding; it must not be taken for the error convention.
    ok("a block out-parameter is not read as an NSError one",
       ![XCTestCase isValidTestMethodWithSignature:[NSMethodSignature signatureWithObjCTypes:"B@:@?"]
                                         convention:&async], nil);
}

static void testAsyncSetUpAndTearDownOverrides(void)
{
    printf("async setUp and tearDown overrides\n");

    // The comparison the answer rests on is of the implementation that would
    // run, read off XCTest. Checked directly here, because it is the part that
    // has to be right for the answer to mean anything.
    IMP baseSetUp = [XCTest instanceMethodForSelector:@selector(setUpWithCompletionHandler:)];
    IMP baseTearDown = [XCTest instanceMethodForSelector:@selector(tearDownWithCompletionHandler:)];
    ok("XCTest supplies both async lifecycle methods",
       baseSetUp != NULL && baseTearDown != NULL, nil);
    ok("a class that overrides neither resolves to XCTest's setUp",
       [XCTSuiteConstructionNoLifecycleFixture instanceMethodForSelector:@selector(setUpWithCompletionHandler:)] == baseSetUp, nil);
    ok("a class that overrides tearDown resolves to XCTest's setUp but not its own tearDown",
       [XCTSuiteConstructionAsyncTearDownFixture instanceMethodForSelector:@selector(setUpWithCompletionHandler:)] == baseSetUp &&
           [XCTSuiteConstructionAsyncTearDownFixture instanceMethodForSelector:@selector(tearDownWithCompletionHandler:)] != baseTearDown, nil);
    // Redeclaring with a body identical to the base's still means the class
    // wrote the method, which is what the question asks -- so identity of the
    // implementation, not similarity of the code, is the thing compared.
    ok("a class that writes its own setUp resolves to something else",
       [XCTSuiteConstructionSyncSetUpFixture instanceMethodForSelector:@selector(setUpWithCompletionHandler:)] != baseSetUp, nil);

    // A class that overrides neither lifecycle method.
    ok("a class that overrides neither does not claim to",
       ![XCTSuiteConstructionNoLifecycleFixture overridesAsyncSetUpOrTearDown], nil);

    // Declares setUp but not in the async shape: overriding is not enough, the
    // override has to report through a handler or a caller would wait for
    // something that never arrives.
    ok("an override that is not handler-based is not seen",
       ![XCTSuiteConstructionSyncSetUpFixture overridesAsyncSetUpOrTearDown], nil);

    // A class that really does replace setUp with a handler-based one. Measured:
    // not reported, because telling an async method from a synchronous one needs
    // the signature of the block argument, and Foundation answers nil for it on
    // this platform -- every index, on a signature taken from a real method, as
    // 3o measured. So the async branch of the classifier cannot be reached and
    // this answers NO.
    //
    // Asserted as NO rather than omitted: the honest state is that an async
    // lifecycle override is invisible here, and a test that quietly expected YES
    // would be testing a Foundation that does not exist. The classifier's async
    // branch is covered directly in "async block signatures", where the handler's
    // shape is supplied rather than obtained.
    ok("a handler-based setUp is not seen, because the block's shape cannot be read",
       ![XCTSuiteConstructionAsyncSetUpFixture overridesAsyncSetUpOrTearDown], nil);
    ok("a handler-based tearDown is not seen, for the same reason",
       ![XCTSuiteConstructionAsyncTearDownFixture overridesAsyncSetUpOrTearDown], nil);

    // The base methods are captured once, so a second call must reach the same
    // verdict as the first rather than comparing against a method captured afresh.
    BOOL first = [XCTSuiteConstructionNoLifecycleFixture overridesAsyncSetUpOrTearDown];
    BOOL second = [XCTSuiteConstructionNoLifecycleFixture overridesAsyncSetUpOrTearDown];
    ok("asking twice gives the same answer", first == second, nil);
    // Asking about one class must not have captured the other's answer.
    ok("the captured base methods are XCTest's whatever class asks",
       [XCTSuiteConstructionNoLifecycleFixture instanceMethodForSelector:@selector(setUpWithCompletionHandler:)] == baseSetUp &&
           [XCTSuiteConstructionSyncSetUpFixture instanceMethodForSelector:@selector(setUpWithCompletionHandler:)] != baseSetUp, nil);
}

static void testMethodConventions(void)
{
    printf("test method conventions\n");

    // Standard: self and _cmd, and no result to wait for.
    ok("standard accepts void with no arguments",
       [XCTestCase isValidTestMethodUsingStandardConventionWithArgumentCount:2 returnType:'v'], nil);
    ok("standard rejects a return value",
       ![XCTestCase isValidTestMethodUsingStandardConventionWithArgumentCount:2 returnType:'i'], nil);
    ok("standard rejects an argument",
       ![XCTestCase isValidTestMethodUsingStandardConventionWithArgumentCount:3 returnType:'v'], nil);

    // Error: one argument to report through, and a return type able to carry a
    // value. All three spellings the reference accepts are accepted.
    ok("error accepts an object returning an out-parameter",
       [XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                            returnType:'o'
                                                    firstArgumentType:"^@"], nil);
    ok("error accepts a C++ bool returning an out-parameter",
       [XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                            returnType:'B'
                                                    firstArgumentType:"^@"], nil);
    ok("error accepts a C++ class returning an out-parameter",
       [XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                            returnType:'C'
                                                    firstArgumentType:"^@"], nil);
    ok("error rejects a void return",
       ![XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                             returnType:'v'
                                                     firstArgumentType:"^@"], nil);
    ok("error rejects a scalar return",
       ![XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                             returnType:'i'
                                                     firstArgumentType:"^@"], nil);
    // A block in that slot is the async convention, so it is not this one.
    ok("error rejects a block argument",
       ![XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                             returnType:'o'
                                                     firstArgumentType:"@?"], nil);
    ok("error rejects a scalar argument",
       ![XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:3
                                                             returnType:'o'
                                                     firstArgumentType:"^i"], nil);
    ok("error rejects a method with no argument",
       ![XCTestCase isValidTestMethodUsingErrorConventionWithArgumentCount:2
                                                             returnType:'o'
                                                     firstArgumentType:"^@"], nil);

    // The predicates classify a signature; they do not decide what runs. Until
    // the invoker knows how to report through an out-parameter, a method in
    // this convention is still left out rather than called incorrectly.
    ok("discovery still finds a plain fixture's tests",
       [[[XCTSuiteConstructionPlainFixture class] testInvocations] count] > 0, nil);
    ok("discovery leaves the error convention out until it can be run",
       [[[XCTSuiteConstructionErrorConventionFixture class] testInvocations] count] == 0, nil);

    // Async: the method yields nothing and takes a completion handler, and the
    // handler's own shape says whether it can report a failure.
    ok("async accepts a handler that reports no error",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                            returnType:'v'
                                                      blockArgumentCount:1
                                                       blockReturnType:'v'
                                             blockFirstArgumentClass:Nil
                                                            isThrowing:NULL], nil);
    ok("async accepts a handler that reports an error",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                            returnType:'v'
                                                      blockArgumentCount:2
                                                       blockReturnType:'v'
                                             blockFirstArgumentClass:[NSError class]
                                                            isThrowing:NULL], nil);
    ok("async rejects a method with a second argument",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:4
                                                             returnType:'v'
                                                       blockArgumentCount:1
                                                        blockReturnType:'v'
                                              blockFirstArgumentClass:Nil
                                                             isThrowing:NULL], nil);
    ok("async rejects a method that returns a value",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                             returnType:'i'
                                                       blockArgumentCount:1
                                                        blockReturnType:'v'
                                              blockFirstArgumentClass:Nil
                                                             isThrowing:NULL], nil);
    ok("async rejects a handler that returns a value",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                             returnType:'v'
                                                       blockArgumentCount:1
                                                        blockReturnType:'B'
                                              blockFirstArgumentClass:Nil
                                                             isThrowing:NULL], nil);
    ok("async rejects a handler that takes something other than an error",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                             returnType:'v'
                                                       blockArgumentCount:2
                                                        blockReturnType:'v'
                                              blockFirstArgumentClass:[NSObject class]
                                                             isThrowing:NULL], nil);
    ok("async rejects a handler with too many arguments",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                             returnType:'v'
                                                       blockArgumentCount:3
                                                        blockReturnType:'v'
                                              blockFirstArgumentClass:[NSError class]
                                                             isThrowing:NULL], nil);
    // Only NSError itself is the documented shape, so a subclass is not one.
    ok("async rejects an error subclass as the handler argument",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                             returnType:'v'
                                                       blockArgumentCount:2
                                                        blockReturnType:'v'
                                              blockFirstArgumentClass:[XCTSuiteConstructionErrorSubclass class]
                                                             isThrowing:NULL], nil);
    // The throwing-ness is an answer, so it is written on the accepting paths
    // and only there.
    BOOL isThrowing = YES;
    ok("a handler that reports no error is not throwing",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                            returnType:'v'
                                                      blockArgumentCount:1
                                                       blockReturnType:'v'
                                             blockFirstArgumentClass:Nil
                                                            isThrowing:&isThrowing] && !isThrowing, nil);
    isThrowing = NO;
    ok("a handler that reports an error is throwing",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                            returnType:'v'
                                                      blockArgumentCount:2
                                                       blockReturnType:'v'
                                             blockFirstArgumentClass:[NSError class]
                                                            isThrowing:&isThrowing] && isThrowing, nil);
    // A rejected method never reaches a verdict, so it must not overwrite an
    // answer the caller already had.
    isThrowing = YES;
    ok("a rejected method leaves the throwing answer alone",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                             returnType:'i'
                                                       blockArgumentCount:1
                                                        blockReturnType:'v'
                                              blockFirstArgumentClass:Nil
                                                             isThrowing:&isThrowing] && isThrowing, nil);
    // Asking only the yes/no is legitimate, so the pointer is optional.
    ok("the throwing answer can be declined",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                            returnType:'v'
                                                      blockArgumentCount:1
                                                       blockReturnType:'v'
                                             blockFirstArgumentClass:Nil
                                                            isThrowing:NULL], nil);
    // Discovery still runs only what it can invoke, so an async method is not
    // yet handed to a caller that would not know to wait for it.
    ok("discovery still leaves the async convention out until it can be run",
       [[[XCTSuiteConstructionAsyncFixture class] testInvocations] count] == 0, nil);
}

#pragma mark - Async block signatures

static void testAsyncBlockSignatures(void)
{
    printf("async block signatures\n");

    // A block's type encoding does not expand what the block takes, so these
    // stand in for the expanded signatures a caller obtains from the method
    // itself. Argument 0 is the block, so a handler taking nothing has a count
    // of one.
    NSMethodSignature *takesNothing = [NSMethodSignature signatureWithObjCTypes:"v@?"];
    NSMethodSignature *takesAnError = [NSMethodSignature signatureWithObjCTypes:"v@?@"];

    ok("a block signature knows how many arguments the block has",
       takesNothing.numberOfArguments == 1 && takesAnError.numberOfArguments == 2, nil);
    ok("a block signature knows the block's return type",
       takesNothing.methodReturnType != NULL && takesNothing.methodReturnType[0] == 'v', nil);

    // No signature means no handler to have read a convention from.
    ok("a missing block signature is not a test",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:Nil
                                                                isThrowing:NULL], nil);

    BOOL isThrowing = YES;
    ok("a handler that takes nothing is a test",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:takesNothing
                                                                isThrowing:&isThrowing] && !isThrowing, nil);

    // Telling a handler that takes an NSError from one that takes nothing means
    // naming the class of the block's first argument. Foundation's private
    // -_classForObjectAtArgumentIndex: is the only route to that, and measured
    // against a signature built from a type encoding it resolves nothing --
    // nil at every index, including the block itself -- because an encoding
    // says only "@" for any object. So such a handler is rejected rather than
    // mistaken for one that can only report success. Rejecting is safe:
    // nothing then invokes a test whose convention was never established.
    isThrowing = NO;
    ok("a handler that takes an error is not recognised",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:takesAnError
                                                                isThrowing:&isThrowing] && !isThrowing, nil);
    // A handler taking no argument does satisfy the shape, so the two are not
    // rejected for the same reason.
    ok("the two handler shapes are told apart, not both refused",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:takesNothing
                                                                isThrowing:NULL], nil);

    // The method's own shape still has to be right.
    ok("a method with a second argument is not a test",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:4
                                                              returnType:'v'
                                                firstBlockArgumentSignature:takesNothing
                                                                isThrowing:NULL], nil);
    ok("a method that returns a value is not a test",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'i'
                                                firstBlockArgumentSignature:takesNothing
                                                                isThrowing:NULL], nil);
    // The handler is called by whoever waits, so a value from it is a
    // different shape than the convention describes.
    ok("a handler that returns a value is not a test",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:[NSMethodSignature signatureWithObjCTypes:"i@?"]
                                                                isThrowing:NULL], nil);
    ok("a handler with three arguments is not a test",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:[NSMethodSignature signatureWithObjCTypes:"v@?@@"]
                                                                isThrowing:NULL], nil);

    // Asking only the yes/no stays legitimate at this layer too.
    ok("the throwing answer can be declined here",
       [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'v'
                                                firstBlockArgumentSignature:takesNothing
                                                                isThrowing:NULL], nil);
    // A method rejected before any verdict is reached must not overwrite an
    // answer the caller already had.
    isThrowing = YES;
    ok("a rejected method leaves the throwing answer alone",
       ![XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                              returnType:'i'
                                                firstBlockArgumentSignature:takesNothing
                                                                isThrowing:&isThrowing] && isThrowing, nil);

    // The two layers have to agree, or the signature layer would be answering
    // a question the primitive answers differently.
    BOOL fromPrimitive = [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                                            returnType:'v'
                                                                      blockArgumentCount:takesNothing.numberOfArguments
                                                                       blockReturnType:takesNothing.methodReturnType[0]
                                                                 blockFirstArgumentClass:Nil
                                                                                isThrowing:NULL];
    ok("the signature layer agrees with the shape it unpacks",
       fromPrimitive ==
           [XCTestCase isValidTestMethodUsingAsyncConventionWithArgumentCount:3
                                                                 returnType:'v'
                                                   firstBlockArgumentSignature:takesNothing
                                                                 isThrowing:NULL], nil);
}

#pragma mark - Invocation descriptors

// -copy on an immutable string hands back the same object, so identity cannot
    // show that the copy happened, and the SDK here has no mutable string to
    // mutate. What can be checked is the declaration the initializer relies on:
//    the property is copy, so a mutable string passed in cannot be changed from
//    under the descriptor afterwards.
//
// The flags are compared without the type encoding that precedes them. The
// attributes string is a type followed by flags -- T@"NSString",C,N,V_name --
// and the type is full of characters that look like flags: NSNumber contains an
// S, NSString a C. Only the field after the quoted type counts.
static BOOL descriptorPropertyHasFlag(const char *name, char flag)
{
    objc_property_t property = class_getProperty([XCTTestInvocationDescriptor class], name);
    if (property == NULL) {
        return NO;
    }
    const char *attributes = property_getAttributes(property);
    if (attributes == NULL) {
        return NO;
    }
    const char *flags = strstr(attributes, "\",");
    if (flags == NULL) {
        return NO;
    }
    flags += 2;
    // The flags are a comma-separated run that ends where the ivar name begins,
    // so the window is everything before ",V" rather than the first field.
    const char *end = strstr(flags, ",V");
    return end != NULL ? memchr(flags, flag, (size_t)(end - flags)) != NULL
                       : strchr(flags, flag) != NULL;
}

static void testInvocationDescriptors(void)
{
    printf("invocation descriptors\n");

    // A real invocation, taken from discovery, rather than one written here: the
    // SDK has no way to spell a signature by hand, and this is the pairing the
    // descriptor exists for anyway.
    NSInvocation *invocation = [[[XCTSuiteConstructionPlainFixture class] testInvocations] firstObject];
    ok("discovery produced an invocation to describe", invocation != nil, nil);

    // The form that states nothing about the convention must not be read as
    // stating the standard one: a descriptor built from only a name and an
    // invocation has not decided, and 0 would claim it had.
    XCTTestInvocationDescriptor *unstated =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:@"testExample"
                                                         invocation:invocation
                                                  customErrorMessage:@"unstated"];
    ok("a descriptor with no stated convention has none",
       unstated.convention == nil, nil);
    ok("a descriptor with no stated convention is not the standard one",
       ![unstated.convention isEqualToNumber:@(XCTTestMethodConventionStandard)], nil);
    ok("a descriptor keeps its selector name",
       [unstated.selectorString isEqualToString:@"testExample"], nil);
    ok("a descriptor keeps its invocation",
       unstated.invocation == invocation, nil);
    ok("a descriptor keeps its error message",
       [unstated.customErrorMessage isEqualToString:@"unstated"], nil);

    // Stating the convention boxes it, so the enum and the stored number cannot
    // disagree about what was asked for.
    XCTTestInvocationDescriptor *standard =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:@"testStandard"
                                                         convention:XCTTestMethodConventionStandard
                                                         invocation:invocation
                                                  customErrorMessage:@"standard"];
    ok("a stated convention is stored as its number",
       [standard.convention isEqualToNumber:@(XCTTestMethodConventionStandard)], nil);
    XCTTestInvocationDescriptor *async =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:@"testAsync"
                                                         convention:XCTTestMethodConventionAsyncNonThrowing
                                                         invocation:invocation
                                                  customErrorMessage:@"async"];
    ok("each convention keeps its own value",
       [async.convention isEqualToNumber:@(XCTTestMethodConventionAsyncNonThrowing)] &&
       ![async.convention isEqualToNumber:@(XCTTestMethodConventionStandard)], nil);

    // The number form is the one the other two build on, so it has to agree.
    XCTTestInvocationDescriptor *numbered =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:@"testNumbered"
                                                    conventionNumber:@(XCTTestMethodConventionError)
                                                         invocation:invocation
                                                  customErrorMessage:@"numbered"];
    ok("the number form stores the convention it was given",
       [numbered.convention isEqualToNumber:@(XCTTestMethodConventionError)], nil);
    ok("the number form and the enum form can express different values",
       ![numbered.convention isEqualToNumber:standard.convention], nil);

    // Names and messages are copied. A descriptor that shared the caller's
    // string would change what test it claims to be after the fact.
    // Copy, not share. Two descriptors built from one string must not end up
    // storing the same object: the caller's string can be changed afterwards,
    // and a descriptor that followed would quietly change which test it claims
    // to be. Distinct-but-equal is what a copy looks like from the outside.
    XCTTestInvocationDescriptor *copied =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:unstated.selectorString
                                                         invocation:invocation
                                                  customErrorMessage:unstated.customErrorMessage];
    ok("a descriptor reads back what it was given",
       [copied.selectorString isEqualToString:unstated.selectorString] &&
       [copied.customErrorMessage isEqualToString:unstated.customErrorMessage], nil);
    ok("the selector name is declared copy",
       descriptorPropertyHasFlag("selectorString", 'C'), nil);
    ok("the error message is declared copy",
       descriptorPropertyHasFlag("customErrorMessage", 'C'), nil);
    // The convention and the invocation are held, not copied: both are objects
    // a test may still be using, and copying either would leave a descriptor
    // describing something other than what will be run.
    ok("the convention is held rather than copied",
       !descriptorPropertyHasFlag("convention", 'C'), nil);
    ok("the invocation is held rather than copied",
       !descriptorPropertyHasFlag("invocation", 'C'), nil);

    // The description names the class and the method, which is the pair that
    // identifies a test when something goes wrong with running it.
    ok("a descriptor describes itself as class and selector",
       [unstated.description isEqualToString:@"<XCTTestInvocationDescriptor testExample>"],
       unstated.description);
}

#pragma mark - Descriptor rejects a test

static void testDescriptorRejection(void)
{
    printf("descriptor without an invocation\n");

    // A descriptor is also how discovery reports a test it refused, and there is
    // nothing to hand back but the reason. The reference factory builds exactly
    // two shapes -- an invocation with no message, or a message with no
    // invocation -- so both nullable properties have to survive nil rather than
    // only ever being handed a real object. Every other test in this file builds
    // a descriptor with both, which is what let the pair be declared nonnull and
    // still compile.
    XCTTestInvocationDescriptor *rejected =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:@"testRejected"
                                                         convention:XCTTestMethodConventionError
                                                         invocation:nil
                                                  customErrorMessage:@"not a valid test method"];
    ok("a rejected test keeps the message it was given",
       [rejected.customErrorMessage isEqualToString:@"not a valid test method"], nil);
    ok("a rejected test has no invocation to run",
       rejected.invocation == nil, nil);
    ok("a rejected test still names the method",
       [rejected.selectorString isEqualToString:@"testRejected"], nil);
    ok("a rejected test keeps the convention it was given",
       [rejected.convention isEqualToNumber:@(XCTTestMethodConventionError)], nil);

    // nil must survive the copy rather than become an empty string. An empty
    // message would be indistinguishable from a deliberate empty one, and would
    // print as a blank reason where the truth is that there was none.
    ok("a nil message stays nil rather than becoming empty",
       rejected.customErrorMessage == nil ||
           ![rejected.customErrorMessage isEqualToString:@""], rejected.customErrorMessage);

    XCTTestInvocationDescriptor *runnable =
        [[XCTTestInvocationDescriptor alloc] initWithSelectorString:@"testRunnable"
                                                         convention:XCTTestMethodConventionError
                                                         invocation:[[[XCTSuiteConstructionPlainFixture class] testInvocations] firstObject]
                                                  customErrorMessage:nil];
    ok("a runnable test has no message",
       runnable.customErrorMessage == nil, runnable.customErrorMessage);
    ok("a runnable test keeps its invocation",
       runnable.invocation != nil, nil);
}

#pragma mark - Method invocation descriptors

/// The descriptor a method name discovered, or nil if discovery left it out.
static XCTTestInvocationDescriptor *descriptorNamed(NSArray *descriptors, NSString *name)
{
    for (XCTTestInvocationDescriptor *descriptor in descriptors) {
        if ([descriptor.selectorString isEqualToString:name]) {
            return descriptor;
        }
    }
    return nil;
}

static NSUInteger countNamed(NSArray *descriptors, NSString *prefix)
{
    NSUInteger count = 0;
    for (XCTTestInvocationDescriptor *descriptor in descriptors) {
        if ([descriptor.selectorString hasPrefix:prefix]) {
            count++;
        }
    }
    return count;
}

static void testMethodInvocationDescriptors(void)
{
    printf("method invocation descriptors\n");

    NSArray *descriptors =
        [XCTSuiteConstructionDiscoveryFixture _testMethodInvocationDescriptors];

    // Two conventions in, two tests out. The count is checked before the
    // contents so a method that is missing and a method that appears twice
    // cannot both hide behind a passing membership test.
    ok("a method per recognized convention",
       descriptors.count == 2, ({
           NSMutableString *why = [NSMutableString string];
           for (XCTTestInvocationDescriptor *descriptor in descriptors) {
               [why appendFormat:@"%@ ", descriptor.selectorString];
           }
           [why appendFormat:@"-- %lu descriptors", (unsigned long)descriptors.count];
           why;
       }));

    // Names come from the selector as written, so a method with arguments keeps
    // them. A name that had been trimmed to fit something else would describe a
    // method the class does not have, which -[NSObject doesNotRecognizeSelector:]
    // would then turn into a failure at run time.
    ok("a discovered method keeps its full selector",
       descriptorNamed(descriptors, @"testReportsThroughAnError:") != nil, nil);
    ok("a zero-argument method is named without arguments",
       descriptorNamed(descriptors, @"testStandard") != nil, nil);

    // Each convention is reported as itself, which is the whole reason a
    // descriptor exists: the list says how to run each test, not only that it
    // exists.
    ok("the standard convention is reported as standard",
       [descriptorNamed(descriptors, @"testStandard").convention
           isEqualToNumber:@(XCTTestMethodConventionStandard)], nil);
    ok("the error convention is reported as error",
       [descriptorNamed(descriptors, @"testReportsThroughAnError:").convention
           isEqualToNumber:@(XCTTestMethodConventionError)], nil);

    // Each descriptor's invocation is ready to run: selector assigned, target
    // aimed at the class that declared the method. An invocation missing either
    // dispatches through nothing.
    XCTTestInvocationDescriptor *standard = descriptorNamed(descriptors, @"testStandard");
    ok("a discovered test is already aimed at its class",
       standard.invocation.target == (id)[XCTSuiteConstructionDiscoveryFixture class] &&
           standard.invocation.selector == @selector(testStandard),
       nil);
    ok("a runnable descriptor carries no failure message",
       standard.customErrorMessage == nil, standard.customErrorMessage);

    // The three methods that only look like tests. A name filter and the
    // classifier are separate decisions, so each is pinned separately: dropping
    // the helper proves the name was read, and dropping the other two proves the
    // shape was.
    ok("a helper whose name only starts like a test is left out",
       descriptorNamed(descriptors, @"helperThatOnlyLooksLikeATest") == nil, nil);
    ok("a test-prefixed method with too many arguments is left out",
       descriptorNamed(descriptors, @"testTakesTwoArguments:and:") == nil, nil);
    // This one is the shape discovery newly had to survive. It is two arguments
    // long -- self and _cmd -- and returns a value, so the async convention has
    // to be considered, and there is no third argument to ask about.
    ok("a test-prefixed method with no argument to report through is left out",
       descriptorNamed(descriptors, @"testReturnsWithoutAHandler") == nil, nil);

    // A descriptor is runnable or it explains itself, never both. Discovery
    // produces the first kind, and the pair of nullable properties only make
    // sense while that stays true.
    BOOL consistent = YES;
    for (XCTTestInvocationDescriptor *descriptor in descriptors) {
        if ((descriptor.invocation != nil) == (descriptor.customErrorMessage != nil)) {
            consistent = NO;
        }
    }
    ok("no discovered test is both runnable and rejected", consistent, nil);

    // The answer is about the receiver alone. Neither inherited methods nor
    // shadowing appear here, because answering either would mean walking the
    // hierarchy, and that walk is +testInvocations' question -- a different one.
    NSArray *fromSuperclass =
        [XCTSuiteConstructionDiscoveryFixture _testMethodInvocationDescriptors];
    ok("discovery does not reach up the hierarchy",
       countNamed(fromSuperclass, @"testOnlyOnTheSubclass") == 0, nil);
    NSArray *fromSubclass =
        [XCTSuiteConstructionDiscoverySubclass _testMethodInvocationDescriptors];
    ok("discovery does not report inherited methods",
       descriptorNamed(fromSubclass, @"testReportsThroughAError:") == nil &&
           descriptorNamed(fromSubclass, @"helperThatOnlyLooksLikeATest") == nil,
       nil);
    ok("discovery reports what the subclass itself declared",
       fromSubclass.count == 2, ({
           NSMutableString *why = [NSMutableString string];
           for (XCTTestInvocationDescriptor *descriptor in fromSubclass) {
               [why appendFormat:@"%@ ", descriptor.selectorString];
           }
           [why appendFormat:@"-- %lu descriptors", (unsigned long)fromSubclass.count];
           why;
       }));
    // The subclass declares testStandard too. Reporting it as a separate test
    // would be right for a per-class scan and wrong for a run -- which is
    // precisely the split between this method and +testInvocations.
    ok("a shadowing override is still reported by the subclass",
       descriptorNamed(fromSubclass, @"testStandard") != nil, nil);

    // A class with no tests has an empty answer, not a missing one. A nil return
    // would be indistinguishable from a class the caller failed to ask about.
    NSArray *empty = [XCTSuiteConstructionNoTestsFixture _testMethodInvocationDescriptors];
    ok("a class with no tests reports none", empty != nil && empty.count == 0,
       empty ? @"array was nil" : @"got a nil array");

    // Copied before returning, so a caller that edits the array cannot change
    // what the next caller is told. A mutable result would make discovery's
    // answer depend on who asked first.
    //
    // Probed on a result with something in it. An empty array copies to the one
    // immutable empty array Foundation hands everyone, so two empty answers are
    // necessarily the same object and identity would say nothing about whether a
    // copy happened. Nor are the two answers compared for equality: the
    // descriptors in them are fresh objects that do not implement -isEqual:, so
    // equality would report NO for two genuinely identical lists.
    NSArray *first = [XCTSuiteConstructionDiscoveryFixture _testMethodInvocationDescriptors];
    NSArray *second = [XCTSuiteConstructionDiscoveryFixture _testMethodInvocationDescriptors];
    ok("the answer is copied rather than handed over",
       first != second, @"two calls returned the same object");

    // The return value's type carries that promise, so it is checked by using it
    // the way a mutable array invites: by adding to it.
    BOOL refusedMutation = NO;
    @try {
        [(NSMutableArray *)descriptors addObject:[[XCTTestInvocationDescriptor alloc]
            initWithSelectorString:@"testAppended"
                         convention:XCTTestMethodConventionStandard
                          invocation:nil
                customErrorMessage:nil]];
    } @catch (NSException *exception) {
        refusedMutation = YES;
    }
    ok("the answer cannot be edited by the caller", refusedMutation,
       @"an immutable array accepted an addition");
}

/// The selector names in an order, so a failure can say which order came out.
///
/// Built by hand rather than through -valueForKey:, which the reduced header set
/// does not declare on NSArray.
static NSString *joinedSelectorNames(NSArray *descriptors)
{
    NSMutableString *joined = [NSMutableString string];
    for (XCTTestInvocationDescriptor *descriptor in descriptors) {
        if (joined.length > 0) {
            [joined appendString:@", "];
        }
        [joined appendString:descriptor.selectorString];
    }
    return joined;
}

static void testAllMethodInvocationDescriptors(void)
{
    printf("all method invocation descriptors\n");

    // A subclass sees what its superclass contributed. This is the difference
    // between the two questions: the receiver's own scan reports two
    // descriptors for the subclass fixture, and this one reports the whole
    // hierarchy's contribution.
    NSArray *all = [XCTSuiteConstructionDiscoverySubclass _allTestMethodInvocationDescriptors];
    ok("the hierarchy's own tests are included", ({
        countNamed(all, @"testReportsThroughAnError:") == 1 &&
            countNamed(all, @"testOnlyOnTheSubclass") == 1;
    }), joinedSelectorNames(all));

    // A redefined test is one test, not two. The dictionary is keyed by name, so
    // a shadowed superclass method is dropped rather than added alongside.
    ok("a shadowed method is reported once", countNamed(all, @"testStandard") == 1,
       joinedSelectorNames(all));

    // And the copy that survives is the subclass's. This is what the
    // first-writer-wins rule buys, and it is observable: each descriptor's
    // invocation is targeted at the class that declared it, so the shadowed
    // entry would be aimed at the superclass had the superclass been allowed to
    // overwrite it. Letting the superclass win would leave an inherited test
    // pointing at the class that no longer defines it.
    XCTTestInvocationDescriptor *shadowed = descriptorNamed(all, @"testStandard");
    ok("the subclass's copy of a shadowed method is the one kept",
       shadowed.invocation.target == (id)[XCTSuiteConstructionDiscoverySubclass class],
       [NSString stringWithFormat:@"target was %@",
        shadowed.invocation.target == nil ? @"nil" : NSStringFromClass([shadowed.invocation.target class])]);

    // An inherited method the subclass did not redefine keeps the superclass's
    // descriptor, so it is aimed at the class that actually declares it.
    XCTTestInvocationDescriptor *inherited =
        descriptorNamed(all, @"testReportsThroughAnError:");
    ok("an inherited method stays aimed at its declaring class",
       inherited.invocation.target == (id)[XCTSuiteConstructionDiscoveryFixture class],
       [NSString stringWithFormat:@"target was %@",
        inherited.invocation.target == nil ? @"nil" : NSStringFromClass([inherited.invocation.target class])]);

    // The whole hierarchy's tests, and nothing else. Three of the two classes'
    // five "test"-prefixed methods survive: testTakesTwoArguments:and: is not a
    // shape any convention recognizes, and testReturnsWithoutAHandler is not
    // either, both already pinned by the per-class checks. The helper that only
    // looks like a test never enters the count.
    ok("the hierarchy contributes each test once", all.count == 3, ({
        [NSString stringWithFormat:@"%lu descriptors: %@",
         (unsigned long)all.count, joinedSelectorNames(all)];
    }));
    ok("a helper that only looks like a test stays out",
       descriptorNamed(all, @"helperThatOnlyLooksLikeATest") == nil, nil);

    // The framework's own methods are not the user's tests. XCTestCase sits
    // below the walk, so its "test"-prefixed methods are never reached -- which
    // is the whole reason the walk stops where it does.
    NSArray *fromFixture = [XCTSuiteConstructionDiscoveryFixture _allTestMethodInvocationDescriptors];
    ok("the walk does not reach XCTestCase's own methods",
       countNamed(fromFixture, @"testInvocations") == 0 &&
           countNamed(fromFixture, @"testRun") == 0 &&
           fromFixture.count == 2,
       joinedSelectorNames(fromFixture));

    // Ordered by name, so a run is reproducible across processes. Checked against
    // an expected order rather than merely "sorted", because the question is
    // which order, not that some order arrived.
    ok("descriptors are ordered by selector name",
       [joinedSelectorNames(all) isEqualToString:@"testOnlyOnTheSubclass, "
        "testReportsThroughAnError:, testStandard"],
       joinedSelectorNames(all));

    // Case does not count. "testZebra" and "testapple" are in the opposite order
    // under a case-sensitive comparison, so this fails if the sort quietly
    // becomes one of those.
    NSArray *cased = [XCTSuiteConstructionCaseFixture _allTestMethodInvocationDescriptors];
    ok("the ordering ignores case",
       [joinedSelectorNames(cased) isEqualToString:@"testapple, testZebra"],
       joinedSelectorNames(cased));

    // An empty hierarchy is still an answer, not a nil.
    NSArray *empty = [XCTSuiteConstructionNoTestsFixture _allTestMethodInvocationDescriptors];
    ok("a hierarchy with no tests reports none", empty != nil && empty.count == 0,
       empty ? @"array was nil" : @"got a nil array");

    // A fresh dictionary per call, so one class's tests cannot appear in the
    // next class's answer. Probed with a class that has tests, since two empty
    // results are necessarily the same object (an empty array copies to the one
    // immutable empty array Foundation hands everyone) and identity would then
    // say nothing about whether anything was built separately.
    NSArray *first = [XCTSuiteConstructionDiscoveryFixture _allTestMethodInvocationDescriptors];
    NSArray *second = [XCTSuiteConstructionDiscoveryFixture _allTestMethodInvocationDescriptors];
    ok("each call collects its own list", first != second && first.count == second.count,
       @"two calls returned the same object");

    // As with discovery, the result is immutable -- `sortedArrayUsingComparator:`
    // already returns one, so this is a statement about the contract rather than
    // a change.
    BOOL refusedMutation = NO;
    @try {
        [(NSMutableArray *)all addObject:[[XCTTestInvocationDescriptor alloc]
            initWithSelectorString:@"testAppended"
                         convention:XCTTestMethodConventionStandard
                          invocation:nil
                customErrorMessage:nil]];
    } @catch (NSException *exception) {
        refusedMutation = YES;
    }
    ok("the collected list cannot be edited by the caller", refusedMutation,
       @"an immutable array accepted an addition");
}

@interface XCTSuiteConstructionOverrideFixture : XCTestCase
- (void)testFromOverride;
@end

static void testTestInvocationDescriptors(void)
{
    printf("test invocation descriptors\n");
    // overridesTestInvocations branch: maps invocations to descriptors, loses convention
    NSArray *overridden = [XCTSuiteConstructionOverrideFixture _testInvocationDescriptors];
    ok("overridden fixture yields descriptors from testInvocations",
       overridden != nil && overridden.count == 1, nil);
    if (overridden.count == 1) {
        XCTTestInvocationDescriptor *d = overridden[0];
        ok("overridden descriptor keeps selector and invocation",
           [d.selectorString isEqualToString:@"testFromOverride"] && d.invocation != nil, nil);
        ok("overridden descriptor has no convention when mapped",
           d.convention == nil, nil);
        ok("overridden descriptor has no custom error message",
           d.customErrorMessage == nil, nil);
    }
    // inherits test cases (default): hierarchy path
    NSArray *hier = [XCTSuiteConstructionDiscoverySubclass _testInvocationDescriptors];
    ok("default inherits path gives hierarchy descriptors",
       hier.count == 3, joinedSelectorNames(hier)); // same as before
}


@implementation XCTSuiteConstructionOverrideFixture
+ (NSArray<NSInvocation *> *)testInvocations
{
    NSMutableArray *invocations = [NSMutableArray array];
    NSMethodSignature *sig = [self instanceMethodSignatureForSelector:@selector(testFromOverride)];
    if (sig != nil) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = @selector(testFromOverride);
        inv.target = self;
        [invocations addObject:inv];
    }
    return invocations;
}
- (void)testFromOverride
{
}
@end

#pragma mark - Identifiers from names

// One test, spelled three ways. A selection carries the name the source wrote,
// so each class below is asked to resolve that name back to what it actually
// implements -- plainly, under an error-returning signature, or under a
// completion-handler signature.
@interface XCTIdentifierPlainFixture : XCTestCase
- (void)testPlain;
@end

@interface XCTIdentifierErrorFixture : XCTestCase
- (BOOL)testErrAndReturnError:(NSError **)error;
@end

@interface XCTIdentifierAsyncFixture : XCTestCase
- (void)testAsyncWithCompletionHandler:(void (^)(void))completion;
@end

// Renames one invocation rather than its whole method list, through the
// class-side hooks the reference gets from its multi-device category.
@interface XCTIdentifierRenameFixture : XCTestCase
- (void)testRenamed;
- (void)testPlainToo;
@end

// Renames every method it runs, which is the question
// +customizesTestMethodNameViaOverrides answers.
@interface XCTIdentifierCustomizingFixture : XCTestCase
- (void)testCustomized;
@end

static NSInvocation *identifierInvocation(Class cls, SEL selector)
{
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:selector];
    if (signature == nil) {
        return nil;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    return invocation;
}

static void testIdentifiersFromNames(void)
{
    printf("identifiers from names\n");

    // Resolution: which selector a class really has for a name a selection may
    // spell out. The plain name is the one the source wrote, and the class may
    // have implemented it with a signature suffix instead.
    ok("a name the class implements resolves to itself",
       [XCTIdentifierPlainFixture _resolvedTestMethodSelectorForSelector:
           @selector(testPlain)] == @selector(testPlain), nil);
    ok("a name the class does not implement resolves to nothing",
       [XCTIdentifierPlainFixture _resolvedTestMethodSelectorForSelector:
           NSSelectorFromString(@"testAbsent")] == NULL, nil);
    ok("a plain name resolves to the error-returning spelling",
       [XCTIdentifierErrorFixture _resolvedTestMethodSelectorForSelector:
           NSSelectorFromString(@"testErr")] == @selector(testErrAndReturnError:), nil);
    ok("a plain name resolves to the completion-handler spelling",
       [XCTIdentifierAsyncFixture _resolvedTestMethodSelectorForSelector:
           NSSelectorFromString(@"testAsync")]
           == @selector(testAsyncWithCompletionHandler:), nil);
    ok("an empty name resolves to nothing",
       [XCTIdentifierPlainFixture _resolvedTestMethodSelectorForSelector:
           NSSelectorFromString(@"")] == NULL, nil);

    // A name carried by a selection becomes the identifier the tree is filtered
    // by, and it must be the same identifier the case would build for itself.
    XCTTestIdentifier *plain =
        [XCTIdentifierPlainFixture _identifierForSelectorString:@"testPlain"];
    ok("a name the class implements names a test",
       [plain.identifierString isEqualToString:@"XCTIdentifierPlainFixture/testPlain"],
       plain.identifierString);
    XCTTestIdentifier *missing =
        [XCTIdentifierPlainFixture _identifierForSelectorString:@"testAbsent"];
    ok("a name the class does not implement names nothing", missing == nil, nil);
    XCTTestIdentifier *errorForm =
        [XCTIdentifierErrorFixture _identifierForSelectorString:@"testErr"];
    ok("an error-returning method is named without its signature suffix",
       [errorForm.identifierString
           isEqualToString:@"XCTIdentifierErrorFixture/testErr"],
       errorForm.identifierString);
    XCTTestIdentifier *asyncForm =
        [XCTIdentifierAsyncFixture _identifierForSelectorString:@"testAsync"];
    ok("a completion-handler method is named without its signature suffix",
       [asyncForm.identifierString
           isEqualToString:@"XCTIdentifierAsyncFixture/testAsync"],
       asyncForm.identifierString);

    // An invocation names a test the same way, unless the class renames it.
    XCTTestIdentifier *byInvocation = [XCTIdentifierPlainFixture
        _identifierForInvocation:identifierInvocation([XCTIdentifierPlainFixture class],
                                                      @selector(testPlain))];
    ok("an invocation names a test",
       [byInvocation.identifierString isEqualToString:@"XCTIdentifierPlainFixture/testPlain"],
       byInvocation.identifierString);
    XCTTestIdentifier *renamed = [XCTIdentifierRenameFixture
        _identifierForInvocation:identifierInvocation([XCTIdentifierRenameFixture class],
                                                      @selector(testRenamed))];
    ok("an invocation the class renames is named by the rename",
       [renamed.identifierString
           isEqualToString:@"XCTIdentifierRenameFixture/renamedByHook"],
       renamed.identifierString);
    XCTTestIdentifier *notRenamed = [XCTIdentifierRenameFixture
        _identifierForInvocation:identifierInvocation([XCTIdentifierRenameFixture class],
                                                      @selector(testPlainToo))];
    ok("an invocation the class leaves alone is named by its selector",
       [notRenamed.identifierString
           isEqualToString:@"XCTIdentifierRenameFixture/testPlainToo"],
       notRenamed.identifierString);
    XCTTestIdentifier *customized = [XCTIdentifierCustomizingFixture
        _identifierForInvocation:identifierInvocation([XCTIdentifierCustomizingFixture class],
                                                      @selector(testCustomized))];
    ok("a class that renames its method list is named by nothing",
       customized == nil, customized.identifierString);

    // An invocation built but never given a selector names no test, which is
    // the answer the caller needs in order to keep it rather than filter it.
    NSMethodSignature *signature =
        [XCTIdentifierPlainFixture instanceMethodSignatureForSelector:@selector(testPlain)];
    NSInvocation *unnamed = [NSInvocation invocationWithMethodSignature:signature];
    ok("an invocation that names no selector names nothing",
       [XCTIdentifierPlainFixture _identifierForInvocation:unnamed] == nil, nil);
}

@implementation XCTIdentifierPlainFixture
- (void)testPlain
{
}
@end

@implementation XCTIdentifierErrorFixture
- (BOOL)testErrAndReturnError:(NSError **)error
{
    (void)error;
    return YES;
}
@end

@implementation XCTIdentifierAsyncFixture
- (void)testAsyncWithCompletionHandler:(void (^)(void))completion
{
    if (completion != nil) {
        completion();
    }
}
@end

@implementation XCTIdentifierRenameFixture
+ (BOOL)overridesTestMethodNameForInvocation:(NSInvocation *)invocation
{
    return invocation.selector == @selector(testRenamed);
}

+ (NSString *)overriddenTestMethodNameForInvocation:(NSInvocation *)invocation
{
    return invocation.selector == @selector(testRenamed) ? @"renamedByHook" : nil;
}

- (void)testRenamed
{
}

- (void)testPlainToo
{
}
@end

@implementation XCTIdentifierCustomizingFixture
- (NSString *)languageAgnosticTestMethodName
{
    return @"renamedEverywhere";
}

- (void)testCustomized
{
}
@end

#pragma mark - Placeholder

static void testPlaceholder(void)
{
    printf("placeholder\n");

    NSString *reason = @"Test is unavailable since it has no invocation";

    // The Objective-C spelling: -displayName reads it as a source expression,
    // which is the form a report prints and the form the legacy name keeps.
    XCTTestIdentifier *identifier =
        [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testFoo"];
    XCTestCasePlaceholder *placeholder =
        [[XCTestCasePlaceholder alloc] initWithIdentifier:identifier reason:reason];
    ok("the reason survives", [placeholder.reason isEqualToString:reason], nil);
    ok("the identifier survives", [placeholder._xctTestIdentifier isEqual:identifier], nil);
    ok("a placeholder counts as one test", placeholder.testCaseCount == 1, nil);
    ok("a placeholder names the test it stands for",
       [placeholder.name isEqualToString:@"Unavailable test: -[MyTests testFoo]"], nil);
    ok("the legacy name is the test without the wrapper",
       [placeholder.nameForLegacyLogging isEqualToString:@"-[MyTests testFoo]"],
       placeholder.nameForLegacyLogging);
    ok("a placeholder runs as a placeholder run",
       placeholder.testRunClass == [XCTestCasePlaceholderRun class], nil);

    // The Swift spelling reads differently under the two names, which is the
    // only place they part: the general name keeps the Swift reading, and the
    // legacy one is what an Objective-C runner would have written.
    XCTTestIdentifier *swiftIdentifier =
        [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyModule.MyTests/testFoo"];
    XCTestCasePlaceholder *swiftPlaceholder =
        [[XCTestCasePlaceholder alloc] initWithIdentifier:swiftIdentifier reason:reason];
    ok("a Swift identifier reads as Swift in -name",
       [swiftPlaceholder.name isEqualToString:@"Unavailable test: MyTests.testFoo()"],
       swiftPlaceholder.name);
    ok("and as Objective-C in the legacy name",
       [swiftPlaceholder.nameForLegacyLogging isEqualToString:@"-[MyTests testFoo]"],
       swiftPlaceholder.nameForLegacyLogging);

    // MARK: Identity and ordering

    XCTestCasePlaceholder *same = [[XCTestCasePlaceholder alloc]
        initWithIdentifier:[[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testFoo"]
                    reason:@"a different reason for the same test"];
    ok("placeholders with one identifier are equal", [placeholder isEqual:same], nil);

    XCTestCasePlaceholder *different = [[XCTestCasePlaceholder alloc]
        initWithIdentifier:[[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testBar"]
                    reason:reason];
    ok("placeholders with different identifiers differ", ![placeholder isEqual:different], nil);

    XCTestSuite *real = [XCTestSuite testSuiteWithName:@"NotAPlaceholder"];
    ok("a test that ran is not a placeholder", ![placeholder isEqual:real], nil);

    ok("a placeholder sorts before a test that ran",
       [placeholder defaultExecutionOrderCompare:real] == NSOrderedAscending, nil);

    XCTestCasePlaceholder *apple = [[XCTestCasePlaceholder alloc]
        initWithIdentifier:[[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testApple"]
                    reason:reason];
    XCTestCasePlaceholder *zebra = [[XCTestCasePlaceholder alloc]
        initWithIdentifier:[[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testZebra"]
                    reason:reason];
    ok("placeholders order by method name",
       [apple defaultExecutionOrderCompare:zebra] == NSOrderedAscending, nil);

    // MARK: The run

    XCTestCasePlaceholderRun *run = [[XCTestCasePlaceholderRun alloc] initWithTest:placeholder];
    ok("a placeholder run reports its placeholder", run.placeholder == placeholder, nil);
    ok("a placeholder run counts its one test", run.testCaseCount == 1, nil);

    [placeholder performTest:run];
    ok("performed, the placeholder adopts the run", placeholder.testRun == run, nil);
    ok("performed, the placeholder is skipped", run.hasBeenSkipped, nil);
    ok("a placeholder's skip is not counted", run.skipCount == 0, nil);

    // The reference's three precondition checks, each raised rather than
    // swallowed: a skip asked of a run in the wrong state is a caller bug, and
    // dropping it would leave the run's state unexplained.
    XCTSourceCodeContext *skipContext =
        [[XCTSourceCodeContext alloc] initWithCallStack:@[] location:nil];

    XCTestCasePlaceholderRun *neverStarted =
        [[XCTestCasePlaceholderRun alloc] initWithTest:placeholder];
    BOOL raised = NO;
    @try {
        [neverStarted recordSkipWithDescription:reason sourceCodeContext:skipContext];
    } @catch (NSException *exception) {
        raised = YES;
        ok("a skip before start names the run",
           [exception.reason rangeOfString:@"has not yet been started"].location != NSNotFound,
           exception.reason);
    }
    ok("a skip before start raises", raised, nil);

    XCTestCasePlaceholderRun *stopped =
        [[XCTestCasePlaceholderRun alloc] initWithTest:placeholder];
    [stopped start];
    [stopped recordSkipWithDescription:reason sourceCodeContext:skipContext];
    ok("a skip while running marks the run", stopped.hasBeenSkipped, nil);
    ok("a skip while running is not counted", stopped.skipCount == 0, nil);
    raised = NO;
    @try {
        [stopped recordSkipWithDescription:reason sourceCodeContext:skipContext];
    } @catch (NSException *exception) {
        raised = YES;
        ok("a second skip says so",
           [exception.reason rangeOfString:@"has already been skipped"].location != NSNotFound,
           exception.reason);
    }
    ok("a second skip raises", raised, nil);

    // A run that was never skipped but is over: the two conditions are
    // distinct checks, so they are checked on separate runs rather than one
    // that has already been disqualified by the earlier ones.
    XCTestCasePlaceholderRun *finished =
        [[XCTestCasePlaceholderRun alloc] initWithTest:placeholder];
    [finished start];
    [finished stop];
    raised = NO;
    @try {
        [finished recordSkipWithDescription:reason sourceCodeContext:skipContext];
    } @catch (NSException *exception) {
        raised = YES;
        ok("a skip after stop says so",
           [exception.reason rangeOfString:@"has already been stopped"].location != NSNotFound,
           exception.reason);
    }
    ok("a skip after stop raises", raised, nil);

    raised = NO;
    @try {
        (void)[[XCTestCasePlaceholderRun alloc] initWithTest:real];
    } @catch (NSException *exception) {
        raised = YES;
        ok("the run refuses a real test by name",
           [exception.reason rangeOfString:@"Invalid parameter not satisfying"].location
               != NSNotFound,
           exception.reason);
    }
    ok("a placeholder run refuses anything but a placeholder", raised, nil);
}

#pragma mark - Class from string

static void testClassFromString(void)
{
    printf("class from string\n");

    // A test case class by its own name: the runtime resolves it, and descending
    // from XCTestCase is all that is needed to accept it.
    ok("a test class resolves by name",
       _XCTTestCaseClassFromString(@"XCTSuiteConstructionPlainFixture")
           == [XCTSuiteConstructionPlainFixture class], nil);

    // XCTestCase is not below itself, so the walk cannot find it. It is still a
    // test case, and it answers +defaultTestSuite, so the shared rule accepts it.
    ok("XCTestCase resolves to itself",
       _XCTTestCaseClassFromString(@"XCTestCase") == [XCTestCase class], nil);
    ok("XCTestCase answers the suite question it is accepted on",
       [XCTestCase respondsToSelector:@selector(defaultTestSuite)], nil);

    // The acceptance test for a class that is not a test case is whether it can
    // build a suite of itself, not whether it descends from anything.
    ok("a non-test class that builds a suite is accepted",
       _XCTTestCaseClassFromString(@"XCTSuiteConstructionSuiteProvider")
           == [XCTSuiteConstructionSuiteProvider class], nil);
    ok("a non-test class that cannot is rejected",
       _XCTTestCaseClassFromString(@"XCTSuiteConstructionNotATestCase") == Nil,
       @"resolves but is neither a test case nor a suite provider");

    // An unknown name is absent, not a class that fails later.
    ok("an unknown name is absent",
       _XCTTestCaseClassFromString(@"XCTSuiteConstructionNoSuchClass") == Nil, nil);

    // The registry is keyed by name with the module stripped, because that is
    // how a configuration names a class. Asserted directly: for an Objective-C
    // class the stripped name and the runtime name are the same string, so the
    // registry cannot be reached by a lookup that -NSClassFromString already
    // answered. It earns its keep for Swift classes, whose runtime name carries
    // the module and whose configured name does not.
    NSDictionary *registry = [XCTTestCaseClassesByString testCaseClassesByString];
    ok("the registry holds the test class under its stripped name",
       [registry[@"XCTSuiteConstructionPlainFixture"]
           isEqual:[XCTSuiteConstructionPlainFixture class]], nil);
    ok("no registry key carries a module",
       [registry.allKeys containsObject:@"XCTSuiteConstructionPlainFixture"], nil);

    // Built once and immutable: a second read is the same object, and asking the
    // question twice does not rebuild.
    ok("the registry is built once",
       [XCTTestCaseClassesByString testCaseClassesByString] == registry, nil);
}

#pragma mark - Empty suite

static void testEmptySuite(void)
{
    printf("empty suite\n");

    // A runnable class gets a case suite, which knows its class and is empty
    // because nothing has been added to it yet. The factory's result is a
    // XCTestSuite either way, so the class is what the kind-of test is for.
    Class runnable = [XCTSuiteConstructionPlainFixture class];
    XCTestSuite *forRunnable = [XCTestSuite emptyTestSuiteForTestCaseClass:runnable];
    ok("a runnable class gets a case suite",
       [forRunnable isKindOfClass:[XCTestCaseSuite class]], NSStringFromClass([forRunnable class]));
    ok("the case suite is empty", forRunnable.tests.count == 0, nil);
    ok("the case suite is named for the class",
       [forRunnable.name isEqualToString:@"XCTSuiteConstructionPlainFixture"], forRunnable.name);
    ok("the case suite knows its class",
       ((XCTestCaseSuite *)forRunnable).testCaseClass == runnable, nil);

    // The identifier is what a selection matches this suite by, so it is one
    // component naming the class and a container: no method, no arguments.
    XCTTestIdentifier *identifier = [forRunnable _xctTestIdentifier];
    ok("the case suite's identifier names the class",
       [identifier.components isEqualToArray:@[ @"XCTSuiteConstructionPlainFixture" ]],
       identifier.identifierString);
    ok("the case suite's identifier is a container", identifier.isContainer, nil);
    ok("the case suite's identifier has no arguments", identifier.argumentIDs == nil, nil);

    // A class that cannot run here gets a plain suite: still named, still
    // addressable, still empty, but not carrying the class.
    XCTestSuite *plainSuite =
        [XCTestSuite emptyTestSuiteForTestCaseClass:[XCTSuiteConstructionUnavailableFixture class]];
    ok("an unavailable class gets a plain suite",
       [plainSuite class] == [XCTestSuite class], NSStringFromClass([plainSuite class]));
    ok("the plain suite is still named for the class",
       [plainSuite.name isEqualToString:@"XCTSuiteConstructionUnavailableFixture"], plainSuite.name);
    ok("the plain suite is still addressable",
       [plainSuite _xctTestIdentifier] != nil, nil);
    ok("the plain suite's identifier names the class",
       [[plainSuite _xctTestIdentifier].components
           isEqualToArray:@[ @"XCTSuiteConstructionUnavailableFixture" ]],
       [plainSuite _xctTestIdentifier].identifierString);
    ok("the plain suite is empty", plainSuite.tests.count == 0, nil);

    // The construction initializer stores what it is given, and leaves a suite
    // built without one without an identifier at all -- which the removal loops
    // read as "not selected", so such a suite is kept rather than dropped.
    XCTTestIdentifier *given = [[XCTTestIdentifier alloc] initWithClassName:@"Module.Widget"];
    XCTestSuite *addressed = [[XCTestSuite alloc] initWithName:@"Widget" identifier:given];
    ok("the identifier given at construction is kept",
       [[addressed _xctTestIdentifier].components isEqualToArray:@[ @"Widget" ]],
       [addressed _xctTestIdentifier].identifierString);
    ok("a module is stripped from the stored identifier",
       ![addressed _xctTestIdentifier].representsBundle, nil);
    XCTestSuite *unaddressed = [[XCTestSuite alloc] initWithName:@"Loose" identifier:nil];
    ok("a nil identifier leaves the suite without one",
       [unaddressed _xctTestIdentifier] == nil, nil);
    ok("the name is set either way",
       [unaddressed.name isEqualToString:@"Loose"], unaddressed.name);
}

#pragma mark - Resolved suite

static void testResolvedSuite(void)
{
    printf("resolved suite\n");

    // A test class contributes no inputs in this system, so its variation
    // options are the default: a set whose inputs are empty and which yields no
    // variations. The consumer substitutes a single empty configuration on that
    // answer, which is the reference's own fallback.
    XCTVariationOptions *defaults = [XCTVariationOptions defaultVariationOptions];
    ok("the default options have empty inputs", defaults.inputs.count == 0, nil);
    ok("the default options contribute no variations",
       defaults.variations.count == 0, nil);

    XCTVariationOptions *fresh = [[XCTVariationOptions alloc] initWithInputs:@{}];
    ok("a constructed set keeps its inputs", fresh.inputs.count == 0, nil);
    ok("a constructed set contributes no variations",
       fresh.variations.count == 0, nil);

    ok("a class's inputs come from the default options",
       [[XCTSuiteConstructionPlainFixture testRunConfigurationInputs]
           isEqualToDictionary:defaults.inputs], nil);
    ok("a class's options are derived from its inputs",
       [[XCTSuiteConstructionPlainFixture _variationOptions].inputs
           isEqualToDictionary:defaults.inputs], nil);

    // The two-argument factory, empty-configuration arm: the invocation is
    // kept as the one-argument factory leaves it -- selector and signature
    // preserved, target re-pointed to the case -- and the configuration is
    // recorded on the case.
    NSInvocation *invocation = identifierInvocation([XCTSuiteConstructionPlainFixture class],
                                                    @selector(testExample));
    NSDictionary *emptyConfiguration = @{};
    XCTestCase *configured = [XCTSuiteConstructionPlainFixture
        testCaseWithInvocation:invocation testRunConfiguration:emptyConfiguration];
    ok("a case built with the empty configuration records it",
       [configured._testRunConfiguration isEqualToDictionary:emptyConfiguration], nil);
    ok("the invocation keeps its selector",
       configured.invocation.selector == @selector(testExample), nil);
    ok("the invocation is re-pointed at the case",
       configured.invocation.target == (id)configured, nil);

    // The non-empty arm rebuilds the invocation rather than retargeting it,
    // because a configuration may widen the argument list an invocation cannot
    // grow into. The selector and signature survive; the original is discarded.
    NSInvocation *argumentInvocation =
        identifierInvocation([XCTSuiteConstructionErrorConventionFixture class],
                             @selector(testReportsThroughAnError:));
    NSDictionary *nonEmptyConfiguration = @{ @"input": @"value" };
    XCTestCase *rebuilt = [XCTSuiteConstructionErrorConventionFixture
        testCaseWithInvocation:argumentInvocation testRunConfiguration:nonEmptyConfiguration];
    ok("a non-empty configuration is recorded",
       [rebuilt._testRunConfiguration isEqualToDictionary:nonEmptyConfiguration], nil);
    ok("the rebuilt invocation keeps its selector",
       rebuilt.invocation.selector == @selector(testReportsThroughAnError:), nil);
    ok("the rebuilt invocation is re-pointed at the case",
       rebuilt.invocation.target == (id)rebuilt, nil);

    // The descriptor consumer, whole-class arm: this is the body of
    // +testSuiteForTestCaseClass: after the swap. Three discovered tests become
    // three cases, each built under a recorded empty configuration -- a case is
    // never built configuration-less.
    XCTestSuite *suite =
        [XCTestSuite testSuiteForTestCaseClass:[XCTSuiteConstructionDiscoverySubclass class]];
    ok("the whole-class suite is a case suite",
       [suite isKindOfClass:[XCTestCaseSuite class]], NSStringFromClass([suite class]));
    ok("the whole-class suite is named for the class",
       [suite.name isEqualToString:@"XCTSuiteConstructionDiscoverySubclass"], suite.name);
    ok("every discovered test becomes a case", suite.tests.count == 3,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)suite.tests.count]);
    if (suite.tests.count == 3) {
        BOOL allCases = YES;
        BOOL allEmptyConfigurations = YES;
        for (XCTest *subtest in suite.tests) {
            allCases = allCases && [subtest isKindOfClass:[XCTestCase class]];
            allEmptyConfigurations = allCases &&
                [((XCTestCase *)subtest)._testRunConfiguration isEqualToDictionary:@{}];
        }
        ok("every discovered test is a runnable case", allCases, nil);
        ok("every discovered case was built under the empty configuration",
           allEmptyConfigurations, nil);
    }

    // The suite is built in the descriptor consumer's order, which sorts method
    // names without regard to case: testapple before testZebra, the opposite of
    // the bytewise order +testInvocations produced before the swap.
    XCTestSuite *caseSuite = [XCTestSuite testSuiteForTestCaseClass:[XCTSuiteConstructionCaseFixture class]];
    ok("a whole-class suite orders methods case-insensitively",
       caseSuite.tests.count == 2 && [[caseSuite.tests[0] _xctTestIdentifier].components[1]
           isEqualToString:@"testapple"],
       caseSuite.tests.count == 2
           ? [caseSuite.tests[0] _xctTestIdentifier].identifierString : nil);

    // The class-unavailable placeholder leg: a discovered test whose class
    // cannot run here still appears in the suite, as a placeholder named for
    // the test and carrying the class reason.
    XCTestSuite *unavailableSuite =
        [XCTestSuite testSuiteForTestCaseClass:
            [XCTSuiteConstructionUnavailableWithTestsFixture class]];
    ok("an unavailable class with tests keeps its plain suite",
       [unavailableSuite class] == [XCTestSuite class],
       NSStringFromClass([unavailableSuite class]));
    ok("the unavailable suite holds its test as a placeholder",
       unavailableSuite.tests.count == 1 &&
           [unavailableSuite.tests[0] isKindOfClass:[XCTestCasePlaceholder class]],
       [NSString stringWithFormat:@"%lu tests", (unsigned long)unavailableSuite.tests.count]);
    if (unavailableSuite.tests.count == 1) {
        XCTestCasePlaceholder *placeholder = unavailableSuite.tests[0];
        ok("the placeholder is named for its test",
           [[placeholder _xctTestIdentifier].identifierString
               isEqualToString:@"XCTSuiteConstructionUnavailableWithTestsFixture/testUnavailable"],
           [placeholder _xctTestIdentifier].identifierString);
        ok("the placeholder carries the class reason",
           [placeholder.reason isEqualToString:
               @"Test class 'XCTSuiteConstructionUnavailableWithTestsFixture' is unavailable "
               @"since it uses features not supported on this OS version"],
           placeholder.reason);
    }
}

static XCTTestIdentifier *identifierFromString(NSString *string)
{
    return [[XCTTestIdentifier alloc] initWithStringRepresentation:string];
}

static void testSelectorConstruction(void)
{
    printf("selector construction\n");

    // The fall-through leg resolves a plain class's selected tests from its
    // selectors: one case per requested identifier, each built under the
    // class's single empty variation. Picking one of the two methods keeps
    // exactly it.
    XCTTestIdentifier *zebra =
        identifierFromString(@"XCTSuiteConstructionCaseFixture/testZebra");
    XCTTestIdentifierSet *oneSelection =
        [[XCTTestIdentifierSet alloc] initWithTestIdentifier:zebra];
    XCTestSuite *selected =
        [XCTestSuite _constructTestSuiteForTestCaseClass:[XCTSuiteConstructionCaseFixture class]
                                              testIdentifiersToRun:oneSelection];
    ok("a selected identifier resolves to a case suite",
       [selected isKindOfClass:[XCTestCaseSuite class]], nil);
    ok("one selected identifier keeps exactly its test", selected.tests.count == 1,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)selected.tests.count]);
    if (selected.tests.count == 1) {
        XCTest *onlyTest = selected.tests[0];
        ok("the kept test is the selected method",
           [[[onlyTest _xctTestIdentifier] identifierString]
               isEqualToString:@"XCTSuiteConstructionCaseFixture/testZebra"],
           [[onlyTest _xctTestIdentifier] identifierString]);
        ok("the kept test is a runnable case",
           [onlyTest isKindOfClass:[XCTestCase class]], nil);
        ok("the kept case was built under the empty configuration",
           [((XCTestCase *)onlyTest)._testRunConfiguration isEqualToDictionary:@{}], nil);
    }

    // Both identifiers resolve to both tests, and neither is lost or dropped.
    XCTTestIdentifier *apple =
        identifierFromString(@"XCTSuiteConstructionCaseFixture/testapple");
    XCTTestIdentifierSet *bothSelections =
        [[XCTTestIdentifierSet alloc] initWithArray:@[ zebra, apple ]];
    XCTestSuite *both =
        [XCTestSuite _constructTestSuiteForTestCaseClass:[XCTSuiteConstructionCaseFixture class]
                                              testIdentifiersToRun:bothSelections];
    ok("both selected identifiers resolve to both tests", both.tests.count == 2,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)both.tests.count]);
    if (both.tests.count == 2) {
        NSSet *names = [NSSet setWithArray:@[
            [[[both.tests[0] _xctTestIdentifier] identifierString]
                componentsSeparatedByString:@"/"].lastObject,
            [[[both.tests[1] _xctTestIdentifier] identifierString]
                componentsSeparatedByString:@"/"].lastObject,
        ]];
        ok("the selected tests are the two requested methods",
           [names isEqualToSet:[NSSet setWithArray:@[ @"testapple", @"testZebra" ]]], nil);
    }

    // An identifier that resolves to no method contributes nothing.
    XCTTestIdentifier *unknown =
        identifierFromString(@"XCTSuiteConstructionCaseFixture/testNope");
    XCTTestIdentifierSet *unknownSelection =
        [[XCTTestIdentifierSet alloc] initWithTestIdentifier:unknown];
    XCTestSuite *unknownSuite =
        [XCTestSuite _constructTestSuiteForTestCaseClass:[XCTSuiteConstructionCaseFixture class]
                                              testIdentifiersToRun:unknownSelection];
    ok("an identifier that names no method keeps it out of the suite",
       unknownSuite.tests.count == 0,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)unknownSuite.tests.count]);

    // An empty selection builds an empty suite.
    XCTTestIdentifierSet *emptySelection = [[XCTTestIdentifierSet alloc] init];
    XCTestSuite *emptySuite =
        [XCTestSuite _constructTestSuiteForTestCaseClass:[XCTSuiteConstructionCaseFixture class]
                                              testIdentifiersToRun:emptySelection];
    ok("an empty selection builds an empty suite", emptySuite.tests.count == 0,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)emptySuite.tests.count]);

    // The first leg hands a class that customises +defaultTestSuite its own
    // suite, pruned to the selection.
    XCTTestIdentifier *beta =
        identifierFromString(@"XCTSuiteConstructionDefaultWithTestsFixture/testBeta");
    XCTTestIdentifierSet *betaSelection =
        [[XCTTestIdentifierSet alloc] initWithTestIdentifier:beta];
    XCTestSuite *pruned =
        [XCTestSuite _constructTestSuiteForTestCaseClass:
            [XCTSuiteConstructionDefaultWithTestsFixture class]
                                     testIdentifiersToRun:betaSelection];
    ok("the custom default suite is returned from the first leg",
       [pruned.name isEqualToString:@"ConstructionDefaultWithTests"], pruned.name);
    ok("pruning keeps only the selected test", pruned.tests.count == 1,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)pruned.tests.count]);
    if (pruned.tests.count == 1) {
ok("the pruned suite holds the selected method",
           [[[pruned.tests[0] _xctTestIdentifier] identifierString]
               isEqualToString:@"XCTSuiteConstructionDefaultWithTestsFixture/testBeta"],
           [[pruned.tests[0] _xctTestIdentifier] identifierString]);
     }

    // The same leg answers nil when the selection matches nothing in the
    // class's own suite, rather than a suite that would claim there was
    // something to run.
    XCTTestIdentifier *outsider =
        identifierFromString(@"XCTSuiteConstructionDefaultWithTestsFixture/testOther");
    XCTTestIdentifierSet *outsiderSelection =
        [[XCTTestIdentifierSet alloc] initWithTestIdentifier:outsider];
    XCTestSuite *noMatch =
        [XCTestSuite _constructTestSuiteForTestCaseClass:
            [XCTSuiteConstructionDefaultWithTestsFixture class]
                                     testIdentifiersToRun:outsiderSelection];
    ok("a selection that matches nothing in the class's own suite answers nil",
       noMatch == nil, nil);

    // The middle leg resolves a class that customises +testInvocations from
    // that list and filters it down to the selection.
    XCTTestIdentifier *first =
        identifierFromString(@"XCTSuiteConstructionInvocationsWithTestsFixture/testFirst");
    XCTTestIdentifierSet *firstSelection =
        [[XCTTestIdentifierSet alloc] initWithTestIdentifier:first];
    XCTestSuite *fromInvocations =
        [XCTestSuite _constructTestSuiteForTestCaseClass:
            [XCTSuiteConstructionInvocationsWithTestsFixture class]
                                     testIdentifiersToRun:firstSelection];
    ok("the invocations leg resolves from the class's own list",
       fromInvocations.tests.count == 1,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)fromInvocations.tests.count]);
    if (fromInvocations.tests.count == 1) {
ok("the invocation leg filtered to the selected method",
           [[[fromInvocations.tests[0] _xctTestIdentifier] identifierString]
               isEqualToString:
                   @"XCTSuiteConstructionInvocationsWithTestsFixture/testFirst"],
           [[fromInvocations.tests[0] _xctTestIdentifier] identifierString]);
    }

    // An empty selection sent down the same leg keeps nothing of the class's
    // invocation list.
    XCTestSuite *invocationsEmpty =
        [XCTestSuite _constructTestSuiteForTestCaseClass:
            [XCTSuiteConstructionInvocationsWithTestsFixture class]
                                     testIdentifiersToRun:emptySelection];
    ok("the invocations leg with an empty selection keeps nothing",
       invocationsEmpty.tests.count == 0,
       [NSString stringWithFormat:@"%lu tests", (unsigned long)invocationsEmpty.tests.count]);
}

static void testActivityObservation(void)
{
    // Activity start and finish are reported through a private protocol layered
    // on XCTestObservation, not through it. An observer has to opt in by
    // conforming to that protocol, and registration routes it to a list of its
    // own -- so the checks below are about the split, not just about delivery.
    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];

    ActivityObserverFixture *first = [[ActivityObserverFixture alloc] init];
    ActivityObserverFixture *second = [[ActivityObserverFixture alloc] init];
    ActivityObserverFixture *third = [[ActivityObserverFixture alloc] init];
    PublicObserverFixture *publicOnly = [[PublicObserverFixture alloc] init];

    [center addTestObserver:first];
    [center addTestObserver:second];
    [center addTestObserver:third];
    [center addTestObserver:publicOnly];

    ok("a private observer is listed as a private observer",
       [center.privateObservers containsObject:first], nil);
    ok("a public observer is not a private observer",
       ![center.privateObservers containsObject:publicOnly], nil);

    // Stands in for the XCTContext and XCActivityRecord the real activity path
    // passes. Neither is defined yet, and the observation center only ever
    // forwards them, so opaque placeholders are enough to pin the dispatch.
    XCTContext *context = (XCTContext *)@"context";
    XCActivityRecord *activity = (XCActivityRecord *)@"activity";

    [center _context:context willStartActivity:activity];

    ok("activity start reaches a private observer",
       [first _sawStart], nil);
    ok("activity start carries the context it was given",
       first.startContext == context, nil);
    ok("activity start carries the activity it was given",
       first.startActivity == activity, nil);
    ok("activity start is reported in registration order",
       first.order < second.order && second.order < third.order, nil);
    ok("activity start does not reach a public observer",
       !publicOnly.sawStart, nil);
    ok("activity start does not report a finish",
       ![first _sawFinish], nil);

    // Finish unwinds. Reporting it in the same order as start would tell a
    // reporter that the innermost of several nested activities ended before the
    // outermost one containing it, so the reference walks the list backwards.
    [center _context:context didFinishActivity:activity];

    ok("activity finish reaches a private observer",
       [first _sawFinish], nil);
    ok("activity finish carries the context it was given",
       first.finishContext == context, nil);
    ok("activity finish is reported in reverse registration order",
       third.order < second.order && second.order < first.order, nil);
    ok("activity finish does not reach a public observer",
       !publicOnly.sawFinish, nil);

    // Every method on the private protocol is optional, so an observer that
    // implements only one of the two callbacks must not be handed the other.
    ActivityStartOnlyFixture *startOnly = [[ActivityStartOnlyFixture alloc] init];
    [center addTestObserver:startOnly];
    [center _context:context willStartActivity:activity];
    [center _context:context didFinishActivity:activity];
    ok("an observer implementing only the start callback is filtered out of finish",
       [startOnly _sawStart] && startOnly.finishCount == 0, nil);

    // A reporter that throws is contained: it must not take down the run, and it
    // must not stop the observers after it from being called.
    ThrowingActivityObserverFixture *thrower = [[ThrowingActivityObserverFixture alloc] init];
    ActivityObserverFixture *afterThrower = [[ActivityObserverFixture alloc] init];
    [center addTestObserver:thrower];
    [center addTestObserver:afterThrower];
    [center _context:context willStartActivity:activity];
    ok("an observer that throws does not stop the ones after it",
       [afterThrower _sawStart], nil);
    [center removeTestObserver:thrower];

    // Suspension is what the runner uses while it tears down and re-arms, so
    // that teardown is not itself reported as activity.
    center.suspended = YES;
    ActivityObserverFixture *whileSuspended = [[ActivityObserverFixture alloc] init];
    [center addTestObserver:whileSuspended];
    [center _context:context willStartActivity:activity];
    ok("no activity is reported while observation is suspended",
       ![whileSuspended _sawStart], nil);
    center.suspended = NO;
    [center _context:context willStartActivity:activity];
    ok("activity is reported again once observation resumes",
       [whileSuspended _sawStart], nil);

    // Removal has to clear the private list too. An observer left behind would
    // keep receiving activity callbacks after the caller believes it detached.
    [center removeTestObserver:whileSuspended];
    whileSuspended.startCount = 0;
    [center _context:context willStartActivity:activity];
    ok("a removed private observer stops being called",
       whileSuspended.startCount == 0, nil);
    ok("a removed private observer leaves the private list",
       ![center.privateObservers containsObject:whileSuspended], nil);

    for (id observer in @[ first, second, third, publicOnly, startOnly, afterThrower,
                           whileSuspended ]) {
        [center removeTestObserver:observer];
    }
}

static void testPlaceholderObservation(void)
{
    // A placeholder reports its own skip through the reporting protocol above
    // the private one, and that protocol refines the private one -- so an
    // observer reaching it has to be in more than one list. The checks below
    // cover the routing before the delivery: an internal observer must not lose
    // the callbacks an exclusive-list split would have taken from it.
    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];

    PlaceholderObserverFixture *internal = [[PlaceholderObserverFixture alloc] init];
    ActivityObserverFixture *privateOnly = [[ActivityObserverFixture alloc] init];
    PublicObserverFixture *publicOnly = [[PublicObserverFixture alloc] init];

    [center addTestObserver:internal];
    [center addTestObserver:privateOnly];
    [center addTestObserver:publicOnly];

    ok("an internal observer is registered for the internal protocol",
       [center.internalObservers containsObject:internal], nil);
    ok("an internal observer is registered for the private protocol too",
       [center.privateObservers containsObject:internal], nil);
    ok("a private observer is registered for the private protocol",
       [center.privateObservers containsObject:privateOnly], nil);
    ok("a private observer is not registered for the internal protocol",
       ![center.internalObservers containsObject:privateOnly], nil);
    ok("a public observer is not registered for the private protocol",
       ![center.privateObservers containsObject:publicOnly], nil);
    ok("a public observer is not registered for the internal protocol",
       ![center.internalObservers containsObject:publicOnly], nil);

    // Additive rather than exclusive: opting into the narrower protocols must
    // not cost the internal observer its public callbacks.
    [center testSuiteWillStart:[XCTestSuite testSuiteWithName:@"Ping"]];
    ok("an internal observer still receives public callbacks",
       internal.sawPublicSuiteStart, nil);
    internal.sawPublicSuiteStart = NO;
    [center removeTestObserver:internal];
    ok("removal clears the internal list",
       ![center.internalObservers containsObject:internal], nil);
    ok("removal leaves the private list alone",
       [center.privateObservers containsObject:privateOnly], nil);

    // End to end: performing a placeholder drives the whole path, from the run
    // recording its skip to the observer being handed the unavailability.
    NSString *reason = @"Test is unavailable since it has no invocation";
    XCTestCasePlaceholder *placeholder =
        [[XCTestCasePlaceholder alloc]
            initWithIdentifier:[[XCTTestIdentifier alloc]
                                   initWithStringRepresentation:@"MyTests/testFoo"]
                        reason:reason];
    [center addTestObserver:internal];
    XCTestCasePlaceholderRun *performedRun =
        [[XCTestCasePlaceholderRun alloc] initWithTest:placeholder];
    [placeholder performTest:performedRun];
    ok("performing a placeholder reports the placeholder",
       internal.unavailablePlaceholder == placeholder, nil);
    ok("performing a placeholder reports the reason",
       [internal.unavailableReason isEqualToString:reason],
       internal.unavailableReason);
    ok("performing a placeholder still marks the run skipped",
       performedRun.hasBeenSkipped, nil);

    // A run reporting the placeholder event for a test that is not one is the
    // runner asserting against itself; the reference refuses and so does this.
    // The refusal carries the reference's own text, so it is matched by the
    // run's test rather than just by the exception name.
    XCTestCase *aCase = [XCTSuiteConstructionPlainFixture testCaseWithSelector:@selector(testExample)];
    XCTestRun *oddRun = [[XCTestRun alloc] initWithTest:aCase];
    BOOL raised = NO;
    NSString *raisedReason = nil;
    @try {
        [center _testCasePlaceholderRun:(XCTestCasePlaceholderRun *)oddRun
                 isUnavailableWithReason:@"surprise"];
    } @catch (NSException *exception) {
        raised = YES;
        raisedReason = exception.reason;
    }
    ok("a run whose test is not a placeholder is refused", raised, raisedReason);
    ok("the refusal names the run's test",
       [raisedReason rangeOfString:@"Reported test case event for non-XCTestCasePlaceholder instance"]
           .location != NSNotFound,
       raisedReason);

    // A run with no test at all is the one shape that cannot be checked, and
    // the reference lets it through rather than inventing a test to assert
    // against.
    internal.sawUnavailable = NO;
    [center _testCasePlaceholderRun:(XCTestCasePlaceholderRun *)[[NilTestRun alloc] init]
             isUnavailableWithReason:@"no test"];
    ok("a run with no test is reported without refusal",
       internal.sawUnavailable, nil);

    [center removeTestObserver:internal];
    [center removeTestObserver:privateOnly];
}

static void testSkipObservation(void)
{
    // A skip is recorded on a run and then broadcast: the run's own override
    // does the bookkeeping through -super and reports the result. The case-level
    // callback is declared on _XCTestObservationPrivate and the suite-level one
    // a protocol above it, so the checks below pin both the delivery and the
    // list the two are routed through.
    printf("test skip reporting\n");

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];

    SkipObserverFixture *observer = [[SkipObserverFixture alloc] init];
    PrivateSkipObserverFixture *privateOnly = [[PrivateSkipObserverFixture alloc] init];
    [center addTestObserver:observer];
    [center addTestObserver:privateOnly];

    ok("a skip observer is registered for the internal protocol",
       [center.internalObservers containsObject:observer], nil);
    ok("a skip observer is registered for the private protocol too",
       [center.privateObservers containsObject:observer], nil);

    XCTSourceCodeContext *context = (XCTSourceCodeContext *)@"context";

    // A case run records a skip on itself; the base marks it skipped, and only
    // then does the override tell the private observers.
    XCTestCase *aCase =
        [XCTSuiteConstructionPlainFixture testCaseWithSelector:@selector(testExample)];
    XCTestCaseRun *caseRun = [[XCTestCaseRun alloc] initWithTest:aCase];
    [caseRun start];
    [caseRun recordSkipWithDescription:@"not today" sourceCodeContext:context];

    ok("recording a case skip marks the run skipped", caseRun.hasBeenSkipped, nil);
    ok("a case skip reaches the case callback", observer.caseSkipCount == 1, nil);
    ok("a case skip is reported against the run's test case",
       observer.skippedCase == aCase, nil);
    ok("a case skip carries the description it was given",
       [observer.skippedCaseDescription isEqualToString:@"not today"], nil);
    ok("a case skip carries the source context it was given",
       observer.skippedCaseContext == context, nil);
    ok("a case skip reaches a private-only observer",
       privateOnly.caseSkipCount == 1, nil);
    ok("a case skip does not reach the suite callback",
       observer.suiteSkipCount == 0, nil);

    // A suite run records one level up; the private-only observer, which does
    // not conform to the protocol that declares this callback, must not see it.
    XCTestSuite *aSuite =
        [XCTestSuite testSuiteForTestCaseClass:[XCTSuiteConstructionPlainFixture class]];
    XCTestSuiteRun *suiteRun = [[XCTestSuiteRun alloc] initWithTest:aSuite];
    [suiteRun start];
    [suiteRun recordSkipWithDescription:@"whole class skipped" sourceCodeContext:context];

    ok("recording a suite skip marks the run skipped", suiteRun.hasBeenSkipped, nil);
    ok("a suite skip reaches the suite callback", observer.suiteSkipCount == 1, nil);
    ok("a suite skip is reported against the run's suite",
       observer.skippedSuite == aSuite, nil);
    ok("a suite skip carries the description it was given",
       [observer.skippedSuiteDescription isEqualToString:@"whole class skipped"], nil);
    ok("a suite skip carries the source context it was given",
       observer.skippedSuiteContext == context, nil);
    ok("a suite skip does not reach a private-only observer",
       privateOnly.caseSkipCount == 1, nil);

    // The base bookkeeping still guards the report: a run that never started,
    // and one already stopped, each refuse -- and a refusal never reaches an
    // observer.
    observer.caseSkipCount = 0;
    XCTestCaseRun *unstarted = [[XCTestCaseRun alloc] initWithTest:aCase];
    BOOL raised = NO;
    @try {
        [unstarted recordSkipWithDescription:@"too soon" sourceCodeContext:context];
    } @catch (NSException *exception) {
        raised = YES;
    }
    ok("a skip on a run that has not started is refused", raised, nil);
    ok("a refused skip never reaches an observer",
       observer.caseSkipCount == 0, nil);

    XCTestCaseRun *stopped = [[XCTestCaseRun alloc] initWithTest:aCase];
    [stopped start];
    [stopped stop];
    raised = NO;
    @try {
        [stopped recordSkipWithDescription:@"too late" sourceCodeContext:context];
    } @catch (NSException *exception) {
        raised = YES;
    }
    ok("a skip on a stopped run is refused", raised, nil);

    // A case or suite run whose test is the wrong kind for the event it reports
    // is the reporting layer against itself. The refusal carries the reference's
    // own text, matched by the run's test rather than just the exception name.
    XCTestSuite *notACase = [XCTestSuite testSuiteWithName:@"NotACase"];
    XCTestCaseRun *oddCaseRun = [[XCTestCaseRun alloc] initWithTest:notACase];
    [oddCaseRun start];
    raised = NO;
    NSString *refusal = nil;
    @try {
        [oddCaseRun recordSkipWithDescription:@"surprise" sourceCodeContext:context];
    } @catch (NSException *exception) {
        raised = YES;
        refusal = exception.reason;
    }
    ok("a case run whose test is not a case is refused", raised, refusal);
    ok("the refusal names the run's test",
       [refusal rangeOfString:@"Reported test case event for non-test case object"].location != NSNotFound,
       refusal);

    XCTestSuiteRun *oddSuiteRun = [[XCTestSuiteRun alloc] initWithTest:aCase];
    [oddSuiteRun start];
    raised = NO;
    refusal = nil;
    @try {
        [oddSuiteRun recordSkipWithDescription:@"surprise" sourceCodeContext:context];
    } @catch (NSException *exception) {
        raised = YES;
        refusal = exception.reason;
    }
    ok("a suite run whose test is not a suite is refused", raised, refusal);
    ok("the refusal names the run's test",
       [refusal rangeOfString:@"Reported test suite event for non-suite test object"].location != NSNotFound,
       refusal);

    // A run with no test is the one case-level shape that cannot be checked, so
    // it is reported rather than refused -- the same allowance the placeholder
    // broadcast makes.
    observer.caseSkipCount = 0;
    [center _testCaseWasSkipped:(XCTestCaseRun *)[[NilTestRun alloc] init]
                withDescription:@"no test"
              sourceCodeContext:context];
    ok("a case skip from a run with no test is reported without refusal",
       observer.caseSkipCount == 1, nil);

    [center removeTestObserver:observer];
    [center removeTestObserver:privateOnly];
}

void testActivityRecord(void)
{
    // These are about the recovered semantics rather than about the plumbing: a
    // record is the identity, timing and attachment store an activity tree is
    // assembled from, and its defaults are what make a hand-built record in a
    // test stand in for a real one.
    XCActivityRecord *record = [[XCActivityRecord alloc] init];

    ok("a new record is valid",
       record.isValid, nil);
    ok("a new record has an identifier",
       record.uuid.UUIDString.length > 0, nil);
    ok("a new record has no parent",
       record.parentID == nil, nil);
    ok("a new record's title is empty, not nil",
       [record.title isEqualToString:@""], nil);
    ok("a record's name is its title",
       [record.name isEqualToString:record.title], nil);
    ok("a new record has a start but no finish",
       record.start != nil && record.finish == nil, nil);
    ok("a new record is not top level",
       !record.isTopLevel, nil);
    ok("a new record carries no ancillary context",
       !record.hasAncillaryContext, nil);
    ok("a new record aggregates under the reference's default",
       [record.aggregationIdentifier isEqualToString:@"Other"], nil);
    ok("a new record does not use the legacy serialization format",
       !record.useLegacySerializationFormat, nil);
    ok("a new record has no children yet",
       record.subactivitiesDuration == 0.0, nil);

    // Parent identity is how the tree is rebuilt: a child names its parent by
    // UUID rather than holding a reference, so the two must agree.
    XCActivityRecord *child = [[XCActivityRecord alloc] initWithParentID:record.uuid];
    ok("a child records its parent's identifier",
       [child.parentID isEqual:record.uuid], nil);
    ok("a child gets an identifier of its own",
       ![child.uuid isEqual:record.uuid], nil);
    ok("a child starts as valid",
       child.isValid, nil);

    // Duration is the reference's own definition: the gap between the two
    // timestamps, both of which are stamped at init. It is not a running clock.
    record.start = [NSDate dateWithTimeIntervalSince1970:1000.0];
    record.finish = [NSDate dateWithTimeIntervalSince1970:1002.5];
    ok("duration is the gap between start and finish",
       fabs(record.duration - 2.5) < 0.001,
       [NSString stringWithFormat:@"%.3f", record.duration]);

    // A finish that never got stamped must not read as a negative or absurd
    // span; the reference guards the subtraction rather than trusting it.
    record.finish = nil;
    ok("duration is zero while the finish is unset",
       record.duration == 0.0,
       [NSString stringWithFormat:@"%.3f", record.duration]);
    ok("a brand new record has no duration yet",
       [[XCActivityRecord alloc] init].duration == 0.0, nil);

    // Children report how long they took, and the parent accumulates it. This is
    // what the stack forwards through -subactivityCompletedWithDuration:.
    [record subactivityCompletedWithDuration:1.25];
    [record subactivityCompletedWithDuration:2.75];
    ok("child durations accumulate",
       fabs(record.subactivitiesDuration - 4.0) < 0.001,
       [NSString stringWithFormat:@"%.3f", record.subactivitiesDuration]);

    // Metadata is read and written by key, and the tree's aggregation fields are
    // set alongside it, so the surface has to be a mutable dictionary rather than
    // an immutable one.
    ok("a new record has no metadata",
       record.metadata == nil, nil);
    // Assigning through the property, not subscripting in place: the reference's
    // init leaves the dictionary absent, so a caller supplies it.
    record.metadata = [NSMutableDictionary dictionary];
    record.metadata[@"k"] = @"v";
    ok("metadata is writable by key",
       [record.metadata[@"k"] isEqualToString:@"v"], nil);
    ok("metadata returns what was stored",
       [record.metadata isEqualToDictionary:@{@"k": @"v"}], nil);

    record.title = @"Suite Set Up";
    ok("a record's name follows its title",
       [record.name isEqualToString:@"Suite Set Up"], nil);

    record.activityType = @"com.apple.dt.xctest.activity-type.ui-testing";
    ok("the activity type is stored",
       [record.activityType isEqualToString:@"com.apple.dt.xctest.activity-type.ui-testing"], nil);

    // Attachments are ordered, and the read-only view is a snapshot rather than
    // the live collection: a caller that walks it must not be able to mutate the
    // record through it.
    XCTAttachment *first = [XCTAttachment attachmentWithUniformTypeIdentifier:nil];
    XCTAttachment *second = [XCTAttachment attachmentWithUniformTypeIdentifier:nil];
    first.name = @"first";
    second.name = @"second";
    [record addAttachment:first];
    [record addAttachment:second];

    ok("attachments keep the order they were added in",
       record.attachments.count == 2 &&
       [((XCTAttachment *)[record.attachments objectAtIndex:0]).name isEqualToString:@"first"] &&
       [((XCTAttachment *)[record.attachments objectAtIndex:1]).name isEqualToString:@"second"], nil);
    ok("an attachment can be found by name",
       [record attachmentForName:@"second"] == second, nil);
    ok("an unknown attachment name finds nothing",
       [record attachmentForName:@"absent"] == nil, nil);
    ok("the attachment view is a copy",
       record.attachments != record.mutableAttachments, nil);

    [record removeAttachmentsWithName:@"first"];
    ok("removing by name drops every match",
       record.attachments.count == 1 &&
       [((XCTAttachment *)[record.attachments objectAtIndex:0]).name isEqualToString:@"second"], nil);

    // Invalidation is the scope boundary. Everything that mutates must refuse
    // afterwards, and the failure has to be the reference's own message.
    [record invalidate];
    ok("an invalidated record is no longer valid",
       !record.isValid, nil);

    XCTAttachment *late = [XCTAttachment attachmentWithUniformTypeIdentifier:nil];
    BOOL raised = NO;
    @try {
        [record addAttachment:late];
    } @catch (NSException *exception) {
        raised = [[exception reason] containsString:@"Activity cannot be used after its scope has completed."];
    }
    ok("mutating an invalidated record raises", raised, nil);
    ok("an invalidated record keeps the attachments it already had",
       record.attachments.count == 1, nil);
}


// The context an activity is reported into. Its job is to own the stack of what
// is running right now, and to be reachable from the code that is running it --
// which means the thread has to be able to find it, and a nested activity has to
// land in the same report the surrounding one goes into.
static void testContext(void)
{
    printf("\nXCTContext\n");

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    ActivityObserverFixture *observer = [[ActivityObserverFixture alloc] init];
    [center addTestObserver:observer];

    // A context cannot be made with -init, so the only way to get one is to ask
    // for the running one. On the main thread, where nothing is running yet,
    // that means one is created and adopted.
    XCTContext *context = [XCTContext currentContextIfAvailable];
    ok("a context is available on the main thread", context != nil, nil);
    ok("asking again returns the same context",
       [XCTContext currentContextIfAvailable] == context, nil);
    ok("+hasCurrentContext agrees", [XCTContext hasCurrentContext], nil);
    ok("+currentContext agrees", [XCTContext currentContext] == context, nil);

    ok("a new context is valid", [context isValid], nil);
    ok("a new context starts at depth zero", context.activityRecordStackDepth == 0, nil);
    ok("a new context has no top activity", context.topActivity == nil, nil);
    ok("a new context has aggregated nothing",
       context.aggregationRecords.count == 0, nil);
    ok("a new context has a start date", context.startDate != nil, nil);
    ok("a new context has no parent", context.parent == nil, nil);
    ok("a new context is not the reporting base", !context.isReportingBase, nil);
    ok("a new context is not ancillary", !context.isAncillaryContext, nil);
    ok("a new context is bound to the thread that made it",
       [context isBoundToCurrentThread], nil);
    ok("a new context is reachable from itself", context.associatedContexts.count > 0, nil);

    // The activity path: a name becomes a record, the record is on top while the
    // block runs, and it is off the stack once the block returns.
    XCActivityRecord *started = [context willStartActivityWithTitle:@"one" type:@"test.type"];
    ok("starting an activity makes one", started != nil, nil);
    ok("the activity has the name it was given", [started.name isEqualToString:@"one"], nil);
    ok("the activity has the type it was given",
       [started.activityType isEqualToString:@"test.type"], nil);
    ok("the started activity is on top", context.topActivity == started, nil);
    ok("the stack is one deep", context.activityRecordStackDepth == 1, nil);
    ok("the activity is still valid", started.isValid, nil);
    ok("an activity reports its start to a private observer",
       observer.startCount == 1, nil);
    ok("the observer is handed the context it ran in",
       observer.startContext == context, nil);
    ok("the observer is handed the activity",
       observer.startActivity == started, nil);

    XCActivityRecord *inner = [context willStartActivityWithTitle:@"two" type:@"test.type"];
    ok("a nested activity goes on top", context.topActivity == inner, nil);
    ok("a nested activity makes the stack deeper", context.activityRecordStackDepth == 2, nil);
    ok("a nested activity records its parent", inner.parentID != nil, nil);
    ok("the parent is the record it was started inside",
       [inner.parentID isEqual:started.uuid], nil);

    [context didFinishActivity:inner];
    ok("finishing pops back to the outer activity", context.topActivity == started, nil);
    ok("a finished activity is invalid", !inner.isValid, nil);
    ok("a finished activity has a duration", inner.duration >= 0.0, nil);
    ok("the finish is reported", observer.finishCount == 1, nil);
    ok("the finished activity reports itself", observer.finishActivity == inner, nil);

    [context didFinishActivity:started];
    ok("finishing the last activity empties the stack", context.activityRecordStackDepth == 0, nil);
    ok("an empty stack has no top activity", context.topActivity == nil, nil);
    ok("aggregation is recorded once something has run",
       context.aggregationRecords.count > 0, nil);

    // Unwinding: a context that is abandoned with activities still running must
    // still finish them, or they stay open for the rest of the run.
    [context willStartActivityWithTitle:@"dangling" type:@"test.type"];
    [context willStartActivityWithTitle:@"also dangling" type:@"test.type"];
    ok("two activities are running before the unwind",
       context.activityRecordStackDepth == 2, nil);
    [context unwindRemainingActivities];
    ok("unwinding empties the stack", context.activityRecordStackDepth == 0, nil);

    // Associated state and tear-down.
    [context setAssociatedObject:@"value" forKey:@"key"];
    ok("an associated value reads back", [[context associatedObjectForKey:@"key"] isEqualToString:@"value"], nil);
    ok("an unknown key finds nothing", [context associatedObjectForKey:@"missing"] == nil, nil);

    __block BOOL toreDown = NO;
    [context addTearDownBlock:^{ toreDown = YES; }];
    ok("a tear-down block does not run yet", !toreDown, nil);
    [context invalidate];
    ok("invalidating runs the tear-down block", toreDown, nil);
    ok("invalidating makes the context invalid", ![context isValid], nil);
    ok("invalidating clears associated values",
       [context associatedObjectForKey:@"key"] == nil, nil);

    __block NSUInteger secondInvalidate = 0;
    [context invalidate];
    secondInvalidate++;
    ok("invalidating again does nothing", secondInvalidate == 1 && toreDown, nil);

    // The public entry point. This is the whole of what a test author has, so
    // what matters is that the activity is reported under the name they gave,
    // that it is finished even if the block throws, and that nothing is left on
    // the stack afterwards.
    __block NSUInteger startsBefore = observer.startCount;
    __block NSString *reportedName = nil;
    __block NSString *reportedType = nil;
    __block BOOL sawActivity = NO;

    XCTContext *before = [XCTContext currentContextIfAvailable];
    NSUInteger depthBefore = before.activityRecordStackDepth;

    [XCTContext runActivityNamed:@"public activity" block:^(id<XCTActivity> activity) {
        sawActivity = YES;
        reportedName = activity.name;
        // The block runs inside the activity, so the activity is on top of the
        // stack for as long as it runs.
        reportedType = ((XCActivityRecord *)activity).activityType;
        ok("the activity is on top while its block runs",
           before.topActivity == (XCActivityRecord *)activity, nil);
        ok("the stack is one deeper while its block runs",
           before.activityRecordStackDepth == depthBefore + 1, nil);
    }];

    ok("the block is given the activity", sawActivity, nil);
    ok("the activity carries the name that was asked for",
       [reportedName isEqualToString:@"public activity"], nil);
    ok("a user-created activity has the user-created type",
       [reportedType isEqualToString:@"com.apple.dt.xctest.activity-type.userCreated"], nil);
    ok("the activity is reported", observer.startCount == startsBefore + 1, nil);
    ok("the stack is back to where it was", before.activityRecordStackDepth == depthBefore, nil);

    // A block that throws has still finished. If it had not, the activity would
    // stay open and every later finish would be one record out of step with it.
    __block NSUInteger depthAfterThrow = 0;
    @try {
        [XCTContext runActivityNamed:@"throwing activity" block:^(id<XCTActivity> activity) {
            (void)activity;
            depthAfterThrow = before.activityRecordStackDepth;
            [NSException raise:NSGenericException format:@"from inside the activity"];
        }];
        ok("a throwing block propagates its exception", NO, nil);
    } @catch (NSException *exception) {
        ok("a throwing block propagates its exception", YES, nil);
    }
    ok("the activity was running when the block threw",
       depthAfterThrow == depthBefore + 1, nil);
    ok("a throwing block still leaves nothing running",
       before.activityRecordStackDepth == depthBefore, nil);

    [center removeTestObserver:observer];
}

// A suite that stands for a class has to run that class's +setUp and +tearDown,
// and has to stay quiet when the class has neither. The way to tell is the IMP:
// asking whether the class responds is no use, because every subclass inherits
// both from XCTestCase.
static void testCaseSuiteLifecycle(void)
{
    printf("\nXCTestCaseSuite lifecycle\n");

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    ActivityObserverFixture *observer = [[ActivityObserverFixture alloc] init];
    [center addTestObserver:observer];

    // A class that does nothing: the suite runs neither, and no activity is
    // reported for it.
    XCTestSuite *plain = [XCTestSuite emptyTestSuiteForTestCaseClass:[XCTSuiteConstructionPlainFixture class]];
    NSUInteger before = observer.startCount;
    [plain setUp];
    [plain tearDown];
    ok("a class with no +setUp reports no suite set-up", observer.startCount == before, nil);
    ok("a class with no +tearDown reports no suite tear-down", observer.startCount == before, nil);

    // A class with its own: both run. Whether each is *reported* is a separate
    // question, answered by the reporting filter rather than by this code --
    // see testActivityReportingFilter. Here the run is a unit-test run, so the
    // runner's own activities are not reportable and nothing is announced.
    XCTestSuite *withSetup = [XCTestSuite emptyTestSuiteForTestCaseClass:[XCTSuiteConstructionSetupFixture class]];
    ok("the fixture starts with nothing run",
       XCTSuiteConstructionSetupFixture.setUpCount == 0 && XCTSuiteConstructionSetupFixture.tearDownCount == 0,
       nil);

    before = observer.startCount;
    [withSetup setUp];
    ok("the class's +setUp is run by the suite", XCTSuiteConstructionSetupFixture.setUpCount == 1, nil);
    ok("the suite's set-up is not reported in a unit-test run",
       observer.startCount == before, nil);

    before = observer.startCount;
    [withSetup tearDown];
    ok("the class's +tearDown is run by the suite", XCTSuiteConstructionSetupFixture.tearDownCount == 1, nil);
    ok("the suite's tear-down is not reported in a unit-test run",
       observer.startCount == before, nil);

    // Same suite, same code, run reported: a UI-test run keeps every type, so
    // the phase shows up and the name and type are the ones chosen above.
    XCTestConfiguration *configuration = XCTestConfiguration.activeTestConfiguration;
    configuration.initializeForUITesting = YES;

    before = observer.startCount;
    [withSetup setUp];
    ok("the suite's set-up is reported in a UI-test run", observer.startCount == before + 1, nil);
    ok("the suite's set-up activity is named for the phase",
       [observer.startActivity.name isEqualToString:@"Suite Set Up"], observer.startActivity.name);
    ok("the suite's set-up is the framework's own activity",
       [observer.startActivity.activityType isEqualToString:@"com.apple.dt.xctest.activity-type.internal"],
       observer.startActivity.activityType);
    ok("the suite's set-up activity reports the context it ran in",
       observer.startContext == [XCTContext currentContextIfAvailable], nil);

    before = observer.startCount;
    [withSetup tearDown];
    ok("the suite's tear-down is reported in a UI-test run", observer.startCount == before + 1, nil);
    ok("the suite's tear-down activity is named for the phase",
       [observer.startActivity.name isEqualToString:@"Suite Tear Down"], observer.startActivity.name);

    configuration.initializeForUITesting = NO;
    [center removeTestObserver:observer];
}

// Which activities a run keeps. The gate is the type, not the name and not the
// caller, so a name chosen by the framework can be just as reportable as one
// chosen by a test -- and, the other way, a name a test chose can be dropped if
// the type says so.
static void testActivityReportingFilter(void)
{
    printf("\nactivity reporting filter\n");

    XCTestConfiguration *configuration = XCTestConfiguration.activeTestConfiguration;

    // A UI-test run is told where it is and answers from that alone; the type is
    // not consulted, so even a type no run would otherwise keep survives.
    ok("a UI-test run reports a user-created activity",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"
                                    inTestMode:XCTTestModeUITests], nil);
    ok("a UI-test run reports an internal activity",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.internal"
                                    inTestMode:XCTTestModeUITests], nil);
    ok("a UI-test run reports a type no run would otherwise keep",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.deletedAttachment"
                                    inTestMode:XCTTestModeUITests], nil);
    ok("a UI-test run reports a type nobody has heard of",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.notAType"
                                    inTestMode:XCTTestModeUITests], nil);

    // A unit-test run answers from a fixed set, so every member is kept and
    // everything else is dropped -- including the framework's own.
    ok("a unit-test run reports a user-created activity",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"
                                    inTestMode:XCTTestModeUnitTests], nil);
    ok("a unit-test run reports an attachment container",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.attachmentContainer"
                                    inTestMode:XCTTestModeUnitTests], nil);
    ok("a unit-test run reports a test assertion failure",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.testAssertionFailure"
                                    inTestMode:XCTTestModeUnitTests], nil);
    ok("a unit-test run reports a skipped test",
       [XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.skippedTest"
                                    inTestMode:XCTTestModeUnitTests], nil);
    ok("a unit-test run does not report an internal activity",
       ![XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.internal"
                                     inTestMode:XCTTestModeUnitTests], nil);
    ok("a unit-test run does not report a deleted attachment",
       ![XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.deletedAttachment"
                                     inTestMode:XCTTestModeUnitTests], nil);

    // The configuration-facing form asks the run first, and its own switch is
    // asked before the type: a run that has turned reporting off has said so
    // about everything.
    ok("a unit-test run reports what its mode keeps",
       [XCTContext _shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"], nil);
    ok("a unit-test run drops what its mode does not",
       ![XCTContext _shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.internal"], nil);

    configuration.initializeForUITesting = YES;
    ok("the same type is reportable once the mode says so",
       [XCTContext _shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.internal"], nil);
    configuration.initializeForUITesting = NO;

    configuration.reportActivities = NO;
    ok("a run with reporting off reports nothing",
       ![XCTContext _shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"], nil);
    ok("reporting being off outranks the mode",
       ![XCTContext shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"
                                     inTestMode:XCTTestModeUITests] == NO, nil);
    configuration.reportActivities = YES;

    // No configuration is no run, so there is nothing to report to. Asked through
    // a mode this does not answer -- there is no mode without a run -- so it
    // reports nothing rather than everything.
    XCTestConfiguration *saved = configuration;
    XCTestConfiguration.activeTestConfiguration = nil;
    ok("with no configuration nothing is reported",
       ![XCTContext _shouldReportActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"], nil);
    XCTestConfiguration.activeTestConfiguration = saved;

    // What the filter drops, the block still sees -- as nothing. The work runs;
    // only the record is withheld, so a block handed nil has nothing to attach.
    XCTContext *context = [XCTContext currentContextIfAvailable];
    __block BOOL ranWithoutActivity = NO;
    __block id<XCTActivity> handedActivity = (id)@"sentinel";
    NSUInteger before = context.activityRecordStackDepth;
    [context _runActivityNamed:@"Dropped"
                          type:@"com.apple.dt.xctest.activity-type.internal"
                         block:^(id<XCTActivity> activity) {
        ranWithoutActivity = YES;
        handedActivity = activity;
    }];
    ok("a dropped activity still runs its block", ranWithoutActivity, nil);
    ok("a dropped activity hands the block nothing", handedActivity == nil, nil);
    ok("a dropped activity leaves the stack where it was",
       context.activityRecordStackDepth == before, nil);

    // And a kept one behaves as before: reported, non-nil, pushed and popped.
    __block id<XCTActivity> keptActivity = nil;
    [context _runActivityNamed:@"Kept"
                          type:@"com.apple.dt.xctest.activity-type.userCreated"
                         block:^(id<XCTActivity> activity) {
        keptActivity = activity;
        ok("a kept activity is on the stack while its block runs",
           context.activityRecordStackDepth == before + 1, nil);
    }];
    ok("a kept activity hands the block the record", keptActivity != nil, nil);
    ok("a kept activity leaves the stack where it was",
       context.activityRecordStackDepth == before, nil);
}

// An empty suite is only worth showing when it still means something, and the
// judge is the setUp it runs rather than what kind of suite it is.
static void testEmptySuiteInclusion(void)
{
    printf("\nempty suite inclusion\n");

    // A suite with tests in it is never in question.
    XCTestSuite *populated = [XCTestSuite emptyTestSuiteForTestCaseClass:[XCTSuiteConstructionPlainFixture class]];
    [populated addTest:[[XCTSuiteConstructionPlainFixture alloc] init]];
    ok("a suite with tests is included", [populated shouldIncludeWhenIncludingEmptySuites], nil);
    ok("the test really landed in it", populated.tests.count == 1, nil);

    // An empty case suite stands for a runnable class that contributed no tests,
    // which is a filtering outcome rather than a fact about the platform, so it
    // is dropped.
    XCTestSuite *caseSuite = [XCTestSuite emptyTestSuiteForTestCaseClass:[XCTSuiteConstructionPlainFixture class]];
    ok("the empty case suite is a case suite",
       [caseSuite isKindOfClass:[XCTestCaseSuite class]], NSStringFromClass([caseSuite class]));
    ok("an empty case suite is excluded", ![caseSuite shouldIncludeWhenIncludingEmptySuites], nil);

    // An empty plain suite is what a class that cannot run here gets. It is
    // kept: the report should say the class is present with nothing under it.
    XCTestSuite *plainSuite = [XCTestSuite emptyTestSuiteForTestCaseClass:[XCTSuiteConstructionUnavailableFixture class]];
    ok("the empty plain suite is not a case suite",
       [plainSuite class] == [XCTestSuite class], NSStringFromClass([plainSuite class]));
    ok("an empty plain suite is included", [plainSuite shouldIncludeWhenIncludingEmptySuites], nil);

    // A suite with a setUp of its own is neither of those, and is dropped.
    XCTestSuite *subclassSuite = [[XCTSuiteConstructionSuiteWithSetUpFixture alloc] initWithName:@"Subclass"];
    ok("the subclass suite's setUp is its own",
       [subclassSuite methodForSelector:@selector(setUp)] != [XCTestSuite instanceMethodForSelector:@selector(setUp)],
       nil);
    ok("an empty suite with its own setUp is excluded",
       ![subclassSuite shouldIncludeWhenIncludingEmptySuites], nil);

    // The comparison is by IMP on the object, not by kind: a case suite that has
    // been given tests is included even though it is one.
    ok("a case suite with tests is included", [populated shouldIncludeWhenIncludingEmptySuites], nil);
}

// A child context exists so that work started inside it can be unwound with it.
// Everything about that is a claim about ordering -- pushed before, unwound
// after, removed in between -- so these checks are mostly about the sequence
// rather than about any one value.
static void testChildContext(void)
{
    printf("\nchild context\n");

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    ActivityObserverFixture *observer = [[ActivityObserverFixture alloc] init];
    [center addTestObserver:observer];

    XCTContext *outer = [XCTContext currentContextIfAvailable];
    ok("the outer context is the one running", [XCTContext currentContextIfAvailable] == outer, nil);

    __block XCTContext *child = nil;
    __block XCTContext *innerWhileRunning = nil;
    NSUInteger outerDepth = outer.activityRecordStackDepth;

    [XCTContext runInContextForTestCase:nil block:^{
        child = [XCTContext currentContextIfAvailable];
        innerWhileRunning = child;
        ok("the child is the context running inside the block", child != outer, nil);
        ok("the child is on the stack above the outer one",
           child.isBoundToCurrentThread && outer.isBoundToCurrentThread, nil);
        ok("the child starts empty", child.activityRecordStackDepth == 0, nil);
        ok("the child has no test case when none was given", child.testCase == nil, nil);
    }];

    ok("the block ran", child != nil, nil);
    ok("the child is gone from the stack once the block returns",
       ![child isBoundToCurrentThread], nil);
    ok("the outer context is running again",
       [XCTContext currentContextIfAvailable] == outer, nil);
    ok("the outer context's depth is untouched", outer.activityRecordStackDepth == outerDepth, nil);
    ok("the child was invalidated on the way out", !child.isValid, nil);

    // The parent is named, not implied: the child hangs off what it was given,
    // and the reporting base is fixed at that moment rather than being asked for.
    __block XCTContext *childUnderOuter = nil;
    __block XCTContext *baseWhileRunning = nil;
    [outer runInContextForTestCase:nil block:^{
        childUnderOuter = [XCTContext currentContextIfAvailable];
        baseWhileRunning = childUnderOuter.reportingBaseContext;
    }];
    ok("the child hangs off the context it was named under",
       childUnderOuter.parent == outer, nil);
    ok("a child that is not a reporting base has no reporting base of its own",
       !childUnderOuter.isReportingBase, nil);
    ok("nothing is a reporting base here, so there is none to report to",
       baseWhileRunning == nil, nil);

    // Marked as the base, it is its own answer. This is the difference
    // markAsReportingBase: exists to make: activities under it report here rather
    // than being gathered under whatever was already running.
    __block XCTContext *marked = nil;
    __block XCTContext *markedBaseWhileRunning = nil;
    [XCTContext runInContextForTestCase:nil markAsReportingBase:YES block:^{
        marked = [XCTContext currentContextIfAvailable];
        markedBaseWhileRunning = marked.reportingBaseContext;
    }];
    ok("a reporting base is marked", marked.isReportingBase, nil);
    ok("a reporting base is its own reporting base",
       markedBaseWhileRunning == marked, nil);

    // The walk, not just the self-answer: a plain child under a reporting base
    // finds that base rather than itself, which is what lets a nested run report
    // where it was told to rather than wherever it happens to sit.
    __block XCTContext *grandchild = nil;
    __block XCTContext *grandchildBase = nil;
    [XCTContext runInContextForTestCase:nil markAsReportingBase:YES block:^{
        XCTContext *middle = [XCTContext currentContextIfAvailable];
        [middle runInContextForTestCase:nil block:^{
            grandchild = [XCTContext currentContextIfAvailable];
            grandchildBase = grandchild.reportingBaseContext;
        }];
    }];
    ok("a plain child under a reporting base is not one itself",
       !grandchild.isReportingBase, nil);
    ok("a plain child under a reporting base finds it",
       grandchildBase != grandchild && grandchildBase != nil, nil);

    // A test case is carried, weakly, and read back out.
    XCTSuiteConstructionPlainFixture *testCase = [[XCTSuiteConstructionPlainFixture alloc] init];
    __block XCTContext *withTestCase = nil;
    [XCTContext runInContextForTestCase:testCase block:^{
        withTestCase = [XCTContext currentContextIfAvailable];
    }];
    ok("the child knows its test case", withTestCase.testCase == testCase, nil);

    // Activities started inside the child unwind with it, and are reported against
    // the child rather than the outer context -- which is the whole reason for
    // having a child.
    XCTestCase *outerCase = [[XCTSuiteConstructionPlainFixture alloc] init];
    NSUInteger before = observer.startCount;
    [outer runInContextForTestCase:outerCase block:^{
        XCTContext *inner = [XCTContext currentContextIfAvailable];
        [inner _runActivityNamed:@"Inside child"
                             type:@"com.apple.dt.xctest.activity-type.userCreated"
                            block:^(id<XCTActivity> activity) {
            (void)activity;
            ok("the activity lands in the child", observer.startContext == inner, nil);
            ok("the outer context's stack is not disturbed",
               outer.activityRecordStackDepth == outerDepth, nil);
        }];
    }];
    ok("the activity was reported", observer.startCount == before + 1, nil);
    ok("it was reported before the block left", observer.finishCount == before + 1, nil);

    // A block that throws still unwinds. This is the case that decides whether the
    // @finally is there at all: a context left valid and on the stack would go on
    // accepting activities that nothing can report, and every later lookup of the
    // running context would find the wrong one.
    __block XCTContext *thrownFrom = nil;
    NSUInteger depthBeforeThrow = [XCTContext currentContextIfAvailable].activityRecordStackDepth;
    BOOL raised = NO;
    @try {
        [XCTContext runInContextForTestCase:nil block:^{
            thrownFrom = [XCTContext currentContextIfAvailable];
            [thrownFrom _runActivityNamed:@"Never finished"
                                      type:@"com.apple.dt.xctest.activity-type.userCreated"
                                     block:^(id<XCTActivity> activity) {
                (void)activity;
                // Thrown with an activity still open, on purpose: the point is
                // what happens to that activity afterwards.
                [NSException raise:NSInternalInconsistencyException format:@"thrown from inside"];
            }];
        }];
    } @catch (NSException *exception) {
        raised = YES;
    }
    ok("the exception came out", raised, nil);
    ok("the child was still taken off the stack",
       ![thrownFrom isBoundToCurrentThread], nil);
    ok("the child was still invalidated", !thrownFrom.isValid, nil);
    ok("the outer context is running again, depth intact",
       [XCTContext currentContextIfAvailable].activityRecordStackDepth == depthBeforeThrow,
       nil);
    ok("the activity the throw left open was finished anyway",
       thrownFrom.topActivity == nil, nil);

    [center removeTestObserver:observer];
}

// Runs a block on a thread that has no context, and waits for it.
//
// Off the main thread is the only place "no context" is a condition that can
// occur at all: the main thread adopts a root context when it has none, so a
// lookup there always succeeds and a nil-context path is unreachable from it.
@interface OffMainThreadRunner : NSObject
@property (atomic) BOOL finished;
@property (atomic) BOOL raised;
@property (atomic, nullable, copy) NSString *reason;
@end

@implementation OffMainThreadRunner

- (void)run
{
    @try {
        [XCTContext _recordActivityMessageWithFormat:@"Where does this go?"];
    } @catch (NSException *exception) {
        self.raised = YES;
        self.reason = exception.reason;
    }
    self.finished = YES;
}

@end

static void runOffMainThread(OffMainThreadRunner *runner, ActivityObserverFixture *observer, NSUInteger *outCount)
{
    NSThread *thread = [[NSThread alloc] initWithTarget:runner selector:@selector(run) object:nil];
    [thread start];
    // The main thread only sleeps here, so nothing else can touch the observer
    // while the worker runs: whatever count it finds is the worker's doing.
    while (!runner.finished) {
        [NSThread sleepForTimeInterval:0.01];
    }
    *outCount = observer.startCount;
}

// Three ways to write into the record without doing any work. None of them runs
// a block, so what matters is entirely what lands: which type it is, what it is
// called, and which context it is reported into.
static void testEmptyActivities(void)
{
    printf("\nempty activities\n");

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    ActivityObserverFixture *observer = [[ActivityObserverFixture alloc] init];
    [center addTestObserver:observer];
    XCTestConfiguration *configuration = XCTestConfiguration.activeTestConfiguration;

    // The surprise comes first: a note is internal, and a plain unit-test run
    // reports no internal activities, so this whole family writes nothing into a
    // report unless the run asked for them. Worth stating plainly, because
    // "record this" reads like it always records something.
    NSUInteger before = observer.startCount;
    [XCTContext _recordActivityMessageWithFormat:@"Invisible in a unit-test run"];
    ok("a note in a unit-test run reports nothing", observer.startCount == before, nil);
    ok("but did not fault either", YES, nil);

    // What lands, and where, is only visible in a run that keeps internal
    // activities. Everything below is in UI-test mode for that reason.
    configuration.initializeForUITesting = YES;

    // A note is internal by type, not by name: nothing in the message says so,
    // and a reader has to be able to tell a note from a test's own activity.
    before = observer.startCount;
    [XCTContext _recordActivityMessageWithFormat:@"Kept %d of %d attachments", 3, 7];
    ok("the note was reported", observer.startCount == before + 1, nil);
    ok("the note is called what it said",
       [observer.startActivity.title isEqualToString:@"Kept 3 of 7 attachments"], nil);
    ok("a note is an internal activity, not a user-created one",
       [observer.startActivity.activityType isEqualToString:@"com.apple.dt.xctest.activity-type.internal"],
       observer.startActivity.activityType);
    ok("the note started and finished inside the call",
       observer.finishCount == before + 1, nil);
    ok("a note landed in the context that was running",
       observer.startContext == [XCTContext currentContextIfAvailable], nil);

    // Both spellings agree, including on ignoring the context they were called
    // on. That is what the instance form is for: a caller with a context in hand
    // says so and gets the same destination anyway.
    __block XCTContext *elsewhere = nil;
    [XCTContext runInContextForTestCase:nil block:^{
        elsewhere = [XCTContext currentContextIfAvailable];
    }];
    before = observer.startCount;
    [elsewhere _recordActivityMessageWithFormat:@"Sent from a context of its own"];
    ok("the instance spelling also reported", observer.startCount == before + 1, nil);
    ok("and landed in the run that was happening, not in the context it was sent from",
       observer.startContext == [XCTContext currentContextIfAvailable], nil);
    ok("the context it was sent from is not the one that got it",
       observer.startContext != elsewhere, nil);

    // An empty activity is the same idea with both choices left to the caller:
    // the type is named here rather than fixed, and the destination is this
    // context rather than the running one. That is what makes it usable by
    // something that has already picked a context out.
    XCTContext *reporting = [XCTContext currentContextIfAvailable];
    before = observer.startCount;
    [reporting _reportEmptyActivityWithType:@"com.apple.dt.xctest.activity-type.userCreated"
                                     format:@"Screenshot %ld of %ld", 2L, 5L];
    ok("the empty activity was reported", observer.startCount == before + 1, nil);
    ok("with the type the caller named",
       [observer.startActivity.activityType isEqualToString:@"com.apple.dt.xctest.activity-type.userCreated"],
       observer.startActivity.activityType);
    ok("and the message it formatted",
       [observer.startActivity.title isEqualToString:@"Screenshot 2 of 5"], nil);
    ok("reported into the context it was called on",
       observer.startContext == reporting, nil);

    // A caller may name a type this port has never heard of. The type is data,
    // not a case in a switch, and a caller that knows what it is doing should not
    // have to have it registered here first.
    [reporting _reportEmptyActivityWithType:@"com.example.activity-type.ours"
                                     format:@"A type XCTest has never heard of"];
    ok("an unknown type is carried through untouched",
       [observer.startActivity.activityType isEqualToString:@"com.example.activity-type.ours"],
       observer.startActivity.activityType);

    // Formatting is the point, and %@ has to work like everywhere else. This is
    // the failure that would be easy to ship: a message that reports "3 and 7"
    // instead of "3 of 7" is still an activity, and still looks fine.
    [XCTContext _recordActivityMessageWithFormat:@"%@ passed in %@", @"FailingTests", @1];
    ok("arguments are formatted, not printed as pointers",
       [observer.startActivity.title isEqualToString:@"FailingTests passed in 1"],
       observer.startActivity.title);

    // A note with nowhere to go is a fault, not a silent no-op: the caller has
    // lost the run the note was for, and pretending otherwise loses the note.
    // (Raising rather than continuing is this port's standing choice for an
    // internal failure; see XCTContextRaiseAssertion in XCTContext.m.)
    before = observer.startCount;
    OffMainThreadRunner *runner = [[OffMainThreadRunner alloc] init];
    NSUInteger offMainCount = 0;
    runOffMainThread(runner, observer, &offMainCount);
    ok("a note with no run to join is a fault", runner.raised, nil);
    ok("and says which condition failed",
       runner.reason != nil && [runner.reason rangeOfString:@"No context has been created"].location != NSNotFound,
       runner.reason);
    ok("and nothing was reported for it", offMainCount == before, nil);
    ok("and the main thread's run was left alone", observer.startCount == before, nil);

    configuration.initializeForUITesting = NO;
    [center removeTestObserver:observer];
}

// A delegate is a back-reference, and the direction of ownership is the whole
// point of it. Worth checking with an object that can be watched dying.
@interface WatchedDelegate : NSObject <XCTContextDelegate>
@property (atomic) BOOL deallocated;
@end

@implementation WatchedDelegate

- (void)dealloc
{
    self.deallocated = YES;
}

@end

static void testContextDelegate(void)
{
    printf("\ncontext delegate\n");

    XCTContext *context = [XCTContext currentContextIfAvailable];
    ok("a context starts with no delegate", context.delegate == nil, nil);

    WatchedDelegate *delegate = [[WatchedDelegate alloc] init];
    context.delegate = delegate;
    ok("the delegate reads back", context.delegate == delegate, nil);

    // Weak is the property here, and it is checkable rather than merely declared:
    // a context that kept its delegate alive would keep a whole runner graph
    // alive behind it for as long as anything held the context.
    __weak WatchedDelegate *weakDelegate = delegate;
    delegate = nil;
    ok("a context does not keep its delegate alive",
       weakDelegate == nil, nil);
    ok("and the delegate reads back as gone once it is", context.delegate == nil, nil);

    // A delegate that outlives the context is fine -- nothing here is symmetric,
    // and that asymmetry is the point.
    WatchedDelegate *survivor = [[WatchedDelegate alloc] init];
    context.delegate = survivor;
    ok("a delegate may outlive the context that named it",
       context.delegate == survivor, nil);
    context.delegate = nil;
    ok("and clearing it lets the context forget", context.delegate == nil, nil);
    ok("without disturbing the delegate itself", survivor.deallocated == NO, nil);
}

// The first child of a suite that is named after it, or nil. Grouping and the
// run entry points all build containers whose children are class suites named
// for the class, and finding one by name is the question every check here asks.
static XCTestSuite *suiteNamedIn(XCTestSuite *parent, NSString *name)
{
    for (XCTest *test in parent.tests) {
        if ([test isKindOfClass:[XCTestSuite class]] && [test.name isEqualToString:name]) {
            return (XCTestSuite *)test;
        }
    }
    return nil;
}

// The entry points that turn a configuration into a suite tree. A run is
// handed a configuration -- a selection, an ordering, a bundle -- and the tree
// it runs is built four steps: the flat selection is grouped back into classes,
// a container is prepared from the grouping, the all-tests shape sources one
// suite per bundle in the process, and the outer suite is named for which of
// the two shapes was asked for.
static void testConfigurationConstruction(void)
{
    printf("\nconfiguration construction\n");

    XCTestConfiguration *configuration = XCTestConfiguration.activeTestConfiguration;
    // Everything this section sets on the configuration it gives back, because
    // the sections after it read the same process-wide object.
    NSURL *savedBundleURL = configuration.testBundleURL;
    XCTTestSelection *savedSelection = configuration.testSelection;
    XCTTestExecutionOrdering savedOrdering = configuration.testExecutionOrdering;
    NSInteger (^savedGenerator)(void) = configuration.randomNumberGenerator;

    // A suite carries the name it was made with, and -setName: replaces it --
    // the rename a selected run's container goes through after it is built.
    XCTestSuite *renamed = [XCTestSuite testSuiteWithName:@"BeforeRenaming"];
    ok("a suite made with a name carries it",
       [renamed.name isEqualToString:@"BeforeRenaming"], renamed.name);
    [renamed setName:@"AfterRenaming"];
    ok("setName: replaces the name",
       [renamed.name isEqualToString:@"AfterRenaming"], renamed.name);

    // Grouping: a flat selection comes back split into the classes to run whole
    // and, per class, the methods of it that were named.
    XCTTestIdentifier *wholeClass =
        [[XCTTestIdentifier alloc] initWithClassName:@"XCTSuiteConstructionPlainFixture"];
    XCTTestIdentifier *method =
        [[XCTTestIdentifier alloc] initWithClassName:@"XCTSuiteConstructionCaseFixture"
                                           methodName:@"testapple"];
    XCTTestIdentifier *swift =
        [[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:
                                       @"XCTSuiteConstructionPlainFixture/testapple()"];
    ok("the Swift spelling of a method reads as an identifier", swift != nil, nil);
    XCTTestIdentifier *unloaded =
        [[XCTTestIdentifier alloc] initWithClassName:@"XCTSuiteConstructionNoSuchClass"
                                           methodName:@"testFoo"];
    NSMutableArray<XCTTestIdentifier *> *spellings =
        [NSMutableArray arrayWithObjects:wholeClass, method, nil];
    if (swift != nil) {
        [spellings addObject:swift];
    }
    [spellings addObject:unloaded];
    XCTTestIdentifierSet *grouping =
        [[XCTTestIdentifierSet alloc] initWithArray:spellings];

    NSMutableSet<Class> *wholeClasses = nil;
    NSMutableDictionary<NSString *, XCTTestIdentifierSet *> *methodsByClass = nil;
    [XCTestSuite groupTestIdentifiers:grouping
                          intoClasses:&wholeClasses
             andTestMethodIdentifiers:&methodsByClass];
    ok("a bare class name groups as a whole class",
       wholeClasses.count == 1 &&
           [wholeClasses containsObject:[XCTSuiteConstructionPlainFixture class]],
       [NSString stringWithFormat:@"%lu", (unsigned long)wholeClasses.count]);
    ok("a class/method pair groups under its class",
       methodsByClass.count == 1 &&
           [methodsByClass[@"XCTSuiteConstructionCaseFixture"] containsTestIdentifier:method],
       [NSString stringWithFormat:@"%lu", (unsigned long)methodsByClass.count]);
    // A Swift Testing identifier names the same test but does not carry the
    // class-and-method spelling, so grouping must not read its second component
    // as a method of the class it happens to share a first component with.
    ok("a Swift Testing spelling groups as no method of its class",
       methodsByClass[@"XCTSuiteConstructionPlainFixture"] == nil, nil);
    // The unloaded class is skipped rather than grouped under a class that is
    // not there; the two counts above already name everything that was grouped,
    // so this pins that nothing else arrived alongside it.
    ok("a class not loaded in this process groups nothing",
       wholeClasses.count == 1 && methodsByClass.count == 1, nil);

    // Either result may be declined, alone or together; the answers that were
    // asked for still come back in full.
    NSMutableSet<Class> *classesOnly = nil;
    [XCTestSuite groupTestIdentifiers:grouping
                          intoClasses:&classesOnly
             andTestMethodIdentifiers:NULL];
    ok("a caller may ask only for the whole classes",
       classesOnly.count == 1, [NSString stringWithFormat:@"%lu",
                                                  (unsigned long)classesOnly.count]);
    NSMutableDictionary<NSString *, XCTTestIdentifierSet *> *methodsOnly = nil;
    [XCTestSuite groupTestIdentifiers:grouping
                          intoClasses:NULL
             andTestMethodIdentifiers:&methodsOnly];
    ok("a caller may ask only for the methods",
       methodsOnly.count == 1,
       [NSString stringWithFormat:@"%lu", (unsigned long)methodsOnly.count]);
    [XCTestSuite groupTestIdentifiers:grouping
                          intoClasses:NULL
             andTestMethodIdentifiers:NULL];
    ok("a caller may ask for neither result", methodsOnly.count == 1, nil);

    // Preparing a container: one suite per selected class, whichever way the
    // class was named. A nil selection names nothing and prepares nothing.
    XCTestSuite *emptyContainer = [XCTestSuite testSuiteWithName:@"EmptyContainer"];
    [XCTestSuite prepareContainerSuite:emptyContainer toRunTestIdentifiers:nil];
    ok("a nil selection prepares an empty container",
       emptyContainer.tests.count == 0, nil);

    XCTestSuite *container = [XCTestSuite testSuiteWithName:@"PreparedContainer"];
    XCTTestIdentifierSet *twoClasses =
        [[XCTTestIdentifierSet alloc] initWithArray:@[ wholeClass, method ]];
    [XCTestSuite prepareContainerSuite:container toRunTestIdentifiers:twoClasses];
    ok("each selected class contributes one suite",
       container.tests.count == 2,
       [NSString stringWithFormat:@"%lu", (unsigned long)container.tests.count]);
    XCTestSuite *wholeSuite = suiteNamedIn(container, @"XCTSuiteConstructionPlainFixture");
    XCTestSuite *methodSuite = suiteNamedIn(container, @"XCTSuiteConstructionCaseFixture");
    ok("the whole class contributes a suite named for it",
       wholeSuite != nil && wholeSuite.tests.count == 1, nil);
    ok("the method's class contributes a suite named for it",
       methodSuite != nil, nil);
    ok("the method's suite holds only the selected test",
       methodSuite.tests.count == 1 &&
           [((XCTest *)[methodSuite.tests firstObject])._xctTestIdentifier.identifierString
               isEqualToString:@"XCTSuiteConstructionCaseFixture/testapple"],
       ((XCTest *)[methodSuite.tests firstObject])._xctTestIdentifier.identifierString);

    // The same class selected whole and by a method of it: one suite, and the
    // test named both ways stands in it once -- a container that held it twice
    // would run it twice.
    XCTTestIdentifierSet *bothWays =
        [[XCTTestIdentifierSet alloc] initWithArray:@[
            [[XCTTestIdentifier alloc]
                initWithClassName:@"XCTSuiteConstructionPlainFixture"],
            [[XCTTestIdentifier alloc]
                initWithClassName:@"XCTSuiteConstructionPlainFixture"
                       methodName:@"testExample"]
        ]];
    XCTestSuite *mergedContainer = [XCTestSuite testSuiteWithName:@"MergedContainer"];
    [XCTestSuite prepareContainerSuite:mergedContainer toRunTestIdentifiers:bothWays];
    ok("a class selected whole and by a method is one suite",
       mergedContainer.tests.count == 1,
       [NSString stringWithFormat:@"%lu", (unsigned long)mergedContainer.tests.count]);
    XCTestSuite *merged = suiteNamedIn(mergedContainer,
                                       @"XCTSuiteConstructionPlainFixture");
    ok("the test named both ways stands in it once",
       merged != nil && merged.tests.count == 1,
       [NSString stringWithFormat:@"%lu",
                                  (unsigned long)(merged != nil ? merged.tests.count : 0)]);

    // The bundle suites: where the all-tests shape gets its children. The
    // include-empty answer is the crash-restart restore path, which answers
    // with nothing; the scan keeps every bundle in the process except the
    // framework's own, and each bundle holds the suites of its classes that
    // have something to show.
    NSDictionary *restore = [XCTestSuite suitesForBundlesIncludingEmptySuites:YES];
    ok("including empty suites answers with nothing",
       restore.count == 0,
       [NSString stringWithFormat:@"%lu", (unsigned long)restore.count]);
    NSDictionary<NSString *, XCTestSuite *> *byBundle =
        [XCTestSuite suitesForBundlesIncludingEmptySuites:NO];
    NSString *toolPath =
        [[NSBundle bundleForClass:[XCTSuiteConstructionPlainFixture class]] bundlePath];
    NSString *frameworkPath = [[NSBundle bundleForClass:[XCTest class]] bundlePath];
    XCTestSuite *toolBundle = byBundle[toolPath];
    ok("the bundle holding the fixtures is among them",
       toolBundle != nil, toolPath);
    ok("the framework's own bundle is left out",
       byBundle[frameworkPath] == nil, frameworkPath);
    ok("the tests of this process come from one bundle",
       byBundle.count == 1,
       [NSString stringWithFormat:@"%lu", (unsigned long)byBundle.count]);
    ok("a bundle suite is named from its path",
       [toolBundle.name isEqualToString:toolPath.lastPathComponent],
       toolBundle.name);
    BOOL everyChildIsASuite = toolBundle != nil;
    for (XCTest *child in toolBundle.tests) {
        if (![child isKindOfClass:[XCTestSuite class]]) {
            everyChildIsASuite = NO;
        }
    }
    ok("every child of a bundle suite is a suite of its own",
       everyChildIsASuite, nil);
    ok("a class with tests contributes its suite",
       suiteNamedIn(toolBundle, @"XCTSuiteConstructionPlainFixture") != nil, nil);
    // No tests means no suite: an empty case suite is a runnable class that
    // filtered down to nothing, and the report has nothing to say about it.
    ok("a class with no tests contributes no suite",
       suiteNamedIn(toolBundle, @"XCTSuiteConstructionNoTestsFixture") == nil, nil);

    // The selected-run container: built from a selection, named after the
    // bundle it runs from, and holding one suite per selected class in
    // execution order.
    configuration.testBundleURL =
        [NSURL fileURLWithPath:@"/tmp/ConstructionRun.xctest"];
    ok("the configuration reports a bundle's file name",
       [configuration.testBundleName isEqualToString:@"ConstructionRun.xctest"],
       configuration.testBundleName);
    XCTestSuite *selected =
        [XCTestSuite testClassSuitesForTestIdentifiers:twoClasses
                              skippingTestIdentifiers:nil
                               randomNumberGenerator:nil];
    ok("a selected container is named for the bundle",
       [selected.name isEqualToString:@"ConstructionRun.xctest"], selected.name);
    ok("one suite per selected class is in it",
       selected.tests.count == 2,
       [NSString stringWithFormat:@"%lu", (unsigned long)selected.tests.count]);
    XCTestSuite *firstInOrder = (XCTestSuite *)selected.tests[0];
    XCTestSuite *secondInOrder = (XCTestSuite *)selected.tests[1];
    ok("the suites are in execution order",
       [firstInOrder.name isEqualToString:@"XCTSuiteConstructionCaseFixture"] &&
           [secondInOrder.name isEqualToString:@"XCTSuiteConstructionPlainFixture"],
       firstInOrder.name);
    XCTTestIdentifier *caseClass =
        [[XCTTestIdentifier alloc] initWithClassName:@"XCTSuiteConstructionCaseFixture"];
    XCTestSuite *afterSkip =
        [XCTestSuite testClassSuitesForTestIdentifiers:twoClasses
                              skippingTestIdentifiers:[[XCTTestIdentifierSet alloc]
                                                          initWithTestIdentifier:method]
                               randomNumberGenerator:nil];
    ok("a skipped method leaves an empty suite behind",
       afterSkip.tests.count == 2 &&
           suiteNamedIn(afterSkip, @"XCTSuiteConstructionCaseFixture") != nil &&
           suiteNamedIn(afterSkip, @"XCTSuiteConstructionCaseFixture").tests.count == 0,
       [NSString stringWithFormat:@"%lu", (unsigned long)afterSkip.tests.count]);
    XCTestSuite *afterWholeClassSkip =
        [XCTestSuite testClassSuitesForTestIdentifiers:twoClasses
                              skippingTestIdentifiers:[[XCTTestIdentifierSet alloc]
                                                          initWithTestIdentifier:caseClass]
                               randomNumberGenerator:nil];
    ok("a skipped class's suite is removed",
       afterWholeClassSkip.tests.count == 1 &&
           suiteNamedIn(afterWholeClassSkip, @"XCTSuiteConstructionPlainFixture") != nil,
       [NSString stringWithFormat:@"%lu", (unsigned long)afterWholeClassSkip.tests.count]);
    XCTestSuite *nothingToRun =
        [XCTestSuite testClassSuitesForTestIdentifiers:nil
                              skippingTestIdentifiers:nil
                               randomNumberGenerator:nil];
    ok("a nil run set prepares nothing",
       nothingToRun.tests.count == 0,
       [NSString stringWithFormat:@"%lu", (unsigned long)nothingToRun.tests.count]);

    // The two run shapes. A selection: SelectedTests, one container, named for
    // the bundle. No selection: AllTests, one suite per bundle in the process.
    configuration.testSelection =
        [[XCTTestSelection alloc] initWithIdentifiersToRun:twoClasses
                                        identifiersToSkip:nil
                                                 tagsToRun:nil
                                                 tagsToSkip:nil];
    XCTestSuite *selectedRun = [XCTestSuite testSuiteForTestConfiguration:configuration];
    ok("a run that names tests is built from the configuration",
       selectedRun != nil, nil);
    ok("a run that names tests is named SelectedTests",
       [selectedRun.name isEqualToString:@"SelectedTests"], selectedRun.name);
    ok("a selected run holds exactly the container",
       selectedRun.tests.count == 1,
       [NSString stringWithFormat:@"%lu", (unsigned long)selectedRun.tests.count]);
    XCTestSuite *containerInRun = (XCTestSuite *)[selectedRun.tests firstObject];
    ok("the container is named for the bundle",
       [containerInRun.name isEqualToString:@"ConstructionRun.xctest"],
       containerInRun.name);
    ok("the container holds both selected classes",
       containerInRun.tests.count == 2,
       [NSString stringWithFormat:@"%lu", (unsigned long)containerInRun.tests.count]);

    ok("a nil configuration builds nothing",
       [XCTestSuite testSuiteForTestConfiguration:nil] == nil, nil);

    configuration.testSelection = [[XCTTestSelection alloc] init];
    ok("a configuration born without a selection names nothing to run",
       configuration.testIdentifiersToRun == nil, nil);
    XCTestSuite *allRun = [XCTestSuite testSuiteForTestConfiguration:configuration];
    ok("a run that names nothing is named AllTests",
       [allRun.name isEqualToString:@"AllTests"], allRun.name);
    ok("an all-tests run holds one suite per bundle",
       allRun.tests.count == byBundle.count,
       [NSString stringWithFormat:@"%lu", (unsigned long)allRun.tests.count]);

    // A run that skips but does not select: named for the selection it made,
    // built from every bundle, and the skip reaches the class suites inside.
    XCTTestIdentifierSet *skipOnlySet =
        [[XCTTestIdentifierSet alloc] initWithTestIdentifier:wholeClass];
    configuration.testSelection =
        [[XCTTestSelection alloc] initWithIdentifiersToRun:nil
                                        identifiersToSkip:skipOnlySet
                                                 tagsToRun:nil
                                                 tagsToSkip:nil];
    XCTestSuite *skipOnlyRun = [XCTestSuite testSuiteForTestConfiguration:configuration];
    ok("a run that only skips is named for the selection it made",
       [skipOnlyRun.name isEqualToString:@"SelectedTests"], skipOnlyRun.name);
    ok("the skip-only run still builds every bundle",
       skipOnlyRun.tests.count == byBundle.count,
       [NSString stringWithFormat:@"%lu", (unsigned long)skipOnlyRun.tests.count]);
    XCTestSuite *bundleAfterSkip = (XCTestSuite *)[skipOnlyRun.tests firstObject];
    ok("the skip set reaches the class suites",
       suiteNamedIn(bundleAfterSkip, @"XCTSuiteConstructionPlainFixture") == nil, nil);

    // Random ordering asks the configuration's own generator for its numbers,
    // and changes the order rather than the contents.
    configuration.testSelection =
        [[XCTTestSelection alloc] initWithIdentifiersToRun:twoClasses
                                        identifiersToSkip:nil
                                                 tagsToRun:nil
                                                 tagsToSkip:nil];
    configuration.testExecutionOrdering = XCTTestExecutionOrderingRandom;
    configuration.randomNumberGenerator = ^NSInteger(void) { return 0; };
    XCTestSuite *shuffledRun = [XCTestSuite testSuiteForTestConfiguration:configuration];
    XCTestSuite *shuffledContainer = (XCTestSuite *)[shuffledRun.tests firstObject];
    ok("a selected run in random order still holds both selected classes",
       shuffledContainer.tests.count == 2,
       [NSString stringWithFormat:@"%lu", (unsigned long)shuffledContainer.tests.count]);

    configuration.testBundleURL = savedBundleURL;
    configuration.testSelection = savedSelection;
    configuration.testExecutionOrdering = savedOrdering;
    configuration.randomNumberGenerator = savedGenerator;
}

int main(void)
{
    printf("XCTestSuite construction from a selection\n");
    // A run has to exist before anything can be reported into one, and this is a
    // plain tool rather than a run, so it installs a configuration of its own. It
    // is a synthesized one, which means a unit-test run that reports activities --
    // the defaults a run gets unless something opts out.
    XCTestConfiguration.activeTestConfiguration = [[XCTestConfiguration alloc] init];
    // First, because it asks what a freshly made context looks like, and the
    // main thread's root context is shared by every section after this one.
    testContext();
    testRuntimeFacts();
    testSwiftCounterparts();
    testNaming();
    testAvailability();
    testMethodConventions();
    testConventionFromSignature();
    testAsyncSetUpAndTearDownOverrides();
    testAsyncBlockSignatures();
    testInvocationDescriptors();
    testDescriptorRejection();
    testMethodInvocationDescriptors();
    testAllMethodInvocationDescriptors();
    testTestInvocationDescriptors();
    testIdentifiersFromNames();
    testPlaceholder();
    testClassFromString();
    testEmptySuite();
    testResolvedSuite();
    testSelectorConstruction();
    testEmptySuiteInclusion();
    testCaseSuiteLifecycle();
    testChildContext();
    testEmptyActivities();
    testContextDelegate();
    testActivityReportingFilter();
    testActivityObservation();
    testPlaceholderObservation();
    testSkipObservation();
    testActivityRecord();
    testConfigurationConstruction();
    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
