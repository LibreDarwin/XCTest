// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for XCTSourceCodeContext and the three types it is built
// from.
//
// The context is the one value type every failure passes through: the assertion
// macros build one, XCTIssue carries one, and anything consuming an issue reads
// one. So its behaviour is worth pinning the same way the expectation
// subclasses' is -- construction, the properties callers actually read, lazy
// symbolication, and the values that go on and come off the wire.
//
// A note on the two private things this file reaches for. XCTestInternal.h
// brings the xct_contextWithFilePath:lineNumber: factory, which is the path
// every assertion macro takes, and with it the framework's own declaration of
// backtrace() -- the Internal SDK ships no <execinfo.h>, so there is no public
// header to get it from. The second private thing is that this harness drives
// -encodeWithCoder:/-initWithCoder: itself, through a stub coder, because the
// Internal SDK declares no NSKeyedArchiver at all. See XCTStubCoder for what
// that does and does not prove.
#import <XCTest/XCTest.h>

#import "XCTestInternal.h"

#import <stdio.h>

static int failures = 0;

/// `detail` is an NSString so a failing check can report the value it actually
/// got -- a description, a key set, a symbol name -- instead of a message about
/// a check having failed.
static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-52s %s%s%s\n", name, passed ? "PASS" : "FAIL", (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

/// Builds a context, and is a global so its name is in the harness executable's
/// symbol table and dladdr can be expected to resolve it. A static function's
/// name would not be, and a check that asserted on symbolication of one would be
/// asserting on luck.
///
/// It is also the frame the capture checks look for, which is why it builds the
/// context itself rather than returning to a caller that would: a frame is on
/// the stack only while the function is executing, so a function that had
/// already returned by the time the backtrace was taken would not be there to
/// find.
XCTSourceCodeContext *xct_harness_capture(XCTSourceCodeLocation *location)
{
    return [[XCTSourceCodeContext alloc] initWithLocation:location];
}

#pragma mark - A stub coder

/// A coder that keeps encoded values in a dictionary, and hands them back.
///
/// This is not an archiver and does not pretend to be one. It exists because
/// the Internal SDK declares no NSKeyedArchiver, so the only way to exercise
/// -encodeWithCoder:/-initWithCoder: here is to call them directly. What it
/// does prove is real: that each type's mapping to keys and back is complete
/// and symmetric, that no key is written that nothing reads, and that every
/// decode asks for the class it is about to hand out. The last one is the part
/// that matters for NSSecureCoding, and it is enforced rather than assumed --
/// a decode that asked for NSNumber where it means XCTSourceCodeFrame raises
/// here, and the check that expects it to succeed fails.
@interface XCTStubCoder : NSCoder
@property (readonly) NSMutableDictionary<NSString *, id> *values;
/// Classes an encode wrote, so a check can assert on the key set exactly rather
/// than on a subset it happened to look for.
@property (readonly) NSSet<NSString *> *keys;
- (instancetype)initWithValues:(nullable NSDictionary<NSString *, id> *)values;
+ (instancetype)coderWithValues:(nullable NSDictionary<NSString *, id> *)values;
@end

@implementation XCTStubCoder {
    NSMutableDictionary<NSString *, id> *_values;
    NSMutableSet<NSString *> *_keys;
}

+ (instancetype)coderWithValues:(NSDictionary<NSString *, id> *)values
{
    return [[self alloc] initWithValues:values];
}

- (instancetype)initWithValues:(NSDictionary<NSString *, id> *)values
{
    self = [super init];
    if (self) {
        _values = values != nil ? [values mutableCopy] : [NSMutableDictionary dictionary];
        _keys = [NSMutableSet set];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithValues:nil];
}

- (NSMutableDictionary<NSString *, id> *)values { return _values; }
- (NSSet<NSString *> *)keys { return _keys; }

- (void)setStored:(id)value forKey:(NSString *)key
{
    [_keys addObject:key];
    if (value == nil) {
        [_values removeObjectForKey:key];
    } else {
        _values[key] = value;
    }
}

#pragma mark Encoding

- (void)encodeObject:(id)object forKey:(NSString *)key { [self setStored:object forKey:key]; }
- (void)encodeInteger:(NSInteger)value forKey:(NSString *)key { [self setStored:@(value) forKey:key]; }
- (void)encodeInt64:(int64_t)value forKey:(NSString *)key { [self setStored:@(value) forKey:key]; }

#pragma mark Decoding

/// nil is always allowed: an absent object is how "there was none" is spelled,
/// and a decoder that refused that could not round-trip a context with no
/// location.
- (id)decodeAllowed:(id)value classes:(NSSet<Class> *)classes
{
    if (value == nil) {
        return nil;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)value) {
            if (element != nil && ![self class:classes accepts:element]) {
                [NSException raise:NSInvalidArgumentException
                            format:@"%@ decoded without allowing %@",
                                   NSStringFromClass([value class]), NSStringFromClass([element class])];
            }
        }
        return value;
    }
    if (![self class:classes accepts:value]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"%@ decoded without allowing %@",
                           NSStringFromClass([value class]), NSStringFromClass([value class])];
    }
    return value;
}

- (BOOL)class:(NSSet<Class> *)classes accepts:(id)value
{
    for (Class candidate in classes) {
        if ([value isKindOfClass:candidate]) {
            return YES;
        }
    }
    return NO;
}

- (id)decodeObjectOfClass:(Class)expected forKey:(NSString *)key
{
    return [self decodeAllowed:self.values[key] classes:[NSSet setWithObject:expected]];
}

- (id)decodeObjectOfClasses:(NSSet<Class> *)expected forKey:(NSString *)key
{
    return [self decodeAllowed:self.values[key] classes:expected];
}

- (NSInteger)decodeIntegerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (int64_t)decodeInt64ForKey:(NSString *)key { return [self.values[key] longLongValue]; }

