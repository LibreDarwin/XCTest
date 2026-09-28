// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTNSNotificationExpectation, an expectation satisfied by a notification.

#import <XCTest/XCTestExpectation.h>

XCT_HEADER_AUDIT_BEGIN

/// Invoked when a notification matching the expectation's name and object
/// arrives. Return YES to fulfill the expectation and NO to keep waiting, which
/// is how a test inspects a notification's payload before committing to it.
typedef BOOL (^XCT_SWIFT_SENDABLE XCNotificationExpectationHandler)(NSNotification *notification);

@interface XCTNSNotificationExpectation : XCTestExpectation

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDescription:(NSString *)expectationDescription NS_UNAVAILABLE;

/// Designated. Observes `notificationCenter` for `notificationName` posted by
/// `object`, or by any object when `object` is nil.
- (instancetype)initWithName:(NSNotificationName)notificationName
                      object:(nullable id)object
         notificationCenter:(NSNotificationCenter *)notificationCenter NS_DESIGNATED_INITIALIZER;

/// Observes the default notification center for `notificationName` posted by
/// `object`.
- (instancetype)initWithName:(NSNotificationName)notificationName object:(nullable id)object;

/// Observes the default notification center for `notificationName` posted by
/// any object.
- (instancetype)initWithName:(NSNotificationName)notificationName;

/// The notification name being waited on.
@property (readonly, copy) NSNotificationName notificationName;

/// The object whose notifications are awaited, or nil for any object.
@property (nullable, readonly, strong) id observedObject;

/// The center being observed.
@property (readonly, strong) NSNotificationCenter *notificationCenter;

/// Consulted for each matching notification. When nil, the first matching
/// notification fulfills the expectation.
@property (nullable, copy) XCNotificationExpectationHandler handler;

@end

XCT_HEADER_AUDIT_END
