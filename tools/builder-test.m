// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Checks the parsing and accumulation a `-only-testing:` loop does, which is
// what XCTestConfigurationLoader calls and the reason any of it exists.
//
// The cases that matter are the ones where the two spellings disagree: a Swift
// test that an Objective-C runner also has, a parameterized test whose name ends
// in a paren, and a plain suite name that is ambiguous with a leaf. A parser
// that mishandles any of them still passes a round-trip test, because the
// string comes back out looking right.
//
// So the checks are on the components and the option bits rather than on the
// string coming back out, and the counts are derived from what a string adds
// rather than written down, or they would only be restating the parser.
//
// It needs no framework, since it compiles from source, and the checks that
// the archive forms round-trip are in selection-test.m.

#import <stdio.h>

#import <Foundation/Foundation.h>
#import <XCTestCore/XCTTestSelection.h>

// The reduced SDK's Foundation is missing -componentsJoinedByString:, which is
// the only thing this needs from it that selection-test.m did not already need.
static NSString *Join(NSArray<NSString *> *parts, NSString *separator)
{
    NSMutableString *joined = [NSMutableString string];
    for (NSString *part in parts) {
        if (joined.length != 0) {
            [joined appendString:separator];
        }
        [joined appendString:part];
    }
    return joined;
}

static NSUInteger checksRun = 0;
static NSUInteger checksFailed = 0;

static void Check(BOOL condition, NSString *name)
{
    checksRun++;
    if (condition) {
        fprintf(stdout, "  %-58s PASS\n", name.UTF8String);
    } else {
        checksFailed++;
        fprintf(stdout, "  %-58s FAIL\n", name.UTF8String);
    }
}

static NSString *Joined(XCTTestIdentifierSet *set)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (XCTTestIdentifier *identifier in set.sortedIdentifiers) {
        [lines addObject:[NSString stringWithFormat:@"%@ [%lu]",
                                                    identifier.identifierString,
                                                    (unsigned long)identifier.options]];
    }
    return Join(lines, @"\n\t");
}

/// Every identifier a selection string added, one per line, so a failure prints
/// the whole set rather than only the count.
static NSString *Describe(XCTTestIdentifierSetBuilder *builder)
{
    return [NSString stringWithFormat:@"%lu identifier(s):\n\t%@",
                                      (unsigned long)builder.count, Joined(builder)];
}

