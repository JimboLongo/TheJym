//
//  ActiveDayStreakTests.swift
//  TheJymTests
//
//  Covers currentActiveStreak / maxActiveStreak — plain consecutive days
//  with SOME activity, with none of the rest-bank machinery the existing
//  currentStreak/maxStreak run on.
//
//  Two halves here. The first drives StatsEngine.activeDayStreaks directly
//  with day sets, which is where the run-length and today-in-progress
//  rules live. The second builds the five real session shapes and pushes
//  them through StatsView's own realSessionDates filter into compute(), so
//  the classification is tested end to end rather than assumed — the two
//  rest-day cases in particular are easy to conflate with the walk case,
//  since all three are "a rest day" colloquially but only one is activity.
//

import XCTest
import SwiftData
@testable import TheJym

final class ActiveDayStreakTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let cal = Calendar.current
    private func day(_ offset: Int, from today: Date) -> Date {
        cal.date(byAdding: .day, value: offset, to: today)!
    }
    private var today: Date { cal.startOfDay(for: .now) }

    /// Mirrors StatsView.realSessionDates — the filter deciding which
    /// session shapes ever reach the streak walk.
    private func realSessionDates(_ sessions: [WorkoutSession]) -> [Date] {
        sessions.filter { !$0.exerciseLogs.isEmpty }.map(\.date)
    }

    // MARK: - The walk itself

    func testNoHistoryGivesZeroNotNil() {
        let result = StatsEngine.activeDayStreaks(activeDays: [], today: today)
        XCTAssertEqual(result.current, 0)
        XCTAssertEqual(result.max, 0)
    }

    func testConsecutiveDaysEndingTodayCount() {
        let days: Set<Date> = [day(-2, from: today), day(-1, from: today), today]
        let result = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(result.current, 3)
        XCTAssertEqual(result.max, 3)
    }

    /// A gap ends the run — no bank, no carry-over.
    func testAGapEndsTheCurrentRun() {
        // today, yesterday active; the day before that missing.
        let days: Set<Date> = [day(-4, from: today), day(-1, from: today), today]
        let result = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(result.current, 2)
    }

    // MARK: - Today in progress

    /// An as-yet-unlogged today must not read as a break — the walk starts
    /// from yesterday instead, matching the "today is pending until logged"
    /// rule used everywhere else in the engine.
    func testAnUnloggedTodayDoesNotBreakTheStreak() {
        let days: Set<Date> = [day(-3, from: today), day(-2, from: today), day(-1, from: today)]
        let result = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(result.current, 3, "three days through yesterday, with today still open")
    }

    /// Logging today extends it rather than restarting it.
    func testLoggingTodayExtendsTheSameRun() {
        let throughYesterday: Set<Date> = [day(-2, from: today), day(-1, from: today)]
        let withToday = throughYesterday.union([today])
        XCTAssertEqual(StatsEngine.activeDayStreaks(activeDays: throughYesterday, today: today).current, 2)
        XCTAssertEqual(StatsEngine.activeDayStreaks(activeDays: withToday, today: today).current, 3)
    }

    /// Genuinely broken still reads 0 — that's when yesterday is inactive
    /// too, not merely when today hasn't happened yet.
    func testAStreakBrokenYesterdayReadsZero() {
        let days: Set<Date> = [day(-5, from: today), day(-4, from: today), day(-3, from: today)]
        XCTAssertEqual(StatsEngine.activeDayStreaks(activeDays: days, today: today).current, 0)
        XCTAssertEqual(StatsEngine.activeDayStreaks(activeDays: days, today: today).max, 3)
    }

    // MARK: - Max vs current divergence

    /// The max is an all-time figure and outlives the current run.
    func testMaxOutlivesACurrentRunThatIsShorter() {
        var days = Set<Date>()
        for i in 20...26 { days.insert(day(-i, from: today)) }   // a 7-day run long ago
        days.formUnion([day(-1, from: today), today])            // a 2-day run now
        let result = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(result.current, 2)
        XCTAssertEqual(result.max, 7)
    }

    /// And the current run counts toward the max when it IS the longest.
    func testTheCurrentRunCanItselfBeTheMax() {
        var days = Set<Date>()
        for i in 0...5 { days.insert(day(-i, from: today)) }
        days.formUnion([day(-20, from: today), day(-19, from: today)])
        let result = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(result.current, 6)
        XCTAssertEqual(result.max, 6)
    }

    // MARK: - Classification, through compute()

    @MainActor
    private func trainingSession(on date: Date, context: ModelContext) -> WorkoutSession {
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

    /// Mirrors TodayView.logActivity — a real session whose one log carries
    /// a restDayActivity.
    @MainActor
    private func walkSession(on date: Date, context: ModelContext) -> (WorkoutSession, RestDayActivity) {
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

    /// Mirrors WorkoutSession.backfillRestDays — day nil, "Rest Day", no logs.
    @MainActor
    private func backfilledPlaceholder(on date: Date, context: ModelContext) -> WorkoutSession {
        let s = WorkoutSession(date: date, dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(s)
        return s
    }

    /// Mirrors TodayView.logPlainRestDay — a real `day`, still no logs.
    @MainActor
    private func plainRestCredit(on date: Date, context: ModelContext) -> WorkoutSession {
        let s = WorkoutSession(date: date, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(s)
        return s
    }

    private func streaks(_ sessions: [WorkoutSession], activities: [RestDayActivity] = []) -> TrainingStats {
        StatsEngine.compute(startDate: day(-60, from: today),
                            sessionDates: realSessionDates(sessions),
                            restActivityDates: activities.map(\.date),
                            restActivities: activities,
                            now: .now)
    }

    /// A walk SUSTAINS the streak — it's activity, not rest.
    @MainActor
    func testAWalkSustainsTheStreak() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-2, from: today), context: context)
        let (walk, activity) = walkSession(on: day(-1, from: today), context: context)
        let t2 = trainingSession(on: today, context: context)

        let stats = streaks([t1, walk, t2], activities: [activity])
        XCTAssertEqual(stats.currentActiveStreak, 3, "the walk day must not break a training streak")
        XCTAssertEqual(stats.maxActiveStreak, 3)
    }

    /// A plain "Log Rest Day" credit BREAKS it — no activity was logged.
    @MainActor
    func testAPlainRestDayCreditBreaksTheStreak() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-2, from: today), context: context)
        let rest = plainRestCredit(on: day(-1, from: today), context: context)
        let t2 = trainingSession(on: today, context: context)

        let stats = streaks([t1, rest, t2])
        XCTAssertEqual(stats.currentActiveStreak, 1, "only today — the plain rest day broke it")
        XCTAssertEqual(stats.maxActiveStreak, 1)
    }

    /// A backfilled Rest Day placeholder BREAKS it too — it represents
    /// nothing having happened, not a rest taken.
    @MainActor
    func testABackfilledPlaceholderBreaksTheStreak() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-2, from: today), context: context)
        let placeholder = backfilledPlaceholder(on: day(-1, from: today), context: context)
        XCTAssertTrue(placeholder.isBackfilledRestPlaceholder, "sanity: this is the documented shape")
        let t2 = trainingSession(on: today, context: context)

        let stats = streaks([t1, placeholder, t2])
        XCTAssertEqual(stats.currentActiveStreak, 1)
        XCTAssertEqual(stats.maxActiveStreak, 1)
    }

    /// A date with no session at all BREAKS it.
    @MainActor
    func testAGapWithNoSessionBreaksTheStreak() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-2, from: today), context: context)
        // nothing at all on day(-1)
        let t2 = trainingSession(on: today, context: context)

        let stats = streaks([t1, t2])
        XCTAssertEqual(stats.currentActiveStreak, 1)
        XCTAssertEqual(stats.maxActiveStreak, 1)
    }

    /// All five shapes at once, and the divergence between current and max.
    @MainActor
    func testAllFiveShapesTogetherWithMaxDivergingFromCurrent() {
        let context = makeContext()
        // An older 4-day run: training, walk, training, walk.
        let a = trainingSession(on: day(-10, from: today), context: context)
        let (b, bAct) = walkSession(on: day(-9, from: today), context: context)
        let c = trainingSession(on: day(-8, from: today), context: context)
        let (d, dAct) = walkSession(on: day(-7, from: today), context: context)
        // Broken by a plain rest credit, then a placeholder, then a gap.
        let e = plainRestCredit(on: day(-6, from: today), context: context)
        let f = backfilledPlaceholder(on: day(-5, from: today), context: context)
        // day(-4) has nothing at all.
        // A shorter current run: yesterday + today.
        let g = trainingSession(on: day(-1, from: today), context: context)
        let h = trainingSession(on: today, context: context)

        let stats = streaks([a, b, c, d, e, f, g, h], activities: [bAct, dAct])
        XCTAssertEqual(stats.maxActiveStreak, 4, "the older training/walk run")
        XCTAssertEqual(stats.currentActiveStreak, 2, "yesterday and today only")
    }

    /// The two measures are genuinely independent, and a walk is where
    /// they diverge most clearly: the rest bank CHARGES 0.5 for an
    /// activity-rest day, so with nothing banked that day breaks the
    /// banked streak — while the active-day walk treats the same walk as
    /// full activity and carries straight through it.
    ///
    /// (Direction worth noting: the new stat is the more generous of the
    /// two about walks, not a stricter variant of it. They aren't ordered.)
    @MainActor
    func testAWalkDivergesFromTheRestBankStreak() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-2, from: today), context: context)
        let (walk, activity) = walkSession(on: day(-1, from: today), context: context)
        let t2 = trainingSession(on: today, context: context)

        let stats = streaks([t1, walk, t2], activities: [activity])
        XCTAssertEqual(stats.currentActiveStreak, 3, "a walk is activity — the run continues")
        XCTAssertEqual(stats.currentStreak, 1,
                       "the rest bank spent 0.5 it didn't have on the walk and broke")
    }
}
