// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTNSNotificationExpectation, an expectation satisfied by a notification.

#import <XCTest/XCTNSNotificationExpectation.h>

#import "XCTestFoundationCompat.h"

@implementation XCTNSNotificationExpectation {
    NSNotificationName _notificationName;
    id _observedObject;
    NSNotificationCenter *_notificationCenter;
    XCNotificationExpectationHandler _handler;

    // Guards the handler, which the notification center calls on whichever
    // thread posted while a test may install one from another.
    NSLock *_lock;
    BOOL _observing;
}

- (instancetype)initWithName:(NSNotificationName)notificationName
                      object:(id)object
         notificationCenter:(NSNotificationCenter *)notificationCenter
{
    self = [super initWithDescription:[NSString stringWithFormat:@"notification %@ from %@",
                                                                 notificationName,
                                                                 object ?: @"any object"]];
    if (self != nil) {
        _notificationName = [notificationName copy];
        _observedObject = object;
        _notificationCenter = notificationCenter;
        _lock = [NSLock new];
        [self _beginObserving];
    }
    return self;
}

- (instancetype)initWithName:(NSNotificationName)notificationName object:(id)object
{
    return [self initWithName:notificationName object:object notificationCenter:[NSNotificationCenter defaultCenter]];
}

- (instancetype)initWithName:(NSNotificationName)notificationName
{
    return [self initWithName:notificationName object:nil notificationCenter:[NSNotificationCenter defaultCenter]];
}

- (void)dealloc
{
    // The center holds an unretained reference to its observers, so failing to
    // deregister would deliver into freed memory the moment the notification
    // arrives.
    [self _endObserving];
}

#pragma mark - Observation

- (void)_beginObserving
{
    // -addObserver:selector:name:object: delivers on the posting thread, which is
    // what a test wants: the callback runs where the state actually changed, so
    // it can be fulfilled from the code that caused it.
    [_notificationCenter addObserver:self
                            selector:@selector(_xct_notificationPosted:)
                                name:_notificationName
                              object:_observedObject];
    _observing = YES;
}

- (void)_endObserving
{
    if (!_observing) {
        return;
    }
    _observing = NO;
    // Set before deregistering: the center may be posting on another thread
    // right now, and a handler that sees no observer has already left.
    [_notificationCenter removeObserver:self name:_notificationName object:_observedObject];
}

- (void)_xct_notificationPosted:(NSNotification *)notification
{
    // The center already filtered by name and object, so reaching here means the
    // notification matches.
    XCNotificationExpectationHandler handler = self.handler;
    if (handler != nil) {
        if (!handler(notification)) {
            return;
        }
    }
    [self fulfill];
}

#pragma mark - Configuration

- (NSNotificationName)notificationName
{
    return _notificationName;
}

- (id)observedObject
{
    return _observedObject;
}

- (NSNotificationCenter *)notificationCenter
{
    return _notificationCenter;
}

- (XCNotificationExpectationHandler)handler
{
    [_lock lock];
    XCNotificationExpectationHandler handler = _handler;
    [_lock unlock];
    return handler;
}

- (void)setHandler:(XCNotificationExpectationHandler)handler
{
    [_lock lock];
    _handler = [handler copy];
    [_lock unlock];
}

@end
