// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTKVOExpectation, an expectation satisfied by a key-value change.

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestExpectation.h>

XCT_HEADER_AUDIT_BEGIN

// The Internal SDK's reduced Foundation declares none of the KVO API, including
// the options type used below. A bare forward declaration is safe under both
// SDKs; the options are only ever passed through to Foundation, never
// enumerated here. See XCTestFoundationCompat.h for the reduced-SDK spelling.
#if !__has_include(<Foundation/NSKeyValueObserving.h>)
typedef NS_OPTIONS(NSUInteger, NSKeyValueObservingOptions);
#endif

/// Invoked for each observed change. Return YES to fulfill the expectation and
/// NO to keep waiting. When a handler is set, `expectedValue` is ignored.
typedef BOOL (^XCT_SWIFT_SENDABLE XCKeyValueObservingExpectationHandler)(id observedObject,
                                                                       NSDictionary *change);

/// An expectation fulfilled when a key-value change makes `observedObject`'s
/// `keyPath` satisfy some condition. The expectation registers itself as the
/// observer and unregisters in -dealloc, so a test must keep it alive for the
/// duration of the wait.
XCT_TO_BE_DEPRECATED_WITH_SWIFT_REPLACEMENT("XCTKeyPathExpectation")
@interface XCTKVOExpectation : XCTestExpectation

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDescription:(NSString *)expectationDescription NS_UNAVAILABLE;

/// Designated. Registers the observation immediately with `options`.
- (instancetype)initWithKeyPath:(NSString *)keyPath
                         object:(id)object
                  expectedValue:(nullable id)expectedValue
                       options:(NSKeyValueObservingOptions)options NS_DESIGNATED_INITIALIZER;

/// Registers with NSKeyValueObservingOptionInitial so the current value is
/// checked at once, plus New and Old so a handler sees a populated change
/// dictionary.
- (instancetype)initWithKeyPath:(NSString *)keyPath object:(id)object expectedValue:(nullable id)expectedValue;

/// Fulfilled by any change at all. No Initial option, since there is no value
/// to check, but New and Old are included.
- (instancetype)initWithKeyPath:(NSString *)keyPath object:(id)object;

/// The observed key path.
@property (readonly, copy) NSString *keyPath;

/// The observed object.
@property (readonly, strong) id observedObject;

/// The value awaited at `keyPath`, if any.
@property (nullable, readonly, strong) id expectedValue;

/// The options the observation was registered with.
@property (readonly) NSKeyValueObservingOptions options;

/// Replaces the default "did the value become expectedValue" check.
@property (nullable, copy, atomic) XCKeyValueObservingExpectationHandler handler;

@end

XCT_HEADER_AUDIT_END
