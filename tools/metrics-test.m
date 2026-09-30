// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for the performance measurement API.
//
// The measure loop is the part of this that nothing else in the tree would catch
// being wrong. The types link, the category compiles, -measureBlock: returns,
// and a measure loop that ran the block once, or ran it six times and reported
// all six, or reported the cold first run, would all still produce a plausible
// number attached to a passing test. So the checks here are mostly about counts
// and call sequences rather than about values: how many times the block ran, how
// many measurements came back, and in what order the metric was told to start
// and stop.
//
// The other thing worth pinning is that a *client* can implement XCTMetric. The
// protocol's optional and required parts are the contract a third-party metric
// is written against, so a fixture metric here is also the check that the
// protocol is usable from outside the framework and that a metric which returns
// an error becomes a test failure rather than a silent zero.
//
// Two private things are used, both from XCTestInternal.h and both because there
// is no public route to them:
//   - xct_performanceRecords, the only place the measurements recorded by a
//     measure block can be read back. The public API has no accessor, by design.
//   - XCTestCase's readwrite testRun, so a failure can be counted without
//     performing the test.
//
// The test case sets continueAfterFailure, and the reason is worth stating:
// -recordIssue: raises to unwind the test body on the first failure unless that
// is set, and several checks here exist precisely to provoke a measurement
// failure. With it set, each one is recorded and the harness carries on.
#import <XCTest/XCTest.h>

#import "XCTestInternal.h"

#import <stdio.h>
#import <unistd.h>

static int failures = 0;

static void ok(const char *name, BOOL passed, NSString *detail)
{
    const char *text = detail.UTF8String;
    printf("  %-56s %s%s%s\n", name, passed ? "PASS" : "FAIL",
           (text && *text) ? " - " : "", text ? text : "");
    if (!passed) {
        failures++;
    }
}

#pragma mark - Fixtures

/// A test case with one real test method, so the class is a shape a bundle could
/// actually contain rather than an object with no invocation.
@interface MeasureFixture : XCTestCase
@end

@implementation MeasureFixture
- (void)testNothing
{
}
@end

/// Counts its own life, so the checks can see how the loop treats a metric:
/// copies per iteration, and start/stop calls per run.
@interface CountingMetric : NSObject <XCTMetric>
@property (class, nonatomic, readonly) NSUInteger copiesMade;
@property (class, nonatomic, readonly) NSUInteger willBeginCalls;
@property (class, nonatomic, readonly) NSUInteger didStopCalls;
@property (nonatomic) NSUInteger identifier;
@end

static NSUInteger countingMetricCopies = 0;
static NSUInteger countingMetricWillBegin = 0;
static NSUInteger countingMetricDidStop = 0;

@implementation CountingMetric

+ (NSUInteger)copiesMade
{
    return countingMetricCopies;
}

+ (NSUInteger)willBeginCalls
{
    return countingMetricWillBegin;
}

+ (NSUInteger)didStopCalls
{
    return countingMetricDidStop;
}

+ (void)reset
{
    countingMetricCopies = 0;
    countingMetricWillBegin = 0;
    countingMetricDidStop = 0;
}

- (id)copyWithZone:(NSZone *)zone
{
    CountingMetric *copy = [[CountingMetric allocWithZone:zone] init];
    copy.identifier = self.identifier;
    countingMetricCopies++;
    return copy;
}

- (void)willBeginMeasuring
{
    countingMetricWillBegin++;
}

- (void)didStopMeasuring
{
    countingMetricDidStop++;
}

- (NSArray<XCTPerformanceMeasurement *> *)
    reportMeasurementsFromStartTime:(XCTPerformanceMeasurementTimestamp *)startTime
                          toEndTime:(XCTPerformanceMeasurementTimestamp *)endTime
                              error:(NSError **)error
{
    // The reported number is the metric's own identifier, not the interval it
    // was handed. That is what lets a check tell one iteration's copy from
    // another's, which an elapsed time could not do -- and it is also why the
    // bounds go unused here: this metric is a counter, not a clock.
    (void)startTime;
    (void)endTime;
    return @[[[XCTPerformanceMeasurement alloc] initWithIdentifier:@"harness.counter"
                                                       displayName:@"Counter"
                                                        doubleValue:(double)self.identifier
                                                        unitSymbol:@"count"]];
}

@end

/// A metric that cannot measure. The error path is the point: a metric that
/// returns nil with no error set would be indistinguishable from one that
/// measured nothing, so the loop has to treat nil as a failure either way and
/// this proves the failure is attributed.
@interface FailingMetric : NSObject <XCTMetric>
@end

@implementation FailingMetric

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

- (NSArray<XCTPerformanceMeasurement *> *)
    reportMeasurementsFromStartTime:(XCTPerformanceMeasurementTimestamp *)startTime
                          toEndTime:(XCTPerformanceMeasurementTimestamp *)endTime
                              error:(NSError **)error
{
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"harness.metric"
                                     code:7
                                 userInfo:@{NSLocalizedDescriptionKey: @"this metric cannot measure"}];
    }
    return nil;
}

@end

/// Collects the issues the measure loop records, which is how a check sees the
/// message and not just the count.
@interface IssueCollector : NSObject <XCTestObservation>
@property (nonatomic, strong) NSMutableArray<XCTIssue *> *issues;
@end

@implementation IssueCollector

- (instancetype)init
{
    self = [super init];
    if (self) {
        _issues = [NSMutableArray array];
    }
    return self;
}

- (void)testCase:(XCTestCase *)testCase didRecordIssue:(XCTIssue *)issue
{
    [self.issues addObject:issue];
}

@end

#pragma mark - Helpers

static IssueCollector *collector = nil;

/// A test case with a run attached and failures that do not unwind it, so a
/// check can provoke a measurement failure on purpose.
static MeasureFixture *newFixture(void)
{
    MeasureFixture *testCase = [[MeasureFixture alloc] initWithSelector:@selector(testNothing)];
    testCase.testRun = [XCTestCaseRun testRunWithTest:testCase];
    testCase.continueAfterFailure = YES;
    [testCase.testRun start];
    return testCase;
}

static NSUInteger issueCount(void)
{
    return collector.issues.count;
}

static NSString *lastIssueText(void)
{
    XCTIssue *issue = collector.issues.lastObject;
    return issue.detailedDescription ?: @"";
}

/// The first measurement of a test's first measure block. -firstObject and
/// -lastObject are not declared by the reduced SDK's NSArray, so the array is
/// indexed explicitly throughout this file rather than having Foundation's own
/// methods redeclared locally. The caller's own checks establish there is
/// something there to read.
static XCTPerformanceActivityRecord *firstRecord(MeasureFixture *testCase)
{
    return [testCase.xct_performanceRecords objectAtIndex:0];
}

/// The first record with the given name. With nesting, the inner measure call
/// finishes before the outer one, so the order records land in is not something
/// to assert on -- which record is which is found by name instead.
static XCTPerformanceActivityRecord *recordNamed(MeasureFixture *testCase, NSString *name)
{
    for (XCTPerformanceActivityRecord *record in testCase.xct_performanceRecords) {
        if ([record.name isEqualToString:name]) {
            return record;
        }
    }
    return nil;
}

static XCTPerformanceMeasurement *firstMeasurementOf(XCTPerformanceActivityRecord *record)
{
    XCTPerformanceMeasurement *measurement = [record.measurements objectAtIndex:0];
    return measurement;
}

static XCTPerformanceMeasurement *firstMeasurement(MeasureFixture *testCase)
{
    return firstMeasurementOf(firstRecord(testCase));
}

static XCTPerformanceMeasurement *measurementAt(XCTPerformanceActivityRecord *record, NSUInteger index)
{
    return [record.measurements objectAtIndex:index];
}

static void resetIssues(void)
{
    [collector.issues removeAllObjects];
}

#pragma mark - The value types

static void test_measurement_from_double_and_symbol(void)
{
    XCTPerformanceMeasurement *m = [[XCTPerformanceMeasurement alloc] initWithIdentifier:@"harness.a"
                                                                             displayName:@"A"
                                                                              doubleValue:1.5
                                                                              unitSymbol:@"ms"];
    ok("double+symbol keeps every field",
       [m.identifier isEqualToString:@"harness.a"] &&
       [m.displayName isEqualToString:@"A"] &&
       m.doubleValue == 1.5 &&
       [m.unitSymbol isEqualToString:@"ms"],
       [NSString stringWithFormat:@"%@ = %g %@", m.identifier, m.doubleValue, m.unitSymbol]);
    // Polarity is the one field whose zero value would silently rank results,
    // and the public initializer cannot know the direction, so it must stay
    // unspecified rather than defaulting to "smaller is better".
    ok("double+symbol leaves polarity unspecified",
       m.polarity == XCTPerformanceMeasurementPolarityUnspecified,
       [NSString stringWithFormat:@"polarity %ld", (long)m.polarity]);
    // There is no unit object behind a unit symbol. Reporting one would give the
    // caller a measurement that looked convertible and was not.
    ok("double+symbol has no unit object", m.value == nil,
       m.value ? @"value was not nil" : @"value is nil");
}

