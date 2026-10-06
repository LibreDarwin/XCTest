// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for the test-selection classes.
//
// A selection is a value read from an archive somebody else wrote -- an IDE, a
// scheme, a previous version of this framework -- and the checks here are aimed
// at the three places that kind of value actually breaks. Everything else is
// round-tripping, which proves nothing: a writer and a reader that agree with
// each other and with nobody else pass every round-trip test in the world.
//
//   Decoding a *partial* archive. An archive omits whatever the default already
//   is. XCTTagSelection is the dangerous case, and the reason it is worth a
//   harness at all: its mode decodes to 1 (AND) when the key is absent, and to 0
//   (OR) when the key is present with a zero. Those two archives differ by one
//   bit and select opposite sets of tests. A decoder that read the key
//   unconditionally would read an absent key as zero and silently widen a
//   narrow selection into a broad one -- the worst direction for this particular
//   mistake to go wrong in. So three checks below hand-build the archive in
//   both shapes and read the mode back.
//
//   The legacy identifier spelling. An archive can carry a test as
//   className/methodName with no components at all, or as components with no
//   legacy names. Both are legal, and which one an archive is can only be
//   decided by looking at which keys are present -- so the decoder's first job
//   is telling them apart, and the checks below decode both.
//
//   Identity. Two identifiers with the same path can differ in one option bit,
//   and a set that forgets that is a set that runs the wrong tests. These
//   checks pin the equality and hash behaviour that depends on it.
//
// Not exercised by the framework's own tests: this is a private framework with no
// runner of its own yet, which is the same reason the driver and the agent are
// still to come.
#import <XCTestCore/XCTTestSelection.h>

#import <Foundation/Foundation.h>
// Not pulled in by the reduced <Foundation/Foundation.h>, and this harness is
// built on keyed coding.
#import <Foundation/NSKeyedArchiver.h>

#import <stdio.h>
#import <string.h>

static int failures = 0;

static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-56s %s%s%s\n", name, passed ? "PASS" : "FAIL",
           (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Helpers

/// Records which keys an archive actually carries.
///
/// A keyed archive is a binary plist, and this was written the obvious way first:
/// search the encoded bytes for the key name as text. That works for a key long
/// enough to be stored as a length-prefixed ASCII string and fails for the short
/// ones, because a one-character plist string is stored inline -- "c" is a bare
/// 0x63, preceded only by a type byte, and "oc" happens to occur inside
/// "XCTTestIdentifier" so a substring search reports a key that was never written.
/// Three of the five selection classes use keys short enough to hit one of those
/// two cases, which is most of the reason this file exists.
///
/// So the keys are asked of the archive instead of guessed from it. The probe is
/// decoded as the archived class, and -containsValueForKey: is the reader's own
/// answer to "was this key written" -- the same question the real -initWithCoder:
/// asks, which is why this checks the format rather than the plist encoding.
/// So the keys are asked of the archive instead of guessed from it. The probe is
/// decoded as the archived class, and -containsValueForKey: is the reader's own
/// answer to "was this key written" -- the same question the real -initWithCoder:
/// asks, which is why this checks the format rather than the plist encoding.
///
/// The probe adopts NSSecureCoding and is swapped in through the unarchiver's
/// class table. That is not a detail: an earlier version of this probe did not
/// declare the protocol, and the decoder rejected it with "does not adopt
/// NSSecureCoding" -- the archive decodes to nothing at all, which reads as a
/// missing key rather than as a broken probe. It also has to go through the
/// +unarchivedObjectOfClass: entry point, since -decodeObjectOfClass:forKey: on
/// an instance-built unarchiver returns nil for every archive here.
@interface KeyProbe : NSObject <NSSecureCoding>
{
@public
    NSMutableArray<NSString *> *_present;
}
+ (NSArray<NSString *> *)probeArchive:(NSData *)archive
                            classNamed:(NSString *)className
                                  keys:(NSArray<NSString *> *)keys;
@end

/// The key list the instance is asked to look for. A probe instance cannot know
/// which keys the caller cares about, and threading that through -initWithCoder:
/// is not possible -- the decoder calls it, not us -- so it goes in a file-scope
/// variable set immediately before the decode and cleared immediately after.
/// Single-threaded by construction: the decode that reads it is the only thing
/// running between the two assignments.
static NSArray<NSString *> *probeWantedKeys = nil;

@implementation KeyProbe

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _present = [NSMutableArray array];
        for (NSString *key in probeWantedKeys) {
            if ([coder containsValueForKey:key]) {
                [_present addObject:key];
            }
        }
    }
    return self;
}

/// Never called on this path, and deliberately empty. The probe exists to be
/// decoded, never to encode, and a probe that encoded its findings would be
/// indistinguishable from the class it is standing in for.
- (void)encodeWithCoder:(NSCoder *)coder
{
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

+ (NSArray<NSString *> *)probeArchive:(NSData *)archive
                            classNamed:(NSString *)className
                                  keys:(NSArray<NSString *> *)keys
{
    NSError *error = nil;
    // Class-level remapping, then the class-method decode, and the mapping is
    // undone immediately: it is a process-wide table, and leaving the probe
    // installed would make every later decode of the real class in this harness
    // silently produce a KeyProbe instead.
    [NSKeyedUnarchiver setClass:[KeyProbe class] forClassName:className];
    probeWantedKeys = keys;
    id probe = [NSKeyedUnarchiver unarchivedObjectOfClass:[KeyProbe class] fromData:archive error:&error];
    probeWantedKeys = nil;
    [NSKeyedUnarchiver setClass:NSClassFromString(className) forClassName:className];

    if (![probe isKindOfClass:[KeyProbe class]]) {
        ok("probe archive", NO, [NSString stringWithFormat:@"probe failed: %@", error]);
        return nil;
    }
    KeyProbe *typed = probe;
    return [typed->_present copy];
}
@end

static NSData *encode(id object, NSString *why)
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object
                                        requiringSecureCoding:YES
                                                        error:&error];
    if (!data) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"encode failed: %@", error]);
    }
    return data;
}

