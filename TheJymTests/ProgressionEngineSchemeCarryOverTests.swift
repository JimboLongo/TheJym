//
//  ProgressionEngineSchemeCarryOverTests.swift
//  TheJymTests
//
//  Covers suggestNextWeights/suggestNextWeightsForUpperTarget/startingWeights
//  carrying over a starting weight across a rep-scheme change (a per-cycle
//  override with a different set count or reps than the most recent log —
//  most commonly a deload). Before this, a scheme change reset weight
//  history to empty (the history(for:) call sites filtered by exact
//  planKey), silently falling back to 0. Now the widened history lookup
//  feeds a scheme-mismatched `latest` log through, and these functions
//  detect the mismatch and carry over a single broadcast weight instead of
//  running the normal per-scheme streak/aggressiveness math.
//

import XCTest
import SwiftData
@testable import TheJym

final class ProgressionEngineSchemeCarryOverTests: XCTestCase {
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
    private func log(_ exerciseName: String, targetReps: [Int], weights: [Double],
                     adjustment: Double? = nil, daysAgo: Int, context: ModelContext) -> ExerciseLog {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let exerciseLog = ExerciseLog(exerciseName: exerciseName, targetReps: targetReps, order: 0)
        exerciseLog.session = session
        exerciseLog.selectedWeightAdjustment = adjustment
        context.insert(exerciseLog)
        for (i, w) in weights.enumerated() {
            // Reps don't matter for these tests — carry-over doesn't
            // evaluate streak/surplus against the OLD scheme at all.
            let set = SetLog(index: i, weight: w, reps: targetReps[i])
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        return exerciseLog
    }

    // MARK: - suggestNextWeights

    /// Fewer sets logged before (3) than the new scheme wants (4) — the
    /// bug's inverse direction from the reported repro, still must not
    /// reset to empty/0.
    @MainActor
    func testSuggestNextWeightsCarriesOverWhenSetCountIncreases() {
        let context = makeContext()
        log("Safety Squats", targetReps: [8, 8, 8], weights: [175, 175, 175], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [6, 6, 6, 6], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [175, 175, 175, 175])
    }

    /// The reported repro's exact direction: more sets logged before (4x9)
    /// than the new override scheme (3x6, e.g. a deload).
    @MainActor
    func testSuggestNextWeightsCarriesOverWhenSetCountDecreases() {
        let context = makeContext()
        log("Safety Squats", targetReps: [9, 9, 9, 9], weights: [175, 175, 175, 175], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [6, 6, 6], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [175, 175, 175], "must carry over 175, not reset to pe.suggestedWeights/0")
    }

    /// Same set count, but the reps themselves changed — still a scheme
    /// change (different planKey), still must carry over rather than reset.
    @MainActor
    func testSuggestNextWeightsCarriesOverWhenOnlyRepsChange() {
        let context = makeContext()
        log("Safety Squats", targetReps: [8, 8, 8], weights: [175, 175, 175], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [10, 10, 10], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [175, 175, 175])
    }

    /// The Workout Recap wheel's adjustment on the carried-over log still
    /// applies, on top of the carried-over base weight.
    @MainActor
    func testSuggestNextWeightsAppliesRecapAdjustmentOnTopOfCarriedOverWeight() {
        let context = makeContext()
        log("Safety Squats", targetReps: [9, 9, 9, 9], weights: [175, 175, 175, 175],
            adjustment: -20, daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [6, 6, 6], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [155, 155, 155], "175 carried over, then the recap's own -20 applied on top")
    }

    /// Non-uniform (ascending/ramping) per-set weights: the carried-over
    /// value must be the MOST FREQUENT weight (150, logged 3 times), tie-
    /// broken toward the earlier/lighter one — NOT the last/heaviest set
    /// (170), which would silently turn a carry-over into a hidden increase.
    @MainActor
    func testSuggestNextWeightsCarriesOverMostFrequentWeightNotTheLastSet() {
        let context = makeContext()
        log("Safety Squats", targetReps: [8, 8, 8, 6, 6, 6],
            weights: [150, 150, 150, 170, 170, 170], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [6, 6, 6], history: logs, aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [150, 150, 150], "150 (earliest of the tied most-frequent weights), not 170 (the last/top set)")
    }

    // MARK: - suggestNextWeightsForUpperTarget (ceiling path)

    @MainActor
    func testSuggestNextWeightsForUpperTargetCarriesOverAcrossSchemeChange() {
        let context = makeContext()
        log("Safety Squats", targetReps: [9, 9, 9, 9], weights: [175, 175, 175, 175], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [8, 8, 8], targetReps: [6, 6, 6], weightIncreaseAmount: 5,
            history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [175, 175, 175],
                      "carries over rather than evaluating qualifiesForUpperTarget against the OLD scheme's sets")
    }

    // MARK: - startingWeights (AI on/off wrapper)

    @MainActor
    func testStartingWeightsCarriesOverAcrossSchemeChangeWhenAIOn() {
        let context = makeContext()
        log("Safety Squats", targetReps: [9, 9, 9, 9], weights: [175, 175, 175, 175], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Safety Squats", targetReps: [6, 6, 6])
        let weights = ProgressionEngine.startingWeights(for: pe, history: logs, aiOn: true,
                                                         aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [175, 175, 175])
    }

    /// AI off carries over the same way, but WITHOUT applying
    /// selectedWeightAdjustment — AI off never applies that wheel choice
    /// even when the scheme matches, so a scheme change doesn't newly
    /// start applying it either.
    @MainActor
    func testStartingWeightsCarriesOverAcrossSchemeChangeWhenAIOffIgnoringAdjustment() {
        let context = makeContext()
        log("Safety Squats", targetReps: [9, 9, 9, 9], weights: [175, 175, 175, 175],
            adjustment: -20, daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Safety Squats", targetReps: [6, 6, 6])
        let weights = ProgressionEngine.startingWeights(for: pe, history: logs, aiOn: false,
                                                         aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [175, 175, 175], "AI off ignores the recap adjustment, same as it always has")
    }
}
