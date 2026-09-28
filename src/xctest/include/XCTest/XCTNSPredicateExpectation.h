// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTNSPredicateExpectation, an expectation satisfied by a predicate.

#import <XCTest/XCTestExpectation.h>

XCT_HEADER_AUDIT_BEGIN

/// Consulted before each evaluation. Return YES to fulfill the expectation
/// without evaluating the predicate, which is how a test forces a completion
/// that the predicate cannot express, such as a timeout of its own.
typedef BOOL (^XCT_SWIFT_SENDABLE XCPredicateExpectationHandler)(void);

// The reduced SDK's Foundation declares no NSPredicate at all, so a bare
// @class would leave this initializer uncallable from a client: there would be
// no way to make the one argument it needs. The construction and evaluation
// entry points are republished here, and only when absent, since the full SDK
// has all of them in NSPredicate.h and a second definition would be a hard
// error. This is a subset of the real class, not a replacement for it: anything
// else a client needs is Foundation's to declare, once the SDK declares it.
#if !__has_include(<Foundation/NSPredicate.h>)
@interface NSPredicate : NSObject
+ (NSPredicate *)predicateWithFormat:(NSString *)format, ...;
+ (NSPredicate *)predicateWithFormat:(NSString *)format argumentArray:(nullable NSArray *)arguments;
+ (NSPredicate *)predicateWithBlock:(BOOL (^)(id evaluatedObject, NSDictionary<NSString *, id> *_Nullable bindings))block;
- (BOOL)evaluateWithObject:(nullable id)object;
@end
#endif /* !__has_include(<Foundation/NSPredicate.h>) */

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
