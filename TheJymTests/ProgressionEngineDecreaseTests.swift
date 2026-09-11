//
//  ProgressionEngineDecreaseTests.swift
//  TheJymTests
//
//  Covers ExerciseLog.selectedWeightDecreaseAmount — the per-session
//  weight-decrease choice (WorkoutRecapView's Picker, shown whenever a
//  session missed a target) and how it overrides both
//  suggestNextWeightsForUpperTarget's (ceiling path) and suggestNextWeights'
//  (general algorithmic path, including its own automatic ~5% backoff)
//  otherwise-computed suggestion for the NEXT session. Mirrors
//  ProgressionEngineUpperTargetTests' coverage of the sibling increase field.
//

import XCTest
import SwiftData
@testable import TheJym

final class ProgressionEngineDecreaseTests: XCTestCase {
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

    /// A persisted decrease choice overrides the algorithm's own suggestion
    /// entirely — even when the streak/aggressiveness logic would otherwise
    /// suggest holding or jumping.
    @MainActor
    func testSuggestNextWeightsAppliesPersistedDecreaseOverridingTheAlgorithm() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightDecreaseAmount = -5
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [8, 8, 8], history: logs, aggressiveness: .aggressive, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [130, 130, 130], "the persisted decrease (-5) wins even though every set beat target and aggressive would otherwise jump")
    }

    /// The persisted decrease also overrides the automatic ~5%-backoff
    /// branch (avgSurplus <= -2) — a decrease of 0 ("No Decrease") holds the
    /// weight instead of the automatic backoff kicking in.
    @MainActor
    func testSuggestNextWeightsExplicitNoDecreaseOverridesTheAutomaticBackoff() {
        let context = makeContext()
        // Missed by 3 reps on every set — would trigger the automatic ~5%
        // backoff on its own.
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [5, 5, 5],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightDecreaseAmount = 0
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [8, 8, 8], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [135, 135, 135], "explicit No Decrease (0) must hold, not fall back to the automatic backoff")
    }

    /// nil (never decided — old data, or a session that didn't miss) falls
    /// through to the existing automatic backoff unchanged.
    @MainActor
    func testSuggestNextWeightsFallsBackToAutomaticBackoffWhenNoDecreaseRecorded() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [5, 5, 5],
                        actualWeights: [100, 100, 100], daysAgo: 1, context: context)
        XCTAssertNil(entry.selectedWeightDecreaseAmount)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [8, 8, 8], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [95, 95, 95], "unchanged: the pre-existing ~5% backoff (100 * 0.95, rounded to plate)")
    }

    // MARK: - Ceiling path (suggestNextWeightsForUpperTarget)

    /// A persisted decrease choice applies when the session didn't qualify
    /// for its ceiling.
    @MainActor
    func testSuggestNextWeightsForUpperTargetAppliesPersistedDecreaseWhenNotQualified() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [7, 7, 7],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightDecreaseAmount = -10
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [125, 125, 125])
    }

    /// nil (never decided) holds the weight when not qualified — unchanged
    /// from the pre-decrease-feature behavior.
    @MainActor
    func testSuggestNextWeightsForUpperTargetHoldsWhenNotQualifiedAndNoDecreaseRecorded() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [7, 7, 7],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        XCTAssertNil(entry.selectedWeightDecreaseAmount)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [135, 135, 135])
    }

    /// A qualifying session's increase amount is unaffected by the decrease
    /// field's mere existence — they don't collide when both happen to be
    /// set on old/unrelated logs in the same history.
    @MainActor
    func testSuggestNextWeightsForUpperTargetIncreaseStillWinsWhenQualified() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightIncreaseAmount = 10
        entry.selectedWeightDecreaseAmount = -10 // stale/irrelevant — qualifies, so decrease is never consulted
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [145, 145, 145], "qualifies, so the increase path applies — the decrease field is irrelevant here")
    }
}
