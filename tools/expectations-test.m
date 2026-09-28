// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for the four specialized expectation subclasses.
//
// Each check states what would make its expectation satisfied and then waits on
// it, so a check that passes has proved the subclass both delivered and settled
// the wait -- a subclass that registers the wrong observer, or one that fires
// without fulfilling, fails here even though it links. Run against the built
// framework rather than the sources, so it also covers installation, umbrella
// visibility, and the reduced SDK's missing declarations.
//
// Where a check has to look at something other than the wait's outcome it says
// why in a comment. -xct_fulfillmentCount is the one private API used: notify(3)
// coalesces posts, so a Darwin delivery can beat the wait that is about to
// start, and a timeout would then be indistinguishable from a lost notification.
#import <XCTest/XCTest.h>

// The only private header this harness reaches for, for the reason above.
#import "XCTestExpectationInternal.h"

#import <dispatch/dispatch.h>
#import <stdio.h>
#import <unistd.h>

#if !__has_include(<notify.h>)
typedef void (^notify_handler_t)(int token);
extern uint32_t notify_register_dispatch(const char *, int *, dispatch_queue_t, notify_handler_t);
extern uint32_t notify_cancel(int token);
extern uint32_t notify_post(const char *);
#define NOTIFY_STATUS_OK 0
#endif

#if !__has_include(<Foundation/NSPredicate.h>)
@interface NSPredicate : NSObject
+ (NSPredicate *)predicateWithFormat:(NSString *)format, ...;
- (BOOL)evaluateWithObject:(id)object;
@end
#endif

#if !__has_include(<Foundation/NSKeyValueObserving.h>)
typedef NS_OPTIONS(NSUInteger, NSKeyValueObservingOptions) {
    NSKeyValueObservingOptionNew = 0x01,
    NSKeyValueObservingOptionOld = 0x02,
    NSKeyValueObservingOptionInitial = 0x04,
};
extern NSString *const NSKeyValueChangeNewKey;
#endif

static int failures = 0;

static void ok(const char *name, BOOL passed, const char *detail)
{
    printf("  %-52s %s%s%s\n", name, passed ? "PASS" : "FAIL", (detail && *detail) ? " - " : "", (detail && *detail) ? detail : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Fixtures

@interface Subject : NSObject
@property (atomic, assign) int counter;
@property (atomic, copy) NSString *name;
@end

@implementation Subject
@end

static void postLater(NSNotificationCenter *center, NSString *name, id object, NSTimeInterval delay)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        [center postNotificationName:name object:object];
    });
}

#pragma mark - Checks

static void checkNotification(void)
{
    NSNotificationCenter *center = [NSNotificationCenter new];
    Subject *subject = [Subject new];
    subject.name = @"target";

    // The plain case: the first matching post fulfills.
    XCTNSNotificationExpectation *e = [[XCTNSNotificationExpectation alloc] initWithName:@"ping"
                                                                                   object:subject
                                                                      notificationCenter:center];
    ok("notification: properties", [e.notificationName isEqual:@"ping"] && e.observedObject == subject && e.notificationCenter == center, NULL);
    postLater(center, @"ping", subject, 0.05);
    XCTWaiterResult r = [XCTWaiter waitForExpectations:@[ e ] timeout:2.0];
    ok("notification: fulfilled by post", r == XCTWaiterResultCompleted, NULL);

    // A non-matching post must not fulfill it.
    XCTNSNotificationExpectation *e2 = [[XCTNSNotificationExpectation alloc] initWithName:@"ping"
                                                                                    object:subject
                                                                       notificationCenter:center];
    postLater(center, @"other", subject, 0.05);
    r = [XCTWaiter waitForExpectations:@[ e2 ] timeout:0.3];
    ok("notification: ignores other name", r == XCTWaiterResultTimedOut, NULL);

    // A post from a different object must not fulfill it either.
    XCTNSNotificationExpectation *e3 = [[XCTNSNotificationExpectation alloc] initWithName:@"ping"
                                                                                    object:subject
                                                                       notificationCenter:center];
    postLater(center, @"ping", [Subject new], 0.05);
    r = [XCTWaiter waitForExpectations:@[ e3 ] timeout:0.3];
    ok("notification: ignores other object", r == XCTWaiterResultTimedOut, NULL);

    // A handler that says no keeps the expectation pending, and a later post
    // that it accepts does fulfill it.
    __block int calls = 0;
    XCTNSNotificationExpectation *e4 = [[XCTNSNotificationExpectation alloc] initWithName:@"ping"
                                                                                    object:subject
                                                                       notificationCenter:center];
    e4.handler = ^BOOL(NSNotification *note) {
        calls++;
        return calls >= 2;
    };
    postLater(center, @"ping", subject, 0.05);
    postLater(center, @"ping", subject, 0.15);
    r = [XCTWaiter waitForExpectations:@[ e4 ] timeout:2.0];
    ok("notification: handler veto then accept", r == XCTWaiterResultCompleted && calls == 2, NULL);

    // Releasing an expectation that was never fulfilled must deregister, or the
    // next post would deliver into freed memory.
    @autoreleasepool {
        XCTNSNotificationExpectation *doomed = [[XCTNSNotificationExpectation alloc] initWithName:@"ping"
                                                                                            object:subject
                                                                                   notificationCenter:center];
        (void)doomed;
    }
    postLater(center, @"ping", subject, 0.02);
    usleep(150000);
    ok("notification: dealloc deregisters", YES, NULL);
}

