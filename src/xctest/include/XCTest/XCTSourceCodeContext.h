// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Source location attached to a recorded issue.

#ifndef XCTEST_XCTSOURCECODECONTEXT_H
#define XCTEST_XCTSOURCECODECONTEXT_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTSourceCodeContext : NSObject <NSCopying, NSSecureCoding>

/// A fully resolved source location, as produced by the backtrace machinery.
- (instancetype)initWithLocation:(NSUInteger)location NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (readonly) NSUInteger location;

/// The file containing the failing line, or nil for a context synthesized
/// without a backtrace.
@property (nullable, readonly, copy) NSString *filePath;

/// 1-based line number, or 0 when unknown.
@property (readonly) NSUInteger lineNumber;

/// 1-based column number, or 0 when unknown.
@property (readonly) NSUInteger columnNumber;

/// The symbol containing the address, or nil.
@property (nullable, readonly, copy) NSString *symbolInfo;

/// The stack captured at the point the context was created, innermost first.
@property (readonly, copy) NSArray<NSNumber *> *callStack;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTSOURCECODECONTEXT_H */
