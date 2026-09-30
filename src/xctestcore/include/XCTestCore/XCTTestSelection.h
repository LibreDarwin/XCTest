// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Test selection: which tests a run should execute, and which it should not.
//
// A configuration says "run these tests in this bundle". This is the other
// half of that sentence. The reference splits it across five classes and the
// split is not arbitrary:
//
//   XCTTestSelection       the four answers: run these, skip these, plus the
//                          same question asked of tags instead of identifiers
//   XCTTestIdentifierSet   an unordered set of identifiers, deduplicated
//   XCTTestIdentifier      one addressable thing: a component list, the
//                          arguments it was invoked with, and option bits
//   XCTTag                 a tag as written in source, not as normalised
//   XCTTagSelection        a set of tags and how to combine them
//
// Two of those five are reached only through the others, which is why they
// live here rather than in a file of their own: a tag cannot be decoded
// without XCTTag, and a tag selection cannot be decoded without knowing that
// its set holds XCTTag objects rather than strings.
//
// Not yet derived, and therefore absent rather than stubbed:
//
//   XCTTestIdentifierSetBuilder              a mutable accumulator for building
//                                            a set incrementally. Convenience,
//                                            not part of any archive.
//   -XCTTagSelection dictionaryRepresentation, +modeFromString:,
//   -XCTTagSelection initWithDictionary:     the plist form, which the IDE
//                                            writes and this port never reads.
//   XCTTestIdentifierSetBuilder -builder     likewise.
//   -XCTTestIdentifier swiftMethodCounterpart, objcMethodCounterpart,
//   legacyEncodingCounterpart, legacyClassAndMethodStringRepresentation,
//   identifierWithAncestorSuiteContext, stagedIdentifier, and the nine
//     private _XCTTestIdentifier_* subclasses
//                                            Swift Testing interoperability and
//                                            the encoding rewrite that carries
//                                            it. None of it is reachable from an
//                                            archive; the archive carries the
//                                            option bits (below), not the
//                                            counterparts.
//
// The distinction that matters throughout: what an *archive* contains is
// implemented here, and what the *IDE* writes into a scheme is not. The
// archives are what a run has to be able to read back.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - XCTTag

/// A tag exactly as it was written in source.
///
/// Identity is the source spelling, not a normalised form: -isEqual: compares
/// -sourceCodeRepresentation, so "@slow" and "@Slow" are different tags. That
/// is deliberate -- a tag is whatever the author typed, and rewriting it would
/// make a typo silently select something.
@interface XCTTag : NSObject <NSCopying, NSSecureCoding>

- (instancetype)initWithSourceCodeRepresentation:(NSString *)representation
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The tag as written, e.g. `@slow` or `@Suite.Nested`.
@property (readonly, copy) NSString *sourceCodeRepresentation;

/// The spelling without its leading `@`, which is how a tag is printed.
@property (readonly, copy) NSString *displayName;

@end

#pragma mark - XCTTagSelection

/// How a set of tags is combined into a single yes-or-no answer.
typedef NS_ENUM(NSInteger, XCTTagSelectionMode) {
    /// Any one of the tags is enough.
    XCTTagSelectionModeOr = 0,
    /// Every one of the tags has to be present.
    XCTTagSelectionModeAnd = 1,
};

/// A set of tags, and how to combine them.
@interface XCTTagSelection : NSObject <NSCopying, NSSecureCoding>

- (instancetype)initWithTags:(NSSet<XCTTag *> *)tags
               selectionMode:(XCTTagSelectionMode)selectionMode;
- (instancetype)initWithTags:(NSSet<XCTTag *> *)tags
               selectionMode:(XCTTagSelectionMode)selectionMode
              includeXCTests:(BOOL)includeXCTests;
- (instancetype)init;

@property (nonatomic, copy) NSSet<XCTTag *> *tags;
@property (nonatomic) XCTTagSelectionMode selectionMode;

/// Whether the tags also apply to XCTest tests, as opposed to only to the
/// Swift Testing tests they were written for.
@property (nonatomic) BOOL includeXCTests;

