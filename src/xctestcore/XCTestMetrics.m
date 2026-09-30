// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Performance measurement: the value types a metric reports, the metric that
// measures time, the options that say how often to run a block, and the
// XCTestCase category that runs it.
//
// Two things here are worth reading before changing anything. The first is that
// a metric is copied per iteration, so a metric that accumulated into itself
// would report the running total every time instead of that iteration's slice.
// The second is that the first iteration is always discarded: it pays for the
// page faults and cache misses that no later iteration pays, so including it
// pulls the reported numbers toward a worst case that says nothing about the
// code under test.

#import "XCTestInternal.h"

// The reduced NSArray.h omits -componentsJoinedByString:, which the failure
// message needs to name every unrecognized metric in one line rather than only
// the first. Nothing here is a public API this header owns.
#import "XCTestFoundationCompat.h"

#include <mach/mach_time.h>

NSErrorDomain const XCTestPerformanceMetricErrorDomain = @"XCTestPerformanceMetric";

/// The identifier a wall-clock measurement is keyed on. Stable across releases
/// and display-name changes, because a baseline is keyed on it.
XCTPerformanceMetric const XCTPerformanceMetric_WallClockTime =
    @"com.apple.XCTPerformanceMetric_WallClockTime";

#pragma mark - Timestamps

@implementation XCTPerformanceMeasurementTimestamp

- (instancetype)init
{
    // One reading of both clocks rather than two calls: a timestamp whose
    // absoluteTime and date disagree is worse than one that is a microsecond
    // stale in both.
    return [self initWithAbsoluteTime:mach_absolute_time() date:[NSDate date]];
}

- (instancetype)initWithAbsoluteTime:(uint64_t)absoluteTime date:(NSDate *)date
{
    self = [super init];
    if (self) {
        _absoluteTime = absoluteTime;
        _date = [date copy];
    }
    return self;
}

- (uint64_t)absoluteTimeNanoSeconds
{
    mach_timebase_info_data_t info;
    if (mach_timebase_info(&info) != KERN_SUCCESS || info.denom == 0) {
        // Without a timebase there is no correct conversion. Reporting zero
        // would be a plausible-looking wrong number, so the raw reading is
        // returned instead: it is not nanoseconds, but the caller can see it is
        // not a time by comparing it against absoluteTime.
        return _absoluteTime;
    }
    // The multiply is done in the order that keeps the intermediate small:
    // absoluteTime * numer overflows long before (absoluteTime / denom) * numer
    // does, and dividing first loses only the remainder.
    return (_absoluteTime / info.denom) * info.numer;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, absoluteTime %llu, date %@>",
                                      NSStringFromClass([self class]), self,
                                      _absoluteTime, _date];
}

@end

#pragma mark - Measurements

/// XCTPerformanceMeasurement with a double and a unit symbol *and* a polarity.
///
/// The public API has no such initializer: the polarity-taking initializers all
/// take an NSMeasurement, because a caller holding a unit object has a
/// measurement. A metric reporting from a double and a symbol has no unit object
/// but does know its polarity -- time is better when smaller, throughput when
/// larger -- so the built-in metrics get it from here rather than by assigning to
/// a property after construction, which would make the polarity briefly wrong to
/// anything that read the object mid-construction.
///
/// A class extension rather than a category, because NS_DESIGNATED_INITIALIZER is
/// not allowed on a category method. It is designated like the public one, and
/// both call -[NSObject init]: one cannot be the other's designated initializer,
/// since clang requires a designated initializer to invoke a designated
/// initializer on super rather than on self. A private setter declared here keeps
/// the field assignment in one place instead of twice.
@interface XCTPerformanceMeasurement ()
- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                        doubleValue:(double)doubleValue
                        unitSymbol:(NSString *)unitSymbol
                          polarity:(XCTPerformanceMeasurementPolarity)polarity NS_DESIGNATED_INITIALIZER;
- (void)_xct_setIdentifier:(NSString *)identifier
                displayName:(NSString *)displayName
                     value:(nullable NSMeasurement *)value
               doubleValue:(double)doubleValue
                unitSymbol:(NSString *)unitSymbol
                  polarity:(XCTPerformanceMeasurementPolarity)polarity;
@end

@implementation XCTPerformanceMeasurement

