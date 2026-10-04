// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// One discovered test method: which method it is, which convention it is
// written in, and the invocation already built for it. Not installed into the
// framework -- discovery and the invoker are the only callers.

#import "XCTestInternal.h"
#import "XCTestFoundationCompat.h"

@implementation XCTTestInvocationDescriptor

- (instancetype)initWithSelectorString:(NSString *)selectorString
                        conventionNumber:(NSNumber *)conventionNumber
                             invocation:(NSInvocation *)invocation
                     customErrorMessage:(NSString *)customErrorMessage
{
    self = [super init];
    if (self != nil) {
        _selectorString = [selectorString copy];
        // Held rather than copied or reduced to an integer: a descriptor can be
        // made by a caller that has not decided which convention it is, and nil
        // says that in a way a zero would not -- zero is the standard
        // convention, so a stand-in for it would report a decision as though it
        // had been made.
        _convention = conventionNumber;
        _invocation = invocation;
        _customErrorMessage = [customErrorMessage copy];
    }
    return self;
}

- (instancetype)initWithSelectorString:(NSString *)selectorString
                            invocation:(NSInvocation *)invocation
                     customErrorMessage:(NSString *)customErrorMessage
{
    // No convention stated is not the standard convention. Passing nil leaves
    // the question open for whoever asks the descriptor, which is what a caller
    // that only has a name and an invocation can honestly say.
    return [self initWithSelectorString:selectorString
                       conventionNumber:nil
                              invocation:invocation
                      customErrorMessage:customErrorMessage];
}

- (instancetype)initWithSelectorString:(NSString *)selectorString
                            convention:(XCTTestMethodConvention)convention
                            invocation:(NSInvocation *)invocation
                     customErrorMessage:(NSString *)customErrorMessage
{
    return [self initWithSelectorString:selectorString
                       conventionNumber:[NSNumber numberWithInteger:convention]
                              invocation:invocation
                      customErrorMessage:customErrorMessage];
}

- (NSString *)description
{
    // The class name is asked for rather than written down, so a subclass
    // describes itself as itself. The selector is what makes the line useful:
    // "which test" is the question an error about a descriptor is asking.
    return [NSString stringWithFormat:@"<%@ %@>", NSStringFromClass([self class]), _selectorString];
}

@end
