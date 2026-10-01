// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// The run session: the object that executes a configuration, and the two
// parameter types a caller hands it.
//
// A configuration says what to run, and the loader produces one, but neither
// of them runs anything. The reference splits the running itself across three
// declarations, and all three are here because a caller cannot use one without
// naming the other two:
//
//   XCTExecutionExtension     the shape of "something that can execute tests".
//                            A run is driven through this and not through the
//                            concrete class, so that a run can be handed a
//                            different executor -- the parallel-testing runner
//                            is one -- without the driver knowing.
//   XCTTestEnumerationOptions what to ask an extension for. Optional, and the
//                            two halves are independent: a caller may want the
//                            flat identifier list, or the grouping that says
//                            which of them may run at the same time, or both.
//   XCTTestEnumerationResult  the answer, and it is optional: the two fields
//                            are each nil when the matching option was not
//                            asked for.
//
// A result that is asked for and not delivered is how a caller finds out that
// the executor cannot answer -- which is why -completion takes an NSError and
// not an exception. The whole protocol is completion-based for the same
// reason: a run can be driven from a different process, and a method that
// answered by returning is a method that cannot cross one.
//
// The completion block of -executeTestsWithIdentifiers:... hands back a queue
// along with the error. That is not decoration. Whoever drives the run is
// frequently not the thread the tests ran on, and it has to be able to put its
// own continuation back on a queue it chose, rather than on whichever one the
// executor happened to finish on. The reference's type for that parameter is
// NSObject<OS_dispatch_queue> *, which is the declaration dispatch_queue_t
// expands to, so -dispatch_queue_t spells the same type and the archive of
// method type encodings this port is checked against is unchanged.
//
// Not yet derived, and therefore absent rather than stubbed:
//
//   XCTTestRunSession         the class itself, and the six methods below it.
//                            It cannot be written before the things it calls:
//                            +[XCTContext runInContextForTestCase:block:],
//                            +[XCTestSuite testSuiteForTestConfiguration:],
//                            +[XCTestCase allSubclassesOutsideXCTest],
//                            +[XCTestCase testClassSuitesFor...], and the
//                            test-observation handler registration that a run
//                            needs in order to be observed at all. Declaring
//                            the class without them would advertise five
//                            methods that do nothing but link.
//
// The distinction that matters here, as everywhere else in this framework: an
// extension answers questions about tests, and the run session asks them. The
// extension does not execute anything by itself; it is told which identifiers
// to execute, and a test that never appears in that list does not run.
//
// Both value types are private, as the protocol is. None belongs in
// <XCTest/XCTest.h>, and none is reachable from a public header, because the
// whole point of them is to describe a private conversation between a driver
// and an executor.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#import <XCTestCore/XCTTestSelection.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - XCTTestEnumerationOptions

/// What a caller wants to know about the tests an extension can run.
///
/// Both flags default to NO, and the two are independent: asking for one does
/// not ask for the other. Neither is a filter. They are a request for two
/// different views of the same test set, because the two are expensive to
/// compute separately and useless together -- an identifier list cannot say
/// which tests are safe to run concurrently, and a parallelizable grouping
/// cannot be turned back into a list of everything.
@interface XCTTestEnumerationOptions : NSObject <NSSecureCoding>

- (instancetype)initWithIncludeAllTestIdentifiers:(BOOL)includeAllTestIdentifiers
         includeParallelizableTestIdentifierGroups:(BOOL)includeParallelizableTestIdentifierGroups
    NS_DESIGNATED_INITIALIZER;

/// Neither view. A freshly made options object asks for nothing, which is not
/// the same as asking for an empty answer, and the distinction survives a
/// round trip through an archive.
- (instancetype)init;

/// Every identifier the extension would consider, flattened, whether or not the
/// configuration selected it. This is the *discovered* set rather than the
/// *selected* one: the question enumeration answers is "what exists", and
/// narrowing that to a selection is the caller's job, not the executor's.
@property (nonatomic, readonly) BOOL includeAllTestIdentifiers;

/// The discovered identifiers grouped into sets that may run concurrently.
///
/// A group is a unit of safety, not a unit of work: two identifiers in one
/// group are known not to interfere, and identifiers in different groups are
/// not known either way. The grouping is therefore a promise the executor makes
/// and the caller is entitled to rely on, which is why it is a separate
/// requested view rather than something derived from the flat list.
@property (nonatomic, readonly) BOOL includeParallelizableTestIdentifierGroups;

@end

#pragma mark - XCTTestEnumerationResult

/// The answer to an enumeration request.
///
/// A field is nil when the matching option was not requested, which is the
/// normal case rather than an error: a caller that wanted one view does not get
/// an error for having declined the other. The two views are also not required
/// to be consistent with one another, because a caller that asked for both is
/// asking a question about a test tree that may have been rebuilt between the
/// two computations.
@interface XCTTestEnumerationResult : NSObject <NSSecureCoding>

- (instancetype)initWithAllTestIdentifiers:(nullable XCTTestIdentifierSet *)allTestIdentifiers
         parallelizableTestIdentifierGroups:(nullable NSArray *)parallelizableTestIdentifierGroups
    NS_DESIGNATED_INITIALIZER;

/// Both views absent, for the same reason a fresh options object asks for
/// nothing: the empty result is a valid answer to a request for nothing, and
/// is not the same as an enumeration that failed.
- (instancetype)init;

/// The flat identifier set, or nil unless includeAllTestIdentifiers was set.
@property (nonatomic, readonly, nullable) XCTTestIdentifierSet *allTestIdentifiers;

/// The parallelizable groups, or nil unless
/// includeParallelizableTestIdentifierGroups was set.
@property (nonatomic, readonly, nullable) NSArray *parallelizableTestIdentifierGroups;

@end

#pragma mark - XCTExecutionExtension

/// Something that can execute a set of tests.
///
/// The protocol rather than the class, because a run may be executed by
/// something that is not the reference's run session -- the reference's own
/// parallel runner is one -- and a driver that was written against the class
/// could not be pointed at the other one.
@protocol XCTExecutionExtension <NSObject>

@required

/// Runs the tests in -identifiersToRun and then calls -completion exactly once.
///
/// -identifiersToSkip is applied as a subtraction from the request rather than
/// as part of it, so a caller that passes an identifier in both lists runs the
/// test: the skip list can only ever remove tests the caller also asked for,
/// and cannot introduce one.
///
/// The completion receives the error first and a queue second. An extension
/// that succeeded passes a nil error, and one that failed passes a queue the
/// caller may use to continue on the executor's terms.
- (void)executeTestsWithIdentifiers:(XCTTestIdentifierSet *)identifiersToRun
         skippingTestsWithIdentifiers:(nullable XCTTestIdentifierSet *)identifiersToSkip
                         completion:(void (^)(NSError *_Nullable error,
                                              dispatch_queue_t completionQueue))completion;

@optional

/// Asks the extension what it could run, without running any of it.
///
/// Optional because an extension that cannot enumerate is still an extension
/// that can execute: enumeration is an optimisation for a caller that wants to
/// show a test list, and a caller that only wants tests run has no use for it.
/// A conforming type that omits this is answering "I cannot tell you", not "I
/// have nothing".
///
/// -completion is called once. It receives a nil result only when the
/// enumeration failed, and a nil error only when it succeeded.
- (void)enumerateTestsWithOptions:(XCTTestEnumerationOptions *)options
                       completion:(void (^)(XCTTestEnumerationResult *_Nullable result,
                                            NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