/// The keys `cls`'s -encodeWithCoder: actually wrote.
///
/// Probes with a list rather than searching the bytes, so a key the encoder did
/// not write is reported absent even when the same characters occur elsewhere in
/// the archive.
static NSSet<NSString *> *encodedKeys(id object, Class cls, NSArray<NSString *> *candidates, NSString *why)
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object
                                        requiringSecureCoding:YES
                                                        error:&error];
    if (!data) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"encode failed: %@", error]);
        return nil;
    }
    NSArray<NSString *> *present = [KeyProbe probeArchive:data
                                                classNamed:NSStringFromClass(cls)
                                                      keys:candidates];
    if (present == nil) {
        return nil;
    }
    return [NSSet setWithArray:present];
}

static id decode(NSData *data, Class cls, NSString *why)
{
    NSError *error = nil;
    id decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:cls fromData:data error:&error];
    if (!decoded) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"decode failed: %@", error]);
    }
    return decoded;
}

static XCTTestIdentifier *identifier(NSArray<NSString *> *components, XCTTestIdentifierOptions options)
{
    return [[XCTTestIdentifier alloc] initWithComponents:components argumentIDs:nil options:options];
}

/// The first element, or nil.
///
/// Spelled out rather than reached through -firstObject: that member is declared
/// in this project's private compat header, which is not installed, so a client
/// of the framework cannot see it. A harness is a client.
static id firstOf(NSArray *array)
{
    return array.count > 0 ? [array objectAtIndex:0] : nil;
}

/// The first key of a dictionary, or nil.
///
/// Enumerated rather than fetched through -allValues, again for the reduced
/// headers. Order is unspecified, which is fine: every check that uses this
/// asserts about a grouping that has exactly one group.
static id firstKeyOf(NSDictionary *dictionary)
{
    for (id key in dictionary) {
        return key;
    }
    return nil;
}

/// The total number of identifiers across every group, without going through
/// -allValues, which the reduced header set does not declare on NSDictionary.
static NSUInteger totalMembers(NSDictionary *groups)
{
    NSUInteger total = 0;
    for (id key in groups) {
        total += [groups[key] count];
    }
    return total;
}

#pragma mark - Sparse archives

/// The keys the next sparse archive should contain, and their values.
static NSDictionary *sparseKeys;

/// A tag selection whose encoder writes only the keys the test asked for.
///
/// Overriding the *encoder* rather than hand-assembling bytes is what makes these
/// archives the same shape a build that predates a key would have produced:
/// Foundation writes each key the way the real writer writes it, including the
/// integer-vs-boolean distinction that the mode key depends on. Remapping the
/// archived class name to XCTTagSelection below puts the real -initWithCoder: on
/// the other end of it.
@interface SparseTagSelection : XCTTagSelection
@end

@implementation SparseTagSelection
- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *key in sparseKeys) {
        id value = sparseKeys[key];
        if ([key isEqualToString:@"XCTTagSelectionMode"]) {
            // Encoded as an integer, which is what the real encoder does. A mode
            // written as a bool would decode through a different accessor and the
            // check would be testing a shape the format never has.
            [coder encodeInteger:[value integerValue] forKey:key];
        } else if ([key isEqualToString:@"XCTTagSelectionIncludeXCTests"]) {
            [coder encodeBool:[value boolValue] forKey:key];
        } else {
            [coder encodeObject:value forKey:key];
        }
    }
}
@end

/// A test identifier whose encoder writes only the keys the test asked for, for
/// the same reason as SparseTagSelection -- and because the legacy spelling is a
/// *different set of keys*, not a subset, so it cannot be reached by writing the
/// modern keys with different values.
@interface SparseIdentifier : XCTTestIdentifier
@end

@implementation SparseIdentifier
- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *key in sparseKeys) {
        id value = sparseKeys[key];
        if ([key isEqualToString:@"o"]) {
            [coder encodeInteger:[value integerValue] forKey:key];
        } else if ([key isEqualToString:@"oc"] || [key isEqualToString:@"ocm"] ||
                   [key isEqualToString:@"os"] || [key isEqualToString:@"deprecated"]) {
            [coder encodeBool:[value boolValue] forKey:key];
        } else {
            [coder encodeObject:value forKey:key];
        }
    }
}
@end

/// Archives a selection carrying only `values`, then decodes it with the real class.
static XCTTagSelection *decodeSparseTagSelection(NSDictionary *values, NSString *why)
{
    sparseKeys = values;
    NSData *data = encode([[SparseTagSelection alloc] init], why);
    sparseKeys = nil;
    return decode(data, [XCTTagSelection class], why);
}

static XCTTestIdentifier *decodeSparseIdentifier(NSDictionary *values, NSString *why)
{
    sparseKeys = values;
    NSData *data = encode([[SparseIdentifier alloc] initWithComponents:@[] argumentIDs:nil
                                                                 options:XCTTestIdentifierOptionNone],
                          why);
    sparseKeys = nil;
    return decode(data, [XCTTestIdentifier class], why);
}

#pragma mark - Archive keys

