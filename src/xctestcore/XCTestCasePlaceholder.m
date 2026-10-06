// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestCasePlaceholder and its run.
//
// A selection names tests by identifier, and a class cannot always supply the
// test an identifier names. Rather than drop it, the runner adds one of these:
// a test that knows its identifier and the reason it could not be built,
// counts as one test, and records itself as skipped when performed. The report
// then shows every test the selection asked for instead of quietly showing
// fewer.
//
// Both classes live in one file because they are one idea: the placeholder and
// the run that proves a placeholder was run. The reference spreads them across
// XCTest.m, XCTestRun.m and XCTestCasePlaceholderRun.m; keeping them together
// here makes the pair readable without cross-referencing three files, and the
// split would buy nothing while they stay this small.

#import <XCTestCore/XCTTestSelection.h>

#import "XCTestInternal.h"

/// Raises one of the reference's parameter assertions.
///
/// NSAssert cannot be used for the reason XCTestConfigurationLoader.m gives:
/// the reduced <Foundation/NSException.h> omits NSAssertionHandler, which
/// NSAssert raises through. What is raised is what the handler would have
/// raised: the same exception name and the same text.
static void _XCTRaiseAssertionFailure(NSString *description)
{
    [[NSException exceptionWithName:NSInternalInconsistencyException
                              reason:description
                            userInfo:nil] raise];
}

@implementation XCTestCasePlaceholder {
    XCTTestIdentifier *_identifier;
}

- (instancetype)initWithIdentifier:(XCTTestIdentifier *)identifier
                            reason:(NSString *)reason
{
    self = [super init];
    if (self != nil) {
        _identifier = identifier;
        _reason = [reason copy];
    }
    return self;
}

/// One, not zero: the placeholder stands for exactly the test its identifier
/// names, and a run over a suite has to count it or the totals will be short by
/// every test that failed to construct.
- (NSUInteger)testCaseCount
{
    return 1;
}

/// The reference spells this "Unavailable test: <identifier>", which is what a
/// report prints where it would otherwise print a method name. -name is asked
/// of every test, so a test that exists only as a name still needs a name.
- (NSString *)name
{
    return [NSString stringWithFormat:@"Unavailable test: %@",
                                      [self _xctTestIdentifier].displayName];
}

/// The same subject under the spelling the Objective-C runner writes, without
/// the "Unavailable test: " prefix: the prefix marks an unavailable test, and
/// the legacy parser is being told which test it is rather than that it is
/// unavailable. An identifier that is already read as Objective-C answers for
/// itself; a Swift one gives its Objective-C counterpart, which drops the module
/// prefix an Objective-C runner does not use.
- (NSString *)nameForLegacyLogging
{
    XCTTestIdentifier *identifier = [self _xctTestIdentifier];
    XCTTestIdentifier *spelling = [identifier objcMethodCounterpart] ?: identifier;
    return [spelling displayName];
}

- (Class)testRunClass
{
    return [XCTestCasePlaceholderRun class];
}

/// Performed, a placeholder records itself as skipped and stops: there is no
/// invocation to run, and the reason is the test's own. The run is the one the
/// caller passed, as every -performTest: takes -- the reference reads -testRun
/// instead, which this port's suites do not set on a child, so the run has to
/// come from the argument for a suite's children to be the runs the suite made.
- (void)performTest:(XCTestRun *)run
{
    XCTestRun *placeholderRun = run ?: [XCTestCasePlaceholderRun testRunWithTest:self];
    self.testRun = placeholderRun;
    [placeholderRun start];
    [placeholderRun recordSkipWithDescription:self.reason
                           sourceCodeContext:[[XCTSourceCodeContext alloc]
                                                initWithCallStack:@[]
                                                         location:nil]];
    [placeholderRun stop];
}

/// Equal when the identifiers are, which is what makes two placeholders for the
/// same test interchangeable -- a selection that names a test twice, or that
/// rebuilds the placeholder in a second pass, does not end up with two rows.
/// Anything that is not a placeholder is never equal to one, so a placeholder
/// never stands in for the real test of the same name.
///
/// -hash is deliberately not overridden to match. The reference does not
/// override it either, and overriding it would promise more than -isEqual:
/// delivers: the identifier's hash is not the placeholder's identity.
- (BOOL)isEqual:(id)object
{
    if (![object isKindOfClass:[XCTestCasePlaceholder class]]) {
        return NO;
    }
    return [[self _xctTestIdentifier] isEqual:[object _xctTestIdentifier]];
}

/// Placeholders sort before everything else, and among themselves by method
/// name. A run over a selection that produced placeholders wants them together
/// at the front rather than interleaved with the tests that could run, because
/// they are not tests that ran -- and ordering by method name keeps the group
/// in an order a reader can follow.
- (NSComparisonResult)defaultExecutionOrderCompare:(XCTest *)other
{
    if (![other isKindOfClass:[XCTestCasePlaceholder class]]) {
        return NSOrderedAscending;
    }
    return [[self _xctTestIdentifier].lastComponentDisplayName
        compare:[other _xctTestIdentifier].lastComponentDisplayName];
}

- (XCTTestIdentifier *)_xctTestIdentifier
{
    return _identifier;
}

@end

@implementation XCTestCasePlaceholderRun

- (instancetype)initWithTest:(XCTest *)test
{
    if (![test isKindOfClass:[XCTestCasePlaceholder class]]) {
        // What NSParameterAssert spells as its condition. The handler raises;
        // reaching -initWithTest: with anything else would make this run report
        // counts and skips against a test that is not the one it claims.
        _XCTRaiseAssertionFailure(@"Invalid parameter not satisfying: "
                           @"[test isKindOfClass:[XCTestCasePlaceholder class]]");
    }
    self = [super initWithTest:test];
    if (self != nil) {
        // The reference's -[XCTestRun testCaseCount] forwards to the test and
        // so answers one on its own; this port keeps the count in an ivar that
        // -initWithTest: does not fill, so it is entered here.
        self.testCaseCount = 1;
    }
    return self;
}

- (XCTestCasePlaceholder *)placeholder
{
    return (XCTestCasePlaceholder *)self.test;
}

@end
