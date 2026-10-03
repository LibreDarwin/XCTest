// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The implementation half of XCTContext. See <XCTest/XCTContext.h> for what is
// public and XCTestInternal.h for what is private; what follows is the object
// that holds a run's activities and the bookkeeping that decides when they are
// allowed to end.
//
// XCTContext lives in XCTestCore even though its public header sits under XCTest:
// the class is not published on its own, and everything it needs -- the activity
// record stack and the observation center -- is core's.

#import <XCTest/XCTestObservationCenter.h>

#import "XCTestInternal.h"

#import <XCTestCore/XCActivityRecord.h>
#import "XCTestObservationInternal.h"

// The SDK's Foundation headers omit -isKindOfClass: on some reduced runtimes but
// libobjc has always exported it. See XCTestFoundationCompat.h.
#import "XCTestFoundationCompat.h"

// The type of an activity a test author asked for by name. Distinct from the
// framework's own bookkeeping types precisely so a reader can tell them apart.
static NSString *const XCActivityTypeUserCreated = @"com.apple.dt.xctest.activity-type.userCreated";

// The key the per-thread context stack is filed under in NSThread's dictionary.
//
// A thread dictionary rather than an ivar because a context belongs to the
// thread that started it, and NSThread already owns storage per thread that goes
// away with the thread.
static NSString *const XCTContextStackThreadDictionaryKey = @"XCTestXCTContextStack";

NS_ASSUME_NONNULL_BEGIN

// XCTestCore raises its own assertion failures rather than using NSAssert; the
// note in XCTActivityRecordStack.m says why. The reference reaches the same
// place through its XCTestCurrentHandler, which this port does not have.
static void XCTContextRaiseAssertion(NSString *description, SEL method)
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ (%@)", description, NSStringFromSelector(method)];
}


@implementation XCTContext {
    // The enclosing context, nil for a root. Strong: a child context cannot
    // outlive the context it is nested in without that context already having
    // been invalidated, and holding it keeps the parent chain intact for
    // -associatedContexts.
    XCTContext *_parent;
    // Weak: a test case outlives the contexts it creates, never the reverse. A
    // strong reference would keep a finished test case and everything it holds
    // alive until the last context referencing it was released.
    __weak XCTestCase *_testCase;
    XCTActivityRecordStack *_activityRecordStack;
    NSDate *_startDate;
    NSMutableDictionary<NSString *, id> *_associatedObjects;
    NSMutableArray<void (^)(void)> *_tearDownBlocks;
    BOOL _isValid;
    BOOL _isReportingBase;
    BOOL _isAncillaryContext;
}

// The three properties the private category declares are implemented by hand
// rather than synthesized: a property declared in a category cannot be
// @synthesize'd from the class implementation, and these three want more than a
// synthesized accessor would give anyway.

#pragma mark - Lifecycle

- (instancetype)initWithParent:(nullable XCTContext *)parent
                      testCase:(nullable XCTestCase *)testCase
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    // Valid with an empty stack: a context that has just been made has nothing
    // to unwind and nothing to tear down. Everything else is created here rather
    // than lazily because the moment a context is created is the moment it starts
    // being timed, and deferring -startDate would make the outermost activity's
    // duration depend on when something first happened to touch the context.
    _isValid = YES;
    _startDate = [[NSDate alloc] init];
    _associatedObjects = [[NSMutableDictionary alloc] init];
    _tearDownBlocks = [[NSMutableArray alloc] init];
    _parent = parent;
    _testCase = testCase;
    _activityRecordStack = [[XCTActivityRecordStack alloc] init];

    return self;
}

- (void)invalidate
{
    @synchronized(self) {
        // Idempotent. A context unwound on the normal path is invalidated again
        // by whichever context owns it, and running the tear-down blocks twice
        // would repeat their side effects.
        if (!_isValid) {
            return;
        }
        _isValid = NO;

        [_associatedObjects removeAllObjects];

        // Copied before draining, because a block is allowed to add another and
        // draining the live array while iterating it would either skip the
        // newcomer or run it now, out of order.
        NSArray<void (^)(void)> *blocks = [_tearDownBlocks copy];
        [_tearDownBlocks removeAllObjects];
        for (void (^block)(void) in blocks) {
            block();
        }
    }
}

- (BOOL)isValid
{
    @synchronized(self) {
        return _isValid;
    }
}

#pragma mark - Activities

- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
{
    return [self willStartActivityWithTitle:title type:type startTime:nil];
}

- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
                                       startTime:(nullable NSDate *)startTime
{
    // Only the thread that started a context may add activities to it. An
    // activity describes work happening under this context, so one started on
    // another thread would name a scope that thread never entered, and there
    // would be nothing on that thread's stack to unwind it against.
    if (![self isBoundToCurrentThread]) {
        XCTContextRaiseAssertion(@"an activity may only be started on the thread that created its context",
                                 @selector(willStartActivityWithTitle:type:startTime:));
    }

    return [_activityRecordStack willStartActivityWithTitle:title
                                                      type:type
                                                 startTime:startTime
                                         observationCenter:self.observationCenter
                                                  context:self];
}

- (void)didFinishActivity:(XCActivityRecord *)activity
{
    [self didFinishActivity:activity finishTime:nil];
}

- (void)didFinishActivity:(XCActivityRecord *)activity
               finishTime:(nullable NSDate *)finishTime
{
    [_activityRecordStack didFinishActivity:activity
                                finishTime:finishTime
                        observationCenter:self.observationCenter
                                 context:self];
}

- (void)unwindRemainingActivities
{
    [_activityRecordStack unwindRemainingActivitiesWithObservationCenter:self.observationCenter
                                                                  context:self];
}

#pragma mark - Stack passthrough

// The stack owns the truth about what is running; these exist so a caller holding
// a context does not have to know that the stack is where it lives.

- (XCTActivityRecordStack *)activityRecordStack
{
    return _activityRecordStack;
}

- (NSUInteger)activityRecordStackDepth
{
    return _activityRecordStack.depth;
}

- (nullable XCActivityRecord *)topActivity
{
    return _activityRecordStack.topActivity;
}

- (NSDictionary<NSString *, id> *)aggregationRecords
{
    return _activityRecordStack.aggregationRecords;
}

#pragma mark - Context graph

- (NSArray<XCTContext *> *)associatedContexts
{
    NSMutableArray<XCTContext *> *contexts = [NSMutableArray array];

    // The contexts already running on this thread, then this one's ancestors.
    // Collected outermost first and reversed below, so the result reads
    // innermost first: that is the order a reader works in, since the closest
    // enclosing context is the one that explains why the ones outside it exist.
    for (XCTContext *context in [[NSThread currentThread] xct_contextStack]) {
        [contexts addObject:context];
    }
    for (XCTContext *context = self.parent; context != nil; context = context.parent) {
        [contexts addObject:context];
    }

    return [[contexts reverseObjectEnumerator] allObjects];
}

- (NSUInteger)transitiveActivityRecordStackDepth
{
    // Measured from the reporting base rather than from zero, so the number is
    // the depth of the whole run and not the depth of whichever part of it this
    // context happens to be.
    NSUInteger depth = 0;
    for (XCTContext *context in self.associatedContexts) {
        if (context.isReportingBase) {
            depth += context.activityRecordStack.depth;
        }
    }
    return depth;
}

- (BOOL)isBoundToCurrentThread
{
    return [[[NSThread currentThread] xct_contextStack] containsObject:self];
}

- (nullable XCTContext *)reportingBaseContext
{
    for (XCTContext *context in self.associatedContexts) {
        if (context.isReportingBase) {
            return context;
        }
    }
    return nil;
}

#pragma mark - Associated state

- (BOOL)isAncillaryContext
{
    return _isAncillaryContext;
}

- (void)setIsAncillaryContext:(BOOL)isAncillaryContext
{
    _isAncillaryContext = isAncillaryContext;
}

- (BOOL)isReportingBase
{
    return _isReportingBase;
}

- (void)setIsReportingBase:(BOOL)isReportingBase
{
    _isReportingBase = isReportingBase;
}

- (nullable id)associatedObjectForKey:(NSString *)key
{
    return _associatedObjects[key];
}

- (void)setAssociatedObject:(nullable id)value forKey:(NSString *)key
{
    _associatedObjects[key] = value;
}

- (void)addTearDownBlock:(XCT_NOESCAPE void (^)(void))block
{
    if (block == nil) {
        XCTContextRaiseAssertion(@"a tear-down block may not be nil", @selector(addTearDownBlock:));
    }
    // Copied, because a block that captured itself would otherwise keep the
    // context alive through its own tear-down list.
    [_tearDownBlocks addObject:[block copy]];
}

#pragma mark - Observation

