//
//  PaceEngineTests.swift
//  TheJymTests
//
//  Verifies the pro-rata pace milestone math against a hand-traced example:
//  a target that moved 200 lbs in each of 5 sets (1000 total). By its own
//  set 3, it had moved 60% of its total, so the set-3 milestone is 60% of
//  (total + 1) = 600.6. Also checks the "n beyond the target's own set
//  count" fallback (milestone = total + 1) and the sign convention (a
//  negative cell means already ahead of pace).
//

import XCTest
import SwiftData
@testable import TheJym

final class PaceEngineTests: XCTestCase {
    private let target = ComparisonTarget(
        kind: .lastLogged, date: .now, totalWeightMoved: 1000,
        setWeightsMoved: [200, 200, 200, 200, 200], weights: [20, 20, 20, 20, 20],
        reps: [10, 10, 10, 10, 10], weightLabels: ["20", "20", "20", "20", "20"], occurrenceCount: 1, medalRank: nil)

    func testMilestoneAtSetIndexWithinTargetsOwnSetCount() {
        // Through set 3: cumulative 600, share 0.6 of 1000 -> 0.6 * 1001 = 600.6
        XCTAssertEqual(PaceEngine.milestone(atSetIndex: 3, setWeightsMoved: target.setWeightsMoved,
                                            total: target.totalWeightMoved), 600.6, accuracy: 1e-9)
    }

    func testMilestoneBeyondTargetsOwnSetCountIsFullWinThreshold() {
        XCTAssertEqual(PaceEngine.milestone(atSetIndex: 8, setWeightsMoved: target.setWeightsMoved,
                                            total: target.totalWeightMoved), 1001, accuracy: 1e-9)
    }

