// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The implementation half of XCTActivityRecordStack. See that header for what
// the stack is for; what follows is mostly bookkeeping that has to happen in a
// particular order, and the order is the interesting part.

#import <XCTest/XCTestObservationCenter.h>

#import "XCTActivityRecordStack.h"

// The record whose state this stack fills in, and the observer registry it
// reports through.
#import <XCTestCore/XCActivityRecord.h>
#import "XCTestObservationInternal.h"

// For XCTContext's private -isAncillaryContext.
#import "XCTestInternal.h"

// The SDK's Foundation headers omit -isKindOfClass: on some reduced
// configurations and -componentsJoinedByString: on others; the runtime has both.
// See the header for how that was established.
#import "XCTestFoundationCompat.h"

NS_ASSUME_NONNULL_BEGIN

// XCTestCore raises its own assertion failures rather than using NSAssert. The
// reason is in XCTestFoundationCompat.h: a reduced SDK ships neither
// NSAssertionHandler nor a working NSAssert, so the macro cannot be relied on to
// compile, let alone to raise. NSException itself is always available.
static void XCTActivityRecordStackRaiseAssertion(NSString *description, SEL method)
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ (%@)", description, NSStringFromSelector(method)];
}

@implementation XCTActivityAggregationRecord

@synthesize totalTime = _totalTime;
@synthesize timeMinusSubactivities = _timeMinusSubactivities;

@end

@implementation XCTActivityRecordStack

// Both properties are readonly but backed by storage this class owns and mutates
// directly, so the compiler-synthesized getters are what callers see. They are
// declared here only to make the intended access explicit.
@synthesize storage = _storage;
@synthesize mutableAggregationRecords = _mutableAggregationRecords;

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        // An empty stack is a valid stack, so both collections exist from
        // construction rather than being created on first push. Depth is read
        // during teardown when nothing was ever pushed, and aggregation is read
        // after a run that never ran an activity.
        _storage = [[NSMutableArray alloc] init];
        _mutableAggregationRecords = [[NSMutableDictionary alloc] init];
    }
    return self;
}

#pragma mark - Starting

- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
                               observationCenter:(XCTestObservationCenter *)observationCenter
                                        context:(XCTContext *)context
{
    return [self willStartActivityWithTitle:title
                                      type:type
                                 startTime:nil
                         observationCenter:observationCenter
                                  context:context];
}

- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
                                       startTime:(nullable NSDate *)startTime
                               observationCenter:(XCTestObservationCenter *)observationCenter
                                        context:(XCTContext *)context
{
    if (title == nil) {
        XCTActivityRecordStackRaiseAssertion(@"Title must not be nil", @selector(willStartActivityWithTitle:type:startTime:observationCenter:context:));
    }
    if (type == nil) {
        XCTActivityRecordStackRaiseAssertion(@"ActivityType must not be nil", @selector(willStartActivityWithTitle:type:startTime:observationCenter:context:));
    }

    @synchronized(self) {
        // Parenting is what the stack is for: the activity being started is
        // nested inside whatever was innermost a moment ago. There is no
        // separate tree to walk, so reading the parent and pushing are the same
        // critical section and cannot be interleaved by another thread's start.
        XCActivityRecord *parent = self.storage.lastObject;
        XCActivityRecord *activity = [[XCActivityRecord alloc] initWithParentID:parent.uuid];

        activity.hasAncillaryContext = context.isAncillaryContext;
        activity.title = title;
        activity.activityType = type;

        // A nil start time leaves the record's own creation timestamp in place,
        // which is the right answer: the activity began when it began, and this
        // call is only how we found out.
        if (startTime != nil) {
            activity.start = startTime;
        }

        // Before the record is pushed, and therefore before it can be reached
        // through -topActivity or -storage by anything else looking.
        [activity publishAssociatedSignpostStartEvent];

        // Reported before the push, matching the reference: an observer told
        // about a start should not already be able to see the activity as
        // something it could itself nest inside.
        [observationCenter _context:context willStartActivity:activity];

        [self.storage addObject:activity];
        return activity;
    }
}

#pragma mark - Finishing

- (void)didFinishActivity:(XCActivityRecord *)activity
         observationCenter:(XCTestObservationCenter *)observationCenter
                  context:(XCTContext *)context
{
    [self didFinishActivity:activity
                 finishTime:nil
         observationCenter:observationCenter
                  context:context];
}

