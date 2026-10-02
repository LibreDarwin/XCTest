// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestSuite, a collection of tests run as a unit.

#import <XCTest/XCTestSuite.h>
#import <XCTest/XCTestCase.h>
#import <XCTest/XCTestSuiteRun.h>
#import <XCTest/XCTIssue.h>
#import <XCTestCore/XCTTestSelection.h>

#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"
#import "XCTestObservationInternal.h"

#import <objc/runtime.h>

#import <stdlib.h>

@implementation XCTestSuite {
    NSMutableArray<XCTest *> *_tests;
    NSString *_name;
    // The identifier of the selection this suite stands for, when it was built
    // from one by -initWithName:identifier:. Stays nil for a suite built through
    // -initWithName:, which is the same answer the removal loops read as "not in
    // the set". See -_xctTestIdentifier.
    XCTTestIdentifier *_identifier;
}

#pragma mark - Creation

+ (instancetype)testSuiteWithName:(NSString *)name
{
    return [[self alloc] initWithName:name];
}

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _tests = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name identifier:(XCTTestIdentifier *)identifier
{
    // Sent to self rather than to super, which is the reference's shape and the
    // reason a subclass may add its own storage by overriding this: the
    // initializer chain is the only thing a suite has to go through to exist.
    self = [self initWithName:name];
    if (self != nil && identifier != nil) {
        // Only a real identifier is stored. A suite built with nil keeps the
        // nil that -initWithName: left behind, which is what the removal loops
        // below read as "this suite was not selected" -- so a suite that was
        // never addressed by a selection is never dropped for lack of an
        // identifier.
        _identifier = identifier;
    }
    return self;
}

/// XCTest declares `name` but keeps its storage in XCTest's own @implementation,
/// so a subclass ivar is invisible to the inherited accessor. Without this
/// override every suite would report its own class name instead of the name it
/// was constructed with.
- (NSString *)name
{
    return _name;
}

- (instancetype)init
{
    // Unavailable in the public header; reaching it would leave the suite with
    // no name and no children, which is never what a caller wants.
    [NSException raise:NSInternalInconsistencyException
                format:@"-init is unavailable on %@; use -initWithName:",
                       NSStringFromClass([self class])];
    return nil;
}

#pragma mark - Contents

- (void)addTest:(XCTest *)test
{
    if (test == nil) {
        return;
    }
    [_tests addObject:test];
}

- (NSArray<__kindof XCTest *> *)tests
{
    return [_tests copy];
}

- (NSUInteger)testCaseCount
{
    NSUInteger count = 0;
    for (XCTest *test in _tests) {
        count += test.testCaseCount;
    }
    return count;
}

- (Class)testRunClass
{
    return [XCTestSuiteRun class];
}

#pragma mark - Ordering

- (NSComparisonResult)defaultExecutionOrderCompare:(XCTest *)other
{
    // A suite only knows how to rank another suite, and it sorts after
    // everything else, matching the case's rule that a case sorts before
    // everything else. Between two suites the name decides, case-sensitively:
    // a suite's name is the class or selection it was built from, so a plain
    // -compare: is the most predictable order for it.
    if (![other isKindOfClass:[XCTestSuite class]]) {
        return NSOrderedDescending;
    }
    return [self.name compare:((XCTestSuite *)other).name];
}

- (XCTTestIdentifier *)_xctTestIdentifier
{
    // Stored rather than derived: a suite's identifier names the selection it
    // stands for, which only its construction knows, so there is nothing here
    // to rebuild from the name. A suite made through -initWithName: has none,
    // and nil is a useful answer rather than a gap: the removal loops treat
    // "not in the set" as "keep", so such a suite is never dropped by a child's
    // identifier.
    return _identifier;
}

- (void)_sortTestsUsingDefaultExecutionOrdering
{
    // Sort the mutable storage in place, then descend. A child that is itself a
    // suite must be ordered before it runs but after it has been sorted, so the
    // recursion is over the now-sorted children, not over the pre-sort list.
    [_tests sortUsingSelector:@selector(defaultExecutionOrderCompare:)];
    for (XCTest *test in self.tests) {
        if ([test isKindOfClass:[XCTestSuite class]]) {
            [(XCTestSuite *)test _sortTestsUsingDefaultExecutionOrdering];
        }
    }
}

