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
// Every declaration below is a category. That is deliberate, and it is what
// makes this file safe under both SDKs: re-declaring a method a category already
// declares is legal, where re-declaring a class is a hard error.
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
// Scope discipline: this declares only what XCTestConfiguration.m calls. It is
// not an attempt to reconstruct Foundation.

#ifndef XCTESTCORE_XCTESTCOREFOUNDATIONCOMPAT_H
#define XCTESTCORE_XCTESTCOREFOUNDATIONCOMPAT_H

#import <Foundation/Foundation.h>
#import <Foundation/NSKeyedArchiver.h>

NS_ASSUME_NONNULL_BEGIN

// Path decomposition. Upstream semantics throughout, including the
// empty-string result for a bare "/" or a path ending in a separator: stripping
// the last component of "/Users/x/" is the answer "" and not "/" again.
@interface NSString (XCTCoreSDKCompat)
@property (readonly, copy) NSString *lastPathComponent;
@property (readonly, copy) NSString *stringByDeletingLastPathComponent;
@end

// The reduced <Foundation/NSURL.h> stops at -isFileURL. A configuration carries
// its bundle as a URL, and the bundle's *name* is the URL's last path component --
// the difference between a run that can find its bundle and one that cannot.
@interface NSURL (XCTCoreSDKCompat)
@property (readonly, copy) NSString *lastPathComponent;
@end

// Flattens the array's elements into one string. This is only here to render
// -description: as a single readable line: a target application's arguments are
// a list that has to appear as a list in the log, not as eleven separate
// placeholders. Upstream returns an empty string for an empty array and the
// separator for an empty element, which is why it is a separator and not a
// delimiter to skip.
@interface NSArray<ObjectType> (XCTCoreSDKCompat)
- (NSString *)componentsJoinedByString:(NSString *)separator;
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

NS_ASSUME_NONNULL_END

#endif /* XCTESTCORE_XCTESTCOREFOUNDATIONCOMPAT_H */
