// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The state side of an activity: identity, timing, and attachments.
//
// The ordering here is not incidental. A record is created before its activity
// has run, so both timestamps are stamped at init and are meaningful from the
// first moment; finish is then overwritten when the activity actually completes.
// Doing it that way means a record handed to an observer on start already has a
// well-formed duration field rather than a nil date that every reader would have
// to special-case.

#import <XCTestCore/XCActivityRecord.h>

#import <XCTest/XCTAttachment.h>

#import "XCTestFoundationCompat.h"

NS_ASSUME_NONNULL_BEGIN

// The activity type every record starts out with when its creator did not name
// one. It is an internal marker rather than a human-readable category: consumers
// distinguish the framework's own activities from a test's by this string.
static NSString *const XCActivityRecordDefaultActivityType =
    @"com.apple.dt.xctest.activity-type.internal";

// A record with no aggregation identifier still has to group as *something*, so
// it groups under this literal. It is the aggregation identifier's default, not
// the title's: -_title is initialised to the empty string, and a title that
// happened to match this one would collide with it in an aggregation.
static NSString *const XCActivityRecordDefaultAggregationIdentifier = @"Other";

@implementation XCActivityRecord
{
    BOOL _valid;
    BOOL _useLegacySerializationFormat;
    XCTActivityDuration _subactivitiesDuration;
    // Marks an id that has already had a signpost published for it. No signpost
    // is published yet, so this stays at its initial value and is not read.
    NSUInteger _signpostId;

    // Guards _mutableAttachments. Attachments may be added from any thread, and
    // are reported in the order they were added, so the collection has to be
    // both appended to and read under the same lock.
    NSLock *_attachmentLock;
}

- (instancetype)initWithParentID:(nullable NSUUID *)parentID
{
    self = [super init];
    if (self != nil) {
        // Derived from the reference's -initWithParentID:, store by store. Only
        // one NSDate is allocated, and it is the *start*: _finish is deliberately
        // left nil, which is what -duration's nil guard is for. Setting a finish
        // here would make every unfinished activity report a nonzero span.
        _valid = YES;
        _uuid = [[NSUUID alloc] init];
        _parentID = [parentID copy];
        _start = [[NSDate alloc] init];
        _title = @"";
        _activityType = [XCActivityRecordDefaultActivityType copy];
        _aggregationIdentifier = [XCActivityRecordDefaultAggregationIdentifier copy];
        _mutableAttachments = [NSMutableArray array];
        // Stated rather than left to zero-fill: the reference stores this byte
        // explicitly, and it is the flag that chooses between the two attachment
        // encodings, so its default is worth naming.
        _useLegacySerializationFormat = NO;
        // No signpost has been published, and -1 is the sentinel for "none yet".
        _signpostId = NSUIntegerMax;
        _attachmentLock = [[NSLock alloc] init];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithParentID:nil];
}

#pragma mark - Identity

- (NSString *)name
{
    return self.title;
}

#pragma mark - Validity

- (BOOL)isValid
{
    return _valid;
}

- (void)invalidate
{
    _valid = NO;
}

/// Raises if the record's scope has already completed.
///
/// Attachments are the case that needs this. A record is handed to observers on
/// start, and the same instance is handed again on finish, so an observer that
/// keeps a reference has an object whose fields are still writable afterwards.
/// Writing to one of those would change a record that a reporter has already
/// read, so the write is refused rather than silently accepted.
// The reference calls NSAssertionHandler's -handleFailureInMethod: here, naming
// the method it was reached through. XCTestCore cannot: see the note in
// XCTestFoundationCompat.h -- NSAssertionHandler cannot be redeclared under the
// full SDK, and the reduced SDK's NSAssert does not even link. Raising the
// exception directly is the convention this tree already follows for the same
// failure, and it reaches the same handler with the same method name.
- (void)_ensureValidForMutation:(SEL)method
{
    if (_valid) {
        return;
    }

    [NSException raise:NSInternalInconsistencyException
                format:@"Activity cannot be used after its scope has completed. (%@)",
                       NSStringFromSelector(method)];
}

