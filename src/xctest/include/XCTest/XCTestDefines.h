// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Shared macros and availability shims for the XCTest API.
//
// This is an independent reimplementation of the XCTest public interface.
// It is written to be source- and (where noted) ABI-compatible with the
// interface Apple publishes, so that code written against Apple's XCTest
// compiles and links against this framework unchanged.

#ifndef XCTEST_XCTESTDEFINES_H
#define XCTEST_XCTESTDEFINES_H

#import <Foundation/Foundation.h>

#if defined(__cplusplus)
    #define XCT_EXPORT extern "C"
#else
    #define XCT_EXPORT extern
#endif

/// UI testing (XCUIAutomation) is not implemented in this phase. The macro is
/// defined unconditionally rather than 0 so that conditional code in client
/// test bundles still parses; see XCTest.h for what is actually omitted.
#ifndef XCT_UI_TESTING_AVAILABLE
#define XCT_UI_TESTING_AVAILABLE 0
#endif

#if defined(__has_attribute)
#if __has_attribute(warn_unused_result)
#define XCT_WARN_UNUSED __attribute__((__warn_unused_result__))
#endif
#if __has_attribute(noescape)
#define XCT_NOESCAPE __attribute__((noescape))
#endif
#if __has_attribute(swift_attr)
#define XCT_SWIFT_MAIN_ACTOR __attribute__((swift_attr("@MainActor")))
#define XCT_SWIFT_UNAVAILABLE_FROM_ASYNC(msg) \
    __attribute__((swift_attr("@_unavailableFromAsync(message: \"" msg "\")")))
#endif
#endif

#if __has_attribute(weak_import)
#define XCT_WEAK_EXPORT __attribute__((weak_import)) XCT_EXPORT
#else
#define XCT_WEAK_EXPORT XCT_EXPORT
#endif

#ifndef XCT_WARN_UNUSED
#define XCT_WARN_UNUSED
#endif
#ifndef XCT_NOESCAPE
#define XCT_NOESCAPE
#endif
#ifndef XCT_SWIFT_MAIN_ACTOR
#define XCT_SWIFT_MAIN_ACTOR
#endif
#ifndef XCT_SWIFT_UNAVAILABLE_FROM_ASYNC
#define XCT_SWIFT_UNAVAILABLE_FROM_ASYNC(msg)
#endif

// Marks a block or parameter as safe to hand across a concurrency domain. Purely
// a Swift-import hint with no effect on the Objective-C compiler, so it expands
// to nothing when swift_attr is unavailable.
#ifndef XCT_SWIFT_SENDABLE
    #if defined(__has_attribute) && __has_attribute(swift_attr)
        #define XCT_SWIFT_SENDABLE __attribute__((swift_attr("@Sendable")))
    #else
        #define XCT_SWIFT_SENDABLE
    #endif
#endif

// A deprecation that also names a Swift replacement, so Swift clients get a
// fix-it rather than only a warning. Swift-only like XCT_SWIFT_SENDABLE.
#ifndef XCT_TO_BE_DEPRECATED_WITH_SWIFT_REPLACEMENT
    #if defined(__has_attribute) && __has_attribute(swift_attr)
        #define XCT_TO_BE_DEPRECATED_WITH_SWIFT_REPLACEMENT(REPLACEMENT) \
            __attribute__((deprecated("Replaced by '" REPLACEMENT "'"))) \
            __attribute__((swift_attr("@_deprecated(replacedBy: \"" REPLACEMENT "\")")))
    #else
        #define XCT_TO_BE_DEPRECATED_WITH_SWIFT_REPLACEMENT(REPLACEMENT) \
            __attribute__((deprecated("Replaced by '" REPLACEMENT "'")))
    #endif
#endif

// Performance measurement was introduced in Xcode 11, so Apple's metric API is
// gated on iOS 13 / tvOS 13 / watchOS 7. This framework has no non-macOS
// deployment targets, so the gate is vacuous here and expands to nothing; the
// macro exists so client code that spells it out keeps compiling.
#ifndef XCT_METRIC_API_AVAILABLE
#define XCT_METRIC_API_AVAILABLE
#endif

#define XCT_UNAVAILABLE(msg) __attribute__((unavailable(msg)))
#define XCT_DEPRECATED_WITH_REPLACEMENT(REPLACEMENT) \
    __attribute__((deprecated("Replaced by '" REPLACEMENT "'")))
#define XCT_DEPRECATED_WITH_DIRECT_REPLACEMENT(REPLACEMENT) \
    __attribute__((deprecated("Replaced by '" REPLACEMENT "'", REPLACEMENT)))

#pragma mark - Header audit

// Apple's headers wrap their bodies in the NS_ASSUME_NONNULL region that
// NS_HEADER_AUDIT_BEGIN/END define, and open a "header audit" region that
// Foundation's nullability audit tooling recognises. Reproduced so the same
// client code keeps compiling without warnings.
#ifndef XCT_HEADER_AUDIT_BEGIN
    // Deliberately aliases NS_ASSUME_NONNULL_*, not NS_HEADER_AUDIT_*.
    // Foundation defines NS_HEADER_AUDIT_BEGIN as a variadic function-like
    // macro ("#define NS_HEADER_AUDIT_BEGIN(...) ..."), so referencing it
    // without parentheses leaves a bare identifier that the parser rejects as
    // an unknown type name.
    #if defined(NS_ASSUME_NONNULL_BEGIN)
        #define XCT_HEADER_AUDIT_BEGIN NS_ASSUME_NONNULL_BEGIN
        #define XCT_HEADER_AUDIT_END NS_ASSUME_NONNULL_END
    #else
        #define XCT_HEADER_AUDIT_BEGIN _Pragma("clang assume_nonnull begin")
        #define XCT_HEADER_AUDIT_END _Pragma("clang assume_nonnull end")
    #endif
#endif

#endif /* XCTEST_XCTESTDEFINES_H */