    func testPaceCellValueBehindPace() {
        // At set 3, milestone 600.6; only 500 logged through sets 1-2; set-3 weight 50.
        guard let cell = PaceEngine.paceCellValue(target: target, setIndex: 3, loggedSoFar: 500, columnWeight: 50) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, (600.6 - 500) / 50, accuracy: 1e-9)
        XCTAssertGreaterThan(cell, 0, "Behind pace should be positive (reps still needed)")
    }

    func testPaceCellValueAheadOfPaceIsNegative() {
        // Same milestone, but already moved 650 through sets 1-2 — past it.
        guard let cell = PaceEngine.paceCellValue(target: target, setIndex: 3, loggedSoFar: 650, columnWeight: 50) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, (600.6 - 650) / 50, accuracy: 1e-9)
        XCTAssertLessThan(cell, 0, "Ahead of pace should be negative")
    }

    func testPaceCellValueNilWithoutAColumnWeight() {
        XCTAssertNil(PaceEngine.paceCellValue(target: target, setIndex: 3, loggedSoFar: 500, columnWeight: 0))
    }

    // MARK: - Even pace cell (spreadsheet-ported "reps needed" formula)

    /// Real reported scenario: Safety Squats, target 145/145/145/155/155/
    /// 155 lbs x 6/7/7/5/5/5 (total 5225). After logging 5/6/6/6 in sets
    /// 1-4 (today's own total so far: 725+870+870+930 = 3395), the deficit
    /// is 5225-3395 = 1830 with 2 sets (5 sets) remaining -- average of the
    /// target's own weight at set positions 5 and 6 (155, 155) is 155, so
    /// ROUNDUP(1830/155/2) = 6.
    func testEvenPaceCellSpreadsTheDeficitAcrossRemainingSets() {
        let safetySquats = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 5225,
            setWeightsMoved: [870, 1015, 1015, 775, 775, 775],
            weights: [145, 145, 145, 155, 155, 155],
            reps: [6, 7, 7, 5, 5, 5],
            weightLabels: ["145", "145", "145", "155", "155", "155"], occurrenceCount: 1, medalRank: nil)
        guard let cell = PaceEngine.evenPaceCellValue(target: safetySquats, loggedSoFar: 3395,
                                                       setsLoggedSoFar: 4, totalSetsToday: 6) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 6, accuracy: 1e-9)
    }

    /// Continuing the same scenario: logging only 3 reps (not 6) in set 5
    /// brings today's total to 3395 + 155*3 = 3860, deficit 5225-3860 =
    /// 1365, with exactly 1 set remaining at 155 lbs -- ROUNDUP(1365/155)
    /// = 9. On this last remaining set the average collapses to that one
    /// set's own weight, so this is also the literal number of reps
    /// needed to cross the target's total outright.
    func testEvenPaceCellOnTheLastRemainingSetIsTheLiteralWinThreshold() {
        let safetySquats = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 5225,
            setWeightsMoved: [870, 1015, 1015, 775, 775, 775],
            weights: [145, 145, 145, 155, 155, 155],
            reps: [6, 7, 7, 5, 5, 5],
            weightLabels: ["145", "145", "145", "155", "155", "155"], occurrenceCount: 1, medalRank: nil)
        guard let cell = PaceEngine.evenPaceCellValue(target: safetySquats, loggedSoFar: 3860,
                                                       setsLoggedSoFar: 5, totalSetsToday: 6) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 9, accuracy: 1e-9)
    }

    func testEvenPaceCellNilWhenNoSetsRemain() {
        XCTAssertNil(PaceEngine.evenPaceCellValue(target: target, loggedSoFar: 1000,
                                                   setsLoggedSoFar: 5, totalSetsToday: 5))
    }

    func testEvenPaceCellNilWithoutTargetData() {
        let empty = ComparisonTarget(kind: .lastLogged, date: nil, totalWeightMoved: 0,
                                     setWeightsMoved: [], weights: [], reps: [], weightLabels: [], occurrenceCount: 1, medalRank: nil)
        XCTAssertNil(PaceEngine.evenPaceCellValue(target: empty, loggedSoFar: 0,
                                                   setsLoggedSoFar: 0, totalSetsToday: 3))
    }

    /// A single-set target should behave the same as any other final set:
    /// the "average" of one weight is just that weight.
    func testEvenPaceCellWithASingleSetTarget() {
        let oneSet = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 200, setWeightsMoved: [200],
            weights: [40], reps: [5], weightLabels: ["40"], occurrenceCount: 1, medalRank: nil)
        guard let cell = PaceEngine.evenPaceCellValue(target: oneSet, loggedSoFar: 0,
                                                       setsLoggedSoFar: 0, totalSetsToday: 1) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 5, accuracy: 1e-9) // ROUNDUP(200/40/1) = 5
    }

    // MARK: - "(Nx)" occurrence-count labels

    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A completed log of `exerciseName` at `weights` (one set each, target
    /// 8 reps), `daysAgo` days back. `hitTarget` controls whether each set's
    /// actual reps meet (8, the default) or fall short of (7) that target —
    /// the thing the `.lastLogged` streak now tracks, independent of weight.
    @MainActor
    @discardableResult
    private func log(_ exerciseName: String, weights: [Double], daysAgo: Int, context: ModelContext,
                     hitTarget: Bool = true) -> ExerciseLog {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let targetReps = Array(repeating: 8, count: weights.count)
        let exerciseLog = ExerciseLog(exerciseName: exerciseName, targetReps: targetReps, order: 0)
        exerciseLog.session = session
        context.insert(exerciseLog)
        let actualReps = hitTarget ? 8 : 7
        for (i, w) in weights.enumerated() {
            let set = SetLog(index: i, weight: w, reps: actualReps)
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        return exerciseLog
    }

    /// The streak describes the previous session's OWN weights, not today's
    /// — two historical sessions in a row at the same weight, both hitting
    /// target, read "(2x)" regardless of what's typed in for today.
    @MainActor
    func testLastLoggedStreakCountsConsecutiveSessionsAtThePreviousSessionsOwnWeightsThatHitTargetReps() {
        let context = makeContext()
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context, hitTarget: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }) else {
            return XCTFail("Expected a .lastLogged comparison")
        }
        XCTAssertEqual(lastLogged.occurrenceCount, 2)
        XCTAssertEqual(lastLogged.label, "Previous Workout (2x)")
    }

    /// Reported correction: the streak should NOT change when today's
    /// weight field changes — it's still (2x) even though today's weight
    /// (135) has never been done before (so "Best at Weights" reads 0/no
    /// data). Previous can legitimately exceed Best at Weights this way.
    @MainActor
    func testLastLoggedStreakDoesNotChangeWhenTodaysWeightDiffersFromHistory() {
        let context = makeContext()
        log("Bench Press", weights: [130, 130, 130], daysAgo: 14, context: context, hitTarget: true)
        log("Bench Press", weights: [130, 130, 130], daysAgo: 7, context: context, hitTarget: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }),
              let bestAtWeights = comparisons.first(where: { $0.kind == .bestAtTheseWeights }) else {
            return XCTFail("Expected .lastLogged and .bestAtTheseWeights comparisons")
        }
        XCTAssertEqual(lastLogged.occurrenceCount, 2)
        XCTAssertEqual(lastLogged.label, "Previous Workout (2x)")
        XCTAssertFalse(bestAtWeights.hasData)
        XCTAssertGreaterThan(lastLogged.occurrenceCount, bestAtWeights.occurrenceCount)
    }

    /// Neither Previous Workout nor Best at Weights should ever exceed
    /// All-Time Best, since both only ever count sessions that also share
    /// this exact rep/set structure.
    @MainActor
    func testNeitherLastLoggedNorBestAtWeightsExceedsBestForExercise() {
        let context = makeContext()
        log("Bench Press", weights: [130, 130, 130], daysAgo: 28, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 21, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context, hitTarget: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }),
              let bestAtWeights = comparisons.first(where: { $0.kind == .bestAtTheseWeights }),
              let bestForExercise = comparisons.first(where: { $0.kind == .bestForExercise }) else {
            return XCTFail("Expected all three comparisons")
        }
        XCTAssertEqual(lastLogged.occurrenceCount, 3)
        XCTAssertEqual(bestAtWeights.occurrenceCount, 3)
        XCTAssertEqual(bestForExercise.occurrenceCount, 4)
        XCTAssertLessThanOrEqual(lastLogged.occurrenceCount, bestForExercise.occurrenceCount)
        XCTAssertLessThanOrEqual(bestAtWeights.occurrenceCount, bestForExercise.occurrenceCount)
    }

    /// Same shape, but the session before "Previous Workout" fell short of
    /// its target reps (same weight throughout, so weight isn't what breaks
    /// it) — so "Previous Workout" is only the 1st hit in a row, "(1x)".
    @MainActor
    func testLastLoggedStreakResetsWhenThePriorSessionMissedTargetReps() {
        let context = makeContext()
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, hitTarget: false)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context, hitTarget: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }) else {
            return XCTFail("Expected a .lastLogged comparison")
        }
        XCTAssertEqual(lastLogged.occurrenceCount, 1)
        XCTAssertEqual(lastLogged.label, "Previous Workout (1x)")
    }

    /// Three sessions in a row that all hit target reps should read "(3x)"
    /// on the most recent one.
    @MainActor
    func testLastLoggedStreakCountsThreeInARow() {
        let context = makeContext()
        log("Bench Press", weights: [135, 135, 135], daysAgo: 21, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context, hitTarget: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }) else {
            return XCTFail("Expected a .lastLogged comparison")
        }
        XCTAssertEqual(lastLogged.occurrenceCount, 3)
        XCTAssertEqual(lastLogged.label, "Previous Workout (3x)")
    }

    /// If "Previous Workout" itself missed target reps, the streak reads
    /// "(0x)" — it starts over rather than just not counting that session.
    @MainActor
    func testLastLoggedStreakIsZeroWhenTheMostRecentSessionMissedTargetReps() {
        let context = makeContext()
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, hitTarget: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context, hitTarget: false)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }) else {
            return XCTFail("Expected a .lastLogged comparison")
        }
        XCTAssertEqual(lastLogged.occurrenceCount, 0)
        XCTAssertEqual(lastLogged.label, "Previous Workout (0x)")
    }

    /// No prior log at all — no streak count should be shown.
    func testLastLoggedLabelHasNoStreakSuffixWithoutData() {
        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: [])
        guard let lastLogged = comparisons.first(where: { $0.kind == .lastLogged }) else {
            return XCTFail("Expected a .lastLogged comparison")
        }
        XCTAssertEqual(lastLogged.label, "Previous Workout")
    }

    /// "Best at Weights" should count every historical session at these
    /// exact weights, not just consecutive ones — unlike the streak above,
    /// a differently-weighted session in between doesn't reset it.
    @MainActor
    func testBestAtTheseWeightsLabelCountsAllSessionsAtThoseWeights() {
        let context = makeContext()
        log("Bench Press", weights: [135, 135, 135], daysAgo: 28, context: context)
        log("Bench Press", weights: [140, 140, 140], daysAgo: 21, context: context)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let bestAtWeights = comparisons.first(where: { $0.kind == .bestAtTheseWeights }) else {
            return XCTFail("Expected a .bestAtTheseWeights comparison")
        }
        XCTAssertEqual(bestAtWeights.occurrenceCount, 3)
        XCTAssertEqual(bestAtWeights.label, "Best at Weights (3x)")
        XCTAssertFalse(bestAtWeights.isPR, "the 140 lb session moved more total weight for this plan than any 135 lb one did")
    }

    /// "All-Time Best" should count every historical session with this same
    /// rep/set structure, regardless of what weight was used.
    @MainActor
    func testBestForExerciseLabelCountsAllSessionsWithThisSetStructure() {
        let context = makeContext()
        log("Bench Press", weights: [125, 125, 125], daysAgo: 28, context: context)
        log("Bench Press", weights: [130, 130, 130], daysAgo: 21, context: context)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let bestForExercise = comparisons.first(where: { $0.kind == .bestForExercise }) else {
            return XCTFail("Expected a .bestForExercise comparison")
        }
        XCTAssertEqual(bestForExercise.occurrenceCount, 4)
        XCTAssertTrue(bestForExercise.isPR, "All-Time Best IS the plan's highest-total log by construction")
        XCTAssertEqual(bestForExercise.label, "All-Time Best (4x)")
    }

    /// Direct regression guard for the reported invariant: whenever
    /// .bestForExercise has data at all, it's always tagged (PR) — it's
    /// defined as the plan's own highest-total log, so this holds no
    /// matter what the history actually looks like.
    @MainActor
    func testBestForExerciseIsAlwaysTaggedPRWheneverItHasData() {
        let context = makeContext()
        log("Bench Press", weights: [95, 95, 95], daysAgo: 60, context: context)
        log("Bench Press", weights: [225, 225, 225], daysAgo: 30, context: context)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], allLogs: allLogs)
        guard let bestForExercise = comparisons.first(where: { $0.kind == .bestForExercise }) else {
            return XCTFail("Expected a .bestForExercise comparison")
        }
        XCTAssertTrue(bestForExercise.hasData)
        XCTAssertTrue(bestForExercise.isPR)
    }

    /// Ranks the plan's distinct totals: 1st = gold (isPR), 2nd = silver,
    /// 3rd = bronze, anything below that gets no medal at all.
    @MainActor
    func testSecondAndThirdHighestTotalsEarnSilverAndBronze() {
        let context = makeContext()
        log("Bench Press", weights: [150, 150, 150], daysAgo: 28, context: context)
        log("Bench Press", weights: [145, 145, 145], daysAgo: 21, context: context)
        log("Bench Press", weights: [140, 140, 140], daysAgo: 14, context: context)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        func bestAtWeights(_ w: Double) -> ComparisonTarget {
            let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                      currentWeights: [w, w, w], allLogs: allLogs)
            return comparisons.first(where: { $0.kind == .bestAtTheseWeights })!
        }

        XCTAssertEqual(bestAtWeights(150).medalRank, 1)
        XCTAssertTrue(bestAtWeights(150).isPR)
        XCTAssertEqual(bestAtWeights(145).medalRank, 2)
        XCTAssertEqual(bestAtWeights(140).medalRank, 3)
        XCTAssertNil(bestAtWeights(135).medalRank)
    }

    /// `PaceEngine.medalRank(for:allLogs:)` — the per-log lookup the
    /// Previous Workouts page uses — should agree with the ranking
    /// `comparisons` computes for its own targets.
    @MainActor
    func testMedalRankForLogMatchesComparisonsRanking() {
        let context = makeContext()
        let gold = log("Bench Press", weights: [150, 150, 150], daysAgo: 28, context: context)
        let silver = log("Bench Press", weights: [145, 145, 145], daysAgo: 21, context: context)
        let bronze = log("Bench Press", weights: [140, 140, 140], daysAgo: 14, context: context)
        let none = log("Bench Press", weights: [135, 135, 135], daysAgo: 7, context: context)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        XCTAssertEqual(PaceEngine.medalRank(for: gold, allLogs: allLogs), 1)
        XCTAssertEqual(PaceEngine.medalRank(for: silver, allLogs: allLogs), 2)
        XCTAssertEqual(PaceEngine.medalRank(for: bronze, allLogs: allLogs), 3)
        XCTAssertNil(PaceEngine.medalRank(for: none, allLogs: allLogs))
    }

    /// `PaceEngine.medalRank(forNewTotal:...)` — what the in-progress
    /// session's own live medal popup uses, since it isn't a saved
    /// ExerciseLog yet to look up with `medalRank(for:allLogs:)`.
    @MainActor
    func testMedalRankForNewTotalRanksAgainstExistingHistory() {
        let context = makeContext()
        log("Bench Press", weights: [150, 150, 150], daysAgo: 28, context: context) // 3600
        log("Bench Press", weights: [145, 145, 145], daysAgo: 21, context: context) // 3480
        log("Bench Press", weights: [140, 140, 140], daysAgo: 14, context: context) // 3360
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())
        let planKey = "Bench Press|8/8/8"

        // Beats the existing best outright -> gold.
        XCTAssertEqual(PaceEngine.medalRank(forNewTotal: 4000, exerciseName: "Bench Press",
                                            planKey: planKey, allLogs: allLogs), 1)
        // Ties the existing best -> also gold.
        XCTAssertEqual(PaceEngine.medalRank(forNewTotal: 3600, exerciseName: "Bench Press",
                                            planKey: planKey, allLogs: allLogs), 1)
        // Lands between 2nd and 3rd -> silver (pushes the old 2nd to 3rd).
        XCTAssertEqual(PaceEngine.medalRank(forNewTotal: 3500, exerciseName: "Bench Press",
                                            planKey: planKey, allLogs: allLogs), 2)
        // Below every existing total -> unranked.
        XCTAssertNil(PaceEngine.medalRank(forNewTotal: 100, exerciseName: "Bench Press",
                                          planKey: planKey, allLogs: allLogs))
    }
}