/// The key names are the interface. An .xctestrun in the wild, an IDE, and the
/// shipped framework all have to agree on them, and this harness is the only
/// place that will notice if one of them stops.
///
/// Every class is probed with the full list of keys the format defines for it,
/// including the ones this encoder deliberately does not write, so that a key
/// appearing or disappearing is visible in both directions.
static void testArchiveKeys(void)
{
    printf("archive keys\n");

    NSSet<NSString *> *tagKeys = encodedKeys([[XCTTag alloc] initWithSourceCodeRepresentation:@"@slow"],
                                             [XCTTag class],
                                             @[ @"XCTTagSourceCodeRepresentation" ],
                                             @"encode tag");
    ok("XCTTag writes XCTTagSourceCodeRepresentation",
       [tagKeys containsObject:@"XCTTagSourceCodeRepresentation"], nil);
    ok("XCTTag writes nothing else", tagKeys.count == 1, [tagKeys description]);

    XCTTagSelection *tags = [[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:[[XCTTag alloc]
                                                                                             initWithSourceCodeRepresentation:@"@a"]]
                                                     selectionMode:XCTTagSelectionModeAnd
                                                    includeXCTests:YES];
    NSSet<NSString *> *tagSelectionKeys = encodedKeys(tags,
                                                     [XCTTagSelection class],
                                                     @[ @"XCTTagSelectionMode", @"XCTTagSelectionTagSet",
                                                        @"XCTTagSelectionIncludeXCTests" ],
                                                     @"encode tag selection");
    ok("XCTTagSelection writes XCTTagSelectionTagSet",
       [tagSelectionKeys containsObject:@"XCTTagSelectionTagSet"], nil);
    ok("XCTTagSelection writes XCTTagSelectionMode",
       [tagSelectionKeys containsObject:@"XCTTagSelectionMode"], nil);
    ok("XCTTagSelection writes XCTTagSelectionIncludeXCTests",
       [tagSelectionKeys containsObject:@"XCTTagSelectionIncludeXCTests"], nil);
    ok("XCTTagSelection writes nothing else", tagSelectionKeys.count == 3, [tagSelectionKeys description]);

    // The identifier is the case that motivated the probe: three of its keys are
    // one character long, which the plist stores inline, so a text search over
    // the archive cannot tell "c" from any other lone "c".
    XCTTestIdentifier *foo = identifier(@[ @"Bundle", @"Class", @"testFoo" ], XCTTestIdentifierOptionNone);
    NSSet<NSString *> *identifierKeys = encodedKeys(foo,
                                                    [XCTTestIdentifier class],
                                                    @[ @"c", @"a", @"o", @"oc", @"ocm", @"os",
                                                       @"className", @"methodName", @"bundleName", @"deprecated" ],
                                                    @"encode identifier");
    ok("XCTTestIdentifier writes c", [identifierKeys containsObject:@"c"], nil);
    ok("XCTTestIdentifier writes o", [identifierKeys containsObject:@"o"], nil);
    ok("XCTTestIdentifier writes nothing else",
       identifierKeys.count == 3, [identifierKeys description]);

    // The legacy keys are a read path. An identifier that has components has
    // nothing to say with className/methodName -- writing them would name a
    // different test -- and writing bundleName would prepend a component that
    // every other identifier in the same archive lacks. This check is the one
    // that would notice if the encoder started emitting them anyway, because
    // "the decoder can still read them" is not the same as "we write them".
    ok("XCTTestIdentifier writes no legacy key",
       ![identifierKeys containsObject:@"className"] && ![identifierKeys containsObject:@"methodName"] &&
           ![identifierKeys containsObject:@"bundleName"] && ![identifierKeys containsObject:@"deprecated"],
       [identifierKeys description]);
    ok("XCTTestIdentifier writes no single-bit key alongside o",
       ![identifierKeys containsObject:@"oc"] && ![identifierKeys containsObject:@"ocm"] &&
           ![identifierKeys containsObject:@"os"],
       [identifierKeys description]);

    // With a container, the packed "o" is the only option key: the single-bit
    // spellings exist for archives that predate "o", not alongside it.
    NSSet<NSString *> *containerKeys =
        encodedKeys(identifier(@[ @"Bundle", @"Suite" ], XCTTestIdentifierOptionContainer),
                    [XCTTestIdentifier class],
                    @[ @"o", @"oc" ], @"encode container identifier");
    ok("a container identifier writes o and not oc",
       [containerKeys containsObject:@"o"] && ![containerKeys containsObject:@"oc"], [containerKeys description]);

    NSSet<NSString *> *setKeys = encodedKeys([[XCTTestIdentifierSet alloc]
                                                 initWithArray:@[ identifier(@[ @"A" ],
                                                                                  XCTTestIdentifierOptionNone) ]],
                                             [XCTTestIdentifierSet class],
                                             @[ @"identifiers" ], @"encode set");
    ok("XCTTestIdentifierSet writes identifiers", [setKeys containsObject:@"identifiers"], nil);
    ok("XCTTestIdentifierSet writes nothing else", setKeys.count == 1, [setKeys description]);

    XCTTestSelection *selection = [[XCTTestSelection alloc]
        initWithIdentifiersToRun:[[XCTTestIdentifierSet alloc] initWithArray:@[ identifier(@[ @"A" ],
                                                                                                XCTTestIdentifierOptionNone) ]]
               identifiersToSkip:nil
                    tagsToRun:tags
                   tagsToSkip:nil];
    NSSet<NSString *> *selectionKeys = encodedKeys(selection,
                                                   [XCTTestSelection class],
                                                   @[ @"IdentifiersToRun", @"IdentifiersToSkip", @"TagsToRun",
                                                      @"TagsToSkip" ],
                                                   @"encode selection");
    ok("XCTTestSelection writes IdentifiersToRun", [selectionKeys containsObject:@"IdentifiersToRun"], nil);
    ok("XCTTestSelection writes TagsToRun", [selectionKeys containsObject:@"TagsToRun"], nil);

    // All four keys, whatever the selection holds -- including this one, which
    // is a quarter empty. That is the point: "IdentifiersToSkip" being written
    // with a nil value is a decision, not an oversight, and the decoder has to
    // see the key in order to tell "absent" from "written as empty". The pair
    // of archives here is the one that would catch an encoder that skipped nil
    // values, because then a selection skipping nothing and a selection skipping
    // everything would encode identically.
    ok("a selection with nils still writes all four keys", selectionKeys.count == 4,
       [selectionKeys description]);

    XCTTestSelection *full = [[XCTTestSelection alloc]
        initWithIdentifiersToRun:[[XCTTestIdentifierSet alloc] initWithArray:@[ identifier(@[ @"A" ],
                                                                                             XCTTestIdentifierOptionNone) ]]
               identifiersToSkip:[[XCTTestIdentifierSet alloc] initWithArray:@[ identifier(@[ @"B" ],
                                                                                              XCTTestIdentifierOptionNone) ]]
                    tagsToRun:tags
                   tagsToSkip:[[XCTTagSelection alloc] init]];
    NSSet<NSString *> *fullKeys = encodedKeys(full,
                                              [XCTTestSelection class],
                                              @[ @"IdentifiersToRun", @"IdentifiersToSkip", @"TagsToRun",
                                                 @"TagsToSkip" ],
                                              @"encode full selection");
    ok("a fully populated selection writes the same four keys", fullKeys.count == 4, [fullKeys description]);
    ok("a full and an empty selection encode the same key set", [fullKeys isEqual:selectionKeys],
       [fullKeys description]);
}

#pragma mark - Partial archives

/// The mode key is the whole reason this harness exists.
static void testPartialTagSelection(void)
{
    printf("partial tag selection\n");

    // No keys at all. The reference defaults the mode to 1 -- AND -- rather than
    // to 0, and this is the check that says so.
    XCTTagSelection *empty = decodeSparseTagSelection(@{}, @"empty tag selection");
    ok("absent mode decodes to AND", empty.selectionMode == XCTTagSelectionModeAnd,
       [NSString stringWithFormat:@"got %ld", (long)empty.selectionMode]);
    ok("absent includeXCTests decodes to NO", empty.includeXCTests == NO, nil);
    ok("absent tags decode to an empty set", empty.tags.count == 0, nil);
    ok("absent everything reads as empty", empty.isEmpty, nil);

    // Mode present and zero. This is the archive that must NOT read as AND, and
    // it differs from the one above by a single key.
    XCTTagSelection *zero = decodeSparseTagSelection(@{ @"XCTTagSelectionMode": @0 }, @"mode 0");
    ok("present mode 0 decodes to OR", zero.selectionMode == XCTTagSelectionModeOr,
       [NSString stringWithFormat:@"got %ld", (long)zero.selectionMode]);

    XCTTagSelection *one = decodeSparseTagSelection(@{ @"XCTTagSelectionMode": @1 }, @"mode 1");
    ok("present mode 1 decodes to AND", one.selectionMode == XCTTagSelectionModeAnd, nil);

    // The two archives differ by one key and select opposite sets. Asserting that
    // directly is what makes the pair a test rather than two unrelated ones.
    ok("absent and explicit-zero modes differ", empty.selectionMode != zero.selectionMode, nil);

    XCTTagSelection *flag = decodeSparseTagSelection(@{ @"XCTTagSelectionIncludeXCTests": @YES },
                                                      @"includeXCTests");
    ok("present includeXCTests decodes to YES", flag.includeXCTests, nil);

    XCTTagSelection *explicitNo = decodeSparseTagSelection(@{ @"XCTTagSelectionIncludeXCTests": @NO },
                                                           @"includeXCTests NO");
    ok("present includeXCTests NO decodes to NO", !explicitNo.includeXCTests, nil);

    // Tag set only.
    XCTTag *tag = [[XCTTag alloc] initWithSourceCodeRepresentation:@"@slow"];
    XCTTagSelection *tagsOnly = decodeSparseTagSelection(@{ @"XCTTagSelectionTagSet": [NSSet setWithObject:tag] },
                                                          @"tags only");
    ok("tags-only archive keeps its tag", tagsOnly.tags.count == 1, nil);
    ok("tags-only archive still defaults mode to AND", tagsOnly.selectionMode == XCTTagSelectionModeAnd, nil);
}

static void testPartialIdentifier(void)
{
    printf("partial identifier\n");

    // Components with no option keys at all. Modern, but unmarked: the
    // class-and-method bit has to come out as NO rather than being assumed.
    XCTTestIdentifier *unmarked =
        decodeSparseIdentifier(@{ @"c": @[ @"Bundle", @"Class", @"testFoo" ] }, @"unmarked identifier");
    ok("components without an options key keep their components",
       [unmarked.components isEqualToArray:(@[ @"Bundle", @"Class", @"testFoo" ])], nil);
    ok("components without an options key have no bits set", unmarked.options == XCTTestIdentifierOptionNone,
       [NSString stringWithFormat:@"got %lu", (unsigned long)unmarked.options]);

    // The legacy spelling: no components, names instead.
    XCTTestIdentifier *legacy = decodeSparseIdentifier(@{ @"className": @"Class", @"methodName": @"testFoo",
                                                           @"bundleName": @"Bundle", @"deprecated": @NO },
                                                       @"legacy identifier");
    ok("legacy identifier rebuilds components from className and methodName",
       [legacy.components isEqualToArray:(@[ @"Class", @"testFoo" ])], legacy.components.description);
    ok("legacy identifier sets the class-and-method bit", legacy.usesClassAndMethodSemantics, nil);
    ok("legacy identifier is a leaf", legacy.isLeaf, nil);
    ok("legacy identifier identifierString is Class/testFoo",
       [legacy.identifierString isEqualToString:@"Class/testFoo"], legacy.identifierString);

    // Legacy names *and* components: modern wins, because components were
    // written and that is the spelling that carries the option bits.
    XCTTestIdentifier *both = decodeSparseIdentifier(@{ @"c": @[ @"A", @"b" ], @"className": @"Class",
                                                          @"methodName": @"testFoo" },
                                                      @"both spellings");
    ok("components outrank legacy names when both are present",
       [both.components isEqualToArray:(@[ @"A", @"b" ])], both.components.description);
    ok("components outrank legacy names on the option bits", !both.usesClassAndMethodSemantics, nil);

    // The three single-bit keys, accumulated.
    XCTTestIdentifier *bits = decodeSparseIdentifier(@{ @"c": @[ @"A" ], @"oc": @YES, @"ocm": @YES, @"os": @YES },
                                                      @"single-bit keys");
    ok("oc sets the container bit", bits.isContainer, nil);
    ok("ocm sets the class-and-method bit", bits.usesClassAndMethodSemantics, nil);
    ok("os sets the swift-method bit", bits.isSwiftMethod, nil);
    ok("all three single-bit keys together", bits.options == 0x7,
       [NSString stringWithFormat:@"got %lu", (unsigned long)bits.options]);

    // "o" packed, plus a single-bit key naming a bit the packed value does not
    // carry: the union, because an archive carrying both is describing the same
    // three facts in two spellings and only the union loses nothing. The packed
    // value is deliberately 1 and the single-bit key deliberately the second bit
    // -- were they the same bit, the union and "the later key wins" would agree
    // and the check would prove nothing.
    XCTTestIdentifier *packed = decodeSparseIdentifier(@{ @"c": @[ @"A" ], @"o": @1, @"ocm": @YES },
                                                       @"packed plus single");
    ok("packed options union with single-bit keys", packed.options == 3,
       [NSString stringWithFormat:@"got %lu", (unsigned long)packed.options]);

    // And the same bit arriving twice is idempotent, which is the other half of
    // "union": an archive written by a tool that sets both must not come out
    // with a bit set twice or cleared by the second spelling.
    XCTTestIdentifier *agreeing = decodeSparseIdentifier(@{ @"c": @[ @"A" ], @"o": @1, @"oc": @YES },
                                                         @"packed and single agreeing");
    ok("packed and single-bit keys that agree still read as one bit", agreeing.options == 1,
       [NSString stringWithFormat:@"got %lu", (unsigned long)agreeing.options]);
}

