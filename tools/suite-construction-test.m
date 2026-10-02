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
//
// It links the installed framework rather than the object files, so it also
// covers installation and the private declarations in XCTestInternal.h, which is
// where these methods would drift if they drifted anywhere.
#import <XCTest/XCTest.h>
#import <XCTestCore/XCTTestSelection.h>

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestObservationInternal.h"

#import <Foundation/Foundation.h>

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

// Answers the availability hook with no. The reference reaches that answer by
// comparing a declared minimum OS version against the running one; a class that
// wants to be unavailable says so here instead.
@interface XCTSuiteConstructionUnavailableFixture : XCTestCase
@end
@implementation XCTSuiteConstructionUnavailableFixture
+ (BOOL)_isAvailable
{
    return NO;
}
@end

// Named here because a class that is not a test case at all has to be refused
// too: the factory takes any Class, and asking one that has no hook is how the
// -respondsToSelector: guard is exercised.
@interface XCTSuiteConstructionNotATestCase : NSObject
@end
@implementation XCTSuiteConstructionNotATestCase
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
       XCTTestCaseClassIsAvailable([XCTSuiteConstructionPlainFixture class]), nil);
    ok("a subclass that overrides the hook can refuse",
       !XCTTestCaseClassIsAvailable([XCTSuiteConstructionUnavailableFixture class]), nil);
    ok("a class that is not a test case is unavailable",
       !XCTTestCaseClassIsAvailable([XCTSuiteConstructionNotATestCase class]), nil);

    // The guard is the -respondsToSelector: one, not a kind-of test: the class
    // with no hook is sent nothing at all.
    ok("a class with no hook does not answer the question",
       ![XCTSuiteConstructionNotATestCase respondsToSelector:@selector(_isAvailable)], nil);
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

int main(void)
{
    printf("XCTestSuite construction from a selection\n");
    testRuntimeFacts();
    testSwiftCounterparts();
    testNaming();
    testAvailability();
    testEmptySuite();
    testActivityObservation();
    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