- (XCTestObservationCenter *)observationCenter
{
    // The reference walks the contexts already running on this thread and asks
    // the first one that has a registry, so that a nested activity reports to
    // the same observers as the run around it. That walk is not reproduced here:
    // every context in this port resolves to the one shared registry, so asking
    // or not asking lands on the same object, and there is no per-run registry
    // for the walk to find.
    return [XCTestObservationCenter sharedTestObservationCenter];
}

#pragma mark - Private state

- (nullable XCTContext *)parent
{
    return _parent;
}

- (nullable XCTestCase *)testCase
{
    return _testCase;
}

- (NSDate *)startDate
{
    return _startDate;
}

- (NSMutableDictionary<NSString *, id> *)associatedObjects
{
    return _associatedObjects;
}

- (NSMutableArray<void (^)(void)> *)tearDownBlocks
{
    return _tearDownBlocks;
}

#pragma mark - Running a block as an activity

+ (void)runActivityNamed:(NSString *)name
                   block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block
{
    XCTContext *context = [self currentContextIfAvailable];
    if (context == nil) {
        XCTContextRaiseAssertion(@"no XCTContext is running on this thread",
                                 @selector(runActivityNamed:block:));
    }
    [context _runActivityNamed:name block:block];
}

+ (void)_runActivityNamed:(NSString *)name
                     type:(NSString *)type
                    block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block
{
    XCTContext *context = [self currentContextIfAvailable];
    if (context == nil) {
        XCTContextRaiseAssertion(@"no XCTContext is running on this thread",
                                 @selector(_runActivityNamed:type:block:));
    }
    [context _runActivityNamed:name type:type block:block];
}

- (void)_runActivityNamed:(NSString *)name
                    block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block
{
    [self _runActivityNamed:name type:XCActivityTypeUserCreated block:block];
}

- (void)_runActivityNamed:(NSString *)name
                    type:(NSString *)type
                   block:(XCT_NOESCAPE void (^)(id<XCTActivity> activity))block
{
    if (block == nil) {
        XCTContextRaiseAssertion(@"an activity block may not be nil",
                                 @selector(_runActivityNamed:type:block:));
    }
    // The pool is pushed and popped around the block rather than left to the
    // enclosing scope: work done inside an activity belongs to that activity,
    // and an object autoreleased out to the end of the test would report its
    // cost against the test rather than against the block that made it.
    @autoreleasepool {
        XCActivityRecord *activity = [self willStartActivityWithTitle:name type:type];
        // @finally, not @catch: a block that throws has still finished. An
        // activity that started and never finished would sit on the stack for
        // the rest of the run, and every later finish would be one record out of
        // step with it.
        @try {
            block(activity);
        } @finally {
            [self didFinishActivity:activity];
        }
    }
}

#pragma mark - Finding the running context

+ (nullable XCTContext *)currentContextIfAvailable
{
    NSMutableArray<XCTContext *> *stack = [[NSThread currentThread] xct_contextStack];
    XCTContext *context = stack.lastObject;
    if (context != nil) {
        return context;
    }
    // Nothing is running here. On the main thread that is the normal state
    // before any test has started -- an activity named outside a test still
    // belongs to somebody -- so a root context is made and adopted. On any other
    // thread it is not: a background thread with no context belongs to no run,
    // and inventing one there would report work nobody asked for and then never
    // unwind it.
    if (![NSThread isMainThread]) {
        return nil;
    }
    context = [[XCTContext alloc] initWithParent:nil testCase:nil];
    [stack addObject:context];
    return context;
}

+ (BOOL)hasCurrentContext
{
    return [self currentContextIfAvailable] != nil;
}

+ (XCTContext *)currentContext
{
    XCTContext *context = [self currentContextIfAvailable];
    if (context == nil) {
        XCTContextRaiseAssertion(@"no XCTContext is running on this thread", @selector(currentContext));
    }
    return context;
}

@end


@implementation NSThread (XCTContext)

- (NSMutableArray<XCTContext *> *)xct_contextStack
{
    NSMutableDictionary *dictionary = self.threadDictionary;
    NSMutableArray<XCTContext *> *stack = dictionary[XCTContextStackThreadDictionaryKey];
    if (stack == nil) {
        // Made here rather than in an initializer because the dictionary is per
        // thread and this is only ever called on the thread doing the running.
        stack = [NSMutableArray array];
        dictionary[XCTContextStackThreadDictionaryKey] = stack;
    }
    return stack;
}

@end

NS_ASSUME_NONNULL_END