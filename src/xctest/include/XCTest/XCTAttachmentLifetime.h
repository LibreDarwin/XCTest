// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Enumerations shared by XCTAttachment and XCTestCase.

#ifndef XCTEST_XCTATTACHMENTLIFETIME_H
#define XCTEST_XCTATTACHMENTLIFETIME_H

#import <XCTest/XCTestDefines.h>

XCT_HEADER_AUDIT_BEGIN

/// How long the system-under-test keeps an attachment.
typedef NS_ENUM(NSInteger, XCTAttachmentLifetime) {
    /// Delete as soon as the run finishes; the default.
    XCTAttachmentLifetimeDeleteOnSuccess = 0,
    /// Keep the attachment even when the test passes.
    XCTAttachmentLifetimeKeepAlways = 1,
} NS_SWIFT_NAME(XCTAttachment.Lifetime);

XCT_HEADER_AUDIT_END

#endif /* XCTEST_XCTATTACHMENTLIFETIME_H */
