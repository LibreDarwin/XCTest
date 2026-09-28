// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// A collection of tests, run as a unit.

#ifndef XCTEST_XCTESTSUITE_H
#define XCTEST_XCTESTSUITE_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCAbstractTest.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTestSuite : XCTest

/// A suite of suites, one per XCTestCase subclass found in the runtime, each
/// populated with that class's discovered tests.
@property (class, readonly) XCTestSuite *defaultTestSuite;
+ (instancetype)defaultTestSuite;

/// Scans a bundle for XCTestCase subclasses and builds the equivalent suite.
+ (instancetype)testSuiteForBundlePath:(NSString *)bundlePath;

/// A suite wrapping every test discovered on the named XCTestCase subclass.
+ (instancetype)testSuiteForTestCaseWithName:(NSString *)name;

/// As above, but taking the class directly.
+ (instancetype)testSuiteForTestCaseClass:(Class)testCaseClass;

+ (instancetype)testSuiteWithName:(NSString *)name;
- (instancetype)initWithName:(NSString *)name NS_DESIGNATED_INITIALIZER;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

- (void)addTest:(XCTest *)test;

/// The tests directly contained by this suite, in execution order.
@property (readonly, copy) NSArray<__kindof XCTest *> *tests;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTSUITE_H */
