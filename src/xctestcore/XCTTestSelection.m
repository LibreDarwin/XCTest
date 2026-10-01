// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The five selection classes, implemented from the shipped XCTestCore binary.
//
// What is implemented here is what an archive carries. What an *IDE* writes
// into a scheme is not, and the two are kept apart on purpose:
//
//   Implemented
//     The NSSecureCoding surface of all five classes, their identity
//     (-isEqual:/-hash), the accessors, and the structural operations a run
//     needs to turn a flat list of identifiers back into a tree.
//
//   Absent
//     XCTTagSelection's plist form (-dictionaryRepresentation:,
//     +modeFromString:, -initWithDictionary:), XCTTestIdentifierSetBuilder, the
//     Swift Testing method counterparts, and the nine private
//     _XCTTestIdentifier_* subclasses.
//
// The header documents why each omission is safe. Nothing here links against
// XCTestCore; every key and default below was read out of the reference
// binary's -initWithCoder: and -encodeWithCoder:.

#import <XCTestCore/XCTTestSelection.h>

#import <Foundation/Foundation.h>
#import <Foundation/NSKeyedArchiver.h>

#import "XCTestCoreFoundationCompat.h"
#import "XCTestInternal.h"

#pragma mark - XCTTag

@implementation XCTTag
{
    NSString *_sourceCodeRepresentation;
}

- (instancetype)initWithSourceCodeRepresentation:(NSString *)representation
{
    self = [super init];
    if (self) {
        _sourceCodeRepresentation = [representation copy];
    }
    return self;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // The one ivar is the one key. There is no default to guard: an archive
    // with no XCTTagSourceCodeRepresentation holds no tag, and there is nothing
    // sensible to substitute -- an empty-string tag would silently match
    // nothing while looking, in a log, like a real tag.
    NSString *representation = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSString class], nil]
                                                    forKey:@"XCTTagSourceCodeRepresentation"];
    self = [self initWithSourceCodeRepresentation:representation];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.sourceCodeRepresentation forKey:@"XCTTagSourceCodeRepresentation"];
}

- (NSString *)sourceCodeRepresentation
{
    return _sourceCodeRepresentation;
}

- (NSString *)displayName
{
    // The tag without its sigil. A tag is written "@slow"; a log line wants
    // "slow", and the sigil is structure the reader already knows about. A tag
    // written without one -- "@Suite.Nested" is a dotted qualified name, but a
    // bare "smoke" is legal too -- is returned unchanged.
    NSString *source = self.sourceCodeRepresentation;
    if ([source hasPrefix:@"@"]) {
        return [source substringFromIndex:1];
    }
    return source;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTTag class]]) {
        return NO;
    }
    // Source spelling, not -displayName and not a normalised form: two tags
    // are the same tag when they are the same characters. That is what makes
    // a typo inert -- "@Slow" is a tag nothing carries, not a synonym for
    // "@slow" that quietly widens a selection.
    return [self.sourceCodeRepresentation isEqualToString:((XCTTag *)object).sourceCodeRepresentation];
}

- (NSUInteger)hash
{
    return self.sourceCodeRepresentation.hash;
}

- (id)copyWithZone:(NSZone *)zone
{
    // Immutable, and its only ivar is already a copy.
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; %@>", NSStringFromClass(self.class), self,
                                      self.sourceCodeRepresentation];
}

@end

#pragma mark - XCTTagSelection

/// The mode's name in the plist form the IDE writes. Recovered from the
/// reference's -dictionaryRepresentation: and +modeFromString:, which
/// together establish the two names and which of them is the default.
///
///   modeString:    mode == 1 ? @"and" : @"or"
///   +modeFromString:  [@"and" isEqualToString:name]   (returns 1, else 0)
///
/// So the mapping is a bijection onto {0, 1}, the default-when-absent is 1, and
/// there is no third spelling to recover.
static NSString *XCTTagSelectionModeToString(XCTTagSelectionMode mode)
{
    return mode == XCTTagSelectionModeAnd ? @"and" : @"or";
}

@implementation XCTTagSelection
{
    NSSet<XCTTag *> *_tags;
    NSInteger _selectionMode;
    BOOL _includeXCTests;
}

- (instancetype)initWithTags:(NSSet<XCTTag *> *)tags
               selectionMode:(XCTTagSelectionMode)selectionMode
{
    return [self initWithTags:tags selectionMode:selectionMode includeXCTests:NO];
}

- (instancetype)initWithTags:(NSSet<XCTTag *> *)tags
               selectionMode:(XCTTagSelectionMode)selectionMode
              includeXCTests:(BOOL)includeXCTests
{
    self = [super init];
    if (self) {
        _tags = [tags copy];
        _selectionMode = selectionMode;
        _includeXCTests = includeXCTests;
    }
    return self;
}

- (instancetype)init
{
    // An empty AND selection, and XCTests included -- the selection that
    // imposes no constraint. Both defaults are the decoder's defaults too
    // (see -initWithCoder:), so a selection built here and a selection decoded
    // from an archive that carries neither key are the same selection.
    return [self initWithTags:[NSSet set] selectionMode:XCTTagSelectionModeAnd includeXCTests:YES];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // All three keys are presence-guarded, and each guard exists because the
    // default differs from zero:
    //
    //   XCTTagSelectionMode        absent -> 1 (and), not 0 (or).  An archive
    //       written before the key existed would otherwise mean "any tag will
    //       do" where it meant "all of them", turning a narrow selection into
    //       a broad one -- the worst direction for this particular mistake to
    //       go wrong in.
    //   XCTTagSelectionIncludeXCTests
    //       absent -> NO.  A tag selection written for the Swift Testing
    //       suite must not start applying to XCTest methods just because the
    //       key was omitted.
    //
    // The tag set is not guarded: an absent tag set is an empty one, which is
    // what -init gives, and there is no third answer.
    NSSet *tagSet = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [XCTTag class], nil]
                                           forKey:@"XCTTagSelectionTagSet"];

    NSInteger mode = XCTTagSelectionModeAnd;
    if ([coder containsValueForKey:@"XCTTagSelectionMode"]) {
        mode = [coder decodeIntegerForKey:@"XCTTagSelectionMode"];
    }

    BOOL includeXCTests = NO;
    if ([coder containsValueForKey:@"XCTTagSelectionIncludeXCTests"]) {
        includeXCTests = [coder decodeBoolForKey:@"XCTTagSelectionIncludeXCTests"];
    }

    self = [self initWithTags:tagSet selectionMode:mode includeXCTests:includeXCTests];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.tags forKey:@"XCTTagSelectionTagSet"];
    [coder encodeInteger:self.selectionMode forKey:@"XCTTagSelectionMode"];
    [coder encodeBool:self.includeXCTests forKey:@"XCTTagSelectionIncludeXCTests"];
}