// Two designated initializers, both calling -[NSObject init] and both funnelling
// through this one setter, rather than one calling the other: clang requires a
// designated initializer to invoke a designated initializer on super, so the
// private one that carries a polarity cannot be the one the public designated
// initializer calls.
- (void)_xct_setIdentifier:(NSString *)identifier
                displayName:(NSString *)displayName
                     value:(NSMeasurement *)value
               doubleValue:(double)doubleValue
                unitSymbol:(NSString *)unitSymbol
                  polarity:(XCTPerformanceMeasurementPolarity)polarity
{
    _identifier = [identifier copy];
    _displayName = [displayName copy];
    _value = [value copy];
    _doubleValue = doubleValue;
    _unitSymbol = [unitSymbol copy];
    _polarity = polarity;
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                        doubleValue:(double)doubleValue
                        unitSymbol:(NSString *)unitSymbol
{
    self = [super init];
    if (self) {
        // Polarity is set explicitly, though it is also the zero value: it is
        // the one field whose default would silently rank results, and "smaller
        // is better" is a claim about what was measured that a bare number has
        // not made. _value stays nil -- there is no unit object behind a unit
        // symbol, and inventing one from a string would produce a measurement
        // that looked convertible and was not.
        [self _xct_setIdentifier:identifier
                     displayName:displayName
                          value:nil
                    doubleValue:doubleValue
                     unitSymbol:unitSymbol
                       polarity:XCTPerformanceMeasurementPolarityUnspecified];
    }
    return self;
}

// The private designated initializer, declared in the class extension above.
// Carries the polarity that the public double-and-symbol initializer cannot.
- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                        doubleValue:(double)doubleValue
                        unitSymbol:(NSString *)unitSymbol
                          polarity:(XCTPerformanceMeasurementPolarity)polarity
{
    self = [super init];
    if (self) {
        [self _xct_setIdentifier:identifier
                     displayName:displayName
                          value:nil
                    doubleValue:doubleValue
                     unitSymbol:unitSymbol
                       polarity:polarity];
    }
    return self;
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                             value:(NSMeasurement *)value
{
    return [self initWithIdentifier:identifier
                        displayName:displayName
                              value:value
                           polarity:XCTPerformanceMeasurementPolarityUnspecified];
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                             value:(NSMeasurement *)value
                          polarity:(XCTPerformanceMeasurementPolarity)polarity
{
    self = [self initWithIdentifier:identifier
                        displayName:displayName
                         doubleValue:value.doubleValue
                         unitSymbol:value.unit.symbol
                           polarity:polarity];
    if (self) {
        // The caller's unit object is kept, so `value` comes back as something
        // convertible into other units rather than only as a bare double.
        _value = [value copy];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, %@ (%@) %g %@>",
                                      NSStringFromClass([self class]), self,
                                      _displayName, _identifier, _doubleValue, _unitSymbol];
}

@end

#pragma mark - Clock metric

@implementation XCTClockMetric

- (instancetype)init
{
    // There is nothing to configure: the clock is the clock, and a metric that
    // let a caller pick the interval to measure would be measuring something
    // other than what the framework measures everyone else with.
    return [super init];
}

// Immutable, so a copy is the receiver. Declared because XCTMetric requires
// NSCopying, and because a metric that handed back a shared mutable object would
// break the per-iteration reporting contract in the protocol's documentation.
- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

- (NSArray<XCTPerformanceMeasurement *> *)
    reportMeasurementsFromStartTime:(XCTPerformanceMeasurementTimestamp *)startTime
                          toEndTime:(XCTPerformanceMeasurementTimestamp *)endTime
                              error:(NSError **)error
{
    if (startTime == nil || endTime == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:XCTestPerformanceMetricErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"XCTClockMetric was asked to report a measurement without both bounds of the interval."}];
        }
        return nil;
    }

    // The subtraction is on the raw counter and the conversion is applied once,
    // to the difference. Converting both ends and subtracting would round twice
    // and, for a short interval, could round a real duration to nothing.
    if (endTime.absoluteTime < startTime.absoluteTime) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:XCTestPerformanceMetricErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"XCTClockMetric measured a negative interval, which a monotonic clock cannot produce."}];
        }
        return nil;
    }

    XCTPerformanceMeasurementTimestamp *delta =
        [[XCTPerformanceMeasurementTimestamp alloc] initWithAbsoluteTime:endTime.absoluteTime - startTime.absoluteTime
                                                                   date:[NSDate date]];
    // Time is better when it is smaller, and that is stated rather than left
    // unspecified so a baseline comparison does not have to guess the direction.
    return @[[[XCTPerformanceMeasurement alloc] initWithIdentifier:XCTPerformanceMetric_WallClockTime
                                                       displayName:@"Wall Clock Time"
                                                        doubleValue:(double)delta.absoluteTimeNanoSeconds / (double)NSEC_PER_SEC
                                                        unitSymbol:@"s"
                                                          polarity:XCTPerformanceMeasurementPolarityPrefersSmaller]];
}

