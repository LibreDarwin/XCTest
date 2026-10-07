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

/// The single run configuration a test runs under when its class contributes no
/// variations: the empty one. The reference seeds the same one-element array of
/// an empty dictionary as the default its descriptor consumer falls back to;
/// an empty dictionary cannot be a static initializer in the Foundation this
/// SDK provides, so the seed is lazy, as it is in the reference.
static NSArray<NSDictionary *> *_XCTestDefaultRunConfigurations;

static NSArray<NSDictionary *> *XCTestDefaultRunConfigurations(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _XCTestDefaultRunConfigurations = @[ @{} ];
    });
    return _XCTestDefaultRunConfigurations;
}

/// The two names a configuration-built suite is given, matching the reference's
/// private _XCTTestSuite_AllTestsIdentifier and
/// _XCTTestSuite_SelectedTestsIdentifier: what runs when a configuration asks
/// for everything, and what runs when a selection names the tests.
static NSString * const XCTestSuiteAllTestsName = @"AllTests";
static NSString * const XCTestSuiteSelectedTestsName = @"SelectedTests";

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

/// Takes over from -name, the same way the reference renames a suite: the
/// container of a selected run is named after its bundle after the container
/// has been built.
- (void)setName:(NSString *)name
{
    _name = [name copy];
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
    // A suite for a whole class is the descriptor consumer with no selection:
    // everything the class discovered runs, under the default configuration.
    return [self _resolveTestSuiteByTestInvocationsInClass:testCaseClass
                              filteringToTestIdentifiersToRun:nil];
}

+ (XCTestSuite *)_resolveTestSuiteByTestInvocationsInClass:(Class)testCaseClass
                               filteringToTestIdentifiersToRun:(XCTTestIdentifierSet *)filter
{
    // The empty suite first: a case suite for a class that can run, a plain
    // named suite for one that cannot, both carrying the class's identifier so
    // a selection that named the class matches this suite later.
    XCTestSuite *suite = [self emptyTestSuiteForTestCaseClass:testCaseClass];
    NSString *classUnavailableReason = nil;
    if (!_XCTTestCaseClassIsAvailable(testCaseClass)) {
        classUnavailableReason = [NSString stringWithFormat:
            @"Test class '%@' is unavailable since it uses features not supported on this OS version",
            testCaseClass];
    }
    for (XCTTestInvocationDescriptor *descriptor in [testCaseClass _testInvocationDescriptors]) {
        // A selection drops a discovered test before anything is built for it.
        // The identifier is asked only of a descriptor with an invocation: a
        // placeholder-carrying descriptor has none to filter by, and the
        // placeholder's identifier is derived from its selector string when it
        // is built, so filtering it here would be answering a question about a
        // name that does not exist yet. A nil identifier means the name cannot
        // be trusted, and the case is kept rather than dropped on a guess.
        if (filter != nil && descriptor.invocation != nil) {
            XCTTestIdentifier *identifier =
                [testCaseClass _identifierForInvocation:descriptor.invocation];
            if (identifier != nil && ![filter containsTestIdentifier:identifier]) {
                continue;
            }
        }
        NSString *reason = classUnavailableReason;
        if (reason == nil && descriptor.invocation == nil) {
            // The other placeholder: the test was discovered and could not be
            // run, and the descriptor carries why. The message is the reference
            // spellings, with a descriptor's own error appended when it has
            // one.
            reason = @"Test is unavailable since it has no invocation";
            if (descriptor.customErrorMessage != nil) {
                reason = [reason stringByAppendingFormat:@". Error: %@",
                         descriptor.customErrorMessage];
            }
        }
        if (reason != nil) {
            XCTTestIdentifier *identifier =
                [testCaseClass _identifierForSelectorString:descriptor.selectorString];
            if (identifier == nil) {
                // The selector was a name after all, even though no method of
                // it exists: the placeholder still has to be addressable, so
                // the identifier falls back to the name as written.
                identifier = [[XCTTestIdentifier alloc] initWithClassName:NSStringFromClass(testCaseClass)
                                                               methodName:descriptor.selectorString];
            }
            [suite addTest:[[XCTestCasePlaceholder alloc] initWithIdentifier:identifier
                                                                      reason:reason]];
            continue;
        }
        // Runnable test: one case per variation, and without variations the
        // default set of one empty configuration -- so a case is never built
        // configuration-less. The configuration is recorded on the case by the
        // two-argument factory.
        NSArray<NSDictionary *> *variations = [testCaseClass _variationOptions].variations;
        if (variations.count == 0) {
            variations = XCTestDefaultRunConfigurations();
        }
        for (NSDictionary *variation in variations) {
            XCTestCase *subtest =
                [testCaseClass testCaseWithInvocation:descriptor.invocation
                                  testRunConfiguration:variation];
            if (filter != nil && ![filter containsTestIdentifier:subtest._xctTestIdentifier]) {
                continue;
            }
            [suite addTest:subtest];
        }
    }
    return suite;
}

