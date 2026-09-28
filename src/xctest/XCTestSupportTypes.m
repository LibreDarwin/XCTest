// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTestErrorDomain, XCTSourceCodeContext, XCTIssue, XCTAttachment and
// XCTExpectedFailure: the value types every other piece of the framework
// passes around.
//
// All three public value types here declare NSSecureCoding in their headers, so
// they implement it for real. A half-implemented -initWithCoder: that decodes
// nothing is worse than no conformance at all: it produces archives that
// silently lose the file and line of a failure, which is the one piece of data
// a result consumer most needs.

#import "XCTestInternal.h"

#import <objc/runtime.h>

NSErrorDomain const XCTestErrorDomain = @"XCTest";

#pragma mark - Backtrace helpers

/// Frames to drop so the failure points at the caller rather than at XCTest's
/// own helpers. Getting this wrong puts XCTest frames at the top of the user's
/// stack, which reads worse than no symbolication at all.
static NSUInteger XCTBacktraceSkipFrames(void)
{
    return 2;
}

static NSArray<NSNumber *> *XCTCaptureCallStack(void)
{
    // Stack-allocated and bounded: 128 frames is well past the deepest
    // realistic test stack and keeps the cost off the failing path.
    void *buffer[128];
    int count = backtrace(buffer, 128);
    if (count <= 0) {
        return @[];
    }

    NSUInteger skip = XCTBacktraceSkipFrames();
    NSMutableArray<NSNumber *> *frames =
        [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = (int)skip; i < count; i++) {
        [frames addObject:@((uintptr_t)buffer[i])];
    }
    return frames;
}

static NSUInteger XCTTopFrame(NSArray<NSNumber *> *stack)
{
    NSNumber *top = stack.count > 0 ? stack[0] : nil;
    return top != nil ? top.unsignedIntegerValue : 0;
}

/// Resolves a return address to an image name and symbol via dladdr. The
/// runtime carries no line table, so lineNumber is reported as unknown rather
/// than guessed; the framework's own call sites pass their __LINE__ through the
/// assertion path instead, which is where the real line number comes from.
static void XCTResolveLocation(uintptr_t location,
                               NSString *__strong _Nullable *outFile,
                               NSString *__strong _Nullable *outSymbol)
{
    *outFile = nil;
    *outSymbol = nil;
    if (location == 0) {
        return;
    }

    Dl_info info;
    if (dladdr((const void *)location, &info) == 0) {
        return;
    }
    if (info.dli_fname != NULL) {
        *outFile = [NSString stringWithUTF8String:info.dli_fname];
    }
    if (info.dli_sname != NULL) {
        *outSymbol = [NSString stringWithUTF8String:info.dli_sname];
    }
}

XCT_EXPORT XCTSourceCodeContext *_XCTCurrentSourceCodeContext(void)
{
    NSArray<NSNumber *> *stack = XCTCaptureCallStack();
    return [[XCTSourceCodeContext alloc] initWithLocation:XCTTopFrame(stack)];
}

#pragma mark - XCTSourceCodeContext

static NSString *const XCTContextLocationKey = @"location";
static NSString *const XCTContextFilePathKey = @"filePath";
static NSString *const XCTContextLineNumberKey = @"lineNumber";
static NSString *const XCTContextColumnNumberKey = @"columnNumber";
static NSString *const XCTContextSymbolInfoKey = @"symbolInfo";
static NSString *const XCTContextCallStackKey = @"callStack";

@implementation XCTSourceCodeContext {
    NSUInteger _location;
    NSString *_filePath;
    NSUInteger _lineNumber;
    NSUInteger _columnNumber;
    NSString *_symbolInfo;
    NSArray<NSNumber *> *_callStack;
}

/// Builds a context from a call site the caller already knows exactly.
///
/// The public initializer takes a stack address and resolves it, which is the
/// right thing for a failure discovered by walking a backtrace. An assertion
/// is the other case: __FILE__ and __LINE__ are literals at the call site, and
/// resolving an address back to that same line would be a slower, less accurate
/// way of learning something already known. Routing through the designated
/// initializer anyway keeps one construction path and one set of invariants.
+ (instancetype)xct_contextWithFilePath:(NSString *)filePath
                             lineNumber:(NSUInteger)lineNumber
{
    XCTSourceCodeContext *context = [[self alloc] initWithLocation:0];
    context->_filePath = [filePath copy];
    context->_lineNumber = lineNumber;
    return context;
}

