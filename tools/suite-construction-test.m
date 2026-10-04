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
    testInvocationDescriptors();
    testClassFromString();
    testEmptySuite();
    testEmptySuiteInclusion();
    testCaseSuiteLifecycle();
    testChildContext();
    testEmptyActivities();
    testContextDelegate();
    testActivityReportingFilter();
    testActivityObservation();
    testActivityRecord();
    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
