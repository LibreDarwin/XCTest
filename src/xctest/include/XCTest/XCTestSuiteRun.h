// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Run record for an XCTestSuite; aggregates its children's runs.

#ifndef XCTEST_XCTESTSUITERUN_H
#define XCTEST_XCTESTSUITERUN_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestRun.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTestSuiteRun : XCTestRun

/// Runs of the tests directly contained by this suite, in execution order.
@property (readonly, copy) NSArray<XCTestRun *> *testRuns;

- (void)addTestRun:(XCTestRun *)testRun;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTSUITERUN_H */
