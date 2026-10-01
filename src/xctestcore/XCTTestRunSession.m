// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The two enumeration value types. See XCTTestRunSession.h for why they are
// here and what they are for.
//
// Everything below is derived from the reference's arm64e. Two details are
// reproduced rather than corrected, and both are called out at the point they
// appear, because each one is observable by a caller that does nothing but
// print the value or archive it:
//
//   -initWithCoder: on the options returns nil for an all-false archive.
//   -description on the options has no closing parenthesis.
//
// Both are noted again in the tests, which is where a reader should look to see
// that they are deliberate rather than oversights.

#import <XCTestCore/XCTTestRunSession.h>

@implementation XCTTestEnumerationOptions
{
    // Declared rather than synthesised: the properties are readonly and the
    // getters below are hand-written, which is the one case where the compiler
    // will not create the storage for you.
    BOOL _includeAllTestIdentifiers;
    BOOL _includeParallelizableTestIdentifierGroups;
}

- (instancetype)initWithIncludeAllTestIdentifiers:(BOOL)includeAllTestIdentifiers
         includeParallelizableTestIdentifierGroups:(BOOL)includeParallelizableTestIdentifierGroups
{
    self = [super init];
    if (self) {
        _includeAllTestIdentifiers = includeAllTestIdentifiers;
        _includeParallelizableTestIdentifierGroups = includeParallelizableTestIdentifierGroups;
    }
    return self;
}

- (instancetype)init
{
    // Both NO, which is the Swift default for a stored Bool and not a choice
    // this port made: a fresh options object asks for nothing. It is also the
    // one value of this type that cannot be archived, which -initWithCoder:
    // explains.
    return [self initWithIncludeAllTestIdentifiers:NO
        includeParallelizableTestIdentifierGroups:NO];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // -decodeBoolForKey:, not a decoded object: the reference encodes these two
    // as plist booleans rather than as NSNumbers wrapped in an archive, and a
    // reader that asked for an object would reject an archive the reference
    // wrote. A missing key decodes to NO, so the "both false" case below also
    // covers an archive with neither key.
    BOOL includeAll = [coder decodeBoolForKey:@"includeAllTestIdentifiers"];
    BOOL includeParallelizable = [coder decodeBoolForKey:@"includeParallelizableTestIdentifierGroups"];

    if (!includeAll && !includeParallelizable) {
        // The reference deallocates itself here and returns nil rather than
        // building an object that requests nothing. It is reproduced because it
        // is load-bearing: an executor decides whether it can answer by
        // enumerating, and the answer it wants is "no such request exists", not
        // "here is a request whose answer is nothing". A caller that receives
        // nil can fall back to executing; a caller that receives an all-false
        // options object has to guess that the caller who wrote the archive
        // meant it.
        //
        // The cost is that -init is not archivable, and the cost of the cost is
        // that a round trip is not a fixed point. Both are the reference's
        // behaviour, and matching it is the point of this port.
        return nil;
    }

    return [self initWithIncludeAllTestIdentifiers:includeAll
        includeParallelizableTestIdentifierGroups:includeParallelizable];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:_includeAllTestIdentifiers forKey:@"includeAllTestIdentifiers"];
    [coder encodeBool:_includeParallelizableTestIdentifierGroups
                forKey:@"includeParallelizableTestIdentifierGroups"];
}

- (BOOL)includeAllTestIdentifiers
{
    return _includeAllTestIdentifiers;
}

- (BOOL)includeParallelizableTestIdentifierGroups
{
    return _includeParallelizableTestIdentifierGroups;
}

