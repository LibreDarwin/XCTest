// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Foundation and libSystem declarations the Internal SDK's headers omit but its
// runtime has.
//
// Why this file exists
// --------------------
// The Internal SDK ships a reduced Foundation header set, and the Foundation it
// links against at runtime is not byte-for-byte the upstream one. The two do not
// agree, and the mismatch is mostly a header problem rather than a runtime one. A
// probe compiled against this SDK and linked against this SDK's Foundation
// reports:
//
//     class = NSArray                        (not the upstream __NSArrayI cluster)
//     -[NSArray firstObject]            responds: YES
//     -[NSArray indexOfObject:]         responds: YES
//     +[NSInvocation invocationWithMethodSignature:] responds: YES
//     -[NSString lastPathComponent]     responds: YES
//     -[NSDate timeIntervalSinceDate:]  responds: YES
//     NSPredicate                     present, evaluates correctly
//     KVO add/removeObserver:         present, delivers synchronously
//     notify_register_dispatch        present, handler fires for a posted name
//
// So the methods below all work; they are simply not declared, and without a
// declaration the compiler rejects the call.
//
// "Mostly" is doing real work in that sentence, and the exception is what makes
// this file worth reading closely. This runtime is not upstream: it is missing
// behaviour as well as declarations. NSMeasurement and NSUnit exist, but neither
// +[NSUnit secondsUnit] nor +[NSMeasurement measurementWithUnit:doubleValue:] is
// present and NSUnitSeconds is not registered at all, so a metric cannot be
// written the way upstream writes it. See the Measurements section for the
// initializers that do survive and the way the code is shaped around them.
//
// Everything the reduced headers do declare is a strict subset of upstream
// Foundation, so this file only ever adds back omissions -- it never contradicts
// a header that is present.
//
// The same situation already applies to backtrace()/backtrace_symbols(), whose
// declarations live in the absent <execinfo.h>; see XCTestInternal.h.
//
// Scope discipline: this declares only what the runner actually calls. It is not
// an attempt to reconstruct Foundation, and it should stay small -- if something
// here is never used by src/xctest, it does not belong here.

#ifndef XCTEST_XCTESTFOUNDATIONCOMPAT_H
#define XCTEST_XCTESTFOUNDATIONCOMPAT_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

// The public notify(3) header, when the SDK has one. Imported here rather than
// beside the fallback declarations below because an #import cannot sit inside
// the NS_ASSUME_NONNULL region. See the Darwin notifications section.
#if __has_include(<notify.h>)
#import <notify.h>
#endif

// For XCT_EXPORT, used by the NSKeyValueChange* key declarations below.
#import <XCTest/XCTestDefines.h>

NS_ASSUME_NONNULL_BEGIN

// Neither header exists in the SDK. objc/NSObject.h already forward-uses both
// types -- -forwardInvocation: and -methodSignatureForSelector: name them -- so
// these are the missing halves of declarations the SDK itself relies on.
//
// Only the members the test runner needs are declared. NSInvocation is how a
// test method is invoked: an invocation carries a selector, its target and its
// arguments, which is precisely "run this method on this object".
//
// The full public SDK ships these classes, and re-declaring them there is a
// hard error ("duplicate interface definition"), not a harmless redeclaration.
// The categories further down are safe either way -- declaring a method a
// category already has is legal -- so only the two class redeclarations need
// the guard.
#if !__has_include(<Foundation/NSMethodSignature.h>)
@interface NSMethodSignature : NSObject
/// Number of bytes the return value occupies, so the caller can size the
/// buffer it passes to -getReturnValue:.
@property (readonly) NSUInteger methodReturnLength;
/// Number of bytes each argument occupies, excluding the implicit self and _cmd.
@property (readonly) NSUInteger frameLength;
@end

@interface NSInvocation : NSObject
+ (NSInvocation *)invocationWithMethodSignature:(NSMethodSignature *)signature;
@property (readonly, retain) NSMethodSignature *methodSignature;
@property (nullable, assign) id target;
@property SEL selector;
/// Argument indices are counted as the runtime counts them: 0 is self, 1 is
/// _cmd, and the method's own arguments start at 2. Arguments are passed and
/// returned as raw storage, so the caller supplies a pointer to a value of the
/// declared type, not the value itself.
- (void)setArgument:(void *)argumentLocation atIndex:(NSInteger)index;
- (void)getArgument:(void *)argumentLocation atIndex:(NSInteger)index;
- (void)setReturnValue:(void *)returnValueLocation;
- (void)getReturnValue:(void *)returnValueLocation;
- (BOOL)argumentsRetained;
/// Calls the target's implementation. The invocation must have been given a
/// target and selector first.
- (void)invoke;
/// Assigns the target and then invokes. It does *not* assign the selector, and
/// +invocationWithMethodSignature: leaves the selector NULL, so a fresh
/// invocation invoked this way dispatches through a NULL IMP and crashes. Always
/// assign `selector` before either -invoke or -invokeWithTarget:.
- (void)invokeWithTarget:(id)target;
@end
#endif /* !__has_include(<Foundation/NSMethodSignature.h>) */

// Collection lookups the reduced NSArray.h omits. -firstObject is nil-safe and
// -indexOfObject: returns NSNotFound when absent; both are ordinary upstream
// behaviour and are relied on throughout the runner.
@interface NSArray<ObjectType> (XCTSDKCompat)
@property (readonly, nullable) ObjectType firstObject;
- (NSUInteger)indexOfObject:(ObjectType)object;
- (NSUInteger)indexOfObjectIdenticalTo:(ObjectType)object;
/// Flattens the array's elements into one string, which is how a list of test
/// names gets rendered in a single log line.
- (NSString *)componentsJoinedByString:(nullable NSString *)separator;
@end

