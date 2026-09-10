//
//  ExerciseDefRepSchemeCeilingTests.swift
//  TheJymTests
//
//  Covers ExerciseDef.repSchemeCeilings/ceiling(for:)/setCeiling/clearCeiling
//  /removeRepScheme — the global, per-exercise-and-rep-scheme storage that
//  replaced PlannedExercise.upperTargetReps/weightIncreaseAmount
//  (e10a508/48078d3, removed).
//

import XCTest
@testable import TheJym

final class ExerciseDefRepSchemeCeilingTests: XCTestCase {
    /// The exact case flagged before implementing: PlannedExercise.targetReps
    /// isn't guaranteed to match a saved repScheme (import/manual-edit path)
    /// — ceiling(for:) must return nil cleanly, not crash, for reps that
    /// don't correspond to anything saved.
    func testCeilingReturnsNilForRepsNotMatchingAnySavedScheme() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        XCTAssertNil(def.ceiling(for: [5, 5, 5, 3, 3, 3]), "no saved scheme matches this reps array at all")
        XCTAssertNil(def.ceiling(for: []), "empty reps array shouldn't match or crash either")
    }

    func testCeilingReturnsNilWhenNothingConfiguredYet() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        XCTAssertNil(def.ceiling(for: [8, 8, 8]))
    }

    func testSetCeilingThenCeilingRoundTrips() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        let ceiling = def.ceiling(for: [8, 8, 8])
        XCTAssertEqual(ceiling?.upperTargetReps, [10, 10, 10])
        XCTAssertEqual(ceiling?.weightIncreaseAmount, 5)
    }

    func testSetCeilingTwiceReplacesRatherThanStacks() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [12, 12, 12], weightIncreaseAmount: 10)
        XCTAssertEqual(def.repSchemeCeilings.count, 1, "the first ceiling should be replaced, not left behind")
        XCTAssertEqual(def.ceiling(for: [8, 8, 8])?.upperTargetReps, [12, 12, 12])
    }

    /// Two different rep schemes on the same exercise get independent
    /// ceilings — confirms the lookup is keyed by the reps array, not just
    /// "this exercise has a ceiling somewhere."
    func testDifferentRepSchemesOnSameExerciseHaveIndependentCeilings() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8], [5, 5, 5, 3, 3, 3]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        XCTAssertEqual(def.ceiling(for: [8, 8, 8])?.upperTargetReps, [10, 10, 10])
        XCTAssertNil(def.ceiling(for: [5, 5, 5, 3, 3, 3]), "a different scheme's ceiling was never set")
    }

    func testClearCeilingRemovesItAndIsANoOpIfNeverSet() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        def.clearCeiling(for: [8, 8, 8])
        XCTAssertNil(def.ceiling(for: [8, 8, 8]))
        def.clearCeiling(for: [8, 8, 8]) // no-op, shouldn't crash
        XCTAssertTrue(def.repSchemeCeilings.isEmpty)
    }

    /// Deleting a repScheme must also drop its ceiling — otherwise it's
    /// orphaned (a ceiling entry for a reps array that's no longer a saved
    /// set at all).
    func testRemoveRepSchemeAlsoRemovesItsCeiling() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        def.removeRepScheme([8, 8, 8])
        XCTAssertFalse(def.repSchemes.contains([8, 8, 8]))
        XCTAssertNil(def.ceiling(for: [8, 8, 8]))
        XCTAssertTrue(def.repSchemeCeilings.isEmpty)
    }

    /// Removing one repScheme leaves an unrelated one's ceiling untouched.
    func testRemoveRepSchemeLeavesOtherCeilingsAlone() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8], [5, 5, 5, 3, 3, 3]])
        def.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        def.setCeiling(for: [5, 5, 5, 3, 3, 3], upperTargetReps: [8, 8, 8, 5, 5, 5], weightIncreaseAmount: 10)
        def.removeRepScheme([8, 8, 8])
        XCTAssertNil(def.ceiling(for: [8, 8, 8]))
        XCTAssertEqual(def.ceiling(for: [5, 5, 5, 3, 3, 3])?.weightIncreaseAmount, 10)
    }
}
