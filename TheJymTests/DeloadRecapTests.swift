//
//  DeloadRecapTests.swift
//  TheJymTests
//
//  Covers deload workouts producing a Workout Recap like any other
//  workout. finishWorkout's guard used to skip RecapEntry construction
//  entirely on a deload cycle — back when deload halved weights and
//  recap's only job was suggesting progressive jumps. Deload no longer
//  cuts weights, so it now gets the same three-state verdict + weight
//  wheel as any other session.
//
//  finishWorkout itself is a private SwiftUI view method and isn't
//  directly callable from a test. What IS testable — and what actually
//  carries the behavior — is the pair these tests cover:
//    1. WorkoutRecapView.verdict/initialAdjustment classifying a
//       deload-session-backed log correctly (the recap sheet's content).
//    2. ProgressionEngine honoring a deload log's own
//       selectedWeightAdjustment via `adjustmentLog` while still keeping
//       that deload's WEIGHTS out of `history` (the part that makes the
//       wheel's choice actually mean something rather than dead data).
//

import XCTest
import SwiftData
@testable import TheJym

final class DeloadRecapTests: XCTestCase {
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
    private func log(_ exerciseName: String, targetReps: [Int], actualReps: [Int], weights: [Double],
                     isDeload: Bool, adjustment: Double? = nil, daysAgo: Int,
                     context: ModelContext) -> ExerciseLog {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Lower Day 1", cycleNumber: 1, isDeload: isDeload)
        context.insert(session)
        let exerciseLog = ExerciseLog(exerciseName: exerciseName, targetReps: targetReps, order: 0)
        exerciseLog.session = session
        exerciseLog.selectedWeightAdjustment = adjustment
        exerciseLog.missedTarget = zip(actualReps, targetReps).contains { $0 < $1 }
        context.insert(exerciseLog)
        for (i, w) in weights.enumerated() {
            let set = SetLog(index: i, weight: w, reps: actualReps[i])
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        return exerciseLog
    }

    @MainActor
    private func entry(for log: ExerciseLog, upperTargetReps: [Int]?,
                       configuredIncrease: Double?) -> WorkoutLogView.RecapEntry {
        WorkoutLogView.RecapEntry(exerciseName: log.exerciseName,
                                  log: log,
                                  currentWeights: log.sortedSets.map(\.weight),
                                  isBodyweight: false,
                                  actualReps: log.sortedSets.map(\.reps),
                                  targetReps: log.targetReps,
                                  upperTargetReps: upperTargetReps,
                                  configuredWeightIncreaseAmount: configuredIncrease)
    }

    // MARK: - A deload workout's recap entry classifies like any other

    /// The reported scenario: a Cycle 4 deload override of 3x6 against a
    /// 4x9 base. No ceiling is configured for the [6,6,6] override scheme
    /// (ExerciseDef.ceiling matches the reps array exactly), so the verdict
    /// lands on Hit Target / Missed Ceiling and the wheel seeds to No
    /// Change — NOT "Increase Weight?", despite the easier rep target
    /// being comfortably hit.
    @MainActor
    func testDeloadOverrideWithNoCeilingConfiguredVerdictsAsNoChange() {
        let context = makeContext()
        let deloadLog = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [6, 6, 6],
                            weights: [175, 175, 175], isDeload: true, daysAgo: 1, context: context)

        let recapEntry = entry(for: deloadLog, upperTargetReps: nil, configuredIncrease: nil)
        XCTAssertEqual(WorkoutRecapView.verdict(for: recapEntry), .hitTargetMissedCeiling)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: recapEntry), 0,
                       "a deload with no ceiling configured for its override scheme must seed No Change")
    }

    /// A deload session is not specially classified — with a ceiling that
    /// IS configured and met, it verdicts as Hit Ceiling like any other
    /// workout. Deliberate: the wheel isn't restricted by verdict, so a
    /// deload can still record a genuine increase or decrease.
    @MainActor
    func testDeloadSessionStillClassifiesAsHitCeilingWhenItQualifies() {
        let context = makeContext()
        let deloadLog = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [8, 8, 8],
                            weights: [175, 175, 175], isDeload: true, daysAgo: 1, context: context)

        let recapEntry = entry(for: deloadLog, upperTargetReps: [8, 8, 8], configuredIncrease: 5)
        XCTAssertEqual(WorkoutRecapView.verdict(for: recapEntry), .hitCeiling)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: recapEntry), 5)
    }

    /// Missing target on a deload verdicts as Missed Target, same as any
    /// other session.
    @MainActor
    func testDeloadSessionClassifiesAsMissedTargetWhenItMisses() {
        let context = makeContext()
        let deloadLog = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [6, 5, 4],
                            weights: [175, 175, 175], isDeload: true, daysAgo: 1, context: context)

        let recapEntry = entry(for: deloadLog, upperTargetReps: [8, 8, 8], configuredIncrease: 5)
        XCTAssertEqual(WorkoutRecapView.verdict(for: recapEntry), .missedTarget)
        XCTAssertEqual(WorkoutRecapView.initialAdjustment(for: recapEntry), -5)
    }

    // MARK: - A deload's wheel choice is honored, its weights are not

    /// The core of the fix: a deload log's selectedWeightAdjustment must
    /// actually reach ProgressionEngine, or the recap sheet a deload now
    /// shows would be decorative. `history` excludes the deload (its
    /// weights stay quarantined); `adjustmentLog` carries the deload's own
    /// wheel choice in separately.
    @MainActor
    func testDeloadWheelChoiceAppliesToTheNonDeloadStartingWeight() {
        let context = makeContext()
        let normal = log("Safety Squats", targetReps: [9, 9, 9, 9], actualReps: [9, 9, 9, 9],
                         weights: [175, 175, 175, 175], isDeload: false, daysAgo: 14, context: context)
        // The deload week itself: hand-lowered to 135, and the user chose
        // +10 on the recap wheel for what to do next.
        let deload = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [6, 6, 6],
                         weights: [135, 135, 135], isDeload: true, adjustment: 10,
                         daysAgo: 7, context: context)

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [9, 9, 9, 9], history: [normal], aggressiveness: .moderate,
            roundingIncrement: 2.5, adjustmentLog: deload)

        XCTAssertEqual(suggestion, [185, 185, 185, 185],
                       "the deload's +10 applies to the pre-deload 175 working weight, never to its own hand-lowered 135")
    }

    /// The quarantine half, stated independently: even with the deload as
    /// `adjustmentLog`, its own 135 never becomes the base weight.
    @MainActor
    func testDeloadWeightsNeverBecomeTheStartingWeight() {
        let context = makeContext()
        let normal = log("Safety Squats", targetReps: [9, 9, 9, 9], actualReps: [9, 9, 9, 9],
                         weights: [175, 175, 175, 175], isDeload: false, daysAgo: 14, context: context)
        let deload = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [6, 6, 6],
                         weights: [135, 135, 135], isDeload: true, adjustment: 0,
                         daysAgo: 7, context: context)

        let suggestion = ProgressionEngine.suggestNextWeights(
            targetReps: [9, 9, 9, 9], history: [normal], aggressiveness: .moderate,
            roundingIncrement: 2.5, adjustmentLog: deload)

        XCTAssertEqual(suggestion, [175, 175, 175, 175],
                       "an explicit No Change on the deload holds the pre-deload 175, not the deload's own 135")
    }

    /// A deload log with no recorded choice (nil) falls through to the
    /// normal algorithm against the non-deload history, unchanged.
    @MainActor
    func testDeloadWithNoRecordedChoiceLeavesTheAlgorithmUntouched() {
        let context = makeContext()
        let normal = log("Safety Squats", targetReps: [9, 9, 9, 9], actualReps: [9, 9, 9, 9],
                         weights: [175, 175, 175, 175], isDeload: false, daysAgo: 14, context: context)
        let deload = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [6, 6, 6],
                         weights: [135, 135, 135], isDeload: true, daysAgo: 7, context: context)
        XCTAssertNil(deload.selectedWeightAdjustment)

        let withDeload = ProgressionEngine.suggestNextWeights(
            targetReps: [9, 9, 9, 9], history: [normal], aggressiveness: .moderate,
            roundingIncrement: 2.5, adjustmentLog: deload)
        let withoutDeload = ProgressionEngine.suggestNextWeights(
            targetReps: [9, 9, 9, 9], history: [normal], aggressiveness: .moderate,
            roundingIncrement: 2.5)

        XCTAssertEqual(withDeload, withoutDeload,
                       "a deload that recorded no choice must not change the suggestion at all")
    }

    /// Same split through the ceiling path.
    @MainActor
    func testDeloadWheelChoiceAppliesThroughTheCeilingPathToo() {
        let context = makeContext()
        let normal = log("Safety Squats", targetReps: [9, 9, 9, 9], actualReps: [9, 9, 9, 9],
                         weights: [175, 175, 175, 175], isDeload: false, daysAgo: 14, context: context)
        let deload = log("Safety Squats", targetReps: [6, 6, 6], actualReps: [6, 6, 6],
                         weights: [135, 135, 135], isDeload: true, adjustment: -5,
                         daysAgo: 7, context: context)

        let suggestion = ProgressionEngine.suggestNextWeightsForUpperTarget(
            upperTargetReps: [11, 11, 11, 11], targetReps: [9, 9, 9, 9], weightIncreaseAmount: 5,
            history: [normal], roundingIncrement: 2.5, adjustmentLog: deload)

        XCTAssertEqual(suggestion, [170, 170, 170, 170],
                       "the deload's -5 applies to the pre-deload 175, overriding the ceiling rule's own bump")
    }
}