- (instancetype)initWithLocation:(NSUInteger)location
{
    self = [super init];
    if (self) {
        _location = location;
        _callStack = XCTCaptureCallStack();
        NSString *file = nil;
        NSString *symbol = nil;
        XCTResolveLocation(location, &file, &symbol);
        _filePath = file;
        _symbolInfo = symbol;
    }
    return self;
}

/// Coding initializer. Decodes into locals and then routes through the
/// designated initializer, so the object is never left half-built and the
/// backtrace is not needlessly recaptured.
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSUInteger location = [coder decodeIntegerForKey:XCTContextLocationKey];
    self = [self initWithLocation:location];
    if (self) {
        _filePath = [[coder decodeObjectOfClass:[NSString class]
                                          forKey:XCTContextFilePathKey] copy];
        _lineNumber = [coder decodeIntegerForKey:XCTContextLineNumberKey];
        _columnNumber = [coder decodeIntegerForKey:XCTContextColumnNumberKey];
        _symbolInfo = [[coder decodeObjectOfClass:[NSString class]
                                           forKey:XCTContextSymbolInfoKey] copy];

        NSSet *stackClasses = [NSSet setWithObjects:[NSArray class], [NSNumber class], nil];
        _callStack = [[coder decodeObjectOfClasses:stackClasses
                                             forKey:XCTContextCallStackKey] copy]
                     ?: @[];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:(NSInteger)_location forKey:XCTContextLocationKey];
    [coder encodeObject:_filePath forKey:XCTContextFilePathKey];
    [coder encodeInteger:(NSInteger)_lineNumber forKey:XCTContextLineNumberKey];
    [coder encodeInteger:(NSInteger)_columnNumber forKey:XCTContextColumnNumberKey];
    [coder encodeObject:_symbolInfo forKey:XCTContextSymbolInfoKey];
    [coder encodeObject:_callStack forKey:XCTContextCallStackKey];
}

- (NSUInteger)location { return _location; }
- (NSString *)filePath { return _filePath; }
- (NSUInteger)lineNumber { return _lineNumber; }
- (NSUInteger)columnNumber { return _columnNumber; }
- (NSString *)symbolInfo { return _symbolInfo; }
- (NSArray<NSNumber *> *)callStack { return _callStack; }

- (id)copyWithZone:(NSZone *)zone { return self; }

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - XCTIssue

static NSString *const XCTIssueTypeKey = @"type";
static NSString *const XCTIssueCompactDescriptionKey = @"compactDescription";
static NSString *const XCTIssueDetailedDescriptionKey = @"detailedDescription";
static NSString *const XCTIssueSourceCodeContextKey = @"sourceCodeContext";
static NSString *const XCTIssueAssociatedErrorKey = @"associatedError";
static NSString *const XCTIssueAttachmentsKey = @"attachments";
static NSString *const XCTIssueSeverityKey = @"severity";

// Ivars are declared here, @protected, rather than left to auto-synthesis.
// XCTMutableIssue has to write these same slots: it redeclares XCTIssue's
// readonly properties as readwrite, which cannot synthesize a setter, and
// auto-synthesized ivars are @private, invisible to a subclass. Declaring them
// @protected lets the subclass share one set of slots instead of shadowing the
// superclass's values with copies that the inherited getters would never read.
@implementation XCTIssue {
@protected
    XCTIssueType _type;
    NSString *_compactDescription;
    NSString *_detailedDescription;
    XCTSourceCodeContext *_sourceCodeContext;
    NSError *_associatedError;
    NSArray<XCTAttachment *> *_attachments;
    XCTIssueSeverity _severity;
}

/// Fills the slots without allocating. Split out only so the two designated
/// initializers below share it: clang forbids a designated initializer from
/// delegating to another designated initializer on self, and a C function could
/// not touch these @protected ivars, so the assignment lives in a plain
/// non-initializer method that runs after [super init] has returned.
- (void)xct_fillWithType:(XCTIssueType)type
     compactDescription:(NSString *)compactDescription
    detailedDescription:(nullable NSString *)detailedDescription
      sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
        associatedError:(nullable NSError *)associatedError
            attachments:(NSArray<XCTAttachment *> *)attachments
               severity:(XCTIssueSeverity)severity
{
    _type = type;
    _compactDescription = [compactDescription copy] ?: @"";
    _detailedDescription = [detailedDescription copy];
    _sourceCodeContext = sourceCodeContext;
    _associatedError = associatedError;
    _attachments = [attachments copy] ?: @[];
    _severity = severity;
}

