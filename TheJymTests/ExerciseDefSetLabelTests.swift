//
//  ExerciseDefSetLabelTests.swift
//  TheJymTests
//
//  Covers ExerciseDef.setLabel(for:) — the one shared formatter behind the
//  saved-set selection buttons on four screens (the Exercises tab's
//  set-history picker, AddExerciseToDayView, PhaseEditView's target-reps
//  picker, and PhasesView's per-cycle override).
//
//  The point of the helper is that those four can't drift, so these assert
//  the exact rendered string rather than "contains a dash" — a test that
//  accepted any separator would let three screens say "–" and one say "-"
//  without failing.
//

import XCTest
@testable import TheJym

final class ExerciseDefSetLabelTests: XCTestCase {

    func testNoCeilingRendersTheSchemeAlone() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6")
    }

    func testCeilingRendersAsARange() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6 \u{2013} 8/8/8")
    }

    /// En dash, with spaces — pinned exactly, because the whole reason this
    /// lives in one place is so the four buttons can't disagree.
    func testSeparatorIsAnEnDashNotAHyphen() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[5, 5, 5]])
        def.setCeiling(for: [5, 5, 5], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        let label = def.setLabel(for: [5, 5, 5])
        XCTAssertTrue(label.contains(" \u{2013} "), "en dash surrounded by spaces")
        XCTAssertFalse(label.contains("-"), "never a hyphen-minus")
    }

    /// A ceiling belongs to one scheme only. Setting one on 6/6/6 must not
    /// leak onto a sibling scheme on the same exercise.
    func testCeilingDoesNotLeakToASiblingScheme() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6], [10, 10]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6 \u{2013} 8/8/8")
        XCTAssertEqual(def.setLabel(for: [10, 10]), "10/10")
    }

    /// The same miss ceiling(for:) documents: reps that match no saved
    /// scheme. The label must degrade to the plain join, not crash or
    /// render a dangling dash.
    func testRepsMatchingNoSavedSchemeRenderPlainly() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [5, 5, 5, 3, 3, 3]), "5/5/5/3/3/3")
        XCTAssertEqual(def.setLabel(for: []), "")
    }

    /// An empty ceiling would render "6/6/6 – " with nothing after it.
    /// Suppressed rather than shown half-finished.
    func testEmptyCeilingIsSuppressedRatherThanLeavingADanglingDash() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6")
    }

    /// A ceiling whose set count doesn't match the scheme's IS shown.
    /// The ceiling editor enforces equal counts, but the import path
    /// parsing "5/5/5>8/8@5" does not — and hiding a malformed ceiling
    /// would hide the problem rather than surface it.
    func testMismatchedLengthCeilingIsShownRatherThanHidden() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6 \u{2013} 8/8")
    }

    /// Ceiling equal to the scheme means "bump the weight as soon as you
    /// hit the target" — a real configuration the editor permits, so it
    /// reads as a range rather than being collapsed to look unconfigured.
    func testCeilingEqualToTheSchemeStillReadsAsARange() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [6, 6, 6], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6 \u{2013} 6/6/6")
    }

    /// removeRepScheme clears the ceiling with the scheme, so a label for
    /// a re-added scheme of the same shape starts clean.
    func testLabelFollowsRemoveRepSchemeClearingTheCeiling() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        def.removeRepScheme([6, 6, 6])
        def.addRepScheme([6, 6, 6])
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6",
                       "the ceiling went with the scheme, so the label is plain again")
    }

    /// clearCeiling returns the label to the plain join.
    func testClearCeilingReturnsTheLabelToPlain() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[6, 6, 6]])
        def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6 \u{2013} 8/8/8")
        def.clearCeiling(for: [6, 6, 6])
        XCTAssertEqual(def.setLabel(for: [6, 6, 6]), "6/6/6")
    }

    /// Single-set schemes read sensibly — no separator confusion between
    /// the "/" joining sets and the "–" joining the range.
    func testSingleSetScheme() {
        let def = ExerciseDef(name: "Pull-Up", repSchemes: [[8]])
        def.setCeiling(for: [8], upperTargetReps: [12], weightIncreaseAmount: 2.5)
        XCTAssertEqual(def.setLabel(for: [8]), "8 \u{2013} 12")
    }
}