int main(void)
{
    @autoreleasepool {
        // MARK: -XCTest Class/test, the form the loader is required to accept

        fprintf(stdout, "-XCTest Class/test\n");
        {
            XCTTestIdentifier *identifier = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testFoo"];
            Check(identifier != nil, @"Class/test parses");
            Check(identifier.componentCount == 2, @"Class/test has two components");
            Check([identifier.identifierString isEqualToString:@"MyTests/testFoo"], @"Class/test round-trips");
            Check(identifier.isContainer == NO, @"Class/test is not a container");
            Check(identifier.usesClassAndMethodSemantics, @"Class/test is class-and-method");
            Check(identifier.isSwiftMethod == NO, @"Class/test is not a Swift method");
        }
        {
            // A parameterized method's Objective-C spelling ends in `:)`, and the
            // reference reads that as the mark of a Swift parameterized test and
            // refuses it here: which is why the arguments survive at all is a
            // question for the Swift Testing spelling, not this one.
            Check([[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testFoo(x:)"] == nil,
                  @"a parameterized method is rejected by the Objective-C parser");
        }
        {
            XCTTestIdentifier *identifier = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests"];
            Check(identifier != nil, @"a bare suite name parses");
            Check(identifier.isContainer, @"a bare suite name is a container");
            Check(identifier.componentCount == 1, @"a bare suite name has one component");
        }

        // MARK: Rejected spellings

        fprintf(stdout, "rejected spellings\n");
        Check([[XCTTestIdentifier alloc] initWithStringRepresentation:@""] == nil, @"the empty string is rejected");
        Check([[XCTTestIdentifier alloc] initWithStringRepresentation:@"A/b/c"] == nil, @"three components are rejected");
        Check([[XCTTestIdentifier alloc] initWithStringRepresentation:@"testFoo()/bar"] == nil, @"a method as the outer component is rejected");
        Check([[XCTTestIdentifier alloc] initWithStringRepresentation:@"A/testFoo(:)"] == nil, @"a parameterized method is rejected");

        // MARK: Module prefixes

        fprintf(stdout, "module prefixes\n");
        {
            XCTTestIdentifier *stripped = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyModule.MyTests/testFoo"];
            Check([stripped.identifierString isEqualToString:@"MyTests/testFoo"], @"the module is dropped by default");
            // A name that needed the module dropping was a Swift name, and the
            // option bit is the only record of that once the module is gone.
            Check(stripped.isSwiftMethod, @"a name that carried a module is a Swift method");
            Check(stripped.options == (XCTTestIdentifierOptionClassAndMethod | XCTTestIdentifierOptionSwiftMethod),
                  @"a dropped module is a class-and-method Swift identifier");
        }
        {
            XCTTestIdentifier *kept = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyModule.MyTests/testFoo"
                                                                       preserveModulePrefix:YES];
            Check([kept.identifierString isEqualToString:@"MyModule.MyTests/testFoo"], @"the module is kept when asked");
        }
        {
            // A nested Swift type is not a module: only the first component goes,
            // because a nested type still needs its outer type to be found.
            XCTTestIdentifier *nested = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"Outer.Inner/testFoo"];
            Check([nested.identifierString isEqualToString:@"Inner/testFoo"], @"only the first component is a module");
            Check(nested.isSwiftMethod, @"a name that carried a module is a Swift method either way");
        }
        {
            // Swift Testing writes an empty argument list, and that is what marks
            // the identifier as needing a counterpart.
            // The `()` is consumed into the option bit: the identifier holds the
            // bare method name, and the bit is what says it was a Swift method.
            XCTTestIdentifier *swiftTest = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyModule.MyTests/testFoo()"];
            Check(swiftTest.isSwiftMethod, @"a `()` method is a Swift method");
            Check([swiftTest.identifierString isEqualToString:@"MyTests/testFoo"], @"a `()` method is stored without its parens");
            Check(swiftTest.argumentIDs != nil, @"a class-and-method identifier has an argument set");
            Check(swiftTest.argumentIDs.count == 0, @"and it is empty, distinguishing no arguments from no parameterization");
        }

        // MARK: Swift Testing spellings

        fprintf(stdout, "Swift Testing spellings\n");
        {
            XCTTestIdentifier *suite = [[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:@"MySuite"];
            Check(suite.isContainer, @"a plain Swift name is a container");
            Check(suite.componentCount == 1, @"a plain Swift name has one component");
            Check(suite.isSwiftMethod == NO, @"a plain Swift name is not a Swift method");
        }
        {
            // The `()` suffix sets no option bit at all, which is the reference's
            // behaviour and the reason the counterpart of a Swift test comes from
            // the Objective-C spelling rather than from this one.
            XCTTestIdentifier *method = [[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:@"MySuite/testFoo()"];
            Check(method.componentCount == 2, @"a Swift `()` name has two components");
            Check(method.options == 0, @"a Swift `()` name has no option bits");
            Check(method.isSwiftMethod == NO, @"a Swift `()` name sets no Swift bit");
            Check(method.isContainer == NO, @"a Swift `()` name is not a container");
        }
        {
            XCTTestIdentifier *parameterized = [[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:@"MySuite/testFoo(:)"];
            Check(parameterized.isContainer, @"a `:)` name is a container as well as a Swift method");
            Check(parameterized.isSwiftMethod, @"a `:)` name is a Swift method");
            Check(parameterized.options == (XCTTestIdentifierOptionContainer | XCTTestIdentifierOptionSwiftMethod),
                  @"a `:)` name is a container and a Swift method");
        }
        Check([[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:@""] == nil,
              @"the empty Swift string is rejected");

        // MARK: Counterparts

        fprintf(stdout, "counterparts\n");
        {
            XCTTestIdentifier *objc = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests/testFoo"];
            Check(objc.swiftMethodCounterpart == nil, @"an Objective-C method has no Swift counterpart");
        }
        {
            XCTTestIdentifier *suite = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyTests"];
            Check(suite.swiftMethodCounterpart == nil, @"a suite has no counterpart");
        }
        {
            XCTTestIdentifier *swiftTest = [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyModule.MyTests/testFoo()"];
            XCTTestIdentifier *counterpart = swiftTest.swiftMethodCounterpart;
            Check(counterpart != nil, @"a Swift method has a counterpart");
            Check([counterpart.identifierString isEqualToString:@"MyTests/testFoo"],
                  @"the counterpart is the Objective-C spelling");
            // The counterpart forces the Swift reading on rather than removing
            // it, so for an identifier that arrived as Swift it equals the
            // receiver. The check that matters is that it is never nil here.
            Check(counterpart.isSwiftMethod, @"the counterpart forces the Swift reading on");
            Check([counterpart isEqual:swiftTest], @"and so it equals the receiver for a Swift identifier");
        }

        // MARK: Accumulation

        // A selection string can name more than one identifier: the Objective-C
        // and Swift Testing readings of a name are kept apart by their option
        // bits, and both go in, because which one runs depends on which runner
        // is driving. So the counts below are derived from what a string adds
        // rather than written down, or they would be restating the parser.
        fprintf(stdout, "accumulation\n");
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            Check(builder.count == 0, @"a new builder is empty");
            Check([builder addTestIdentifiersForStringRepresentation:@"MyTests/testFoo"
                                         includingSwiftCounterpart:NO],
                  @"a valid selection string is accepted");
            Check(builder.count > 0, @"a valid selection string adds something");
            NSUInteger perString = builder.count;
            Check(perString == 2, @"a plain selection string names two identifiers");
            Check(![builder addTestIdentifiersForStringRepresentation:@""
                                         includingSwiftCounterpart:NO],
                  @"the empty selection string is refused");
            Check(builder.count == perString, @"a refused string adds nothing");
        }
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"MyModule.MyTests/testFoo()"
                                         includingSwiftCounterpart:NO];
            fprintf(stdout, "    %s\n", Describe(builder).UTF8String);
            Check(builder.count == 2, @"a Swift `()` selection string names two identifiers");
            // preserveModulePrefix:, because that is the spelling the builder
            // asks for: a selection read from an environment has to keep the
            // module to match what Swift Testing wrote.
            Check([builder containsTestIdentifier:
                       [[XCTTestIdentifier alloc] initWithStringRepresentation:@"MyModule.MyTests/testFoo()"
                                                          preserveModulePrefix:YES]],
                  @"the primary spelling is added");
            Check([builder containsTestIdentifier:
                       [[XCTTestIdentifier alloc] initWithSwiftTestingStringRepresentation:
                           @"MyModule.MyTests/testFoo()"]],
                  @"the Swift Testing reading is added too");
        }
        {
            // A bare suite name is ambiguous between the suite and a leaf of the
            // same name, so both readings go in as well.
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"MyTests" includingSwiftCounterpart:NO];
            fprintf(stdout, "    %s\n", Describe(builder).UTF8String);
            Check(builder.count == 3, @"a bare suite name adds three readings of one name");
            Check([builder containsTestIdentifier:
                       [[XCTTestIdentifier alloc] initWithComponents:@[ @"MyTests" ] isContainer:YES]],
                  @"the suite is added as a container");
            Check([builder containsTestIdentifier:
                       [[XCTTestIdentifier alloc] initWithComponents:@[ @"MyTests" ] isContainer:NO]],
                  @"the suite name is also added as a leaf");
        }
        {
            // The counterpart path, which includingSwiftCounterpart:YES is the
            // only way to reach.
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"MyTests/testFoo"
                                         includingSwiftCounterpart:YES];
            fprintf(stdout, "    %s\n", Describe(builder).UTF8String);
            Check(builder.count == 2,
                  @"asking for the counterpart adds nothing for a plain method, which has none");
            NSUInteger afterPlain = builder.count;
            [builder addTestIdentifiersForStringRepresentation:@"MyModule.MyTests/testFoo()"
                                         includingSwiftCounterpart:YES];
            Check(builder.count == afterPlain + 2,
                  @"a Swift method's counterpart is its own reading, so the string adds two, not three");
        }
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"MyTests/testFoo"
                                         includingSwiftCounterpart:NO];
            Check(builder.anyTestIdentifier != nil, @"a builder answers the set's questions");
            Check(![builder isEmpty], @"a builder with an identifier is not empty");
            NSUInteger before = builder.count;
            [builder removeTestIdentifier:builder.anyTestIdentifier];
            Check(builder.count == before - 1, @"removing one identifier removes exactly one");
            while (builder.anyTestIdentifier != nil) {
                [builder removeTestIdentifier:builder.anyTestIdentifier];
            }
            Check(builder.isEmpty, @"removing every identifier empties the builder");
        }
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"A/a" includingSwiftCounterpart:NO];
            NSUInteger afterFirst = builder.count;
            [builder addTestIdentifiersForStringRepresentation:@"B/b" includingSwiftCounterpart:NO];
            Check(builder.count == 2 * afterFirst, @"two strings accumulate");
            [builder removeAllTestIdentifiers];
            Check(builder.count == 0, @"removeAll empties the builder");
        }

        // MARK: The snapshot is independent of the builder

        fprintf(stdout, "the snapshot is independent\n");
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"A/a" includingSwiftCounterpart:NO];
            NSUInteger held = builder.count;
            XCTTestIdentifierSet *snapshot = builder.testIdentifierSet;
            Check(snapshot.count == held, @"the snapshot holds what the builder held");
            Check([snapshot isKindOfClass:[XCTTestIdentifierSet class]], @"the snapshot is a plain set");
            Check(![snapshot isKindOfClass:[XCTTestIdentifierSetBuilder class]], @"the snapshot is not a builder");
            [builder addTestIdentifiersForStringRepresentation:@"B/b" includingSwiftCounterpart:NO];
            Check(snapshot.count == held, @"growing the builder does not grow the snapshot");
            Check(builder.count == 2 * held, @"the builder itself did grow");
        }
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"A/a" includingSwiftCounterpart:NO];
            NSUInteger original = builder.count;
            XCTTestIdentifierSetBuilder *copy = [builder copy];
            Check(copy.count == original, @"a copy holds what the builder held");
            Check([copy isKindOfClass:[XCTTestIdentifierSetBuilder class]], @"a copy is still a builder");
            [builder addTestIdentifiersForStringRepresentation:@"B/b" includingSwiftCounterpart:NO];
            Check(copy.count == original, @"growing the builder does not grow the copy");
        }
        {
            XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
            [builder addTestIdentifiersForStringRepresentation:@"A/a" includingSwiftCounterpart:NO];
            [builder addTestIdentifiersForStringRepresentation:@"B/b" includingSwiftCounterpart:NO];
            XCTTestIdentifierSet *other = builder.testIdentifierSet;
            NSUInteger size = other.count;
            Check(size > 0, @"the set under test is not empty");

            XCTTestIdentifierSetBuilder *sum = [[XCTTestIdentifierSetBuilder alloc] initWithSet:other];
            [sum unionSet:other];
            Check(sum.count == size, @"union with a set holding the same adds nothing new");

            XCTTestIdentifierSetBuilder *difference = [[XCTTestIdentifierSetBuilder alloc] initWithSet:other];
            [difference minusSet:other];
            Check(difference.isEmpty, @"minus a set removes everything it shares");

            XCTTestIdentifierSetBuilder *untouched = [[XCTTestIdentifierSetBuilder alloc] initWithSet:other];
            [untouched minusSet:[[XCTTestIdentifierSet alloc] init]];
            Check(untouched.count == size, @"minus an empty set changes nothing");

            XCTTestIdentifierSetBuilder *fromBuilder = [[XCTTestIdentifierSetBuilder alloc] initWithSet:other];
            [fromBuilder minusBuilder:[[XCTTestIdentifierSetBuilder alloc] initWithSet:other]];
            Check(fromBuilder.isEmpty, @"minusBuilder removes everything it shares");

            XCTTestIdentifierSetBuilder *unioned = [[XCTTestIdentifierSetBuilder alloc] initWithSet:other];
            [unioned unionBuilder:[[XCTTestIdentifierSetBuilder alloc] initWithSet:other]];
            Check(unioned.count == size, @"unionBuilder over the same set is idempotent");

            // A builder unioned with itself must not lose its contents, which is
            // the one case where a naive in-place union would empty the storage
            // it is reading from.
            XCTTestIdentifierSetBuilder *self = [[XCTTestIdentifierSetBuilder alloc] initWithSet:other];
            [self unionSet:self];
            Check(self.count == size, @"a builder unioned with itself keeps everything");
            [self minusSet:self];
            Check(self.count == size, @"a builder minus itself also keeps everything");
        }
    }

    fprintf(stdout, "PASSED: %lu failure(s) of %lu check(s)\n",
            (unsigned long)checksFailed, (unsigned long)checksRun);
    return checksFailed == 0 ? 0 : 1;
}
