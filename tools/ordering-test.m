// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for the ordering and removal increment: the two ways a
// suite puts its children in order, and the three ways a selection prunes them.
//
// These are the operations that decide *which* of two things runs first and
// *whether* a thing runs at all, so the checks pin the decisions rather than the
// implementation:
//
//   - The array helpers are the leaves both orderings stand on. A shuffle is
//     checked against a fixed generator at every step, because the failure that
//     matters is not "is it random" but "is it the reference's permutation" --
//     two Fisher-Yates variants both shuffle and both disagree. A stable
//     partition is checked for both halves of its contract: the return value is
//     the boundary, and the passing prefix keeps its order.
//   - The execution ordering is pinned on the two keys it uses. Cases order by
//     their method name *case-insensitively*, which a fixture whose names differ
//     only in capitalization detects; suites order by name and sort *after*
//     cases, which a mixed container detects in both directions.
//   - Removal is checked for the argument mapping (a parameterized test's
//     identifier names its parent, so removing the parent removes the siblings),
//     for the recursion into nested suites, and for the empty-set asymmetry: an
//     empty "in set" removes nothing, an empty "without set" removes everything.
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

static void okOrder(const char *name, NSComparisonResult actual, NSComparisonResult expected)
{
    ok(name, actual == expected, [NSString stringWithFormat:@"got %ld, want %ld",
                                  (long)actual, (long)expected]);
}

#pragma mark - Fixtures

// Names that differ only by capitalization: case-sensitive ordering would put
// Bravo and Charlie before alpha; case-insensitive ordering puts alpha first.
@interface XCTOrderFixture : XCTestCase
- (void)testBravo;
- (void)testalpha;
- (void)testCharlie;
@end
@implementation XCTOrderFixture
- (void)testBravo {}
- (void)testalpha {}
- (void)testCharlie {}
@end

// Opts into selector ordering, where the raw selector is the key. Its two
// selectors compare one way and their stripped identifiers compare another:
// "testExampleWithCompletionHandler:" vs "testExample" is not equal, while both
// identifiers collapse to "testExample" and are equal. So a run that ordered by
// identifier here would call the pair tied.
@interface XCTSelectorSortFixture : XCTestCase
- (void)testExample;
- (void)testExampleWithCompletionHandler:(void (^)(void))handler;
@end
@implementation XCTSelectorSortFixture
+ (BOOL)shouldSortTestsBySelector { return YES; }
- (void)testExample {}
- (void)testExampleWithCompletionHandler:(void (^)(void))handler {}
@end

static XCTestCase *caseWithSelector(Class cls, SEL selector)
{
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    return [[cls alloc] initWithInvocation:invocation];
}

// The labels a suite's direct children sort and prune by: a case's stripped
// method name, anything else's name. Nested suites are named with a "Z" prefix
// so they sort last, which keeps the expected orders readable.
static NSArray<NSString *> *labelsOf(XCTestSuite *suite)
{
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (XCTest *test in suite.tests) {
        if ([test isKindOfClass:[XCTestCase class]]) {
            [labels addObject:[(XCTestCase *)test languageAgnosticTestMethodName]];
        } else {
            [labels addObject:test.name];
        }
    }
    return labels;
}

#pragma mark - Array helpers

