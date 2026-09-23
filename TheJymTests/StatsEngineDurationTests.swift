//
//  StatsEngineDurationTests.swift
//  TheJymTests
//
//  Covers the deload exclusion in StatsEngine's two duration-based stats:
//  allTimeHoursTrained (TrainingStats, via StatsEngine.compute) and
//  dayDurationResult's shortest/average/longest spread. A deload session's
//  duration must never enter either computation — not counted as 0, just
//  excluded from the input entirely, same treatment as a nil duration.
//

import XCTest
import SwiftData
@testable import TheJym

final class StatsEngineDurationTests: XCTestCase {
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
    private func session(dayLabel: String, daysAgo: Int, duration: Int?, isDeload: Bool,
                         context: ModelContext) -> WorkoutSession {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let s = WorkoutSession(date: date, dayLabel: dayLabel, cycleNumber: 1, isDeload: isDeload)
        s.durationSeconds = duration
        context.insert(s)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        log.session = s
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)
        return s
    }

    // MARK: - allTimeHoursTrained

    @MainActor
    func testAllTimeHoursTrainedExcludesADeloadSessionsDurationButIncludesNonDeload() {
        let context = makeContext()
        let normal = session(dayLabel: "Push", daysAgo: 5, duration: 3600, isDeload: false, context: context)
        let deload = session(dayLabel: "Push", daysAgo: 3, duration: 7200, isDeload: true, context: context)
        let allSessions = [normal, deload]

        let stats = StatsEngine.compute(startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
                                        sessionDates: allSessions.map(\.date),
                                        allSessions: allSessions)
        XCTAssertEqual(stats.allTimeHoursTrained, 1.0, accuracy: 0.001,
                       "only the non-deload session's 3600s (1 hour) should count — the deload's 7200s is excluded, not added or zeroed")
    }

    /// If every session with a duration happens to be a deload, the sum is
    /// 0 hours — not because a deload counted as 0, but because there was
    /// nothing left in the input at all.
    @MainActor
    func testAllTimeHoursTrainedIsZeroWhenOnlyDeloadSessionsHaveDurations() {
        let context = makeContext()
        let deload = session(dayLabel: "Push", daysAgo: 3, duration: 7200, isDeload: true, context: context)
        let allSessions = [deload]

        let stats = StatsEngine.compute(startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
                                        sessionDates: allSessions.map(\.date),
                                        allSessions: allSessions)
        XCTAssertEqual(stats.allTimeHoursTrained, 0, accuracy: 0.001)
    }

    // MARK: - dayDurationResult

    @MainActor
    func testDayDurationResultExcludesADeloadSessionFromShortestAverageLongest() {
        let context = makeContext()
        let short = session(dayLabel: "Push", daysAgo: 10, duration: 1800, isDeload: false, context: context)
        let long = session(dayLabel: "Push", daysAgo: 5, duration: 3600, isDeload: false, context: context)
        // A 60s deload duration would otherwise become the new shortest —
        // it must not move any of the three numbers.
        let deload = session(dayLabel: "Push", daysAgo: 2, duration: 60, isDeload: true, context: context)

        let result = StatsEngine.dayDurationResult(named: "Push", in: [short, long, deload])
        let unwrapped = try! XCTUnwrap(result)
        XCTAssertEqual(unwrapped.shortestSeconds, 1800, "the deload's 60s must not become the new shortest")
        XCTAssertEqual(unwrapped.longestSeconds, 3600)
        XCTAssertEqual(unwrapped.averageSeconds, 2700, accuracy: 0.001, "average of the two non-deload sessions only")
    }

    // MARK: - deloadOnly: the second Workout Duration page

    /// The deload page is the mirror image: only deload sessions, and the
    /// normal ones are excluded from it just as firmly as deloads are from
    /// the default page.
    @MainActor
    func testDeloadOnlyMeasuresOnlyDeloadSessions() {
        let context = makeContext()
        let normalShort = session(dayLabel: "Push", daysAgo: 10, duration: 1800, isDeload: false, context: context)
        let normalLong = session(dayLabel: "Push", daysAgo: 9, duration: 3600, isDeload: false, context: context)
        let deloadA = session(dayLabel: "Push", daysAgo: 5, duration: 900, isDeload: true, context: context)
        let deloadB = session(dayLabel: "Push", daysAgo: 2, duration: 1500, isDeload: true, context: context)
        let all = [normalShort, normalLong, deloadA, deloadB]

        let result = try! XCTUnwrap(StatsEngine.dayDurationResult(named: "Push", in: all, deloadOnly: true))
        XCTAssertEqual(result.shortestSeconds, 900, "the 1800s normal session must not become the shortest here")
        XCTAssertEqual(result.longestSeconds, 1500, "nor the 3600s normal session the longest")
        XCTAssertEqual(result.averageSeconds, 1200, accuracy: 0.001, "average of the two deloads only")
    }

    /// The two pages partition the sessions — neither can see the other's,
    /// which is what stops a session being counted on both.
    @MainActor
    func testTheTwoPagesPartitionTheSessionsWithNoOverlapOrGap() {
        let context = makeContext()
        let normal = session(dayLabel: "Push", daysAgo: 5, duration: 3600, isDeload: false, context: context)
        let deload = session(dayLabel: "Push", daysAgo: 3, duration: 1800, isDeload: true, context: context)
        let all = [normal, deload]

        let standard = try! XCTUnwrap(StatsEngine.dayDurationResult(named: "Push", in: all))
        let deloadPage = try! XCTUnwrap(StatsEngine.dayDurationResult(named: "Push", in: all, deloadOnly: true))
        XCTAssertEqual(standard.shortestSeconds, 3600)
        XCTAssertEqual(standard.longestSeconds, 3600)
        XCTAssertEqual(deloadPage.shortestSeconds, 1800)
        XCTAssertEqual(deloadPage.longestSeconds, 1800)
    }

    /// nil when there are no deload sessions for that day — which is how
    /// the view knows to leave the day off the deload page entirely rather
    /// than show an all-"No Data" group.
    @MainActor
    func testDeloadOnlyIsNilWhenOnlyNormalSessionsExist() {
        let context = makeContext()
        let normal = session(dayLabel: "Push", daysAgo: 5, duration: 3600, isDeload: false, context: context)
        XCTAssertNil(StatsEngine.dayDurationResult(named: "Push", in: [normal], deloadOnly: true))
    }

    /// A deload session with no recorded duration is skipped on the deload
    /// page for the same reason it would be on the standard one — omitted,
    /// not counted as 0.
    @MainActor
    func testDeloadOnlySkipsADeloadSessionWithNoRecordedDuration() {
        let context = makeContext()
        let timed = session(dayLabel: "Push", daysAgo: 5, duration: 1200, isDeload: true, context: context)
        let untimed = session(dayLabel: "Push", daysAgo: 3, duration: nil, isDeload: true, context: context)

        let result = try! XCTUnwrap(StatsEngine.dayDurationResult(named: "Push", in: [timed, untimed], deloadOnly: true))
        XCTAssertEqual(result.shortestSeconds, 1200)
        XCTAssertEqual(result.averageSeconds, 1200, accuracy: 0.001, "the nil-duration deload must not drag this to 600")
    }

    /// The default argument keeps every pre-existing caller on the normal
    /// half, so adding the deload page changed no existing behavior.
    @MainActor
    func testOmittingDeloadOnlyIsIdenticalToAskingForNormalSessions() {
        let context = makeContext()
        let normal = session(dayLabel: "Push", daysAgo: 5, duration: 3600, isDeload: false, context: context)
        let deload = session(dayLabel: "Push", daysAgo: 3, duration: 1800, isDeload: true, context: context)
        let all = [normal, deload]

        let implicit = StatsEngine.dayDurationResult(named: "Push", in: all)
        let explicit = StatsEngine.dayDurationResult(named: "Push", in: all, deloadOnly: false)
        XCTAssertEqual(implicit?.shortestSeconds, explicit?.shortestSeconds)
        XCTAssertEqual(implicit?.longestSeconds, explicit?.longestSeconds)
        XCTAssertEqual(implicit?.averageSeconds ?? -1, explicit?.averageSeconds ?? -2, accuracy: 0.001)
    }

    /// If the only session logged for this day template is a deload, the
    /// result is nil — no data to report, not a spread built from one
    /// deload's duration.
    @MainActor
    func testDayDurationResultNilWhenOnlyDeloadSessionsHaveDurations() {
        let context = makeContext()
        let deload = session(dayLabel: "Push", daysAgo: 2, duration: 3600, isDeload: true, context: context)

        let result = StatsEngine.dayDurationResult(named: "Push", in: [deload])
        XCTAssertNil(result)
    }

    // MARK: - The Workout Timer page's history

    /// **A deload session compares against deload history, not normal
    /// history.** Otherwise every deload reads as unusually short, which is
    /// what a deload is for.
    ///
    /// This is a call-site test, not a rule test: the spread itself is
    /// covered above. Sabotaging the page's `deloadOnly:` argument while it
    /// lived in the view produced **0 failures**, which is why the choice
    /// was pulled out to `workoutTimerDayHistory`.
    @MainActor
    func testWorkoutTimerHistoryComparesLikeWithLike() throws {
        let context = makeContext()
        let normalA = session(dayLabel: "Push", daysAgo: 10, duration: 3600, isDeload: false, context: context)
        let normalB = session(dayLabel: "Push", daysAgo: 5, duration: 4200, isDeload: false, context: context)
        let deload = session(dayLabel: "Push", daysAgo: 2, duration: 1800, isDeload: true, context: context)
        let all = [normalA, normalB, deload]

        let onDeload = try XCTUnwrap(StatsEngine.workoutTimerDayHistory(
            dayName: "Push", sessions: all, isDeloadCycle: true))
        XCTAssertEqual(onDeload.shortestSeconds, 1800)
        XCTAssertEqual(onDeload.longestSeconds, 1800, "only the deload session")

        let onNormal = try XCTUnwrap(StatsEngine.workoutTimerDayHistory(
            dayName: "Push", sessions: all, isDeloadCycle: false))
        XCTAssertEqual(onNormal.shortestSeconds, 3600)
        XCTAssertEqual(onNormal.longestSeconds, 4200, "the deload is excluded")
    }

    /// Matched by day template, so another day's sessions never leak in.
    @MainActor
    func testWorkoutTimerHistoryIsScopedToItsOwnDay() throws {
        let context = makeContext()
        let push = session(dayLabel: "Push", daysAgo: 5, duration: 3600, isDeload: false, context: context)
        let pull = session(dayLabel: "Pull", daysAgo: 4, duration: 9000, isDeload: false, context: context)

        let result = try XCTUnwrap(StatsEngine.workoutTimerDayHistory(
            dayName: "Push", sessions: [push, pull], isDeloadCycle: false))

        XCTAssertEqual(result.longestSeconds, 3600, "Pull's 2.5 hours must not raise Push's high")
    }

    /// Nil with no recorded history, so the page omits the row rather than
    /// showing zeroes — the same "omit rather than show a false number"
    /// rule the Stats screen uses.
    @MainActor
    func testWorkoutTimerHistoryIsNilWithNothingRecorded() {
        let context = makeContext()
        let untimed = session(dayLabel: "Push", daysAgo: 3, duration: nil, isDeload: false, context: context)

        XCTAssertNil(StatsEngine.workoutTimerDayHistory(
            dayName: "Push", sessions: [untimed], isDeloadCycle: false))
        XCTAssertNil(StatsEngine.workoutTimerDayHistory(
            dayName: "Push", sessions: [], isDeloadCycle: false))
    }
}