@end

#pragma mark - Options

/// The documented default. Apple's header says the property's default value is
/// 5, which only holds if something sets it; -init does, so that the documented
/// default is the default rather than a property comment describing a value no
/// code path produces.
static const NSUInteger XCTMeasureOptionsDefaultIterationCount = 5;

@implementation XCTMeasureOptions

- (instancetype)init
{
    self = [super init];
    if (self) {
        _invocationOptions = XCTMeasurementInvocationNone;
        _iterationCount = XCTMeasureOptionsDefaultIterationCount;
    }
    return self;
}

+ (XCTMeasureOptions *)defaultOptions
{
    return [[self alloc] init];
}

@end

#pragma mark - The results record

@implementation XCTPerformanceActivityRecord

- (instancetype)initWithName:(NSString *)name
                measurements:(NSArray<XCTPerformanceMeasurement *> *)measurements
               iterationCount:(NSUInteger)iterationCount
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _measurements = [measurements copy] ?: @[];
        _iterationCount = iterationCount;
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p, %@, %lu iterations, %lu measurements>",
                                      NSStringFromClass([self class]), self, _name,
                                      (unsigned long)_iterationCount, (unsigned long)_measurements.count];
}

@end

#pragma mark - Running a measure block

/// The state of one measure block while it is running. Not the test case's,
/// because a measure block may be nested inside another and the inner one must
/// not see the outer one's start and stop times.
@interface _XCTMeasureInvocation : NSObject
@property (nonatomic, strong) NSMutableArray<XCTPerformanceMeasurement *> *measurements;
/// The metric copies for this iteration, one per requested metric.
@property (nonatomic, copy) NSArray<id<XCTMetric>> *iterationMetrics;
@property (nonatomic, strong, nullable) XCTPerformanceMeasurementTimestamp *startTime;
@property (nonatomic, strong, nullable) XCTPerformanceMeasurementTimestamp *endTime;
@property (nonatomic) BOOL manualStartExpected;
@property (nonatomic) BOOL manualStopExpected;
@property (nonatomic) BOOL stopAlreadyCalled;
@property (nonatomic) BOOL discarded;
@end

@implementation _XCTMeasureInvocation
@end

@implementation XCTestCase (XCTPerformanceAnalysis)

#pragma mark Defaults

+ (NSArray<XCTPerformanceMetric> *)defaultPerformanceMetrics
{
    return @[XCTPerformanceMetric_WallClockTime];
}

+ (NSArray<id<XCTMetric>> *)defaultMetrics
{
    return @[[[XCTClockMetric alloc] init]];
}

+ (XCTMeasureOptions *)defaultMeasureOptions
{
    return [XCTMeasureOptions defaultOptions];
}

#pragma mark Public entry points

- (void)measureBlock:(XCT_NOESCAPE void (^)(void))block
{
    // Routed through the same loop as the string API rather than implemented
    // separately, so a test using the old entry point gets the same iteration
    // count, the same discarded warm-up and the same results. The record is
    // named for the method the caller actually wrote, because that is the only
    // thing a result reader has to go on when a test has several measure blocks.
    [self _xct_runNameBasedMeasureBlock:block
                                  names:[self.class defaultPerformanceMetrics]
                          automaticStart:YES
                                    name:@"measureBlock"];
}

- (void)measureWithMetrics:(NSArray<id<XCTMetric>> *)metrics block:(XCT_NOESCAPE void (^)(void))block
{
    [self _xct_runMeasureBlock:block
                       metrics:metrics
                       options:[self.class defaultMeasureOptions]
                          name:@"measureWithMetrics"];
}

- (void)measureWithOptions:(XCTMeasureOptions *)options block:(XCT_NOESCAPE void (^)(void))block
{
    [self _xct_runMeasureBlock:block
                       metrics:[self.class defaultMetrics]
                       options:options
                          name:@"measureWithOptions"];
}

