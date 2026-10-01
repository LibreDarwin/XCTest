// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for the enumeration value types and the execution protocol.
//
// The framework has no runner of its own yet, so these are the only thing that
// exercises the run-session surface, and they are worth a file for one reason
// above all: almost everything interesting about these two types is invisible
// to a round trip, because the interesting part is what the *encoder and
// decoder* do when the two disagree with each other's defaults.
//
//   -initWithCoder: on the options rejects an archive in which neither flag is
//   set. Both flags decode to NO when their key is absent, and NO/NO is refused
//   outright rather than decoded into an object that requests nothing. So the
//   value -init produces cannot be archived at all, and a round trip of it is
//   not a fixed point. No round-trip test can see that; a decoder handed a
//   hand-built archive can.
//
//   The result behaves the opposite way, and the asymmetry is the point: nil is
//   a value its two keys can carry, so a result that declined both views
//   archives and comes back declined. One type refuses its own default and the
//   other keeps it, and which one a caller gets decides whether "no such
//   request" is representable.
//
//   The options' two flags are plist booleans, not NSNumbers. -decodeBoolForKey:
//   accepts either, so a reader cannot tell the two apart -- which is exactly
//   why the check below reads the archive as a property list and looks at the
//   stored type, rather than going through a codec that would hide it.
//
//   -description has no closing parenthesis, and prints its booleans in lower
//   case. Both are asserted against exact strings, including the missing
//   character, because the alternative is that the next reader "fixes" it and
//   the divergence from the reference becomes invisible.
//
// The protocol is exercised by conforming a stub to it, which is the check that
// its two block signatures are spelled correctly: a wrong spelling is a
// compile error here rather than a mismatch discovered when a caller tries to
// implement it.
//
// Not exercised: XCTTestRunSession itself, which is not written yet -- see the
// header for the five things it calls that have to land first.
#import <XCTestCore/XCTTestRunSession.h>

#import <Foundation/Foundation.h>
// Not pulled in by the reduced <Foundation/Foundation.h>, and this harness is
// built on keyed coding and on property lists.
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSPropertyList.h>

#import <CoreFoundation/CoreFoundation.h>

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

static id decode(NSData *data, Class cls, NSString *why)
{
    NSError *error = nil;
    id decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:cls fromData:data error:&error];
    if (!decoded) {
        ok(why.UTF8String, NO, [NSString stringWithFormat:@"decode failed: %@", error]);
    }
    return decoded;
}

/// Decodes an archive that is *expected* to yield no object, for a stated
/// reason.
///
/// The nil here is not a failure to decode; it is the answer. Pinning the error
/// code is what keeps the distinction meaningful, because "the class refused"
/// and "the archive was not readable" are both nil, and only the first is what
/// the class is being asked to do. Two things are reported: an object arriving
/// when none should have, and an error other than the expected one.
static id decodeRefusing(NSData *data, Class cls, NSInteger expectedCode, NSString *why)
{
    if (!data) {
        return nil;
    }
    NSError *error = nil;
    id decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:cls fromData:data error:&error];
    if (decoded) {
        ok(why.UTF8String, NO, @"expected the archive to be refused, got an object");
    } else if (!error || error.code != expectedCode) {
        ok(why.UTF8String, NO,
           [NSString stringWithFormat:@"expected rejection %ld, got: %@", (long)expectedCode,
                                      error]);
    }
    return decoded;
}