- (BOOL)shouldIncludeWhenIncludingEmptySuites
{
    // A suite with tests in it is never in question; this is only about the ones
    // a selection or a filter left with nothing under them.
    if (self.tests.count > 0) {
        return YES;
    }
    // Of the empty suites, only a plain one is kept. It is the suite a class
    // that cannot run here is given, and listing it says "this class is here,
    // and none of it ran" -- which is the truth, and better than its absence. An
    // XCTestCaseSuite is a runnable class, so an empty one means its tests were
    // all filtered out, and there is nothing left to say about it. A subclass
    // with a setUp of its own matches neither and is dropped for the same reason.
    //
    // Compared by IMP rather than by -isKindOfClass: an XCTestCaseSuite *is* a
    // suite, so the kind-of test cannot separate the two, and what is being asked
    // is exactly whether this object runs the suite setUp or a different one.
    IMP setUp = [self methodForSelector:@selector(setUp)];
    if (setUp == [XCTestCaseSuite instanceMethodForSelector:@selector(setUp)]) {
        return NO;
    }
    return setUp == [XCTestSuite instanceMethodForSelector:@selector(setUp)];
}

+ (XCTestSuite *)emptyTestSuiteForTestCaseClass:(Class)testCaseClass
{
    // The identifier is built first and used by both branches, from the class
    // name with its module still attached: stripping the module is the
    // identifier's own job when it is constructed, so a Swift class and an
    // Objective-C one reach the same spelling either way round.
    XCTTestIdentifier *identifier = [[XCTTestIdentifier alloc] initWithClassName:NSStringFromClass(testCaseClass)];
    if (_XCTTestCaseClassIsAvailable(testCaseClass)) {
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

#pragma mark - Selection construction

+ (XCTestSuite *)testSuiteForTestWithIdentifier:(XCTTestIdentifier *)identifier
                                   inTestClass:(Class)testCaseClass
                                     variations:(NSArray<NSDictionary *> *)variations
{
    XCTestSuite *suite = [self emptyTestSuiteForTestCaseClass:testCaseClass];
    BOOL classAvailable = _XCTTestCaseClassIsAvailable(testCaseClass);
    BOOL classAnswersSelectorFactory =
        [testCaseClass respondsToSelector:@selector(testCaseWithSelector:testRunConfiguration:)];
    for (NSDictionary *variation in variations) {
        // Only the last component names the test here: a selection addresses a
        // method, and whichever arguments a parameterized test carries live
        // above that, in the components the case itself knows how to read.
        NSString *lastComponent = identifier.lastComponent;
        if (classAvailable && classAnswersSelectorFactory) {
            // Runnable and built by selector: one real case under each
            // variation. An identifier that names no method answers nil and
            // stays out of the suite.
            XCTestCase *testCase =
                [testCaseClass testCaseWithSelector:NSSelectorFromString(lastComponent)
                                testRunConfiguration:variation];
            if (testCase != nil) {
                [suite addTest:testCase];
            }
        } else if ([testCaseClass respondsToSelector:@selector(_identifierForSelectorString:)]) {
            // Not runnable here, or the class predates the selector factory,
            // but the test is still nameable: a placeholder carries the reason
            // so the report still shows it was asked for.
            XCTTestIdentifier *unavailableIdentifier =
                [testCaseClass _identifierForSelectorString:lastComponent];
            if (unavailableIdentifier != nil) {
                [suite addTest:[[XCTestCasePlaceholder alloc] initWithIdentifier:unavailableIdentifier
                          reason:@"Test is unavailable since it uses features not supported by this OS version"]];
            }
        }
    }
    return suite;
}

+ (XCTestSuite *)_resolveTestSuiteBySelectorsInClass:(XCTTestIdentifierSet *)identifiers
                                    inTestCaseClass:(Class)testCaseClass
{
    XCTestSuite *suite = [self emptyTestSuiteForTestCaseClass:testCaseClass];
    // The class's own variations, or the single empty configuration when it
    // contributes none -- the reference's fall-back from an empty answer.
    NSArray<NSDictionary *> *variations = nil;
    if ([testCaseClass respondsToSelector:@selector(_variationOptions)]) {
        variations = [testCaseClass _variationOptions].variations;
    }
    if (variations.count == 0) {
        variations = @[ @{} ];
    }
    // One flat suite: each identifier contributes a sub-suite holding its
    // cases, and those tests are re-homed here. An identifier that resolves to
    // nothing contributes nothing.
    for (XCTTestIdentifier *identifier in identifiers.sortedIdentifiers) {
        XCTestSuite *subsuite = [self testSuiteForTestWithIdentifier:identifier
                                                        inTestClass:testCaseClass
                                                          variations:variations];
        for (XCTest *test in subsuite.tests) {
            [suite addTest:test];
        }
    }
    return suite;
}

+ (XCTestSuite *)_constructTestSuiteForTestCaseClass:(Class)testCaseClass
                                         testIdentifiersToRun:(XCTTestIdentifierSet *)identifiers
{
    if ([testCaseClass respondsToSelector:@selector(overridesDefaultTestSuite)] &&
        [testCaseClass overridesDefaultTestSuite]) {
        // The class describes itself: take its suite as-is and keep only what
        // the selection asked for. A selection may name the Swift spelling of
        // a method while the set holds the Objective-C one (and vice versa),
        // so the counterpart-completed set is what the pruning checks against.
        XCTestSuite *suite = [testCaseClass defaultTestSuite];
        XCTTestIdentifierSet *requestedIdentifiers = [identifiers setByAddingSwiftCounterparts];
        [suite _removeTestsWithoutIdentifierInSet:requestedIdentifiers];
        // A selection that matches nothing in the class's own suite means there
        // is nothing to run here, and the reference answers nil where an empty
        // suite would be a claim that there was.
        if (suite.tests.count == 0) {
            return nil;
        }
        return suite;
    }
    if ([testCaseClass respondsToSelector:@selector(overridesTestInvocations)] &&
        [testCaseClass overridesTestInvocations]) {
        // The class supplies an invocation list of its own: resolve those, then
        // keep only what the selection asked for, with the same counterpart
        // completion applied to the requested set.
        return [self _resolveTestSuiteByTestInvocationsInClass:testCaseClass
                                    filteringToTestIdentifiersToRun:[identifiers setByAddingSwiftCounterparts]];
    }
    return [self _resolveTestSuiteBySelectorsInClass:identifiers inTestCaseClass:testCaseClass];
}

#pragma mark - Configuration construction

/// The entry a run session uses to turn its configuration into a suite.
+ (instancetype)testSuiteForTestConfiguration:(XCTestConfiguration *)configuration
{
    // The reference builds through -initWithTestConfiguration:, which ignores
    // the receiver it is sent to and answers a brand-new suite. This port keeps
    // the two-method shape but makes the initializer initializer-shaped, so the
    // suite is allocated here and filled below, and the allocation happens once.
    return [[self alloc] _initWithTestConfiguration:configuration];
}

- (instancetype)_initWithTestConfiguration:(XCTestConfiguration *)configuration
{
    // Two shapes of run, decided by whether the configuration's selection names
    // anything to run. With identifiers: a selected run, grouped into classes
    // and resolved. Without: everything in the process runs, one suite per test
    // bundle. Both paths apply the configuration's ordering and its "skip" set
    // to the finished container.
    if (configuration == nil) {
        // The reference treats a nil configuration as a crash-restart event and
        // dives into diagnostics; that recovery is not ported, so there is
        // nothing to build and nil is the honest answer.
        return nil;
    }
    XCTTestIdentifierSet *identifiersToRun = configuration.testIdentifiersToRun;
    NSString *name;
    if (identifiersToRun != nil || configuration.testIdentifiersToSkip.count != 0) {
        name = XCTestSuiteSelectedTestsName;
    } else {
        name = XCTestSuiteAllTestsName;
    }
    self = [self initWithName:name];
    if (self == nil) {
        return self;
    }
    if (identifiersToRun == nil) {
        // Everything: one suite per bundle found in the process, then the
        // ordering and exclusion the configuration asked for.
        NSDictionary<NSString *, XCTestSuite *> *bundles =
            [XCTestSuite suitesForBundlesIncludingEmptySuites:NO];
        for (NSString *bundlePath in bundles) {
            [self addTest:bundles[bundlePath]];
        }
        if (configuration.testExecutionOrdering == XCTTestExecutionOrderingRandom) {
            [self _applyRandomExecutionOrderingWithGenerator:(XCTRandomNumberGenerator)
                                     configuration.randomNumberGenerator];
        }
        if (configuration.testIdentifiersToSkip.count != 0) {
            [self removeTestsWithIdentifierInSet:configuration.testIdentifiersToSkip];
        }
    } else {
        // A selection: grouped and resolved by the class method below, then
        // named after the bundle the run came from.
        NSString *bundleName = configuration.testBundleName;
        if (bundleName == nil) {
            // The reference treats a selection whose bundle has no name the
            // same way it treats a nil configuration: a crash-restart event.
            // Not ported; a run that has nothing to name has nothing.
            return nil;
        }
        XCTestSuite *selected =
            [XCTestSuite testClassSuitesForTestIdentifiers:identifiersToRun
                                  skippingTestIdentifiers:configuration.testIdentifiersToSkip
                                   randomNumberGenerator:(configuration.testExecutionOrdering ==
                                                                  XCTTestExecutionOrderingRandom
                                                          ? (XCTRandomNumberGenerator)
                                                          configuration.randomNumberGenerator
                                                          : nil)];
        [selected setName:bundleName];
        [self addTest:selected];
    }
    return self;
}

/// The selected-tests half of suite building, reachable directly by a caller
/// that already has the identifiers split out.
+ (XCTestSuite *)testClassSuitesForTestIdentifiers:(XCTTestIdentifierSet *)identifiersToRun
                          skippingTestIdentifiers:(XCTTestIdentifierSet *)identifiersToSkip
                             randomNumberGenerator:(XCTRandomNumberGenerator)generator
{
    // A nil "to run" set runs nothing: the reference substitutes the empty set,
    // which groups nothing and leaves the container empty.
    if (identifiersToRun == nil) {
        identifiersToRun = [XCTTestIdentifierSet new];
    }
    // The container is named after the bundle that is actually running, so the
    // report's top line says where the tests came from.
    NSString *suiteName = [XCTestConfiguration activeTestConfiguration].testBundleName;
    XCTestSuite *container = [[self alloc] initWithName:suiteName];
    [self prepareContainerSuite:container toRunTestIdentifiers:identifiersToRun];
    [container _sortTestsUsingDefaultExecutionOrdering];
    if (generator != nil) {
        // Random only when the caller asked for it; a nil generator is how a
        // run that wants the default order stays with the sort above.
        [container _applyRandomExecutionOrderingWithGenerator:generator];
    }
    if (identifiersToSkip.count != 0) {
        // [nil count] is 0, so a selection that names nothing to skip skips the
        // exclusion pass.
        [container removeTestsWithIdentifierInSet:identifiersToSkip];
    }
    return container;
}

+ (void)prepareContainerSuite:(XCTestSuite *)containerSuite
         toRunTestIdentifiers:(XCTTestIdentifierSet *)identifiersToRun
{
    if (identifiersToRun == nil) {
        identifiersToRun = [XCTTestIdentifierSet new];
    }
    NSMutableSet<Class> *wholeClasses = [NSMutableSet set];
    NSMutableDictionary<NSString *, XCTTestIdentifierSet *> *classesToIdentifiers = nil;
    [XCTestSuite groupTestIdentifiers:identifiersToRun
                          intoClasses:&wholeClasses
             andTestMethodIdentifiers:&classesToIdentifiers];

    // Candidates are gathered by name so the container ends up with one suite
    // per class, whether the class was selected whole or by its methods -- or,
    // when the selection names it both ways, one suite holding both. See the
    // merge in the block below.
    NSMutableDictionary<NSString *, XCTestSuite *> *namedSuites = [NSMutableDictionary dictionary];
    void (^addSuite)(XCTestSuite *) = ^(XCTestSuite *candidate) {
        // The reference's add-candidate block asks each candidate for its name
        // and drops the ones without one. Every candidate built here has a
        // name, and following the reference to the letter would empty the
        // container, so the name is the merge key instead: two candidates with
        // the same name are one suite, and the later one's tests join the
        // first's. A candidate that cannot be named still has no key to merge
        // under and is dropped.
        NSString *name = candidate.name;
        if (name == nil) {
            return;
        }
        XCTestSuite *existing = namedSuites[name];
        if (existing == nil) {
            namedSuites[name] = candidate;
            [containerSuite addTest:candidate];
            return;
        }
        // The class arrived twice -- selected whole and selected by a method of
        // it -- so the same test may stand in both suites. A container that
        // held it twice would run it twice, so each of the candidate's tests
        // joins only when the suite does not already hold an equal identifier.
        // A test with no identifier cannot be compared, and is added rather
        // than dropped: losing a real test is the worse of the two errors.
        NSMutableSet<XCTTestIdentifier *> *held = [NSMutableSet set];
        for (XCTest *test in existing.tests) {
            XCTTestIdentifier *identifier = [test _xctTestIdentifier];
            if (identifier != nil) {
                [held addObject:identifier];
            }
        }
        for (XCTest *test in candidate.tests) {
            XCTTestIdentifier *identifier = [test _xctTestIdentifier];
            if (identifier != nil && [held containsObject:identifier]) {
                continue;
            }
            [existing addTest:test];
        }
    };

    // Whole classes first: a class's default suite is the broadest thing it
    // contributes, and a more specific suite for the same class merges into it.
    for (Class testCaseClass in wholeClasses) {
        if (![testCaseClass respondsToSelector:@selector(defaultTestSuite)]) {
            continue;
        }
        XCTestSuite *suite = [testCaseClass defaultTestSuite];
        if (![suite shouldIncludeWhenIncludingEmptySuites]) {
            continue;
        }
        addSuite(suite);
    }

// Classes with specific tests, resolved from the identifiers each was
    // grouped under. Grouping already proved each name resolves to a class;
    // resolving it again is the only way back from the name it keyed by.
    // _constructTestSuiteForTestCaseClass: answers nil when a selection matches
    // nothing in a class's own suite, and the merge drops it the way it drops
    // an unnameable candidate.
    for (NSString *className in classesToIdentifiers) {
        Class testCaseClass = NSClassFromString(className);
        if (testCaseClass == Nil) {
            continue;
        }
        addSuite([XCTestSuite _constructTestSuiteForTestCaseClass:testCaseClass
                                       testIdentifiersToRun:classesToIdentifiers[className]]);
    }
}

+ (void)groupTestIdentifiers:(XCTTestIdentifierSet *)identifiers
                 intoClasses:(NSMutableSet<Class> **)wholeClassIdentifiersOut
    andTestMethodIdentifiers:(NSMutableDictionary<NSString *, XCTTestIdentifierSet *> **)classesToIdentifiersOut
{
    NSMutableSet<Class> *wholeClasses = [NSMutableSet set];
    // A second map holds the build-up, one builder per class name; the map sent
    // out is the finished one, a set of identifiers per class. Both keyed by
    // the name as the identifier spelled it: this platform's NSMapTable offers
    // only its legacy C interface, and the name round-trips through
    // NSClassFromString, which grouping does anyway to prove the class exists.
    NSMutableDictionary<NSString *, XCTTestIdentifierSetBuilder *> *builders =
        [NSMutableDictionary dictionary];
    for (XCTTestIdentifier *identifier in identifiers) {
        // Only a class/method-shaped identifier has a first component that is a
        // class name at all; anything else is skipped rather than guessed at.
        if (!identifier.usesClassAndMethodSemantics || identifier.componentCount == 0) {
            continue;
        }
        NSString *className = identifier.firstComponent;
        Class testCaseClass = NSClassFromString(className);
        if (testCaseClass == Nil) {
            // A selection can name a class that is not loaded in this process;
            // there is no class to group the identifier under, and no code
            // should try to build for it later.
            continue;
        }
        if (identifier.componentCount == 1) {
            // A bare class name runs the whole class.
            [wholeClasses addObject:testCaseClass];
            continue;
        }
        // A class/method pair: accumulated under its class for resolution.
        XCTTestIdentifierSetBuilder *builder = builders[className];
        if (builder == nil) {
            builder = [[XCTTestIdentifierSetBuilder alloc] init];
            builders[className] = builder;
        }
        [builder addTestIdentifier:identifier];
    }
    if (wholeClassIdentifiersOut != NULL) {
        *wholeClassIdentifiersOut = wholeClasses;
    }
    if (classesToIdentifiersOut != NULL) {
        NSMutableDictionary<NSString *, XCTTestIdentifierSet *> *classesToIdentifiers =
            [NSMutableDictionary dictionary];
        for (NSString *className in builders) {
            XCTTestIdentifierSetBuilder *builder = builders[className];
            classesToIdentifiers[className] = builder.testIdentifierSet;
        }
        *classesToIdentifiersOut = classesToIdentifiers;
    }
}

+ (NSDictionary<NSString *, XCTestSuite *> *)suitesForBundlesIncludingEmptySuites:(BOOL)includeEmptySuites
{
    // Nobody in this port asks for YES; in the reference it is the
    // crash-restart restore path, where its -shouldIncludeWhenIncludingEmptySuites:
    // answers NO for every suite and nothing is retained. Matched rather than
    // "fixed": the empty answer is the reference's, and inventing another is
    // the only thing that could be wrong here.
    if (includeEmptySuites) {
        return @{};
    }
    NSString *outerBundlePath = [[NSBundle bundleForClass:[XCTest class]] bundlePath];
    NSMutableDictionary<NSString *, XCTestSuite *> *suites = [NSMutableDictionary dictionary];
    for (Class testCaseClass in [XCTestCase allSubclasses]) {
        NSString *bundlePath = [[NSBundle bundleForClass:testCaseClass] bundlePath];
        // The framework's own classes are the machinery, not a test bundle, and
        // are left out the way the reference's -xct_bundlePathForTestSuite
        // leaves the framework's own bundle out of the scan.
        if (bundlePath == nil || [bundlePath isEqualToString:outerBundlePath]) {
            continue;
        }
        XCTestSuite *suite = [testCaseClass defaultTestSuite];
        if (![suite shouldIncludeWhenIncludingEmptySuites]) {
            continue;
        }
        XCTestSuite *bundleSuite = suites[bundlePath];
        if (bundleSuite == nil) {
            // A bundle's own suite is named from its path, which is the whole
            // of the reference's +emptyTestSuiteNamedFromPath:.
            bundleSuite = [XCTestSuite testSuiteWithName:bundlePath.lastPathComponent ?: bundlePath];
            suites[bundlePath] = bundleSuite;
        }
        [bundleSuite addTest:suite];
    }
    return suites;
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

- (void)setUp
{
    Class testCaseClass = self.testCaseClass;
    // Every subclass inherits +setUp from XCTestCase, so asking whether the class
    // responds is no use at all -- it always does. What distinguishes a class
    // with setup work from one without is whether the IMP it would run is
    // XCTestCase's own, and that is what asking for the method directly answers.
    if ([testCaseClass methodForSelector:@selector(setUp)] == [XCTestCase methodForSelector:@selector(setUp)]) {
        return;
    }
    [XCTContext runInternalActivityNamed:@"Suite Set Up" block:^(id<XCTActivity> activity) {
        (void)activity;
        [self.testCaseClass setUp];
    }];
}

- (void)tearDown
{
    Class testCaseClass = self.testCaseClass;
    if ([testCaseClass methodForSelector:@selector(tearDown)] == [XCTestCase methodForSelector:@selector(tearDown)]) {
        return;
    }
    [XCTContext runInternalActivityNamed:@"Suite Tear Down" block:^(id<XCTActivity> activity) {
        (void)activity;
        [self.testCaseClass tearDown];
    }];
}

@end