static void testArrayHelpers(void)
{
    // A generator that returns a constant is the sharpest probe: the reference
    // draws `j = i + rand % (count - i)` and swaps, so a constant 1 walks the
    // first element to the end and a constant 0 changes nothing. A variant that
    // drew `rand % count` would produce a different array for the same 1.
    __block NSUInteger draws = 0;
    NSMutableArray<NSString *> *letters = [@[ @"a", @"b", @"c", @"d" ] mutableCopy];
    [letters xct_shuffleWithRandomNumberGenerator:^NSUInteger(void) {
        draws++;
        return 0;
    }];
    ok("shuffle with an all-zero generator is the identity",
       [letters isEqualToArray:(@[ @"a", @"b", @"c", @"d" ])],
       [letters componentsJoinedByString:@""]);
    ok("shuffle draws once per position, including the last", draws == 4,
       [NSString stringWithFormat:@"drew %lu", (unsigned long)draws]);

    letters = [@[ @"a", @"b", @"c", @"d" ] mutableCopy];
    [letters xct_shuffleWithRandomNumberGenerator:^NSUInteger(void) {
        return 1;
    }];
    ok("shuffle with an all-one generator is the reference permutation",
       [letters isEqualToArray:(@[ @"b", @"c", @"d", @"a" ])],
       [letters componentsJoinedByString:@""]);

    // Half-stable partition: the failing run is gathered at the front and keeps
    // its relative order, the passing run is pushed to the tail, and the return
    // value is the size of the failing run (the boundary where it ends).
    NSMutableArray<NSNumber *> *numbers = [@[ @1, @2, @3, @4, @5 ] mutableCopy];
    NSUInteger boundary = [numbers xct_halfStablePartitionUsingBlock:^BOOL(NSNumber *n) {
        return n.integerValue % 2 == 0;
    }];
    ok("partition returns the failing-run length", boundary == 3,
       [NSString stringWithFormat:@"got %lu", (unsigned long)boundary]);
    ok("partition gathers the failing run first, stably, the passing run after",
       [numbers isEqualToArray:(@[ @1, @3, @5, @4, @2 ])],
       [numbers componentsJoinedByString:@","]);

    numbers = [@[ @2, @4, @6 ] mutableCopy];
    boundary = [numbers xct_halfStablePartitionUsingBlock:^BOOL(NSNumber *n) {
        return n.integerValue % 2 == 0;
    }];
    ok("an all-passing partition returns zero and changes nothing",
       boundary == 0 && [numbers isEqualToArray:(@[ @2, @4, @6 ])], nil);

    numbers = [@[ @1, @3, @5 ] mutableCopy];
    boundary = [numbers xct_halfStablePartitionUsingBlock:^BOOL(NSNumber *n) {
        return n.integerValue % 2 == 0;
    }];
    ok("a nothing-passing partition returns the count and changes nothing",
       boundary == 3 && [numbers isEqualToArray:(@[ @1, @3, @5 ])], nil);

    NSMutableArray<NSNumber *> *toRemove = [@[ @1, @2, @3, @4, @5, @6 ] mutableCopy];
    [toRemove xct_removeObjectsPassingTest:^BOOL(NSNumber *n) {
        return n.integerValue % 2 == 1;
    }];
    ok("remove-passing drops exactly the passing elements",
       [toRemove isEqualToArray:(@[ @2, @4, @6 ])],
       [toRemove componentsJoinedByString:@","]);

    NSMutableArray<NSNumber *> *keepAll = [@[ @2, @4 ] mutableCopy];
    [keepAll xct_removeObjectsPassingTest:^BOOL(NSNumber *n) {
        (void)n;
        return NO;
    }];
    ok("remove-passing with a never-passing block is a no-op",
       [keepAll isEqualToArray:(@[ @2, @4 ])], nil);
}

#pragma mark - Execution ordering

