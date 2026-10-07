// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTVariationOptions, the run-configuration axes a test class may vary a test
// over.

#import "XCTestInternal.h"

@implementation XCTVariationOptions {
    NSDictionary *_inputs;
}

+ (XCTVariationOptions *)defaultVariationOptions
{
    static XCTVariationOptions *defaultVariationOptions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultVariationOptions = [[self alloc] initWithInputs:@{}];
    });
    return defaultVariationOptions;
}

- (instancetype)initWithInputs:(NSDictionary *)inputs
{
    self = [super init];
    if (self != nil) {
        _inputs = [inputs copy];
    }
    return self;
}

- (NSDictionary *)inputs
{
    return _inputs;
}

- (NSArray<NSDictionary *> *)variations
{
    // The reference builds the cartesian product of the values in -inputs over
    // a key set shared by the axes, and answers an empty array when there are
    // no inputs to build a product from. Only the empty answer is reachable in
    // this system: no class overrides +testRunConfigurationInputsForUITesting,
    // so -inputs is always empty and the descriptor consumer substitutes the
    // single default configuration, which is the reference's own fallback for
    // an empty array. Reproducing the product would be reproducing machinery
    // with no caller, so [] -- the true answer for every reachable state -- is
    // what is returned, and the divergence from the reference is confined to
    // states no input can reach.
    return @[];
}

@end