- (void)measureWithMetrics:(NSArray<id<XCTMetric>> *)metrics
                   options:(XCTMeasureOptions *)options
                     block:(XCT_NOESCAPE void (^)(void))block
{
    [self _xct_runMeasureBlock:block metrics:metrics options:options name:@"measureWithMetrics"];
}

- (void)measureMetrics:(NSArray<XCTPerformanceMetric> *)metrics
    automaticallyStartMeasuring:(BOOL)automaticallyStartMeasuring
                     forBlock:(XCT_NOESCAPE void (^)(void))block
{
    [self _xct_runNameBasedMeasureBlock:block
                                  names:metrics
                          automaticStart:automaticallyStartMeasuring
                                    name:@"measureMetrics"];
}

/// Shared by the two string-named entry points, which differ only in where the
/// metric names come from and what the resulting record is called.
- (void)_xct_runNameBasedMeasureBlock:(XCT_NOESCAPE void (^)(void))block
                                 names:(NSArray<XCTPerformanceMetric> *)names
                         automaticStart:(BOOL)automaticallyStartMeasuring
                                   name:(NSString *)name
{
    // The string API has no options object of its own, so the iteration count
    // and the discarded first run come from +defaultMeasureOptions. A subclass
    // that overrides that property therefore changes the old API's behaviour
    // too, which is what makes the two generations agree on iteration count.
    //
    // Resolved in one pass, collecting the names that could not be resolved
    // rather than stopping at the first: the failure message should list all of
    // them, because a caller who has misspelled two names should not have to
    // run the test twice to find out.
    NSMutableArray<id<XCTMetric>> *resolved = [NSMutableArray arrayWithCapacity:names.count];
    NSMutableArray<NSString *> *unknown = [NSMutableArray array];
    for (XCTPerformanceMetric metric in names) {
        id<XCTMetric> object = [self _xct_metricForPerformanceMetricName:metric];
        if (object == nil) {
            [unknown addObject:metric];
        } else {
            [resolved addObject:object];
        }
    }
    if (unknown.count != 0) {
        [self _xct_recordMeasurementFailure:[NSString stringWithFormat:
            @"-%@ was given %lu metric name(s) it does not recognize: %@. Only the names in "
            @"+defaultPerformanceMetrics can be measured by name; for anything else use "
            @"-measureWithMetrics:options:block: with a metric object.",
            name, (unsigned long)unknown.count, [unknown componentsJoinedByString:@", "]]];
        return;
    }

    XCTMeasureOptions *options = [self.class defaultMeasureOptions];
    if (!automaticallyStartMeasuring) {
        options.invocationOptions |= XCTMeasurementInvocationManuallyStart;
    }
    [self _xct_runMeasureBlock:block metrics:resolved options:options name:name];
}

- (void)startMeasuring
{
    _XCTMeasureInvocation *invocation = self.xct_measureInvocation;
    if (invocation == nil) {
        [self _xct_recordMeasurementFailure:@"-startMeasuring was called outside a measure block. "
            @"It marks the start of the region to measure, so there is nothing for it to mark."];
        return;
    }
    if (!invocation.manualStartExpected) {
        // The caller asked XCTest to bracket the whole block, so a manual start
        // would silently discard everything before it. Reported rather than
        // ignored, because the numbers would otherwise be quietly wrong.
        [self _xct_recordMeasurementFailure:@"-startMeasuring was called although this measure block is already "
            @"being measured from its start. Pass XCTMeasurementInvocationManuallyStart (or pass NO for "
            @"automaticallyStartMeasuring:) if the block should mark its own start."];
        return;
    }
    if (invocation.startTime != nil) {
        [self _xct_recordMeasurementFailure:@"-startMeasuring was called more than once in one measure block "
            @"iteration. There is one measured region per iteration."];
        return;
    }
    invocation.startTime = [[XCTPerformanceMeasurementTimestamp alloc] init];
}

- (void)stopMeasuring
{
    _XCTMeasureInvocation *invocation = self.xct_measureInvocation;
    if (invocation == nil) {
        [self _xct_recordMeasurementFailure:@"-stopMeasuring was called outside a measure block. "
            @"It marks the end of the region to measure, so there is nothing for it to mark."];
        return;
    }
    if (invocation.stopAlreadyCalled) {
        [self _xct_recordMeasurementFailure:@"-stopMeasuring was called more than once in one measure block "
            @"iteration. There is one measured region per iteration, and a second call would extend or restart it."];
        return;
    }
    invocation.stopAlreadyCalled = YES;
    invocation.endTime = [[XCTPerformanceMeasurementTimestamp alloc] init];
}