- (void)_didFinishActivity:(XCActivityRecord *)activity
                 finishTime:(nullable NSDate *)finishTime
         observationCenter:(XCTestObservationCenter *)observationCenter
                  context:(XCTContext *)context
{
    // A caller that passes no time is asking for "now", not for the record to
    // stay unstamped -- a record popped without a finish time would still read as
    // running.
    if (finishTime == nil) {
        finishTime = [NSDate date];
    }
    activity.finish = finishTime;

    [self.storage removeObject:activity];

    // Aggregated by group, created on demand: the alternative is pre-seeding
    // every identifier a run might use, most of which it will not.
    NSString *group = activity.aggregationIdentifier;
    XCTActivityAggregationRecord *aggregate = self.mutableAggregationRecords[group];
    if (aggregate == nil) {
        aggregate = [[XCTActivityAggregationRecord alloc] init];
        self.mutableAggregationRecords[group] = aggregate;
    }
    aggregate.totalTime = activity.duration;
    aggregate.timeMinusSubactivities = activity.duration - activity.subactivitiesDuration;

    // Read after the pop, so the new innermost activity -- the one that was
    // nested inside the activity being finished -- is what gets billed. Nil
    // sends are no-ops, which is the top-level case.
    XCActivityRecord *parent = self.storage.lastObject;
    [parent subactivityCompletedWithDuration:activity.duration];

    // Before -invalidate: an observer reacting to the finish is still entitled
    // to the record the way it was entitled to it on start.
    [observationCenter _context:context didFinishActivity:activity];

    // Last, because it ends the record's scope. Anything after this point that
    // touches the record is a bug, and the record is the thing that catches it.
    [activity invalidate];
}

- (void)didFinishActivity:(XCActivityRecord *)activity
               finishTime:(nullable NSDate *)finishTime
       observationCenter:(XCTestObservationCenter *)observationCenter
                context:(XCTContext *)context
{
    // Narrowed before `finish` is read. `finish` is a property on the record, not
    // part of the XCTActivity protocol, so a caller holding the protocol can hand
    // us something that does not have it -- and silently treating an unknown
    // object as finished would hide that.
    if (![activity isKindOfClass:[XCActivityRecord class]]) {
        XCTActivityRecordStackRaiseAssertion(@"Activity must be an instance of XCActivityRecord", @selector(didFinishActivity:finishTime:observationCenter:context:));
    }

    // Already finished: leave it alone. This is what makes finishing idempotent,
    // which matters because -unwindRemainingActivitiesWithObservationCenter:
    // drives this method and a caller may have finished the same activity already.
    if (activity.finish != nil) {
        return;
    }

    @synchronized(self) {
        XCActivityRecord *top = (XCActivityRecord *)self.storage.lastObject;

        // The common case, and the only one where nothing else has to be reasoned
        // about: the activity is already innermost.
        if (top == activity) {
            [self _didFinishActivity:activity
                          finishTime:finishTime
                  observationCenter:observationCenter
                           context:context];
            return;
        }

        // Not innermost. Something is running inside it, and those activities
        // have to finish first -- but only if they are ancillary. An activity that
        // is not ancillary is a sibling the caller has no business unwinding on
        // this path, so we stop and let the mismatch below report it.
        while ([((XCActivityRecord *)self.storage.lastObject) hasAncillaryContext]) {
            XCActivityRecord *ancillary = (XCActivityRecord *)self.storage.lastObject;
            if (ancillary == activity) {
                break;
            }
            [self _didFinishActivity:ancillary
                          finishTime:finishTime
                  observationCenter:observationCenter
                           context:context];
        }

        if (self.storage.lastObject != activity) {
            // The reference builds this message out of the whole stack, because
            // "this is not on top" is nearly undebuggable without seeing what
            // is. Raises, so the finish below does not run.
            XCTActivityRecordStackRaiseAssertion([NSString stringWithFormat:@"Activity %@ must be the top of the stack: %@",
                                                  activity,
                                                  [self.storage componentsJoinedByString:@", "]],
                                                  @selector(didFinishActivity:finishTime:observationCenter:context:));
        }

        [self _didFinishActivity:activity
                      finishTime:finishTime
              observationCenter:observationCenter
                       context:context];
    }
}

- (void)unwindRemainingActivitiesWithObservationCenter:(XCTestObservationCenter *)observationCenter
                                                context:(XCTContext *)context
{
    // Through the public method rather than -_didFinishActivity:, so a run that
    // ends without unwinding its own activities still gets the same finish order
    // and the same top-of-stack checking as an orderly one.
    XCActivityRecord *activity = self.storage.lastObject;
    while (activity != nil) {
        [self didFinishActivity:activity
                     finishTime:nil
             observationCenter:observationCenter
                      context:context];
        activity = self.storage.lastObject;
    }
}

#pragma mark - Reading the stack

- (NSUInteger)depth
{
    return self.storage.count;
}

- (nullable XCActivityRecord *)topActivity
{
    return self.storage.lastObject;
}

- (NSDictionary<NSString *, XCTActivityAggregationRecord *> *)aggregationRecords
{
    // Copied: a caller walking the groups should not be able to change the
    // totals as it goes, and should not have to reason about whether it is
    // looking at a snapshot.
    return [self.mutableAggregationRecords copy];
}

@end

NS_ASSUME_NONNULL_END