@property (readonly, getter=isEmpty) BOOL empty;

@end

#pragma mark - XCTTestIdentifier

/// What an identifier is: a container that has children, or a leaf that does not.
///
/// The distinction is structural, not about XCTest: a suite is a container and a
/// test method is a leaf, and the bits are stored explicitly so the answer
/// survives a round trip through an archive that cannot see the test tree.
typedef NS_OPTIONS(NSUInteger, XCTTestIdentifierOptions) {
    XCTTestIdentifierOptionNone       = 0,
    /// The identifier names something that can contain other identifiers.
    XCTTestIdentifierOptionContainer  = 1 << 0,
    /// The components are a class name and a method name, the pre-Swift-Testing
    /// spelling, and are also written as the legacy `className`/`methodName`
    /// keys.
    XCTTestIdentifierOptionClassAndMethod = 1 << 1,
    /// The leaf is a Swift Testing test rather than an XCTest method.
    XCTTestIdentifierOptionSwiftMethod = 1 << 2,
};

/// One addressable thing in a test bundle: a component list, the arguments it
/// was invoked with, and what kind of thing it is.
///
/// A component is one path element. `MyTests.testFoo` has two, plus the
/// implicit bundle component in front, so a fully qualified identifier has
/// three. The bundle component is why `initWithClassName:` and
/// `initWithClassName:methodName:` both exist as shorthands, and why an
/// identifier read back from an archive carries its own spelling rather than
/// re-deriving one.
@interface XCTTestIdentifier : NSObject <NSCopying, NSSecureCoding>

- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                       argumentIDs:(nullable NSSet<NSData *> *)argumentIDs
                           options:(XCTTestIdentifierOptions)options NS_DESIGNATED_INITIALIZER;

// The four shorthands below are conveniences over the designated initializer,
// not initializers in their own right: each one picks an option bits or drops
// a field, and all four are reconstructible from the designated form. Keeping
// exactly one designated initializer is what lets the compiler check that
// every other path ends up there.
- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                       isContainer:(BOOL)isContainer;
- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                            options:(XCTTestIdentifierOptions)options;
- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                       argumentIDs:(nullable NSSet<NSData *> *)argumentIDs;

- (instancetype)initWithClassAndMethodComponents:(NSArray<NSString *> *)components;
- (instancetype)initWithClassName:(NSString *)className;
- (instancetype)initWithClassName:(NSString *)className
                       methodName:(NSString *)methodName;

// No bare -init: an identifier with no components is not a shorter spelling of
// any identifier, it is an invalid one, and there is no default that would be
// right rather than merely plausible.
- (instancetype)init NS_UNAVAILABLE;

/// The path components, outermost first.
@property (nonatomic, readonly, copy) NSArray<NSString *> *components;
@property (nonatomic, readonly) NSUInteger componentCount;
- (nullable NSString *)componentAtIndex:(NSUInteger)index;
@property (nonatomic, readonly, copy, nullable) NSString *firstComponent;
@property (nonatomic, readonly, copy, nullable) NSString *lastComponent;

/// The identifiers of the arguments this test was invoked with, if any.
@property (nonatomic, readonly, copy, nullable) NSSet<NSData *> *argumentIDs;

@property (nonatomic, readonly) XCTTestIdentifierOptions options;
@property (nonatomic, readonly) BOOL isContainer;
@property (nonatomic, readonly) BOOL isLeaf;
@property (nonatomic, readonly) BOOL usesClassAndMethodSemantics;
@property (nonatomic, readonly) BOOL isSwiftMethod;
@property (nonatomic, readonly) BOOL representsBundle;

/// The single string an identifier is written and compared as.
@property (nonatomic, readonly, copy) NSString *identifierString;

/// The identifier with -argumentIDs removed, which is what identifies a test
/// when arguments are not part of the question being asked.
@property (nonatomic, readonly) XCTTestIdentifier *identifierWithoutArguments;

- (XCTTestIdentifier *)childIdentifierWithComponent:(NSString *)component
                                       isContainer:(BOOL)isContainer;