static void test_measurement_from_measurement(void)
{
    NSUnit *unit = [[NSUnit alloc] initWithSymbol:@"s"];
    NSMeasurement *value = [[NSMeasurement alloc] initWithDoubleValue:0.25 unit:unit];
    XCTPerformanceMeasurement *m = [[XCTPerformanceMeasurement alloc] initWithIdentifier:@"harness.b"
                                                                             displayName:@"B"
                                                                                  value:value];
    ok("NSMeasurement keeps value, unit and symbol",
       m.doubleValue == 0.25 &&
       [m.unitSymbol isEqualToString:@"s"] &&
       m.value != nil &&
       [m.value.unit.symbol isEqualToString:@"s"],
       [NSString stringWithFormat:@"%g %@, value %@", m.doubleValue, m.unitSymbol, m.value]);
    ok("NSMeasurement alone leaves polarity unspecified",
       m.polarity == XCTPerformanceMeasurementPolarityUnspecified, nil);
}

static void test_measurement_with_polarity(void)
{
    NSUnit *unit = [[NSUnit alloc] initWithSymbol:@"MB/s"];
    NSMeasurement *value = [[NSMeasurement alloc] initWithDoubleValue:1200 unit:unit];
    XCTPerformanceMeasurement *m =
        [[XCTPerformanceMeasurement alloc] initWithIdentifier:@"harness.c"
                                                  displayName:@"C"
                                                        value:value
                                                     polarity:XCTPerformanceMeasurementPolarityPrefersLarger];
    ok("polarity is kept with the value",
       m.polarity == XCTPerformanceMeasurementPolarityPrefersLarger && m.doubleValue == 1200,
       [NSString stringWithFormat:@"%g %@, polarity %ld", m.doubleValue, m.unitSymbol, (long)m.polarity]);
}

static void test_measurement_edge_values(void)
{
    XCTPerformanceMeasurement *zero = [[XCTPerformanceMeasurement alloc] initWithIdentifier:@"harness.z"
                                                                               displayName:@"Z"
                                                                                doubleValue:0
                                                                                unitSymbol:@"s"];
    XCTPerformanceMeasurement *negative = [[XCTPerformanceMeasurement alloc] initWithIdentifier:@"harness.n"
                                                                                   displayName:@"N"
                                                                                    doubleValue:-0.5
                                                                                    unitSymbol:@"s"];
    ok("zero and negative values are not normalized away",
       zero.doubleValue == 0 && negative.doubleValue == -0.5,
       [NSString stringWithFormat:@"%g and %g", zero.doubleValue, negative.doubleValue]);
}

static void test_timestamp(void)
{
    XCTPerformanceMeasurementTimestamp *first = [[XCTPerformanceMeasurementTimestamp alloc] init];
    usleep(2000);
    XCTPerformanceMeasurementTimestamp *second = [[XCTPerformanceMeasurementTimestamp alloc] init];
    ok("timestamps move forward and carry a date",
       second.absoluteTime > first.absoluteTime &&
       second.absoluteTimeNanoSeconds > first.absoluteTimeNanoSeconds &&
       first.date != nil && second.date != nil,
       [NSString stringWithFormat:@"+%llu ns",
          (unsigned long long)(second.absoluteTimeNanoSeconds - first.absoluteTimeNanoSeconds)]);
}

static void test_clock_metric_is_a_metric(void)
{
    XCTClockMetric *clock = [[XCTClockMetric alloc] init];
    ok("XCTClockMetric conforms to XCTMetric", [clock conformsToProtocol:@protocol(XCTMetric)], nil);
    id<XCTMetric> copy = [(id<XCTMetric>)clock copyWithZone:NULL];
    ok("XCTClockMetric can be copied, as the protocol requires", copy != nil, nil);
    ok("XCTClockMetric copy still reports",
       [[copy reportMeasurementsFromStartTime:[[XCTPerformanceMeasurementTimestamp alloc] init]
                                      toEndTime:[[XCTPerformanceMeasurementTimestamp alloc] init]
                                          error:NULL] count] == 1,
       nil);
}

static void test_clock_metric_polarity(void)
{
    // The one built-in metric that states a direction. Wall clock time is better
    // when smaller, and the report says so rather than leaving a baseline to
    // guess which way round the comparison goes.
    XCTPerformanceMeasurementTimestamp *start = [[XCTPerformanceMeasurementTimestamp alloc] init];
    usleep(3000);
    XCTPerformanceMeasurementTimestamp *end = [[XCTPerformanceMeasurementTimestamp alloc] init];
    NSError *error = nil;
    NSArray<XCTPerformanceMeasurement *> *reported = [[[XCTClockMetric alloc] init]
        reportMeasurementsFromStartTime:start
                              toEndTime:end
                                  error:&error];
    XCTPerformanceMeasurement *m = [reported objectAtIndex:0];
    ok("wall clock reports seconds, smaller-is-better",
       reported.count == 1 &&
       error == nil &&
       [m.identifier isEqualToString:XCTPerformanceMetric_WallClockTime] &&
       [m.unitSymbol isEqualToString:@"s"] &&
       m.polarity == XCTPerformanceMeasurementPolarityPrefersSmaller &&
       m.doubleValue > 0 && m.doubleValue < 5.0,
       [NSString stringWithFormat:@"%@ = %g %@, polarity %ld", m.identifier, m.doubleValue,
                                    m.unitSymbol, (long)m.polarity]);
}

static void test_clock_metric_rejects_impossible_intervals(void)
{
    XCTPerformanceMeasurementTimestamp *now = [[XCTPerformanceMeasurementTimestamp alloc] init];
    NSError *error = nil;
    // Both bounds are nonnull in the public header, so a literal nil is a
    // compile error. Handed over in a variable instead: the point is to reach the
    // runtime check, which a caller calling through a selector, or building with
    // a compiler that does not diagnose it, would still be able to trip.
    XCTPerformanceMeasurementTimestamp *noStart = nil;
    NSArray *reported = [[[XCTClockMetric alloc] init] reportMeasurementsFromStartTime:noStart
                                                                             toEndTime:now
                                                                                 error:&error];
    // A nil bound is a contract error, and reporting a zero duration instead
    // would be a plausible-looking number that means nothing.
    ok("clock metric fails rather than reporting a missing bound",
       reported == nil && error != nil,
       error.localizedDescription ?: @"no error was reported");
}

#pragma mark - The options

static void test_options_defaults(void)
{
    XCTMeasureOptions *options = [[XCTMeasureOptions alloc] init];
    ok("iterationCount defaults to 5", options.iterationCount == 5,
       [NSString stringWithFormat:@"%lu", (unsigned long)options.iterationCount]);
    ok("invocationOptions defaults to none",
       options.invocationOptions == XCTMeasurementInvocationNone,
       [NSString stringWithFormat:@"%lu", (unsigned long)options.invocationOptions]);
    XCTMeasureOptions *fromDefault = [XCTMeasureOptions defaultOptions];
    ok("+defaultOptions matches a fresh instance",
       fromDefault.iterationCount == options.iterationCount &&
       fromDefault.invocationOptions == options.invocationOptions, nil);
    options.iterationCount = 3;
    XCTMeasureOptions *other = [XCTMeasureOptions defaultOptions];
    ok("options are per-instance, not shared defaults",
       other.iterationCount == 5, [NSString stringWithFormat:@"%lu", (unsigned long)other.iterationCount]);
}

static void test_class_defaults(void)
{
    ok("+defaultPerformanceMetrics is wall clock time",
       [MeasureFixture.defaultPerformanceMetrics isEqualToArray:@[XCTPerformanceMetric_WallClockTime]],
       [NSString stringWithFormat:@"%lu metric(s)", (unsigned long)MeasureFixture.defaultPerformanceMetrics.count]);
    ok("+defaultMetrics is one clock metric",
       MeasureFixture.defaultMetrics.count == 1 &&
       [[MeasureFixture.defaultMetrics objectAtIndex:0] isKindOfClass:[XCTClockMetric class]], nil);
    ok("+defaultMeasureOptions has 5 iterations",
       MeasureFixture.defaultMeasureOptions.iterationCount == 5, nil);
}

#pragma mark - The measure loop

