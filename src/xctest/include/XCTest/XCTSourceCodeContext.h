// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A place in source code, a symbol in a binary, and a stack of both.
//
// This is a redesign, not an extension. The first version modelled a failure as
// one resolved address: `initWithLocation:` took a stack address, dladdr turned
// it into a file and a symbol, and a context was that address plus whatever
// strings came out. It read well for a failure found by walking a backtrace and
// badly for an assertion, where __FILE__ and __LINE__ are already known and the
// address could not be resolved back to a line anyway -- the runtime carries no
// line table, so every address was reported as "line unknown" while the real
// line number sat in the caller's __LINE__.
//
// Apple's shape separates the three things that were being conflated: a
// location is a file and a line, a symbol is a name in an image with an
// optional location, and a frame is an address that can be asked for its symbol.
// A context is a stack of frames plus an optional location that may or may not
// be one of them.
//
// Two consequences are deliberate. `filePath` and `lineNumber` are gone from
// XCTSourceCodeContext, because a context no longer has a single "the" file --
// callers that want the file of the failing line read
// `sourceCodeContext.location.fileURL`, and callers that want the binary read
// `callStack[0].symbolInfo.imageName`. And `symbolInfo` becomes a
// `XCTSourceCodeSymbolInfo` rather than an NSString, so an image name travels
// with the symbol name instead of being dropped.

#ifndef XCTEST_XCTSOURCECODECONTEXT_H
#define XCTEST_XCTSOURCECODECONTEXT_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

/// A file and a line, the smallest thing that identifies a place in source.
__attribute__((objc_subclassing_restricted))
@interface XCTSourceCodeLocation : NSObject <NSSecureCoding>

/// A location, from a file URL and a 1-based line number.
- (instancetype)initWithFileURL:(NSURL *)fileURL
                     lineNumber:(NSInteger)lineNumber NS_DESIGNATED_INITIALIZER;

/// A location, from a path. Used by the assertion path, where __FILE__ is a
/// path and there is no URL to be had.
- (instancetype)initWithFilePath:(NSString *)filePath lineNumber:(NSInteger)lineNumber;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (readonly) NSURL *fileURL;
@property (readonly) NSInteger lineNumber;

@end

/// A named symbol in a named image, and where in its source that symbol was.
__attribute__((objc_subclassing_restricted))
@interface XCTSourceCodeSymbolInfo : NSObject <NSSecureCoding>

- (instancetype)initWithImageName:(NSString *)imageName
                       symbolName:(NSString *)symbolName
                         location:(nullable XCTSourceCodeLocation *)location NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (readonly, copy) NSString *imageName;
@property (readonly, copy) NSString *symbolName;
@property (readonly, nullable) XCTSourceCodeLocation *location;

@end

/// One return address in a call stack, and the symbol it names.
__attribute__((objc_subclassing_restricted))
@interface XCTSourceCodeFrame : NSObject <NSSecureCoding>

- (instancetype)initWithAddress:(uint64_t)address
                    symbolInfo:(nullable XCTSourceCodeSymbolInfo *)symbolInfo NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithAddress:(uint64_t)address;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (readonly) uint64_t address;

/// The symbol at `address`, if it was resolved when the frame was built.
@property (readonly, nullable) XCTSourceCodeSymbolInfo *symbolInfo;

/// Why the last symbolication attempt failed, if it did. Not encoded, since an
/// error is a property of this process's attempt and not of the frame.
@property (readonly, nullable) NSError *symbolicationError;

/// Resolves `address` through dladdr, once. A second call returns the first
/// result rather than asking again, because symbolication is not free and the
/// answer for a loaded image does not change under a caller.
- (nullable XCTSourceCodeSymbolInfo *)symbolInfoWithError:(NSError **)outError;

@end

/// A call stack, and optionally the place the code was when it was captured.
/// The location is not required to be any of the frames: an assertion's
/// __LINE__ is the line being executed, which is the frame below the assertion
/// helper, not the assertion helper itself.
__attribute__((objc_subclassing_restricted))
@interface XCTSourceCodeContext : NSObject <NSSecureCoding>

- (instancetype)initWithCallStack:(NSArray<XCTSourceCodeFrame *> *)callStack
                         location:(nullable XCTSourceCodeLocation *)location NS_DESIGNATED_INITIALIZER;

/// From raw return addresses, as NSThread.callStackReturnAddresses gives them.
- (instancetype)initWithCallStackAddresses:(NSArray<NSNumber *> *)callStackAddresses
                                  location:(nullable XCTSourceCodeLocation *)location;

/// The current thread's call stack, and `location`.
- (instancetype)initWithLocation:(nullable XCTSourceCodeLocation *)location;

/// The current thread's call stack, and no location.
- (instancetype)init;

@property (readonly, copy) NSArray<XCTSourceCodeFrame *> *callStack;
@property (readonly, nullable) XCTSourceCodeLocation *location;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTSOURCECODECONTEXT_H */
