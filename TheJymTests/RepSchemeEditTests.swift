//
//  RepSchemeEditTests.swift
//  TheJymTests
//
//  ExerciseDef.updateRepScheme(from:to:newCeiling:) and RepSchemeImpact.
//
//  The load-bearing case is ORPHANED CEILINGS. A ceiling is keyed on the
//  reps array (`ceiling(for:)` matches `$0.reps == reps`), so editing a
//  scheme without moving its ceiling strands it — and a stranded ceiling is
//  not merely invisible, it stays ACTIVE: every PlannedExercise keeps its
//  own copy of the OLD reps, and WorkoutLogView.ceiling(for:) resolves by
//  pe.targetReps, so the ceiling no screen can show goes on replacing the
//  AI weight suggestion forever, with removeRepScheme unable to reach it.
//
//  That is the failure nobody would notice in use, so it is asserted from
//  both directions: nothing remains under the old array, and nothing
//  unexpected appears under the new one.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class RepSchemeEditTests: XCTestCase {

    private func def(_ schemes: [[Int]] = [[6, 6, 6]]) -> ExerciseDef {
        ExerciseDef(name: "Safety Squats", repSchemes: schemes)
    }

    // MARK: - The orphan case

    /// Set count CHANGES and the ceiling is dropped: nothing may remain
    /// under the old array.
    func testEditChangingSetCountLeavesNoCeilingUnderTheOldReps() {
        let d = def()
        d.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        XCTAssertTrue(d.updateRepScheme(from: [6, 6, 6], to: [6, 6, 6, 6], newCeiling: nil))

        XCTAssertNil(d.ceiling(for: [6, 6, 6]),
                     "a ceiling left under the old array is invisible but still ACTIVE")
        XCTAssertNil(d.ceiling(for: [6, 6, 6, 6]))
        XCTAssertTrue(d.repSchemeCeilings.isEmpty,
                      "no ceiling entry may survive anywhere, under any key")
        XCTAssertEqual(d.repSchemes, [[6, 6, 6, 6]])
    }

    /// Set count is UNCHANGED and the ceiling rides across: it must move,
    /// not be copied — the old array still has to resolve to nothing.
    func testEditKeepingSetCountMovesTheCeilingRatherThanCopyingIt() {
        let d = def()
        d.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        let carried = d.ceiling(for: [6, 6, 6])!
        XCTAssertTrue(d.updateRepScheme(from: [6, 6, 6], to: [7, 7, 7], newCeiling: carried))

        XCTAssertNil(d.ceiling(for: [6, 6, 6]), "the old array must resolve to nothing")
        XCTAssertEqual(d.ceiling(for: [7, 7, 7])?.upperTargetReps, [8, 8, 8])
        XCTAssertEqual(d.ceiling(for: [7, 7, 7])?.weightIncreaseAmount, 5)
        XCTAssertEqual(d.repSchemeCeilings.count, 1, "moved, not duplicated")
    }

    /// The general invariant, swept across every edit shape: after ANY
    /// successful edit, the old array resolves to nothing and no ceiling
    /// entry references a scheme that isn't saved.
    func testNoEditEverLeavesACeilingMatchingNoSavedScheme() {
        let shapes: [(from: [Int], to: [Int], keepCeiling: Bool)] = [
            ([6, 6, 6], [6, 6, 6, 6], false),   // more sets, dropped
            ([6, 6, 6], [6, 6], false),         // fewer sets, dropped
            ([6, 6, 6], [8, 8, 8], true),       // same count, carried
            ([6, 6, 6], [6, 6, 6], true),       // no-op edit, carried
            ([6, 6, 6], [5], false),            // collapse to one set
        ]
        for shape in shapes {
            let d = def()
            d.setCeiling(for: [6, 6, 6], upperTargetReps: [9, 9, 9], weightIncreaseAmount: 10)
            let carried = shape.keepCeiling ? d.ceiling(for: [6, 6, 6]) : nil
            XCTAssertTrue(d.updateRepScheme(from: shape.from, to: shape.to, newCeiling: carried),
                          "\(shape) should apply")

            if shape.to != shape.from {
                XCTAssertNil(d.ceiling(for: shape.from),
                             "\(shape): old array still resolves to a ceiling")
            }
            for c in d.repSchemeCeilings {
                XCTAssertTrue(d.repSchemes.contains(c.reps),
                              "\(shape): ceiling \(c.reps) matches no saved scheme — orphaned")
            }
        }
    }

    /// Editing the same scheme twice must not accumulate ceiling entries.
    func testRepeatedEditsDoNotAccumulateCeilings() {
        let d = def()
        d.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        d.updateRepScheme(from: [6, 6, 6], to: [7, 7, 7], newCeiling: d.ceiling(for: [6, 6, 6]))
        d.updateRepScheme(from: [7, 7, 7], to: [8, 8, 8], newCeiling: d.ceiling(for: [7, 7, 7]))
        d.updateRepScheme(from: [8, 8, 8], to: [9, 9, 9], newCeiling: d.ceiling(for: [8, 8, 8]))
        XCTAssertEqual(d.repSchemeCeilings.count, 1)
        XCTAssertEqual(d.repSchemes, [[9, 9, 9]])
        XCTAssertNil(d.ceiling(for: [6, 6, 6]))
        XCTAssertNil(d.ceiling(for: [7, 7, 7]))
        XCTAssertNil(d.ceiling(for: [8, 8, 8]))
    }

    // MARK: - Ordering

    /// Replaced in place, not removed-and-appended: AddExerciseToDayView
    /// seeds a brand-new slot from repSchemes.first, so reordering here
    /// would silently change what a new exercise defaults to.
    func testEditKeepsTheSchemesPositionSoFirstDoesNotChange() {
        let d = def([[5, 5, 5], [6, 6, 6], [8, 8]])
        d.updateRepScheme(from: [6, 6, 6], to: [7, 7, 7], newCeiling: nil)
        XCTAssertEqual(d.repSchemes, [[5, 5, 5], [7, 7, 7], [8, 8]])

        d.updateRepScheme(from: [5, 5, 5], to: [4, 4, 4], newCeiling: nil)
        XCTAssertEqual(d.repSchemes.first, [4, 4, 4], "the first scheme stays first")
    }

    // MARK: - Refusals

    func testEditingAnUnsavedSchemeIsANoOp() {
        let d = def()
        XCTAssertFalse(d.updateRepScheme(from: [1, 2, 3], to: [4, 4, 4], newCeiling: nil))
        XCTAssertEqual(d.repSchemes, [[6, 6, 6]])
    }

    func testEditingToAnEmptySchemeIsRefused() {
        let d = def()
        XCTAssertFalse(d.updateRepScheme(from: [6, 6, 6], to: [], newCeiling: nil))
        XCTAssertEqual(d.repSchemes, [[6, 6, 6]])
    }

    /// Renaming one scheme onto another would merge two entries into one and
    /// silently drop whichever ceiling lost — refused instead.
    func testEditingOntoAnExistingSchemeIsRefused() {
        let d = def([[6, 6, 6], [8, 8, 8]])
        d.setCeiling(for: [8, 8, 8], upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5)
        XCTAssertFalse(d.updateRepScheme(from: [6, 6, 6], to: [8, 8, 8], newCeiling: nil))
        XCTAssertEqual(d.repSchemes, [[6, 6, 6], [8, 8, 8]])
        XCTAssertEqual(d.ceiling(for: [8, 8, 8])?.upperTargetReps, [10, 10, 10],
                       "the existing scheme's ceiling survives the refused merge")
    }

    /// removeRepScheme set the precedent this follows; assert it still holds
    /// so the two can't drift apart.
    func testRemoveRepSchemeStillTakesTheCeilingWithIt() {
        let d = def()
        d.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        d.removeRepScheme([6, 6, 6])
        XCTAssertTrue(d.repSchemes.isEmpty)
        XCTAssertTrue(d.repSchemeCeilings.isEmpty)
        XCTAssertNil(d.ceiling(for: [6, 6, 6]))
    }
}