- (NSSet<XCTTag *> *)tags
{
    return _tags;
}

- (void)setTags:(NSSet<XCTTag *> *)tags
{
    _tags = [tags copy];
}

- (XCTTagSelectionMode)selectionMode
{
    return (XCTTagSelectionMode)_selectionMode;
}

- (void)setSelectionMode:(XCTTagSelectionMode)selectionMode
{
    _selectionMode = selectionMode;
}

- (BOOL)includeXCTests
{
    return _includeXCTests;
}

- (void)setIncludeXCTests:(BOOL)includeXCTests
{
    _includeXCTests = includeXCTests;
}

- (BOOL)isEmpty
{
    return self.tags.count == 0;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTTagSelection class]]) {
        return NO;
    }
    XCTTagSelection *other = object;
    // All three fields, including the mode. Two selections over the same tags
    // mean different things under "or" and "and", so folding the mode out would
    // make them compare equal while selecting opposite sets of tests.
    return self.selectionMode == other.selectionMode && self.includeXCTests == other.includeXCTests &&
           [self.tags isEqualToSet:other.tags];
}

- (NSUInteger)hash
{
    return self.tags.hash ^ (NSUInteger)self.selectionMode ^ ((NSUInteger)self.includeXCTests << 1);
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithTags:self.tags
                                              selectionMode:self.selectionMode
                                             includeXCTests:self.includeXCTests];
}

- (NSString *)description
{
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:self.tags.count];
    for (XCTTag *tag in self.tags) {
        [names addObject:tag.displayName];
    }
    // Tags in name order, because the set has no order and a description that
    // reorders itself between two dumps of the same selection is useless in a
    // diff.
    [names sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"<%@: %p; %@ {%@} includeXCTests: %@>",
                                      NSStringFromClass(self.class), self,
                                      XCTTagSelectionModeToString(self.selectionMode),
                                      [names componentsJoinedByString:@", "],
                                      self.includeXCTests ? @"YES" : @"NO"];
}

@end

#pragma mark - XCTTestIdentifier

/// Archive keys, as the reference writes and reads them.
static NSString *const XCTTestIdentifierComponentsKey = @"c";
static NSString *const XCTTestIdentifierArgumentIDsKey = @"a";
static NSString *const XCTTestIdentifierOptionsKey = @"o";
/// The pre-Swift-Testing spelling of the three option bits, one key per bit.
static NSString *const XCTTestIdentifierContainerKey = @"oc";
static NSString *const XCTTestIdentifierClassAndMethodKey = @"ocm";
static NSString *const XCTTestIdentifierSwiftMethodKey = @"os";
static NSString *const XCTTestIdentifierLegacyClassNameKey = @"className";
static NSString *const XCTTestIdentifierLegacyMethodNameKey = @"methodName";
static NSString *const XCTTestIdentifierBundleNameKey = @"bundleName";
static NSString *const XCTTestIdentifierDeprecatedKey = @"deprecated";

/// The one core constructor for the Objective-C spelling. Declared in a category
/// of its own so both the part-by-part entry points in the primary
/// implementation and the string-parsing methods in the creation category reach
/// the same method rather than a second, subtly different one.
@interface XCTTestIdentifier (XCTTestIdentifierPrivateCore)
- (instancetype)_initWithClassAndMethodComponents:(NSArray<NSString *> *)components
                             preserveModulePrefix:(BOOL)preserveModulePrefix;
@end

@implementation XCTTestIdentifier
{
    NSArray<NSString *> *_components;
    NSSet<NSData *> *_argumentIDs;
    NSUInteger _options;
}

- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                       isContainer:(BOOL)isContainer
{
    NSUInteger options = isContainer ? XCTTestIdentifierOptionContainer : XCTTestIdentifierOptionNone;
    return [self initWithComponents:components argumentIDs:nil options:options];
}

- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                            options:(XCTTestIdentifierOptions)options
{
    return [self initWithComponents:components argumentIDs:nil options:options];
}

- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                       argumentIDs:(NSSet<NSData *> *)argumentIDs
{
    return [self initWithComponents:components
                        argumentIDs:argumentIDs
                            options:XCTTestIdentifierOptionNone];
}

- (instancetype)initWithComponents:(NSArray<NSString *> *)components
                       argumentIDs:(NSSet<NSData *> *)argumentIDs
                           options:(XCTTestIdentifierOptions)options
{
    self = [super init];
    if (self) {
        _components = [components copy];
        _argumentIDs = [argumentIDs copy];
        _options = (NSUInteger)options;
    }
    return self;
}

- (instancetype)initWithClassAndMethodComponents:(NSArray<NSString *> *)components
{
    // Every way of spelling an Objective-C identifier by its parts ends up here,
    // and this is only a layer over the one core constructor, exactly as
    // -initWithStringRepresentation: is: the same components, the module prefix
    // stripped rather than kept. Sharing the core is what makes a selection
    // parsed from a string compare equal to the identifier a test case builds
    // for itself; a second, subtly different constructor would not.
    return [self _initWithClassAndMethodComponents:components
                             preserveModulePrefix:NO];
}

- (instancetype)initWithClassName:(NSString *)className
{
    return [self initWithClassAndMethodComponents:@[ className ]];
}

- (instancetype)initWithClassName:(NSString *)className
                       methodName:(NSString *)methodName
{
    return [self initWithClassAndMethodComponents:@[ className, methodName ]];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // An identifier is written two ways, and the archive carries enough to tell
    // which:
    //
    //   Modern     components under "c", plus the option bits under "o" or
    //              under the three single-bit keys "oc"/"ocm"/"os".
    //   Legacy     no "c"; a class name and a method name under "className"
    //              and "methodName", with "bundleName" and "deprecated" beside
    //              them.
    //
    // The test for which is one key: are there components? An archive carrying
    // "c" is modern whatever else it holds, because the legacy spelling is the
    // only one that can do without components -- an identifier that has them
    // has no use for a class name and a method name, and reading the two
    // spellings in the other order would make an archive that carries both say
    // something other than what either writer meant.
    NSArray *components = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil]
                                                forKey:XCTTestIdentifierComponentsKey];

    BOOL wroteContainerBit = [coder containsValueForKey:XCTTestIdentifierContainerKey];
    BOOL wroteClassAndMethodBit = [coder containsValueForKey:XCTTestIdentifierClassAndMethodKey];
    BOOL wroteSwiftMethodBit = [coder containsValueForKey:XCTTestIdentifierSwiftMethodKey];
    BOOL wroteOptions = [coder containsValueForKey:XCTTestIdentifierOptionsKey];

    // Components alone decide the spelling, and an option key is not required
    // alongside them. An archive carrying "c" and no option key is a modern
    // identifier whose option bits happen to be zero, and reading it as legacy
    // would drop the components and set the class-and-method bit instead --
    // turning /A/b into Class/testA-style semantics for an identifier that was
    // written as components. The legacy spelling is identified by the absence
    // of "c" and by nothing else, because it is the only spelling that can omit
    // components entirely.
    if (components != nil) {
        // Modern. "o" is the packed value, and the three single-bit keys are
        // accumulated on top of it: an archive carrying both is describing the
        // same three facts in the old and the new spelling, and the union is
        // the only reading that loses nothing. An absent "o" contributes
        // nothing, which is what lets "c" alone decode to no option bits.
        NSUInteger options = 0;
        if (wroteOptions) {
            options |= (NSUInteger)[coder decodeIntegerForKey:XCTTestIdentifierOptionsKey];
        }
        if (wroteContainerBit && [coder decodeBoolForKey:XCTTestIdentifierContainerKey]) {
            options |= XCTTestIdentifierOptionContainer;
        }
        if (wroteClassAndMethodBit && [coder decodeBoolForKey:XCTTestIdentifierClassAndMethodKey]) {
            options |= XCTTestIdentifierOptionClassAndMethod;
        }
        if (wroteSwiftMethodBit && [coder decodeBoolForKey:XCTTestIdentifierSwiftMethodKey]) {
            options |= XCTTestIdentifierOptionSwiftMethod;
        }

        NSSet *argumentIDs = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [NSData class], nil]
                                                  forKey:XCTTestIdentifierArgumentIDsKey];

        self = [self initWithComponents:components
                            argumentIDs:argumentIDs
                                options:(XCTTestIdentifierOptions)options];
        return self;
    }

    // Legacy. The components are rebuilt from the two names, and the
    // class-and-method bit is set because that is what the pair of names means.
    // "bundleName" is decoded and then dropped: a legacy identifier named its
    // bundle, but the identifier itself is scoped by the configuration's
    // bundle, and prepending it here would produce a component list one longer
    // than every identifier written after it -- so a run comparing them would
    // find nothing matches.
    NSString *className = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSString class], nil]
                                                 forKey:XCTTestIdentifierLegacyClassNameKey];
    NSString *methodName = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSString class], nil]
                                                  forKey:XCTTestIdentifierLegacyMethodNameKey];
    [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSString class], nil]
                          forKey:XCTTestIdentifierBundleNameKey];

    NSMutableArray<NSString *> *legacyComponents = [NSMutableArray arrayWithCapacity:2];
    if (className != nil) {
        [legacyComponents addObject:className];
    }
    if (methodName != nil) {
        [legacyComponents addObject:methodName];
    }

    // "deprecated" is decoded and dropped for the same reason as the bundle
    // name: it records how an identifier was spelled, not which test it names,
    // and two spellings of one test have to stay one identifier.
    [coder decodeBoolForKey:XCTTestIdentifierDeprecatedKey];

    // Argument IDs are possible on either spelling. Decoded once, and only
    // after the components are settled, so that the modern and legacy paths
    // build their result identically.
    NSSet *legacyArgumentIDs =
        [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSSet class], [NSData class], nil]
                              forKey:XCTTestIdentifierArgumentIDsKey];

    self = [self initWithComponents:legacyComponents
                        argumentIDs:legacyArgumentIDs
                            options:(XCTTestIdentifierOptions)XCTTestIdentifierOptionClassAndMethod];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    // Always the modern spelling. The legacy keys are a read path: an archive
    // this writes is read by this, which prefers "c" plus the option keys, so
    // writing both would only add a second source of truth for the same three
    // facts.
    [coder encodeObject:self.components forKey:XCTTestIdentifierComponentsKey];
    [coder encodeObject:self.argumentIDs forKey:XCTTestIdentifierArgumentIDsKey];
    [coder encodeInteger:(NSInteger)self.options forKey:XCTTestIdentifierOptionsKey];
}

- (NSArray<NSString *> *)components
{
    return _components;
}

- (NSUInteger)componentCount
{
    return self.components.count;
}

- (NSString *)componentAtIndex:(NSUInteger)index
{
    // Bounds-checked, returning nil rather than raising. This is called with a
    // component count that came out of an archive, and an archive is not
    // obliged to be internally consistent.
    if (index >= self.components.count) {
        return nil;
    }
    return self.components[index];
}

- (NSString *)firstComponent
{
    return [self componentAtIndex:0];
}

- (NSString *)lastComponent
{
    return [self componentAtIndex:self.componentCount - 1];
}

- (NSSet<NSData *> *)argumentIDs
{
    return _argumentIDs;
}

- (XCTTestIdentifierOptions)options
{
    return (XCTTestIdentifierOptions)_options;
}

- (BOOL)isContainer
{
    return (self.options & XCTTestIdentifierOptionContainer) != 0;
}

- (BOOL)isLeaf
{
    return !self.isContainer;
}

- (BOOL)usesClassAndMethodSemantics
{
    return (self.options & XCTTestIdentifierOptionClassAndMethod) != 0;
}

- (BOOL)isSwiftMethod
{
    return (self.options & XCTTestIdentifierOptionSwiftMethod) != 0;
}

- (BOOL)representsBundle
{
    // A three-component identifier names its bundle. Two does not: that is the
    // class-and-method spelling, which is scoped by the configuration instead.
    return self.componentCount >= 3;
}

- (NSString *)identifierString
{
    // The components, joined by "/". For the class-and-method spelling that is
    // exactly the string an .xctestrun uses to name a test, which is why this
    // is the join and not, say, a colon.
    return [self.components componentsJoinedByString:@"/"];
}

- (XCTTestIdentifier *)identifierWithoutArguments
{
    if (self.argumentIDs == nil) {
        return self;
    }
    return [[[self class] alloc] initWithComponents:self.components
                                       argumentIDs:nil
                                           options:self.options];
}

- (XCTTestIdentifier *)parentIdentifier
{
    if (self.componentCount == 0) {
        return nil;
    }
    // With arguments the enclosing scope is the same test without them. A
    // class-and-method identifier keeps an empty argument set rather than none,
    // which is the spelling its unparameterized case carries too, so the two
    // compare equal; anything else has no arguments and gains the container and
    // Swift-method bits instead.
    if (self.argumentIDs.count != 0) {
        if (self.usesClassAndMethodSemantics && self.componentCount == 2) {
            return [[[self class] alloc] initWithComponents:self.components
                                               argumentIDs:[NSSet set]
                                                   options:self.options];
        }
        return [[[self class] alloc] initWithComponents:self.components
                                           argumentIDs:nil
                                               options:self.options | XCTTestIdentifierOptionContainer | XCTTestIdentifierOptionSwiftMethod];
    }
    // Without arguments the enclosing scope is one component shorter: a
    // method's class, or a suite's parent. It is a container, and a Swift
    // method's spelling is dropped along with its method component.
    NSArray<NSString *> *parentComponents =
        [self.components subarrayWithRange:NSMakeRange(0, self.componentCount - 1)];
    return [[[self class] alloc] initWithComponents:parentComponents
                                       argumentIDs:nil
                                           options:(self.options & ~XCTTestIdentifierOptionSwiftMethod) | XCTTestIdentifierOptionContainer];
}

- (XCTTestIdentifier *)childIdentifierWithComponent:(NSString *)component
                                       isContainer:(BOOL)isContainer
{
    NSMutableArray<NSString *> *components = [self.components mutableCopy];
    [components addObject:component];
    return [[[self class] alloc] initWithComponents:components
                                        argumentIDs:nil
                                            options:isContainer ? XCTTestIdentifierOptionContainer
                                                                 : self.options & ~XCTTestIdentifierOptionContainer];
}

- (XCTTestIdentifier *)childIdentifierWithArgumentIDs:(NSSet<NSData *> *)argumentIDs
{
    return [[[self class] alloc] initWithComponents:self.components
                                        argumentIDs:argumentIDs
                                            options:self.options];
}

- (XCTTestIdentifier *)identifierByAppendingComponent:(NSString *)component
                                          isContainer:(BOOL)isContainer
{
    return [self childIdentifierWithComponent:component isContainer:isContainer];
}

- (BOOL)isAncestorOfTestIdentifier:(XCTTestIdentifier *)identifier
{
    if (identifier == nil) {
        return NO;
    }
    // An identifier is not its own ancestor. A container contains itself as a
    // prefix, and a run that asked "does this suite contain itself" would
    // either recurse forever or need a special case at every call site.
    if (self == identifier || [self isEqual:identifier]) {
        return NO;
    }
    NSUInteger count = self.componentCount;
    if (count == 0 || identifier.componentCount <= count) {
        return NO;
    }
    for (NSUInteger i = 0; i < count; i++) {
        if (![self.components[i] isEqualToString:identifier.components[i]]) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)displayName
{
    return self.lastComponent ?: @"";
}

- (NSArray<NSString *> *)displayNameComponents
{
    return self.components;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTTestIdentifier class]]) {
        return NO;
    }
    XCTTestIdentifier *other = object;
    // Components, options, and arguments -- all three. Two identifiers with the
    // same path that differ in one option bit are different tests: a container
    // and a leaf with that path, or an XCTest method and a Swift Testing one.
    return self.options == other.options &&
           (self.argumentIDs == other.argumentIDs || [self.argumentIDs isEqualToSet:other.argumentIDs]) &&
           [self.components isEqualToArray:other.components];
}

- (NSUInteger)hash
{
    return self.components.hash ^ self.options ^ self.argumentIDs.hash;
}

- (id)copyWithZone:(NSZone *)zone
{
    // Immutable, and both ivars are already copies.
    return self;
}

- (NSString *)description
{
    NSMutableString *out = [NSMutableString stringWithFormat:@"<%@: %p; %@",
                                                      NSStringFromClass(self.class), self, self.identifierString];
    if (self.isContainer) {
        [out appendString:@" (container)"];
    }
    if (self.usesClassAndMethodSemantics) {
        [out appendString:@" (class and method)"];
    }
    if (self.isSwiftMethod) {
        [out appendString:@" (swift method)"];
    }
    if (self.argumentIDs.count > 0) {
        [out appendFormat:@" arguments: %lu", (unsigned long)self.argumentIDs.count];
    }
    [out appendString:@">"];
    return out;
}

@end

#pragma mark - XCTTestIdentifierCreation

@implementation XCTTestIdentifier (XCTTestIdentifierCreation)

- (instancetype)initWithStringRepresentation:(NSString *)stringRepresentation
{
    return [self initWithStringRepresentation:stringRepresentation
                        preserveModulePrefix:NO];
}

- (instancetype)initWithStringRepresentation:(NSString *)stringRepresentation
                        preserveModulePrefix:(BOOL)preserveModulePrefix
{
    if (stringRepresentation == nil) {
        [[NSException exceptionWithName:NSInternalInconsistencyException
                                 reason:@"a test identifier needs a string to be made of"
                               userInfo:nil] raise];
        return nil;
    }

    if (stringRepresentation.length == 0) {
        return nil;
    }
    NSArray<NSString *> *components = [stringRepresentation componentsSeparatedByString:@"/"];
    if (components.count > 2) {
        // An Objective-C identifier names a class and at most one method. A
        // deeper path is a suite path, which is spelled with a different
        // method and is not this one.
        return nil;
    }
    if ([components.firstObject hasSuffix:@")"]) {
        // A suite is spelled by its own name; a name ending in a paren is a
        // method, and a method cannot be the outer component of anything.
        return nil;
    }
    if (![components.lastObject hasSuffix:@":)"]) {
        // A `:)` suffix is how a parameterized Swift test spells its input, and
        // that is not a method name an Objective-C runner can ask for.
        return [self _initWithClassAndMethodComponents:components
                                preserveModulePrefix:preserveModulePrefix];
    }
    return nil;
}

- (instancetype)initWithSwiftTestingStringRepresentation:(NSString *)stringRepresentation
{
    if (stringRepresentation == nil) {
        [[NSException exceptionWithName:NSInternalInconsistencyException
                                 reason:@"a test identifier needs a string to be made of"
                               userInfo:nil] raise];
        return nil;
    }

    if (stringRepresentation.length == 0) {
        return nil;
    }
    NSArray<NSString *> *components = [stringRepresentation componentsSeparatedByString:@"/"];

    // The suffix is what says which of the two things this is, and it is kept:
    // the identifier the archive stores has to still be able to tell a
    // parameterized test from a plain one.
    XCTTestIdentifierOptions options = XCTTestIdentifierOptionContainer;
    if ([components.lastObject hasSuffix:@":)"]) {
        options = XCTTestIdentifierOptionContainer | XCTTestIdentifierOptionSwiftMethod;
    } else if ([components.lastObject hasSuffix:@")"]) {
        options = 0;
    }
    return [self initWithComponents:components argumentIDs:nil options:options];
}

- (XCTTestIdentifier *)swiftMethodCounterpart
{
    if (!self.usesClassAndMethodSemantics || self.componentCount != 2 || !self.isSwiftMethod) {
        // A suite is not a method under another spelling, and a method that is
        // not already a Swift one has no Swift reading to give.
        return nil;
    }
    // The same components and the same arguments, read as Swift. For an
    // identifier that came from -initWithStringRepresentation: that is the
    // identifier itself, and the copy is the point: the reading is forced here
    // rather than inherited, so a subclass that reports different option bits
    // for the same components still gets the Swift reading asked for.
    return [[XCTTestIdentifier alloc] initWithComponents:self.components
                                             argumentIDs:self.argumentIDs
                                                 options:self.options | XCTTestIdentifierOptionSwiftMethod];
}

@end

#pragma mark - XCTTestIdentifierPrivateCore

@implementation XCTTestIdentifier (XCTTestIdentifierPrivateCore)

/// The core of the Objective-C spelling, and where the two options the
/// identifier carries come from: a single component is a container, two are a
/// class and a method, and either the class was spelled with its module or the
/// method with an empty argument list only when the caller is describing Swift
/// Testing's own output.
- (instancetype)_initWithClassAndMethodComponents:(NSArray<NSString *> *)components
                           preserveModulePrefix:(BOOL)preserveModulePrefix
{
    // As in XCTTestExecutionOrderingToString: this SDK declares
    // NSAssertionFailure but does not export it, so the same failure is raised
    // here rather than reached through the assertion handler.
    if (self == nil) {
        [[NSException exceptionWithName:NSInternalInconsistencyException
                                 reason:@"an identifier has to be allocated before it is made"
                               userInfo:nil] raise];
        return nil;
    }
    if (components.count == 0) {
        [[NSException exceptionWithName:NSInternalInconsistencyException
                                 reason:@"an identifier needs at least one component"
                               userInfo:nil] raise];
        return nil;
    }

    NSString *rawClassName = components[0];
    NSString *className = rawClassName;
    // Whether the string named a module, or a `()`, either of which is how Swift
    // Testing spells something the Objective-C runner spells differently.
    BOOL isSwiftSpelling = NO;
    if (!preserveModulePrefix) {
        NSString *classNameWithoutModule = _XCTClassNameWithoutModuleFromClassName(rawClassName);
        if (![classNameWithoutModule isEqualToString:rawClassName]) {
            className = classNameWithoutModule;
            isSwiftSpelling = YES;
        }
    }

    NSString *methodName = nil;
    NSString *unadornedMethodName = nil;
    if (components.count == 2) {
        methodName = components[1];
        if ([methodName hasSuffix:@"()"]) {
            unadornedMethodName = [methodName substringToIndex:methodName.length - @"()".length];
            isSwiftSpelling = YES;
        } else {
            unadornedMethodName = methodName;
        }
    }

    NSArray<NSString *> *identifierComponents = components;
    if (isSwiftSpelling) {
        // At least one component named something extra, so the components as
        // given are not the ones the identifier is built from.
        if (components.count == 2) {
            identifierComponents = @[className, unadornedMethodName];
        } else {
            identifierComponents = @[className];
        }
    }

    XCTTestIdentifierOptions options;
    NSSet<NSData *> *argumentIDs;
    if (components.count == 1) {
        options = XCTTestIdentifierOptionContainer | XCTTestIdentifierOptionClassAndMethod;
        argumentIDs = nil;
    } else {
        options = XCTTestIdentifierOptionClassAndMethod;
        // Present but empty, to distinguish "no arguments" from "not a
        // parameterized test", which the Swift Testing spelling relies on.
        argumentIDs = [NSSet set];
    }
    if (isSwiftSpelling && unadornedMethodName != nil) {
        options |= XCTTestIdentifierOptionSwiftMethod;
    }
    return [self initWithComponents:identifierComponents
                        argumentIDs:argumentIDs
                            options:options];
}

@end

#pragma mark - XCTTestIdentifierSet

/// Declared rather than left to the compiler so XCTTestIdentifierSetBuilder, in
/// this same file, can be seen to be overriding it and not inventing a method
/// that happens to share a name. Private to XCTestCore, and not in the installed
/// header: it names storage, and storage is not part of the contract.
@interface XCTTestIdentifierSet ()
- (NSMutableSet<XCTTestIdentifier *> *)xctMutableIdentifiers;
@end

@implementation XCTTestIdentifierSet
{
    // An NSMutableSet, not the reference's open-addressed C array. The array is
    // an implementation detail with one observable consequence -- uniqueness on
    // insert, which is the entire contract of a set -- and NSMutableSet gives
    // that for free along with -hash and -isEqual:, which the array has to
    // hand-roll and which every later method would otherwise have to trust.
    NSMutableSet<XCTTestIdentifier *> *_identifiers;
}

/// The one place in this class that names its own storage.
///
/// Everything below reads through this rather than touching -_identifiers, and
/// that is not a style preference: XCTTestIdentifierSetBuilder is a subclass
/// holding its own collection, and a subclass's ivar is not the superclass's.
/// An inherited method that read -_identifiers directly would answer from the
/// builder's empty superclass storage -- -sortedIdentifiers on a builder with
/// three identifiers in it would come back empty, with nothing to indicate it
/// had gone wrong. Routing every read through one overridable method is what
/// lets the builder inherit the ~dozen query methods that follow and have them
/// mean what they say.
- (NSMutableSet<XCTTestIdentifier *> *)xctMutableIdentifiers
{
    return _identifiers;
}

- (instancetype)init
{
    return [self initWithArray:@[]];
}

- (instancetype)initWithArray:(NSArray<XCTTestIdentifier *> *)identifiers
{
    self = [super init];
    if (self) {
        _identifiers = [NSMutableSet setWithCapacity:identifiers.count];
        NSMutableSet<XCTTestIdentifier *> *storage = self.xctMutableIdentifiers;
        // Re-adding through the setter rather than the ivar: a nil element in
        // the array is a corrupt archive, and -moreserve capacity aside the
        // difference only shows up in a crash that would otherwise happen here
        // instead of at the point of use.
        for (XCTTestIdentifier *identifier in identifiers) {
            if (identifier != nil) {
                [storage addObject:identifier];
            }
        }
    }
    return self;
}