#pragma mark The loop

- (void)_xct_runMeasureBlock:(void (^)(void))block
                      metrics:(NSArray<id<XCTMetric>> *)metrics
                      options:(XCTMeasureOptions *)options
                         name:(NSString *)name
{
    if (block == nil) {
        [self _xct_recordMeasurementFailure:
            [NSString stringWithFormat:@"-%@ was given a nil block. There is nothing to measure.", name]];
        return;
    }
    if (metrics.count == 0) {
        // Measuring nothing would report an empty result that reads as "this was
        // fast", which is worse than no result at all.
        [self _xct_recordMeasurementFailure:
            [NSString stringWithFormat:@"-%@ was given no metrics. Add at least one, or use -measureBlock: "
                                        @"for wall clock time.", name]];
        return;
    }
    if (options == nil) {
        options = [self.class defaultMeasureOptions];
    }

    NSUInteger iterationCount = options.iterationCount;
    BOOL manualStart = (options.invocationOptions & XCTMeasurementInvocationManuallyStart) != 0;
    BOOL manualStop = (options.invocationOptions & XCTMeasurementInvocationManuallyStop) != 0;

    NSMutableArray<XCTPerformanceMeasurement *> *collected = [NSMutableArray array];

    // The warm-up, then one measured run per iteration. The warm-up is a full dry
    // run -- the block runs with its manual bounds live and its metrics started,
    // exactly as a measured iteration would -- and only what it produced is
    // thrown away. Skipping the setup instead would mean that a block which marks
    // its own boundaries failed on every measure call, complaining that it was
    // called outside a measure block, which is a complaint about the warm-up
    // rather than about the caller.
    //
    // The first call into freshly loaded code pays for the page faults, the lazy
    // initialization and the cold caches, and keeping that run's number would
    // report a worst case that says nothing about the code.
    // A measure call made inside a run that is itself being thrown away is warm-up
    // work too, so it keeps nothing: not its measurements, not its record. Left
    // alone it would leave a record per enclosing iteration, warm-up included --
    // one more record than the iteration count the caller asked for.
    _XCTMeasureInvocation *enclosing = self.xct_measureInvocation;
    BOOL keep = enclosing == nil || !enclosing.discarded;

    // The warm-up is always this call's own throwaway run, even for a nested call
    // that is being dropped wholesale below.
    [self _xct_runIteration:block
                     metrics:metrics
                 manualStart:manualStart
                  manualStop:manualStop
               keepResults:NO];

    for (NSUInteger iteration = 0; iteration < iterationCount; iteration++) {
        _XCTMeasureInvocation *invocation = [self _xct_runIteration:block
                                                             metrics:metrics
                                                         manualStart:manualStart
                                                          manualStop:manualStop
                                                           keepResults:keep];
        [collected addObjectsFromArray:invocation.measurements];
    }
    if (!keep) {
        return;
    }

    XCTPerformanceActivityRecord *record = [[XCTPerformanceActivityRecord alloc]
        initWithName:name
         measurements:collected
        iterationCount:iterationCount];
    // Read-modify-write through the accessors rather than appending to a mutable
    // array in place, so the getter's copy is never the thing being mutated and
    // the test case stays the only owner of its storage.
    NSMutableArray<XCTPerformanceActivityRecord *> *records =
        [self.xct_performanceRecords mutableCopy];
    [records addObject:record];
    self.xct_performanceRecords = records;
}

