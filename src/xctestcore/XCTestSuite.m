// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestSuite, a collection of tests run as a unit.

#import <XCTest/XCTestSuite.h>
#import <XCTest/XCTestCase.h>
#import <XCTest/XCTestSuiteRun.h>
#import <XCTest/XCTIssue.h>

#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"
#import "XCTestObservationInternal.h"

#import <objc/runtime.h>

#import <stdlib.h>

@implementation XCTestSuite {
    NSMutableArray<XCTest *> *_tests;
    NSString *_name;
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

#pragma mark - Default suite

// The header declares `defaultTestSuite` as a class property, which synthesises
// this class method; the body is the bundle-wide scan.
+ (XCTestSuite *)defaultTestSuite
{
    return [self testSuiteForBundlePath:@"All Tests"];
}

@end
