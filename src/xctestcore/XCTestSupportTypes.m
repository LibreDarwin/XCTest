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

/// Resolves a return address to its image and symbol via dladdr.
///
/// The runtime carries no line table, so a resolved symbol has no
/// XCTSourceCodeLocation: the address says which function it is in, and nothing
/// more. That is why the framework's own call sites pass their __LINE__ through
/// the assertion path instead -- that is the only place a real line number
/// comes from.
static XCTSourceCodeSymbolInfo *_Nullable XCTSymbolInfoForAddress(uintptr_t address)
{
    if (address == 0) {
        return nil;
    }
    Dl_info info;
    if (dladdr((const void *)address, &info) == 0) {
        return nil;
    }
    if (info.dli_fname == NULL) {
        // dladdr can succeed with no image name for a main executable built
        // without it. A symbol without an image is not much use, but it is
        // still the best answer available, so the name is reported as empty
        // rather than the whole symbol discarded.
        return [[XCTSourceCodeSymbolInfo alloc] initWithImageName:@""
                                                      symbolName:info.dli_sname != NULL
                                                                    ? @(info.dli_sname)
                                                                    : @""
                                                        location:nil];
    }
    return [[XCTSourceCodeSymbolInfo alloc] initWithImageName:@(info.dli_fname)
                                                  symbolName:info.dli_sname != NULL
                                                                ? @(info.dli_sname)
                                                                : @""
                                                    location:nil];
}

XCT_EXPORT XCTSourceCodeContext *_XCTCurrentSourceCodeContext(void)
{
    return [[XCTSourceCodeContext alloc] init];
}

#pragma mark - XCTSourceCodeLocation

static NSString *const XCTLocationFileURLKey = @"fileURL";
static NSString *const XCTLocationLineNumberKey = @"lineNumber";

@implementation XCTSourceCodeLocation {
    NSURL *_fileURL;
    NSInteger _lineNumber;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL lineNumber:(NSInteger)lineNumber
{
    self = [super init];
    if (self) {
        _fileURL = [fileURL copy];
        _lineNumber = lineNumber;
    }
    return self;
}

/// A path, not a URL. __FILE__ is a path and the assertion path has nothing
/// else, so refusing to build a location from one would leave every assertion
/// without a file. The URL is built relative to nothing in particular: it is a
/// file:// URL carrying the path the compiler was given, which is the same
/// string the old -filePath property returned, and no attempt is made to
/// resolve symlinks or absolutise it, because the caller may well be reporting a
/// file that no longer exists on this machine.
- (instancetype)initWithFilePath:(NSString *)filePath lineNumber:(NSInteger)lineNumber
{
    return [self initWithFileURL:[NSURL fileURLWithPath:filePath]
                      lineNumber:lineNumber];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // Decoded into locals and routed through the designated initializer, so the
    // object is never left half-built.
    NSURL *fileURL = [coder decodeObjectOfClass:[NSURL class] forKey:XCTLocationFileURLKey];
    NSInteger lineNumber = [coder decodeIntegerForKey:XCTLocationLineNumberKey];
    return [self initWithFileURL:fileURL lineNumber:lineNumber];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_fileURL forKey:XCTLocationFileURLKey];
    [coder encodeInteger:_lineNumber forKey:XCTLocationLineNumberKey];
}

- (NSURL *)fileURL { return _fileURL; }
- (NSInteger)lineNumber { return _lineNumber; }

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTSourceCodeLocation class]]) {
        return NO;
    }
    XCTSourceCodeLocation *other = object;
    return _lineNumber == other->_lineNumber && (_fileURL == other->_fileURL || [_fileURL isEqual:other->_fileURL]);
}

