// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Runtime verification for src/xctest/XCTestFoundationCompat.h.
//
// That header declares Foundation API the Internal SDK's headers omit while its
// runtime provides. A declaration like that is a promise this project makes on
// somebody else's behalf, and nothing in the compiler checks the promise: a typo
// or a wrong signature still compiles, then fails at run time inside the test
// runner, far from the cause. This program exercises every declaration in the
// header against the real SDK and fails loudly if any of them is wrong.
//
// Built and run by tools/check-foundation-compat.sh.

#include <stdio.h>

#import <Foundation/Foundation.h>

#import "XCTestFoundationCompat.h"

static int failures = 0;

static void check(BOOL condition, const char *what, const char *detail)
{
    if (condition) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s (%s)\n", what, detail);
        failures++;
    }
}

#pragma mark - Fixtures

@interface Fixture : NSObject
@property (nonatomic, readonly) NSUInteger takeNoArgumentsCallCount;
- (NSInteger)add:(NSInteger)a to:(NSInteger)b;
- (void)takeNoArguments;
@end

@implementation Fixture
- (NSInteger)add:(NSInteger)a to:(NSInteger)b { return a + b; }
- (void)takeNoArguments { _takeNoArgumentsCallCount++; }
@end

#pragma mark - Checks

static void checkInvocation(void)
{
    printf("NSInvocation / NSMethodSignature\n");

    Fixture *fixture = [[Fixture alloc] init];
    SEL selector = @selector(add:to:);

    NSMethodSignature *signature = [fixture methodSignatureForSelector:selector];
    check(signature != nil, "-methodSignatureForSelector: returns a signature",
          "signature was nil");

    // A method returning NSInteger needs at least pointer-width return storage.
    // If this ever reads 0 the offsets in the invocation frame would be wrong
    // and every -getReturnValue: would scribble past its buffer.
    check(signature.methodReturnLength >= sizeof(NSInteger),
          "methodReturnLength covers the return value",
          "too small for an NSInteger");

    NSInvocation *invocation =
        [NSInvocation invocationWithMethodSignature:signature];
    check(invocation != nil, "+invocationWithMethodSignature: returns an invocation",
          "invocation was nil");

    invocation.target = fixture;
    invocation.selector = selector;

    NSInteger forty = 40;
    NSInteger two = 2;
    [invocation setArgument:&forty atIndex:2];
    [invocation setArgument:&two atIndex:3];
    [invocation invoke];

    NSInteger result = 0;
    [invocation getReturnValue:&result];
    check(result == 42, "-invoke dispatches through target and selector",
          "got the wrong result");

    // A freshly created invocation has a nil target and a NULL selector.
    // -invokeWithTarget: sets the target but *not* the selector, so calling it
    // on a fresh invocation dispatches through a NULL IMP and jumps to 0x0.
    // The runner must therefore always assign both before invoking.
    NSMethodSignature *voidSignature =
        [fixture methodSignatureForSelector:@selector(takeNoArguments)];
    NSInvocation *freshInvocation =
        [NSInvocation invocationWithMethodSignature:voidSignature];
    check(freshInvocation.target == nil && freshInvocation.selector == NULL,
          "a fresh invocation has no target and no selector",
          "assumed the NULL-selector trap away");

    // The zero-argument, void case is the one the runner itself uses for test
    // methods, so it is the one that must not regress. -invokeWithTarget: is
    // only safe once the selector has been assigned.
    NSInvocation *voidInvocation =
        [NSInvocation invocationWithMethodSignature:voidSignature];
    voidInvocation.selector = @selector(takeNoArguments);
    [voidInvocation invokeWithTarget:fixture];
    check([fixture takeNoArgumentsCallCount] == 1,
          "-invokeWithTarget: runs once the selector is assigned",
          "the method body did not run exactly once");
}

