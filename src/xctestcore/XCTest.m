// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTest, the abstract base of everything runnable.
//
// XCTestCase and XCTestSuite differ almost entirely in how they execute, so this
// base stays thin: identity, the run it performs against, and the lifecycle
// hooks. Anything a subclass overrides, it overrides -performTest: wholesale
// rather than filling in hooks here.

#import <XCTest/XCAbstractTest.h>
#import <XCTest/XCTIssue.h>

#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"

#import <objc/runtime.h>

@implementation XCTest {
    NSString *_name;
    XCTestRun *_testRun;
    XCTestObservationCenter *_xct_observationCenter;
}

#pragma mark - Observation

- (XCTestObservationCenter *)_xct_observationCenter
{
    // Synchronized because two activities starting at once on two threads both
    // come through here, and both would otherwise create a registry and one of
    // them would report to a registry no observer ever registered with.
    @synchronized(self) {
        if (_xct_observationCenter == nil) {
            _xct_observationCenter = [XCTestObservationCenter sharedTestObservationCenter];
        }
        return _xct_observationCenter;
    }
}

#pragma mark - Identity

- (NSUInteger)testCaseCount
{
    // Abstract. A case overrides this with 1 and a suite with the sum over its
    // children; answering 0 here keeps an unimplemented subclass from claiming
    // to have executed anything.
    return 0;
}

- (NSString *)name
{
    return _name ?: NSStringFromClass([self class]);
}

- (NSString *)nameForLegacyLogging
{
    // The base has no class-and-method spelling of its own to offer, so a
    // subclass that does not name itself here falls back to -name.
    return self.name;
}

- (NSString *)languageAgnosticTestClassName
{
    return _XCTClassNameWithoutModuleFromClass([self class]);
}

// The class-method form of the accessor above, declared in XCTestInternal.h
// next to the property. One C helper under both spellings, on purpose: a suite
// names its class through this, and the cases inside that suite name the same
// class through the instance accessor, and those two names have to be the same
// string for a selection written either way to find the same class.
+ (NSString *)languageAgnosticTestClassNameForTestClass:(Class)testCaseClass
{
    return _XCTClassNameWithoutModuleFromClass(testCaseClass);
}

- (nullable NSString *)languageAgnosticTestMethodName
{
    // A suite has no single method; only a case overrides this.
    return nil;
}

- (NSString *)_methodNameForReporting
{
    // A single test reports the method it runs, with the harness suffixes
    // stripped. A suite that reaches here has no method, so it names itself
    // instead, which keeps the report from printing an empty subject.
    if ([self isKindOfClass:[XCTestCase class]] && ((XCTestCase *)self).invocation.selector != NULL) {
        return [self languageAgnosticTestMethodName] ?: @"";
    }
    return [NSString stringWithFormat:@"unspecifiedMethod_%@", self.name];
}

- (Class)testRunClass
{
    // Abstract: nil until a subclass names the run type it produces.
    return Nil;
}

- (XCTestRun *)testRun
{
    return _testRun;
}

- (void)setTestRun:(XCTestRun *)testRun
{
    _testRun = testRun;
}

#pragma mark - Execution

- (void)performTest:(XCTestRun *)run
{
    // Abstract. Reporting rather than returning quietly matters: a subclass that
    // forgets to override this would otherwise look like a passing test.
    [run start];
    [run recordIssue:[[XCTIssue alloc] initWithType:XCTIssueTypeTestFailure
                                compactDescription:[NSString stringWithFormat:
                                                      @"-[%@ performTest:] is not implemented",
                                                      NSStringFromClass([self class])]
                                            severity:XCTIssueSeverityError]];
    [run stop];
}

- (void)runTest
{
    // The factory lives on the run class, not on the test class, so it has to
    // go through testRunClass; asking self.class for it would look for
    // +testRunWithTest: on the test case subclass and raise.
    Class runClass = self.testRunClass;
    XCTestRun *run = (runClass != Nil) ? [runClass testRunWithTest:self] : nil;
    [self performTest:run];
}

#pragma mark - Ordering

- (NSComparisonResult)defaultExecutionOrderCompare:(XCTest *)other
{
    // An object that is not a runnable test has no natural place in a test
    // order, so the base refuses to rank it either way. A container overrides
    // this to order its own kind; the base answer is only reached by a test that
    // is not a case and not a suite, which cannot occur in a real run.
    return NSOrderedSame;
}

- (void)_removeTestsWithIdentifierInSet:(XCTTestIdentifierSet *)set
{
    // A single test is removed by the container that holds it, not by itself.
    // Only a container has children to filter, so the base does nothing.
}

- (void)_removeTestsWithoutIdentifierInSet:(XCTTestIdentifierSet *)set
{
    // The complement of the above, and likewise a container's concern.
}

#pragma mark - Lifecycle

- (void)setUp
{
}

- (void)tearDown
{
}

- (void)setUpWithCompletionHandler:(void (^)(NSError *_Nullable error))completion
{
    [self setUp];
    completion(nil);
}

- (BOOL)setUpWithError:(NSError **)error
{
    [self setUp];
    return YES;
}

- (void)tearDownWithCompletionHandler:(void (^)(NSError *_Nullable error))completion
{
    [self tearDown];
    completion(nil);
}

- (BOOL)tearDownWithError:(NSError **)error
{
    [self tearDown];
    return YES;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p name=%@>",
                                      NSStringFromClass([self class]), (void *)self, self.name];
}

@end
