// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A client of the four specialized expectations that sees only the installed
// framework. tools/expectations-test.m compiles with -Isrc/xctest, so it can
// reach private headers and would keep building even if a public header stopped
// declaring something its own API forces its users to name. This file cannot: it
// is compiled with no include path but the bundle's Headers, exactly as a caller
// would use it.
//
// That is the whole point. Two declarations went missing this way and neither
// build noticed. XCTKVOExpectation names NSKeyValueObservingOptions in its
// initializer, so the option constants are XCTest's surface whether or not the
// SDK's Foundation declares them, and the header published only the typedef. And
// XCTNSPredicateExpectation's only initializer takes an NSPredicate, which a
// reduced SDK does not declare at all, so the header's bare @class left the
// class uncallable from outside the framework.
//
// Compiled, not run: this is a reachability check. Behaviour is covered by
// tools/expectations-test.m, and every initializer here is called through the
// public headers only.

#import <XCTest/XCTest.h>

@interface Note : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) int count;
@end

@implementation Note
@end

/// Touches the parts of an expectation a caller reads back.
static void use(XCTestExpectation *expectation)
{
    (void)expectation.description;
    (void)expectation.isInverted;
    (void)expectation.expectedFulfillmentCount;
}

int main(void)
{
    // ---- XCTKVOExpectation -------------------------------------------------
    // The options type and the option constants, which are named by the API.
    NSKeyValueObservingOptions options =
        NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld;
    Note *subject = [Note new];
    XCTKVOExpectation *kvo =
        [[XCTKVOExpectation alloc] initWithKeyPath:@"text"
                                            object:subject
                                     expectedValue:@"ready"
                                          options:options];
    // Apple exposes the handler as a property, not an initializer argument.
    kvo.handler = ^BOOL(id observedObject, NSDictionary *change) {
        // The change-dictionary keys, also reachable only if published.
        id newValue = change[NSKeyValueChangeNewKey];
        id oldValue = change[NSKeyValueChangeOldKey];
        NSNumber *kind = change[NSKeyValueChangeKindKey];
        (void)observedObject;
        (void)oldValue;
        (void)kind;
        return newValue == nil || [newValue isEqual:@"ready"];
    };
    use(kvo);
    (void)kvo.keyPath;
    (void)kvo.observedObject;
    (void)kvo.expectedValue;
    (void)kvo.options;

    // The convenience initializers, whose option sets are part of the contract:
    // Initial when there is an expected value to check, none for "any change".
    use([[XCTKVOExpectation alloc] initWithKeyPath:@"count" object:[Note new]]);
    use([[XCTKVOExpectation alloc] initWithKeyPath:@"count"
                                            object:[Note new]
                                     expectedValue:@1]);

    // ---- XCTNSNotificationExpectation --------------------------------------
    NSNotificationCenter *center = [NSNotificationCenter new];
    XCTNSNotificationExpectation *note = [[XCTNSNotificationExpectation alloc]
        initWithName:@"NotePosted"
              object:subject
notificationCenter:center];
    note.handler = ^BOOL(NSNotification *n) { return n != nil; };
    use(note);
    (void)note.notificationName;
    (void)note.observedObject;
    (void)note.notificationCenter;

    use([[XCTNSNotificationExpectation alloc] initWithName:@"NotePosted"]);
    use([[XCTNSNotificationExpectation alloc] initWithName:@"NotePosted"
                                                    object:subject]);

    // ---- XCTNSPredicateExpectation -----------------------------------------
    // Building the argument at all is what the forward declaration forbade.
    XCTNSPredicateExpectation *predicate =
        [[XCTNSPredicateExpectation alloc] initWithPredicate:
            [NSPredicate predicateWithFormat:@"count > %d", 3]
                                                   object:subject];
    predicate.handler = ^BOOL { return NO; };
    use(predicate);
    (void)predicate.predicate;
    (void)predicate.object;

    // The other two construction entry points, so the published subset is
    // actually exercised rather than merely present. A nil object evaluates
    // against the expectation itself, which is how Apple intends a context-free
    // predicate to be used.
    use([[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id evaluated, NSDictionary *bindings) {
            (void)bindings;
            return [evaluated isKindOfClass:[Note class]];
        }]
                                               object:nil]);
    XCTNSPredicateExpectation *fromArray =
        [[XCTNSPredicateExpectation alloc] initWithPredicate:
            [NSPredicate predicateWithFormat:@"count > %@" argumentArray:@[@0]]
                                                   object:subject];
    use(fromArray);
    (void)[fromArray.predicate evaluateWithObject:subject];

    // ---- XCTDarwinNotificationExpectation ----------------------------------
    XCTDarwinNotificationExpectation *darwin =
        [[XCTDarwinNotificationExpectation alloc]
            initWithNotificationName:@"com.example.note"];
    // Apple takes no argument here: notify(3) reports only that the name was
    // posted, with no sender.
    darwin.handler = ^BOOL { return YES; };
    use(darwin);
    (void)darwin.notificationName;

    return 0;
}
