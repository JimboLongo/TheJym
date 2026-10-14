//
//  PlannedExerciseCeilingTests.swift
//  TheJymTests
//
//  PlannedExercise.ceiling(in:) — the single resolution now shared by
//  WorkoutLogView's log-time lookup, PhaseEditView's row and PhasesView's
//  cycle row. It was three copies of a two-step lookup whose second step
//  matches on an array an edit can change out from under it.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class PlannedExerciseCeilingTests: XCTestCase {

    private func slot(_ name: String, _ reps: [Int],
                      goal: GoalType = .fixedSets) -> PlannedExercise {
        PlannedExercise(order: 0, exerciseName: name, targetReps: reps,
                        isBodyweight: false, goalType: goal)
    }

    private func def(_ name: String, _ schemes: [[Int]],
                     ceilingFor: [Int]? = nil) -> ExerciseDef {
        let d = ExerciseDef(name: name, repSchemes: schemes)
        if let ceilingFor {
            d.setCeiling(for: ceilingFor, upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        }
        return d
    }

    func testResolvesByNameThenTargetReps() {
        let d = def("Safety Squats", [[6, 6, 6]], ceilingFor: [6, 6, 6])
        let pe = slot("Safety Squats", [6, 6, 6])
        XCTAssertEqual(pe.ceiling(in: [d])?.upperTargetReps, [8, 8, 8])
        XCTAssertEqual(pe.ceiling(in: [d])?.weightIncreaseAmount, 5)
    }

    func testNilWhenTheExerciseIsNotInTheLibrary() {
        let d = def("Bench Press", [[6, 6, 6]], ceilingFor: [6, 6, 6])
        XCTAssertNil(slot("Safety Squats", [6, 6, 6]).ceiling(in: [d]))
        XCTAssertNil(slot("Safety Squats", [6, 6, 6]).ceiling(in: []))
    }

    /// The documented miss: an import or manual edit can leave a slot whose
    /// reps match no saved scheme. It must resolve to nothing, not crash
    /// and not borrow a sibling scheme's ceiling.
    func testNilWhenTheSlotsRepsMatchNoSavedScheme() {
        let d = def("Safety Squats", [[6, 6, 6]], ceilingFor: [6, 6, 6])
        XCTAssertNil(slot("Safety Squats", [5, 5, 5, 3, 3, 3]).ceiling(in: [d]))
        XCTAssertNil(slot("Safety Squats", []).ceiling(in: [d]))
    }

    /// A rep-total slot has no rep scheme to hang a ceiling on. Its
    /// targetReps is empty, so without the goal-type guard it would be
    /// asking for the ceiling of [].
    func testNilForARepTotalSlot() {
        let d = def("Safety Squats", [[6, 6, 6]], ceilingFor: [6, 6, 6])
        let pe = slot("Safety Squats", [], goal: .repTotal(target: 40))
        XCTAssertNil(pe.ceiling(in: [d]))
    }

    func testNilWhenTheSchemeExistsButHasNoCeiling() {
        let d = def("Safety Squats", [[6, 6, 6]])
        XCTAssertNil(slot("Safety Squats", [6, 6, 6]).ceiling(in: [d]))
    }

    /// Two slots of the same exercise on different schemes resolve
    /// independently — the lookup is per (name, reps), not per exercise.
    func testSiblingSchemesResolveIndependently() {
        let d = ExerciseDef(name: "Safety Squats", repSchemes: [[6, 6, 6], [10, 10]])
        d.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        XCTAssertEqual(slot("Safety Squats", [6, 6, 6]).ceiling(in: [d])?.upperTargetReps, [8, 8, 8])
        XCTAssertNil(slot("Safety Squats", [10, 10]).ceiling(in: [d]))
    }

    /// An edit that moves the scheme must move what this resolves to —
    /// the orphan case, reached through the shared lookup rather than
    /// ExerciseDef's own.
    func testFollowsAnEditThatMovesTheScheme() {
        let d = def("Safety Squats", [[6, 6, 6]], ceilingFor: [6, 6, 6])
        let carried = d.ceiling(for: [6, 6, 6])
        d.updateRepScheme(from: [6, 6, 6], to: [7, 7, 7], newCeiling: carried)

        XCTAssertNil(slot("Safety Squats", [6, 6, 6]).ceiling(in: [d]),
                     "a slot left on the old reps must resolve to nothing")
        XCTAssertEqual(slot("Safety Squats", [7, 7, 7]).ceiling(in: [d])?.upperTargetReps, [8, 8, 8])
    }

    /// The scope sentence shown when changing a ceiling from a per-slot row.
    func testCeilingScopeWarningLeadsWithGlobalScope() {
        let d = def("Safety Squats", [[6, 6, 6]], ceilingFor: [6, 6, 6])
        let impact = RepSchemeImpact(defName: d.name, reps: [6, 6, 6],
                                     plannedUsages: ["Phase 1 · Lower Day 1",
                                                     "Phase 2 · Lower Day 1"],
                                     loggedCount: 12, ceiling: d.ceiling(for: [6, 6, 6]))
        let text = impact.ceilingScopeWarning
        XCTAssertTrue(text.hasPrefix("This set is saved on Safety Squats in Exercises."), text)
        XCTAssertTrue(text.contains("every phase that uses it"), text)
        XCTAssertTrue(text.contains("Phase 2 · Lower Day 1"), text)
        // Changing a ceiling orphans nothing and moves no history, so the
        // edit/delete lines would be noise here.
        XCTAssertFalse(text.contains("logged workout"), text)
        XCTAssertFalse(text.contains("keep training"), text)
    }

    func testCeilingScopeWarningOmitsUsagesWhenThisIsTheOnlySlot() {
        let impact = RepSchemeImpact(defName: "Safety Squats", reps: [6, 6, 6],
                                     plannedUsages: ["Phase 2 · Lower Day 1"],
                                     loggedCount: 0, ceiling: nil)
        XCTAssertFalse(impact.ceilingScopeWarning.contains("Also used by"))
    }
}