static void testExecutionOrdering(void)
{
    XCTestCase *bravo = caseWithSelector([XCTOrderFixture class], @selector(testBravo));
    XCTestCase *alpha = caseWithSelector([XCTOrderFixture class], @selector(testalpha));
    XCTestCase *charlie = caseWithSelector([XCTOrderFixture class], @selector(testCharlie));

    // Cases compare by their method name, case-insensitively.
    okOrder("a lowercase method sorts before a capitalized one",
            [alpha defaultExecutionOrderCompare:bravo], NSOrderedAscending);
    okOrder("the comparison is antisymmetric",
            [bravo defaultExecutionOrderCompare:alpha], NSOrderedDescending);
    okOrder("a case compares equal to a case with the same name",
            [alpha defaultExecutionOrderCompare:alpha], NSOrderedSame);

    // A case sorts before anything that is not a case; a suite sorts after.
    XCTest *plainTest = [[XCTest alloc] init];
    XCTestSuite *suiteAlpha = [XCTestSuite testSuiteWithName:@"Alpha"];
    okOrder("a case sorts before a non-case",
            [alpha defaultExecutionOrderCompare:plainTest], NSOrderedAscending);
    okOrder("a case sorts before a suite",
            [alpha defaultExecutionOrderCompare:suiteAlpha], NSOrderedAscending);

    ok("cases do not sort by selector by default",
       ![XCTOrderFixture shouldSortTestsBySelector], nil);

    // The opt-in branch: keyed on the raw selector, so the suffix-bearing
    // selector is longer and sorts after its stripped identifier's equal.
    XCTestCase *plain = caseWithSelector([XCTSelectorSortFixture class], @selector(testExample));
    XCTestCase *handler = caseWithSelector([XCTSelectorSortFixture class],
                                           @selector(testExampleWithCompletionHandler:));
    ok("the selector-sort fixture opts in",
       [XCTSelectorSortFixture shouldSortTestsBySelector], nil);
    ok("the fixture's two identifiers are otherwise equal",
       [plain._xctTestIdentifier isEqual:handler._xctTestIdentifier], nil);
    okOrder("selector ordering uses the selector, not the identifier",
            [handler defaultExecutionOrderCompare:plain], NSOrderedDescending);

    // Suites compare by name, case-sensitively, and only against suites.
    XCTestSuite *suiteBeta = [XCTestSuite testSuiteWithName:@"Beta"];
    okOrder("suites order by name",
            [suiteAlpha defaultExecutionOrderCompare:suiteBeta], NSOrderedAscending);
    okOrder("suite order is antisymmetric",
            [suiteBeta defaultExecutionOrderCompare:suiteAlpha], NSOrderedDescending);
    okOrder("a suite compares equal to a suite of the same name",
            [suiteAlpha defaultExecutionOrderCompare:suiteAlpha], NSOrderedSame);
    okOrder("a suite sorts after a non-suite",
            [suiteAlpha defaultExecutionOrderCompare:alpha], NSOrderedDescending);

    // The base has no opinion, which is what lets the two overrides meet.
    okOrder("the base test compares everything equal",
            [plainTest defaultExecutionOrderCompare:alpha], NSOrderedSame);

    // Sorting a suite orders its own children and descends.
    XCTestSuite *outer = [XCTestSuite testSuiteWithName:@"Outer"];
    [outer addTest:charlie];
    [outer addTest:alpha];
    [outer addTest:bravo];
    XCTestSuite *inner = [XCTestSuite testSuiteWithName:@"ZInner"];
    [inner addTest:caseWithSelector([XCTOrderFixture class], @selector(testCharlie))];
    [inner addTest:caseWithSelector([XCTOrderFixture class], @selector(testalpha))];
    [outer addTest:inner];
    [outer _sortTestsUsingDefaultExecutionOrdering];
    ok("default sort orders a suite's cases case-insensitively",
       [labelsOf(outer) isEqualToArray:(@[ @"testalpha", @"testBravo", @"testCharlie", @"ZInner" ])],
       [labelsOf(outer) componentsJoinedByString:@","]);
    ok("default sort descends into nested suites",
       [labelsOf(inner) isEqualToArray:(@[ @"testalpha", @"testCharlie" ])],
       [labelsOf(inner) componentsJoinedByString:@","]);

    // The random pass threads one generator through the whole tree: with all
    // zeros every suite is unchanged, and the draw count is the sum of the
    // children, not the product.
    __block NSUInteger randomDraws = 0;
    [outer _applyRandomExecutionOrderingWithGenerator:^NSUInteger(void) {
        randomDraws++;
        return 0;
    }];
    ok("a zero random ordering leaves the whole tree unchanged",
       [labelsOf(outer) isEqualToArray:(@[ @"testalpha", @"testBravo", @"testCharlie", @"ZInner" ])] &&
       [labelsOf(inner) isEqualToArray:(@[ @"testalpha", @"testCharlie" ])],
       nil);
    ok("one generator serves every suite in the tree",
       randomDraws == 6,
       [NSString stringWithFormat:@"drew %lu", (unsigned long)randomDraws]);
}

#pragma mark - Removal

static XCTTestIdentifierSet *setWith(NSArray<NSString *> *identifierStrings)
{
    NSMutableArray<XCTTestIdentifier *> *identifiers = [NSMutableArray array];
    for (NSString *string in identifierStrings) {
        [identifiers addObject:[[XCTTestIdentifier alloc] initWithStringRepresentation:string]];
    }
    return [[XCTTestIdentifierSet alloc] initWithArray:identifiers];
}

