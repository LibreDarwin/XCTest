// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTKVOExpectation, an expectation satisfied by a key-value change.

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestExpectation.h>

XCT_HEADER_AUDIT_BEGIN

// The reduced SDK's Foundation declares none of the KVO API -- not the options
// type named below, and not the option constants or change-dictionary keys that
// any caller passing options has to write. Reintroducing only the typedef would
// leave the initializer unusable from a client, so the whole surface is
// republished here, and only when it is absent: the full SDK has all of it in
// NSKeyValueObserving.h, and a second definition would be a hard error. The
// runtime implements every symbol below, verified by the KVO checks in
// tools/expectations-test.m.
#if !__has_include(<Foundation/NSKeyValueObserving.h>)
typedef NS_OPTIONS(NSUInteger, NSKeyValueObservingOptions) {
    NSKeyValueObservingOptionNew = 0x01,
    NSKeyValueObservingOptionOld = 0x02,
    NSKeyValueObservingOptionInitial = 0x04,
    NSKeyValueObservingOptionPrior = 0x08,
};

XCT_EXPORT NSString *const NSKeyValueChangeNewKey;
XCT_EXPORT NSString *const NSKeyValueChangeOldKey;
XCT_EXPORT NSString *const NSKeyValueChangeKindKey;
#endif /* !__has_include(<Foundation/NSKeyValueObserving.h>) */

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
