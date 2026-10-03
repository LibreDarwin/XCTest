// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The recorded result of one activity: what it was called, when it started and
// finished, and whatever it produced along the way.
//
// This is the value half of the activity machinery. XCTContext decides when an
// activity begins and ends, XCTActivityRecordStack keeps the nesting, and this
// class only holds the state both of them fill in and observers read back.

#ifndef XCTEST_XCACTIVITYRECORD_H
#define XCTEST_XCACTIVITYRECORD_H

#import <Foundation/Foundation.h>
#import <XCTest/XCTActivity.h>

NS_ASSUME_NONNULL_BEGIN

@class XCTAttachment;

// NSUUID, declared here rather than forward-declared for the same reason
// XCTestConfiguration.h declares it: -uuid and -parentID hand one back, and a
// client that wants to print or key a record needs -UUIDString, so a @class
// would make a public property uncallable.
//
// The outer guard is shared with XCTestConfiguration.h so that the two headers
// can both reintroduce the class without duplicating it when both are reachable
// -- the umbrella header imports them together. The inner guard is the reduced
// SDK test: a full SDK ships the header, and redeclaring a class is a hard error,
// which is why the whole block is conditional rather than merely annotated.
#ifndef XCTCoreSDKCompat_NSUUID
#define XCTCoreSDKCompat_NSUUID
#if !__has_include(<Foundation/NSUUID.h>)
@interface NSUUID : NSObject <NSCopying, NSSecureCoding>
+ (instancetype)UUID;
- (nullable instancetype)initWithUUIDString:(NSString *)string;
@property (readonly, copy) NSString *UUIDString;
@end
#endif /* !__has_include(<Foundation/NSUUID.h>) */
#endif /* XCTCoreSDKCompat_NSUUID */

/// Seconds spent inside child activities, accumulated by
/// -subactivityCompletedWithDuration: so that a parent can report its own time
/// separately from the time its children consumed.
typedef double XCTActivityDuration;

/// One activity, as reported to observers.
///
/// A record is created when an activity starts and is filled in as it runs. It
/// is handed to the observation center twice -- once on start and once on
/// finish -- and the same instance is passed both times, so an observer can
/// correlate the two and read whatever the activity recorded in between.
///
/// A record stops being usable once its scope has completed. -invalidate is what
/// ends that scope, and using the record afterwards is a programming error
/// rather than a silent no-op: an observer that has already been told the
/// activity finished would otherwise be handed a record that keeps changing.
@interface XCActivityRecord : NSObject <XCTActivity>

/// Creates a record whose parent is `parentID`, or a root record when that is
/// nil. The start and finish dates are both stamped at creation, so a record is
/// well-formed before its activity has run.
- (instancetype)initWithParentID:(nullable NSUUID *)parentID NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

/// Identifier of the activity this one was nested in, or nil for a root.
@property (readonly, copy, nullable) NSUUID *parentID;

/// Identifier unique to this record, generated at creation. Children are handed
/// this as their parent identifier, which is what ties the tree together.
@property (readonly, copy) NSUUID *uuid;

/// Human-readable label. Initialised to the empty string rather than to a
/// placeholder: an unnamed activity is distinguished by having no name, and
/// giving every record the same default would make that indistinguishable from a
/// genuinely-titled one in a report.
@property (copy, nullable) NSString *title;

/// Initialised to the framework's own internal marker, so a consumer can tell a
/// record XCTest made from one a test's activity without being told separately.
@property (copy, nullable) NSString *activityType;

/// The reference's -init allocates only the start date. A finished-but-unstamped
/// record therefore reads as still running here, which is the intended reading.
@property (copy, nullable) NSDate *start;
@property (copy, nullable) NSDate *finish;

/// How long the activity took, measured finish minus start. Zero while an
/// activity is still running and whenever finish is unset.
@property (readonly) XCTActivityDuration duration;

/// Seconds attributed to child activities, excluding time this activity spent
/// on its own work.
@property (readonly) XCTActivityDuration subactivitiesDuration;

/// Adds a completed child's duration to -subactivitiesDuration. The record stack
/// calls this as each nested activity finishes.
- (void)subactivityCompletedWithDuration:(XCTActivityDuration)duration;

/// NO once -invalidate has been called. Callbacks that need the record to still
/// be live check this first.
@property (readonly, getter=isValid) BOOL valid;

/// Marks the record finished for good. Called when the activity's scope
/// completes, including on the paths where it ends early.
- (void)invalidate;

/// YES for a record that is not nested inside another activity.
@property BOOL isTopLevel;

/// YES when the activity carried context the reader is expected to have.
@property BOOL hasAncillaryContext;

/// Signpost identifier for this activity, or NSUIntegerMax when the run is not
/// emitting signposts. Assigned by the machinery that decides whether to signpost
/// at all; never set by hand.
@property NSUInteger signpostId;

/// Emits the signpost event that marks this activity starting.
///
/// A no-op unless a signpost identifier has been assigned, which is what makes
/// it safe to call unconditionally: a run that is not tracing pays a load and a
/// compare, and a run that is tracing gets the event. The record stack calls this
/// as the activity is pushed, before observers are told about the start.
- (void)publishAssociatedSignpostStartEvent;

/// Groups sibling activities for aggregation. Consumers key aggregation off
/// this, so an absent identifier leaves the record ungrouped. The reference
/// initialises it to the literal @"Other" rather than to nil -- an unnamed record
/// still has to group as *something* -- and it is deliberately not the same value
/// as the default title, because a title that matched it would pull unrelated
/// activities into one group.
@property (copy, nullable) NSString *aggregationIdentifier;

/// Free-form values the activity chose to publish with it, keyed by string.
///
/// This is the reference's `NSMutableDictionary`, and that is not a detail: the
/// stack writes aggregation fields into a record's metadata through keyed
/// subscripting, so an immutable dictionary here would make the consumer
/// unbuildable. It is readwrite and mutable rather than copy-on-assignment,
/// which also matches the reference's property, whose accessors are a plain `&`
/// with no copy attribute.
@property NSMutableDictionary<NSString *, id> *metadata;

/// Set when the record's attachments are encoded the legacy way, for consumers
/// that predate the current format. Not consumed yet.
@property BOOL useLegacySerializationFormat;

/// Backing store for the attachments. Exposed because -attachments returns a
/// snapshot while this is the live collection.
@property (readonly, strong) NSMutableArray<XCTAttachment *> *mutableAttachments;

/// Snapshot of the attachments added so far, in the order they were added.
@property (readonly, copy) NSArray<XCTAttachment *> *attachments;

/// The first attachment with this name, or nil.
- (nullable XCTAttachment *)attachmentForName:(NSString *)name;

/// Removes every attachment with this name and returns how many went.
- (NSUInteger)removeAttachmentsWithName:(NSString *)name;

/// Swaps the first attachment with this name for a replacement.
- (void)replaceAttachment:(XCTAttachment *)attachment
           withAttachment:(nullable XCTAttachment *)replacement;

@end

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCACTIVITYRECORD_H */