// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// XCTKVOExpectation, an expectation satisfied by a key-value change.

#import <XCTest/XCTKVOExpectation.h>

#import "XCTestFoundationCompat.h"

@implementation XCTKVOExpectation {
    NSString *_keyPath;
    id _observedObject;
    id _expectedValue;
    NSKeyValueObservingOptions _options;
    XCKeyValueObservingExpectationHandler _handler;

    // Guards the handler, which Foundation calls on whichever thread mutated the
    // object while a test may install one from another.
    NSLock *_lock;
    BOOL _observing;
}

- (instancetype)initWithKeyPath:(NSString *)keyPath
                         object:(id)object
                  expectedValue:(id)expectedValue
                       options:(NSKeyValueObservingOptions)options
{
    self = [super initWithDescription:[NSString stringWithFormat:@"KVO %@ on %@ == %@",
                                                                 keyPath,
                                                                 [object class],
                                                                 expectedValue]];
    if (self != nil) {
        _keyPath = [keyPath copy];
        // Held strongly, matching KVO's own requirement: an observed object
        // must outlive its observation or the change callback dereferences
        // freed memory.
        _observedObject = object;
        _expectedValue = expectedValue;
        _options = options;
        _lock = [NSLock new];
        [self _beginObserving];
    }
    return self;
}

- (instancetype)initWithKeyPath:(NSString *)keyPath object:(id)object expectedValue:(id)expectedValue
{
    // Initial so the value that is already there can satisfy the wait, which is
    // what makes this usable for a change that happened before the wait began.
    return [self initWithKeyPath:keyPath
                          object:object
                   expectedValue:expectedValue
                        options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                 | NSKeyValueObservingOptionOld];
}

- (instancetype)initWithKeyPath:(NSString *)keyPath object:(id)object
{
    // New and Old but deliberately not Initial. An Initial callback fires while
    // this initializer is still running, before the caller has a reference to
    // the expectation, so "any change" would be satisfied by the value that was
    // already there and the wait would pass without observing anything -- the
    // opposite of what this initializer promises. Routing through the
    // expected-value convenience initializer used to add Initial anyway, which
    // is the bug the missing option here exists to prevent.
    return [self initWithKeyPath:keyPath
                          object:object
                   expectedValue:nil
                        options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld];
}

- (void)dealloc
{
    // KVO holds an unretained reference to its observers and raises on a change
    // if the observer has gone away, so deregistering is mandatory.
    [self _endObserving];
}

#pragma mark - Observation

- (void)_beginObserving
{
    [_observedObject addObserver:self
                      forKeyPath:_keyPath
                         options:_options
                         context:(__bridge void *)self];
    _observing = YES;
}

- (void)_endObserving
{
    if (!_observing) {
        return;
    }
    _observing = NO;
    // A nil context removes the one observation registered by _beginObserving.
    // Passing a different context here would leave the observation in place, and
    // the next change would raise for an unregistered observer.
    [_observedObject removeObserver:self forKeyPath:_keyPath context:(__bridge void *)self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if (context != (__bridge void *)self) {
        // Another registration on this object shares our key path. Not an
        // error, but not ours to act on either.
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    XCKeyValueObservingExpectationHandler handler = self.handler;
    if (handler != nil) {
        if (handler(object, change)) {
            [self fulfill];
        }
        return;
    }

    // The changed value, not the whole dictionary: an expectation is about the
    // value at the key path having become a particular thing.
    id value = change[NSKeyValueChangeNewKey];
    if (_expectedValue == nil) {
        [self fulfill];
        return;
    }
    if ([value isEqual:_expectedValue]) {
        [self fulfill];
    }
}

#pragma mark - Configuration

- (NSString *)keyPath
{
    return _keyPath;
}

- (id)observedObject
{
    return _observedObject;
}

- (id)expectedValue
{
    return _expectedValue;
}

- (NSKeyValueObservingOptions)options
{
    return _options;
}

- (XCKeyValueObservingExpectationHandler)handler
{
    [_lock lock];
    XCKeyValueObservingExpectationHandler handler = _handler;
    [_lock unlock];
    return handler;
}

- (void)setHandler:(XCKeyValueObservingExpectationHandler)handler
{
    [_lock lock];
    _handler = [handler copy];
    [_lock unlock];
}

@end
