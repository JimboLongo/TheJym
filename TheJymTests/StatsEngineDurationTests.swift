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
}
