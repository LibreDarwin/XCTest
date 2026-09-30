// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTDarwinNotificationExpectation, an expectation satisfied by a Darwin
// notification.

#import <XCTest/XCTDarwinNotificationExpectation.h>
#import <XCTest/XCTIssue.h>
#import <XCTest/XCTestCase.h>

#import "XCTestExpectationInternal.h"
#import "XCTestFoundationCompat.h"
#import "XCTestInternal.h"

@implementation XCTDarwinNotificationExpectation {
    NSString *_notificationName;
    XCTDarwinNotificationExpectationHandler _handler;

    // Guards the handler, which notify(3) calls on its queue while a test may
    // install one from another.
    NSLock *_lock;
    dispatch_queue_t _queue;
    int _token;
    BOOL _registered;
}

- (instancetype)initWithNotificationName:(NSString *)notificationName
{
    self = [super initWithDescription:[NSString stringWithFormat:@"Darwin notification %@", notificationName]];
    if (self != nil) {
        _notificationName = [notificationName copy];
        _lock = [NSLock new];
        // A serial queue of the expectation's own, so its handler is never
        // entered concurrently with itself. A global queue would allow two
        // posted notifications to run the handler at once and race on the
        // handler property.
        _queue = dispatch_queue_create("org.libre.xct.darwin-notification", DISPATCH_QUEUE_SERIAL);
        [self _beginObserving];
    }
    return self;
}

- (void)dealloc
{
    // -_endObserving cancels the registration, which is what stops notify(3)
    // from calling into a freed expectation. Dispatch keeps its own reference to
    // the queue, so releasing it here is safe.
    [self _endObserving];
}

#pragma mark - Observation

- (void)_beginObserving
{
    __weak __typeof(self) weakSelf = self;
    int token = 0;
    uint32_t status = notify_register_dispatch(_notificationName.UTF8String,
                                               &token,
                                               _queue,
                                               ^(int deliveredToken) {
                                                   [weakSelf _xct_darwinNotificationPosted:deliveredToken];
                                               });
    if (status != NOTIFY_STATUS_OK) {
        // A registration can be refused, for instance when the name is one
        // notify(3) reserves. Reporting here rather than waiting silently is the
        // difference between a test that fails with a reason and one that fails
        // by timing out with no explanation.
        NSString *message = [NSString stringWithFormat:@"Could not observe Darwin notification %@ (status %u)",
                                                       _notificationName,
                                                       status];
        XCTestCase *testCase = [self _xct_issueReportingTestCase];
        [testCase _xct_recordIssueWithoutUnwinding:[[XCTIssue alloc]
                                                      initWithType:XCTIssueTypeTestFailure
                                             compactDescription:message
                                                        severity:XCTIssueSeverityError]];
        return;
    }
    _token = token;
    _registered = YES;
}

- (void)_endObserving
{
    if (!_registered) {
        return;
    }
    _registered = NO;
    notify_cancel(_token);
}

// The block's argument is the registration token, not a status, and that
// distinction is the whole reason this method has nothing to branch on.
// notify_register_dispatch passes the token so the callee can set the
// notification's state or cancel the registration; a delivery of token 7
// arrives as 7, and tokens are documented as zero or positive, so no value of
// the argument means failure. Comparing it against NOTIFY_STATUS_OK -- which
// reads naturally enough to be tempting -- drops every delivery carrying a
// nonzero token and leaves the expectation to time out with nothing to show
// for it. A registration that has been cancelled stops calling back on its
// own, which is what -_endObserving relies on instead.
- (void)_xct_darwinNotificationPosted:(int)deliveredToken
{
    (void)deliveredToken;

    XCTDarwinNotificationExpectationHandler handler = self.handler;
    if (handler != nil) {
        if (!handler()) {
            return;
        }
    }
    [self fulfill];
}

#pragma mark - Configuration

- (NSString *)notificationName
{
    return _notificationName;
}

- (XCTDarwinNotificationExpectationHandler)handler
{
    [_lock lock];
    XCTDarwinNotificationExpectationHandler handler = _handler;
    [_lock unlock];
    return handler;
}

- (void)setHandler:(XCTDarwinNotificationExpectationHandler)handler
{
    [_lock lock];
    _handler = [handler copy];
    [_lock unlock];
}

@end