- (instancetype)initWithSet:(XCTTestIdentifierSet *)set
{
    // Copies the contents, not the object: a copy of a set has to be
    // independent of the original, and the original is going to keep mutating
    // while the copy is being compared against something.
    return [self initWithArray:set.sortedIdentifiers];
}

- (instancetype)initWithTestIdentifier:(XCTTestIdentifier *)identifier
{
    return [self initWithArray:@[ (id)identifier ]];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // The identifier array, and only XCTTestIdentifier elements. The allowed
    // class set is what stops a hand-edited archive from smuggling an
    // arbitrary object into a set that is going to be asked for
    // -componentCount.
    NSArray *identifiers =
        [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [XCTTestIdentifier class], nil]
                              forKey:@"identifiers"];
    self = [self initWithArray:identifiers];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    // Sorted, so the archive is byte-stable for a given selection. The set is
    // unordered by design, but an archive that reorders itself between two
    // identical runs is a nuisance to diff and a nuisance to sign.
    [coder encodeObject:self.sortedIdentifiers forKey:@"identifiers"];
}

- (NSUInteger)count
{
    return self.xctMutableIdentifiers.count;
}

- (NSArray<XCTTestIdentifier *> *)sortedIdentifiers
{
    // Sorted by identifier string, with -compare: rather than a localized
    // compare: the order has to be the same on every machine, and a localized
    // one depends on the locale of whoever is reading.
    return [self.xctMutableIdentifiers.allObjects sortedArrayUsingComparator:^NSComparisonResult(XCTTestIdentifier *a,
                                                                                           XCTTestIdentifier *b) {
        NSComparisonResult result = [a.identifierString compare:b.identifierString];
        // Two identifiers can share a string and still differ -- that is what
        // the option bits are for -- so the order has to keep going past the
        // string to stay total, or the archive is unstable.
        if (result != NSOrderedSame) {
            return result;
        }
        NSComparisonResult byOptions = (a.options < b.options)    ? NSOrderedAscending
                                       : (a.options > b.options)  ? NSOrderedDescending
                                                                  : NSOrderedSame;
        if (byOptions != NSOrderedSame) {
            return byOptions;
        }
        NSUInteger argumentCount = a.argumentIDs.count;
        NSUInteger otherArgumentCount = b.argumentIDs.count;
        if (argumentCount < otherArgumentCount) {
            return NSOrderedAscending;
        }
        if (argumentCount > otherArgumentCount) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
}

- (XCTTestIdentifier *)anyTestIdentifier
{
    // Any element, not the first in enumeration order: the method promises an
    // example, not a particular one, and nothing should depend on which.
    // The smallest identifier string is chosen so that -anyTestIdentifier is at
    // least reproducible.
    return self.sortedIdentifiers.firstObject;
}

- (BOOL)isEmpty
{
    return self.xctMutableIdentifiers.count == 0;
}

- (BOOL)containsTestIdentifier:(XCTTestIdentifier *)identifier
{
    if (identifier == nil) {
        return NO;
    }
    return [self.xctMutableIdentifiers containsObject:identifier];
}

- (BOOL)containsTestIdentifier:(XCTTestIdentifier *)identifier
              includingParents:(BOOL)includingParents
{
    if (identifier == nil) {
        return NO;
    }
    if ([self containsTestIdentifier:identifier]) {
        return YES;
    }
    if (!includingParents) {
        return NO;
    }
    // "Does this set name something inside -identifier". Answered by walking
    // the set once rather than by asking the set for a subtree, because the set
    // is unordered and has no index to walk down.
    for (XCTTestIdentifier *candidate in self.xctMutableIdentifiers) {
        if ([candidate isAncestorOfTestIdentifier:identifier]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isSubsetOfTestIdentifierSet:(XCTTestIdentifierSet *)other
{
    if (other == nil) {
        return NO;
    }
    // -other may be a builder holding its own collection, so this asks it
    // through the same hook rather than reaching past it into its storage.
    return [self.xctMutableIdentifiers isSubsetOfSet:other.xctMutableIdentifiers];
}

- (XCTTestIdentifierSet *)setByAddingTestIdentifiersFromSet:(XCTTestIdentifierSet *)other
{
    if (other == nil) {
        return self;
    }
    NSMutableArray<XCTTestIdentifier *> *identifiers = [self.xctMutableIdentifiers.allObjects mutableCopy];
    [identifiers addObjectsFromArray:other.sortedIdentifiers];
    return [[[self class] alloc] initWithArray:identifiers];
}

- (XCTTestIdentifierSet *)setByApplyingBlock:(id (^)(XCTTestIdentifier *))block
{
    NSMutableArray<XCTTestIdentifier *> *identifiers = [NSMutableArray arrayWithCapacity:self.count];
    for (XCTTestIdentifier *identifier in self.sortedIdentifiers) {
        id replacement = block(identifier);
        // A block that returns nothing removes the identifier; one that returns
        // an identifier replaces it. Both are load-bearing -- "keep the passing
        // tests" is a filter, "renumber the failed ones" is a map -- so the
        // return type cannot be a plain void.
        if (replacement == nil) {
            continue;
        }
        if ([replacement isKindOfClass:[XCTTestIdentifier class]]) {
            [identifiers addObject:replacement];
        } else if ([replacement isKindOfClass:[NSArray class]]) {
            // An array means several replacements for one identifier, which is
            // how a component is expanded.
            for (id element in (NSArray *)replacement) {
                if ([element isKindOfClass:[XCTTestIdentifier class]]) {
                    [identifiers addObject:element];
                }
            }
        }
    }
    return [[[self class] alloc] initWithArray:identifiers];
}

- (NSDictionary<XCTTestIdentifier *, NSSet<XCTTestIdentifier *> *> *)
    testIdentifiersGroupedByFirstComponentIdentifier
{
    // Flat list back to a tree. Each identifier is filed under the identifier
    // of its first component marked as a container; an identifier whose first
    // component is itself the whole identifier (a top-level suite) is its own
    // key. The alternative -- grouping by raw string -- would produce a
    // dictionary keyed by something that cannot be asked whether it contains
    // anything, which is the question a caller has.
    NSMutableDictionary<XCTTestIdentifier *, NSMutableSet<XCTTestIdentifier *> *> *groups =
        [NSMutableDictionary dictionary];
    for (XCTTestIdentifier *identifier in self.sortedIdentifiers) {
        // Built from the first component alone rather than by appending that
        // component to the identifier it came from. Appending would give a
        // two-component key for a one-component identifier -- /Bundle/Bundle --
        // which is a key that names nothing in particular. One branch, not two:
        // the top-level case and the nested case want the same key.
        XCTTestIdentifier *parent =
            [[[XCTTestIdentifier class] alloc] initWithComponents:@[ identifier.firstComponent ]
                                                    isContainer:YES];
        NSMutableSet<XCTTestIdentifier *> *group = groups[parent];
        if (group == nil) {
            group = [NSMutableSet set];
            groups[parent] = group;
        }
        [group addObject:identifier];
    }
    return groups;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTTestIdentifierSet class]]) {
        return NO;
    }
    // Set equality, so enumeration order cannot make two identical selections
    // compare unequal.
    return [self.xctMutableIdentifiers isEqualToSet:((XCTTestIdentifierSet *)object).xctMutableIdentifiers];
}

- (NSUInteger)hash
{
    return self.xctMutableIdentifiers.hash;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithSet:self];
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len
{
    // Enumeration order is the set's, and is deliberately unspecified. The
    // header says so; this is where that promise is kept.
    //
    // Delegated rather than hand-rolled: this SDK's <Foundation/NSObject.h>
    // documents the state struct's contract in place (state->state is the
    // cursor, itemsPtr is the buffer the collection fills, mutationsPtr points
    // at state->extra[0] and must stay stable between calls), and the set
    // already implements exactly that. Writing the loop here would be a second
    // implementation of an ABI whose subtleties are the part most likely to be
    // misremembered.
    return [self.xctMutableIdentifiers countByEnumeratingWithState:state objects:buffer count:len];
}

- (NSString *)description
{
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:self.count];
    for (XCTTestIdentifier *identifier in self.sortedIdentifiers) {
        [lines addObject:identifier.identifierString];
    }
    return [NSString stringWithFormat:@"<%@: %p; %lu identifier(s):\n\t%@\n>",
                                      NSStringFromClass(self.class), self, (unsigned long)self.count,
                                      [lines componentsJoinedByString:@"\n\t"]];
}

@end

#pragma mark - XCTTestIdentifierSetBuilder

@implementation XCTTestIdentifierSetBuilder
{
    NSMutableSet<XCTTestIdentifier *> *_testIdentifiers;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _testIdentifiers = [NSMutableSet set];
    }
    return self;
}