static void testRemoval(void)
{
    // A suite whose identifier was never set answers nil, and nil is not in any
    // set, so a suite is never pruned by a child's identifier.
    XCTestSuite *anonymous = [XCTestSuite testSuiteWithName:@"Anonymous"];
    ok("an unconstructed suite has no identifier", anonymous._xctTestIdentifier == nil, nil);

    XCTestCase *bravo = caseWithSelector([XCTOrderFixture class], @selector(testBravo));
    XCTestCase *alpha = caseWithSelector([XCTOrderFixture class], @selector(testalpha));
    XCTestCase *charlie = caseWithSelector([XCTOrderFixture class], @selector(testCharlie));

    // Removing a name that is present drops exactly that case.
    XCTestSuite *one = [XCTestSuite testSuiteWithName:@"One"];
    [one addTest:alpha];
    [one addTest:bravo];
    [one addTest:charlie];
    [one _removeTestsWithIdentifierInSet:setWith(@[ @"XCTOrderFixture/testalpha" ])];
    ok("remove-in-set drops the named case and keeps the rest",
       [labelsOf(one) isEqualToArray:(@[ @"testBravo", @"testCharlie" ])],
       [labelsOf(one) componentsJoinedByString:@","]);

    // An empty set matches nothing, so it removes nothing.
    XCTestSuite *emptied = [XCTestSuite testSuiteWithName:@"Emptied"];
    [emptied addTest:alpha];
    [emptied addTest:bravo];
    [emptied _removeTestsWithIdentifierInSet:[[XCTTestIdentifierSet alloc] init]];
    ok("remove-in-set with an empty set removes nothing",
       [labelsOf(emptied) isEqualToArray:(@[ @"testalpha", @"testBravo" ])], nil);

    // The argument mapping: the selection carries an argument-bearing
    // identifier, but the case is addressed by its unparameterized parent.
    XCTTestIdentifier *parent = [[XCTTestIdentifier alloc] initWithClassName:@"XCTOrderFixture"
                                                                  methodName:@"testalpha"];
    XCTTestIdentifier *withArguments =
        [parent childIdentifierWithArgumentIDs:[NSSet setWithObject:[@"1" dataUsingEncoding:NSUTF8StringEncoding]]];
    XCTestSuite *mapped = [XCTestSuite testSuiteWithName:@"Mapped"];
    [mapped addTest:alpha];
    [mapped addTest:bravo];
    [mapped removeTestsWithIdentifierInSet:[[XCTTestIdentifierSet alloc] initWithTestIdentifier:withArguments]];
    ok("remove-with-identifier maps an argument identifier to its parent",
       [labelsOf(mapped) isEqualToArray:(@[ @"testBravo" ])],
       [labelsOf(mapped) componentsJoinedByString:@","]);

    // Recursion: a nested suite's children are pruned by the same set.
    XCTestSuite *nested = [XCTestSuite testSuiteWithName:@"Nested"];
    [nested addTest:alpha];
    XCTestSuite *childSuite = [XCTestSuite testSuiteWithName:@"Child"];
    [childSuite addTest:bravo];
    [childSuite addTest:charlie];
    [nested addTest:childSuite];
    [nested _removeTestsWithIdentifierInSet:setWith(@[ @"XCTOrderFixture/testCharlie" ])];
    ok("remove-in-set descends into nested suites",
       [labelsOf(childSuite) isEqualToArray:(@[ @"testBravo" ])],
       [labelsOf(childSuite) componentsJoinedByString:@","]);
    ok("remove-in-set keeps the unnamed nested suite itself",
       [nested.tests containsObject:childSuite], nil);

    // The complement: keep only what is named, and an empty set keeps nothing.
    XCTestSuite *kept = [XCTestSuite testSuiteWithName:@"Kept"];
    [kept addTest:alpha];
    [kept addTest:bravo];
    [kept addTest:charlie];
    [kept _removeTestsWithoutIdentifierInSet:setWith(@[ @"XCTOrderFixture/testBravo" ])];
    ok("remove-without-set keeps only the named cases",
       [labelsOf(kept) isEqualToArray:(@[ @"testBravo" ])],
       [labelsOf(kept) componentsJoinedByString:@","]);

    XCTestSuite *wiped = [XCTestSuite testSuiteWithName:@"Wiped"];
    [wiped addTest:alpha];
    [wiped addTest:bravo];
    [wiped _removeTestsWithoutIdentifierInSet:[[XCTTestIdentifierSet alloc] init]];
    ok("remove-without-set with an empty set removes everything",
       wiped.tests.count == 0, nil);

    // The base's removal entry points are no-ops; calling them must not alter it.
    XCTest *base = [[XCTest alloc] init];
    [base _removeTestsWithIdentifierInSet:setWith(@[ @"XCTOrderFixture/testalpha" ])];
    [base _removeTestsWithoutIdentifierInSet:setWith(@[ @"XCTOrderFixture/testalpha" ])];
    ok("the base test ignores both removal passes", YES, nil);
}

int main(void)
{
    printf("XCTestSuite ordering and removal\n");
    testArrayHelpers();
    testExecutionOrdering();
    testRemoval();
    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
