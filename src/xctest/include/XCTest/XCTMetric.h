// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A metric measures something over an interval, and reports numbers.

#ifndef XCTEST_XCTMETRIC_H
#define XCTEST_XCTMETRIC_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

// XCTPerformanceMeasurement exposes an NSMeasurement, and this SDK's
// Foundation headers do not carry it. Declared here rather than in the
// implementation because a caller that reads -[XCTPerformanceMeasurement value]
// has to name the type, and a declaration the caller cannot see is a type the
// caller cannot use. Guarded so a full SDK, which has the real header, wins.
#if !__has_include(<Foundation/NSMeasurement.h>)

@class NSUnit;

/// The unit a measurement is expressed in: a symbol, not a format.
@interface NSUnit : NSObject
+ (instancetype)unitWithSymbol:(NSString *)symbol;
- (instancetype)initWithSymbol:(NSString *)symbol;
@property (readonly, copy) NSString *symbol;
@end

/// A number paired with the unit it is counted in.
@interface NSMeasurement : NSObject
+ (instancetype)measurementWithDoubleValue:(double)value unit:(NSUnit *)unit;
- (instancetype)initWithDoubleValue:(double)value unit:(NSUnit *)unit;
- (double)doubleValueForUnit:(NSUnit *)unit;
@property (readonly, copy) NSNumber *value;
@property (readonly, copy) NSUnit *unit;
@property (readonly) double doubleValue;
@end

#endif /* !__has_include(<Foundation/NSMeasurement.h>) */

/// Which direction is an improvement, when comparing a measurement against a
/// baseline. Time and memory are better when smaller; throughput is better when
/// larger; a count with no natural direction is unspecified.
typedef NS_ENUM(NSInteger, XCTPerformanceMeasurementPolarity) {
    /// Smaller is better.
    XCTPerformanceMeasurementPolarityPrefersSmaller = -1,

    /// Neither direction is better. Use this when the number is a fact rather
    /// than a score, so nothing downstream tries to rank on it.
    XCTPerformanceMeasurementPolarityUnspecified,

    /// Larger is better.
    XCTPerformanceMeasurementPolarityPrefersLarger,
};

/// A point in time, at the three precisions a metric might need.
///
/// `absoluteTime` is a mach_absolute_time() reading, which is what a metric
/// that subtracts two readings must use: it is a bare counter, so the
/// difference is exact and costs nothing. `absoluteTimeNanoSeconds` is the same
/// moment converted to nanoseconds, which is a convenience for reporting rather
/// than something to subtract, because the conversion is a multiply and can
/// overflow where the raw difference would not. `date` is for a human.
@interface XCTPerformanceMeasurementTimestamp : NSObject

/// mach_absolute_time() at construction.
@property (readonly) uint64_t absoluteTime;

/// `absoluteTime` converted through the timebase. Does not advance while the
/// system is asleep.
@property (readonly) uint64_t absoluteTimeNanoSeconds;

/// The wall-clock moment, for reporting.
@property (readonly, copy) NSDate *date;

- (instancetype)initWithAbsoluteTime:(uint64_t)absoluteTime
                                date:(NSDate *)date NS_DESIGNATED_INITIALIZER;

/// Now.
- (instancetype)init;

@end

/// One metric's numbers for one iteration of a measure block.
@interface XCTPerformanceMeasurement : NSObject

/// What is being measured, e.g. "com.apple.XCTPerformanceMetric_WallClockTime".
/// Stable across releases and across display-name changes, so it is what a
/// baseline is keyed on.
@property (readonly, copy) NSString *identifier;

/// The same thing for a human, e.g. "Wall Clock Time". May be localized; never
/// key anything on it.
@property (readonly, copy) NSString *displayName;

/// The value as an NSMeasurement, or nil when it was built from a double and a
/// unit symbol.
///
/// The two initializer families are why this is nullable rather than derived.
/// A caller with an NSUnit in hand hands over the measurement and gets one
/// back; the designated initializer takes a double and a unit *symbol* and has
/// no unit object to build one from, so `value` is nil rather than a guess at
/// which unit a bare symbol refers to.
@property (readonly, copy, nullable) NSMeasurement *value;

/// `value.doubleValue`, or the double this was initialized with.
@property (readonly) double doubleValue;

/// The unit the double is in, e.g. "s".
@property (readonly, copy) NSString *unitSymbol;

/// Which direction is better. Defaults to
/// XCTPerformanceMeasurementPolarityUnspecified, so a metric that does not say
/// is not silently ranked as "smaller is better".
@property (readonly) XCTPerformanceMeasurementPolarity polarity;

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                        doubleValue:(double)doubleValue
                        unitSymbol:(NSString *)unitSymbol NS_DESIGNATED_INITIALIZER;

/// Designated over the double form: a caller who has a unit object gets a
/// `value` back. Polarity defaults to unspecified.
- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                             value:(NSMeasurement *)value;

/// As above, with the direction of improvement stated explicitly.
- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                             value:(NSMeasurement *)value
                          polarity:(XCTPerformanceMeasurementPolarity)polarity;

- (instancetype)init XCT_UNAVAILABLE("Default initializer not available. Use -initWithIdentifier:displayName:doubleValue:unitSymbol: instead.");
+ (instancetype)new XCT_UNAVAILABLE("Default initializer not available. Use -initWithIdentifier:displayName:doubleValue:unitSymbol: instead.");

@end

/// Something that can be measured across the iterations of a measure block.
///
/// A metric is copied once per iteration, so adopting NSCopying is required and
/// a metric that holds mutable state must copy it rather than share it. The
/// reason for the copy is that the same metric instance is asked to report
/// after every iteration, and a metric that accumulated into itself would report
/// the total every time instead of that iteration's slice.
@protocol XCTMetric <NSCopying, NSObject>

@required

/// Report what was measured between `startTime` and `endTime`.
///
/// Called once per iteration, after -didStopMeasuring, with the interval that
/// was actually measured rather than the whole iteration. A metric that
/// accumulates over the whole run can use the interval to subtract its way back
/// to just this iteration, which is why both bounds are passed in.
///
/// Return nil with `error` set to fail the test: a metric that cannot measure
/// is a test failure, not a zero, because a zero reads as "fast".
- (nullable NSArray<XCTPerformanceMeasurement *> *)
    reportMeasurementsFromStartTime:(XCTPerformanceMeasurementTimestamp *)startTime
                          toEndTime:(XCTPerformanceMeasurementTimestamp *)endTime
                              error:(NSError **)error;

@optional

/// Start measuring. Invoked just before the measure block runs.
- (void)willBeginMeasuring;

/// Stop measuring. Invoked just after the measure block returns.
- (void)didStopMeasuring;

@end

/// Elapsed monotonic time, the metric to reach for when nothing better is
/// available.
///
/// Monotonic, so a clock adjustment or the system suspending mid-test cannot
/// make an interval come out negative.
@interface XCTClockMetric : NSObject <XCTMetric>
- (instancetype)init;
@end

XCT_HEADER_AUDIT_END

#endif /* XCTTEST_XCTMETRIC_H */
