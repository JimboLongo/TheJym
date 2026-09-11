//
//  WorkoutRecapVerdictTests.swift
//  TheJymTests
//
//  Covers WorkoutRecapView.verdict(for:)/initialAdjustment(for:) — the
//  exhaustive three-state classification (Missed Target / Hit Target but
//  not Ceiling / Hit Ceiling) that replaced the old ceiling-only and
//  missed-only dropdowns, and the wheel's per-state initial position.
//  Reuses ExerciseLog.missedTarget (itself from missedAnyTarget) and
//  ProgressionEngine.qualifiesForUpperTarget directly rather than
//  reimplementing either check — these tests verify the BUCKETING, not
//  those checks' own logic (already covered elsewhere).
//

import XCTest
import SwiftData
@testable import TheJym

final class WorkoutRecapVerdictTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// `missedTarget` sets `log.missedTarget` directly (mirroring how
    /// finishWorkout already computes it via missedAnyTarget before a
    /// RecapEntry is ever built — verdict(for:) reuses that stored value
    /// rather than recomputing it). `actualReps`, separately, is what
    /// `qualifiesForUpperTarget` itself checks against `upperTargetReps` —
    /// the two are independent knobs here specifically so a test can put an
    /// entry in the "hit the base target but not the ceiling" state (reps
    /// high enough to not miss, not high enough to qualify).
    @MainActor
    private func makeEntry(missedTarget: Bool, actualReps: Int, upperTargetReps: [Int]?,
                           configuredWeightIncreaseAmount: Double?,
                           context: ModelContext) -> WorkoutLogView.RecapEntry {
        let session = WorkoutSession(dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        log.session = session
        log.missedTarget = missedTarget
        context.insert(log)
        for i in 0..<3 {
            let set = SetLog(index: i, weight: 135, reps: actualReps)
            set.exerciseLog = log
            context.insert(set)
        }
        return WorkoutLogView.RecapEntry(exerciseName: "Bench Press", log: log, currentWeights: [135, 135, 135],
                                         isBodyweight: false, actualReps: Array(repeating: actualReps, count: 3),
                                         targetReps: [8, 8, 8], upperTargetReps: upperTargetReps,
                                         configuredWeightIncreaseAmount: configuredWeightIncreaseAmount)
    }

    // MARK: - verdict(for:) bucketing

    @MainActor
    func testMissedTargetTakesPrecedenceRegardlessOfCeiling() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: true, actualReps: 5, upperTargetReps: [10, 10, 10],
                              configuredWeightIncreaseAmount: 5, context: context)
        XCTAssertEqual(WorkoutRecapView.verdict(for: entry), .missedTarget)
    }

    /// No ceiling configured at all — buckets into hitTargetMissedCeiling,
    /// not a distinct 4th state.
    @MainActor
    func testHitTargetWithNoCeilingConfiguredBucketsAsHitTargetMissedCeiling() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: false, actualReps: 8, upperTargetReps: nil,
                              configuredWeightIncreaseAmount: nil, context: context)
        XCTAssertEqual(WorkoutRecapView.verdict(for: entry), .hitTargetMissedCeiling)
    }

    /// A ceiling IS configured, but this session didn't fully hit it —
    /// same bucket as "no ceiling at all".
    @MainActor
    func testHitTargetButNotCeilingBucketsAsHitTargetMissedCeiling() {
        let context = makeContext()
        // reps=8 hits the base target [8,8,8] but not the ceiling [10,10,10].
        let entry = makeEntry(missedTarget: false, actualReps: 8, upperTargetReps: [10, 10, 10],
                              configuredWeightIncreaseAmount: 5, context: context)
        XCTAssertEqual(WorkoutRecapView.verdict(for: entry), .hitTargetMissedCeiling)
    }

    @MainActor
    func testHitCeilingBucketsAsHitCeiling() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: false, actualReps: 8, upperTargetReps: [8, 8, 8],
                              configuredWeightIncreaseAmount: 5, context: context)
        XCTAssertEqual(WorkoutRecapView.verdict(for: entry), .hitCeiling)
    }

    // MARK: - initialAdjustment(for:) — wheel seeding per verdict

    @MainActor
    func testMissedTargetSeedsNegativeOfConfiguredAmount() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: true, actualReps: 5, upperTargetReps: [10, 10, 10],
                              configuredWeightIncreaseAmount: 5, context: context)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: entry), -5)
    }

    /// No configured amount to negate — falls back to No Change (0), same
    /// reasoning the decrease dropdown had (nothing to default to).
    @MainActor
    func testMissedTargetWithNoConfiguredAmountSeedsNoChange() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: true, actualReps: 5, upperTargetReps: nil,
                              configuredWeightIncreaseAmount: nil, context: context)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: entry), 0)
    }

    @MainActor
    func testHitTargetMissedCeilingAlwaysSeedsNoChange() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: false, actualReps: 8, upperTargetReps: [10, 10, 10],
                              configuredWeightIncreaseAmount: 5, context: context)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: entry), 0)
    }

    @MainActor
    func testHitCeilingSeedsConfiguredAmountAsIs() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: false, actualReps: 8, upperTargetReps: [8, 8, 8],
                              configuredWeightIncreaseAmount: 10, context: context)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: entry), 10)
    }

    /// An out-of-range configured amount (predates UpperTargetPickerSheet's
    /// 3-choice validation, or an import) rounds to the nearest real wheel
    /// choice rather than landing off the wheel.
    @MainActor
    func testHitCeilingWithOutOfRangeConfiguredAmountRoundsToNearestChoice() {
        let context = makeContext()
        let entry = makeEntry(missedTarget: false, actualReps: 8, upperTargetReps: [8, 8, 8],
                              configuredWeightIncreaseAmount: 6, context: context)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: entry), 5, "6 rounds to the nearest choice, 5, not 10")
    }
}
