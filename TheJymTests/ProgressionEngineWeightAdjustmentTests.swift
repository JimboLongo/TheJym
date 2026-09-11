//
//  ProgressionEngineWeightAdjustmentTests.swift
//  TheJymTests
//
//  Covers ExerciseLog.selectedWeightAdjustment — the single per-session
//  weight-adjustment wheel choice (WorkoutRecapView, shown for every
//  fixedSets exercise regardless of verdict) that replaced the separate
//  selectedWeightIncreaseAmount/selectedWeightDecreaseAmount fields. Unlike
//  those two, this one field applies UNCONDITIONALLY whenever set — not
//  gated by qualifiesForUpperTarget/missedAnyTarget — since the wheel
//  itself isn't restricted to the direction its own verdict suggested.
//

import XCTest
import SwiftData
@testable import TheJym

final class ProgressionEngineWeightAdjustmentTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    @discardableResult
    private func log(_ exerciseName: String, targetReps: [Int], actualReps: [Int], actualWeights: [Double],
                     daysAgo: Int, context: ModelContext) -> ExerciseLog {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let exerciseLog = ExerciseLog(exerciseName: exerciseName, targetReps: targetReps, order: 0)
        exerciseLog.session = session
        context.insert(exerciseLog)
        for (i, w) in actualWeights.enumerated() {
            let set = SetLog(index: i, weight: w, reps: actualReps[i])
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        return exerciseLog
    }

    // MARK: - General path (suggestNextWeights) — no ceiling involved

    @MainActor
    func testSuggestNextWeightsAppliesPersistedAdjustmentOverridingTheAlgorithm() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightAdjustment = -5
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [8, 8, 8], history: logs, aggressiveness: .aggressive, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [130, 130, 130], "the persisted adjustment (-5) wins even though every set beat target and aggressive would otherwise jump")
    }

    /// An explicit "No Change" (0) overrides the automatic ~5%-backoff
    /// branch (avgSurplus <= -2) that would otherwise trigger.
    @MainActor
    func testSuggestNextWeightsExplicitNoChangeOverridesTheAutomaticBackoff() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [5, 5, 5],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightAdjustment = 0
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [8, 8, 8], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [135, 135, 135], "explicit No Change (0) must hold, not fall back to the automatic backoff")
    }

    /// nil (never decided — old data predating this field) falls through to
    /// the existing automatic backoff unchanged.
    @MainActor
    func testSuggestNextWeightsFallsBackToAutomaticBackoffWhenNoAdjustmentRecorded() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [5, 5, 5],
                        actualWeights: [100, 100, 100], daysAgo: 1, context: context)
        XCTAssertNil(entry.selectedWeightAdjustment)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [8, 8, 8], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [95, 95, 95], "unchanged: the pre-existing ~5% backoff (100 * 0.95, rounded to plate)")
    }

    // MARK: - Ceiling path (suggestNextWeightsForUpperTarget) — applies
    // unconditionally, regardless of qualifiesForUpperTarget

    @MainActor
    func testSuggestNextWeightsForUpperTargetAppliesPersistedDecreaseWhenNotQualified() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [7, 7, 7],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightAdjustment = -10
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [125, 125, 125])
    }

    /// The wheel isn't restricted by verdict — a DECREASE chosen for a
    /// session that actually QUALIFIED for its ceiling still applies,
    /// overriding the increase that would otherwise be automatic.
    @MainActor
    func testSuggestNextWeightsForUpperTargetAppliesPersistedDecreaseEvenWhenQualified() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightAdjustment = -5
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 10, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [130, 130, 130], "qualified, but the wheel's own -5 choice overrides the automatic +10")
    }

    /// nil (never decided) holds the weight when not qualified — unchanged
    /// from the pre-adjustment-field behavior.
    @MainActor
    func testSuggestNextWeightsForUpperTargetHoldsWhenNotQualifiedAndNoAdjustmentRecorded() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [7, 7, 7],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        XCTAssertNil(entry.selectedWeightAdjustment)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [135, 135, 135])
    }
}