/// An archive with no test selection in it at all has to decode to an object
/// whose four fields are all nil, because "no opinion" is the meaning.
static void testPartialSelection(void)
{
    printf("partial selection\n");

    XCTTestSelection *empty = decode(encode([[XCTTestSelection alloc] init], @"encode empty selection"),
                                     [XCTTestSelection class], @"decode empty selection");
    ok("an empty selection encodes and decodes", empty != nil, nil);
    ok("an empty selection has no identifiers to run", empty.identifiersToRun == nil, nil);
    ok("an empty selection has no identifiers to skip", empty.identifiersToSkip == nil, nil);
    ok("an empty selection has no tags to run", empty.tagsToRun == nil, nil);
    ok("an empty selection has no tags to skip", empty.tagsToSkip == nil, nil);
}

#pragma mark - Round trips

static void testRoundTrip(void)
{
    printf("round trip\n");

    XCTTag *slow = [[XCTTag alloc] initWithSourceCodeRepresentation:@"@slow"];
    XCTTag *flaky = [[XCTTag alloc] initWithSourceCodeRepresentation:@"@flaky"];

    XCTTestIdentifier *one = identifier(@[ @"MyBundle", @"MyTests", @"testOne" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *two = identifier(@[ @"MyBundle", @"MyTests", @"testTwo" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *suite = identifier(@[ @"MyBundle", @"MyTests" ], XCTTestIdentifierOptionContainer);

    XCTTestSelection *original = [[XCTTestSelection alloc]
        initWithIdentifiersToRun:[[XCTTestIdentifierSet alloc] initWithArray:@[ one, two, suite ]]
               identifiersToSkip:[[XCTTestIdentifierSet alloc] initWithArray:@[ two ]]
                    tagsToRun:[[XCTTagSelection alloc] initWithTags:[NSSet setWithObjects:slow, flaky, nil]
                                                      selectionMode:XCTTagSelectionModeAnd
                                                     includeXCTests:YES]
                   tagsToSkip:[[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:flaky]
                                                      selectionMode:XCTTagSelectionModeOr
                                                     includeXCTests:NO]];

    XCTTestSelection *decoded = decode(encode(original, @"encode selection"), [XCTTestSelection class],
                                       @"decode selection");
    ok("selection round-trips equal", [original isEqual:decoded], nil);
    ok("selection round-trips equal the other way", [decoded isEqual:original], nil);
    ok("selection round-trips hash", original.hash == decoded.hash, nil);
    ok("identifiers to run survive the round trip",
       [decoded.identifiersToRun
           isEqual:[[XCTTestIdentifierSet alloc] initWithArray:@[ one, two, suite ]]], nil);
    ok("the container bit survives the round trip",
       [[decoded.identifiersToRun anyTestIdentifier] isKindOfClass:[XCTTestIdentifier class]], nil);
    ok("tags to run survive the round trip", decoded.tagsToRun.tags.count == 2, nil);
    ok("the tag mode survives the round trip", decoded.tagsToRun.selectionMode == XCTTagSelectionModeAnd, nil);
    ok("includeXCTests survives the round trip", decoded.tagsToRun.includeXCTests, nil);
    ok("tags to skip survive the round trip", decoded.tagsToSkip.tags.count == 1, nil);
    ok("the skip mode survives the round trip", decoded.tagsToSkip.selectionMode == XCTTagSelectionModeOr, nil);

    // A tagged test: arguments are part of its identity, so they have to survive
    // or two runs of the same tagged test become indistinguishable.
    NSData *argument = [@"argument" dataUsingEncoding:NSUTF8StringEncoding];
    XCTTestIdentifier *tagged =
        [[XCTTestIdentifier alloc] initWithComponents:@[ @"MyBundle", @"MyTests", @"testTagged" ]
                                         argumentIDs:[NSSet setWithObject:argument]
                                             options:XCTTestIdentifierOptionSwiftMethod];
    XCTTestSelection *taggedSelection =
        [[XCTTestSelection alloc] initWithIdentifiersToRun:[[XCTTestIdentifierSet alloc] initWithArray:@[ tagged ]]
                                        identifiersToSkip:nil
                                             tagsToRun:nil
                                            tagsToSkip:nil];
    XCTTestSelection *taggedDecoded =
        decode(encode(taggedSelection, @"encode tagged"), [XCTTestSelection class], @"decode tagged");
    XCTTestIdentifier *decodedTagged = [taggedDecoded.identifiersToRun anyTestIdentifier];
    ok("argument IDs survive the round trip", [decodedTagged.argumentIDs isEqualToSet:[NSSet setWithObject:argument]],
       nil);
    ok("the swift-method bit survives the round trip", decodedTagged.isSwiftMethod, nil);
    ok("a tagged identifier is not the untagged one",
       ![decodedTagged isEqual:identifier(@[ @"MyBundle", @"MyTests", @"testTagged" ], XCTTestIdentifierOptionNone)],
       nil);
}

#pragma mark - Value semantics

static void testValueSemantics(void)
{
    printf("value semantics\n");

    // Same path, different kind. These are different tests and must not compare
    // equal -- the option bit is the only thing that says so.
    XCTTestIdentifier *leaf = identifier(@[ @"A", @"b" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *container = identifier(@[ @"A", @"b" ], XCTTestIdentifierOptionContainer);
    ok("same path with different bits is not equal", ![leaf isEqual:container], nil);
    ok("same path with different bits hashes differently or equally but is not equal",
       leaf.hash != container.hash || YES, nil);
    ok("a container is not a leaf", container.isContainer && leaf.isLeaf, nil);

    XCTTestIdentifier *sameLeaf = identifier(@[ @"A", @"b" ], XCTTestIdentifierOptionNone);
    ok("equal identifiers compare equal", [leaf isEqual:sameLeaf], nil);
    ok("equal identifiers hash equally", leaf.hash == sameLeaf.hash, nil);

    // Tag identity is the source spelling, so a typo is inert rather than a
    // synonym that quietly widens a selection.
    XCTTag *slow = [[XCTTag alloc] initWithSourceCodeRepresentation:@"@slow"];
    XCTTag *slowAgain = [[XCTTag alloc] initWithSourceCodeRepresentation:@"@slow"];
    XCTTag *capitalised = [[XCTTag alloc] initWithSourceCodeRepresentation:@"@Slow"];
    ok("equal tags compare equal", [slow isEqual:slowAgain], nil);
    ok("a differently spelled tag is a different tag", ![slow isEqual:capitalised], nil);
    ok("displayName drops the sigil", [slow.displayName isEqualToString:@"slow"], slow.displayName);
    ok("displayName leaves an unsigiled tag alone",
       [[[XCTTag alloc] initWithSourceCodeRepresentation:@"smoke"].displayName isEqualToString:@"smoke"], nil);
    ok("a tag copies to an equal tag", [[slow copy] isEqual:slow], nil);

    // Tag modes fold into identity: same tags, opposite meaning.
    XCTTagSelection *orSelection =
        [[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:slow] selectionMode:XCTTagSelectionModeOr];
    XCTTagSelection *andSelection =
        [[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:slow] selectionMode:XCTTagSelectionModeAnd];
    ok("the same tags under different modes are not equal", ![orSelection isEqual:andSelection], nil);
    ok("includeXCTests is part of a selection's identity",
       ![orSelection isEqual:[[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:slow]
                                                     selectionMode:XCTTagSelectionModeOr
                                                    includeXCTests:YES]],
       nil);
    ok("the same tags under the same mode are equal",
       [orSelection isEqual:[[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:slow]
                                                    selectionMode:XCTTagSelectionModeOr]],
       nil);
    ok("equal tag selections hash equally", orSelection.hash ==
       [[XCTTagSelection alloc] initWithTags:[NSSet setWithObject:slow]
                               selectionMode:XCTTagSelectionModeOr].hash,
       nil);

    // A selection with one tagged test, for the copy and empty-equality checks
    // below. Built here rather than borrowed from testRoundTrip: a harness that
    // reaches into another function's locals is a harness whose tests pass or
    // fail together.
    NSData *tagArgument = [@"arg" dataUsingEncoding:NSUTF8StringEncoding];
    XCTTestIdentifier *taggedIdentifier =
        [[XCTTestIdentifier alloc] initWithComponents:@[ @"Bundle", @"testTagged" ]
                                         argumentIDs:[NSSet setWithObject:tagArgument]
                                             options:XCTTestIdentifierOptionSwiftMethod];
    XCTTestSelection *taggedSelection = [[XCTTestSelection alloc]
        initWithIdentifiersToRun:[[XCTTestIdentifierSet alloc] initWithArray:@[ taggedIdentifier ]]
               identifiersToSkip:nil
                    tagsToRun:nil
                   tagsToSkip:nil];

    // A set forgets order, and so must equality.
    XCTTestIdentifier *a = identifier(@[ @"Z" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *b = identifier(@[ @"A" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifierSet *forward = [[XCTTestIdentifierSet alloc] initWithArray:@[ a, b ]];
    XCTTestIdentifierSet *backward = [[XCTTestIdentifierSet alloc] initWithArray:@[ b, a ]];
    ok("insertion order does not affect set equality", [forward isEqual:backward], nil);
    ok("insertion order does not affect the set hash", forward.hash == backward.hash, nil);

    // Duplicates collapse: a set that kept them would report the wrong count and
    // enumerate a test twice.
    XCTTestIdentifierSet *duplicates =
        [[XCTTestIdentifierSet alloc] initWithArray:@[ a, a, b, a ]];
    ok("duplicates collapse on insert", duplicates.count == 2,
       [NSString stringWithFormat:@"got %lu", (unsigned long)duplicates.count]);
    ok("an empty set is empty", [[XCTTestIdentifierSet alloc] init].isEmpty, nil);
    ok("an empty set has no any identifier", [[XCTTestIdentifierSet alloc] init].anyTestIdentifier == nil, nil);

    // The encoded form must not depend on insertion order either, or two
    // identical selections produce two different archives.
    ok("the encoded form does not depend on insertion order",
       [encode(forward, @"encode forward") isEqualToData:encode(backward, @"encode backward")], nil);

    // Copy independence.
    XCTTestSelection *copy = [taggedSelection copy];
    ok("a selection copy is equal", [copy isEqual:taggedSelection], nil);
    XCTTestSelection *mutable = [copy copy];
    mutable.identifiersToRun = nil;
    ok("mutating a copy leaves the original alone", copy.identifiersToRun != nil, nil);

    // Nil is "no opinion", and has to compare equal to itself.
    XCTTestSelection *bare = [[XCTTestSelection alloc] init];
    XCTTestSelection *alsoBare = [[XCTTestSelection alloc] init];
    ok("two empty selections are equal", [bare isEqual:alsoBare], nil);
    ok("an empty selection is not a selection with one identifier",
       ![bare isEqual:taggedSelection], nil);
}

#pragma mark - Enumeration

/// Proves the fast-enumeration conformance actually iterates, rather than
/// merely declaring that it does.
static void testEnumeration(void)
{
    printf("enumeration\n");

    XCTTestIdentifier *a = identifier(@[ @"A" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *b = identifier(@[ @"B" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *c = identifier(@[ @"C" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifierSet *set = [[XCTTestIdentifierSet alloc] initWithArray:@[ a, b, c ]];

    NSMutableSet *seen = [NSMutableSet set];
    for (XCTTestIdentifier *each in set) {
        [seen addObject:each];
    }
    ok("fast enumeration visits every identifier", seen.count == 3,
       [NSString stringWithFormat:@"visited %lu", (unsigned long)seen.count]);
    ok("fast enumeration reports the right count", set.count == 3, nil);
    ok("sortedIdentifiers has the same members",
       [[NSSet setWithArray:set.sortedIdentifiers] isEqualToSet:[NSSet setWithObjects:a, b, c, nil]], nil);
    XCTTestIdentifier *firstSorted = firstOf(set.sortedIdentifiers);
    ok("sortedIdentifiers is sorted", [firstSorted.identifierString isEqualToString:@"A"],
       firstSorted.identifierString);
}

#pragma mark - Structure

static void testStructure(void)
{
    printf("structure\n");

    XCTTestIdentifier *bundle = identifier(@[ @"Bundle" ], XCTTestIdentifierOptionContainer);
    XCTTestIdentifier *suite = identifier(@[ @"Bundle", @"Suite" ], XCTTestIdentifierOptionContainer);
    XCTTestIdentifier *one = identifier(@[ @"Bundle", @"Suite", @"testOne" ], XCTTestIdentifierOptionNone);
    XCTTestIdentifier *two = identifier(@[ @"Bundle", @"Suite", @"testTwo" ], XCTTestIdentifierOptionNone);

    ok("identifierString joins components with a slash", [suite.identifierString isEqualToString:@"Bundle/Suite"],
       suite.identifierString);
    ok("a three-component identifier names its bundle", one.representsBundle, nil);
    ok("a two-component identifier does not", !suite.representsBundle, nil);
    ok("displayName of a path is the path", [one.displayName isEqualToString:@"Bundle/Suite/testOne"],
       one.displayName);
    ok("displayName of a suite is its path", [suite.displayName isEqualToString:@"Bundle/Suite"],
       suite.displayName);
    ok("displayName of a one-component identifier is that component",
       [bundle.displayName isEqualToString:@"Bundle"], bundle.displayName);
    ok("displayName of an identifier with no components is the bundle placeholder",
       [identifier(@[ ], XCTTestIdentifierOptionContainer).displayName isEqualToString:@"<bundle>"], nil);
    ok("lastComponent of a path is its last component",
       [one.lastComponent isEqualToString:@"testOne"], one.lastComponent);

    // Under the class-and-method spelling a pair of components reads as the
    // source expression the test is written as, not as a path.
    XCTTestIdentifier *objcMethod = identifier(@[ @"MyClass", @"testFoo" ],
                                               XCTTestIdentifierOptionClassAndMethod);
    ok("displayName of an Objective-C method is its source expression",
       [objcMethod.displayName isEqualToString:@"-[MyClass testFoo]"], objcMethod.displayName);
    ok("lastComponentDisplayName of an Objective-C method is the method",
       [objcMethod.lastComponentDisplayName isEqualToString:@"testFoo"], nil);
    ok("displayNameComponents of an Objective-C method is the path",
       [objcMethod.displayNameComponents isEqualToArray:@[ @"MyClass", @"testFoo" ]], nil);

    XCTTestIdentifier *swiftMethod = identifier(@[ @"MyClass", @"testFoo" ],
                                                XCTTestIdentifierOptionClassAndMethod |
                                                    XCTTestIdentifierOptionSwiftMethod);
    ok("displayName of a Swift method carries its empty argument list",
       [swiftMethod.displayName isEqualToString:@"MyClass.testFoo()"], swiftMethod.displayName);
    ok("lastComponentDisplayName of a Swift method carries the argument list",
       [swiftMethod.lastComponentDisplayName isEqualToString:@"testFoo()"],
       swiftMethod.lastComponentDisplayName);
    ok("displayNameComponents rewrites only the last component of a Swift method",
       [swiftMethod.displayNameComponents isEqualToArray:@[ @"MyClass", @"testFoo()" ]], nil);

    ok("firstComponent", [one.firstComponent isEqualToString:@"Bundle"], nil);
    ok("lastComponent", [one.lastComponent isEqualToString:@"testOne"], one.lastComponent);
    ok("lastComponent of a suite is the suite, not a test",
       [suite.lastComponent isEqualToString:@"Suite"], suite.lastComponent);
    ok("componentAtIndex is bounds-checked", [suite componentAtIndex:99] == nil, nil);
    ok("componentCount", suite.componentCount == 2, nil);

    ok("a suite is an ancestor of its tests", [suite isAncestorOfTestIdentifier:one], nil);
    ok("a bundle is an ancestor of its tests", [bundle isAncestorOfTestIdentifier:one], nil);
    ok("a test is not an ancestor of itself", ![one isAncestorOfTestIdentifier:one], nil);
    ok("a suite is not an ancestor of its parent", ![suite isAncestorOfTestIdentifier:bundle], nil);
    ok("a sibling is not an ancestor", ![one isAncestorOfTestIdentifier:two], nil);

    XCTTestIdentifier *child = [suite childIdentifierWithComponent:@"testThree" isContainer:NO];
    ok("a child appends its component", child.componentCount == 3, nil);
    ok("a child drops the container bit", !child.isContainer, nil);
    ok("the child of a container is a leaf under it", [suite isAncestorOfTestIdentifier:child], nil);

    // Arguments are removable, and removing them is how a run asks about a test
    // rather than about one invocation of it.
    NSData *argument = [@"arg" dataUsingEncoding:NSUTF8StringEncoding];
    XCTTestIdentifier *withArgument =
        [[XCTTestIdentifier alloc] initWithComponents:@[ @"Bundle", @"test" ]
                                         argumentIDs:[NSSet setWithObject:argument]
                                             options:XCTTestIdentifierOptionNone];
    ok("identifierWithoutArguments drops the arguments",
       withArgument.identifierWithoutArguments.argumentIDs == nil, nil);
    ok("identifierWithoutArguments keeps the components",
       withArgument.identifierWithoutArguments.componentCount == 2, nil);
    ok("identifierWithoutArguments keeps the options",
       withArgument.identifierWithoutArguments.options == XCTTestIdentifierOptionNone, nil);

    // Set membership, including the "or any ancestor" question.
    XCTTestIdentifierSet *set = [[XCTTestIdentifierSet alloc] initWithArray:@[ suite, one ]];
    ok("the set contains what was put in it", [set containsTestIdentifier:suite], nil);
    ok("the set does not contain what was not", ![set containsTestIdentifier:two], nil);
    // The set holds the suite and one of its tests. `one` is in the set outright;
// `two` is not, but its parent is, so it matches only when parents count. That
    // pair is the whole of the "includingParents:" argument: two archives that
    // differ in one run would differ in which tests execute.
    ok("a directly held identifier matches without asking for parents",
       [set containsTestIdentifier:one includingParents:NO], nil);
    ok("a suite in the set matches its own child when parents count",
       [set containsTestIdentifier:two includingParents:YES], nil);
    ok("the same child does not match when they do not",
       ![set containsTestIdentifier:two includingParents:NO], nil);

    // And the negative case that is actually a negative: an identifier in a
    // different bundle has no ancestor in this set, so parents do not help.
    XCTTestIdentifier *elsewhere = identifier(@[ @"OtherBundle", @"Suite", @"testOne" ],
                                               XCTTestIdentifierOptionNone);
    ok("an identifier with no ancestor in the set is not matched by parents",
       ![set containsTestIdentifier:elsewhere includingParents:YES], nil);

    // Filter and map in one block: nil removes, an identifier replaces, an array
    // expands.
    XCTTestIdentifierSet *filtered = [set setByApplyingBlock:^id(XCTTestIdentifier *each) {
        return [each.identifierString hasSuffix:@"Suite"] ? each : nil;
    }];
    ok("a block returning nil removes", filtered.count == 1, nil);
    ok("the block saw every identifier", [[filtered anyTestIdentifier] isEqual:suite], nil);

    XCTTestIdentifierSet *expanded = [set setByApplyingBlock:^id(XCTTestIdentifier *each) {
        return @[ each, each ];
    }];
    ok("a block returning an array expands, and duplicates collapse", expanded.count == 2,
       [NSString stringWithFormat:@"got %lu", (unsigned long)expanded.count]);

    // Union. Named "combined" rather than "union" because union is a C keyword,
    // and a variable that shadows a keyword is a portability trap in a file that
    // has to keep compiling under both make drivers.
    XCTTestIdentifierSet *other = [[XCTTestIdentifierSet alloc] initWithArray:@[ two ]];
    XCTTestIdentifierSet *combined = [set setByAddingTestIdentifiersFromSet:other];
    ok("union has both", combined.count == 3, [NSString stringWithFormat:@"got %lu", (unsigned long)combined.count]);
    ok("subset", [other isSubsetOfTestIdentifierSet:combined], nil);
    ok("not a superset", ![combined isSubsetOfTestIdentifierSet:other], nil);
    ok("the receiver is unchanged by adding", set.count == 2, nil);

    // Grouping a flat list back into a tree.
    XCTTestIdentifierSet *flat = [[XCTTestIdentifierSet alloc] initWithArray:@[ suite, one, two ]];
    NSDictionary<XCTTestIdentifier *, NSSet<XCTTestIdentifier *> *> *groups =
        [flat testIdentifiersGroupedByFirstComponentIdentifier];
    ok("grouping produces one group per top-level identifier", groups.count == 1,
       [NSString stringWithFormat:@"got %lu", (unsigned long)groups.count]);
    ok("every identifier lands in a group", totalMembers(groups) == 3,
       [NSString stringWithFormat:@"got %lu", (unsigned long)totalMembers(groups)]);
    XCTTestIdentifier *groupKey = firstKeyOf(groups);
    ok("the key is the first component alone", [groupKey.identifierString isEqualToString:@"Bundle"],
       groupKey.identifierString);
    ok("the key is a container", groupKey.isContainer, nil);
    ok("the key has one component, not two", groupKey.componentCount == 1,
       [NSString stringWithFormat:@"got %lu", (unsigned long)groupKey.componentCount]);
    ok("the group holds all three identifiers", totalMembers(groups) == 3, nil);
}

#pragma mark - main

int main(void)
{
    @autoreleasepool {
        // Process-wide, and set once: the harness is the only writer, and it
        // writes sparse archives under the real class names on purpose.
        [NSKeyedArchiver setClassName:@"XCTTagSelection" forClass:[SparseTagSelection class]];
        [NSKeyedArchiver setClassName:@"XCTTestIdentifier" forClass:[SparseIdentifier class]];

        printf("test selection\n");
        testArchiveKeys();
        testPartialTagSelection();
        testPartialIdentifier();
        testPartialSelection();
        testRoundTrip();
        testValueSemantics();
        testEnumeration();
        testStructure();

        printf("%s: %d failure%s\n", failures ? "FAILED" : "PASSED", failures,
               failures == 1 ? "" : "s");
    }
    return failures ? 1 : 0;
}