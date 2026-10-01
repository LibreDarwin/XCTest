// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestCase, a single test: one zero-argument, void-returning instance method.

#import <XCTest/XCTestCase.h>
#import <XCTest/XCTestCaseRun.h>
#import <XCTest/XCTestSuite.h>
#import <XCTest/XCTestAssertionsImpl.h>
#import <XCTest/XCTestSkippingImpl.h>
#import <XCTest/XCTIssue.h>
#import <XCTest/XCTExpectedFailure.h>
#import <XCTestCore/XCTTestSelection.h>

#import "XCTestExpectationInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"
#import "XCTestObservationInternal.h"

#import <objc/runtime.h>

#import <pthread.h>
#import <string.h>

/// How long an async teardown block is given when the test sets no execution
/// time allowance. An allowance of 0 means "no limit", which is right for the
/// test body but not for teardown, where a block that never calls back would
/// otherwise hold up the whole run. Deliberately not configurable through the
/// environment: a wedged teardown must not be able to widen its own deadline.
#define _XCTAsyncTeardownDefaultTimeout 30.0

/// One outstanding XCTExpectFailure declaration, held until an issue matches it
/// or the test ends.
@interface _XCTExpectedFailureScope : NSObject
@property (nonatomic, copy, nullable) NSString *reason;
@property (nonatomic, strong) XCTExpectedFailureOptions *options;
@property (nonatomic, assign) pthread_t declaringThread;
@end

@implementation _XCTExpectedFailureScope
@end

/// The selector name with the trailing suffixes the harness appends to mark a
/// method as error- or completion-handler-shaped stripped. The name a report
/// prints is the name the source used: `testFooAndReturnError:` is `testFoo`
/// with a signature the runner understands, not a different test.
static NSString *_XCTSelectorNameByRemovingErrorAndAsyncSuffixes(NSString *selectorName)
{
    static NSString *const errorSuffix = @"AndReturnError:";
    static NSString *const completionSuffix = @"WithCompletionHandler:";
    if ([selectorName hasSuffix:errorSuffix]) {
        selectorName = [selectorName substringToIndex:selectorName.length - errorSuffix.length];
    }
    if ([selectorName hasSuffix:completionSuffix]) {
        selectorName = [selectorName substringToIndex:selectorName.length - completionSuffix.length];
    }
    return selectorName;
}

@implementation XCTestCase {
    NSInvocation *_invocation;
    XCTTestIdentifier *_identifier;
    NSMutableArray<void (^)(void)> *_teardownBlocks;
    NSMutableArray<void (^)(void (^)(NSError *_Nullable))> *_asyncTeardownBlocks;
    NSMutableArray *_expectedFailureScopes;
    NSLock *_expectedFailureLock;
    pthread_t _primaryThread;
    // Performance measurement state, reached through the
    // XCTestCase(XCTInternalPerformance) category that XCTestMetrics.m
    // implements. Declared here for the same reason the expectation-failure
    // state is: a category cannot declare the ivar backing its property, and
    // the measure loop and -startMeasuring/-stopMeasuring have to agree on one
    // piece of state rather than each keeping their own.
    NSMutableArray<XCTPerformanceActivityRecord *> *_performanceRecords;
    id _measureInvocation;
}

#pragma mark - Creation

+ (instancetype)testCaseWithInvocation:(NSInvocation *)invocation
{
    return [[self alloc] initWithInvocation:invocation];
}

- (instancetype)initWithInvocation:(NSInvocation *)invocation
{
    self = [super init];
    if (self != nil) {
        _invocation = invocation;
        _teardownBlocks = [NSMutableArray array];
        _asyncTeardownBlocks = [NSMutableArray array];
        // Not lazily created: -lock on a nil lock is a silent no-op, so a lock
        // allocated on first use would leave the declarations unsynchronized on
        // exactly the concurrent path that needs them locked.
        _expectedFailureLock = [[NSLock alloc] init];
        if (invocation != nil) {
            // The discovered invocation targets the class; a case is its own
            // instance, so re-point it here or the body would run against a
            // class object and see no ivars.
            invocation.target = self;
        }
    }
    return self;
}