/// The value the archive stored under `key`, read as a property list rather than
/// through a codec.
///
/// The reason this exists is that a keyed archive stores a non-object value
/// *inline* in the entry that owns it, so the plist can be asked directly what
/// type was written. Going through -decodeBoolForKey: cannot answer that, since
/// it accepts a boolean and an integer alike and reports the same thing for
/// both. Returns nil when the key was not written at all, which is the
/// distinction this whole file keeps needing.
static id rawArchivedValue(NSData *data, NSString *key, NSString *why)
{
    if (!data) {
        return nil;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListImmutable
                                                         format:NULL
                                                          error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        ok(why.UTF8String, NO, @"archive is not a property list");
        return nil;
    }
    id objects = [[plist objectForKey:@"$objects"] copy];
    if (![objects isKindOfClass:[NSArray class]]) {
        ok(why.UTF8String, NO, @"archive has no $objects array");
        return nil;
    }
    for (id entry in objects) {
        if ([entry isKindOfClass:[NSDictionary class]] && [entry objectForKey:key] != nil) {
            return [entry objectForKey:key];
        }
    }
    return nil;
}

/// Whether a value read out of an archive was written as a plist boolean rather
/// than as a plist integer. Both are toll-free NSNumbers and both are
/// indistinguishable to -decodeBoolForKey:, which is why the archive is read
/// this way rather than through the coder.
static BOOL isPlistBoolean(id value)
{
    if (!value) {
        return NO;
    }
    return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static XCTTestIdentifier *identifier(NSString *component)
{
    return [[XCTTestIdentifier alloc] initWithComponents:@[ component ]
                                              argumentIDs:nil
                                                  options:XCTTestIdentifierOptionNone];
}

#pragma mark - Sparse archives

/// The keys a sparse writer should write, and only those.
///
/// File-scope for the same reason the selection harness uses one: the encoder
/// is called by the archiver, not by us, so the key list cannot be threaded
/// through -encodeWithCoder:.
static NSDictionary *sparseKeys = nil;

/// Writes an options archive carrying only `values`.
///
/// Foundation writes each key the way the real writer writes it, including the
/// boolean encoding, and the archive names *this* subclass -- there is no class
/// remapping involved. It is still read back as XCTTestEnumerationOptions
/// because -unarchivedObjectOfClasses:fromData:error: accepts a subclass of the
/// class it was given, and this one overrides only the writing side. The real
/// -initWithCoder: is therefore what answers on the way back in, which is the
/// whole point: the refusal under test is the real class's, not a stand-in's.
@interface SparseOptions : XCTTestEnumerationOptions
@end

@implementation SparseOptions
- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *key in sparseKeys) {
        [coder encodeBool:[[sparseKeys objectForKey:key] boolValue] forKey:key];
    }
}
@end

static XCTTestEnumerationOptions *decodeSparseOptions(NSDictionary *values, NSString *why)
{
    sparseKeys = values;
    NSData *data = encode([[SparseOptions alloc] init], why);
    sparseKeys = nil;
    return decode(data, [XCTTestEnumerationOptions class], why);
}

/// As -decodeSparseOptions, for the archives the class is expected to refuse.
static XCTTestEnumerationOptions *decodeSparseOptionsRefusing(NSDictionary *values, NSString *why)
{
    sparseKeys = values;
    NSData *data = encode([[SparseOptions alloc] init], why);
    sparseKeys = nil;
    return decodeRefusing(data, [XCTTestEnumerationOptions class], NSCoderValueNotFoundError, why);
}

/// An options writer that stores an integer under a flag key, to prove the flag
/// is stored as a boolean and not merely *read* as one.
@interface IntegerOptions : XCTTestEnumerationOptions
@end

@implementation IntegerOptions
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:1 forKey:@"includeAllTestIdentifiers"];
}
@end

#pragma mark - Options: values

static void testOptionsValues(void)
{
    printf("options values\n");

    XCTTestEnumerationOptions *fresh = [[XCTTestEnumerationOptions alloc] init];
    ok("a fresh options object asks for nothing", !fresh.includeAllTestIdentifiers, nil);
    ok("and for no parallelizable groups either",
       !fresh.includeParallelizableTestIdentifierGroups, nil);

    // The two flags are a pair of independent booleans, not a mode. All four
    // combinations are reachable, and the two "one flag" cases are the ones a
    // three-state enum would have got wrong.
    struct {
        BOOL all;
        BOOL parallelizable;
        const char *label;
    } cases[] = {
        { NO,  NO,  "neither" },
        { YES, NO,  "identifiers only" },
        { NO,  YES, "groups only" },
        { YES, YES, "both" },
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        XCTTestEnumerationOptions *options =
            [[XCTTestEnumerationOptions alloc]
                initWithIncludeAllTestIdentifiers:cases[i].all
              includeParallelizableTestIdentifierGroups:cases[i].parallelizable];
        ok(cases[i].label,
           options.includeAllTestIdentifiers == cases[i].all &&
           options.includeParallelizableTestIdentifierGroups == cases[i].parallelizable,
           nil);
    }
}