static void test_measure_block_runs_warmup_plus_iterations(void)
{
    MeasureFixture *testCase = newFixture();
    __block NSUInteger runs = 0;
    // The block has to take real time, and `runs++` does not: it is sometimes
    // one clock tick wide and sometimes none at all. A monotonic clock that has
    // not ticked reports a zero-length interval, so the "above zero" half of
    // the wall-clock assertion below was a race -- it passed about one run in
    // five against a Release xcodebuild of this framework, and passed every time
    // against a Debug make build, which is a difference in the block, not in the
    // metric. 2ms is about four orders of magnitude above the resolution that
    // produced the zeros and four below the 5s upper bound, so the number is
    // reliably positive without the check turning into a test of how fast the
    // machine is.
    [testCase measureBlock:^{ runs++; usleep(2000); }];

    ok("measureBlock: runs 5 measured iterations plus 1 warm-up", runs == 6,
       [NSString stringWithFormat:@"%lu runs", (unsigned long)runs]);

    XCTPerformanceActivityRecord *record = firstRecord(testCase);
    ok("one record, five iterations, five measurements",
       testCase.xct_performanceRecords.count == 1 &&
       record.iterationCount == 5 &&
       record.measurements.count == 5,
       [NSString stringWithFormat:@"%lu records, %lu iterations, %lu measurements",
                                    (unsigned long)testCase.xct_performanceRecords.count,
                                    (unsigned long)record.iterationCount,
                                    (unsigned long)record.measurements.count]);
    ok("the discarded warm-up reports nothing", issueCount() == 0, nil);

    XCTPerformanceMeasurement *m = firstMeasurement(testCase);
    ok("measureBlock: records wall clock seconds",
       [m.identifier isEqualToString:XCTPerformanceMetric_WallClockTime] &&
       [m.unitSymbol isEqualToString:@"s"] &&
       m.doubleValue > 0 && m.doubleValue < 5.0,
       [NSString stringWithFormat:@"%g %@", m.doubleValue, m.unitSymbol]);
}

static void test_each_iteration_is_a_fresh_metric(void)
{
    MeasureFixture *testCase = newFixture();
    [CountingMetric reset];
    CountingMetric *metric = [[CountingMetric alloc] init];
    metric.identifier = 1;
    [testCase measureWithMetrics:@[metric] block:^{}];

    // One copy per run, warm-up included, because the warm-up is a full dry run:
    // five measured iterations plus the one run whose results are thrown away. A
    // fresh copy each time is the point -- the same instance reporting twice
    // would report its running total twice. Only the reports are dropped: the
    // fixture counts the copies, and the record below holds five measurements,
    // so the warm-up's copy was made and then discarded.
    ok("one metric copy per run, warm-up included",
       CountingMetric.copiesMade == 6, [NSString stringWithFormat:@"%lu copies",
                                                  (unsigned long)CountingMetric.copiesMade]);
    ok("willBeginMeasuring is called once per run",
       CountingMetric.willBeginCalls == 6, [NSString stringWithFormat:@"%lu calls",
                                                        (unsigned long)CountingMetric.willBeginCalls]);
    ok("didStopMeasuring is called once per run",
       CountingMetric.didStopCalls == 6, [NSString stringWithFormat:@"%lu calls",
                                                      (unsigned long)CountingMetric.didStopCalls]);
    ok("the warm-up's copy reports nothing",
       firstRecord(testCase).measurements.count == 5, [NSString stringWithFormat:@"%lu measurements",
                                                                     (unsigned long)firstRecord(testCase).measurements.count]);
    ok("a client metric's measurements are recorded",
       firstRecord(testCase).measurements.count == 5 &&
       [firstMeasurement(testCase).identifier isEqualToString:@"harness.counter"], nil);
}

static void test_several_metrics(void)
{
    MeasureFixture *testCase = newFixture();
    XCTMeasureOptions *options = [[XCTMeasureOptions alloc] init];
    options.iterationCount = 2;
    CountingMetric *first = [[CountingMetric alloc] init];
    first.identifier = 1;
    CountingMetric *second = [[CountingMetric alloc] init];
    second.identifier = 2;
    __block NSUInteger runs = 0;
    [testCase measureWithMetrics:@[first, second] options:options block:^{ runs++; }];

    XCTPerformanceActivityRecord *record = firstRecord(testCase);
    ok("two metrics over two iterations give four measurements",
       runs == 3 && record.iterationCount == 2 && record.measurements.count == 4,
       [NSString stringWithFormat:@"%lu runs, %lu measurements", (unsigned long)runs,
                                    (unsigned long)record.measurements.count]);
    // Per iteration the order is the order the metrics were given in, which is
    // what lets a caller line a report up with its own list.
    ok("measurements keep the order the metrics were given in",
       [measurementAt(record, 0).identifier isEqualToString:@"harness.counter"] &&
       measurementAt(record, 0).doubleValue == 1 &&
       measurementAt(record, record.measurements.count - 1).doubleValue == 2,
       [NSString stringWithFormat:@"first %g, last %g", measurementAt(record, 0).doubleValue,
                                    measurementAt(record, record.measurements.count - 1).doubleValue]);
}