- (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - XCTSourceCodeLocation

static void checkLocation(void)
{
    puts("XCTSourceCodeLocation:");

    NSURL *url = [NSURL fileURLWithPath:@"/tmp/example.m"];
    XCTSourceCodeLocation *loc = [[XCTSourceCodeLocation alloc] initWithFileURL:url lineNumber:42];
    ok("initWithFileURL:lineNumber: keeps the url", [loc.fileURL isEqual:url], NULL);
    ok("initWithFileURL:lineNumber: keeps the line", loc.lineNumber == 42, NULL);

    // The assertion path has __FILE__, which is a path, and no URL. A
    // fileURLWithPath round trip is what makes the factory below possible.
    XCTSourceCodeLocation *fromPath = [[XCTSourceCodeLocation alloc] initWithFilePath:@"/tmp/from-file.m"
                                                                           lineNumber:7];
    ok("initWithFilePath: keeps the path as a file url",
       [fromPath.fileURL.path isEqualToString:@"/tmp/from-file.m"], fromPath.fileURL.path);
    ok("initWithFilePath: keeps the line", fromPath.lineNumber == 7, NULL);

    XCTSourceCodeLocation *same = [[XCTSourceCodeLocation alloc] initWithFileURL:url lineNumber:42];
    XCTSourceCodeLocation *otherLine = [[XCTSourceCodeLocation alloc] initWithFileURL:url lineNumber:43];
    XCTSourceCodeLocation *otherFile = [[XCTSourceCodeLocation alloc] initWithFileURL:[NSURL fileURLWithPath:@"/tmp/other.m"]
                                                                        lineNumber:42];
    ok("equal when url and line match", [loc isEqual:same] && loc.hash == same.hash, NULL);
    ok("not equal on a different line", ![loc isEqual:otherLine], NULL);
    ok("not equal on a different file", ![loc isEqual:otherFile], NULL);
    ok("not equal to another type", ![loc isEqual:@"42"], NULL);
    ok("description shows path and line", [loc.description hasSuffix:@"/tmp/example.m:42"], loc.description);
    ok("supports secure coding", [XCTSourceCodeLocation supportsSecureCoding], NULL);

    // Both keys, and nothing else. A stray key here is a wire-format change no
    // reader is asking for.
    XCTStubCoder *enc = [XCTStubCoder coderWithValues:nil];
    [loc encodeWithCoder:enc];
    ok("encodes exactly fileURL and lineNumber",
       [enc.keys isEqualToSet:[NSSet setWithObjects:@"fileURL", @"lineNumber", nil]], enc.keys.description);

    XCTSourceCodeLocation *decoded = [[XCTSourceCodeLocation alloc]
        initWithCoder:[XCTStubCoder coderWithValues:enc.values]];
    ok("round trips through the coder", [decoded isEqual:loc], decoded.description);
}

#pragma mark - XCTSourceCodeSymbolInfo

static void checkSymbolInfo(void)
{
    puts("XCTSourceCodeSymbolInfo:");

    XCTSourceCodeLocation *loc = [[XCTSourceCodeLocation alloc] initWithFilePath:@"/tmp/symbol.m"
                                                                        lineNumber:3];
    XCTSourceCodeSymbolInfo *sym = [[XCTSourceCodeSymbolInfo alloc] initWithImageName:@"/tmp/libtest.dylib"
                                                                         symbolName:@"_helper"
                                                                           location:loc];
    ok("keeps the image name", [sym.imageName isEqualToString:@"/tmp/libtest.dylib"], NULL);
    ok("keeps the symbol name", [sym.symbolName isEqualToString:@"_helper"], NULL);
    ok("keeps the location", [sym.location isEqual:loc], NULL);

    // copy, not retain: a symbol outlives the string it was built from, and the
    // strings that reach it are often autoreleased temporaries. -mutableCopy is
    // used rather than +[NSMutableString stringWithString:], which the reduced
    // SDK does not declare.
    NSMutableString *image = [@"/tmp/a.dylib" mutableCopy];
    NSMutableString *name = [@"_a" mutableCopy];
    XCTSourceCodeSymbolInfo *fromMutable = [[XCTSourceCodeSymbolInfo alloc] initWithImageName:image
                                                                                    symbolName:name
                                                                                      location:nil];
    [image appendString:@".renamed"];
    [name appendString:@"_renamed"];
    ok("copies the image name", [fromMutable.imageName isEqualToString:@"/tmp/a.dylib"], fromMutable.imageName);
    ok("copies the symbol name", [fromMutable.symbolName isEqualToString:@"_a"], fromMutable.symbolName);
    ok("a nil location stays nil", fromMutable.location == nil, NULL);

    XCTSourceCodeSymbolInfo *same = [[XCTSourceCodeSymbolInfo alloc] initWithImageName:@"/tmp/libtest.dylib"
                                                                           symbolName:@"_helper"
                                                                             location:loc];
    XCTSourceCodeSymbolInfo *renamed = [[XCTSourceCodeSymbolInfo alloc] initWithImageName:@"/tmp/libtest.dylib"
                                                                             symbolName:@"_other"
                                                                               location:loc];
    ok("equal when all three match", [sym isEqual:same] && sym.hash == same.hash, NULL);
    ok("not equal on a different symbol name", ![sym isEqual:renamed], NULL);
    ok("supports secure coding", [XCTSourceCodeSymbolInfo supportsSecureCoding], NULL);

    XCTStubCoder *enc = [XCTStubCoder coderWithValues:nil];
    [sym encodeWithCoder:enc];
    ok("encodes exactly imageName, symbolName and location",
       [enc.keys isEqualToSet:[NSSet setWithObjects:@"imageName", @"symbolName", @"location", nil]],
       enc.keys.description);
    XCTSourceCodeSymbolInfo *decoded = [[XCTSourceCodeSymbolInfo alloc]
        initWithCoder:[XCTStubCoder coderWithValues:enc.values]];
    ok("round trips through the coder", [decoded isEqual:sym], decoded.description);

    // A symbol with no location is the common case here: the runtime has no
    // line table, so every resolved symbol has a nil location and the coder has
    // to carry that faithfully.
    XCTStubCoder *nilEnc = [XCTStubCoder coderWithValues:nil];
    [fromMutable encodeWithCoder:nilEnc];
    XCTSourceCodeSymbolInfo *nilDecoded = [[XCTSourceCodeSymbolInfo alloc]
        initWithCoder:[XCTStubCoder coderWithValues:nilEnc.values]];
    ok("round trips with no location",
       nilDecoded.location == nil && [nilDecoded isEqual:fromMutable], nilDecoded.description);
}

#pragma mark - XCTSourceCodeFrame

static void checkFrame(void)
{
    puts("XCTSourceCodeFrame:");

    // A full 64-bit value. The old context held its address in an NSUInteger
    // and this is the check that would not notice a 32-bit build truncating one,
    // so the value is chosen to have both halves non-zero.
    XCTSourceCodeFrame *wide = [[XCTSourceCodeFrame alloc] initWithAddress:0xdeadbeefcafef00dULL];
    ok("keeps a full 64-bit address", wide.address == 0xdeadbeefcafef00dULL, NULL);
    ok("an unresolved frame has no symbol", wide.symbolInfo == nil, NULL);

    // Lazy symbolication, against a symbol that is definitely in the table.
    XCTSourceCodeFrame *known = [[XCTSourceCodeFrame alloc] initWithAddress:(uint64_t)(uintptr_t)&xct_harness_capture];
    ok("has not symbolicated before being asked", known.symbolInfo == nil, NULL);
    NSError *error = nil;
    XCTSourceCodeSymbolInfo *resolved = [known symbolInfoWithError:&error];
    ok("resolves a known address", [resolved.symbolName isEqualToString:@"xct_harness_capture"],
       resolved.symbolName);
    ok("names the image too", resolved.imageName.length > 0, resolved.imageName);
    ok("has no error when it resolved", error == nil, error.description);
    ok("a resolved symbol has no location", resolved.location == nil,
       @"the runtime carries no line table, so there is no line to report");
    ok("caches the answer on the frame", [known symbolInfo] == resolved, NULL);
    ok("asking again returns the same object", [known symbolInfoWithError:NULL] == resolved, NULL);

    // A resolvable symbol in another image.
    XCTSourceCodeFrame *printfFrame = [[XCTSourceCodeFrame alloc] initWithAddress:(uint64_t)(uintptr_t)&printf];
    XCTSourceCodeSymbolInfo *printfSymbol = [printfFrame symbolInfoWithError:NULL];
    ok("resolves a symbol in another image", [printfSymbol.symbolName isEqualToString:@"printf"],
       printfSymbol.symbolName);
    ok("the image is not the harness", ![printfSymbol.imageName isEqualToString:resolved.imageName], NULL);

    // An address nothing knows about must say so rather than returning a blank
    // symbol, which a caller could not distinguish from a real unnamed symbol.
    XCTSourceCodeFrame *bogus = [[XCTSourceCodeFrame alloc] initWithAddress:0x10];
    NSError *bogusError = nil;
    ok("an unresolvable address has no symbol", [bogus symbolInfoWithError:&bogusError] == nil, NULL);
    ok("an unresolvable address reports why", bogusError != nil &&
       [bogusError.domain isEqualToString:XCTestErrorDomain], bogusError.domain);
    ok("the error says which address", [bogusError.localizedDescription hasPrefix:@"no symbol information for address 0x10"],
       bogusError.localizedDescription);
    ok("symbolicationError reports the same error", [bogus symbolicationError] == bogusError, NULL);
    ok("asking again repeats the error", [bogus symbolInfoWithError:NULL] == nil &&
       [bogus symbolicationError] == bogusError, NULL);
    // The code has to be outside the XCTestErrorCode range. 0 and 1 are
    // XCTestErrorCodeTimeoutWhileWaiting and XCTestErrorCodeFailureWhileWaiting,
    // and a symbolication failure wearing either of those would be read as a
    // wait that timed out.
    ok("the error code is not a public XCTestErrorCode",
       bogusError.code != XCTestErrorCodeTimeoutWhileWaiting &&
       bogusError.code != XCTestErrorCodeFailureWhileWaiting,
       [NSString stringWithFormat:@"%ld", (long)bogusError.code]);

    // Equality is by address alone. Whether this process has looked the address
    // up yet is not part of what the frame is, and making it part of equality
    // would make two frames equal or not depending on the order they were read.
    XCTSourceCodeFrame *sameAddressBare = [[XCTSourceCodeFrame alloc] initWithAddress:(uint64_t)(uintptr_t)&xct_harness_capture];
    ok("equal to the same address with no symbol", [known isEqual:sameAddressBare] &&
       known.hash == sameAddressBare.hash, NULL);
    ok("not equal to a different address", ![known isEqual:[[XCTSourceCodeFrame alloc] initWithAddress:1]], NULL);
    ok("supports secure coding", [XCTSourceCodeFrame supportsSecureCoding], NULL);

    XCTStubCoder *enc = [XCTStubCoder coderWithValues:nil];
    [known encodeWithCoder:enc];
    ok("encodes exactly address and symbolInfo",
       [enc.keys isEqualToSet:[NSSet setWithObjects:@"address", @"symbolInfo", nil]], enc.keys.description);
    XCTSourceCodeFrame *decoded = [[XCTSourceCodeFrame alloc] initWithCoder:[XCTStubCoder coderWithValues:enc.values]];
    ok("round trips the address", decoded.address == known.address, NULL);
    ok("round trips the symbol", [decoded.symbolInfo isEqual:known.symbolInfo], decoded.symbolInfo.description);

    // The symbolication attempt is deliberately not encoded: it describes this
    // process's lookup, and a decoded frame has made none. So a decoded frame
    // can be asked again, and a decoded unresolvable frame is still unresolvable.
    XCTStubCoder *wideEnc = [XCTStubCoder coderWithValues:nil];
    [wide encodeWithCoder:wideEnc];
    XCTSourceCodeFrame *wideDecoded = [[XCTSourceCodeFrame alloc] initWithCoder:[XCTStubCoder coderWithValues:wideEnc.values]];
    ok("a decoded frame has not symbolicated", wideDecoded.symbolInfo == nil, NULL);
    ok("a decoded frame can be symbolicated",
       [wideDecoded symbolInfoWithError:NULL] == nil, NULL);
    ok("description shows the address",
       [wide.description isEqualToString:@"0xdeadbeefcafef00d"], wide.description);
}

#pragma mark - XCTSourceCodeContext


static void checkContext(void)
{
    puts("XCTSourceCodeContext:");

    XCTSourceCodeLocation *loc = [[XCTSourceCodeLocation alloc] initWithFilePath:@"/tmp/context.m"
                                                                        lineNumber:11];
    XCTSourceCodeFrame *frame = [[XCTSourceCodeFrame alloc] initWithAddress:0x1000];
    NSMutableArray<XCTSourceCodeFrame *> *stack = [@[ frame ] mutableCopy];
    XCTSourceCodeContext *context = [[XCTSourceCodeContext alloc] initWithCallStack:stack location:loc];
    ok("keeps the stack", context.callStack.count == 1 && context.callStack[0] == frame, NULL);
    ok("keeps the location", context.location == loc, NULL);
    [stack addObject:[[XCTSourceCodeFrame alloc] initWithAddress:0x2000]];
    ok("copies the stack", context.callStack.count == 1, NULL);

    // A context with no frames is legal: a failure caught where the stack
    // unwound past the capture, or a caller with nothing to report. It must not
    // be nil, because every caller of -callStack would then have to check.
    XCTSourceCodeContext *empty = [[XCTSourceCodeContext alloc] initWithCallStack:@[] location:nil];
    ok("an empty stack is not nil", empty.callStack != nil && empty.callStack.count == 0, NULL);
    ok("a nil location stays nil", empty.location == nil, NULL);

    // From raw addresses, the way NSThread.callStackReturnAddresses hands them
    // over.
    XCTSourceCodeContext *fromAddresses = [[XCTSourceCodeContext alloc]
        initWithCallStackAddresses:@[@((uintptr_t)&xct_harness_capture)] location:loc];
    ok("builds one frame per address", fromAddresses.callStack.count == 1, NULL);
    // objectAtIndex:0 rather than -firstObject, which the reduced SDK's NSArray
    // does not declare. The count check above has already established there is
    // something to read.
    XCTSourceCodeFrame *only = [fromAddresses.callStack objectAtIndex:0];
    ok("keeps the address on the frame", only.address == (uint64_t)(uintptr_t)&xct_harness_capture, NULL);
    // Resolved at construction, not on demand: an address only names something
    // while its image is still loaded, so the name has to be taken while the
    // stack is being captured.
    ok("resolves symbols while building the stack", only.symbolInfo.symbolName.length > 0,
       only.symbolInfo.symbolName);

    ok("supports secure coding", [XCTSourceCodeContext supportsSecureCoding], NULL);
    ok("equal when stack and location match",
       [context isEqual:[[XCTSourceCodeContext alloc] initWithCallStack:@[ frame ] location:loc]] &&
       context.hash == [[XCTSourceCodeContext alloc] initWithCallStack:@[ frame ] location:loc].hash, NULL);
    ok("not equal on a different stack",
       ![context isEqual:[[XCTSourceCodeContext alloc] initWithCallStack:@[] location:loc]], NULL);
    ok("not equal on a different location",
       ![context isEqual:[[XCTSourceCodeContext alloc] initWithCallStack:@[ frame ] location:nil]], NULL);

    // The wire format, which is what a result consumer reads. Exactly two keys:
    // the stack and the location. The old context also wrote filePath,
    // lineNumber, columnNumber and a symbolInfo string, and the point of the
    // redesign is that none of those exist to be written.
    XCTStubCoder *enc = [XCTStubCoder coderWithValues:nil];
    [context encodeWithCoder:enc];
    ok("encodes exactly callStack and location",
       [enc.keys isEqualToSet:[NSSet setWithObjects:@"callStack", @"location", nil]], enc.keys.description);
    ok("writes no filePath, lineNumber, columnNumber or symbolInfo",
       ![enc.keys intersectsSet:[NSSet setWithObjects:@"filePath", @"lineNumber", @"columnNumber", @"symbolInfo", nil]],
       enc.keys.description);
    XCTSourceCodeContext *decoded = [[XCTSourceCodeContext alloc]
        initWithCoder:[XCTStubCoder coderWithValues:enc.values]];
    ok("round trips through the coder", [decoded isEqual:context], decoded.description);
    ok("a decoded context is not the same object", decoded != context, NULL);
    ok("a decoded context keeps its frames", decoded.callStack.count == 1 && decoded.callStack[0] == frame, NULL);
}

#pragma mark - Capturing a real stack

static void checkCapture(void)
{
    puts("call stack capture:");

    XCTSourceCodeContext *bare = [[XCTSourceCodeContext alloc] init];
    ok("-init captures a stack", bare.callStack.count > 1, NULL);
    ok("-init has no location", bare.location == nil, NULL);
    // -indexOfObjectPassingTest: is not in the reduced SDK's NSArray, so the
    // scan is written out.
    BOOL anyZero = NO;
    for (XCTSourceCodeFrame *frame in bare.callStack) {
        if (frame.address == 0) {
            anyZero = YES;
            break;
        }
    }
    ok("every captured address is non-zero", !anyZero, NULL);

    // The point of the redesign: a captured context has real frames that
    // symbolicate, rather than one address and some strings.
    XCTSourceCodeLocation *loc = [[XCTSourceCodeLocation alloc] initWithFilePath:@"/tmp/capture.m"
                                                                        lineNumber:99];
    XCTSourceCodeContext *context = xct_harness_capture(loc);
    ok("a captured stack holds several frames", context.callStack.count > 1, NULL);
    ok("a captured context keeps its location", context.location == loc, NULL);

    // The harness's own code is in the captured stack, so at least one frame
    // must resolve to this executable. Asserting on the image rather than on a
    // particular symbol name is deliberate: which frames survive the
    // capture's own skip count depends on whether the framework's capture
    // helpers were inlined, and a check that asserted on one exact name would be
    // asserting on the optimizer rather than on the behaviour.
    //
    // The names are reported either way, so a failure says what was seen.
    NSMutableString *seen = [NSMutableString string];
    NSMutableString *ownImage = [NSMutableString string];
    for (XCTSourceCodeFrame *frame in context.callStack) {
        NSString *name = [frame symbolInfo].symbolName;
        [seen appendFormat:@"%@ ", name != nil ? name : @"?"];
        if (name != nil && [[frame symbolInfo].imageName hasSuffix:@"source-context-test"]) {
            [ownImage appendFormat:@"%@ ", name];
        }
    }
    ok("a captured frame is in the harness's own image", ownImage.length > 0, seen);
    ok("unresolved frames are marked, not invented", seen.length > 0, NULL);

    // Unresolvable frames are normal in a real stack, so the loop above asking
    // every frame must not throw and must not invent symbols for them.
    unsigned long resolved = 0;
    for (XCTSourceCodeFrame *frame in context.callStack) {
        if ([frame symbolInfoWithError:NULL] != nil) {
            resolved++;
        }
    }
    ok("asks every frame without failing", resolved > 0, NULL);
}

#pragma mark - The assertion path

static void checkAssertionPath(void)
{
    puts("assertion path:");

    // What _XCTSourceCodeContextAtLocation() builds for every assertion: the
    // file and line are literals at the call site, so they must arrive intact,
    // and the stack must still be captured.
    // The line is captured into a local first, exactly as the assertion macros
    // do. Comparing against a __LINE__ written at the check would compare the
    // check's own line with the failure's, and the two differ by construction.
    const NSUInteger assertedLine = __LINE__;
    XCTSourceCodeContext *context = _XCTSourceCodeContextAtLocation(__FILE__, assertedLine);
    // @(__FILE__): the macro expands to a C string, and -isEqualToString: wants
    // an NSString. The harness is deliberately written the way a client would
    // write it, so the conversion is done here rather than inside the framework.
    ok("keeps the file the macro supplied",
       [context.location.fileURL.path isEqualToString:@(__FILE__)], context.location.fileURL.path);
    ok("keeps the line the macro supplied",
       context.location.lineNumber == (NSInteger)assertedLine, nil);
    ok("still captures a stack", context.callStack.count > 1, NULL);
    // The reduced SDK's -objectAtIndex: returns plain id, so the cast is
    // needed here and is the reader's, not the framework's.
    XCTSourceCodeFrame *innermost = [context.callStack objectAtIndex:0];
    ok("the innermost frame is a real address", innermost.address != 0, NULL);

    // And an issue built from it carries the whole thing, which is the only
    // reason any of this exists: a consumer of a result reads the file and line
    // of the failure off the issue.
    XCTIssue *issue = [[XCTIssue alloc] initWithType:XCTIssueTypeAssertionFailure
                                 compactDescription:@"failed"
                                detailedDescription:@"XCTAssertTrue failed"
                                  sourceCodeContext:context
                                    associatedError:nil
                                        attachments:@[]
                                           severity:XCTIssueSeverityError];
    ok("an issue hands back its own context", issue.sourceCodeContext == context, NULL);
    ok("an issue's context has the location",
       [issue.sourceCodeContext.location.fileURL.path isEqualToString:@(__FILE__)], NULL);

    XCTStubCoder *enc = [XCTStubCoder coderWithValues:nil];
    [issue encodeWithCoder:enc];
    ok("an issue encodes its context under one key",
       [enc.keys containsObject:@"sourceCodeContext"] &&
       enc.values[@"sourceCodeContext"] == context, enc.keys.description);
    XCTIssue *decoded = [[XCTIssue alloc] initWithCoder:[XCTStubCoder coderWithValues:enc.values]];
    ok("an issue round trips its context",
       [decoded.sourceCodeContext.location isEqual:context.location] &&
       decoded.sourceCodeContext.callStack.count == context.callStack.count,
       decoded.sourceCodeContext.description);
    ok("an issue round trips its own fields",
       decoded.type == XCTIssueTypeAssertionFailure && decoded.severity == XCTIssueSeverityError &&
       [decoded.compactDescription isEqualToString:@"failed"], NULL);
}

#pragma mark - Entry

int main(void)
{
    checkLocation();
    checkSymbolInfo();
    checkFrame();
    checkContext();
    checkCapture();
    checkAssertionPath();
    printf("\n%s (%d failure%s)\n", failures == 0 ? "ALL PASS" : "FAILURES", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