#pragma mark - Options: archive keys

static void testOptionsArchiveKeys(void)
{
    printf("options archive keys\n");

    NSData *data = encode([[XCTTestEnumerationOptions alloc]
                              initWithIncludeAllTestIdentifiers:YES
                              includeParallelizableTestIdentifierGroups:NO],
                          @"encode both flags");
    ok("the all-identifiers key is written",
       rawArchivedValue(data, @"includeAllTestIdentifiers", @"keys") != nil, nil);
    ok("the parallelizable-groups key is written",
       rawArchivedValue(data, @"includeParallelizableTestIdentifierGroups", @"keys") != nil, nil);
    ok("no third key is written",
       rawArchivedValue(data, @"includeAllTestIdentifierGroups", @"keys") == nil, nil);

    // A plist boolean is not a matter of taste here. -decodeBoolForKey: rejects a
    // plain integer outright, so the type this class writes is the type its own
    // reader demands: an archive whose flags are numbers is unreadable, not
    // merely unusual. That is checked from the other side below, because it is
    // the failure the check above exists to prevent.
    ok("the flag is stored as a plist boolean",
       isPlistBoolean(rawArchivedValue(data, @"includeAllTestIdentifiers", @"type")), nil);
    ok("the parallelizable flag is stored as a plist boolean",
       isPlistBoolean(rawArchivedValue(data, @"includeParallelizableTestIdentifierGroups",
                                       @"type")),
        nil);

    // Note which code this is *not*: NSCoderReadIncompatibleArchiveError looks
    // like the right name for a wrongly typed value, but it shares its value
    // (4865) with NSCoderValueNotFoundError, which is the refusal from above. A
    // flag of the wrong type is reported as NSCoderReadCorruptError (4864), so
    // pinning the number is the only way to tell the two rejections apart.
    NSData *integerForm = encode([[IntegerOptions alloc] init], @"integer form");
    XCTTestEnumerationOptions *rejected = decodeRefusing(integerForm, [XCTTestEnumerationOptions class],
                                                        NSCoderReadCorruptError,
                                                        @"integer form rejected");
    ok("a flag stored as an integer is refused, not coerced", rejected == nil, nil);
}

#pragma mark - Options: partial archives

