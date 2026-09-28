// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Error domain and codes reported by the XCTest API.

#ifndef XCTEST_XCTESTERRORS_H
#define XCTEST_XCTESTERRORS_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

/// The error domain for NSError values produced by XCTest. The string value
/// must be "XCTest", because serialized results and logs are compared against
/// tool output produced by the shipping implementation.
XCT_EXPORT NSErrorDomain const XCTestErrorDomain;

/// Error codes paired with XCTestErrorDomain.
typedef NS_ENUM(NSInteger, XCTestErrorCode) {
    /// A wait finished at or after its deadline without every expectation
    /// being fulfilled.
    XCTestErrorCodeTimeoutWhileWaiting,
    /// A wait observed an expectation that had already failed, or a nested
    /// wait that could not complete.
    XCTestErrorCodeFailureWhileWaiting,
};

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTESTERRORS_H */
