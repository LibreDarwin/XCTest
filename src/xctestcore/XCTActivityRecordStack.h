// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The stack of activities currently running, and the timing it accumulates while
// they unwind.
//
// XCTestCore has no other notion of "what is happening right now": a record is
// created when an activity starts, pushed here, and popped when it finishes. The
// nesting is implicit -- the last object is the innermost activity -- so the stack
// is the whole of an activity's context, and a record's parent is simply whatever
// was on top at the moment it was created.
//
// Private, like everything else in this framework: nothing here belongs in
// <XCTest/XCTest.h>.

#ifndef XCTEST_XCTACTIVITYRECORDSTACK_H
#define XCTEST_XCTACTIVITYRECORDSTACK_H

#import <Foundation/Foundation.h>

@class XCActivityRecord;
@class XCTestObservationCenter;
@class XCTContext;

/// Running totals for one aggregation group.
///
/// A group is named by -[XCActivityRecord aggregationIdentifier], and the two
/// numbers kept per group are not the same quantity. `totalTime` is the sum of
/// every member's wall-clock duration, which double-counts work done inside
/// nested activities. `timeMinusSubactivities` subtracts each member's reported
/// child time, leaving what the group itself was responsible for -- which is what
/// makes two activities that both ran for a second but serially report one second
/// rather than two.
@interface XCTActivityAggregationRecord : NSObject
@property double totalTime;
@property double timeMinusSubactivities;
@end

@interface XCTActivityRecordStack : NSObject

/// The running activities, outermost first, so the last object is the innermost.
@property (readonly, nonnull) NSMutableArray<XCActivityRecord *> *storage;

/// Accumulator per aggregation identifier, created on the first record to claim
/// one rather than up front, so an unused identifier costs nothing.
@property (readonly, nonnull) NSMutableDictionary<NSString *, XCTActivityAggregationRecord *> *mutableAggregationRecords;

/// A snapshot of -mutableAggregationRecords. Copied rather than exposed, so a
/// consumer iterating the groups cannot change the totals it is reading.
@property (readonly, copy, nonnull) NSDictionary<NSString *, XCTActivityAggregationRecord *> *aggregationRecords;

/// Starts an activity stamped with the current time.
- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
                               observationCenter:(XCTestObservationCenter *)observationCenter
                                        context:(XCTContext *)context;

/// Starts an activity stamped with `startTime`.
///
/// The start time is a parameter because an activity can be reported as having
/// begun before the stack hears about it -- a measurement that started earlier
/// must not be backdated to whenever it was recorded.
- (XCActivityRecord *)willStartActivityWithTitle:(NSString *)title
                                            type:(NSString *)type
                                       startTime:(nullable NSDate *)startTime
                               observationCenter:(XCTestObservationCenter *)observationCenter
                                        context:(XCTContext *)context;

/// Finishes `activity` now. Equivalent to passing a nil finish time.
- (void)didFinishActivity:(XCActivityRecord *)activity
         observationCenter:(XCTestObservationCenter *)observationCenter
                  context:(XCTContext *)context;

/// Finishes `activity`, unwinding any inner activities first.
///
/// A record that has already been stamped with a finish time is left alone, which
/// is what makes this safe to call twice for the same activity.
- (void)didFinishActivity:(XCActivityRecord *)activity
               finishTime:(nullable NSDate *)finishTime
       observationCenter:(XCTestObservationCenter *)observationCenter
                context:(XCTContext *)context;

/// The finish path itself: stamps the time, pops, accumulates the group's totals,
/// bills the elapsed time to the new innermost activity, reports the finish and
/// invalidates the record.
///
/// Public only because -unwindRemainingActivitiesWithObservationCenter:context:
/// drives it; there is no reason to call it directly, since going through
/// -didFinishActivity:finishTime:observationCenter:context: is what guarantees an
/// activity is on top before it is popped.
- (void)_didFinishActivity:(XCActivityRecord *)activity
                 finishTime:(nullable NSDate *)finishTime
         observationCenter:(XCTestObservationCenter *)observationCenter
                  context:(XCTContext *)context;

/// Pops and finishes everything still running, innermost first.
///
/// This is what a run calls when it ends without unwinding its own activities, so
/// that no record is left with an open scope.
- (void)unwindRemainingActivitiesWithObservationCenter:(XCTestObservationCenter *)observationCenter
                                                context:(XCTContext *)context;

/// How many activities are running.
- (NSUInteger)depth;

/// The innermost running activity, or nil when none are.
- (nullable XCActivityRecord *)topActivity;

@end

#endif /* XCTACTIVITYRECORDSTACK_H */