- (NSUInteger)hash
{
    return _fileURL.hash ^ (NSUInteger)_lineNumber;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@:%ld", _fileURL.path ?: @"(none)", (long)_lineNumber];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - XCTSourceCodeSymbolInfo

static NSString *const XCTSymbolImageNameKey = @"imageName";
static NSString *const XCTSymbolSymbolNameKey = @"symbolName";
static NSString *const XCTSymbolLocationKey = @"location";

@implementation XCTSourceCodeSymbolInfo {
    NSString *_imageName;
    NSString *_symbolName;
    XCTSourceCodeLocation *_location;
}

- (instancetype)initWithImageName:(NSString *)imageName
                       symbolName:(NSString *)symbolName
                         location:(XCTSourceCodeLocation *)location
{
    self = [super init];
    if (self) {
        _imageName = [imageName copy];
        _symbolName = [symbolName copy];
        _location = location;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *imageName = [coder decodeObjectOfClass:[NSString class]
                                              forKey:XCTSymbolImageNameKey];
    NSString *symbolName = [coder decodeObjectOfClass:[NSString class]
                                               forKey:XCTSymbolSymbolNameKey];
    XCTSourceCodeLocation *location = [coder decodeObjectOfClass:[XCTSourceCodeLocation class]
                                                          forKey:XCTSymbolLocationKey];
    return [self initWithImageName:imageName symbolName:symbolName location:location];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_imageName forKey:XCTSymbolImageNameKey];
    [coder encodeObject:_symbolName forKey:XCTSymbolSymbolNameKey];
    [coder encodeObject:_location forKey:XCTSymbolLocationKey];
}

- (NSString *)imageName { return _imageName; }
- (NSString *)symbolName { return _symbolName; }
- (XCTSourceCodeLocation *)location { return _location; }

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTSourceCodeSymbolInfo class]]) {
        return NO;
    }
    XCTSourceCodeSymbolInfo *other = object;
    return (_imageName == other->_imageName || [_imageName isEqual:other->_imageName]) &&
           (_symbolName == other->_symbolName || [_symbolName isEqual:other->_symbolName]) &&
           (_location == other->_location || [_location isEqual:other->_location]);
}

- (NSUInteger)hash
{
    return _imageName.hash ^ _symbolName.hash;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ in %@", _symbolName, _imageName];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - XCTSourceCodeFrame

static NSString *const XCTFrameAddressKey = @"address";
static NSString *const XCTFrameSymbolInfoKey = @"symbolInfo";

/// A private code for dladdr failures, kept out of the XCTestErrorCode range:
/// 0 and 1 are already XCTestErrorCodeTimeoutWhileWaiting and
/// XCTestErrorCodeFailureWhileWaiting, and a symbolication failure reporting
/// itself as either would be indistinguishable from a wait that failed.
/// Private, because nothing in the public API promises a code here.
static const NSInteger XCTSymbolicationErrorCode = 1000;

static NSError *XCTSymbolicationError(uintptr_t address)
{
    return [NSError errorWithDomain:XCTestErrorDomain
                               code:XCTSymbolicationErrorCode
                           userInfo:@{
                               NSLocalizedDescriptionKey: [NSString stringWithFormat:
                                   @"no symbol information for address 0x%lx",
                                   (unsigned long)address]
                           }];
}

@implementation XCTSourceCodeFrame {
    uint64_t _address;
    XCTSourceCodeSymbolInfo *_symbolInfo;
    // Set once -symbolInfoWithError: has run, so that a second call reports the
    // first outcome rather than asking dladdr again. NOT encoded: it describes
    // this process's attempt, and a decoded frame has made none.
    BOOL _symbolicationAttempted;
    NSError *_symbolicationError;
}

- (instancetype)initWithAddress:(uint64_t)address
                    symbolInfo:(XCTSourceCodeSymbolInfo *)symbolInfo
{
    self = [super init];
    if (self) {
        _address = address;
        _symbolInfo = symbolInfo;
        // A symbol handed in is an answer, so the lazy path must not ask again.
        _symbolicationAttempted = symbolInfo != nil;
    }
    return self;
}

- (instancetype)initWithAddress:(uint64_t)address
{
    return [self initWithAddress:address symbolInfo:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    uint64_t address = (uint64_t)[coder decodeInt64ForKey:XCTFrameAddressKey];
    XCTSourceCodeSymbolInfo *symbolInfo = [coder decodeObjectOfClass:[XCTSourceCodeSymbolInfo class]
                                                              forKey:XCTFrameSymbolInfoKey];
    return [self initWithAddress:address symbolInfo:symbolInfo];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt64:(int64_t)_address forKey:XCTFrameAddressKey];
    [coder encodeObject:_symbolInfo forKey:XCTFrameSymbolInfoKey];
}

- (uint64_t)address { return _address; }
- (XCTSourceCodeSymbolInfo *)symbolInfo { return _symbolInfo; }
- (NSError *)symbolicationError { return _symbolicationError; }

- (XCTSourceCodeSymbolInfo *)symbolInfoWithError:(NSError **)outError
{
    if (!_symbolicationAttempted) {
        _symbolicationAttempted = YES;
        _symbolInfo = XCTSymbolInfoForAddress((uintptr_t)_address);
        if (_symbolInfo == nil) {
            _symbolicationError = XCTSymbolicationError((uintptr_t)_address);
        }
    }
    if (outError != NULL) {
        *outError = _symbolicationError;
    }
    return _symbolInfo;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTSourceCodeFrame class]]) {
        return NO;
    }
    XCTSourceCodeFrame *other = object;
    // Only the address, deliberately. A frame that has not been symbolicated is
    // the same frame as one that has, and two frames equal if they are the same
    // return address; whether this process has looked it up yet is not part of
    // what the frame is. Including _symbolInfo would make equality depend on
    // call order.
    return _address == other->_address;
}

