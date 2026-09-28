// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Foundation declarations the Internal SDK's headers omit but its runtime has.
//
// Why this file exists
// --------------------
// The Internal SDK ships a reduced Foundation header set, while the Foundation
// it links against at runtime is the full upstream implementation. The two do
// not agree, and the mismatch is a header problem, not a runtime one. A probe
// compiled against this SDK and linked against this SDK's Foundation reports:
//
//     class = __NSArrayI                      (the upstream immutable cluster)
//     -[NSArray firstObject]            responds: YES
//     -[NSArray indexOfObject:]         responds: YES
//     +[NSInvocation invocationWithMethodSignature:] responds: YES
//     -[NSString lastPathComponent]     responds: YES
//     -[NSDate timeIntervalSinceDate:]  responds: YES
//
// So the methods below all work; they are simply not declared, and without a
// declaration the compiler rejects the call. Everything the reduced headers do
// declare is a strict subset of upstream Foundation, so this file only ever adds
// back omissions -- it never contradicts a header that is present.
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

NS_ASSUME_NONNULL_BEGIN

// Neither header exists in the SDK. objc/NSObject.h already forward-uses both
// types -- -forwardInvocation: and -methodSignatureForSelector: name them -- so
// these are the missing halves of declarations the SDK itself relies on.
//
// Only the members the test runner needs are declared. NSInvocation is how a
// test method is invoked: an invocation carries a selector, its target and its
// arguments, which is precisely "run this method on this object".
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

NS_ASSUME_NONNULL_END

#endif /* XCTEST_XCTESTFOUNDATIONCOMPAT_H */