static void checkPredicate(void)
{
    Subject *subject = [Subject new];
    subject.counter = 0;

    // False now, true after a delay: the wait must end when it becomes true.
    XCTNSPredicateExpectation *e = [[XCTNSPredicateExpectation alloc] initWithPredicate:
                                       [NSPredicate predicateWithFormat:@"counter == 3"]
                                                                              object:subject];
    ok("predicate: properties", e.predicate != nil && e.object == subject, NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        subject.counter = 3;
    });
    XCTWaiterResult r = [XCTWaiter waitForExpectations:@[ e ] timeout:2.0];
    ok("predicate: fulfilled when it becomes true", r == XCTWaiterResultCompleted, NULL);

    // Never true: the wait must time out rather than spin forever.
    XCTNSPredicateExpectation *never = [[XCTNSPredicateExpectation alloc] initWithPredicate:
                                            [NSPredicate predicateWithFormat:@"counter == 99"]
                                                                           object:subject];
    r = [XCTWaiter waitForExpectations:@[ never ] timeout:0.3];
    ok("predicate: times out when it never holds", r == XCTWaiterResultTimedOut, NULL);

    // A handler takes precedence over the predicate and can fulfill on its own.
    __block int polls = 0;
    XCTNSPredicateExpectation *handled = [[XCTNSPredicateExpectation alloc] initWithPredicate:
                                               [NSPredicate predicateWithFormat:@"counter == 99"]
                                                                              object:subject];
    handled.handler = ^BOOL {
        return ++polls >= 3;
    };
    r = [XCTWaiter waitForExpectations:@[ handled ] timeout:2.0];
    ok("predicate: handler overrides predicate", r == XCTWaiterResultCompleted && polls >= 3, NULL);

    // A predicate over a key the object does not have raises. That must not
    // escape into the waiter's poll loop and take the process down.
    XCTNSPredicateExpectation *bad = [[XCTNSPredicateExpectation alloc] initWithPredicate:
                                          [NSPredicate predicateWithFormat:@"noSuchKey == 1"]
                                                                             object:subject];
    r = [XCTWaiter waitForExpectations:@[ bad ] timeout:1.0];
    ok("predicate: malformed key path does not crash", r == XCTWaiterResultCompleted, NULL);
}