- (void)_applyRandomExecutionOrderingWithGenerator:(XCTRandomNumberGenerator)generator
{
    // One generator threaded through the whole tree, so a seeded run is
    // reproducible from the seed alone; shuffling each suite with a fresh
    // generator would still be random but no longer repeatable.
    [_tests xct_shuffleWithRandomNumberGenerator:generator];
    for (XCTest *test in self.tests) {
        if ([test isKindOfClass:[XCTestSuite class]]) {
            [(XCTestSuite *)test _applyRandomExecutionOrderingWithGenerator:generator];
        }
    }
}

#pragma mark - Removal

- (void)removeTestsWithIdentifierInSet:(XCTTestIdentifierSet *)set
{
    // A parameterized test's identifier carries its argument, but the selection
    // asks to remove the test by its unparameterized parent. Map each argument-
    // bearing identifier to its parent first so removing one case removes its
    // siblings too; an identifier with no arguments already is its own parent.
    XCTTestIdentifierSet *mapped = [set setByApplyingBlock:^id _Nullable(XCTTestIdentifier *identifier) {
        if (identifier.argumentIDs.count != 0) {
            return identifier.parentIdentifier;
        }
        return identifier;
    }];
    [self _removeTestsWithIdentifierInSet:mapped];
}

- (void)_removeTestsWithIdentifierInSet:(XCTTestIdentifierSet *)set
{
    // An empty set matches nothing, so the pass would be a no-op; skipping it
    // also keeps this from recursing into every suite of a large tree for
    // nothing.
    if (set.count == 0) {
        return;
    }
    // Drop this suite's direct children that are in the set, then descend so a
    // nested suite's own children are filtered by the same set. The recursion
    // is over the survivors, so an already-removed child is not revisited.
    [_tests xct_removeObjectsPassingTest:^BOOL(XCTest *test) {
        return [set containsTestIdentifier:[test _xctTestIdentifier]];
    }];
    for (XCTest *test in self.tests) {
        [test _removeTestsWithIdentifierInSet:set];
    }
}

- (void)_removeTestsWithoutIdentifierInSet:(XCTTestIdentifierSet *)set
{
    // The complement: keep only what is in the set, and descend the same way.
    // There is no empty-set guard because an empty set here removes everything,
    // which is a meaningful request rather than a no-op.
    [_tests xct_removeObjectsPassingTest:^BOOL(XCTest *test) {
        return ![set containsTestIdentifier:[test _xctTestIdentifier]];
    }];
    for (XCTest *test in self.tests) {
        [test _removeTestsWithoutIdentifierInSet:set];
    }
}

#pragma mark - Execution

- (void)performTest:(XCTestRun *)run
{
    XCTestRun *suiteRun = run ?: [XCTestSuiteRun testRunWithTest:self];
    self.testRun = suiteRun;
    [suiteRun start];

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    [center testSuiteWillStart:self];

    for (XCTest *test in [_tests copy]) {
        XCTestRun *childRun = [test.testRunClass testRunWithTest:test];
        [test performTest:childRun];
        // Only a suite run aggregates children; a case run's own counters are
        // set by the case itself.
        if ([suiteRun isKindOfClass:[XCTestSuiteRun class]]) {
            [(XCTestSuiteRun *)suiteRun addTestRun:childRun];
        }
    }

    // Stop before notifying, for the same reason XCTestCase does: a didFinish
    // observer that reads the run needs a verdict, not a still-open run.
    [suiteRun stop];
    [center testSuiteDidFinish:self];
}

#pragma mark - Discovery