- (instancetype)init
{
    // -initWithInvocation: is the designated initializer, so this override is
    // required rather than optional. A case with no invocation can still be
    // built; -invokeTest reports the omission as a failure rather than it
    // silently passing.
    return [self initWithInvocation:nil];
}

+ (instancetype)testCaseWithSelector:(SEL)selector
{
    if (selector == NULL || ![self instancesRespondToSelector:selector]) {
        return nil;
    }
    NSInvocation *invocation =
        [NSInvocation invocationWithMethodSignature:[self instanceMethodSignatureForSelector:selector]];
    // A signature alone is not enough to invoke: the selector is what
    // NSInvocation dispatches through, and a fresh invocation leaves it NULL.
    invocation.selector = selector;
    return [self testCaseWithInvocation:invocation];
}

- (instancetype)initWithSelector:(SEL)selector
{
    XCTestCase *testCase = [self.class testCaseWithSelector:selector];
    return [self initWithInvocation:testCase.invocation];
}

#pragma mark - Identity

- (NSInvocation *)invocation
{
    return _invocation;
}

- (void)setInvocation:(NSInvocation *)invocation
{
    _invocation = invocation;
    invocation.target = self;
}

- (NSString *)name
{
    // The public spelling Apple documents: `-[MyTests testExample]`. The class
    // name is module-stripped and the method name carries neither the trailing
    // signature suffix nor, for Swift, a spelled-out argument list.
    return [NSString stringWithFormat:@"-[%@ %@]",
                                      self.languageAgnosticTestClassName,
                                      self.languageAgnosticTestMethodName];
}

- (NSString *)nameForLegacyLogging
{
    // The legacy spelling keeps the module: the class name here is the one the
    // Objective-C runtime, and so a crash log, uses.
    return [NSString stringWithFormat:@"-[%@ %@]",
                                      NSStringFromClass([self class]),
                                      self.languageAgnosticTestMethodName];
}

- (NSString *)languageSpecificTestClassName
{
    return NSStringFromClass([self class]);
}

- (NSString *)languageAgnosticTestMethodName
{
    // A subclass may rename itself: XCTestCastMethodNamesUIAutomationDelegate
    // does, so an automation script that calls a differently-named method is
    // still reported under the name the script uses. The override wins over the
    // invocation's own selector.
    id<XCTestMethodNameOverriding> overriding = (id<XCTestMethodNameOverriding>)self;
    if ([overriding respondsToSelector:@selector(overridesTestMethodName)] &&
        overriding.overridesTestMethodName) {
        return overriding.overriddenTestMethodName;
    }
    if (self.invocation.selector == NULL) {
        return nil;
    }
    return _XCTSelectorNameByRemovingErrorAndAsyncSuffixes(NSStringFromSelector(self.invocation.selector));
}

- (NSString *)overridden_languageAgnosticTestMethodName
{
    // If the class implements -languageAgnosticTestMethodName itself, that is
    // the name and the rename hooks below do not apply. Compared as an
    // implementation pointer, not by asking -respondsToSelector:, because every
    // case responds -- the question is whether this class's answer is its own.
    if ([self methodForSelector:@selector(languageAgnosticTestMethodName)] !=
        [XCTestCase instanceMethodForSelector:@selector(languageAgnosticTestMethodName)]) {
        return self.languageAgnosticTestMethodName;
    }
    id<XCTestMethodNameOverriding> overriding = (id<XCTestMethodNameOverriding>)self;
    if ([overriding respondsToSelector:@selector(overridesTestMethodName)] &&
        overriding.overridesTestMethodName) {
        return overriding.overriddenTestMethodName;
    }
    return nil;
}

- (NSString *)languageSpecificTestMethodName
{
    SEL selector = self.invocation.selector;
    if (selector == NULL) {
        return nil;
    }
    return [[self class] _languageSpecificTestMethodNameForSelector:selector];
}

+ (NSString *)_languageSpecificTestMethodNameForSelector:(SEL)selector
{
    NSString *name = _XCTSelectorNameByRemovingErrorAndAsyncSuffixes(NSStringFromSelector(selector));
    if (_class_isSwift(self)) {
        // A Swift test method's spelled-out name carries its argument list --
        // `testFoo()` -- which the Objective-C selector has already dropped.
        // Put it back so a name read off a report matches the source.
        name = [name stringByAppendingString:@"()"];
    }
    return name;
}

+ (BOOL)mayBeSwift
{
    return _class_isSwift(self);
}

+ (BOOL)customizesTestMethodNameViaOverrides
{
    // Two independent questions: does this class answer -name itself, and does
    // it answer -languageAgnosticTestMethodName itself. Either override means
    // the cheap selector-derived name would be wrong for it.
    SEL methodNameSelector = @selector(languageAgnosticTestMethodName);
    if ([self instanceMethodForSelector:methodNameSelector] !=
        [XCTestCase instanceMethodForSelector:methodNameSelector]) {
        return YES;
    }
    SEL nameSelector = @selector(name);
    return [self instanceMethodForSelector:nameSelector] !=
           [XCTestCase instanceMethodForSelector:nameSelector];
}

- (XCTTestIdentifier *)_uncachedIdentifierWithClassName:(NSString *)className
{
    // First answer wins: an explicit rename, then the selector spelled with its
    // signature suffix, then the display name, then the reporting fallback,
    // which is never nil.
    NSString *methodName =
        self.overridden_languageAgnosticTestMethodName ?:
        self.languageSpecificTestMethodName ?:
        self.languageAgnosticTestMethodName ?:
        [self _methodNameForReporting];
    return [[XCTTestIdentifier alloc] initWithClassName:className methodName:methodName];
}

- (XCTTestIdentifier *)_xctTestIdentifier
{
    // A case is asked for its identifier once per test-run session and once per
    // report line, so it is built once. @synchronized rather than assumed
    // single-threaded: selection may run concurrently with reporting.
    @synchronized (self) {
        if (_identifier == nil) {
            _identifier = [self _uncachedIdentifierWithClassName:self.languageSpecificTestClassName];
        }
        return _identifier;
    }
}

#pragma mark - Ordering

- (NSComparisonResult)defaultExecutionOrderCompare:(XCTest *)other
{
    // A case only knows how to rank another case. Anything else -- a suite, or
    // an object that is not a test -- sorts ahead of it, which keeps a mixed
    // container's cases together and its suites out of their way. Asked the
    // other direction, the suite ranks itself after the case, so the two agree.
    if (![other isKindOfClass:[XCTestCase class]]) {
        return NSOrderedAscending;
    }
    XCTestCase *otherCase = (XCTestCase *)other;
    if ([[self class] shouldSortTestsBySelector]) {
        // Hand-built cases may have no identifier yet, but they always have a
        // selector, so this path orders by the method name spelled as written
        // rather than by the identifier the rest of the machinery uses.
        return [NSStringFromSelector(self.invocation.selector)
                   caseInsensitiveCompare:NSStringFromSelector(otherCase.invocation.selector)];
    }
    // The method name is the last component of an identifier; the class is the
    // rest, and every case in one container shares it, so comparing it would be
    // constant work. Case-insensitive for the same reason as the suite's name
    // comparison: ordering should not turn on capitalization.
    return [self._xctTestIdentifier.lastComponent
               caseInsensitiveCompare:otherCase._xctTestIdentifier.lastComponent];
}

+ (BOOL)shouldSortTestsBySelector
{
    // NO in the shipping framework: discovered cases always have identifiers and
    // those are the more stable key. The hook exists so a container
    // constructed by hand, whose cases were never given identifiers, can still
    // be given a deterministic order; no in-tree class returns YES.
    return NO;
}

- (NSUInteger)testCaseCount
{
    return 1;
}

- (Class)testRunClass
{
    return [XCTestCaseRun class];
}

#pragma mark - Issue recording

- (void)recordIssue:(XCTIssue *)issue
{
    XCTestRun *run = self.testRun ?: [XCTestCaseRun testRunWithTest:self];

    // The run decides first whether an XCTExpectFailure declaration absorbs this
    // issue, because the answer changes both whether it is counted and whether
    // the test should keep going.
    BOOL absorbed = [run _xct_recordIssue:issue];

    // With continueAfterFailure off, the first failure unwinds the test so the
    // assertions after it do not run and report a cascade of consequences. The
    // issue is already recorded, so the runner can tell this was deliberate and
    // must not count it as an unexpected exception.
    //
    // An absorbed issue is the outcome the test asked for, so it must not
    // unwind: a test written to document a known bug would abort mid-way and be
    // reported as never having finished.
    if (!absorbed && !self.continueAfterFailure && issue.isFailure) {
        // Only the test's own thread can be unwound. The handler for this
        // exception is the @try around the test body, so raising from any other
        // thread unwinds a stack that has no handler for it: for a dispatch
        // queue or a thread already returned, that takes the whole process down
        // instead of stopping the test. The issue is already recorded either
        // way, so the test still fails.
        if (![self _xct_isOnPrimaryThread]) {
            return;
        }
        [[[_XCTestCaseInterruptionException alloc] initWithName:_XCTInternalUnwindExceptionName
                                                       reason:@"Failed assertion"
                                                     userInfo:nil] raise];
    }
}

#pragma mark - Invocation

- (void)invokeTest
{
    SEL selector = _invocation.selector;
    if (selector == NULL) {
        // A fresh NSInvocation has a NULL selector, and invoking through one
        // dispatches via a NULL IMP. The class-level discovery in -testInvocations
        // always assigns one, so this is only reachable from a hand-built
        // invocation.
        [self recordIssue:[[XCTIssue alloc]
                              initWithType:XCTIssueTypeTestFailure
                         compactDescription:@"XCTestCase has no invocation to run"
                                    severity:XCTIssueSeverityError]];
        return;
    }
    _invocation.target = self;
    _invocation.selector = selector;
    [_invocation invoke];
}

#pragma mark - Execution

- (void)performTest:(XCTestRun *)run
{
    XCTestRun *testRun = run ?: [XCTestCaseRun testRunWithTest:self];
    self.testRun = testRun;
    [testRun start];
    testRun.executionCount = 1;

    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    [center testCaseWillStart:self];

    // Installed for the whole body so helpers called without a receiver -- an
    // expectation fulfiller, an async teardown -- still attribute issues here.
    _XCTSetCurrentTestCase(self);

    // Recorded before the body runs, because it is what decides which
    // declarations are allowed to absorb issues coming off other threads.
    [self _xct_markPrimaryThread];

    @try {
        [self setUp];
        [self invokeTest];
    } @catch (_XCTSkipFailureException *skip) {
        // Deliberate: the skip issue was already recorded before the raise.
    } @catch (_XCTestCaseInterruptionException *interruption) {
        // Deliberate: a failed assertion with continueAfterFailure off, or an
        // execution-time interruption.
    } @catch (NSException *exception) {
        [self _recordUnexpectedException:exception];
    }     @catch (...) {
        [self _recordUnexpectedException:nil];
    }
    // TearDown runs even when the test body threw or skipped: a test that
    // allocates in setUp has to be able to release it, otherwise one failure
    // leaks into every later test in the process.
    @try {
        [self tearDown];
    } @catch (_XCTSkipFailureException *skip) {
        // A skip raised from tearDown is still a skip.
        [self.testRun recordIssue:[[XCTIssue alloc]
                                     initWithType:XCTIssueTypeSkippedTest
                                compactDescription:skip.reason ?: @"Test skipped"
                                           severity:XCTIssueSeverityWarning]];
    } @catch (_XCTestCaseInterruptionException *interruption) {
        // An assertion failed in tearDown; the issue is already recorded.
    } @catch (NSException *exception) {
        [self _recordUnexpectedException:exception];
    } @catch (...) {
        [self _recordUnexpectedException:nil];
    }
    [self _runTeardown];

    // After teardown, because a declaration made in the body covers the body and
    // its teardown, and a declaration still standing by now matched nothing.
    [self _xct_finishExpectedFailures];

    _XCTSetCurrentTestCase(nil);

    // The run is closed before observers are told the case finished, so that
    // didFinish: sees a complete run: stopDate set and hasSucceeded meaningful.
    // Notifying first would hand every observer a run that reports failure by
    // default purely because it has not stopped yet.
    [testRun stop];
    [center testCaseDidFinish:self];
}

- (void)_recordUnexpectedException:(NSException *)exception
{
    NSString *reason = nil;
    if ([exception isKindOfClass:[NSException class]]) {
        reason = [NSString stringWithFormat:@"%@: %@", exception.name ?: @"Exception",
                                            exception.reason ?: @"(no reason)"];
    } else {
        // A non-ObjC throw carries nothing inspectable, so there is nothing more
        // specific to say than that the test threw something unexpected.
        reason = @"a non-ObjC exception";
    }
    [self.testRun recordIssue:[[XCTIssue alloc]
                                 initWithType:XCTIssueTypeUncaughtException
                            compactDescription:@"Test threw an unexpected exception"
                           detailedDescription:reason
                             sourceCodeContext:_XCTCurrentSourceCodeContext()
                               associatedError:nil
                                   attachments:@[]]];
}

#pragma mark - Teardown

- (void)addTeardownBlock:(void (^)(void))block
{
    if (block == nil) {
        return;
    }
    [_teardownBlocks addObject:[block copy]];
}

- (void)addAsyncTeardownBlock:(void (^)(void (^completion)(NSError *_Nullable error)))block
{
    if (block == nil) {
        return;
    }
    [_asyncTeardownBlocks addObject:[block copy]];
}

- (void)_runTeardown
{
    // Reverse registration order, so blocks nest like a stack: the first
    // registered runs last, and pairs with the first setUp that followed it.
    for (void (^block)(void) in [_teardownBlocks reverseObjectEnumerator]) {
        @try {
            block();
        } @catch (NSException *exception) {
            [self _recordUnexpectedException:exception];
        } @catch (...) {
            [self _recordUnexpectedException:nil];
        }
    }
    _teardownBlocks = [NSMutableArray array];

    for (void (^block)(void (^)(NSError *_Nullable)) in [_asyncTeardownBlocks reverseObjectEnumerator]) {
        [self _runAsyncTeardownBlock:block];
    }
    _asyncTeardownBlocks = [NSMutableArray array];
}

- (void)_runAsyncTeardownBlock:(void (^)(void (^completion)(NSError *_Nullable)))block
{
    XCTestExpectation *finished = [[XCTestExpectation alloc] initWithDescription:@"async teardown"];
    // The waiter already reports an unfulfilled expectation, and the message it
    // produces is the same failure, so only one of the two reports it.
    finished.xct_reportsAutomaticFailures = NO;

    // Guarded rather than a plain __block BOOL: a block may call back from any
    // thread, and two threads racing through the check below would both believe
    // they were first, fulfilling the expectation twice and unbalancing the
    // waiter's bookkeeping.
    NSLock *completionLock = [[NSLock alloc] init];
    __block BOOL completed = NO;

    // Shared by both catch clauses: a block that threw will never call back, so
    // the expectation is fulfilled here to keep the waiter balanced. The lock
    // covers the case where the block threw after already calling completion.
    void (^abandonCompletion)(void) = ^{
        [completionLock lock];
        BOOL alreadyCompleted = completed;
        completed = YES;
        [completionLock unlock];
        if (!alreadyCompleted) {
            [finished fulfill];
        }
    };

    @try {
        block(^(NSError *_Nullable error) {
            [completionLock lock];
            BOOL alreadyCompleted = completed;
            completed = YES;
            [completionLock unlock];

            if (alreadyCompleted) {
                // Calling back twice would unbalance the waiter. Recorded as a
                // failure of this test rather than an unexpected exception: the
                // test's own code did not throw, it broke the callback contract.
                [self.testRun recordIssue:[[XCTIssue alloc]
                                              initWithType:XCTIssueTypeTestFailure
                                         compactDescription:@"Asynchronous teardown completed more than once"
                                        detailedDescription:@"The completion handler was called again after it had already been called."
                                          sourceCodeContext:_XCTCurrentSourceCodeContext()
                                            associatedError:nil
                                                attachments:@[]]];
                return;
            }
            if (error != nil) {
                [self.testRun recordIssue:[[XCTIssue alloc]
                                              initWithType:XCTIssueTypeTestFailure
                                         compactDescription:@"Asynchronous teardown failed"
                                        detailedDescription:error.localizedDescription
                                          sourceCodeContext:_XCTCurrentSourceCodeContext()
                                            associatedError:error
                                                attachments:@[]]];
            }
            [finished fulfill];
        });
    } @catch (NSException *exception) {
        [self _recordUnexpectedException:exception];
        abandonCompletion();
        return;
    } @catch (...) {
        // Matches _runTeardown: a throw of something that is not an NSException
        // is still the test's failure, not a reason to take down the process.
        [self _recordUnexpectedException:nil];
        abandonCompletion();
        return;
    }

    // An execution time allowance of 0 disables the limit, which is the right
    // default for the test body but not for teardown: a block that never calls
    // back would then hold up the whole run. Fall back to a bound so a wedged
    // teardown is reported instead of stalling indefinitely. A test that wants
    // a different limit sets executionTimeAllowance; nothing else is consulted.
    NSTimeInterval timeout = (self.executionTimeAllowance > 0.0)
        ? self.executionTimeAllowance
        : _XCTAsyncTeardownDefaultTimeout;
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[finished] timeout:timeout];
    if (result != XCTWaiterResultCompleted) {
        [self.testRun recordIssue:[[XCTIssue alloc]
                                      initWithType:XCTIssueTypeTestFailure
                                 compactDescription:@"Asynchronous teardown did not complete"
                                detailedDescription:@"The block never called its completion handler."
                                  sourceCodeContext:_XCTCurrentSourceCodeContext()
                                    associatedError:nil
                                        attachments:@[]]];
    }
}

