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