@interface NSMutableArray<ObjectType> (XCTSDKCompat)
- (void)insertObject:(ObjectType)object atIndex:(NSUInteger)index;
- (void)removeObject:(ObjectType)object;
- (void)removeObjectIdenticalTo:(ObjectType)object;
@end

// Path decomposition, used to name a test case after its file and to walk a
// bundle path. Upstream semantics, including the empty-string results for a
// bare "/" or a trailing slash.
@interface NSString (XCTSDKCompat)
@property (readonly, copy) NSString *lastPathComponent;
@property (readonly, copy) NSString *pathExtension;
@property (readonly, copy) NSString *stringByDeletingLastPathComponent;
@property (readonly, copy) NSString *stringByDeletingPathExtension;
- (NSString *)stringByAppendingPathComponent:(NSString *)component;
@end

#pragma mark - Key-value observing

// XCTKVOExpectation registers itself as a KVO observer. The reduced SDK's
// NSObject.h declares none of this API, and neither NSKeyValueObservingOptions
// nor the NSKeyValueChange* keys are declared anywhere in the SDK, so all of
// it has to be reintroduced. A probe confirms the runtime implements it and
// that changes are delivered synchronously on the mutating thread.
//
// The enum and keys are redeclared only when absent: the full public SDK has
// them in NSKeyValueObserving.h, and a second definition would be a hard error.
// The categories are safe either way, since declaring a method a category
// already declares is legal.
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

@interface NSObject (XCTSDKCompatKVO)
- (void)addObserver:(NSObject *)observer
         forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options
            context:(nullable void *)context;
- (void)removeObserver:(NSObject *)observer
            forKeyPath:(NSString *)keyPath
               context:(nullable void *)context;
- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath;
- (nullable id)valueForKeyPath:(NSString *)keyPath;
- (void)setValue:(nullable id)value forKeyPath:(NSString *)keyPath;
/// The callback an observer implements. Implemented by every KVO observer, and
/// by NSObject itself, which raises for a change it has no handler for.
- (void)observeValueForKeyPath:(nullable NSString *)keyPath
                      ofObject:(nullable id)object
                        change:(nullable NSDictionary *)change
                       context:(nullable void *)context;
@end

#pragma mark - Predicates

// XCTNSPredicateExpectation evaluates a predicate against an object. The class
// is absent from the reduced headers but present and working in the runtime.
#if !__has_include(<Foundation/NSPredicate.h>)
@interface NSPredicate : NSObject
+ (NSPredicate *)predicateWithFormat:(NSString *)format, ...;
- (BOOL)evaluateWithObject:(nullable id)object;
@end
#endif /* !__has_include(<Foundation/NSPredicate.h>) */

#pragma mark - Measurements

// XCTClockMetric hands back elapsed time as an NSMeasurement in seconds, so
// both classes are needed. This is the one place the reduced runtime is not
// merely missing declarations but missing *behaviour*, and the difference
// decides how the metric has to be written.
//
// Upstream constructs these through class methods:
//     +[NSUnit secondsUnit]
//     +[NSMeasurement measurementWithUnit:doubleValue:]
// A probe finds none of those present, and NSUnitSeconds is not registered at
// all. What survives is the instance initializers:
//     -[NSUnit initWithSymbol:]
//     -[NSMeasurement initWithDoubleValue:unit:]
// and the arithmetic, e.g. 10s - 1.5s = 8.5.
//
// So the metric builds its unit with -initWithSymbol: rather than +secondsUnit.
// That spelling works on the upstream runtime too, which is what keeps this
// single implementation valid under both SDKs. The unit is then treated as an
// opaque object the metric only stores and reads back.
#if !__has_include(<Foundation/NSMeasurement.h>)
@interface NSUnit : NSObject
- (instancetype)initWithSymbol:(NSString *)symbol;
@property (readonly, copy) NSString *symbol;
@end

@interface NSMeasurement : NSObject
- (instancetype)initWithDoubleValue:(double)value unit:(NSUnit *)unit;
@property (readonly) double doubleValue;
@property (readonly, retain) NSUnit *unit;
- (NSMeasurement *)measurementByAddingMeasurement:(NSMeasurement *)other;
- (NSMeasurement *)measurementBySubtractingMeasurement:(NSMeasurement *)other;
- (NSMeasurement *)measurementByConvertingToUnit:(NSUnit *)unit;
- (BOOL)canBeConvertedToUnit:(NSUnit *)unit;
@end
#endif /* !__has_include(<Foundation/NSMeasurement.h>) */

#pragma mark - Darwin notifications

// XCTDarwinNotificationExpectation registers a notify(3) handler. Unlike the
// classes above, the runtime here is complete: a probe finds
// notify_register_dispatch, notify_cancel and notify_post all present in
// libSystem, registration returning 0 and the handler firing for a posted name.
// Only the header is missing, so the same declarations are reintroduced when
// the public one imported above is absent. The signatures are byte-for-byte the
// same either way, so there is only one behaviour to reason about.
#if !__has_include(<notify.h>)
/// The block's argument is the registration token, not a status. notify(3)
/// passes it so the callee can set the notification's state or cancel the
/// registration; a successful delivery is simply the block being called, so
/// there is no argument value that reports failure.
typedef void (^notify_handler_t)(int token);

/// The status a registration returns when it succeeded.
#define NOTIFY_STATUS_OK 0

extern uint32_t notify_register_dispatch(const char *name,
                                         int *out_token,
                                         dispatch_queue_t queue,
                                         notify_handler_t handler);
extern uint32_t notify_cancel(int token);
#endif /* !__has_include(<notify.h>) */

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTFOUNDATIONCOMPAT_H */
