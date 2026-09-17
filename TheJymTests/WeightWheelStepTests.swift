//
//  WeightWheelStepTests.swift
//  TheJymTests
//
//  Covers the in-workout weight wheels' option lists: their step must be
//  the smallest ACHIEVABLE weight change for the exercise's equipment
//  (smallest plate x loadableSides for a plate-loaded bar), not merely the
//  smallest plate owned.
//
//  weightStep/weightValues/addedWeightValues are private to
//  ExercisePageView, so these tests exercise the same arithmetic against
//  the real Bar model rather than reaching into the view. The intent is to
//  pin the RULE — if the view's formula is ever changed to disagree with
//  this, the mismatch is the bug these describe.
//

import XCTest
import SwiftData
@testable import TheJym

final class WeightWheelStepTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Bar.self, ExerciseDef.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Mirrors ExercisePageView.weightStep exactly.
    private func weightStep(bar: Bar?, plateSizes: [Double], dumbbellIncrement: Double) -> Double {
        guard let bar else { return 2.5 }
        if bar.isDumbbell { return dumbbellIncrement }
        guard let smallestPlate = plateSizes.min() else { return 2.5 }
        return smallestPlate * Double(max(1, bar.loadableSides))
    }

    /// Mirrors ExercisePageView.addedWeightStep exactly.
    private func addedWeightStep(plateSizes: [Double]) -> Double {
        plateSizes.min() ?? 2.5
    }

    // MARK: - The reported case

    /// The bug: smallest plate 1.25 on a two-sided bar was offering 1.25
    /// steps, but a plate goes on both sides at once, so 2.5 is the finest
    /// real jump.
    @MainActor
    func testTwoSidedBarDoublesTheSmallestPlate() {
        let context = makeContext()
        let bar = Bar(name: "Barbell", weight: 45, loadableSides: 2)
        context.insert(bar)
        XCTAssertEqual(weightStep(bar: bar, plateSizes: [45, 25, 10, 5, 2.5, 1.25],
                                  dumbbellIncrement: 5), 2.5)
    }

    /// A landmine genuinely can move in 1.25 — the multiplier must respect
    /// loadableSides rather than assuming two.
    @MainActor
    func testSingleSidedBarUsesTheSmallestPlateAsIs() {
        let context = makeContext()
        let bar = Bar(name: "Landmine", weight: 25, loadableSides: 1)
        context.insert(bar)
        XCTAssertEqual(weightStep(bar: bar, plateSizes: [45, 25, 10, 5, 2.5, 1.25],
                                  dumbbellIncrement: 5), 1.25)
    }

    /// Without 1.25s owned, a two-sided bar steps by 5.
    @MainActor
    func testTwoSidedBarWithoutFractionalPlatesStepsByFive() {
        let context = makeContext()
        let bar = Bar(name: "Barbell", weight: 45, loadableSides: 2)
        context.insert(bar)
        XCTAssertEqual(weightStep(bar: bar, plateSizes: [45, 25, 10, 5, 2.5],
                                  dumbbellIncrement: 5), 5)
    }

    // MARK: - Fallbacks

    func testNoBarAssignedFallsBackToTwoAndAHalf() {
        XCTAssertEqual(weightStep(bar: nil, plateSizes: [1.25], dumbbellIncrement: 5), 2.5)
    }

    /// A dumbbell's own increment, NOT multiplied — plate math and
    /// loadableSides are both meaningless for a dumbbell set.
    @MainActor
    func testDumbbellUsesItsOwnIncrementUnmultiplied() {
        let context = makeContext()
        let db = Bar(name: "Dumbbells", weight: 0, isDumbbell: true,
                     dumbbellWeights: [10, 15, 20], loadableSides: 2)
        context.insert(db)
        XCTAssertEqual(weightStep(bar: db, plateSizes: [1.25], dumbbellIncrement: 5), 5,
                       "a dumbbell set must not get the x2 sides multiplier")
    }

    /// An unconfigured inventory must not silently become a 5 lb step via
    /// 2.5 x 2 sides.
    @MainActor
    func testEmptyPlateInventoryFallsBackToTwoAndAHalfTotalNotDoubled() {
        let context = makeContext()
        let bar = Bar(name: "Barbell", weight: 45, loadableSides: 2)
        context.insert(bar)
        XCTAssertEqual(weightStep(bar: bar, plateSizes: [], dumbbellIncrement: 5), 2.5)
    }

    /// A machine modelled as a single-sided Bar needs no special case.
    @MainActor
    func testMachineModelledAsSingleSidedBarBehavesAsSuch() {
        let context = makeContext()
        let machine = Bar(name: "Cable Stack", weight: 0, loadableSides: 1)
        context.insert(machine)
        XCTAssertEqual(weightStep(bar: machine, plateSizes: [5, 2.5], dumbbellIncrement: 5), 2.5)
    }

    /// Defensive: loadableSides is a plain stored Int, so a 0 from
    /// imported/edited data must not collapse the step to 0 and produce an
    /// infinite stride.
    @MainActor
    func testZeroLoadableSidesIsTreatedAsOneRatherThanCollapsingTheStep() {
        let context = makeContext()
        let bar = Bar(name: "Odd", weight: 45, loadableSides: 0)
        context.insert(bar)
        let step = weightStep(bar: bar, plateSizes: [2.5], dumbbellIncrement: 5)
        XCTAssertEqual(step, 2.5)
        XCTAssertGreaterThan(step, 0, "a zero step would make stride(by:) never terminate")
    }

    // MARK: - Bodyweight added load

    /// A belt or vest takes plates one at a time — no paired sides — so the
    /// smallest plate owned IS the increment, and it's finer than the flat
    /// 2.5 this replaced.
    func testAddedWeightUsesTheSmallestPlateWithNoSidesMultiplier() {
        XCTAssertEqual(addedWeightStep(plateSizes: [45, 25, 10, 5, 2.5, 1.25]), 1.25)
    }

    func testAddedWeightFallsBackToTwoAndAHalfWithNoInventory() {
        XCTAssertEqual(addedWeightStep(plateSizes: []), 2.5)
    }

    // MARK: - The resulting option lists

    /// Every offered value must be a whole multiple of the step — that's
    /// what "achievable" means here.
    func testEveryOfferedValueIsAWholeMultipleOfTheStep() {
        for step in [1.25, 2.5, 5.0] {
            let values = Array(stride(from: 0.0, through: 600.0, by: step))
            for v in values {
                let multiples = v / step
                XCTAssertEqual(multiples, multiples.rounded(), accuracy: 0.0001,
                               "\(v) is not a multiple of \(step)")
            }
        }
    }

    /// The range is unchanged by this fix — only which values fall inside
    /// it. A coarser step means fewer options over the same 0...600.
    func testRangeIsUnchangedWhileTheStepGetsCoarser() {
        let fine = Array(stride(from: 0.0, through: 600.0, by: 1.25))
        let coarse = Array(stride(from: 0.0, through: 600.0, by: 2.5))
        XCTAssertEqual(fine.first, 0)
        XCTAssertEqual(coarse.first, 0)
        XCTAssertEqual(fine.last, 600)
        XCTAssertEqual(coarse.last, 600)
        XCTAssertLessThan(coarse.count, fine.count)
        // And the coarse list is a strict subset of the fine one.
        XCTAssertTrue(coarse.allSatisfy { c in fine.contains { abs($0 - c) < 0.0001 } })
    }

    // MARK: - nearestValue snaps for DISPLAY without mutating

    /// nearestValue is used only in the Picker binding's `get`, which is a
    /// pure function — it reports which wheel row to highlight and writes
    /// nothing. An off-step weight therefore displays snapped while the
    /// stored text stays exactly as entered.
    func testNearestValueIsAPureReadThatLeavesTheSourceUntouched() {
        // Same implementation as ExercisePageView.nearestValue.
        func nearestValue(_ target: Double, in values: [Double]) -> Double {
            values.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
        }
        var draft = WorkoutLogView.SetDraft(weightText: "181", repsText: "8")
        let values = Array(stride(from: 0.0, through: 600.0, by: 2.5))

        let displayed = nearestValue(draft.weight ?? 0, in: values)
        XCTAssertEqual(displayed, 180, "the wheel highlights the nearest offered row")
        XCTAssertEqual(draft.weightText, "181", "reading it must not rewrite the stored value")
        XCTAssertEqual(draft.weight, 181)

        // Still 181 after repeated reads — no accumulating drift.
        _ = nearestValue(draft.weight ?? 0, in: values)
        _ = nearestValue(draft.weight ?? 0, in: values)
        XCTAssertEqual(draft.weightText, "181")

        // And an off-step value under the NEW coarser step behaves the same
        // way a mid-step value already did under the old finer one.
        draft.weightText = "181.25"
        XCTAssertEqual(nearestValue(draft.weight ?? 0, in: values), 180)
        XCTAssertEqual(draft.weightText, "181.25")
    }
}
