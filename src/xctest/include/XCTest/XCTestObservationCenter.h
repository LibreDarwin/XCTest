// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Process-wide registry of XCTestObservation observers.

#ifndef XCTEST_XCTESTOBSERVATIONCENTER_H
#define XCTEST_XCTESTOBSERVATIONCENTER_H

#import <XCTest/XCTestDefines.h>
#import <XCTest/XCTestObservation.h>

XCT_HEADER_AUDIT_BEGIN

@interface XCTestObservationCenter : NSObject

@property (class, readonly) XCTestObservationCenter *sharedTestObservationCenter;

- (void)addTestObserver:(id<XCTestObservation>)testObserver;
- (void)removeTestObserver:(id<XCTestObservation>)testObserver;

@end

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTOBSERVATIONCENTER_H */
