// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTDarwinNotificationExpectation, an expectation satisfied by a Darwin
// notification (a notify(3) name).

#import <XCTest/XCTestExpectation.h>

XCT_HEADER_AUDIT_BEGIN

/// Invoked when the notification is received. Return YES to fulfill the
/// expectation and NO to keep waiting. Darwin notifications are edge-triggered
/// and carry no payload, so a handler is mostly useful for rejecting a
/// spurious first post.
typedef BOOL (^XCT_SWIFT_SENDABLE XCTDarwinNotificationExpectationHandler)(void);

/// An expectation fulfilled the first time a Darwin notification with the given
/// name is posted. Useful for observing system-level signals, such as a power
/// or display notification, from a test.
@interface XCTDarwinNotificationExpectation : XCTestExpectation

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDescription:(NSString *)expectationDescription NS_UNAVAILABLE;

/// Designated. Begins observing `notificationName` immediately. The token is
/// cancelled in -dealloc, so the expectation must outlive the wait.
- (instancetype)initWithNotificationName:(NSString *)notificationName NS_DESIGNATED_INITIALIZER;

/// The observed notify(3) name.
@property (readonly, copy) NSString *notificationName;

/// Consulted on receipt. When nil, any post fulfills the expectation.
@property (nullable, copy) XCTDarwinNotificationExpectationHandler handler;

@end

XCT_HEADER_AUDIT_END
