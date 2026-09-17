//
//  SetWeightLabelTests.swift
//  TheJymTests
//
//  Covers Formatters.setWeightLabel — the "total (added)" display format
//  for a logged bodyweight set, shared by History, the Pace Calculator,
//  Previous Workouts, and the Workout Recap.
//
//  The rule this format exists to preserve: the total always comes from
//  SetLog.weight, which is bodyweightAtLog + addedWeight FROZEN at log
//  time. A historical set must keep showing the bodyweight it was actually
//  performed at, never a re-resolution against today's weigh-in.
//

import XCTest
import SwiftData
@testable import TheJym

final class SetWeightLabelTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Non-bodyweight

    @MainActor
    func testANormalSetShowsAPlainNumber() {
        let set = SetLog(index: 0, weight: 135, reps: 8)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: false), "135")
    }

    /// The isBodyweight flag comes from the LOG, not the set — a set that
    /// happens to carry bodyweight fields on a non-bodyweight log still
    /// renders plainly.
    @MainActor
    func testNonBodyweightIgnoresAnyStrayBodyweightFields() {
        let set = SetLog(index: 0, weight: 209, reps: 8, addedWeight: 30, bodyweightAtLog: 179)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: false), "209")
    }

    // MARK: - Bodyweight with added load

    @MainActor
    func testBodyweightWithAddedLoadShowsTotalThenAddedInParentheses() {
        let set = SetLog(index: 0, weight: 209, reps: 8, addedWeight: 30, bodyweightAtLog: 179)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: true), "209 (30)")
    }

    /// The reported example: 180 lb bodyweight with 20/25/30 added.
    @MainActor
    func testTheReportedExampleRendersAsSpecified() {
        let labels = [20.0, 25.0, 30.0].enumerated().map { i, added in
            Formatters.setWeightLabel(
                SetLog(index: i, weight: 180 + added, reps: 8, addedWeight: added, bodyweightAtLog: 180),
                isBodyweight: true)
        }
        XCTAssertEqual(labels, ["200 (20)", "205 (25)", "210 (30)"])
    }

    /// Fractional added weight trims the same way every other weight on the
    /// page does — no trailing ".0".
    @MainActor
    func testFractionalWeightsAreTrimmedNotPadded() {
        let set = SetLog(index: 0, weight: 181.5, reps: 8, addedWeight: 2.5, bodyweightAtLog: 179)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: true), "181.5 (2.5)")
    }

    // MARK: - Bodyweight with no added load

    /// The common case for pull-ups/planks/leg raises — the parenthetical
    /// exists to surface added load, so "(0)" would be noise on hundreds of
    /// rows.
    @MainActor
    func testZeroAddedShowsTheBareTotal() {
        let set = SetLog(index: 0, weight: 177, reps: 12, addedWeight: 0, bodyweightAtLog: 177)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: true), "177")
    }

    // MARK: - Frozen bodyweight, never re-resolved

    /// Two sets at the same added load but different bodyweights render
    /// different totals — each against the weigh-in it was performed at.
    @MainActor
    func testEachSetUsesItsOwnFrozenBodyweight() {
        let older = SetLog(index: 0, weight: 195, reps: 8, addedWeight: 20, bodyweightAtLog: 175)
        let newer = SetLog(index: 0, weight: 199, reps: 8, addedWeight: 20, bodyweightAtLog: 179)
        XCTAssertEqual(Formatters.setWeightLabel(older, isBodyweight: true), "195 (20)")
        XCTAssertEqual(Formatters.setWeightLabel(newer, isBodyweight: true), "199 (20)")
    }

    // MARK: - Missing bodyweightAtLog (older / imported data)

    /// With no bodyweight on record, `weight` silently resolved against 0 —
    /// so it's really just the added load, and presenting it as a "total"
    /// would overstate what's known. Falls back to the added weight alone.
    @MainActor
    func testNilBodyweightAtLogFallsBackToTheAddedWeightAlone() {
        let set = SetLog(index: 0, weight: 25, reps: 8, addedWeight: 25, bodyweightAtLog: nil)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: true), "25")
    }

    /// Neither field on record (the oldest imported shape) falls back to
    /// the stored weight rather than rendering an empty or zero cell.
    @MainActor
    func testNilBodyweightAndNilAddedFallsBackToTheStoredWeight() {
        let set = SetLog(index: 0, weight: 42, reps: 8)
        XCTAssertEqual(Formatters.setWeightLabel(set, isBodyweight: true), "42")
    }

    // MARK: - The shared call sites agree

    /// PaceEngine.weightLabels (Pace Calculator / Previous Workouts / full
    /// history) must produce the same strings the History tab does — they
    /// go through the same formatter, and a test here is what keeps a
    /// future change to one from silently diverging.
    @MainActor
    func testPaceEngineWeightLabelsUseTheSameFormat() {
        let context = makeContext()
        let session = WorkoutSession(date: .now, dayLabel: "Pull Day", cycleNumber: 1)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Wide-Grip Pull-Ups", targetReps: [8, 8], order: 0, isBodyweight: true)
        log.session = session
        context.insert(log)
        for (i, added) in [20.0, 0.0].enumerated() {
            let set = SetLog(index: i, weight: 179 + added, reps: 8, addedWeight: added, bodyweightAtLog: 179)
            set.exerciseLog = log
            context.insert(set)
        }

        XCTAssertEqual(PaceEngine.weightLabels(for: log), ["199 (20)", "179"])
    }

    /// Display formatting must not disturb the stored total that every
    /// progression/Big Lift/Est. 1RM calculation reads.
    @MainActor
    func testFormattingDoesNotAlterTheStoredResolvedTotal() {
        let set = SetLog(index: 0, weight: 209, reps: 8, addedWeight: 30, bodyweightAtLog: 179)
        _ = Formatters.setWeightLabel(set, isBodyweight: true)
        XCTAssertEqual(set.weight, 209, "the resolved total is what the math reads — untouched by display")
        XCTAssertEqual(set.addedWeight, 30)
        XCTAssertEqual(set.bodyweightAtLog, 179)
    }
}
