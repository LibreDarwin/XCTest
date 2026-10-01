// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Private plumbing shared between the XCTest implementation files. Not
// installed into the framework and not part of the public contract.

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"

// arc4random(): the default source for the shuffle. It is in libSystem, but its
// declaration rides along in <stdlib.h>, which the reduced SDK keeps out of the
// Foundation umbrella.
#include <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

NSExceptionName const _XCTInternalUnwindExceptionName =
    @"XCTestInternalUnwindException";

/// The test case currently running on this thread.
///
/// Thread-local rather than global or a property on the suite. A test's helper
/// methods, expectation callbacks and teardown blocks all need to know which
/// test they belong to, and none of them have the case in hand; passing it
/// through every signature would be a large, permanent tax on the public API.
/// A global would be wrong in the other direction, because parallel test
/// execution would cross-contaminate.
static __thread __unsafe_unretained XCTestCase *_XCTCurrentTestCaseStorage = nil;

XCT_EXPORT void _XCTSetCurrentTestCase(XCTestCase *_Nullable testCase)
{
    _XCTCurrentTestCaseStorage = testCase;
}

XCT_EXPORT XCTestCase *_Nullable _XCTCurrentTestCase(void)
{
    return _XCTCurrentTestCaseStorage;
}

XCT_EXPORT XCTSourceCodeContext *_XCTSourceCodeContextAtLocation(const char *filePath,
                                                                 NSUInteger lineNumber)
{
    return [XCTSourceCodeContext xct_contextWithFilePath:[NSString stringWithUTF8String:filePath ?: "?"]
                                               lineNumber:lineNumber];
}

XCT_EXPORT void _XCTRecordIssueOnTestCase(XCTestCase *_Nullable testCase,
                                          XCTIssue *issue)
{
    if (testCase == nil) {
        return;
    }
    [testCase recordIssue:issue];
}

#pragma mark - Class name helpers

/// Strips the module from a Swift class name: `MyTests.MyTestsCase` becomes
/// `MyTestsCase`, and a name with no dot is returned unchanged. Only the first
/// component goes, because only the first is the module: a type nested in
/// another type still needs its outer type spelled to be found.
NSString *_XCTClassNameWithoutModuleFromClassName(NSString *className)
{
    NSRange moduleSeparator = [className rangeOfString:@"."];
    if (moduleSeparator.location == NSNotFound) {
        return className;
    }
    NSUInteger startOfName = moduleSeparator.location + 1;
    if (className.length <= startOfName) {
        // A trailing dot names nothing, so there is no name to return.
        return className;
    }
    return [className substringFromIndex:startOfName];
}

NSString *_XCTClassNameWithoutModuleFromClass(Class cls)
{
    return _XCTClassNameWithoutModuleFromClassName(NSStringFromClass(cls));
}

#pragma mark - Mutable array ordering primitives

// The shuffle and the partition are one algorithm each, kept here rather than in
// XCTestSuite so the suite reads as ordering policy and not as index arithmetic.
// Both are in-place and both are deliberately O(n) swaps over the array, never a
// rebuild: a suite's tests are addressed by position while it is being ordered,
// so replacing the array under a concurrent reader would be the one way to make
// this racy.
@implementation NSMutableArray (XCTestAdditions)

- (void)xct_shuffle
{
    // One generator for the whole run is what makes a seeded order reproducible.
    // The default draws from the system randomness, so two unseeded runs differ;
    // -[XCTestSuite _applyRandomExecutionOrderingWithGenerator:] is how a seed
    // reaches this and replaces the default.
    [self xct_shuffleWithRandomNumberGenerator:^NSUInteger {
        return (NSUInteger)arc4random();
    }];
}

- (void)xct_shuffleWithRandomNumberGenerator:(XCTRandomNumberGenerator)generator
{
    NSUInteger count = self.count;
    for (NSUInteger i = 0; i < count; i++) {
        // A Fisher-Yates walk from the front: the remaining window is [i, count),
        // and i is only ever swapped with a position at or after itself, so each
        // element is drawn exactly once and the result is uniform. The final
        // iteration draws from a one-element window and is a no-op, which keeps
        // the loop a plain for rather than a special case at the end.
        NSUInteger offset = generator() % (count - i);
        NSUInteger j = i + offset;
        [self exchangeObjectAtIndex:i withObjectAtIndex:j];
    }
}

- (void)xct_removeObjectsPassingTest:(BOOL (^)(id object))test
{
    // The partition gathers the passing elements into the tail [boundary, count),
    // so dropping that run in one call removes exactly the matching elements. An
    // all-failing array returns count, making the range empty, and the guard
    // covers that along with the all-passing boundary of zero.
    NSUInteger boundary = [self xct_halfStablePartitionUsingBlock:test];
    NSUInteger count = self.count;
    if (boundary < count) {
        [self removeObjectsInRange:NSMakeRange(boundary, count - boundary)];
    }
}

- (NSUInteger)xct_halfStablePartitionUsingBlock:(BOOL (^)(id object))block
{
    // The mirror of std::stable_partition: elements that fail the block are
    // gathered at the front, stably, and the return value is how many of them
    // there are. It is "half" stable because only the failing run keeps its
    // order -- the passers are moved as a whole and may be reordered. The first
    // passer is located in one search; everything before it already fails and so
    // does not move. NSNotFound is the whole "nothing passes" signal, so there is
    // no separate count comparison to get wrong. The wrapper adapts the
    // two-argument predicate -indexOfObjectPassingTest: wants to the
    // single-object one the caller supplied; the index and stop out-parameters
    // are not used.
    NSUInteger boundary = [self indexOfObjectPassingTest:^BOOL(id object, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return block(object);
    }];
    if (boundary == NSNotFound) {
        return self.count;
    }
    // From the first passer on, a later non-passer is swapped into the boundary
    // and the boundary advances, which pushes a passer one step toward the tail.
    // The failing elements thus keep their relative order; the passers do not.
    NSUInteger count = self.count;
    for (NSUInteger j = boundary + 1; j < count; j++) {
        if (!block(self[j])) {
            [self exchangeObjectAtIndex:boundary withObjectAtIndex:j];
            boundary++;
        }
    }
    return boundary;
}

@end

NS_ASSUME_NONNULL_END