static void checkCollections(void)
{
    printf("NSArray / NSMutableArray additions\n");

    NSArray *array = @[ @"a", @"b", @"c" ];

    check([array.firstObject isEqualToString:@"a"], "-firstObject returns the head",
          "wrong element");
    check([NSArray array].firstObject == nil, "-firstObject of an empty array is nil",
          "expected nil");

    check([array indexOfObject:@"b"] == 1, "-indexOfObject: finds by equality",
          "wrong index");
    check([array indexOfObject:@"missing"] == NSNotFound,
          "-indexOfObject: reports NSNotFound when absent", "expected NSNotFound");

    check([array indexOfObjectIdenticalTo:@"c"] == 2,
          "-indexOfObjectIdenticalTo: finds by identity", "wrong index");

    check([array componentsJoinedByString:@"-"] != nil &&
          [[array componentsJoinedByString:@"-"] isEqualToString:@"a-b-c"],
          "-componentsJoinedByString: joins in order", "wrong join");

    NSMutableArray *mutable = [array mutableCopy];
    [mutable insertObject:@"z" atIndex:0];
    check([mutable.firstObject isEqualToString:@"z"],
          "-insertObject:atIndex: inserts at the head", "wrong element");

    [mutable removeObject:@"b"];
    check([mutable indexOfObject:@"b"] == NSNotFound,
          "-removeObject: removes by equality", "element still present");

    [mutable addObject:@"b"];
    [mutable removeObjectIdenticalTo:@"b"];
    check([mutable indexOfObject:@"b"] == NSNotFound,
          "-removeObjectIdenticalTo: removes by identity", "element still present");
}

static void checkPaths(void)
{
    printf("NSString path additions\n");

    NSString *path = @"/Users/someone/MyTests.m";

    check([path.lastPathComponent isEqualToString:@"MyTests.m"],
          "-lastPathComponent strips directories", "wrong component");
    check([path.pathExtension isEqualToString:@"m"], "-pathExtension returns the extension",
          "wrong extension");
    check([path.stringByDeletingLastPathComponent isEqualToString:@"/Users/someone"],
          "-stringByDeletingLastPathComponent keeps the directory", "wrong directory");
    check([path.stringByDeletingPathExtension isEqualToString:@"/Users/someone/MyTests"],
          "-stringByDeletingPathExtension drops the extension", "wrong result");
    // Bound to a local first: an @"..." literal inside a message send is fine,
    // but the result then has to be compared, and spelling that comparison
    // inline reads badly enough to be worth the extra line.
    NSString *appended = [@"/a" stringByAppendingPathComponent:@"b"];
    check([appended isEqualToString:@"/a/b"],
          "-stringByAppendingPathComponent: joins with a separator", "wrong result");
}

static void checkBlockSignature(void)
{
    printf("NSMethodSignature block argument lookup\n");

    // XCTestCore decides whether a method is written in the async convention by
    // asking its signature what the handler at index 2 takes, because a method's
    // own encoding writes every block as "@?". Two properties of the answer
    // matter to that decision, and both are checked here.
    Fixture *fixture = [[Fixture alloc] init];

    // nil, not a signature: which is what makes an async test undiscoverable on
    // this platform and the reason no test here asserts that such a test is
    // found.
    NSMethodSignature *signature = [fixture methodSignatureForSelector:@selector(add:to:)];
    check([signature _signatureForBlockAtArgumentIndex:2] == nil,
          "-_signatureForBlockAtArgumentIndex: reports nothing here",
          "a block signature was produced, so the async convention may now differ");

    // nil rather than a raise, including past the end of the signature. XCTestCore
    // guards the index anyway, because an answer about an index the method does
    // not have says nothing about the method -- but it must not cost a test run
    // an exception, or a helper method that happens to be named test* would take
    // the whole discovery pass down with it.
    NSMethodSignature *twoArguments = [fixture methodSignatureForSelector:@selector(takeNoArguments)];
    BOOL raised = NO;
    @try {
        (void)[twoArguments _signatureForBlockAtArgumentIndex:2];
    } @catch (NSException *exception) {
        raised = YES;
    }
    check(!raised, "asking past the end of a signature does not raise",
          "the lookup raised, so discovery of an odd test method would raise too");
}

int main(void)
{
    @autoreleasepool {
        checkInvocation();
        checkBlockSignature();
        checkCollections();
        checkPaths();
    }

    if (failures != 0) {
        printf("\nfoundation-compat: %d declaration(s) do not hold\n", failures);
        return 1;
    }

    printf("\nfoundation-compat: every declaration in XCTestFoundationCompat.h holds\n");
    return 0;
}
