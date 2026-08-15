//
//  ProgressionEngineStartingWeightsTests.swift
//  TheJymTests
//
//  Covers ProgressionEngine.startingWeights/startingRepTotal — the shared
//  "what would this exercise actually start at right now" resolution that
//  both WorkoutLogView's draft setup and the Train tab's preview call, so
//  the preview can never show a different weight than opening the workout
//  does (the bug this pair of functions was extracted to fix).
//

import XCTest
import SwiftData
@testable import TheJym

final class ProgressionEngineStartingWeightsTests: XCTestCase {
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
    private func log(_ exerciseName: String, targetReps: [Int], actualWeights: [Double],
                     daysAgo: Int, context: ModelContext) -> ExerciseLog {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let exerciseLog = ExerciseLog(exerciseName: exerciseName, targetReps: targetReps, order: 0)
        exerciseLog.session = session
        context.insert(exerciseLog)
        for (i, w) in actualWeights.enumerated() {
            let set = SetLog(index: i, weight: w, reps: targetReps[i])
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        return exerciseLog
    }

    /// AI off, no history yet: falls back to the plan's own suggestedWeights.
    func testStartingWeightsFallsBackToSuggestedWeightsWithoutHistory() {
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8],
                                 suggestedWeights: [95, 95, 95])
        let weights = ProgressionEngine.startingWeights(for: pe, history: [], aiOn: false,
                                                         aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [95, 95, 95])
    }

    /// AI off, with history: uses last time's actual weights, not
    /// suggestedWeights — this is exactly what the Train tab preview was
    /// missing before it called into this same function.
    @MainActor
    func testStartingWeightsUsesLastActualWeightsWhenAIIsOff() {
        let context = makeContext()
        log("Bench Press", targetReps: [8, 8, 8], actualWeights: [135, 135, 135], daysAgo: 7, context: context)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8],
                                 suggestedWeights: [95, 95, 95])
        let weights = ProgressionEngine.startingWeights(for: pe, history: logs, aiOn: false,
                                                         aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(weights, [135, 135, 135])
    }

    /// A deload cycle halves (roughly — rounded to plate) whatever weights
    /// would otherwise have been resolved.
    func testStartingWeightsHalvesForADeloadCycle() {
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [8, 8, 8],
                                 suggestedWeights: [100, 100, 100])
        let weights = ProgressionEngine.startingWeights(for: pe, history: [], aiOn: false,
                                                         aggressiveness: .moderate, roundingIncrement: 2.5,
                                                         isDeloadCycle: true)
        XCTAssertEqual(weights, [60, 60, 60])
    }

    /// repTotal, AI off, no history: falls back to suggestedWeights.first
    /// and the plan's own target, same shape as the fixedSets fallback.
    func testStartingRepTotalFallsBackToPlanDefaultsWithoutHistory() {
        let pe = PlannedExercise(order: 0, exerciseName: "Farmer's Carry", targetReps: [],
                                 suggestedWeights: [50], goalType: .repTotal(target: 40))
        let resolved = ProgressionEngine.startingRepTotal(for: pe, history: [], aiOn: false,
                                                           aggressiveness: .moderate, roundingIncrement: 2.5)
        XCTAssertEqual(resolved.weight, 50)
        XCTAssertEqual(resolved.target, 40)
    }

    /// Custom auto weight-increase rule overrides repTotal's own default
    /// setsTaken<=1 ? 5 : 2.5 bump outright, same as it does for a
    /// fixedSets exercise via suggestNextWeights — the gap this fixed.
    @MainActor
    func testStartingRepTotalUsesCustomIncreaseAmountWhenProvided() {
        let context = makeContext()
        let date = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Farmer's Carry", targetReps: [], order: 0, goalType: .repTotal(target: 40))
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 50, reps: 40)
        set.exerciseLog = log
        context.insert(set)
        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let pe = PlannedExercise(order: 0, exerciseName: "Farmer's Carry", targetReps: [],
                                 suggestedWeights: [50], goalType: .repTotal(target: 40))
        let resolved = ProgressionEngine.startingRepTotal(for: pe, history: logs, aiOn: true,
                                                           aggressiveness: .moderate, roundingIncrement: 2.5,
                                                           customIncreaseAmount: 10)
        XCTAssertEqual(resolved.weight, 60, "50 + the custom 10 lb rule, not the default 2.5/5 bump")
    }
}
