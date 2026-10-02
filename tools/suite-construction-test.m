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
//
// It links the installed framework rather than the object files, so it also
// covers installation and the private declarations in XCTestInternal.h, which is
// where these methods would drift if they drifted anywhere.
#import <XCTest/XCTest.h>
#import <XCTestCore/XCTTestSelection.h>

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"

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

int main(void)
{
    printf("XCTestSuite construction from a selection\n");
    testRuntimeFacts();
    testSwiftCounterparts();
    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
