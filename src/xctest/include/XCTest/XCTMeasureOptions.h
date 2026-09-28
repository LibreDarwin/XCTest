// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// How many times to run a measure block, and who decides when the measured
// region starts and ends.

#ifndef XCTEST_XCTMEASUREOPTIONS_H
#define XCTEST_XCTMEASUREOPTIONS_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

/// Who marks the boundaries of the measured region.
typedef NS_OPTIONS(NSUInteger, XCTMeasurementInvocationOptions) {
    /// XCTest brackets the block itself: measuring starts just before the block
    /// is invoked and stops just after it returns. This is the default, and it
    /// is the only option that can measure a block which never calls
    /// -startMeasuring.
    XCTMeasurementInvocationNone = 0,

    /// Measuring does not start until the block calls -startMeasuring. Pair
    /// this with setup work you do not want counted.
    XCTMeasurementInvocationManuallyStart = 1 << 0,

    /// Measuring continues after the block returns, until the block calls
    /// -stopMeasuring. Pair this with teardown you do want counted.
    XCTMeasurementInvocationManuallyStop = 1 << 1,
};

/// The settings -measureWithOptions:block: and its siblings read.
///
/// Iteration count matters more than it looks. The first run of a measured
/// block pays for the page faults, the lazy initialization and the branch
/// predictor and instruction cache misses that no later run pays, so including
/// it drags the reported numbers toward a worst case that says nothing about
/// the code. So the block runs `iterationCount + 1` times and the first
/// iteration is thrown away. The reported measurements are all from later runs.
@interface XCTMeasureOptions : NSObject

/// A fresh set of the recommended defaults: no manual invocation, five
/// iterations.
@property (class, readonly, copy) XCTMeasureOptions *defaultOptions;

/// Defaults to XCTMeasurementInvocationNone.
@property (nonatomic) XCTMeasurementInvocationOptions invocationOptions;

/// Times the block is invoked and measured. Defaults to 5. The block is
/// actually invoked one more time than this, and that first iteration is
/// discarded.
@property (nonatomic) NSUInteger iterationCount;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTTEST_XCTMEASUREOPTIONS_H */