- (NSUInteger)hash { return (NSUInteger)_address; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)_address];
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - XCTSourceCodeContext

static NSString *const XCTContextCallStackKey = @"callStack";
static NSString *const XCTContextLocationKey = @"location";

/// The current thread's return addresses, innermost first, with the framework's
/// own frames removed.
static NSArray<NSNumber *> *XCTCaptureCallStack(void);

@implementation XCTSourceCodeContext {
    NSArray<XCTSourceCodeFrame *> *_callStack;
    XCTSourceCodeLocation *_location;
}

/// A context for a call site the caller already knows exactly.
///
/// The public initializers all describe a place by resolving a stack, which is
/// right for a failure found by walking a backtrace and wrong for an assertion:
/// __FILE__ and __LINE__ are literals at the call site, and the address of the
/// assertion helper cannot be resolved back to that line -- the runtime has no
/// line table, so it would report a symbol and an unknown line where the real
/// line number was already in hand. So the location is built from the literals
/// and the stack is left to the initializer, which captures the current thread
/// the same way it does for any other context.
+ (instancetype)xct_contextWithFilePath:(NSString *)filePath
                             lineNumber:(NSUInteger)lineNumber
{
    XCTSourceCodeLocation *location =
        [[XCTSourceCodeLocation alloc] initWithFilePath:filePath
                                             lineNumber:(NSInteger)lineNumber];
    return [[XCTSourceCodeContext alloc] initWithLocation:location];
}

- (instancetype)initWithCallStack:(NSArray<XCTSourceCodeFrame *> *)callStack
                         location:(XCTSourceCodeLocation *)location
{
    self = [super init];
    if (self) {
        _callStack = [callStack copy] ?: @[];
        _location = location;
    }
    return self;
}

- (instancetype)initWithCallStackAddresses:(NSArray<NSNumber *> *)callStackAddresses
                                  location:(XCTSourceCodeLocation *)location
{
    NSMutableArray<XCTSourceCodeFrame *> *frames =
        [NSMutableArray arrayWithCapacity:callStackAddresses.count];
    for (NSNumber *address in callStackAddresses) {
        // Resolved now rather than left for -symbolInfoWithError:, and that is
        // a deliberate trade of work for fidelity. A frame is a return address,
        // and an address only means something while the image it points into is
        // still mapped and named: a test bundle that has been unloaded, or a
        // dylib renamed on disk since, resolves to nothing or to the wrong name
        // once the failure has already happened. Symbolication that runs when
        // the stack is captured names the code as it was at the moment the test
        // failed, which is the whole reason the failure is being recorded.
        //
        // The cost is one dladdr per frame, on a stack that is short, and only
        // on the paths that build a context at all.
        [frames addObject:[[XCTSourceCodeFrame alloc]
            initWithAddress:(uint64_t)address.unsignedLongLongValue
                  symbolInfo:XCTSymbolInfoForAddress((uintptr_t)address.unsignedLongLongValue)]];
    }
    return [self initWithCallStack:frames location:location];
}

- (instancetype)initWithLocation:(XCTSourceCodeLocation *)location
{
    return [self initWithCallStackAddresses:XCTCaptureCallStack() location:location];
}

- (instancetype)init
{
    return [self initWithLocation:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    // Decoded into locals and routed through the designated initializer, so the
    // object is never left half-built and the backtrace is not recaptured.
    NSSet *classes = [NSSet setWithObjects:[NSArray class], [XCTSourceCodeFrame class], nil];
    NSArray<XCTSourceCodeFrame *> *callStack =
        [coder decodeObjectOfClasses:classes forKey:XCTContextCallStackKey];
    XCTSourceCodeLocation *location = [coder decodeObjectOfClass:[XCTSourceCodeLocation class]
                                                          forKey:XCTContextLocationKey];
    return [self initWithCallStack:callStack location:location];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_callStack forKey:XCTContextCallStackKey];
    [coder encodeObject:_location forKey:XCTContextLocationKey];
}

- (NSArray<XCTSourceCodeFrame *> *)callStack { return _callStack; }
- (XCTSourceCodeLocation *)location { return _location; }

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[XCTSourceCodeContext class]]) {
        return NO;
    }
    XCTSourceCodeContext *other = object;
    return (_location == other->_location || [_location isEqual:other->_location]) &&
           [_callStack isEqualToArray:other->_callStack];
}

- (NSUInteger)hash
{
    return _location.hash ^ _callStack.count;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %lu frames", _location, (unsigned long)_callStack.count];
}

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