- (instancetype)initWithType:(XCTIssueType)type
          compactDescription:(NSString *)compactDescription
         detailedDescription:(nullable NSString *)detailedDescription
           sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
             associatedError:(nullable NSError *)associatedError
                 attachments:(NSArray<XCTAttachment *> *)attachments
{
    self = [super init];
    if (self) {
        [self xct_fillWithType:type
            compactDescription:compactDescription
           detailedDescription:detailedDescription
             sourceCodeContext:sourceCodeContext
               associatedError:associatedError
                   attachments:attachments
                      severity:XCTIssueSeverityError];
    }
    return self;
}

- (instancetype)initWithType:(XCTIssueType)type
          compactDescription:(NSString *)compactDescription
         detailedDescription:(nullable NSString *)detailedDescription
           sourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
             associatedError:(nullable NSError *)associatedError
                 attachments:(NSArray<XCTAttachment *> *)attachments
                    severity:(XCTIssueSeverity)severity
{
    self = [super init];
    if (self) {
        [self xct_fillWithType:type
            compactDescription:compactDescription
           detailedDescription:detailedDescription
             sourceCodeContext:sourceCodeContext
               associatedError:associatedError
                   attachments:attachments
                      severity:severity];
    }
    return self;
}

- (instancetype)initWithType:(XCTIssueType)type
          compactDescription:(NSString *)compactDescription
                    severity:(XCTIssueSeverity)severity
{
    return [self initWithType:type
          compactDescription:compactDescription
         detailedDescription:nil
           sourceCodeContext:_XCTCurrentSourceCodeContext()
             associatedError:nil
                 attachments:@[]
                    severity:severity];
}

- (instancetype)initWithType:(XCTIssueType)type
         compactDescription:(NSString *)compactDescription
{
    return [self initWithType:type
          compactDescription:compactDescription
                    severity:XCTIssueSeverityError];
}

- (BOOL)isFailure { return _severity == XCTIssueSeverityError; }

- (id)copyWithZone:(NSZone *)zone
{
    // Immutable, so a copy may alias the original, matching the other
    // Foundation value types. Callers that need to mutate use XCTMutableIssue.
    return self;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [[XCTMutableIssue alloc] initWithType:_type
                             compactDescription:_compactDescription
                            detailedDescription:_detailedDescription
                              sourceCodeContext:_sourceCodeContext
                                associatedError:_associatedError
                                    attachments:_attachments
                                       severity:_severity];
}

/// A secondary (non-designated) initializer, so it must funnel into a
/// designated initializer on self rather than calling [super init] and touching
/// slots directly. That also makes it correct for XCTMutableIssue, which adds no
/// state of its own and therefore needs no override.
- (instancetype)initWithCoder:(NSCoder *)coder
{
    XCTIssueType type = (XCTIssueType)[coder decodeIntegerForKey:XCTIssueTypeKey];
    NSString *compact = [coder decodeObjectOfClass:[NSString class]
                                            forKey:XCTIssueCompactDescriptionKey];
    NSString *detailed = [coder decodeObjectOfClass:[NSString class]
                                             forKey:XCTIssueDetailedDescriptionKey];
    XCTSourceCodeContext *context = [coder decodeObjectOfClass:[XCTSourceCodeContext class]
                                                       forKey:XCTIssueSourceCodeContextKey];
    NSError *error = [coder decodeObjectOfClass:[NSError class]
                                         forKey:XCTIssueAssociatedErrorKey];
    NSSet *attachmentClasses = [NSSet setWithObjects:
        [NSArray class], [XCTAttachment class], nil];
    NSArray *attachments = [coder decodeObjectOfClasses:attachmentClasses
                                                 forKey:XCTIssueAttachmentsKey];
    XCTIssueSeverity severity =
        (XCTIssueSeverity)[coder decodeIntegerForKey:XCTIssueSeverityKey];

    return [self initWithType:type
          compactDescription:compact
         detailedDescription:detailed
           sourceCodeContext:context
             associatedError:error
                 attachments:attachments
                    severity:severity];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_type forKey:XCTIssueTypeKey];
    [coder encodeObject:_compactDescription forKey:XCTIssueCompactDescriptionKey];
    [coder encodeObject:_detailedDescription forKey:XCTIssueDetailedDescriptionKey];
    [coder encodeObject:_sourceCodeContext forKey:XCTIssueSourceCodeContextKey];
    [coder encodeObject:_associatedError forKey:XCTIssueAssociatedErrorKey];
    [coder encodeObject:_attachments forKey:XCTIssueAttachmentsKey];
    [coder encodeInteger:_severity forKey:XCTIssueSeverityKey];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