static void testOptionsPartialArchive(void)
{
    printf("options partial archives\n");

    // One flag present, the other absent. The absent one decodes to NO, and the
    // object survives because the other one is YES.
    XCTTestEnumerationOptions *allOnly =
        decodeSparseOptions(@{ @"includeAllTestIdentifiers": @YES }, @"all only");
    ok("an archive with one flag decodes to an object", allOnly != nil, nil);
    ok("the present flag comes back set", allOnly.includeAllTestIdentifiers, nil);
    ok("the absent flag comes back NO", !allOnly.includeParallelizableTestIdentifierGroups, nil);

    XCTTestEnumerationOptions *groupsOnly =
        decodeSparseOptions(@{ @"includeParallelizableTestIdentifierGroups": @YES }, @"groups only");
    ok("the mirror-image archive also decodes", groupsOnly != nil, nil);
    ok("and it is not the same answer as the first",
       allOnly.includeAllTestIdentifiers != groupsOnly.includeAllTestIdentifiers, nil);

    XCTTestEnumerationOptions *both =
        decodeSparseOptions(@{ @"includeAllTestIdentifiers": @YES,
                               @"includeParallelizableTestIdentifierGroups": @YES }, @"both");
    ok("both flags present decodes with both set",
       both.includeAllTestIdentifiers && both.includeParallelizableTestIdentifierGroups, nil);

    // The two archives below are the reason this file exists. They differ from
    // the one above by one key's *value*, and the decoder's answer changes from
    // an object to nil -- which is a distinction no caller can make by asking
    // the object what it contains, because there is no object to ask.
    XCTTestEnumerationOptions *allNo =
        decodeSparseOptionsRefusing(@{ @"includeAllTestIdentifiers": @NO,
                                       @"includeParallelizableTestIdentifierGroups": @NO },
                                    @"both NO");
    ok("both flags present and false decodes to nil", allNo == nil, nil);

    XCTTestEnumerationOptions *neither =
        decodeSparseOptionsRefusing(@{}, @"no keys");
    ok("an archive with neither key decodes to nil", neither == nil, nil);

    // Asserting the relationship is what makes this a test rather than two
    // unrelated ones: the empty archive and the all-false archive have different
    // bytes, and the reference refuses both.
    ok("the two empty requests are refused alike", allNo == nil && neither == nil, nil);

    // The consequence, stated as a test: the value -init produces is the one
    // value of this type that cannot be archived. A round trip returns nil, and
    // the round trip is not a fixed point.
    NSData *fresh = encode([[XCTTestEnumerationOptions alloc] init], @"fresh options");
    XCTTestEnumerationOptions *reborn = decodeRefusing(fresh, [XCTTestEnumerationOptions class],
                                                      NSCoderValueNotFoundError, @"fresh options");
    ok("a fresh options object does not survive its own archive", reborn == nil, nil);
}

#pragma mark - Options: description

static void testOptionsDescription(void)
{
    printf("options description\n");

    // The exact reference string, parenthesis and all. The four cases differ
    // only in the two booleans, and they are written out rather than built from
    // a pattern so that a change to the wording has to be made here.
    XCTTestEnumerationOptions *fresh = [[XCTTestEnumerationOptions alloc] init];
    ok("neither flag",
       [fresh.description isEqualToString:
           @"XCTTestEnumerationOptions(includeAllTestIdentifiers: false, "
           @"includeParallelizableTestIdentifierGroups: false"],
       fresh.description);

    XCTTestEnumerationOptions *allOnly =
        [[XCTTestEnumerationOptions alloc] initWithIncludeAllTestIdentifiers:YES
                                includeParallelizableTestIdentifierGroups:NO];
    ok("identifiers only",
       [allOnly.description isEqualToString:
           @"XCTTestEnumerationOptions(includeAllTestIdentifiers: true, "
           @"includeParallelizableTestIdentifierGroups: false"],
       allOnly.description);

    XCTTestEnumerationOptions *groupsOnly =
        [[XCTTestEnumerationOptions alloc] initWithIncludeAllTestIdentifiers:NO
                                includeParallelizableTestIdentifierGroups:YES];
    ok("groups only",
       [groupsOnly.description isEqualToString:
           @"XCTTestEnumerationOptions(includeAllTestIdentifiers: false, "
           @"includeParallelizableTestIdentifierGroups: true"],
       groupsOnly.description);

    XCTTestEnumerationOptions *both =
        [[XCTTestEnumerationOptions alloc] initWithIncludeAllTestIdentifiers:YES
                                includeParallelizableTestIdentifierGroups:YES];
    ok("both flags",
       [both.description isEqualToString:
           @"XCTTestEnumerationOptions(includeAllTestIdentifiers: true, "
           @"includeParallelizableTestIdentifierGroups: true"],
       both.description);

    // The two properties that separate this from an ordinary -description: the
    // booleans are lower case rather than 1/0, and there is no closing
    // parenthesis. Asserted separately as well as inside the strings above, so
    // that the reason each one is there is not only in a comment.
    ok("the description opens a parenthesis it never closes",
       [allOnly.description hasPrefix:@"XCTTestEnumerationOptions("] &&
           ![allOnly.description hasSuffix:@")"],
       nil);
    ok("booleans are spelled, not numbered",
       [allOnly.description rangeOfString:@": 1,"].location == NSNotFound &&
           [allOnly.description rangeOfString:@": true,"].location != NSNotFound,
       nil);
}

