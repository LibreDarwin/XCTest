// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTNSPredicateExpectation, an expectation satisfied by a predicate.

#import <XCTest/XCTestExpectation.h>

// The Internal SDK's reduced Foundation does not declare NSPredicate, so the
// include above does not introduce it either. A bare @class is legal even
// where Foundation later declares the real interface, so this is safe under
// both SDKs and needs no conditional. It sits outside the audit region because
// NS_ASSUME_NONNULL does not apply to a forward declaration.
@class NSPredicate;

XCT_HEADER_AUDIT_BEGIN

/// Consulted before each evaluation. Return YES to fulfill the expectation
/// without evaluating the predicate, which is how a test forces a completion
/// that the predicate cannot express, such as a timeout of its own.
typedef BOOL (^XCT_SWIFT_SENDABLE XCPredicateExpectationHandler)(void);

@interface XCTNSPredicateExpectation : XCTestExpectation

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDescription:(NSString *)expectationDescription NS_UNAVAILABLE;

/// Designated. The expectation is fulfilled when `predicate` first evaluates
/// true against `object`, or when `object` is nil, against the key-value coding
/// state of the expectation itself.
- (instancetype)initWithPredicate:(NSPredicate *)predicate
                           object:(nullable id)object NS_DESIGNATED_INITIALIZER;

/// Evaluated repeatedly, on a timer, until it succeeds or the wait times out.
@property (readonly, copy) NSPredicate *predicate;

/// The object the predicate is evaluated against, if any.
@property (nullable, readonly, strong) id object;

/// Overrides predicate evaluation when set.
@property (nullable, copy) XCPredicateExpectationHandler handler;

/// A predicate either succeeds or does not, so counting fulfillments has no
/// meaning here.
@property (nonatomic) NSUInteger expectedFulfillmentCount NS_UNAVAILABLE;

@end

XCT_HEADER_AUDIT_END
