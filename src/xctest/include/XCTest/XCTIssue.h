// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A single recorded test failure, unexpected error or warning.

#ifndef XCTEST_XCTISSUE_H
#define XCTEST_XCTISSUE_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTSourceCodeContext.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTAttachment;

/// The kind of problem an XCTIssue describes.
///
/// The numeric values 0 through 5 are the ones the rest of the toolchain reads
/// out of a result bundle, so they are fixed and must not be renumbered:
/// an out-of-process reporter that misreads one would mislabel every issue.
/// Cases 6 and up are additions specific to this implementation and are
/// therefore safe to extend, but never to renumber anything below them.
typedef NS_ENUM(NSInteger, XCTIssueType) {
    /// An assertion that did not hold, raised by an XCTAssert* macro.
    XCTIssueTypeAssertionFailure = 0,
    /// An error thrown by the test.
    XCTIssueTypeThrownError = 1,
    /// An exception that escaped the test.
    XCTIssueTypeUncaughtException = 2,
    /// A performance regression found by the -measure: family of APIs.
    XCTIssueTypePerformanceRegression = 3,
    /// A framework API failed internally, such as being unable to launch the
    /// application under test.
    XCTIssueTypeSystem = 4,
    /// An XCTExpectFailure was declared but no issue matched it. Recorded
    /// instead of the silence that would otherwise look like a passing test.
    XCTIssueTypeUnmatchedExpectedFailure = 5,

    /// A test skipped with XCTSkip. An extension: the toolchain has no
    /// corresponding value for a skip, so a skip has to be carried as an issue
    /// type of its own for its message and source location to survive.
    XCTIssueTypeSkippedTest = 6,
    /// A test that failed without going through an assertion macro, such as
    /// through the deprecated -recordFailureWithDescription: family. An
    /// extension, for the same reason as XCTIssueTypeSkippedTest.
    XCTIssueTypeTestFailure = 7,
} NS_SWIFT_NAME(XCTIssue.IssueType);

/// Whether an issue fails the run.
typedef NS_ENUM(NSInteger, XCTIssueSeverity) {
    XCTIssueSeverityWarning = 4,
    XCTIssueSeverityError = 8,
} NS_SWIFT_NAME(XCTIssue.Severity);

@interface XCTIssue : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>

- (instancetype)initWithType:(XCTIssueType)type
          compactDescription:(NSString *)compactDescription
         detailedDescription:(nullable NSString *)detailedDescription
           sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
             associatedError:(nullable NSError *)associatedError
                 attachments:(NSArray<XCTAttachment *> *)attachments NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithType:(XCTIssueType)type
          compactDescription:(NSString *)compactDescription
         detailedDescription:(nullable NSString *)detailedDescription
           sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
             associatedError:(nullable NSError *)associatedError
                 attachments:(NSArray<XCTAttachment *> *)attachments
                    severity:(XCTIssueSeverity)severity NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithType:(XCTIssueType)type
          compactDescription:(NSString *)compactDescription
                    severity:(XCTIssueSeverity)severity;

- (instancetype)initWithType:(XCTIssueType)type
         compactDescription:(NSString *)compactDescription;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (readonly) XCTIssueType type;
@property (readonly, copy) NSString *compactDescription;
@property (readonly, copy, nullable) NSString *detailedDescription;
@property (readonly, strong) XCTSourceCodeContext *sourceCodeContext;
@property (readonly, strong, nullable) NSError *associatedError;
@property (readonly, copy) NSArray<XCTAttachment *> *attachments;
@property (readonly) XCTIssueSeverity severity;

/// YES for any issue whose severity is XCTIssueSeverityError.
@property (readonly) BOOL isFailure;

@end

/// Mutable variant, for reporting chains that need to amend an issue in flight.
@interface XCTMutableIssue : XCTIssue
@property (readwrite) XCTIssueType type;
@property (readwrite, copy) NSString *compactDescription;
@property (readwrite, copy, nullable) NSString *detailedDescription;
@property (readwrite, strong) XCTSourceCodeContext *sourceCodeContext;
@property (readwrite, strong, nullable) NSError *associatedError;
@property (readwrite, copy) NSArray<XCTAttachment *> *attachments;
@property (readwrite) XCTIssueSeverity severity;
- (void)addAttachment:(XCTAttachment *)attachment;
@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTISSUE_H */