#pragma mark - Discovery

+ (NSArray<NSInvocation *> *)testInvocations
{
    NSMutableDictionary<NSString *, NSValue *> *selectorsByName = [NSMutableDictionary dictionary];

    // Walk up to but not including XCTestCase, so the framework's own methods
    // are never mistaken for tests while a subclass override still wins.
    for (Class cls = self; cls != Nil && cls != [XCTestCase class];
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (methods == NULL) {
            continue;
        }
        for (unsigned int i = 0; i < count; i++) {
            SEL selector = method_getName(methods[i]);
            const char *name = sel_getName(selector);
            if (name == NULL || strncmp(name, "test", 4) != 0) {
                continue;
            }
            // self and _cmd only: a test takes no arguments.
            if (method_getNumberOfArguments(methods[i]) != 2) {
                continue;
            }
            char *returnType = method_copyReturnType(methods[i]);
            if (returnType == NULL) {
                continue;
            }
            BOOL isVoid = strcmp(returnType, "v") == 0;
            free(returnType);
            if (!isVoid) {
                continue;
            }
            // A subclass method of the same name shadows the superclass one.
            [selectorsByName setObject:[NSValue valueWithPointer:selector]
                                forKey:[NSString stringWithUTF8String:name]];
        }
        free(methods);
    }

    NSArray<NSString *> *names = [selectorsByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSInvocation *> *invocations = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        SEL selector = (SEL)[selectorsByName[name] pointerValue];
        NSMethodSignature *signature = [self instanceMethodSignatureForSelector:selector];
        if (signature == nil) {
            continue;
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.selector = selector;
        invocation.target = self;
        [invocations addObject:invocation];
    }
    return invocations;
}

#pragma mark - Runtime utilities

/// Sorts a set of classes by class name, with the Swift module stripped, so a
/// run is reproducible across processes -- where the runtime's class-list order
/// is not. Sorting by the name a user would write is what the reference does;
/// a name that fails to sort the same way would change the run order.
static NSArray *_XCTSortedClassList(NSSet *classes)
{
    return [[classes allObjects] sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        NSString *leftName = _XCTClassNameWithoutModuleFromClass((Class)left);
        NSString *rightName = _XCTClassNameWithoutModuleFromClass((Class)right);
        return [leftName compare:rightName];
    }];
}

/// Every discoverable subclass, as a set.
///
/// The runtime can grow its class list while it is being copied -- realizing a
/// class can register another -- so the copy is retried until the population
/// stops changing. The reference does the same, for the same reason: a class
/// missed on an unstable pass is a test that silently never runs.
+ (NSSet *)_allSubclasses
{
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) {
        return [NSSet set];
    }

    NSMutableSet *discovered = [NSMutableSet set];
    for (;;) {
        for (unsigned int i = 0; i < count; i++) {
            Class candidate = classes[i];
            if (candidate == self) {
                continue;
            }
            // Walk to the receiver to decide membership, so a class that merely
            // resembles a subclass is not mistaken for one.
            Class superclass = class_getSuperclass(candidate);
            while (superclass != Nil && superclass != self) {
                superclass = class_getSuperclass(superclass);
            }
            if (superclass != self) {
                continue;
            }
            if ([candidate _isDiscoverable]) {
                [discovered addObject:candidate];
            }
        }
        free(classes);

        unsigned int newCount = 0;
        Class *newClasses = objc_copyClassList(&newCount);
        if (newCount == count || newClasses == NULL) {
            free(newClasses);
            break;
        }
        classes = newClasses;
        count = newCount;
    }
    return [discovered copy];
}

+ (NSArray *)allSubclasses
{
    return _XCTSortedClassList([self _allSubclasses]);
}

+ (NSSet *)allSubclassesOutsideXCTest
{
    NSString *xctestBundlePath = [[NSBundle bundleForClass:[XCTestCase class]] bundlePath];
    return [[self _allSubclasses] objectsPassingTest:^BOOL(id candidate, BOOL *stop) {
        (void)stop;
        NSString *candidateBundlePath = [[NSBundle bundleForClass:(Class)candidate] bundlePath];
        return ![candidateBundlePath isEqualToString:xctestBundlePath];
    }];
}

+ (BOOL)_isDiscoverable
{
    NSString *className = NSStringFromClass(self);
    if ([className hasPrefix:@"NSKVONotifying_"]) {
        return NO;
    }
    // A Swift generic class cannot be instantiated by name, so it is not a test
    // case. The name prefix alone is not enough: an Objective-C class is free to
    // be called `_TtGC...`, and _class_isSwift is what tells the two apart.
    if (_class_isSwift(self) && [className hasPrefix:@"_TtGC"]) {
        return NO;
    }
    return YES;
}

#pragma mark - Suite extensions

+ (XCTestSuite *)defaultTestSuite
{
    XCTestSuite *suite = [[XCTestSuite alloc] initWithName:NSStringFromClass(self)];
    for (NSInvocation *invocation in [self testInvocations]) {
        [suite addTest:[XCTestCase testCaseWithInvocation:invocation]];
    }
    return suite;
}

+ (void)setUp
{
}

+ (void)tearDown
{
}

#pragma mark - Performance measurement state

- (NSArray<XCTPerformanceActivityRecord *> *)xct_performanceRecords
{
    // Lazily created rather than reset in -init: a test case that measures
    // nothing, which is nearly all of them, should not pay for an array.
    if (_performanceRecords == nil) {
        _performanceRecords = [NSMutableArray array];
    }
    return [_performanceRecords copy];
}

- (void)setXct_performanceRecords:(NSArray<XCTPerformanceActivityRecord *> *)records
{
    _performanceRecords = [records mutableCopy];
}

- (id)xct_measureInvocation
{
    return _measureInvocation;
}

- (void)setXct_measureInvocation:(id)measureInvocation
{
    _measureInvocation = measureInvocation;
}

#pragma mark - XCTExpectFailure declarations

- (id)_xct_pushExpectedFailureWithReason:(NSString *)reason
                                 options:(XCTExpectedFailureOptions *)options
{
    _XCTExpectedFailureScope *scope = [[_XCTExpectedFailureScope alloc] init];
    scope.reason = reason;
    // Copied, so that a caller reusing or mutating its options object after the
    // declaration cannot change what the declaration already promised to match.
    scope.options = options ? [options copy] : [[XCTExpectedFailureOptions alloc] init];
    scope.declaringThread = pthread_self();

    [_expectedFailureLock lock];
    if (_expectedFailureScopes == nil) {
        _expectedFailureScopes = [NSMutableArray array];
    }
    [_expectedFailureScopes addObject:scope];
    [_expectedFailureLock unlock];

    return scope;
}

- (void)_xct_removeExpectedFailureScope:(id)scope
{
    if (scope == nil) {
        return;
    }
    [_expectedFailureLock lock];
    // A nil-safe remove: the scope may already be gone, because the failure it
    // was waiting for arrived inside the block and consumed it.
    [_expectedFailureScopes removeObjectIdenticalTo:scope];
    [_expectedFailureLock unlock];
}

- (NSString *)_xct_matchExpectedFailureForIssue:(XCTIssue *)issue
{
    // Issue matching is called from every thread that records an issue, so the
    // stack is read and consumed under the lock.
    [_expectedFailureLock lock];
    NSArray<_XCTExpectedFailureScope *> *scopes = [_expectedFailureScopes copy];
    [_expectedFailureLock unlock];

    // Closest declaration wins, so a nested one describes the failure that is
    // actually in front of the test rather than an outer, broader statement.
    for (_XCTExpectedFailureScope *scope in scopes.reverseObjectEnumerator) {
        if (![self _xct_scope:scope matchesIssue:issue]) {
            continue;
        }
        [_expectedFailureLock lock];
        // Removed here rather than in the matcher loop: another thread may have
        // consumed it between the snapshot and this point, and consuming the
        // same declaration twice would let one failure clear two declarations.
        BOOL present = [_expectedFailureScopes containsObject:scope];
        if (present) {
            [_expectedFailureScopes removeObject:scope];
        }
        [_expectedFailureLock unlock];
        if (present) {
            return scope.reason;
        }
        return nil;
    }
    return nil;
}

- (BOOL)_xct_scope:(_XCTExpectedFailureScope *)scope
       matchesIssue:(XCTIssue *)issue
{
    if (!scope.options.isEnabled) {
        return NO;
    }

    // A declaration made on the test's primary thread may absorb an issue
    // recorded on any thread, because that is how an asynchronous helper is
    // covered. One made anywhere else is confined to its own thread, so that a
    // declaration in a background task cannot absorb a failure belonging to
    // unrelated work.
    if (scope.declaringThread != _primaryThread &&
        scope.declaringThread != pthread_self()) {
        return NO;
    }

    BOOL (^matcher)(XCTIssue *) = scope.options.issueMatcher;
    if (matcher == nil) {
        return YES;
    }
    return matcher(issue);
}

- (void)_xct_finishExpectedFailures
{
    [_expectedFailureLock lock];
    NSArray<_XCTExpectedFailureScope *> *remaining = [_expectedFailureScopes copy];
    [_expectedFailureScopes removeAllObjects];
    [_expectedFailureLock unlock];

    XCTestRun *run = self.testRun;
    if (run == nil) {
        return;
    }

    // Reported outermost first, so a reader meets the declarations in the order
    // the test made them.
    for (_XCTExpectedFailureScope *scope in remaining) {
        if (!scope.options.isEnabled || !scope.options.isStrict) {
            // A disabled declaration was never claiming anything, and a
            // non-strict one is used precisely for issues that only appear in
            // some environments.
            continue;
        }
        NSString *description =
            [NSString stringWithFormat:@"XCTExpectFailure was declared but no issue matched it%@",
                                       scope.reason.length > 0
                                           ? [NSString stringWithFormat:@": %@", scope.reason]
                                           : @""];
        [run recordIssue:[[XCTIssue alloc]
                             initWithType:XCTIssueTypeUnmatchedExpectedFailure
                        compactDescription:description
                                   severity:XCTIssueSeverityError]];
    }
}

- (void)_xct_recordIssueWithoutUnwinding:(XCTIssue *)issue
{
    // Same funnel as -recordIssue:, minus the unwind: the run still counts the
    // issue and still consults the expected-failure declarations, but the test
    // keeps running. The test decides for itself whether to keep going, and a
    // callback-driven failure has no assertion on this thread to abandon.
    XCTestRun *run = self.testRun ?: [XCTestCaseRun testRunWithTest:self];
    [run _xct_recordIssue:issue];
}

- (void)_xct_markPrimaryThread
{
    _primaryThread = pthread_self();
}

- (BOOL)_xct_isOnPrimaryThread
{
    return pthread_equal(_primaryThread, pthread_self()) != 0;
}

@end
