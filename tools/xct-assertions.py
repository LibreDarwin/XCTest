#!/usr/bin/env python3
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
"""Generate the XCTest assertion primitives and their failure format strings.

Why this is generated
---------------------
Every XCTAssert* macro expands to a primitive that reports a message built by
``_XCTFailureFormat(type, index)``. The macro passes a specific list of
arguments to that format; the format string must have exactly one conversion per
argument, in the same order. That is a two-place coupling across 23 primitives
and 30-odd format strings, maintained by hand, where the failure mode is silent:
a mismatched list still compiles, and the symptom is a garbled failure message
or a crash in a user's test run.

So the table below is the single source of truth. It emits both halves:

  * the ``_XCTPrimitive*`` macros, into XCTestAssertionsImpl.h
  * the ``_XCTFailureFormat`` implementation, into XCTestAssertionFormats.h

and validates that every format string's conversion count equals its argument
list length. That check is the entire point: a mismatch is a build-time error
here rather than a bad message at runtime.

Run:  python3 tools/xct-assertions.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IMPL_HEADER = os.path.join(ROOT, "src/xctest/include/XCTest/XCTestAssertionsImpl.h")
FORMATS_HEADER = os.path.join(ROOT, "src/xctest/XCTestAssertionFormats.h")

BEGIN = "// BEGIN GENERATED ASSERTION PRIMITIVES"
END = "// END GENERATED ASSERTION PRIMITIVES"


class Assertion:
    """One _XCTPrimitive* macro.

    kind is "condition" for the value-comparison family, or one of the throws
    sub-shapes. Only the condition shape is templated from fields; the throws
    shapes are irregular enough that spelling them out is clearer than
    parameterising them.
    """

    def __init__(self, name, kind, params, enum, body, uses):
        self.name = name
        self.kind = kind
        self.params = params
        self.enum = enum
        self.body = body
        self.uses = uses  # list of (index, format_string, [arg, ...])


def cond(name, params, setup, cond_expr, enum, fmt0, fmt1):
    """Build a value-comparison primitive.

    Every one of these shares the same skeleton: evaluate the operands into
    locals inside a @try, register a failure if the condition holds, and convert
    an unexpected exception into a failure that names the expression. The
    operand locals matter -- they evaluate each expression exactly once, so an
    expression with side effects is not evaluated twice by the message.
    """
    lines = ["_XCT_ASSERT_BEGIN \\"]
    lines.append("    _XCT_TRY { \\")
    for stmt in setup:
        lines.append("        %s \\" % stmt)
    lines.append("        if (%s) { \\" % cond_expr)
    lines.append(
        "            _XCTRegisterFailure(%s, _XCTFailureDescription(%s, 0, %s), __VA_ARGS__); \\"
        % (params[0], enum, ", ".join(fmt0[1])))
    lines.append("        } \\")
    lines.append("    } \\")
    # "_xct_reason" is a placeholder: the two catch clauses have different ways
    # of naming what was caught, so the substitution happens per clause rather
    # than once when the table is written.
    def args(reason):
        return ", ".join(a.replace("_xct_reason", reason) for a in fmt1[1])

    lines.append(
        "    _XCT_CATCH (_XCTestCaseInterruptionException *interruption) "
        "{ [interruption raise]; } \\")
    lines.append("    _XCT_CATCH (NSException *_xct_exception) { \\")
    lines.append(
        "        _XCTRegisterUnexpectedFailure(%s, _XCTFailureDescription(%s, 1, %s), __VA_ARGS__); \\"
        % (params[0], enum, args("_XCTReasonForException(_xct_exception)")))
    lines.append("    } \\")
    lines.append("    _XCT_CATCH (...) { \\")
    lines.append(
        "        _XCTRegisterUnexpectedFailure(%s, _XCTFailureDescription(%s, 1, %s), __VA_ARGS__); \\"
        % (params[0], enum, args('@"a non-ObjC exception"')))
    lines.append("    } \\")
    lines.append("_XCT_ASSERT_END")
    return Assertion(
        name, "condition", params, enum, lines,
        [(0, fmt0[0], fmt0[1]), (1, fmt1[0], fmt1[1])])


ID1 = ["id expression1Value = (expression1);"]
ID2 = ["id expression2Value = (expression2);"]
SCALAR1 = ["__typeof__(expression1) expression1Value = (expression1);"]
SCALAR2 = ["__typeof__(expression2) expression2Value = (expression2);"]


def boxes_from(prefixes, types):
    """Box each named local so its value can be rendered in the failure text.

    A scalar has to be boxed because the format string is built at runtime, long
    after the local that holds it is gone; NSValue is what carries a C value
    through as an object. The objCType has to be the operand's real type rather
    than a generic one or _XCTDescriptionForValue would misread the bytes.
    """
    out = []
    for prefix, ty in zip(prefixes, types):
        out.append(
            "NSValue *%sBox = [NSValue value:&%sValue "
            "withObjCType:@encode(%s)];" % (prefix, prefix, ty))
    return out


ACCURACY_SETUP = (
    SCALAR1 + SCALAR2 + ["__typeof__(accuracy) accuracyValue = (accuracy);"] +
    boxes_from(("expression1", "expression2", "accuracy"),
               ("__typeof__(expression1)", "__typeof__(expression2)",
                "__typeof__(accuracy)")))

# Two-operand descriptions for the comparison family, reused by the relational
# assertions so the wording stays consistent across them.
def pair(verb, a="expressionStr1", b="expressionStr2"):
    return ("XCTAssert%s failed: (%@) is not %s (%@): (%@) != (%@)"
            % (verb, "%@", "%@", "%@"),
            [a, b, "_XCTDescriptionForValue(expression1Box)",
             "_XCTDescriptionForValue(expression2Box)"])


def threw(verb, exprs=("expressionStr",), reason=True):
    parts = " with ".join(["(%@)"] * len(exprs))
    if reason:
        return ("XCTAssert%s threw an exception comparing %s: %%@" % (verb, parts),
                list(exprs) + ["_xct_reason"])
    return ("XCTAssert%s threw an exception evaluating (%@)" % (verb, ), list(exprs))


ASSERTIONS = [
    # ---- nil-ness -------------------------------------------------------
    cond("_XCTPrimitiveAssertNil",
         ["test", "expression", "expressionStr"],
         ["id expressionValue = (expression);"],
         "expressionValue != nil",
         "_XCTAssertion_Nil",
         ("XCTAssertNil failed: (%@) is not nil: (%@)",
          ["expressionStr", "expressionValue"]),
         ("XCTAssertNil threw an exception evaluating (%@): %@",
          ["expressionStr", "_xct_reason"])),
    cond("_XCTPrimitiveAssertNotNil",
         ["test", "expression", "expressionStr"],
         ["id expressionValue = (expression);"],
         "expressionValue == nil",
         "_XCTAssertion_NotNil",
         ("XCTAssertNotNil failed: (%@) is nil", ["expressionStr"]),
         ("XCTAssertNotNil threw an exception evaluating (%@): %@",
          ["expressionStr", "_xct_reason"])),

    # ---- booleans -------------------------------------------------------
    cond("_XCTPrimitiveAssertTrue",
         ["test", "expression", "expressionStr"],
         ["BOOL expressionValue = (expression) ? YES : NO;"],
         "!expressionValue",
         "_XCTAssertion_True",
         ("XCTAssertTrue failed: (%@)", ["expressionStr"]),
         ("XCTAssertTrue threw an exception evaluating (%@): %@",
          ["expressionStr", "_xct_reason"])),
    cond("_XCTPrimitiveAssertFalse",
         ["test", "expression", "expressionStr"],
         ["BOOL expressionValue = (expression) ? YES : NO;"],
         "expressionValue",
         "_XCTAssertion_False",
         ("XCTAssertFalse failed: (%@)", ["expressionStr"]),
         ("XCTAssertFalse threw an exception evaluating (%@): %@",
          ["expressionStr", "_xct_reason"])),

    # ---- object identity / equality -------------------------------------
    cond("_XCTPrimitiveAssertEqualObjects",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         ID1 + ID2,
         "(expression1Value != expression2Value) && "
         "![(id<NSObject>)expression1Value isEqual:expression2Value]",
         "_XCTAssertion_EqualObjects",
         ("XCTAssertEqualObjects failed: (%@) is not equal to (%@): (%@) != (%@)",
          ["expressionStr1", "expressionStr2", "expression1Value", "expression2Value"]),
         ("XCTAssertEqualObjects threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertNotEqualObjects",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         ID1 + ID2,
         "(expression1Value == expression2Value) || "
         "[(id<NSObject>)expression1Value isEqual:expression2Value]",
         "_XCTAssertion_NotEqualObjects",
         ("XCTAssertNotEqualObjects failed: (%@) is equal to (%@): (%@) == (%@)",
          ["expressionStr1", "expressionStr2", "expression1Value", "expression2Value"]),
         ("XCTAssertNotEqualObjects threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertIdentical",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         ID1 + ID2,
         "(expression1Value != expression2Value)",
         "_XCTAssertion_Identical",
         ("XCTAssertIdentical failed: (%@) is not identical to (%@)",
          ["expressionStr1", "expressionStr2"]),
         ("XCTAssertIdentical threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertNotIdentical",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         ID1 + ID2,
         "(expression1Value == expression2Value)",
         "_XCTAssertion_NotIdentical",
         ("XCTAssertNotIdentical failed: (%@) is identical to (%@)",
          ["expressionStr1", "expressionStr2"]),
         ("XCTAssertNotIdentical threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),

    # ---- scalar equality / ordering -------------------------------------
    cond("_XCTPrimitiveAssertEqual",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         SCALAR1 + SCALAR2 + boxes_from(("expression1", "expression2"),
                                        ("__typeof__(expression1)",
                                         "__typeof__(expression2)")),
         "!(expression1Value == expression2Value)",
         "_XCTAssertion_Equal",
         ("XCTAssertEqual failed: (%@) is not equal to (%@): (%@) != (%@)",
          ["expressionStr1", "expressionStr2",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)"]),
         ("XCTAssertEqual threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertNotEqual",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         SCALAR1 + SCALAR2 + boxes_from(("expression1", "expression2"),
                                        ("__typeof__(expression1)",
                                         "__typeof__(expression2)")),
         "(expression1Value == expression2Value)",
         "_XCTAssertion_NotEqual",
         ("XCTAssertNotEqual failed: (%@) is equal to (%@): (%@) == (%@)",
          ["expressionStr1", "expressionStr2",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)"]),
         ("XCTAssertNotEqual threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertGreaterThan",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         SCALAR1 + SCALAR2 + boxes_from(("expression1", "expression2"),
                                        ("__typeof__(expression1)",
                                         "__typeof__(expression2)")),
         "!(expression1Value > expression2Value)",
         "_XCTAssertion_GreaterThan",
         ("XCTAssertGreaterThan failed: (%@) is not greater than (%@): (%@) <= (%@)",
          ["expressionStr1", "expressionStr2",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)"]),
         ("XCTAssertGreaterThan threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertGreaterThanOrEqual",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         SCALAR1 + SCALAR2 + boxes_from(("expression1", "expression2"),
                                        ("__typeof__(expression1)",
                                         "__typeof__(expression2)")),
         "!(expression1Value >= expression2Value)",
         "_XCTAssertion_GreaterThanOrEqual",
         ("XCTAssertGreaterThanOrEqual failed: (%@) is not greater than or equal to (%@): (%@) < (%@)",
          ["expressionStr1", "expressionStr2",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)"]),
         ("XCTAssertGreaterThanOrEqual threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertLessThan",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         SCALAR1 + SCALAR2 + boxes_from(("expression1", "expression2"),
                                        ("__typeof__(expression1)",
                                         "__typeof__(expression2)")),
         "!(expression1Value < expression2Value)",
         "_XCTAssertion_LessThan",
         ("XCTAssertLessThan failed: (%@) is not less than (%@): (%@) >= (%@)",
          ["expressionStr1", "expressionStr2",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)"]),
         ("XCTAssertLessThan threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),
    cond("_XCTPrimitiveAssertLessThanOrEqual",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2"],
         SCALAR1 + SCALAR2 + boxes_from(("expression1", "expression2"),
                                        ("__typeof__(expression1)",
                                         "__typeof__(expression2)")),
         "!(expression1Value <= expression2Value)",
         "_XCTAssertion_LessThanOrEqual",
         ("XCTAssertLessThanOrEqual failed: (%@) is not less than or equal to (%@): (%@) > (%@)",
          ["expressionStr1", "expressionStr2",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)"]),
         ("XCTAssertLessThanOrEqual threw an exception comparing (%@) with (%@): %@",
          ["expressionStr1", "expressionStr2", "_xct_reason"])),

    # ---- accuracy -------------------------------------------------------
    # A NaN operand is a failure, not a pass: NaN is unordered, so every
    # relational test against it is false and "!(v1 <= v2)" would otherwise
    # report success for a comparison that can never hold.
    cond("_XCTPrimitiveAssertEqualWithAccuracy",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2",
          "accuracy", "accuracyStr"],
         ACCURACY_SETUP,
         "isnan(expression1Value) || isnan(expression2Value) || "
         "((MAX(expression1Value, expression2Value) - "
         "MIN(expression1Value, expression2Value)) > accuracyValue)",
         "_XCTAssertion_EqualWithAccuracy",
         ("XCTAssertEqualWithAccuracy failed: (%@) is not within (%@) of (%@): "
          "(%@) != (%@) +/- (%@)",
          ["expressionStr1", "expressionStr2", "accuracyStr",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)",
           "_XCTDescriptionForValue(accuracyBox)"]),
         ("XCTAssertEqualWithAccuracy threw an exception comparing (%@) with (%@) "
          "within (%@): %@",
          ["expressionStr1", "expressionStr2", "accuracyStr", "_xct_reason"])),
    cond("_XCTPrimitiveAssertNotEqualWithAccuracy",
         ["test", "expression1", "expressionStr1", "expression2", "expressionStr2",
          "accuracy", "accuracyStr"],
         ACCURACY_SETUP,
         "!isnan(expression1Value) && !isnan(expression2Value) && "
         "((MAX(expression1Value, expression2Value) - "
         "MIN(expression1Value, expression2Value)) <= accuracyValue)",
         "_XCTAssertion_NotEqualWithAccuracy",
         ("XCTAssertNotEqualWithAccuracy failed: (%@) is within (%@) of (%@): "
          "(%@) == (%@) +/- (%@)",
          ["expressionStr1", "expressionStr2", "accuracyStr",
           "_XCTDescriptionForValue(expression1Box)",
           "_XCTDescriptionForValue(expression2Box)",
           "_XCTDescriptionForValue(accuracyBox)"]),
         ("XCTAssertNotEqualWithAccuracy threw an exception comparing (%@) with (%@) "
          "within (%@): %@",
          ["expressionStr1", "expressionStr2", "accuracyStr", "_xct_reason"])),
]


# ---- the irregular throws family -----------------------------------------
# These do not share the value-comparison skeleton: they assert something about
# whether an expression raised, so they are built from @try/@catch and a
# _didThrow flag rather than a failure condition.

def _macro(name, params, body):
    return Assertion(name, "throws", params, None, body, [])


THROWS = [
    _macro("_XCTPrimitiveAssertThrows",
           ["test", "expression", "expressionStr"],
           ["_XCT_ASSERT_BEGIN \\",
            "    BOOL _didThrow = NO; \\",
            "    _XCT_TRY { \\",
            "        (void)(expression); \\",
            "    } \\",
            "    _XCT_CATCH (...) { \\",
            "        _didThrow = YES; \\",
            "    } \\",
            "    if (!_didThrow) { \\",
            "        _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_Throws, 0, expressionStr), __VA_ARGS__); \\",
            "    } \\",
            "_XCT_ASSERT_END"]),
    _macro("_XCTPrimitiveAssertThrowsSpecific",
           ["test", "expression", "expressionStr", "exception_class"],
           ["_XCT_ASSERT_BEGIN \\",
            "    BOOL _didThrow = NO; \\",
            "    _XCT_TRY { \\",
            "        (void)(expression); \\",
            "    } \\",
            "    _XCT_CATCH (_XCT_CATCHABLE_TYPE(exception_class)) { \\",
            "        _didThrow = YES; \\",
            "    } \\",
             "    _XCT_CATCH (NSException *_xct_exception) { \\",
             "        _didThrow = YES; \\",
             "        _XCTRegisterFailure(test, _XCTFailureDescription("
             "_XCTAssertion_ThrowsSpecific, 0, expressionStr, @#exception_class, "
             "@#exception_class, _XCTReasonForException(_xct_exception)), __VA_ARGS__); \\",
             "    } \\",
             "    _XCT_CATCH (...) { \\",
             "        _didThrow = YES; \\",
             "        _XCTRegisterFailure(test, _XCTFailureDescription("
             "_XCTAssertion_ThrowsSpecific, 0, expressionStr, @#exception_class, "
             '@#exception_class, @"a non-ObjC exception"), __VA_ARGS__); \\',
             "    } \\",
            "    if (!_didThrow) { \\",
            "        _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_ThrowsSpecific, 1, expressionStr, @#exception_class), "
            "__VA_ARGS__); \\",
            "    } \\",
            "_XCT_ASSERT_END"]),
    _macro("_XCTPrimitiveAssertThrowsSpecificNamed",
           ["test", "expression", "expressionStr", "exception_class",
            "exception_name"],
           ["_XCT_ASSERT_BEGIN \\",
            "    BOOL _didThrow = NO; \\",
            "    _XCT_TRY { \\",
            "        _XCT_TRY { \\",
            "            (void)(expression); \\",
            "        } \\",
            "        _XCT_CATCH (exception_class *exception) { \\",
            "            _didThrow = YES; \\",
            "            if (![exception_name isEqualToString:[exception name]]) { \\",
            "                _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_ThrowsSpecificNamed, 0, expressionStr, @#exception_class, "
            "exception_name, @#exception_class, [exception name], [exception reason]), "
            "__VA_ARGS__); \\",
            "            } \\",
            "        } \\",
            "    } \\",
            "    _XCT_CATCH (NSException *exception) { \\",
            "        _didThrow = YES; \\",
            "        _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_ThrowsSpecificNamed, 1, expressionStr, @#exception_class, "
            "exception_name, @#exception_class, [exception name], [exception reason]), "
            "__VA_ARGS__); \\",
            "    } \\",
            "    _XCT_CATCH (...) { \\",
            "        _didThrow = YES; \\",
            "        _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_ThrowsSpecificNamed, 2, expressionStr, @#exception_class, "
            "exception_name), __VA_ARGS__); \\",
            "    } \\",
            "    if (!_didThrow) { \\",
            "        _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_ThrowsSpecificNamed, 3, expressionStr, @#exception_class, "
            "exception_name), __VA_ARGS__); \\",
            "    } \\",
            "_XCT_ASSERT_END"]),
    _macro("_XCTPrimitiveAssertNoThrow",
           ["test", "expression", "expressionStr"],
           ["_XCT_ASSERT_BEGIN \\",
            "    _XCT_TRY { \\",
            "        (void)(expression); \\",
            "    } \\",
             "    _XCT_CATCH (NSException *_xct_exception) { \\",
             "        _XCTRegisterFailure(test, _XCTFailureDescription("
             "_XCTAssertion_NoThrow, 0, expressionStr, "
             "_XCTReasonForException(_xct_exception)), __VA_ARGS__); \\",
             "    } \\",
             "    _XCT_CATCH (...) { \\",
             "        _XCTRegisterFailure(test, _XCTFailureDescription("
             "_XCTAssertion_NoThrow, 0, expressionStr, "
             '@"a non-ObjC exception"), __VA_ARGS__); \\',
             "    } \\",
             "_XCT_ASSERT_END"]),
    _macro("_XCTPrimitiveAssertNoThrowSpecific",
           ["test", "expression", "expressionStr", "exception_class"],
           ["_XCT_ASSERT_BEGIN \\",
            "    _XCT_TRY { \\",
            "        (void)(expression); \\",
            "    } \\",
            "    _XCT_CATCH (_XCT_CATCHABLE_TYPE(exception_class) _xct_caught) { \\",
            "        _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_NoThrowSpecific, 0, expressionStr, @#exception_class, "
            "@#exception_class, _XCTReasonForException((NSException *)_xct_caught)), "
            "__VA_ARGS__); \\",
            "    } \\",
            "    _XCT_CATCH (...) { \\",
            "        ; \\",
            "    } \\",
            "_XCT_ASSERT_END"]),
    _macro("_XCTPrimitiveAssertNoThrowSpecificNamed",
           ["test", "expression", "expressionStr", "exception_class",
            "exception_name"],
           ["_XCT_ASSERT_BEGIN \\",
            "    _XCT_TRY { \\",
            "        (void)(expression); \\",
            "    } \\",
            "    _XCT_CATCH (exception_class *exception) { \\",
            "        if ([exception_name isEqualToString:[exception name]]) { \\",
            "            _XCTRegisterFailure(test, _XCTFailureDescription("
            "_XCTAssertion_NoThrowSpecificNamed, 0, expressionStr, @#exception_class, "
            "exception_name, @#exception_class, [exception name], [exception reason]), "
            "__VA_ARGS__); \\",
            "        } \\",
            "    } \\",
            "    _XCT_CATCH (...) { \\",
            "        ; \\",
            "    } \\",
            "_XCT_ASSERT_END"]),
]

# The throws primitives are hand-spelled above, so their format strings are
# declared here instead of inside the macro bodies. Keyed by
# (enum, index) so a duplicate is caught.
THROWS_FORMATS = {
    ("_XCTAssertion_Fail", 0):
        ("XCTFail failed", []),
    ("_XCTAssertion_Throws", 0):
        ("XCTAssertThrows failed: (%@) did not throw an exception", ["expressionStr"]),
    ("_XCTAssertion_ThrowsSpecific", 0):
        ("XCTAssertThrowsSpecific failed: (%@) threw an exception, but not of "
         "type %@ (expected %@): %@",
         ["expressionStr", "@#exception_class", "@#exception_class", "_xct_reason"]),
    ("_XCTAssertion_ThrowsSpecific", 1):
        ("XCTAssertThrowsSpecific failed: (%@) did not throw an exception of "
         "type %@", ["expressionStr", "@#exception_class"]),
    ("_XCTAssertion_ThrowsSpecificNamed", 0):
        ("XCTAssertThrowsSpecificNamed failed: (%@) threw %@ (expected %@) with "
         "name \"%@\", but it was named \"%@\": %@",
         ["expressionStr", "@#exception_class", "exception_name", "@#exception_class",
          "[exception name]", "[exception reason]"]),
    ("_XCTAssertion_ThrowsSpecificNamed", 1):
        ("XCTAssertThrowsSpecificNamed failed: (%@) threw a %@ named \"%@\", "
         "but it was expected to be a %@ named \"%@\": %@",
         ["expressionStr", "@#exception_class", "[exception name]",
          "@#exception_class", "exception_name", "[exception reason]"]),
    ("_XCTAssertion_ThrowsSpecificNamed", 2):
        ("XCTAssertThrowsSpecificNamed failed: (%@) did not throw an exception of "
         "type %@ with name \"%@\"",
         ["expressionStr", "@#exception_class", "exception_name"]),
    ("_XCTAssertion_ThrowsSpecificNamed", 3):
        ("XCTAssertThrowsSpecificNamed failed: (%@) did not throw at all; "
         "expected %@ named \"%@\"",
         ["expressionStr", "@#exception_class", "exception_name"]),
    ("_XCTAssertion_NoThrow", 0):
        ("XCTAssertNoThrow failed: (%@) threw an exception: %@",
         ["expressionStr", "_xct_reason"]),
    ("_XCTAssertion_NoThrowSpecific", 0):
        ("XCTAssertNoThrowSpecific failed: (%@) threw an exception of type %@ "
         "(expected %@): %@",
         ["expressionStr", "@#exception_class", "@#exception_class", "_xct_reason"]),
    ("_XCTAssertion_NoThrowSpecificNamed", 0):
        ("XCTAssertNoThrowSpecificNamed failed: (%@) threw %@ (expected %@) with "
         "name \"%@\", but it was named \"%@\": %@",
         ["expressionStr", "@#exception_class", "exception_name", "@#exception_class",
          "[exception name]", "[exception reason]"]),
}

ALL = ASSERTIONS + THROWS

# Enum name -> value, in Apple's declaration order. Order matters only for
# readability; the values are internal.
ENUM_MEMBERS = [
    ("_XCTAssertion_Fail", 0),
    ("_XCTAssertion_Nil", 1),
    ("_XCTAssertion_NotNil", 2),
    ("_XCTAssertion_EqualObjects", 3),
    ("_XCTAssertion_NotEqualObjects", 4),
    ("_XCTAssertion_Equal", 5),
    ("_XCTAssertion_NotEqual", 6),
    ("_XCTAssertion_EqualWithAccuracy", 7),
    ("_XCTAssertion_NotEqualWithAccuracy", 8),
    ("_XCTAssertion_GreaterThan", 9),
    ("_XCTAssertion_GreaterThanOrEqual", 10),
    ("_XCTAssertion_LessThan", 11),
    ("_XCTAssertion_LessThanOrEqual", 12),
    ("_XCTAssertion_True", 13),
    ("_XCTAssertion_False", 14),
    ("_XCTAssertion_Throws", 15),
    ("_XCTAssertion_ThrowsSpecific", 16),
    ("_XCTAssertion_ThrowsSpecificNamed", 17),
    ("_XCTAssertion_NoThrow", 18),
    ("_XCTAssertion_NoThrowSpecific", 19),
    ("_XCTAssertion_NoThrowSpecificNamed", 20),
    ("_XCTAssertion_Unwrap", 21),
    ("_XCTAssertion_Identical", 22),
    ("_XCTAssertion_NotIdentical", 23),
]


def c_string(text):
    """Quote `text` as an Objective-C string literal.

    The @ matters: the function returns an NSString, and a bare "..." in an
    Objective-C file is a C literal that cannot be returned. The leading @ is
    placed outside the escaping so the backslashes stay inside the quoted run.
    """
    return '@"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def validate():
    """Every format string's conversion count must match its argument list."""
    problems = []
    formats = {}
    for a in ASSERTIONS:
        for index, fmt, args in a.uses:
            formats[(a.enum, index)] = (fmt, args)
    formats.update(THROWS_FORMATS)

    for (enum, index), (fmt, args) in sorted(formats.items()):
        n_conv = len(re.findall(r"%[@dDiuUxXoOfeEgGcspq]", fmt))
        if n_conv != len(args):
            problems.append(
                "%s[%d]: format has %d conversion(s) but is passed %d argument(s)\n"
                "    format: %s\n    args:   %s"
                % (enum, index, n_conv, len(args), fmt, ", ".join(args)))

    declared = {name for name, _ in ENUM_MEMBERS}
    for enum, _ in formats:
        if enum not in declared:
            problems.append("%s used in a format but not declared in the enum" % enum)

    # _XCTPrimitiveFail is emitted by hand in render_primitives() because it has
    # no condition and no operand locals, so it is not built by cond().
    known = {a.name for a in ALL} | {"_XCTPrimitiveFail"}
    expected = {
        "_XCTPrimitiveFail", "_XCTPrimitiveAssertNil", "_XCTPrimitiveAssertNotNil",
        "_XCTPrimitiveAssertTrue", "_XCTPrimitiveAssertFalse",
        "_XCTPrimitiveAssertEqualObjects", "_XCTPrimitiveAssertNotEqualObjects",
        "_XCTPrimitiveAssertEqual", "_XCTPrimitiveAssertNotEqual",
        "_XCTPrimitiveAssertIdentical", "_XCTPrimitiveAssertNotIdentical",
        "_XCTPrimitiveAssertEqualWithAccuracy",
        "_XCTPrimitiveAssertNotEqualWithAccuracy",
        "_XCTPrimitiveAssertGreaterThan", "_XCTPrimitiveAssertGreaterThanOrEqual",
        "_XCTPrimitiveAssertLessThan", "_XCTPrimitiveAssertLessThanOrEqual",
        "_XCTPrimitiveAssertThrows", "_XCTPrimitiveAssertThrowsSpecific",
        "_XCTPrimitiveAssertThrowsSpecificNamed", "_XCTPrimitiveAssertNoThrow",
        "_XCTPrimitiveAssertNoThrowSpecific", "_XCTPrimitiveAssertNoThrowSpecificNamed",
    }
    missing = expected - known
    if missing:
        problems.append("missing primitives: %s" % ", ".join(sorted(missing)))
    return problems, formats


def render_primitives():
    out = [BEGIN,
           "// Generated by tools/xct-assertions.py. Do not edit by hand:",
           "// re-run the generator instead. See that file for why this is generated.",
           ""]
    out.append("#define _XCTPrimitiveFail(test, ...) \\")
    out.append("    _XCTRegisterFailure(test, "
               "_XCTFailureDescription(_XCTAssertion_Fail, 0, \"\"), __VA_ARGS__)")
    out.append("")
    for a in ALL:
        out.append("#define %s(%s, ...) \\" % (a.name, ", ".join(a.params)))
        for i, line in enumerate(a.body):
            out.append("    " + line)
        out.append("")
    out.append(END)
    return "\n".join(out)


def render_formats(formats):
    out = ["""// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Generated by tools/xct-assertions.py. Do not edit by hand.
//
// The failure text for every assertion primitive. Each entry is keyed by
// (assertion type, format index); the index distinguishes the "the assertion did
// not hold" message from the "the expression raised" one, and the throws family
// adds further indices for the different ways it can go wrong.
//
// The argument lists here are not decorative. The generated macros pass exactly
// these expressions, in this order, to _XCTFailureDescription, and the generator
// refuses to emit if a conversion count and its argument count disagree.

#import "XCTestInternal.h"

NSString *_XCTFailureFormat(_XCTAssertionType assertionType, NSUInteger formatIndex)
{
    switch (assertionType) {"""]
    for name, value in ENUM_MEMBERS:
        entries = [(i, f, a) for (e, i), (f, a) in formats.items() if e == name]
        if not entries:
            continue
        entries.sort()
        out.append("        case %s:" % name)
        for index, fmt, args in entries:
            if index == 0:
                out.append("            if (formatIndex == 0) {")
            else:
                out.append("            if (formatIndex == %d) {" % index)
            out.append("                return %s;" % c_string(fmt))
            out.append("            }")
        out.append("            break;")
    out.append("        default:")
    out.append("            break;")
    out.append("    }")
    out.append("    return @\"\";")
    out.append("}")
    return "\n".join(out) + "\n"


def splice(path, begin, end, block):
    with open(path) as f:
        text = f.read()
    if begin not in text or end not in text:
        sys.exit("error: markers not found in %s" % path)
    head = text.split(begin)[0]
    tail = text.split(end, 1)[1]
    with open(path, "w") as f:
        f.write(head + block + tail)
    print("wrote %s" % os.path.relpath(path, ROOT))


def main():
    problems, formats = validate()
    if problems:
        sys.stderr.write("assertion table is inconsistent:\n")
        for p in problems:
            sys.stderr.write("  - %s\n" % p)
        return 1

    splice(IMPL_HEADER, BEGIN, END, render_primitives())

    with open(FORMATS_HEADER, "w") as f:
        f.write(render_formats(formats))
    print("wrote %s" % os.path.relpath(FORMATS_HEADER, ROOT))
    print("%d primitives, %d format strings" % (len(ALL) + 1, len(formats)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