/// Every loaded XCTestCase subclass, in class-name order.
///
/// The scan is over the runtime rather than over a bundle's image because the
/// reduced Foundation headers in this SDK do not offer enough of NSBundle to
/// enumerate a bundle's classes. Every XCTestCase subclass has to be linked into
/// the process to be runnable at all, so the runtime list is equivalent.
+ (NSArray<Class> *)_xct_discoveredTestCaseClasses
{
    unsigned int count = objc_getClassList(NULL, 0);
    if (count == 0) {
        return @[];
    }
    Class *classes = (Class *)calloc(count, sizeof(Class));
    if (classes == NULL) {
        return @[];
    }
    count = objc_getClassList(classes, count);

    NSMutableArray<Class> *found = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        Class candidate = classes[i];
        for (Class super = class_getSuperclass(candidate); super != Nil;
             super = class_getSuperclass(super)) {
            if (super == [XCTestCase class]) {
                // XCTestCase itself is the base, not something to run.
                if (candidate != [XCTestCase class]) {
                    [found addObject:candidate];
                }
                break;
            }
        }
    }
    free(classes);

    return [found sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        return [NSStringFromClass(left) compare:NSStringFromClass(right)];
    }];
}

+ (XCTestSuite *)testSuiteForBundlePath:(NSString *)bundlePath
{
    XCTestSuite *suite = [[self alloc] initWithName:bundlePath.lastPathComponent ?: @"All Tests"];
    for (Class testCaseClass in [self _xct_discoveredTestCaseClasses]) {
        [suite addTest:[self testSuiteForTestCaseClass:testCaseClass]];
    }
    return suite;
}

+ (XCTestSuite *)testSuiteForTestCaseWithName:(NSString *)name
{
    Class testCaseClass = NSClassFromString(name);
    if (testCaseClass == Nil) {
        return nil;
    }
    return [self testSuiteForTestCaseClass:testCaseClass];
}

+ (XCTestSuite *)testSuiteForTestCaseClass:(Class)testCaseClass
{
    XCTestSuite *suite = [[self alloc] initWithName:NSStringFromClass(testCaseClass)];
    for (NSInvocation *invocation in [testCaseClass testInvocations]) {
        // The case has to be an instance of the discovered subclass. Asking
        // XCTestCase for it would build a base instance that does not override
        // the test method, and every test would fail as unrecognised selector.
        [suite addTest:[testCaseClass testCaseWithInvocation:invocation]];
    }
    return suite;
}

+ (XCTestSuite *)emptyTestSuiteForTestCaseClass:(Class)testCaseClass
{
    // The identifier is built first and used by both branches, from the class
    // name with its module still attached: stripping the module is the
    // identifier's own job when it is constructed, so a Swift class and an
    // Objective-C one reach the same spelling either way round.
    XCTTestIdentifier *identifier = [[XCTTestIdentifier alloc] initWithClassName:NSStringFromClass(testCaseClass)];
    if (XCTTestCaseClassIsAvailable(testCaseClass)) {
        // The case suite names itself from the class, so the name is not passed
        // in here.
        return [[XCTestCaseSuite alloc] initWithTestCaseClass:testCaseClass identifier:identifier];
    }
    // Not runnable here, so not a case suite -- but still a suite, still named
    // and still addressable, because a report that lists the class with nothing
    // under it is the honest outcome, and a missing class is not.
    return [[self alloc] initWithName:[XCTest languageAgnosticTestClassNameForTestClass:testCaseClass]
                            identifier:identifier];
}

#pragma mark - Default suite

// The header declares `defaultTestSuite` as a class property, which synthesises
// this class method; the body is the bundle-wide scan.
+ (XCTestSuite *)defaultTestSuite
{
    return [self testSuiteForBundlePath:@"All Tests"];
}

@end

@implementation XCTestCaseSuite {
    Class _testCaseClass;
}

- (instancetype)initWithTestCaseClass:(Class)testCaseClass identifier:(XCTTestIdentifier *)identifier
{
    // The name is the class name with its module stripped, not the name of the
    // file or bundle it was found in: a suite for a class is what a report
    // prints, and the class is what the caller asked for. XCTestCaseSuite has no
    // setUp or tearDown of its own to contribute yet, so there is nothing else
    // to record here -- the class is what a later pass needs to fill the suite.
    self = [self initWithName:[XCTest languageAgnosticTestClassNameForTestClass:testCaseClass]
                   identifier:identifier];
    if (self != nil) {
        _testCaseClass = testCaseClass;
    }
    return self;
}

- (Class)testCaseClass
{
    return _testCaseClass;
}

@end
