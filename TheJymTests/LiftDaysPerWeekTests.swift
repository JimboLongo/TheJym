//
//  LiftDaysPerWeekTests.swift
//  TheJymTests
//
//  Covers TrainingStats.liftDaysPerWeek — the same measure as daysPerWeek
//  over the same window and denominator, but counting only days with
//  actual lifting on them.
//
//  The distinction that matters: a day with BOTH a lift and a walk is a
//  lift day. StatsEngine's existing `trainingDates` gets that wrong (it
//  drops any date carrying a RestDayActivity, which is right for the rest
//  bank it feeds), so this deliberately doesn't use it — see
//  WorkoutSession.hasLiftingLog.
//

import XCTest
import SwiftData
@testable import TheJym

final class LiftDaysPerWeekTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: .now) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    @MainActor
    @discardableResult
    private func lift(on date: Date, context: ModelContext) -> WorkoutSession {
        let s = WorkoutSession(date: date, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(s)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
        log.session = s
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)
        return s
    }

    @MainActor
    private func walk(on date: Date, context: ModelContext) -> (WorkoutSession, RestDayActivity) {
        let activity = RestDayActivity(date: date, name: "Walk", distance: 2.5)
        context.insert(activity)
        let s = WorkoutSession(date: date, dayLabel: "Rest", cycleNumber: 1)
        context.insert(s)
        let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log.session = s
        log.restDayActivity = activity
        context.insert(log)
        let set = SetLog(index: 0, weight: 2.5, reps: 1)
        set.exerciseLog = log
        context.insert(set)
        return (s, activity)
    }

    /// What `n` days works out to per week under whatever denominator
    /// compute() actually used — derived rather than hardcoded, since
    /// daysSinceStart depends on the pending-today rule (an unlogged today
    /// isn't counted as elapsed), which would otherwise make these
    /// assertions quietly wrong depending on when they run.
    private func perWeek(_ days: Double, _ result: TrainingStats) -> Double {
        let weeks = Double(result.daysSinceStart) / 7.0
        return weeks > 0 ? days / weeks : 0
    }

    /// Mirrors StatsView's own call, including realSessionDates.
    private func stats(_ sessions: [WorkoutSession], activities: [RestDayActivity] = [],
                       startOffset: Int) -> TrainingStats {
        StatsEngine.compute(startDate: day(startOffset),
                            sessionDates: sessions.filter { !$0.exerciseLogs.isEmpty }.map(\.date),
                            restActivityDates: activities.map(\.date),
                            restActivities: activities,
                            allSessions: sessions,
                            now: .now)
    }

    // MARK: - The three classification cases

    @MainActor
    func testALiftOnlyDayCounts() {
        let context = makeContext()
        let s = lift(on: day(-3), context: context)
        let result = stats([s], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, perWeek(1, result), accuracy: 0.001)
    }

    @MainActor
    func testAWalkOnlyDayDoesNotCount() {
        let context = makeContext()
        let (session, activity) = walk(on: day(-3), context: context)
        let result = stats([session], activities: [activity], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, 0, accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek, perWeek(1, result), accuracy: 0.001,
                       "but it does count toward the existing Days per week")
    }

    /// The case `trainingDates` would get wrong: lifted AND walked the
    /// same day is still a lift day.
    @MainActor
    func testADayWithBothALiftAndAWalkCountsAsALiftDay() {
        let context = makeContext()
        let lifted = lift(on: day(-3), context: context)
        let (walked, activity) = walk(on: day(-3), context: context)
        let result = stats([lifted, walked], activities: [activity], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, perWeek(1, result), accuracy: 0.001,
                       "the walk must not cancel out the lift on the same date")
    }

    /// Two sessions on one lift day are still ONE day.
    @MainActor
    func testTwoLiftsOnOneDayCountOnce() {
        let context = makeContext()
        let a = lift(on: day(-3), context: context)
        let b = lift(on: day(-3), context: context)
        let result = stats([a, b], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, perWeek(1, result), accuracy: 0.001)
    }

    // MARK: - Relationship to the existing stat

    /// Same denominator, so the gap between the two rows is exactly the
    /// walk-only days.
    @MainActor
    func testTheGapBetweenTheTwoRowsIsTheWalkOnlyDays() {
        let context = makeContext()
        let l1 = lift(on: day(-6), context: context)
        let l2 = lift(on: day(-5), context: context)
        let l3 = lift(on: day(-4), context: context)
        let (w1, a1) = walk(on: day(-3), context: context)
        let (w2, a2) = walk(on: day(-2), context: context)

        let result = stats([l1, l2, l3, w1, w2], activities: [a1, a2], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, perWeek(3, result), accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek, perWeek(5, result), accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek - result.liftDaysPerWeek, perWeek(2, result), accuracy: 0.001,
                       "two walk-only days")
    }

    /// Neither a backfilled placeholder nor a plain rest credit is a lift
    /// day — neither has any exercise log at all.
    @MainActor
    func testRestDayShapesAreNotLiftDays() {
        let context = makeContext()
        let lifted = lift(on: day(-6), context: context)
        let placeholder = WorkoutSession(date: day(-5), dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(placeholder)
        let plainRest = WorkoutSession(date: day(-4), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(plainRest)

        let result = stats([lifted, placeholder, plainRest], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, perWeek(1, result), accuracy: 0.001)
    }

    @MainActor
    func testNoDataGivesZero() {
        let result = stats([], startOffset: -6)
        XCTAssertEqual(result.liftDaysPerWeek, 0, accuracy: 0.001)
    }

    // MARK: - The shared predicate

    @MainActor
    func testHasLiftingLogAgreesWithConsistencyDayKind() {
        let context = makeContext()
        let lifted = lift(on: day(-1), context: context)
        let (walked, _) = walk(on: day(-2), context: context)
        let placeholder = WorkoutSession(date: day(-3), dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(placeholder)

        XCTAssertTrue(lifted.hasLiftingLog)
        XCTAssertFalse(walked.hasLiftingLog)
        XCTAssertFalse(placeholder.hasLiftingLog)
        // consistencyDayKind is built on the same predicate, so it must
        // bucket the same sessions the same way.
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: day(-1), sessions: [lifted]), .trained)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: day(-2), sessions: [walked]), .rest)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: day(-3), sessions: [placeholder]), .rest)
    }
}