#pragma mark - Timing

- (XCTActivityDuration)duration
{
    NSDate *finish = self.finish;
    if (finish == nil) {
        return 0;
    }
    return [finish timeIntervalSinceDate:self.start];
}

- (XCTActivityDuration)subactivitiesDuration
{
    return _subactivitiesDuration;
}

- (void)subactivityCompletedWithDuration:(XCTActivityDuration)duration
{
    _subactivitiesDuration += duration;
}

#pragma mark - Signposts

@synthesize signpostId = _signpostId;

- (void)publishAssociatedSignpostStartEvent
{
    // The reference checks this same sentinel before emitting anything. Until a
    // run has actually assigned a signpost id there is no signpost to publish
    // against, so this returns without doing work -- which is why the record
    // stack can call it unconditionally rather than the run deciding first.
    if (_signpostId == NSUIntegerMax) {
        return;
    }

    // Emitting the event itself is deferred to the signpost work that will assign
    // identifiers. Until then the no-signpost configuration is the only one that
    // can be reached, so there is nothing to publish and the guard above is the
    // whole behaviour. See -signpostId.
}

#pragma mark - Attachments

// The getter is hand-written so the lock is taken, which suppresses
// auto-synthesis, so the backing ivar is asked for explicitly.
@synthesize mutableAttachments = _mutableAttachments;

- (NSMutableArray<XCTAttachment *> *)mutableAttachments
{
    [_attachmentLock lock];
    NSMutableArray<XCTAttachment *> *attachments = _mutableAttachments;
    [_attachmentLock unlock];
    return attachments;
}

- (NSArray<XCTAttachment *> *)attachments
{
    [_attachmentLock lock];
    NSArray<XCTAttachment *> *snapshot = [_mutableAttachments copy];
    [_attachmentLock unlock];
    return snapshot;
}

- (void)addAttachment:(XCTAttachment *)attachment
{
    [self _ensureValidForMutation:_cmd];
    if (attachment == nil) {
        return;
    }

    [_attachmentLock lock];
    [_mutableAttachments addObject:attachment];
    [_attachmentLock unlock];
}

- (nullable XCTAttachment *)attachmentForName:(NSString *)name
{
    if (name == nil) {
        return nil;
    }

    [_attachmentLock lock];
    XCTAttachment *match = nil;
    for (XCTAttachment *attachment in _mutableAttachments) {
        if ([attachment.name isEqualToString:name]) {
            match = attachment;
            break;
        }
    }
    [_attachmentLock unlock];
    return match;
}

- (NSUInteger)removeAttachmentsWithName:(NSString *)name
{
    [self _ensureValidForMutation:_cmd];
    if (name == nil) {
        return 0;
    }

    [_attachmentLock lock];
    NSMutableArray<XCTAttachment *> *survivors =
        [NSMutableArray arrayWithCapacity:_mutableAttachments.count];
    NSUInteger removed = 0;
    for (XCTAttachment *attachment in _mutableAttachments) {
        if ([attachment.name isEqualToString:name]) {
            removed++;
        } else {
            [survivors addObject:attachment];
        }
    }
    if (removed > 0) {
        [_mutableAttachments setArray:survivors];
    }
    [_attachmentLock unlock];
    return removed;
}

- (void)replaceAttachment:(XCTAttachment *)attachment
           withAttachment:(nullable XCTAttachment *)replacement
{
    [self _ensureValidForMutation:_cmd];
    if (attachment == nil) {
        return;
    }

    [_attachmentLock lock];
    NSUInteger index = [_mutableAttachments indexOfObjectIdenticalTo:attachment];
    if (index != NSNotFound) {
        if (replacement == nil) {
            [_mutableAttachments removeObjectAtIndex:index];
        } else {
            [_mutableAttachments replaceObjectAtIndex:index withObject:replacement];
        }
    }
    [_attachmentLock unlock];
}

@end

NS_ASSUME_NONNULL_END