static void test_iteration_count_is_honoured(void)
{
    MeasureFixture *testCase = newFixture();
    XCTMeasureOptions *options = [[XCTMeasureOptions alloc] init];
    options.iterationCount = 1;
    __block NSUInteger runs = 0;
    [testCase measureWithOptions:options block:^{ runs++; }];
    ok("iterationCount 1 runs the block twice, warm-up included",
       runs == 2 && firstRecord(testCase).measurements.count == 1,
       [NSString stringWithFormat:@"%lu runs", (unsigned long)runs]);
}

static void test_records_accumulate_in_order(void)
{
    MeasureFixture *testCase = newFixture();
    [testCase measureBlock:^{}];
    [testCase measureWithMetrics:@[[[XCTClockMetric alloc] init]] block:^{}];
    [testCase measureMetrics:@[XCTPerformanceMetric_WallClockTime]
        automaticallyStartMeasuring:YES
                         forBlock:^{}];

    NSArray<XCTPerformanceActivityRecord *> *records = testCase.xct_performanceRecords;
    // Bound to typed locals because the reduced SDK's NSArray is ungenerified, so
    // -objectAtIndex: comes back as id and has no properties of its own.
    XCTPerformanceActivityRecord *first = [records objectAtIndex:0];
    XCTPerformanceActivityRecord *second = [records objectAtIndex:1];
    XCTPerformanceActivityRecord *third = [records objectAtIndex:2];
    ok("every measure block in the test keeps its own record",
       records.count == 3 &&
       [first.name isEqualToString:@"measureBlock"] &&
       [second.name isEqualToString:@"measureWithMetrics"] &&
       [third.name isEqualToString:@"measureMetrics"],
       [NSString stringWithFormat:@"%lu records", (unsigned long)records.count]);
}

#pragma mark - Manual bounds

static void test_manual_start_and_stop(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    XCTMeasureOptions *options = [[XCTMeasureOptions alloc] init];
    options.invocationOptions = XCTMeasurementInvocationManuallyStart | XCTMeasurementInvocationManuallyStop;
    __block NSUInteger runs = 0;
    [testCase measureWithOptions:options block:^{
        runs++;
        [testCase startMeasuring];
        usleep(2000);
        [testCase stopMeasuring];
        // The sleep below is inside the block but outside the measured region.
        // If the manual bounds were ignored, this would be in the number.
        usleep(20000);
    }];

    double measured = firstMeasurement(testCase).doubleValue;
    // The block sleeps about 22ms per iteration; the measured region is about
    // 2ms of it. The threshold sits between the two with room on both sides, so
    // this is not a race -- if the bounds were ignored the number would be an
    // order of magnitude too large to land under it by accident.
    ok("manual bounds measure only the marked region",
       runs == 6 && issueCount() == 0 && measured > 0 && measured < 0.010,
       [NSString stringWithFormat:@"%lu runs, %lu issues, measured %g s of ~0.022 s per run",
                                   (unsigned long)runs, (unsigned long)issueCount(), measured]);
}

static void test_missing_manual_start_is_a_failure(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    XCTMeasureOptions *options = [[XCTMeasureOptions alloc] init];
    options.invocationOptions = XCTMeasurementInvocationManuallyStart;
    [testCase measureWithOptions:options block:^{}];

    XCTPerformanceActivityRecord *record = firstRecord(testCase);
    // A block told to mark its own start and not doing so cannot be measured.
    // Reporting an interval of zero instead would be a plausible number meaning
    // nothing, so this is a failure and the iteration reports nothing.
    ok("a missing manual start fails the test",
       issueCount() == 5 && [lastIssueText() containsString:@"-startMeasuring"],
       [NSString stringWithFormat:@"%lu issues: %@", (unsigned long)issueCount(), lastIssueText()]);
    ok("an unmeasurable iteration reports no measurement",
       record.measurements.count == 0 && record.iterationCount == 5,
       [NSString stringWithFormat:@"%lu measurements", (unsigned long)record.measurements.count]);
}

static void test_double_stop_is_a_failure(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    XCTMeasureOptions *options = [[XCTMeasureOptions alloc] init];
    options.invocationOptions = XCTMeasurementInvocationManuallyStart;
    [testCase measureWithOptions:options block:^{
        [testCase startMeasuring];
        [testCase stopMeasuring];
        [testCase stopMeasuring];
    }];
    ok("a second -stopMeasuring fails rather than extending the region",
       issueCount() == 5 && [lastIssueText() containsString:@"more than once"],
       [NSString stringWithFormat:@"%lu issues: %@", (unsigned long)issueCount(), lastIssueText()]);
}

static void test_nested_measure_blocks(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    __block NSUInteger innerRuns = 0;
    XCTMeasureOptions *manual = [[XCTMeasureOptions alloc] init];
    manual.invocationOptions = XCTMeasurementInvocationManuallyStart | XCTMeasurementInvocationManuallyStop;
    manual.iterationCount = 1;

    // The inner block marks its own bounds inside the outer block's, so if the
    // inner run cleared the outer invocation instead of putting it back, the
    // outer's own -stopMeasuring would have nothing to stop and the outer
    // iteration would go unmeasured.
    [testCase measureWithOptions:manual block:^{
        [testCase startMeasuring];
        usleep(1000);
        [testCase measureWithMetrics:@[[[XCTClockMetric alloc] init]] block:^{
            innerRuns++;
        }];
        usleep(1000);
        [testCase stopMeasuring];
    }];

    // The outer asks for one iteration, so it runs twice; the nested call uses the
    // default of five, so it runs six times each time, giving 12 inner runs. The
    // nested call made during the outer's warm-up is warm-up work itself and
    // leaves no record, which is what holds the record count at two.
    XCTPerformanceActivityRecord *outer = recordNamed(testCase, @"measureWithOptions");
    XCTPerformanceActivityRecord *inner = recordNamed(testCase, @"measureWithMetrics");
    ok("a measure block nested in a measure block measures both",
       issueCount() == 0 && innerRuns == 12 && testCase.xct_performanceRecords.count == 2 &&
       outer != nil && outer.measurements.count == 1 && inner != nil && inner.measurements.count == 5,
       [NSString stringWithFormat:@"%lu issues, %lu inner runs, %lu records, %lu outer and %lu inner measurements",
                                   (unsigned long)issueCount(), (unsigned long)innerRuns,
                                   (unsigned long)testCase.xct_performanceRecords.count,
                                   (unsigned long)outer.measurements.count, (unsigned long)inner.measurements.count]);
    // The outer region contains both 1ms sleeps and the whole nested measure call,
    // so it has to be the longer of the two. If the inner run had replaced the
    // outer invocation instead of stacking on it, the outer's own -stopMeasuring
    // would have had nothing to stop and this would collapse to a failure.
    ok("the outer region still spans the nested one",
       outer != nil && inner != nil && [outer.measurements objectAtIndex:0] != nil &&
       firstMeasurementOf(outer).doubleValue > firstMeasurementOf(inner).doubleValue,
       nil);
}

static void test_start_measuring_outside_a_block(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    [testCase startMeasuring];
    ok("-startMeasuring outside a measure block is a failure",
       issueCount() == 1 && [lastIssueText() containsString:@"-startMeasuring was called outside a measure block"],
       [NSString stringWithFormat:@"%lu issues: %@", (unsigned long)issueCount(), lastIssueText()]);
    ok("nothing is recorded for a block that never ran",
       testCase.xct_performanceRecords.count == 0, nil);
}

static void test_stop_measuring_outside_a_block(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    [testCase stopMeasuring];
    ok("-stopMeasuring outside a measure block is a failure",
       issueCount() == 1 && [lastIssueText() containsString:@"-stopMeasuring was called outside a measure block"],
       [NSString stringWithFormat:@"%lu issues: %@", (unsigned long)issueCount(), lastIssueText()]);
}

static void test_manual_start_on_an_automatic_block(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    // The default options start the measurement for the caller, so a manual start
    // here would silently discard everything before it. Reported, because the
    // numbers would otherwise be quietly wrong.
    [testCase measureBlock:^{
        [testCase startMeasuring];
    }];
    ok("a manual start on an automatically measured block is reported",
       issueCount() == 5 && [lastIssueText() containsString:@"already being measured"],
       [NSString stringWithFormat:@"%lu issues: %@", (unsigned long)issueCount(), lastIssueText()]);
}

static void test_measure_metrics_without_automatic_start(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    __block NSUInteger runs = 0;
    // The string API's NO has to reach the same manual-start contract the
    // options object expresses, or a caller using the old API cannot mark its
    // own bounds at all.
    [testCase measureMetrics:@[XCTPerformanceMetric_WallClockTime]
        automaticallyStartMeasuring:NO
                         forBlock:^{
        runs++;
        [testCase startMeasuring];
    }];
    XCTPerformanceActivityRecord *record = firstRecord(testCase);
    ok("automaticallyStartMeasuring:NO asks the block to mark its start",
       runs == 6 && issueCount() == 0 && record.measurements.count == 5,
       [NSString stringWithFormat:@"%lu runs, %lu issues, %lu measurements", (unsigned long)runs,
                                    (unsigned long)issueCount(), (unsigned long)record.measurements.count]);
}