#pragma mark - Result: values and archives

static void testResult(void)
{
    printf("result values and archives\n");

    XCTTestEnumerationResult *fresh = [[XCTTestEnumerationResult alloc] init];
    ok("a fresh result has no identifier set", fresh.allTestIdentifiers == nil, nil);
    ok("and no groups", fresh.parallelizableTestIdentifierGroups == nil, nil);

    XCTTestIdentifierSet *identifiers =
        [[XCTTestIdentifierSet alloc] initWithArray:@[ identifier(@"MyTests") ]];
    NSArray *groups = @[ [NSSet setWithObject:identifier(@"MyTests")] ];
    XCTTestEnumerationResult *result =
        [[XCTTestEnumerationResult alloc] initWithAllTestIdentifiers:identifiers
                                        parallelizableTestIdentifierGroups:groups];
    ok("the identifier set is the one it was given",
       result.allTestIdentifiers == identifiers, nil);
    ok("the grouping is the one it was given",
       result.parallelizableTestIdentifierGroups == groups, nil);

    // Pointer identity, deliberately: the result shares the caller's objects
    // rather than snapshotting them, and a copy would be a stronger promise
    // than the reference makes.
    ok("the identifier set is shared, not copied", result.allTestIdentifiers == identifiers, nil);

    NSData *data = encode(result, @"encode result");
    ok("the all-identifiers key is written",
       rawArchivedValue(data, @"allTestIdentifiers", @"result keys") != nil, nil);
    ok("the groups key is written",
       rawArchivedValue(data, @"parallelizableTestIdentifierGroups", @"result keys") != nil, nil);

    XCTTestEnumerationResult *reborn = decode(data, [XCTTestEnumerationResult class],
                                              @"decode result");
    ok("a result round trips", reborn != nil, nil);
    ok("the identifier set survives", reborn.allTestIdentifiers.count == 1, nil);
    ok("the grouping survives", reborn.parallelizableTestIdentifierGroups.count == 1, nil);

    // The asymmetry with the options, asserted rather than left to the comments.
    // Both types have an -init that produces their "nothing asked for" value; one
    // of them refuses to read that value back and the other keeps it, and which
    // one it is decides whether "no such request" survives a round trip.
    NSData *emptyResult = encode(fresh, @"encode fresh result");
    XCTTestEnumerationResult *emptyReborn = decode(emptyResult, [XCTTestEnumerationResult class],
                                                   @"decode fresh result");
    ok("a result that declined both views does survive its own archive",
       emptyReborn != nil, nil);
    ok("and comes back still declining both",
       emptyReborn.allTestIdentifiers == nil &&
           emptyReborn.parallelizableTestIdentifierGroups == nil,
       nil);

    // A result carrying one view only: the other key is absent, and absent has
    // to mean nil rather than an empty object standing in for one.
    XCTTestEnumerationResult *half =
        [[XCTTestEnumerationResult alloc] initWithAllTestIdentifiers:identifiers
                                        parallelizableTestIdentifierGroups:nil];
    XCTTestEnumerationResult *halfReborn = decode(encode(half, @"encode half"),
                                                  [XCTTestEnumerationResult class],
                                                  @"decode half");
    ok("a half result keeps its identifier set",
       halfReborn.allTestIdentifiers.count == 1, nil);
    ok("and leaves the groups key absent rather than empty",
       halfReborn.parallelizableTestIdentifierGroups == nil, nil);
}

#pragma mark - Protocol

