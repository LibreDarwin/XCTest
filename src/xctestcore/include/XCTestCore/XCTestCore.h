// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Umbrella header for the private XCTestCore framework.
//
// Everything a client of XCTestCore needs is one of the four headers below, and
// this file exists so that the module has a single umbrella. A module map can
// only declare one, and pointing it at one of the others would make the rest
// reachable only by naming their files directly -- which works, and is not what
// a client should have to know.
//
// The four are layered, not peers:
//
//   XCTestConfiguration        one configuration: the bundle, the target app,
//                              the timeouts, the ordering, the statistics keys.
//                              The thing that describes a whole run.
//   XCTTestSelection           which tests in that run execute. The thing that
//                              describes a subset of them.
//   XCTestConfigurationLoader  where that configuration comes from. The thing
//                              that decides it, and is the only one of the three
//                              with behaviour: the other two are values this
//                              one reads.
//   XCTTestRunSession          what a run is handed to in order to be executed,
//                              and the shape of "something that can execute
//                              tests" that a driver programs against. The
//                              layer above all three, because an extension is
//                              given identifiers and answers questions about
//                              tests, and so is downstream of every one of them.
//
// The first two are mutually reachable -- each imports the other, because a run
// is a configuration plus a selection and a client holding one has to be able
// to ask what the other says. The loader sits above both rather than beside them,
// and imports them for the same reason: its return value is a configuration and
// one of its results is a selection, so neither would be nameable from here
// otherwise.
//
// All four are private. None belongs in <XCTest/XCTest.h>, and none is
// re-exported from this framework to a public header; the split is the same one
// Apple's tree makes, and it is why this framework can be built without linking
// XCTest at all.

#import <XCTestCore/XCTestConfiguration.h>
#import <XCTestCore/XCTestConfigurationLoader.h>
#import <XCTestCore/XCTTestRunSession.h>
#import <XCTestCore/XCTTestSelection.h>