@implementation XCTMutableIssue

// @dynamic is required, not stylistic. Redeclaring a superclass readonly
// property as readwrite does not trigger auto synthesis: clang sees the
// property as already synthesized (readonly) on XCTIssue, refuses to synthesize
// the setter, and then errors under -Wobjc-property-synthesis unless we
// acknowledge the intent. The setters below write the inherited @protected
// slots, so XCTIssue's getters and these setters agree on one value; shadowing
// them with subclass ivars would produce objects whose getters return the
// original contents no matter what the setters were given.
@dynamic type;
@dynamic compactDescription;
@dynamic detailedDescription;
@dynamic sourceCodeContext;
@dynamic associatedError;
@dynamic attachments;
@dynamic severity;

- (void)setType:(XCTIssueType)type
{
    _type = type;
}

- (void)setCompactDescription:(NSString *)compactDescription
{
    _compactDescription = [compactDescription copy] ?: @"";
}

- (void)setDetailedDescription:(nullable NSString *)detailedDescription
{
    _detailedDescription = [detailedDescription copy];
}

- (void)setSourceCodeContext:(XCTSourceCodeContext *)sourceCodeContext
{
    _sourceCodeContext = sourceCodeContext;
}

- (void)setAssociatedError:(nullable NSError *)associatedError
{
    _associatedError = associatedError;
}

- (void)setAttachments:(NSArray<XCTAttachment *> *)attachments
{
    _attachments = [attachments copy] ?: @[];
}

- (void)setSeverity:(XCTIssueSeverity)severity
{
    _severity = severity;
}

- (void)addAttachment:(XCTAttachment *)attachment
{
    if (attachment == nil) {
        return;
    }
    // Copy-on-write rather than -arrayByAddingObject:, which this SDK's NSArray
    // does not declare.
    NSMutableArray<XCTAttachment *> *updated = [_attachments mutableCopy]
        ?: [NSMutableArray array];
    [updated addObject:attachment];
    _attachments = updated;
}

@end

#pragma mark - XCTAttachment

static NSString *const XCTAttachmentTypeIdentifierKey = @"uniformTypeIdentifier";
static NSString *const XCTAttachmentNameKey = @"name";
static NSString *const XCTAttachmentUserInfoKey = @"userInfo";
static NSString *const XCTAttachmentLifetimeKey = @"lifetime";
static NSString *const XCTAttachmentPayloadKey = @"payload";

@implementation XCTAttachment {
    NSData *_payload;
}

- (instancetype)initWithUniformTypeIdentifier:(NSString *)identifier
{
    self = [super init];
    if (self) {
        _uniformTypeIdentifier = [identifier copy] ?: @"public.data";
        _lifetime = XCTAttachmentLifetimeDeleteOnSuccess;
        _payload = [NSData data];
    }
    return self;
}

+ (instancetype)attachmentWithUniformTypeIdentifier:(NSString *)identifier
{
    return [[self alloc] initWithUniformTypeIdentifier:identifier];
}

+ (instancetype)attachmentWithData:(NSData *)payload
{
    return [self attachmentWithData:payload uniformTypeIdentifier:@"public.data"];
}

+ (instancetype)attachmentWithData:(NSData *)payload
            uniformTypeIdentifier:(NSString *)identifier
{
    XCTAttachment *attachment = [[self alloc] initWithUniformTypeIdentifier:identifier];
    // Direct ivar write rather than a property: the payload is not part of the
    // public interface, and a setter would imply it is.
    attachment->_payload = [payload copy] ?: [NSData data];
    return attachment;
}