- (NSString *)description
{
    // Spelled the way the reference spells it, which means two deviations from
    // what an -NSString description in this framework would normally look like.
    //
    // The booleans are rendered `true` and `false` in lower case rather than
    // being interpolated as NSNumbers, which would print `1` and `0`. That is
    // not a choice about style: the reference builds this string in Swift from
    // a Bool, and Swift prints a Bool that way.
    //
    // There is no closing parenthesis. The reference appends the two labels and
    // the two booleans and returns, and the result is
    //
    //     XCTTestEnumerationOptions(includeAllTestIdentifiers: true,
    //     includeParallelizableTestIdentifierGroups: false
    //
    // with an unmatched `(`. Reproduced rather than fixed: this string reaches
    // test logs and crash reports, and a log line that differs from the
    // reference's is a difference in what a reader comparing the two is looking
    // at. The tests assert the exact bytes, including the missing parenthesis,
    // so that a future decision to close it has to be a deliberate edit here
    // rather than a quiet drift.
    return [NSString stringWithFormat:
        @"XCTTestEnumerationOptions(includeAllTestIdentifiers: %@, includeParallelizableTestIdentifierGroups: %@",
        _includeAllTestIdentifiers ? @"true" : @"false",
        _includeParallelizableTestIdentifierGroups ? @"true" : @"false"];
}

@end

@implementation XCTTestEnumerationResult
{
    // As above: hand-written getters over readonly properties, so the storage
    // is declared.
    XCTTestIdentifierSet *_allTestIdentifiers;
    NSArray *_parallelizableTestIdentifierGroups;
}

- (instancetype)initWithAllTestIdentifiers:(XCTTestIdentifierSet *)allTestIdentifiers
         parallelizableTestIdentifierGroups:(NSArray *)parallelizableTestIdentifierGroups
{
    self = [super init];
    if (self) {
        // Retained rather than copied. The reference stores both in a Swift
        // `let` and its two properties are plain strong references, so a result
        // shares the caller's identifier set and the caller's grouping rather
        // than taking a private snapshot. Copying here would be a stronger
        // promise than the type makes, and would make it observable: a caller
        // that mutates the grouping after asking would see the reference change
        // under the result and would not see it here.
        _allTestIdentifiers = allTestIdentifiers;
        _parallelizableTestIdentifierGroups = parallelizableTestIdentifierGroups;
    }
    return self;
}

- (instancetype)init
{
    // Both fields nil, and unlike the options this *is* archivable: nil is a
    // value the two keys can carry, so a result that declined both views
    // survives a round trip and comes back declined rather than absent.
    return [self initWithAllTestIdentifiers:nil parallelizableTestIdentifierGroups:nil];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // Both keys are optional, and a missing one decodes to nil rather than
    // failing, because a result is allowed to carry one view without the other.
    // The grouping is an array of identifier sets, matching the shape
    // -[XCTTestIdentifierSet testIdentifiersGroupedByFirstComponentIdentifier]
    // produces: a dictionary keyed by first component, whose values are sets.
    NSSet *identifierClasses = [NSSet setWithObjects:[XCTTestIdentifierSet class], nil];
    XCTTestIdentifierSet *all = [coder decodeObjectOfClasses:identifierClasses
                                                      forKey:@"allTestIdentifiers"];

    NSSet *groupClasses = [NSSet setWithObjects:[NSArray class], [NSSet class],
                         [XCTTestIdentifier class], nil];
    NSArray *groups = [coder decodeObjectOfClasses:groupClasses
                                            forKey:@"parallelizableTestIdentifierGroups"];

    return [self initWithAllTestIdentifiers:all parallelizableTestIdentifierGroups:groups];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_allTestIdentifiers) {
        [coder encodeObject:_allTestIdentifiers forKey:@"allTestIdentifiers"];
    }
    if (_parallelizableTestIdentifierGroups) {
        [coder encodeObject:_parallelizableTestIdentifierGroups
                     forKey:@"parallelizableTestIdentifierGroups"];
    }
}

- (XCTTestIdentifierSet *)allTestIdentifiers
{
    return _allTestIdentifiers;
}

- (NSArray *)parallelizableTestIdentifierGroups
{
    return _parallelizableTestIdentifierGroups;
}

@end