- (instancetype)initWithSet:(XCTTestIdentifierSet *)set
{
    self = [self init];
    if (self) {
        [self unionSet:set];
    }
    return self;
}

- (instancetype)initWithTestIdentifier:(XCTTestIdentifier *)identifier
{
    self = [self init];
    if (self) {
        [self addTestIdentifier:identifier];
    }
    return self;
}

- (instancetype)initWithTestIdentifierSet:(XCTTestIdentifierSet *)set
{
    return [self initWithSet:set];
}

- (NSMutableSet<XCTTestIdentifier *> *)xctMutableIdentifiers
{
    return _testIdentifiers;
}

- (void)addTestIdentifier:(XCTTestIdentifier *)identifier
{
    if (identifier != nil) {
        [_testIdentifiers addObject:identifier];
    }
}

- (BOOL)addTestIdentifiersForStringRepresentation:(NSString *)stringRepresentation
                        includingSwiftCounterpart:(BOOL)includingSwiftCounterpart
{
    // Two attempts, because the two spellings disagree about a string that
    // either could name, and each attempt has to be made on its own terms: the
    // Objective-C spelling rejects a `:)` suffix and the Swift Testing one
    // reads it as the mark of a parameterized test.
    XCTTestIdentifier *identifier = [[XCTTestIdentifier alloc] initWithStringRepresentation:stringRepresentation
                                                                    preserveModulePrefix:YES];
    if (identifier != nil) {
        [self addTestIdentifier:identifier];
        if (includingSwiftCounterpart) {
            [self addTestIdentifier:identifier.swiftMethodCounterpart];
        }
    }

    XCTTestIdentifier *swiftIdentifier = [[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:stringRepresentation];
    if (swiftIdentifier == nil) {
        // Only the empty string reaches here, since anything non-empty parses.
        return NO;
    }
    [self addTestIdentifier:swiftIdentifier];

    // A bare suite name in a selection is ambiguous between "this suite" and
    // "every test in it", and a suite that is also a test is the one case where
    // reading the name as a leaf is not wrong. So the name is added a second
    // time, as a leaf, but only when the suite is not itself a Swift method.
    if (identifier.componentCount == 1 && !swiftIdentifier.isSwiftMethod) {
        [self addTestIdentifier:[[XCTTestIdentifier alloc] initWithComponents:identifier.components
                                                                   isContainer:NO]];
    }
    return YES;
}

- (BOOL)addTestIdentifierWithLegacyStringRepresentation:(NSString *)stringRepresentation
                                includingSwiftCounterpart:(BOOL)includingSwiftCounterpart
{
    XCTTestIdentifier *identifier = [[XCTTestIdentifier alloc] initWithStringRepresentation:stringRepresentation
                                                                    preserveModulePrefix:YES];
    if (identifier == nil) {
        // The legacy spelling is a subset of the current one, so the current
        // parser is the one that has to be the judge of whether a string is one.
        return NO;
    }
    [self addTestIdentifier:identifier];
    if (includingSwiftCounterpart) {
        [self addTestIdentifier:identifier.swiftMethodCounterpart];
    }
    return YES;
}

- (void)removeTestIdentifier:(XCTTestIdentifier *)identifier
{
    if (identifier != nil) {
        [_testIdentifiers removeObject:identifier];
    }
}

- (void)removeAllTestIdentifiers
{
    [_testIdentifiers removeAllObjects];
}

- (void)unionSet:(XCTTestIdentifierSet *)set
{
    // The identity check is not in the reference, and is here deliberately: the
    // storage being added to is the storage being enumerated, and a mutable set
    // enumerated while it is being added to raises rather than finishing. A
    // caller that passes a builder to itself means "no change", so that is what
    // it gets, instead of an exception.
    if (set == nil || set == self) {
        return;
    }
    NSMutableSet<XCTTestIdentifier *> *storage = self.xctMutableIdentifiers;
    for (XCTTestIdentifier *identifier in set) {
        [storage addObject:identifier];
    }
}

- (void)unionBuilder:(XCTTestIdentifierSetBuilder *)builder
{
    [self unionSet:builder];
}

- (void)minusSet:(XCTTestIdentifierSet *)set
{
    // As in -unionSet:, and for the same reason: subtracting a set from itself
    // while enumerating it would raise, and "no change" is the only reading of
    // it that is true.
    if (set == nil || set == self) {
        return;
    }
    NSMutableSet<XCTTestIdentifier *> *storage = self.xctMutableIdentifiers;
    for (XCTTestIdentifier *identifier in set) {
        [storage removeObject:identifier];
    }
}

- (void)minusBuilder:(XCTTestIdentifierSetBuilder *)builder
{
    [self minusSet:builder];
}

- (XCTTestIdentifierSet *)testIdentifierSet
{
    return [[XCTTestIdentifierSet alloc] initWithSet:self];
}

- (NSSet<XCTTestIdentifier *> *)testIdentifiers
{
    return self.xctMutableIdentifiers;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    XCTTestIdentifierSetBuilder *copy = [[[self class] allocWithZone:zone] init];
    [copy unionSet:self];
    return copy;
}

@end

#pragma mark - XCTTestSelection

@implementation XCTTestSelection
{
    XCTTestIdentifierSet *_identifiersToRun;
    XCTTestIdentifierSet *_identifiersToSkip;
    XCTTagSelection *_tagsToRun;
    XCTTagSelection *_tagsToSkip;
}

- (instancetype)init
{
    return [self initWithIdentifiersToRun:nil identifiersToSkip:nil tagsToRun:nil tagsToSkip:nil];
}

- (instancetype)initWithIdentifiersToRun:(XCTTestIdentifierSet *)identifiersToRun
                       identifiersToSkip:(XCTTestIdentifierSet *)identifiersToSkip
                            tagsToRun:(XCTTagSelection *)tagsToRun
                           tagsToSkip:(XCTTagSelection *)tagsToSkip
{
    self = [super init];
    if (self) {
        _identifiersToRun = [identifiersToRun copy];
        _identifiersToSkip = [identifiersToSkip copy];
        _tagsToRun = [tagsToRun copy];
        _tagsToSkip = [tagsToSkip copy];
    }
    return self;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // Four keys, none guarded. Every one of the four defaults to "no opinion",
    // and nil decodes to exactly that, so there is nothing to distinguish
    // "absent" from "present and nil" and nothing to fall back to.
    //
    // Each is decoded with -decodeObjectOfClass:forKey: rather than the plural
    // form: each field has one exact type, and an archive that puts anything
    // else there is corrupt rather than merely different.
    XCTTestIdentifierSet *identifiersToRun = [coder decodeObjectOfClass:[XCTTestIdentifierSet class]
                                                                forKey:@"IdentifiersToRun"];
    XCTTestIdentifierSet *identifiersToSkip = [coder decodeObjectOfClass:[XCTTestIdentifierSet class]
                                                                 forKey:@"IdentifiersToSkip"];
    XCTTagSelection *tagsToRun = [coder decodeObjectOfClass:[XCTTagSelection class] forKey:@"TagsToRun"];
    XCTTagSelection *tagsToSkip = [coder decodeObjectOfClass:[XCTTagSelection class] forKey:@"TagsToSkip"];

    self = [self initWithIdentifiersToRun:identifiersToRun
                       identifiersToSkip:identifiersToSkip
                            tagsToRun:tagsToRun
                           tagsToSkip:tagsToSkip];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.identifiersToRun forKey:@"IdentifiersToRun"];
    [coder encodeObject:self.identifiersToSkip forKey:@"IdentifiersToSkip"];
    [coder encodeObject:self.tagsToRun forKey:@"TagsToRun"];
    [coder encodeObject:self.tagsToSkip forKey:@"TagsToSkip"];
}

