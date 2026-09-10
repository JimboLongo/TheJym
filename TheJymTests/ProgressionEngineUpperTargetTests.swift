//
//  ProgressionEngineUpperTargetTests.swift
//  TheJymTests
//
//  Covers the fixed upperTargetReps/weightIncreaseAmount rule — the
//  per-slot "hit this rep ceiling on every set, get this exact bump"
//  suggestion source that REPLACES ProgressionEngine's usual aggressiveness-
//  scaled algorithm for any PlannedExercise with it configured.
//

import XCTest
import SwiftData
@testable import TheJym

final class ProgressionEngineUpperTargetTests: XCTestCase {
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

    // MARK: - qualifiesForUpperTarget

    @MainActor
    func testQualifiesWhenEverySetMeetsOrBeatsItsCeiling() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 8, 13],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        XCTAssertTrue(ProgressionEngine.qualifiesForUpperTarget(entry, upperTargetReps: [10, 8, 10]))
    }

    @MainActor
    func testFallingShortOnAnySingleSetDisqualifiesTheWholeExercise() {
        let context = makeContext()
        // 13 vs ceiling 10 is fine, but 9 vs ceiling 10 on set 2 fails —
        // even though set 1 and set 3 both cleared their own ceilings.
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [13, 9, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        XCTAssertFalse(ProgressionEngine.qualifiesForUpperTarget(entry, upperTargetReps: [10, 10, 10]))
    }

    @MainActor
    func testExactlyMeetingEveryCeilingQualifiesWithoutNeedingToExceed() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        XCTAssertTrue(ProgressionEngine.qualifiesForUpperTarget(entry, upperTargetReps: [10, 10, 10]))
    }

    /// Fewer logged sets than the plan (a skipped set) must NOT qualify,
    /// even if every set that was logged individually cleared its ceiling —
    /// unlike metAll (used elsewhere), which only checks as many sets as
    /// were actually logged and would silently let this through.
    @MainActor
    func testFewerLoggedSetsThanPlannedNeverQualifies() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [15],
                        actualWeights: [135], daysAgo: 1, context: context)
        XCTAssertFalse(ProgressionEngine.qualifiesForUpperTarget(entry, upperTargetReps: [10, 10, 10]))
    }

    /// An extra, unplanned set beyond upperTargetReps' count also never
    /// qualifies — no target is inferred for it.
    @MainActor
    func testExtraLoggedSetBeyondThePlanNeverQualifies() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10, 10],
                        actualWeights: [135, 135, 135, 135], daysAgo: 1, context: context)
        XCTAssertFalse(ProgressionEngine.qualifiesForUpperTarget(entry, upperTargetReps: [10, 10, 10]))
    }

    // MARK: - suggestNextWeightsForUpperTarget

    func testSuggestNextWeightsForUpperTargetReturnsNilWithoutHistory() {
        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: [])
        XCTAssertNil(suggestion)
    }

    @MainActor
    func testSuggestNextWeightsForUpperTargetBumpsEverySetWhenQualified() {
        let context = makeContext()
        log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
            actualWeights: [135, 140, 135], daysAgo: 1, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [140, 145, 140])
    }

    @MainActor
    func testSuggestNextWeightsForUpperTargetHoldsWeightWhenNotQualified() {
        let context = makeContext()
        log("Bench Press", targetReps: [8, 8, 8], actualReps: [9, 10, 10],
            actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [135, 135, 135], "no bump earned — hold, don't fall back to a smaller bump")
    }

    @MainActor
    func testSuggestNextWeightsForUpperTargetUsesAddedWeightForBodyweight() {
        let context = makeContext()
        let date = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let exerciseLog = ExerciseLog(exerciseName: "Pull-Up", targetReps: [8, 8, 8], order: 0, isBodyweight: true)
        exerciseLog.session = session
        context.insert(exerciseLog)
        for i in 0..<3 {
            let set = SetLog(index: i, weight: 175, reps: 10, addedWeight: 25, bodyweightAtLog: 150)
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs,
            roundingIncrement: 2.5, isBodyweight: true)
        XCTAssertEqual(suggestion, [30, 30, 30], "bumps ADDED weight (25 + 5), never the resolved bodyweight total")
    }

    /// A per-session choice (ExerciseLog.selectedWeightIncreaseAmount, set
    /// via WorkoutRecapView's Picker) overrides the exercise's configured
    /// default for that specific qualifying log.
    @MainActor
    func testSuggestNextWeightsForUpperTargetPrefersPerSessionChoiceOverConfiguredDefault() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightIncreaseAmount = 10
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [145, 145, 145], "the recorded per-session choice (10) wins over the configured default (5)")
    }

    /// "No Increase" (0) is a real, distinct choice — it must actually hold
    /// the weight even though the session qualified and the exercise's
    /// configured default would otherwise bump it.
    @MainActor
    func testSuggestNextWeightsForUpperTargetHonorsExplicitNoIncreaseChoice() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        entry.selectedWeightIncreaseAmount = 0
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [135, 135, 135], "explicit No Increase (0) must hold the weight, not fall back to the configured default")
    }

    /// nil (never decided — old data, predating this field) falls back to
    /// the configured default, same as before this feature existed.
    @MainActor
    func testSuggestNextWeightsForUpperTargetFallsBackToConfiguredDefaultWhenNoPerSessionChoiceRecorded() {
        let context = makeContext()
        let entry = log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
                        actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        XCTAssertNil(entry.selectedWeightIncreaseAmount)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5, history: logs, roundingIncrement: 2.5)
        XCTAssertEqual(suggestion, [140, 140, 140])
    }

    // MARK: - startingWeightsForUpperTarget

    @MainActor
    func testStartingWeightsForUpperTargetUsesLastActualWeightsWhenAIIsOff() {
        let context = makeContext()
        log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
            actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8])
        let weights = ProgressionEngine.startingWeightsForUpperTarget(
            for: pe, upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5,
            history: logs, aiOn: false, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [135, 135, 135], "AI off ignores the bump rule entirely, same as the algorithmic path")
    }

    @MainActor
    func testStartingWeightsForUpperTargetBumpsWhenAIOnAndQualified() {
        let context = makeContext()
        log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
            actualWeights: [135, 135, 135], daysAgo: 1, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8])
        let weights = ProgressionEngine.startingWeightsForUpperTarget(
            for: pe, upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5,
            history: logs, aiOn: true, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [140, 140, 140])
    }

    @MainActor
    func testStartingWeightsForUpperTargetHalvesForADeloadCycle() {
        let context = makeContext()
        log("Bench Press", targetReps: [8, 8, 8], actualReps: [10, 10, 10],
            actualWeights: [100, 100, 100], daysAgo: 1, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8])
        let weights = ProgressionEngine.startingWeightsForUpperTarget(
            for: pe, upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5,
            history: logs, aiOn: true, roundingIncrement: 2.5, isDeloadCycle: true)
        XCTAssertEqual(weights, [62.5, 62.5, 62.5], "(100 + 5 = 105) * 0.6 rounded to plate")
    }

    func testStartingWeightsForUpperTargetFallsBackToSuggestedWeightsWithoutHistory() {
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8],
                                 suggestedWeights: [95, 95, 95])
        let weights = ProgressionEngine.startingWeightsForUpperTarget(
            for: pe, upperTargetReps: [10, 10, 10], weightIncreaseAmount: 5,
            history: [], aiOn: true, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [95, 95, 95])
    }
}
