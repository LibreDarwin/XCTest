// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Foundation declarations XCTestCore needs but the Internal SDK's reduced
// headers omit.
//
// The reduced header set is a strict subset of upstream Foundation, so this file
// only ever adds back omissions -- it never contradicts a header that is
// present. The underlying runtime is a full Foundation, and a probe against this
// SDK's own Foundation confirms the members declared below all respond; they are
// simply not declared, and without a declaration the compiler rejects the call.
//
// Split from XCTestCore/XCTestConfiguration.h on purpose. That header is
// installed, and everything a public property names has to be declared there
// (NSUUID, above) so a client can actually use what it is handed. Nothing here
// appears in a signature: the path properties are how this implementation
// derives a value, and -containsValueForKey: is how this implementation asks
// what an archive contained. None of that is anybody else's business, so it
// stays here.
//
// Every *method* declaration below is a category. That is deliberate, and it is
// what makes this file safe under both SDKs: re-declaring a method a category
// already declares is legal, where re-declaring a class is a hard error.
//
// A constant is the one thing that cannot follow the rule, because a
// category has nowhere to put one, and this file now needs
// NSURLContentModificationDateKey. It is declared as an extern rather than
// spelled out as a literal: the runtime exports that symbol, so this resolves to
// the real constant instead of a second copy of its value that could drift.
//
// The one place that choice stopped being enough was assertions. The reduced
// <Foundation/NSException.h> omits NSAssertionHandler, and upstream declares that
// class inside NSException.h rather than in a header of its own, so no
// __has_include test can distinguish the two SDKs -- and the reduced SDK declares
// NSAssertionFailure without exporting the symbol, so NSAssert compiles and then
// fails to link. XCTestConfiguration.m therefore raises the exception itself
// instead, which needs no declaration: NSException, +exceptionWithName:reason:
// userInfo:, and NSInternalInconsistencyException are all in that same reduced
// header, and all three are what the assertion handler would have used.
//
// Scope discipline: this declares only what XCTestConfiguration.m and
// XCTestConfigurationLoader.m call. It is not an attempt to reconstruct
// Foundation.

#ifndef XCTESTCORE_XCTESTCOREFOUNDATIONCOMPAT_H
#define XCTESTCORE_XCTESTCOREFOUNDATIONCOMPAT_H

#import <Foundation/Foundation.h>
#import <Foundation/NSKeyedArchiver.h>

NS_ASSUME_NONNULL_BEGIN

// The one constant this file needs, and the reason it is here rather than in
// XCTestConfigurationLoader.m: it is part of what that file's public signature
// vocabulary is made of, and duplicating its value would be a second source of
// truth for a string the runtime already owns. Verified to link and to equal
// its own name.
FOUNDATION_EXPORT NSString * const NSURLContentModificationDateKey;

// Path decomposition. Upstream semantics throughout, including the
// empty-string result for a bare "/" or a path ending in a separator: stripping
// the last component of "/Users/x/" is the answer "" and not "/" again.
@interface NSString (XCTCoreSDKCompat)
@property (readonly, copy) NSString *lastPathComponent;
@property (readonly, copy) NSString *stringByDeletingLastPathComponent;
@end

// Deciding which file in a directory is the right one means comparing
// modification dates, and that means going through NSURL rather than a path: the
// URL is what -contentsOfDirectoryAtURL: hands back, and it is the only one of
// the two that reports a date without a second stat() that could disagree with
// the first.
//
// The reduced <Foundation/NSURL.h> stops at -isFileURL, so everything below is
// missing from it. lastPathComponent is here because a configuration carries its
// bundle as a URL, and the bundle's *name* is the URL's last path component --
// the difference between a run that can find its bundle and one that cannot.
//
// getResourceValue:forKey:error: takes and returns id, not a typed out-parameter,
// because that is the shape upstream uses: one method serves every resource key,
// and the caller is the only thing that knows what it asked for. The key is
// spelled NSString * rather than NSURLResourceKey because the reduced SDK has no
// such typedef; the underlying type is identical, so the call is the same call.
@interface NSURL (XCTCoreSDKCompat)
@property (readonly, copy) NSString *lastPathComponent;
/// The URL's last path component with its extension removed, or "" when there
/// is nothing left after the last dot. A bundle URL's extension decides whether
/// the file is a loadable bundle at all, so an empty answer is meaningful and not
/// an error.
@property (readonly, copy) NSString *pathExtension;
/// A new URL, not a mutation of the receiver.
- (NSURL *)URLByAppendingPathComponent:(NSString *)pathComponent;
- (BOOL)getResourceValue:(out id _Nullable * _Nonnull)value
                  forKey:(NSString *)key
                   error:(out NSError **)error;
@end

// Flattens the array's elements into one string. This is only here to render
// -description: as a single readable line: a target application's arguments are
// a list that has to appear as a list in the log, not as eleven separate
// placeholders. Upstream returns an empty string for an empty array and the
// separator for an empty element, which is why it is a separator and not a
// delimiter to skip.
//
// The reduced header set declares -firstObject on NSOrderedSet and nowhere
// else, which is a gap rather than a decision: upstream has it on NSArray, and
// the runtime answers it. Two things want it and neither can spell it as
// -objectAtIndex:0, because neither knows the count is non-zero -- an
// -anyTestIdentifier on an empty set, and an identifier's last component, which
// is nil precisely when the component list is empty.
//
// Both in one category because clang treats two categories of the same name on
// one class as a duplicate definition, not a merge.
@interface NSArray<ObjectType> (XCTCoreSDKCompat)
- (NSString *)componentsJoinedByString:(NSString *)separator;
- (nullable ObjectType)firstObject;
@end

// Archive introspection. A decoded configuration has to distinguish "this key
// was absent" from "this key was present and nil", because the reference
// writes some keys conditionally and reads the absence as the signal to fall
// back to a default. -decodeObjectForKey: collapses those two cases into nil, so
// it cannot answer the question; the unarchiver's own key table can.
//
// This replaces the reference's use of Foundation's private
// -objectForKeyedSubscript:, which is not declared in any public header and
// would be a dependency on a symbol that can vanish in any SDK update.
@interface NSKeyedUnarchiver (XCTCoreSDKCompat)
/// Whether the archive has an entry for -key, whatever that entry holds.
- (BOOL)containsValueForKey:(NSString *)key;
@end

// The three bundle questions a run asks before it has a configuration to run:
// which bundle is this, where do its resources live, and where would a plugin
// have been installed.
//
// +bundleWithURL: is the URL-based constructor, and it is what makes a bundle
// found by directory scan usable at all -- bundleWithPath: would round-trip the
// path through a string and lose the distinction between a URL that points at
// something and a path that merely spells it.
//
// builtInPlugInsURL is nullable, and correctly so: a bundle with no PlugIns
// directory has no answer, and that is a normal thing for a test bundle to be.
@interface NSBundle (XCTCoreSDKCompat)
+ (nullable instancetype)bundleWithURL:(NSURL *)url;
@property (readonly, copy) NSURL *resourceURL;
@property (readonly, copy, nullable) NSURL *builtInPlugInsURL;
@end

// Directory enumeration, in the URL form. The reduced header has only the
// NSString form, which would mean converting every entry back to a path to
// compare dates and then forward again to build the bundle URL -- and the two
// conversions are not required to agree about what a path is.
//
// The options argument is NSUInteger rather than NSDirectoryEnumerationOptions
// because the reduced SDK omits that enum. Every enumeration this makes passes
// 0, so no flag value is ever spelled, and NSUInteger is what the enum is
// anyway.
@interface NSFileManager (XCTCoreSDKCompat)
- (nullable NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url
                             includingPropertiesForKeys:(nullable NSArray<NSString *> *)propertyKeys
                                                options:(NSUInteger)options
                                                  error:(out NSError **)error;
@end

// Reading a configuration's bytes. Three ways in, one reason: a configuration
// arrives either as a file the run was pointed at or as a string an environment
// variable carried, and the string case is base64 rather than a path because it
// has to survive a process boundary that has no opinion about files.
//
// As above, the options are NSUInteger because the reduced SDK omits
// NSDataReadingOptions and NSDataBase64DecodingOptions. All three are called
// with 0 here, which for the base64 case is the strict reading: it rejects
// anything outside the alphabet instead of skipping over it, and a
// configuration that needed forgiving was not produced by the reference.
@interface NSData (XCTCoreSDKCompat)
+ (nullable NSData *)dataWithContentsOfFile:(NSString *)path
                                   options:(NSUInteger)options
                                     error:(out NSError **)error;
+ (nullable NSData *)dataWithContentsOfURL:(NSURL *)url
                                  options:(NSUInteger)options
                                    error:(out NSError **)error;
- (nullable instancetype)initWithBase64EncodedString:(NSString *)base64EncodedString
                                             options:(NSUInteger)options;
@end

NS_ASSUME_NONNULL_END

#endif /* XCTESTCORE_XCTESTCOREFOUNDATIONCOMPAT_H */