static void checkKVO(void)
{
    Subject *subject = [Subject new];
    subject.counter = 0;

    XCTKVOExpectation *e = [[XCTKVOExpectation alloc] initWithKeyPath:@"counter" object:subject expectedValue:@7];
    ok("kvo: properties", [[e.keyPath copy] isEqual:@"counter"] && e.observedObject == subject && [e.expectedValue isEqual:@7]
                              && (e.options & NSKeyValueObservingOptionInitial) != 0, NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        subject.counter = 7;
    });
    XCTWaiterResult r = [XCTWaiter waitForExpectations:@[ e ] timeout:2.0];
    ok("kvo: fulfilled on matching change", r == XCTWaiterResultCompleted, NULL);

    // A change to a different value must keep waiting.
    XCTKVOExpectation *e2 = [[XCTKVOExpectation alloc] initWithKeyPath:@"counter" object:subject expectedValue:@11];
    subject.counter = 1;
    r = [XCTWaiter waitForExpectations:@[ e2 ] timeout:0.3];
    ok("kvo: ignores other values", r == XCTWaiterResultTimedOut, NULL);

    // Any change at all, with no expected value. The mutation is what has to
    // satisfy this one, so the counter is given a value the "any" path has
    // never seen: an Initial callback carrying the existing value would also
    // fulfill, and the check below cannot tell the two apart unless the value
    // is not already the new one. (It is written as a fresh subject so an
    // earlier expectation's registration cannot be what delivers it.)
    Subject *anysubject = [Subject new];
    XCTKVOExpectation *any = [[XCTKVOExpectation alloc] initWithKeyPath:@"counter" object:anysubject];
    // No mutation yet, and there is nothing to wait for, so this must time out.
    r = [XCTWaiter waitForExpectations:@[ any ] timeout:0.3];
    ok("kvo: any change does not fire on init", r == XCTWaiterResultTimedOut, NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        anysubject.counter = 2;
    });
    r = [XCTWaiter waitForExpectations:@[ any ] timeout:2.0];
    ok("kvo: fulfilled by any change", r == XCTWaiterResultCompleted, NULL);

    // A handler inspects the change dictionary and can veto.
    __block int calls = 0;
    XCTKVOExpectation *handled = [[XCTKVOExpectation alloc] initWithKeyPath:@"counter" object:subject];
    handled.handler = ^BOOL(id observed, NSDictionary *change) {
        calls++;
        return [change[NSKeyValueChangeNewKey] intValue] == 5;
    };
    subject.counter = 3;
    subject.counter = 5;
    r = [XCTWaiter waitForExpectations:@[ handled ] timeout:2.0];
    ok("kvo: handler sees new value", r == XCTWaiterResultCompleted && calls == 2, NULL);

    // The Initial option means a value already present satisfies the wait with
    // no mutation at all.
    subject.counter = 42;
    XCTKVOExpectation *initial = [[XCTKVOExpectation alloc] initWithKeyPath:@"counter" object:subject expectedValue:@42];
    r = [XCTWaiter waitForExpectations:@[ initial ] timeout:1.0];
    ok("kvo: initial option sees current value", r == XCTWaiterResultCompleted, NULL);

    // Releasing without a change must deregister, or the next change would raise
    // for an observer that no longer exists.
    @autoreleasepool {
        XCTKVOExpectation *doomed = [[XCTKVOExpectation alloc] initWithKeyPath:@"counter" object:subject];
        (void)doomed;
    }
    subject.counter = 100;
    ok("kvo: dealloc deregisters", YES, NULL);
}

static void checkDarwin(void)
{
    const char *name = "com.libre.xct.harness.darwin";

    XCTDarwinNotificationExpectation *e = [[XCTDarwinNotificationExpectation alloc] initWithNotificationName:
                                              [NSString stringWithUTF8String:name]];
    ok("darwin: properties", [e.notificationName isEqualToString:[NSString stringWithUTF8String:name]], NULL);
    for (int i = 0; i < 20; i++) {
        notify_post(name);
        usleep(50000);
        if (e.xct_fulfillmentCount > 0) {
            break;
        }
    }
    XCTWaiterResult r = [XCTWaiter waitForExpectations:@[ e ] timeout:2.0];
    ok("darwin: fulfilled by post", r == XCTWaiterResultCompleted, NULL);

    // A handler can veto the first post and accept the second.
    const char *name2 = "com.libre.xct.harness.darwin2";
    __block int calls = 0;
    XCTDarwinNotificationExpectation *e2 = [[XCTDarwinNotificationExpectation alloc] initWithNotificationName:
                                               [NSString stringWithUTF8String:name2]];
    e2.handler = ^BOOL {
        return ++calls >= 2;
    };
    for (int i = 0; i < 40 && e2.xct_fulfillmentCount == 0; i++) {
        notify_post(name2);
        usleep(50000);
    }
    r = [XCTWaiter waitForExpectations:@[ e2 ] timeout:2.0];
    ok("darwin: handler veto then accept", r == XCTWaiterResultCompleted && calls >= 2, NULL);

    // A name that is never posted must time out.
    XCTDarwinNotificationExpectation *never = [[XCTDarwinNotificationExpectation alloc] initWithNotificationName:
                                                  @"com.libre.xct.harness.never"];
    r = [XCTWaiter waitForExpectations:@[ never ] timeout:0.3];
    ok("darwin: times out when never posted", r == XCTWaiterResultTimedOut, NULL);

    // Releasing must cancel the registration.
    const char *name3 = "com.libre.xct.harness.darwin3";
    @autoreleasepool {
        XCTDarwinNotificationExpectation *doomed = [[XCTDarwinNotificationExpectation alloc] initWithNotificationName:
                                                      [NSString stringWithUTF8String:name3]];
        (void)doomed;
    }
    notify_post(name3);
    usleep(100000);
    ok("darwin: dealloc cancels", YES, NULL);
}

#pragma mark - Entry

int main(void)
{
    puts("XCTNSNotificationExpectation:");
    checkNotification();
    puts("XCTNSPredicateExpectation:");
    checkPredicate();
    puts("XCTKVOExpectation:");
    checkKVO();
    puts("XCTDarwinNotificationExpectation:");
    checkDarwin();
    printf("\n%s (%d failure%s)\n", failures == 0 ? "ALL PASS" : "FAILURES", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
