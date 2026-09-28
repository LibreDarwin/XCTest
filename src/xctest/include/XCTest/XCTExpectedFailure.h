// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Declaring a failure the test is known to produce, and the objects describing
// how that declaration matches and reports.

#ifndef XCTEST_XCTEXPECTEDFAILURE_H
#define XCTEST_XCTEXPECTEDFAILURE_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTIssue.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTExpectedFailureOptions;

/*!
 * @function XCTExpectFailure()
 * Declares that the test is expected to fail at some point after this call, which
 * both documents a known issue and keeps it from turning the suite red.
 *
 * Has stack semantics and may be called repeatedly. A failure is associated with
 * the closest matching declaration, and a declaration is consumed by the first
 * issue that matches it, so two declarations in a row need two failures to
 * clear them. Anything still unmatched when the test finishes is itself
 * recorded, as XCTIssueTypeUnmatchedExpectedFailure -- a declaration that
 * quietly matches nothing would otherwise hide the case where the bug it
 * documents has been fixed.
 *
 * Matches any issue by default, including ones of warning severity.
 *
 * Threading: on the test's primary thread this matches an issue recorded on any
 * thread. Called from any other thread it matches only issues recorded on that
 * same thread, so a background declaration cannot absorb a failure belonging to
 * a different piece of work.
 *
 * @param failureReason Explanation of the issue being suppressed. A reporting UI
 * may extract a URL from it and present it as a link, so a bug-tracker URL is
 * worth including. May be nil.
 */
XCT_EXPORT void XCTExpectFailure(NSString *_Nullable failureReason)
    NS_SWIFT_UNAVAILABLE("Use XCTExpectFailure(_:options:) instead");

/*!
 * @function XCTExpectFailureWithOptions()
 * As XCTExpectFailure, but with rules for how issues are matched and what
 * happens to a declaration nothing matches.
 *
 * @param options Rules for matching and strictness. Copied, so the caller may
 * reuse or mutate its instance afterwards.
 */
XCT_EXPORT void XCTExpectFailureWithOptions(NSString *_Nullable failureReason,
                                            XCTExpectedFailureOptions *options)
    NS_REFINED_FOR_SWIFT;

/*!
 * @function XCTExpectFailureInBlock()
 * As XCTExpectFailure, but limited to the issues recorded by the given block.
 *
 * The block runs normally whether or not a declaration is active, so this
 * cannot be used to skip work.
 *
 * @param failingBlock The scope in which the failure is expected. Only failures
 * on the calling thread and within this block are matched; failures raised in a
 * dispatch callout or on another thread are recorded normally.
 */
XCT_EXPORT void XCTExpectFailureInBlock(
    NSString *_Nullable failureReason,
    XCT_NOESCAPE void (^failingBlock)(void))
    NS_SWIFT_UNAVAILABLE("Use XCTExpectFailure(_:options:failingBlock:) instead");

/*!
 * @function XCTExpectFailureWithOptionsInBlock()
 * As XCTExpectFailureInBlock, with matching rules.
 */
XCT_EXPORT void XCTExpectFailureWithOptionsInBlock(
    NSString *_Nullable failureReason,
    XCTExpectedFailureOptions *options,
    XCT_NOESCAPE void (^failingBlock)(void))
    NS_REFINED_FOR_SWIFT;

/// The rules for matching a recorded issue to a declaration, and for reporting a
/// declaration that nothing matched.
@interface XCTExpectedFailureOptions : NSObject <NSCopying, NSSecureCoding>

/*!
 * @property issueMatcher
 * Filters whether a recorded issue is absorbed by the declaration. An issue the
 * filter rejects is recorded normally, as a real failure.
 *
 * Nil by default, meaning every issue matches, including warnings. Use it to
 * declare one specific known problem rather than "whatever this test does".
 */
@property (copy, nullable) BOOL (^issueMatcher)(XCTIssue *issue);

/*!
 * @property enabled
 * Whether the declaration is active. For a known issue that only appears under
 * some conditions, set this to NO to declare it without absorbing anything; in
 * the block-based forms the block still runs normally. Defaults to YES.
 */
@property (getter=isEnabled) BOOL enabled;

/*!
 * @property strict
 * Whether a declaration that matched no issue is itself recorded as
 * XCTIssueTypeUnmatchedExpectedFailure. Defaults to YES, which is what makes a
 * fixed bug show up as a failing test.
 */
@property (getter=isStrict) BOOL strict;

/// Options identical to the defaults except that a declaration matching nothing
/// is not reported, for known issues that only fail in some environments.
+ (XCTExpectedFailureOptions *)nonStrictOptions;

@end

/// One declaration that was matched by one issue, as handed to observers.
@interface XCTExpectedFailure : NSObject <NSSecureCoding>

- (instancetype)init
    XCT_UNAVAILABLE("Instances of XCTExpectedFailure are provided by the framework.");
+ (instancetype)new
    XCT_UNAVAILABLE("Instances of XCTExpectedFailure are provided by the framework.");

/*!
 * @property failureReason
 * The explanation passed to the declaration that this issue matched, or nil if
 * none was given.
 */
@property (readonly, nullable, copy) NSString *failureReason;

/// The issue that was absorbed.
@property (readonly, copy) XCTIssue *issue;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTEXPECTEDFAILURE_H */
