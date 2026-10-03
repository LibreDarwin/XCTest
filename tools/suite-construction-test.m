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
#import <XCTestCore/XCActivityRecord.h>

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestObservationInternal.h"

#import <Foundation/Foundation.h>
#import <math.h>

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

int main(void)
{
    printf("XCTestSuite construction from a selection\n");
    testRuntimeFacts();
    testSwiftCounterparts();
    testNaming();
    testAvailability();
    testEmptySuite();
    testActivityObservation();
    testActivityRecord();
    testContext();
    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
