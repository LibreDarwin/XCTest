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
// "Mostly" is doing real work in that sentence. This runtime is not upstream, and
// the one place it is missing *behaviour* rather than declarations is
// NSMeasurement: the classes exist, but neither +[NSUnit secondsUnit] nor
// +[NSMeasurement measurementWithUnit:doubleValue:] is present and NSUnitSeconds
// is not registered at all, so code cannot construct a unit the way upstream does.
// What survives is -[NSUnit initWithSymbol:] and
// -[NSMeasurement initWithDoubleValue:unit:], which is how the performance metric
// headers have to be written; see XCTMetric.h, where those two classes are now
// declared, since a public API mentioning a type has to declare it.
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

// For XCT_EXPORT, and for the KVO options type the categories below are
// written in terms of, which is declared with the public API that names it.
#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTKVOExpectation.h>

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
/// Builds a signature from a type encoding. The encoding is the one the
/// compiler writes, so a block's parameters are not expanded here: "@?" stands
/// for a block and says nothing about what that block takes.
+ (instancetype)signatureWithObjCTypes:(const char *)types;
/// Number of bytes the return value occupies, so the caller can size the
/// buffer it passes to -getReturnValue:.
@property (readonly) NSUInteger methodReturnLength;
/// Number of bytes each argument occupies, excluding the implicit self and _cmd.
@property (readonly) NSUInteger frameLength;
/// How many arguments the signature has, counted the way the runtime counts
/// them: 0 is self and 1 is _cmd. A signature standing for a block has the
/// block itself at index 0, so a handler that takes nothing has a count of 1.
@property (readonly) NSUInteger numberOfArguments;
/// The type encoding of the return value, or null when there is none to read.
@property (readonly, nullable) const char *methodReturnType;
/// The type encoding of the argument at index, counting the way the runtime
/// counts, so index 2 is the first declared argument of an instance method.
- (nullable const char *)getArgumentTypeAtIndex:(NSUInteger)index;
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
/// Enumerates the elements, optionally in reverse. The observation center
/// reports activity finish in reverse registration order so that nested
/// activities unwind in the order they were entered, and NSEnumerationReverse
/// is what expresses that without hand-rolling an index loop. A probe confirms
/// the runtime implements it; only the reduced header omits the declaration.
- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts
                         usingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block;
- (NSUInteger)indexOfObject:(ObjectType)object;
- (NSUInteger)indexOfObjectIdenticalTo:(ObjectType)object;
/// The first index whose element passes `predicate`, or NSNotFound. A probe
/// confirms the runtime implements it; the ordering partition is the caller.
- (NSUInteger)indexOfObjectPassingTest:(BOOL (^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;
/// Flattens the array's elements into one string, which is how a list of test
/// names gets rendered in a single log line.
- (NSString *)componentsJoinedByString:(nullable NSString *)separator;
@end

@interface NSMutableArray<ObjectType> (XCTSDKCompat)
- (void)insertObject:(ObjectType)object atIndex:(NSUInteger)index;
- (void)removeObject:(ObjectType)object;
- (void)removeObjectIdenticalTo:(ObjectType)object;
/// Swaps two elements by index. A probe confirms the runtime implements it; the
/// shuffle and the half-stable partition are built on it.
- (void)exchangeObjectAtIndex:(NSUInteger)index1 withObjectAtIndex:(NSUInteger)index2;
/// Removes the elements in `range`. The removal is by range rather than by
/// predicate because the partition has already moved the matching elements into
/// one contiguous run at the tail, leaving that run to drop.
- (void)removeObjectsInRange:(NSRange)range;
/// Wholesale replacement of the contents, which is how an activity record
/// rebuilds its attachment list after filtering rather than mutating the live
/// collection element by element. A probe confirms the runtime implements it.
- (void)setArray:(NSArray<ObjectType> *)array;
@end

// Clearing a dictionary wholesale, which the reduced NSMutableDictionary.h omits.
// XCTContext does it when a context is invalidated: the associations a context
// was carrying are meaningless once it has ended, and dropping them one by one
// would be both slower and easier to get wrong. A probe confirms the runtime
// implements it.
@interface NSMutableDictionary<KeyType, ObjectType> (XCTSDKCompat)
- (void)removeAllObjects;
@end

// Set filtering the reduced NSSet.h omits. A probe confirms the runtime
// implements it. Class discovery is the caller: it drops the framework's own
// test-case subclasses from a discovered set by image path.
@interface NSSet<ObjectType> (XCTSDKCompat)
- (NSSet<ObjectType> *)objectsPassingTest:(BOOL (^)(ObjectType obj, BOOL *stop))predicate;
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

// The signature of the block passed as argument at index.
//
// Private Foundation API, with no public equivalent, and the only way to learn
// what a block argument actually takes: a method's own type encoding writes every
// block as "@?", which says nothing about the block's parameters. The reference
// asks the signature for one before deciding whether a method is written in the
// async convention.
//
// Measured on this platform: nil at every index tried, for a signature taken from
// a real method as well as one built from a type encoding. So a caller that asks
// for an async convention this way is told nothing, and answers NO. Declared in a
// category rather than in the shim above because the call has to compile under
// both SDKs, and the reduced one hides its Foundation headers inside the guard.
@interface NSMethodSignature (XCTSDKCompatPrivateBlockSignature)
- (nullable instancetype)_signatureForBlockAtArgumentIndex:(NSUInteger)index;
@end

#pragma mark - Failure reporting

// XCTestCore does NOT reintroduce NSAssertionHandler, though the reduced SDK
// omits the class and XCTest adds -handleFailureInMethod: to it upstream.
//
// The reason is the one recorded at the top of XCTestCoreFoundationCompat.h: a
// *method* may be redeclared in a category under both SDKs, but a *class* may
// not -- upstream declares NSAssertionHandler inside NSException.h rather than a
// header of its own, so no __has_include test can tell the two SDKs apart, and an
// unguarded @interface is a hard error wherever the full SDK is in use. The
// reduced SDK additionally declares NSAssertionFailure without exporting the
// symbol, so going through the handler would compile and then fail to link.
//
// XCActivityRecord.m therefore raises the exception itself. NSException,
// +exceptionWithName:reason:userInfo: and NSInternalInconsistencyException are all
// declared in that same reduced header, and all three are what the assertion
// handler would have used to report the same failure.

#pragma mark - Key-value observing

// XCTKVOExpectation registers itself as a KVO observer. The reduced SDK's
// NSObject.h declares none of this API, so it all has to be reintroduced. A
// probe confirms the runtime implements it and that changes are delivered
// synchronously on the mutating thread.
//
// The options type, its constants and the change-dictionary keys are not
// repeated here: they are part of XCTKVOExpectation's own API, so a client that
// passes options needs them too, and they are declared once in
// <XCTest/XCTKVOExpectation.h>, which every user of them imports. What remains
// here is the object-level API with no public counterpart.
//
// The categories are safe under both SDKs, since declaring a method a category
// already declares is legal.
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
// Its construction and evaluation entry points are declared once, in
// <XCTest/XCTNSPredicateExpectation.h>, because a client needs them too: the
// initializer takes an NSPredicate, so a header that only forward-declared the
// class would make it uncallable from outside the framework.

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