- (XCTTestIdentifierSet *)identifiersToRun
{
    return _identifiersToRun;
}

- (void)setIdentifiersToRun:(XCTTestIdentifierSet *)identifiersToRun
{
    _identifiersToRun = [identifiersToRun copy];
}

- (XCTTestIdentifierSet *)identifiersToSkip
{
    return _identifiersToSkip;
}

- (void)setIdentifiersToSkip:(XCTTestIdentifierSet *)identifiersToSkip
{
    _identifiersToSkip = [identifiersToSkip copy];
}

- (XCTTagSelection *)tagsToRun
{
    return _tagsToRun;
}

- (void)setTagsToRun:(XCTTagSelection *)tagsToRun
{
    _tagsToRun = [tagsToRun copy];
}

- (XCTTagSelection *)tagsToSkip
{
    return _tagsToSkip;
}

- (void)setTagsToSkip:(XCTTagSelection *)tagsToSkip
{
    _tagsToSkip = [tagsToSkip copy];
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTTestSelection class]]) {
        return NO;
    }
    XCTTestSelection *other = object;
    // nil == nil is the same answer as "absent in both archives", so a plain
    // -isEqual: per field is right here. A run asking "did the selection
    // change" must not be told it did because one archive spelled an empty
    // selection and the other omitted it.
    return (self.identifiersToRun == other.identifiersToRun ||
            [self.identifiersToRun isEqual:other.identifiersToRun]) &&
           (self.identifiersToSkip == other.identifiersToSkip ||
            [self.identifiersToSkip isEqual:other.identifiersToSkip]) &&
           (self.tagsToRun == other.tagsToRun || [self.tagsToRun isEqual:other.tagsToRun]) &&
           (self.tagsToSkip == other.tagsToSkip || [self.tagsToSkip isEqual:other.tagsToSkip]);
}

- (NSUInteger)hash
{
    return self.identifiersToRun.hash ^ self.identifiersToSkip.hash ^ self.tagsToRun.hash ^
           self.tagsToSkip.hash;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithIdentifiersToRun:self.identifiersToRun
                                                      identifiersToSkip:self.identifiersToSkip
                                                           tagsToRun:self.tagsToRun
                                                          tagsToSkip:self.tagsToSkip];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p;\n\tidentifiersToRun: %@\n\tidentifiersToSkip: %@"
                                      @"\n\ttagsToRun: %@\n\ttagsToSkip: %@>",
                                      NSStringFromClass(self.class), self,
                                      self.identifiersToRun ?: @"(none)",
                                      self.identifiersToSkip ?: @"(none)", self.tagsToRun ?: @"(none)",
                                      self.tagsToSkip ?: @"(none)"];
}

@end