/// Conforms to the protocol and implements only the required half, so that the
/// optional enumeration method's absence is something the runtime can be asked
/// about.
@interface MinimalExtension : NSObject <XCTExecutionExtension>
@property (nonatomic, copy) NSError *lastError;
@property (nonatomic, assign) BOOL sawSkipList;
@end

@implementation MinimalExtension

- (void)executeTestsWithIdentifiers:(XCTTestIdentifierSet *)identifiersToRun
         skippingTestsWithIdentifiers:(XCTTestIdentifierSet *)identifiersToSkip
                         completion:(void (^)(NSError *_Nullable, dispatch_queue_t))completion
{
    _sawSkipList = (identifiersToSkip != nil);
    _lastError = nil;
    completion(nil, dispatch_get_main_queue());
}

@end

/// Implements both halves, to prove the optional method's signature is the one
/// the protocol declares and not merely a selector that happens to match.
@interface FullExtension : MinimalExtension
@property (nonatomic, copy) XCTTestEnumerationResult *lastResult;
@end

@implementation FullExtension

- (void)enumerateTestsWithOptions:(XCTTestEnumerationOptions *)options
                       completion:(void (^)(XCTTestEnumerationResult *_Nullable, NSError *_Nullable))completion
{
    _lastResult = [[XCTTestEnumerationResult alloc] init];
    completion(_lastResult, nil);
}

@end

static void testProtocol(void)
{
    printf("execution protocol\n");

    // The required method is the whole contract, so a conformer that implements
    // only it is a complete XCTExecutionExtension.
    ok("executing is the only required method",
       [MinimalExtension instancesRespondToSelector:
           @selector(executeTestsWithIdentifiers:skippingTestsWithIdentifiers:completion:)],
       nil);
    ok("enumerating is optional, and is absent from a minimal conformer",
       ![MinimalExtension instancesRespondToSelector:
           @selector(enumerateTestsWithOptions:completion:)],
       nil);
    ok("a full conformer implements it",
       [FullExtension instancesRespondToSelector:
           @selector(enumerateTestsWithOptions:completion:)],
       nil);

    // And the two block shapes are usable as declared -- a mismatch here is a
    // compile error, which is the point of spelling them out in a conformer.
    MinimalExtension *minimal = [[MinimalExtension alloc] init];
    __block BOOL called = NO;
    [minimal executeTestsWithIdentifiers:[[XCTTestIdentifierSet alloc] init]
               skippingTestsWithIdentifiers:nil
                               completion:^(NSError *error, dispatch_queue_t queue) {
                                   called = YES;
                                   ok("the completion receives a nil error on success",
                                      error == nil, nil);
                                   ok("and a usable queue", queue != nil, nil);
                               }];
    ok("the completion is called", called, nil);
    ok("a nil skip list reads as absent, not as present-and-empty",
       !minimal.sawSkipList, nil);

    FullExtension *full = [[FullExtension alloc] init];
    __block XCTTestEnumerationResult *received = nil;
    [full enumerateTestsWithOptions:[[XCTTestEnumerationOptions alloc]
                                        initWithIncludeAllTestIdentifiers:YES
                        includeParallelizableTestIdentifierGroups:NO]
                         completion:^(XCTTestEnumerationResult *result, NSError *error) {
                             received = result;
                             ok("enumeration reports no error", error == nil, nil);
                         }];
    ok("enumeration delivers a result", received != nil, nil);
    ok("and it is the one the extension produced", received == full.lastResult, nil);
    ok("declining the groups key leaves the result without groups",
       received.parallelizableTestIdentifierGroups == nil, nil);
}

#pragma mark - main

int main(void)
{
    @autoreleasepool {
        printf("run session\n");
        testOptionsValues();
        testOptionsArchiveKeys();
        testOptionsPartialArchive();
        testOptionsDescription();
        testResult();
        testProtocol();

        printf("%s: %d failure%s\n", failures ? "FAILED" : "PASSED", failures,
               failures == 1 ? "" : "s");
    }
    return failures ? 1 : 0;
}