/// One run of the block. `keepResults` is NO for the discarded warm-up: the
/// invocation is still real, so the block's own -startMeasuring/-stopMeasuring
/// calls land, but the measurements and the failures it produced are dropped
/// rather than reported. Auditing the block `iterationCount` times is the point;
/// a sixth copy of the same complaint is noise.
- (_XCTMeasureInvocation *)_xct_runIteration:(void (^)(void))block
                                     metrics:(NSArray<id<XCTMetric>> *)metrics
                                 manualStart:(BOOL)manualStart
                                  manualStop:(BOOL)manualStop
                                keepResults:(BOOL)keepResults
{
    // A fresh copy per iteration, per the XCTMetric contract: the same instance
    // reporting twice would report its running total twice. The cast is explicit
    // because -copy on id<XCTMetric> returns id.
    NSMutableArray<id<XCTMetric>> *iterationMetrics = [NSMutableArray arrayWithCapacity:metrics.count];
    for (id<XCTMetric> metric in metrics) {
        [iterationMetrics addObject:(id<XCTMetric>)[(id)metric copy]];
    }

    _XCTMeasureInvocation *invocation = [[_XCTMeasureInvocation alloc] init];
    invocation.measurements = [NSMutableArray array];
    invocation.iterationMetrics = iterationMetrics;
    invocation.manualStartExpected = manualStart;
    invocation.manualStopExpected = manualStop;
    invocation.discarded = !keepResults;
    // stopAlreadyCalled starts NO whatever the mode. It records whether the block
    // has already called -stopMeasuring, which is a different question from
    // whether the block is the one expected to call it: pre-setting it for the
    // manual mode would make the block's first call look like a second one.
    invocation.stopAlreadyCalled = NO;
    // Saved and restored so a block that measures something inside a measure
    // block still leaves the outer block's own bounds intact. -startMeasuring and
    // -stopMeasuring act on the innermost invocation, which is the one the code
    // that called them is inside of.
    _XCTMeasureInvocation *enclosing = self.xct_measureInvocation;
    self.xct_measureInvocation = invocation;

    for (id<XCTMetric> metric in iterationMetrics) {
        if ([metric respondsToSelector:@selector(willBeginMeasuring)]) {
            [metric willBeginMeasuring];
        }
    }
    if (!manualStart) {
        invocation.startTime = [[XCTPerformanceMeasurementTimestamp alloc] init];
    }

    block();

    if (!manualStop) {
        invocation.endTime = [[XCTPerformanceMeasurementTimestamp alloc] init];
    }

    for (id<XCTMetric> metric in iterationMetrics) {
        if ([metric respondsToSelector:@selector(didStopMeasuring)]) {
            [metric didStopMeasuring];
        }
    }

    if (invocation.startTime == nil || invocation.endTime == nil) {
        // A block that was told to mark its own boundaries and did not. The
        // alternative is reporting an interval of zero, which is a plausible
        // number meaning nothing.
        [self _xct_recordMeasurementFailure:
            @"A measure block was told to call -startMeasuring/-stopMeasuring and did not. "
            @"Every measured iteration needs both bounds of the region."];
    } else {
        for (id<XCTMetric> metric in iterationMetrics) {
            NSError *error = nil;
            NSArray<XCTPerformanceMeasurement *> *reported =
                [metric reportMeasurementsFromStartTime:invocation.startTime
                                              toEndTime:invocation.endTime
                                                  error:&error];
            if (reported == nil) {
                        [self _xct_recordMeasurementFailure:
                    [NSString stringWithFormat:@"A metric failed to report a measurement: %@",
                                               error.localizedDescription ?: @"the metric gave no reason."]];
            } else {
                [invocation.measurements addObjectsFromArray:reported];
            }
        }
    }

    self.xct_measureInvocation = enclosing;
    return invocation;
}

#pragma mark Helpers

- (id<XCTMetric>)_xct_metricForPerformanceMetricName:(NSString *)metric
{
    if ([metric isEqualToString:XCTPerformanceMetric_WallClockTime]) {
        return [[XCTClockMetric alloc] init];
    }
    return nil;
}

- (void)_xct_recordMeasurementFailure:(NSString *)description
{
    // The discarded warm-up is not audited. A block that is malformed is
    // malformed on every measured iteration, and those runs report it; a sixth
    // copy from the throwaway run would only make the count wrong.
    if (((_XCTMeasureInvocation *)self.xct_measureInvocation).discarded) {
        return;
    }
    // A measurement failure is a test failure and follows the same rule as a
    // failed assertion: recorded through the test run, and raised on the test
    // thread unless the run continues after failure. So a block that breaks the
    // contract ends the test there when the run stops at the first failure, and
    // is reported once per measured iteration when it does not. The failure is
    // attributed to the call site inside the measure block, which is where the
    // mistake is.
    _XCTRecordIssueOnTestCase(self,
                              [[XCTIssue alloc]
                                  initWithType:XCTIssueTypeTestFailure
                             compactDescription:@"Measure block failed"
                            detailedDescription:description
                              sourceCodeContext:_XCTCurrentSourceCodeContext()
                                associatedError:nil
                                    attachments:@[]]);
}

@end
