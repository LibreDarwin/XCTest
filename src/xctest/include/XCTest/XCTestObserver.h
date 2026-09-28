// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Deprecated observer base class, superseded by XCTestObservation.
// Retained because existing test bundles subclass it.

#ifndef XCTEST_XCTESTOBSERVER_H
#define XCTEST_XCTESTOBSERVER_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

@class XCTestRun;

@interface XCTestObserver : NSObject

- (void)startObserving;
- (void)stopObserving;

- (void)testSuiteDidStart:(XCTestRun *)testRun;
- (void)testSuiteDidStop:(XCTestRun *)testRun;
- (void)testCaseDidStart:(XCTestRun *)testRun;
- (void)testCaseDidStop:(XCTestRun *)testRun;
- (void)testCaseDidFail:(XCTestRun *)testRun
        withDescription:(NSString *)description
                   inFile:(NSString *)filePath
                   atLine:(NSUInteger)lineNumber;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTOBSERVER_H */
