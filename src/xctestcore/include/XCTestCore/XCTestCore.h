// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Umbrella header for the private XCTestCore framework.
//
// Everything a client of XCTestCore needs is one of the two headers below, and
// this file exists so that the module has a single umbrella. A module map can
// only declare one, and pointing it at one of the two value types would make
// the other reachable only by naming its file directly -- which works, and is
// not what a client should have to know.
//
// The two headers are layered, not peers:
//
//   XCTestConfiguration   one configuration: the bundle, the target app, the
//                         timeouts, the ordering, the statistics keys. The thing
//                         that describes a whole run.
//   XCTTestSelection      which tests in that run execute. The thing that
//                         describes a subset of them.
//
// Both are private. Neither belongs in <XCTest/XCTest.h>, and neither is
// re-exported from this framework to a public header; the split is the same one
// Apple's tree makes, and it is why this framework can be built without linking
// XCTest at all.

#import <XCTestCore/XCTestConfiguration.h>
#import <XCTestCore/XCTTestSelection.h>