// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for class discovery: which classes in a process the runner
// is willing to treat as test cases.
//
// This is the one XCTestCore unit whose answer depends on the whole process
// rather than on its arguments, so a harness is the only way to see it work: a
// test bundle has already registered its classes by the time discovery runs,
// and nothing inside the framework can supply that. The fixtures below give
// discovery something to find, and -- more to the point -- something to reject.
//
// The rejections and acceptances that are invisible from the framework are the
// reason for the file:
//
//   - XCTestCase is never its own subclass. An implementation that matched on
//     "responds to +testInvocations" would hand the runner the base class as a
//     test suite.
//   - A `NSKVONotifying_` class is the runtime's per-object KVO shim. It is a
//     real subclass, and it would run once per observed object.
//   - A `_TtGC...` name is a Swift generic class *only if it is Swift*. An
//     Objective-C class is free to use the same prefix, so the check has to ask
//     libobjc rather than read the name. `_TtGCXCTObjCFixture` is that trap, and
//     it is deliberately discoverable.
//   - A leading underscore is *not* a rejection. The reference filters KVO and
//     Swift generics by name, not by privacy convention, so a plain `_Foo` is a
//     test class. `_XCTUnderscoreFixture` pins that.
//
// The rest of the checks cover the *outside XCTest* filter, which is the name
// XCTest uses for "not one of the framework's own test-case subclasses": it is
// a bundle-path comparison against the image XCTestCase lives in. This build
// has no such subclass, so the positive assertion is that a class from this
// harness survives the filter, and that nothing in the result carries XCTest's
// own bundle path.
#import <XCTest/XCTest.h>

#import "XCTestInternal.h"

#import <stdio.h>

static int failures = 0;

static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-58s %s%s%s\n", name, passed ? "PASS" : "FAIL",
           (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Fixtures

// The plain pair exists only to give the sort a defined order: Alpha sorts
// before Zulu, so a check that compared the returned order against the
// runtime's would fail on most machines.
@interface XCTAlphaFixture : XCTestCase
@end
@implementation XCTAlphaFixture
@end

@interface XCTZuluFixture : XCTestCase
@end
@implementation XCTZuluFixture
@end

// Not rejected: the reference has no underscore rule, and this pins that.
@interface _XCTUnderscoreFixture : XCTestCase
@end
@implementation _XCTUnderscoreFixture
@end

// Rejected: the runtime's key-value-observing subclass naming.
@interface NSKVONotifying_XCTFixture : XCTestCase
@end
@implementation NSKVONotifying_XCTFixture
@end

// Not rejected: `_TtGC` *and* not Swift.
@interface _TtGCXCTObjCFixture : XCTestCase
@end
@implementation _TtGCXCTObjCFixture
@end

static NSUInteger indexOfClass(NSArray *classes, Class cls)
{
    for (NSUInteger i = 0; i < classes.count; i++) {
        if ((Class)classes[i] == cls) {
            return i;
        }
    }
    return NSNotFound;
}

int main(void)
{
    printf("XCTestCase class discovery\n");

    NSArray *all = [XCTestCase allSubclasses];

    ok("allSubclasses is an array", [all isKindOfClass:[NSArray class]], nil);

    // Membership: four discoverable fixtures.
    ok("finds a plain ObjC subclass",
       indexOfClass(all, [XCTAlphaFixture class]) != NSNotFound, @"XCTAlphaFixture");
    ok("finds a second plain ObjC subclass",
       indexOfClass(all, [XCTZuluFixture class]) != NSNotFound, @"XCTZuluFixture");
    ok("an underscore-prefixed ObjC class is discoverable",
       indexOfClass(all, [_XCTUnderscoreFixture class]) != NSNotFound, @"_XCTUnderscoreFixture");
    ok("a `_TtGC` name on an ObjC class is discoverable",
       indexOfClass(all, [_TtGCXCTObjCFixture class]) != NSNotFound, @"_TtGCXCTObjCFixture");

    // Rejections.
    ok("XCTestCase is not its own subclass",
       indexOfClass(all, [XCTestCase class]) == NSNotFound, nil);
    ok("a NSKVONotifying_ subclass is rejected",
       indexOfClass(all, [NSKVONotifying_XCTFixture class]) == NSNotFound, @"NSKVONotifying_XCTFixture");

    // Ordering.
    NSUInteger alpha = indexOfClass(all, [XCTAlphaFixture class]);
    NSUInteger zulu = indexOfClass(all, [XCTZuluFixture class]);
    ok("subclasses are ordered by class name",
       alpha != NSNotFound && zulu != NSNotFound && alpha < zulu,
       [NSString stringWithFormat:@"alpha=%lu zulu=%lu",
                                  (unsigned long)alpha, (unsigned long)zulu]);

    // No duplicates: a retry loop that appended without reusing a set would
    // show up here.
    NSUInteger distinct = [[NSSet setWithArray:all] count];
    ok("no duplicate classes", all.count == distinct,
       [NSString stringWithFormat:@"%lu entries, %lu distinct",
                                  (unsigned long)all.count, (unsigned long)distinct]);

    // Everything returned really is a subclass answering the same predicate the
    // filter consulted.
    BOOL everyElementIsDiscoverable = YES;
    BOOL everyElementIsASubclass = YES;
    for (id element in all) {
        Class cls = (Class)element;
        if (![cls _isDiscoverable]) {
            everyElementIsDiscoverable = NO;
        }
        if (![cls isSubclassOfClass:[XCTestCase class]]) {
            everyElementIsASubclass = NO;
        }
    }
    ok("every result is a discoverable XCTestCase subclass",
       everyElementIsDiscoverable && everyElementIsASubclass, nil);

    // Reproducibility: a second call must agree, or the run order is not
    // reproducible across passes.
    ok("discovery is stable across calls",
       [[XCTestCase allSubclasses] isEqualToArray:all], nil);

    // _isDiscoverable directly, including the shape a Swift class cannot be
    // manufactured into from Objective-C.
    ok("_isDiscoverable(YES) for a plain subclass",
       [XCTAlphaFixture _isDiscoverable], @"XCTAlphaFixture");
    ok("_isDiscoverable(NO) for a KVO subclass",
       ![NSKVONotifying_XCTFixture _isDiscoverable], @"NSKVONotifying_XCTFixture");
    ok("_isDiscoverable(YES) for `_TtGC` on an ObjC class",
       [_TtGCXCTObjCFixture _isDiscoverable], @"_TtGCXCTObjCFixture");

    // The outside filter.
    NSSet *outside = [XCTestCase allSubclassesOutsideXCTest];
    ok("allSubclassesOutsideXCTest is a set",
       [outside isKindOfClass:[NSSet class]], nil);
    ok("the outside set is a subset of allSubclasses",
       [outside isSubsetOfSet:[NSSet setWithArray:all]], nil);
    ok("a harness class survives the outside filter",
       [outside containsObject:[XCTAlphaFixture class]], @"XCTAlphaFixture");
    ok("the KVO subclass is absent from the outside set",
       ![outside containsObject:[NSKVONotifying_XCTFixture class]], nil);

    NSString *xctestBundlePath = [[NSBundle bundleForClass:[XCTestCase class]] bundlePath];
    BOOL noFrameworkClass = YES;
    for (id element in outside) {
        Class cls = (Class)element;
        NSString *path = [[NSBundle bundleForClass:cls] bundlePath];
        if ([path isEqualToString:xctestBundlePath]) {
            noFrameworkClass = NO;
        }
    }
    ok("no outside class shares XCTestCase's bundle path",
       noFrameworkClass, xctestBundlePath);

    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