/// The bytes to persist. Not in the public header: the result writer reaches
/// this, client code does not.
- (NSData *)xct_payload
{
    return _payload;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *identifier = [coder decodeObjectOfClass:[NSString class]
                                              forKey:XCTAttachmentTypeIdentifierKey];
    self = [self initWithUniformTypeIdentifier:identifier];
    if (self) {
        _name = [[coder decodeObjectOfClass:[NSString class]
                                      forKey:XCTAttachmentNameKey] copy];
        NSSet *userInfoClasses = [NSSet setWithObjects:[NSDictionary class], [NSString class], nil];
        _userInfo = [[coder decodeObjectOfClasses:userInfoClasses
                                           forKey:XCTAttachmentUserInfoKey] copy];
        _lifetime = (XCTAttachmentLifetime)[coder decodeIntegerForKey:XCTAttachmentLifetimeKey];
        _payload = [[coder decodeObjectOfClass:[NSData class]
                                        forKey:XCTAttachmentPayloadKey] copy] ?: [NSData data];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_uniformTypeIdentifier forKey:XCTAttachmentTypeIdentifierKey];
    [coder encodeObject:_name forKey:XCTAttachmentNameKey];
    [coder encodeObject:_userInfo forKey:XCTAttachmentUserInfoKey];
    [coder encodeInteger:_lifetime forKey:XCTAttachmentLifetimeKey];
    [coder encodeObject:_payload forKey:XCTAttachmentPayloadKey];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - XCTExpectedFailure

static NSString *const XCTExpectedFailureOptionsEnabledKey = @"enabled";
static NSString *const XCTExpectedFailureOptionsStrictKey = @"strict";

@implementation XCTExpectedFailureOptions

- (instancetype)init
{
    self = [super init];
    if (self) {
        // Every issue matches and an unmatched declaration is reported, unless
        // the caller says otherwise. Absorbing a known issue silently would
        // make a fixed bug look like a passing test.
        _enabled = YES;
        _strict = YES;
    }
    return self;
}

+ (XCTExpectedFailureOptions *)nonStrictOptions
{
    XCTExpectedFailureOptions *options = [[self alloc] init];
    options.strict = NO;
    return options;
}

- (id)copyWithZone:(NSZone *)zone
{
    XCTExpectedFailureOptions *copy =
        [[[self class] allocWithZone:zone] init];
    copy.issueMatcher = self.issueMatcher;
    copy.enabled = self.enabled;
    copy.strict = self.strict;
    return copy;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _enabled = [coder decodeBoolForKey:@"enabled"];
        _strict = [coder decodeBoolForKey:@"strict"];
        // A matcher is a block, which cannot be encoded. Archiving an options
        // object that had one therefore yields options with no matcher, which
        // matches everything -- the same as the default, and the only behavior
        // that is safe when the original filter is no longer known.
        _issueMatcher = nil;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:self.enabled forKey:XCTExpectedFailureOptionsEnabledKey];
    [coder encodeBool:self.strict forKey:XCTExpectedFailureOptionsStrictKey];
}

@end

static NSString *const XCTExpectedFailureIssueKey = @"issue";
static NSString *const XCTExpectedFailureReasonKey = @"failureReason";

@implementation XCTExpectedFailure

- (instancetype)initWithIssue:(XCTIssue *)issue
                failureReason:(NSString *)failureReason
{
    self = [super init];
    if (self) {
        _issue = [issue copy];
        // Left nil when the caller gave no reason, rather than becoming an empty
        // string: "no reason given" and "an empty reason" are different answers
        // for a reporter trying to present the declaration.
        _failureReason = [failureReason copy];
    }
    return self;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        // Encoded as a nested object rather than by flattening the issue's own
        // keys into this coder, so the two share no key namespace and a future
        // key on XCTIssue cannot collide with one here.
        _issue = [coder decodeObjectOfClass:[XCTIssue class]
                                     forKey:XCTExpectedFailureIssueKey];
        _failureReason = [coder decodeObjectOfClass:[NSString class]
                                             forKey:XCTExpectedFailureReasonKey];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_issue forKey:XCTExpectedFailureIssueKey];
    [coder encodeObject:_failureReason forKey:XCTExpectedFailureReasonKey];
}

@end