- (XCTTestIdentifier *)childIdentifierWithArgumentIDs:(nullable NSSet<NSData *> *)argumentIDs;
- (XCTTestIdentifier *)identifierByAppendingComponent:(NSString *)component
                                          isContainer:(BOOL)isContainer;

/// Whether -argumentID is an ancestor of the receiver, i.e. whether the
/// receiver names something inside that argument.
- (BOOL)isAncestorOfTestIdentifier:(XCTTestIdentifier *)identifier;

/// The name shown in a test log, which is the last component.
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSArray<NSString *> *displayNameComponents;

@end

#pragma mark - XCTTestIdentifierSet

/// An unordered set of identifiers.
///
/// Conforms to NSFastEnumeration because the reference's does, and because
/// `for (XCTTestIdentifier *id in set)` is the natural way to walk one. The
/// order is unspecified and must stay that way: the reference sorts on demand
/// through -sortedIdentifiers rather than storing sorted, so a set that
/// happened to enumerate sorted would be a stronger promise than the type makes.
@interface XCTTestIdentifierSet : NSObject <NSCopying, NSFastEnumeration, NSSecureCoding>

- (instancetype)initWithArray:(NSArray<XCTTestIdentifier *> *)identifiers;
- (instancetype)initWithSet:(XCTTestIdentifierSet *)set;
- (instancetype)initWithTestIdentifier:(XCTTestIdentifier *)identifier;
- (instancetype)init;

@property (nonatomic, readonly) NSUInteger count;

/// The identifiers, in a deterministic order, for anything that has to be
/// stable across runs -- a log line, a hash, an archive.
@property (nonatomic, readonly, copy) NSArray<XCTTestIdentifier *> *sortedIdentifiers;
@property (nonatomic, readonly, nullable) XCTTestIdentifier *anyTestIdentifier;
@property (nonatomic, readonly, getter=isEmpty) BOOL empty;

- (BOOL)containsTestIdentifier:(XCTTestIdentifier *)identifier;

/// Whether the receiver holds -identifier, or anything inside it.
- (BOOL)containsTestIdentifier:(XCTTestIdentifier *)identifier
              includingParents:(BOOL)includingParents;

- (BOOL)isSubsetOfTestIdentifierSet:(XCTTestIdentifierSet *)other;

- (XCTTestIdentifierSet *)setByAddingTestIdentifiersFromSet:(XCTTestIdentifierSet *)other;
- (XCTTestIdentifierSet *)setByApplyingBlock:(id _Nullable (^)(XCTTestIdentifier *identifier))block;

/// The identifiers grouped by the identifier of their first component, which
/// is how a run turns a flat identifier list back into a tree.
- (NSDictionary<XCTTestIdentifier *, NSSet<XCTTestIdentifier *> *> *)testIdentifiersGroupedByFirstComponentIdentifier;

@end

#pragma mark - XCTTestSelection

/// The four answers that decide what runs.
///
/// All four are optional in the sense that a nil means "no opinion": an empty
/// -identifiersToRun means run everything that is not skipped, which is the
/// default for a configuration that never had a selection attached.
@interface XCTTestSelection : NSObject <NSCopying, NSSecureCoding>

- (instancetype)initWithIdentifiersToRun:(nullable XCTTestIdentifierSet *)identifiersToRun
                       identifiersToSkip:(nullable XCTTestIdentifierSet *)identifiersToSkip
                            tagsToRun:(nullable XCTTagSelection *)tagsToRun
                           tagsToSkip:(nullable XCTTagSelection *)tagsToSkip;
- (instancetype)init;

@property (nonatomic, copy, nullable) XCTTestIdentifierSet *identifiersToRun;
@property (nonatomic, copy, nullable) XCTTestIdentifierSet *identifiersToSkip;
@property (nonatomic, copy, nullable) XCTTagSelection *tagsToRun;
@property (nonatomic, copy, nullable) XCTTagSelection *tagsToSkip;

@end

NS_ASSUME_NONNULL_END