#pragma mark - Rejected requests

static void test_unknown_metric_name(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    __block NSUInteger runs = 0;
    [testCase measureMetrics:@[XCTPerformanceMetric_WallClockTime, @"com.example.Nonsense"]
        automaticallyStartMeasuring:YES
                         forBlock:^{ runs++; }];
    // The block never runs: half a measure block is not a measurement, and
    // reporting the recognized metric alone would hide the typo.
    ok("an unknown metric name fails the test before measuring",
       runs == 0 && issueCount() == 1 &&
       [lastIssueText() containsString:@"com.example.Nonsense"] &&
       testCase.xct_performanceRecords.count == 0,
       [NSString stringWithFormat:@"%lu runs, %lu issues", (unsigned long)runs,
                                    (unsigned long)issueCount()]);
}

static void test_no_metrics(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    __block NSUInteger runs = 0;
    [testCase measureWithMetrics:@[] block:^{ runs++; }];
    ok("measuring nothing is refused rather than reported as fast",
       runs == 0 && issueCount() == 1 && [lastIssueText() containsString:@"no metrics"],
       [NSString stringWithFormat:@"%lu runs, %lu issues", (unsigned long)runs,
                                    (unsigned long)issueCount()]);
}

static void test_nil_block(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    // A block is nonnull too, so it arrives through a variable for the same
    // reason as the missing timestamp above.
    void (^noBlock)(void) = nil;
    [testCase measureWithMetrics:@[[[XCTClockMetric alloc] init]] block:noBlock];
    ok("a nil block is refused with a reason",
       issueCount() == 1 && [lastIssueText() containsString:@"nil block"],
       lastIssueText());
}

static void test_metric_error_becomes_a_test_failure(void)
{
    MeasureFixture *testCase = newFixture();
    resetIssues();
    [testCase measureWithMetrics:@[[[FailingMetric alloc] init]] block:^{}];

    XCTPerformanceActivityRecord *record = firstRecord(testCase);
    // The metric's own reason is carried into the failure, because "the metric
    // failed" without saying which metric or why is not something a test author
    // can act on.
    ok("a metric that cannot measure fails the test",
       issueCount() == 5 && [lastIssueText() containsString:@"this metric cannot measure"],
       [NSString stringWithFormat:@"%lu issues: %@", (unsigned long)issueCount(), lastIssueText()]);
    ok("a failed metric reports no measurement in place of a zero",
       record.measurements.count == 0, [NSString stringWithFormat:@"%lu measurements",
                                                        (unsigned long)record.measurements.count]);
}

#pragma mark - Entry point

int main(void)
{
    collector = [[IssueCollector alloc] init];
    XCTestObservationCenter *center = [XCTestObservationCenter sharedTestObservationCenter];
    [center addTestObserver:collector];

    printf("Performance measurement\n");
    printf("  Value types\n");
    test_measurement_from_double_and_symbol();
    test_measurement_from_measurement();
    test_measurement_with_polarity();
    test_measurement_edge_values();
    test_timestamp();
    test_clock_metric_is_a_metric();
    test_clock_metric_polarity();
    test_clock_metric_rejects_impossible_intervals();

    printf("  Defaults\n");
    test_options_defaults();
    test_class_defaults();

    printf("  The measure loop\n");
    test_measure_block_runs_warmup_plus_iterations();
    test_each_iteration_is_a_fresh_metric();
    test_several_metrics();
    test_iteration_count_is_honoured();
    test_records_accumulate_in_order();

    printf("  Manual bounds\n");
    test_manual_start_and_stop();
    test_missing_manual_start_is_a_failure();
    test_double_stop_is_a_failure();
    test_nested_measure_blocks();
    test_start_measuring_outside_a_block();
    test_stop_measuring_outside_a_block();
    test_manual_start_on_an_automatic_block();
    test_measure_metrics_without_automatic_start();

    printf("  Rejected requests\n");
    test_unknown_metric_name();
    test_no_metrics();
    test_nil_block();
    test_metric_error_becomes_a_test_failure();

    [center removeTestObserver:collector];

    if (failures == 0) {
        printf("ALL PASS (0 failures)\n");
        return 0;
    }
    printf("%d FAILURES\n", failures);
    return 1;
}
