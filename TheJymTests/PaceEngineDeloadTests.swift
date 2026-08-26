//
//  PaceEngineDeloadTests.swift
//  TheJymTests
//
//  Covers PaceEngine's deload-matching rule: a deload session only ever
//  compares against other deload sessions, and a normal session only
//  against other normal ones — cut deload loads shouldn't look like a
//  huge miss against full-weight history, or vice versa.
//

import XCTest
import SwiftData
@testable import TheJym

final class PaceEngineDeloadTests: XCTestCase {
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
    private func log(_ exerciseName: String, weights: [Double], daysAgo: Int, context: ModelContext,
                     isDeload: Bool = false) -> ExerciseLog {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let session = WorkoutSession(date: date, dayLabel: "Day", cycleNumber: 1, isDeload: isDeload)
        context.insert(session)
        let targetReps = Array(repeating: 8, count: weights.count)
        let exerciseLog = ExerciseLog(exerciseName: exerciseName, targetReps: targetReps, order: 0)
        exerciseLog.session = session
        context.insert(exerciseLog)
        for (i, w) in weights.enumerated() {
            let set = SetLog(index: i, weight: w, reps: 8)
            set.exerciseLog = exerciseLog
            context.insert(set)
        }
        return exerciseLog
    }

    @MainActor
    func testComparisonsExcludeDeloadHistoryWhenTodayIsNotDeload() {
        let context = makeContext()
        log("Bench Press", weights: [80, 80, 80], daysAgo: 7, context: context, isDeload: true)
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, isDeload: false)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [135, 135, 135], isDeload: false, allLogs: allLogs)
        let lastLogged = comparisons.first { $0.kind == .lastLogged }
        XCTAssertEqual(lastLogged?.totalWeightMoved, 135 * 8 * 3, "should skip the deload session entirely")
    }

    @MainActor
    func testComparisonsExcludeNormalHistoryWhenTodayIsDeload() {
        let context = makeContext()
        log("Bench Press", weights: [135, 135, 135], daysAgo: 14, context: context, isDeload: false)
        log("Bench Press", weights: [80, 80, 80], daysAgo: 7, context: context, isDeload: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let comparisons = PaceEngine.comparisons(for: "Bench Press", targetReps: [8, 8, 8],
                                                  currentWeights: [80, 80, 80], isDeload: true, allLogs: allLogs)
        let lastLogged = comparisons.first { $0.kind == .lastLogged }
        XCTAssertEqual(lastLogged?.totalWeightMoved, 80 * 8 * 3, "should skip the normal session entirely")
    }

    @MainActor
    func testMedalRankForLogOnlyRanksAgainstItsOwnDeloadStatus() {
        let context = makeContext()
        // Three normal sessions establish gold/silver/bronze at full weight.
        log("Squat", weights: [225], daysAgo: 30, context: context, isDeload: false)
        log("Squat", weights: [215], daysAgo: 21, context: context, isDeload: false)
        log("Squat", weights: [205], daysAgo: 14, context: context, isDeload: false)
        // A deload session moves far less total weight than any of those —
        // it should NOT rank below bronze against them; it should be gold
        // among the (empty-until-now) deload history instead.
        let deloadLog = log("Squat", weights: [130], daysAgo: 7, context: context, isDeload: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        XCTAssertEqual(PaceEngine.medalRank(for: deloadLog, allLogs: allLogs), 1,
                      "the only deload session for this plan should be gold among other deload sessions, not ranked against normal ones")
    }

    @MainActor
    func testMedalRankForNewTotalRespectsIsDeloadParameter() {
        let context = makeContext()
        log("Squat", weights: [225], daysAgo: 30, context: context, isDeload: false)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        // A live deload total, even much smaller than the normal history,
        // should rank gold among deload sessions (there are none yet).
        let liveRank = PaceEngine.medalRank(forNewTotal: 130 * 8, exerciseName: "Squat",
                                            planKey: "Squat|8", isDeload: true, allLogs: allLogs)
        XCTAssertEqual(liveRank, 1)
    }

    @MainActor
    func testMedalThresholdsOnlyDrawFromMatchingDeloadStatus() {
        let context = makeContext()
        log("Squat", weights: [225], daysAgo: 30, context: context, isDeload: false)
        log("Squat", weights: [130], daysAgo: 7, context: context, isDeload: true)
        let allLogs = try! context.fetch(FetchDescriptor<ExerciseLog>())

        let deloadThresholds = PaceEngine.medalThresholds(exerciseName: "Squat", planKey: "Squat|8",
                                                           isDeload: true, allLogs: allLogs)
        XCTAssertEqual(deloadThresholds.gold, 130 * 8)
        XCTAssertNil(deloadThresholds.silver)

        let normalThresholds = PaceEngine.medalThresholds(exerciseName: "Squat", planKey: "Squat|8",
                                                           isDeload: false, allLogs: allLogs)
        XCTAssertEqual(normalThresholds.gold, 225 * 8)
    }
}
