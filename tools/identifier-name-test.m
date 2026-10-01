// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for the identifier/name family: how a test spells its own
// name, and the identifier the selection machinery addresses it by.
//
// Three derivations share one source, and no single check sees all of them, so
// the harness pins each separately:
//
//   - The *suffix-stripped* method name. The harness appends `AndReturnError:`
//     and `WithCompletionHandler:` to the same base method and requires both
//     spellings to name the same test as the bare method. A report that printed
//     `testExampleAndReturnError:` would print a signature the source never
//     wrote.
//   - The *language-specific* method name. This is the same stripped name; the
//     two differ only for a Swift test, whose spelled-out name carries its
//     argument list (`testFoo()`). That branch is unobservable from an
//     Objective-C fixture -- `_class_isSwift` is a libobjc property of the
//     real class -- so the harness pins the branch it can reach and requires
//     the two spellings to agree for Objective-C, which is what a wrong
//     append would break.
//   - The *rename* hook. XCTestCastMethodNamesUIAutomationDelegate reports a
//     name other than its selector implies, so a case must consult the hook
//     before reading the selector. The obverse is that a case that does *not*
//     opt in must not be renamed by the hook's mere presence.
//
// The identifier is the tuple of the class name and the resulting method name,
// so the checks that matter are that it carries the *dynamic* answer (a rename,
// or a stripped suffix) and not a name re-derived from the selector at call
// time. The cache is checked by pointer identity, because a rebuilt-but-equal
// value would satisfy an equality check while defeating the cache.
//
// It links the installed framework rather than the object files, so it also
// covers installation and the private declarations in XCTestInternal.h, which
// is where these methods would drift if they drifted anywhere.
#import <XCTest/XCTest.h>
#import <XCTestCore/XCTTestSelection.h>

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"

#import <Foundation/Foundation.h>

#import <stdio.h>

static int failures = 0;

static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-58s %s%s%s\n", name, passed ? "PASS" : "FAIL",
           (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Fixtures

// One base method spelled three ways. The trailing-suffix forms need real
// methods so -instanceMethodSignatureForSelector: can build an invocation.
@interface XCTNameFixture : XCTestCase
- (void)testExample;
- (void)testExampleAndReturnError:(NSError **)error;
- (void)testExampleWithCompletionHandler:(void (^)(NSError *error))handler;
@end
@implementation XCTNameFixture
- (void)testExample {}
- (void)testExampleAndReturnError:(NSError **)error {}
- (void)testExampleWithCompletionHandler:(void (^)(NSError *error))handler {}
@end

// Opts into the rename hook: reports a name no selector implies.
@interface XCTVoiceFixture : XCTestCase
@end
@implementation XCTVoiceFixture
- (void)testOriginal {}
- (BOOL)overridesTestMethodName { return YES; }
- (NSString *)overriddenTestMethodName { return @"renamedTest"; }
@end

// Overrides -name directly, which is the other half of what
// +customizesTestMethodNameViaOverrides looks for.
@interface XCTCustomNameFixture : XCTestCase
@end
@implementation XCTCustomNameFixture
- (void)testOriginal {}
- (NSString *)name { return @"a custom display name"; }
@end

static XCTestCase *caseWithSelector(Class cls, SEL selector)
{
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    return [[cls alloc] initWithInvocation:invocation];
}

int main(void)
{
    printf("XCTestCase identifier and name family\n");

    XCTestCase *plain = caseWithSelector([XCTNameFixture class], @selector(testExample));
    XCTestCase *errorForm = caseWithSelector([XCTNameFixture class], @selector(testExampleAndReturnError:));
    XCTestCase *handlerForm = caseWithSelector([XCTNameFixture class], @selector(testExampleWithCompletionHandler:));

    // -name: the public spelling, with the suffix and the module gone.
    ok("name of a plain method is -[Class method]",
       [plain.name isEqualToString:@"-[XCTNameFixture testExample]"], plain.name);
    ok("name strips AndReturnError:",
       [errorForm.name isEqualToString:@"-[XCTNameFixture testExample]"], errorForm.name);
    ok("name strips WithCompletionHandler:",
       [handlerForm.name isEqualToString:@"-[XCTNameFixture testExample]"], handlerForm.name);

    // -languageAgnosticTestMethodName: the same stripped name, on its own.
    ok("language-agnostic method of a plain method",
       [plain.languageAgnosticTestMethodName isEqualToString:@"testExample"],
       plain.languageAgnosticTestMethodName);
    ok("language-agnostic method strips AndReturnError:",
       [errorForm.languageAgnosticTestMethodName isEqualToString:@"testExample"],
       errorForm.languageAgnosticTestMethodName);
    ok("language-agnostic method strips WithCompletionHandler:",
       [handlerForm.languageAgnosticTestMethodName isEqualToString:@"testExample"],
       handlerForm.languageAgnosticTestMethodName);

    // -languageSpecificTestMethodName: the same stripped name for Objective-C.
    // The Swift-only `()` append is not reachable from here; what is reachable
    // is that the two derivations agree, which a stray append would break.
    ok("language-specific method of a plain method",
       [plain.languageSpecificTestMethodName isEqualToString:@"testExample"],
       plain.languageSpecificTestMethodName);
    ok("language-specific method strips AndReturnError:",
       [errorForm.languageSpecificTestMethodName isEqualToString:@"testExample"],
       errorForm.languageSpecificTestMethodName);
    ok("language-specific method strips WithCompletionHandler:",
       [handlerForm.languageSpecificTestMethodName isEqualToString:@"testExample"],
       handlerForm.languageSpecificTestMethodName);
    ok("language-specific and language-agnostic agree for Objective-C",
       [errorForm.languageSpecificTestMethodName isEqualToString:errorForm.languageAgnosticTestMethodName],
       errorForm.languageSpecificTestMethodName);

    // The class-method form the instance method delegates to.
    ok("+_languageSpecificTestMethodNameForSelector: strips the suffix",
       [[XCTNameFixture _languageSpecificTestMethodNameForSelector:@selector(testExampleAndReturnError:)]
           isEqualToString:@"testExample"], nil);

    // Class names: the agnostic one has no module to strip here.
    ok("language-specific class name is the runtime name",
       [plain.languageSpecificTestClassName isEqualToString:NSStringFromClass([XCTNameFixture class])],
       plain.languageSpecificTestClassName);
    ok("language-agnostic class name has no module to strip",
       [plain.languageAgnosticTestClassName isEqualToString:NSStringFromClass([XCTNameFixture class])],
       plain.languageAgnosticTestClassName);

    // -nameForLegacyLogging: same shape, but the class name is un-stripped.
    ok("legacy logging name is -[Class method]",
       [plain.nameForLegacyLogging isEqualToString:@"-[XCTNameFixture testExample]"],
       plain.nameForLegacyLogging);

    // The identifier: class name plus the dynamic method name.
    XCTTestIdentifier *identifier = plain._xctTestIdentifier;
    ok("identifier components are class and method",
       [identifier.components isEqualToArray:(@[ @"XCTNameFixture", @"testExample" ])], identifier.identifierString);
    ok("identifier string joins with a slash",
       [identifier.identifierString isEqualToString:@"XCTNameFixture/testExample"], identifier.identifierString);
    ok("identifier last component is the method",
       [identifier.lastComponent isEqualToString:@"testExample"], identifier.lastComponent);

    // The identifier uses the stripped name, not the selector's own.
    ok("identifier uses the stripped method name",
       [errorForm._xctTestIdentifier.identifierString isEqualToString:@"XCTNameFixture/testExample"],
       errorForm._xctTestIdentifier.identifierString);

    // The cache: same object, or it is not a cache.
    ok("the identifier is cached",
       plain._xctTestIdentifier == identifier, nil);
    ok("an uncached identifier is freshly built",
       [plain _uncachedIdentifierWithClassName:@"XCTNameFixture"] != identifier, nil);

    // A case with no invocation still gets a usable name and identifier.
    XCTestCase *empty = [[XCTNameFixture alloc] initWithInvocation:nil];
    ok("a case with no invocation still names its class",
       [empty.name containsString:@"XCTNameFixture"], empty.name);
    ok("a case with no invocation falls back for reporting",
       [empty._xctTestIdentifier.lastComponent hasPrefix:@"unspecifiedMethod_"],
       empty._xctTestIdentifier.lastComponent);

    // The rename hook.
    XCTestCase *voice = caseWithSelector([XCTVoiceFixture class], @selector(testOriginal));
    ok("the rename hook wins over the selector",
       [voice.languageAgnosticTestMethodName isEqualToString:@"renamedTest"],
       voice.languageAgnosticTestMethodName);
    ok("the overridden name is exposed",
       [voice.overridden_languageAgnosticTestMethodName isEqualToString:@"renamedTest"],
       voice.overridden_languageAgnosticTestMethodName);
    ok("the identifier carries the renamed method",
       [voice._xctTestIdentifier.identifierString isEqualToString:@"XCTVoiceFixture/renamedTest"],
       voice._xctTestIdentifier.identifierString);
    ok("a plain case has no override",
       plain.overridden_languageAgnosticTestMethodName == nil, nil);

    // Class predicates.
    ok("an Objective-C class is not Swift", ![XCTNameFixture mayBeSwift], nil);
    ok("a plain case does not customize its name",
       ![XCTNameFixture customizesTestMethodNameViaOverrides], nil);
    ok("a -name override is detected",
       [XCTCustomNameFixture customizesTestMethodNameViaOverrides], nil);

    // The suite half of the base answers.
    XCTestSuite *suite = [XCTestSuite testSuiteWithName:@"SomeSuite"];
    ok("a suite has no method name", suite.languageAgnosticTestMethodName == nil, nil);
    ok("a suite reports itself when it has no method",
       [suite._methodNameForReporting isEqualToString:@"unspecifiedMethod_SomeSuite"],
       suite._methodNameForReporting);
    ok("a case reports its method name",
       [plain._methodNameForReporting isEqualToString:@"testExample"], plain._methodNameForReporting);

    // The base spelling, which a non-case object falls back to.
    XCTest *base = [[XCTest alloc] init];
    ok("the base legacy name forwards to -name",
       [base.nameForLegacyLogging isEqualToString:base.name], base.nameForLegacyLogging);

    printf("\n%d check%s failed\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
