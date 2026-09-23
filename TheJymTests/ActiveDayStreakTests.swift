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

    // MARK: - The current run's start date
    //
    // The pending-today rule decides where the walk starts looking back
    // FROM; it must never move where the run is reported to have BEGUN.

    func testNoHistoryGivesNoStartDate() {
        XCTAssertNil(StatsEngine.activeDayStreaks(activeDays: [], today: today).currentStart)
    }

    /// A broken streak reports no start date, so the row shows no subtitle
    /// — same convention as currentStreakStartDate.
    func testABrokenStreakGivesNoStartDate() {
        let days: Set<Date> = [day(-5, from: today), day(-4, from: today)]
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(r.current, 0)
        XCTAssertNil(r.currentStart, "a 0 streak must have no start date to render")
    }

    /// Today logged: the start is the run's first day, not today.
    func testStartDateWithTodayLogged() {
        var days = Set<Date>()
        for i in 0...4 { days.insert(day(-i, from: today)) }
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(r.current, 5)
        XCTAssertEqual(r.currentStart, day(-4, from: today))
    }

    /// Today NOT logged: the walk starts from yesterday, but the reported
    /// start must still be the run's genuine first day — unshifted.
    func testStartDateIsUnshiftedWhenTodayIsUnlogged() {
        var days = Set<Date>()
        for i in 1...5 { days.insert(day(-i, from: today)) }   // -5 ... -1
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(r.current, 5)
        XCTAssertEqual(r.currentStart, day(-5, from: today),
                       "the pending-today rule must not move the run's first day")
    }

    /// The same run reports the same start whether or not today has been
    /// logged yet — logging today extends the run without re-anchoring it.
    func testLoggingTodayDoesNotMoveTheStartDate() {
        var base = Set<Date>()
        for i in 1...5 { base.insert(day(-i, from: today)) }
        let before = StatsEngine.activeDayStreaks(activeDays: base, today: today)
        let after = StatsEngine.activeDayStreaks(activeDays: base.union([today]), today: today)
        XCTAssertEqual(before.currentStart, after.currentStart, "same run, same first day")
        XCTAssertEqual(before.current, 5)
        XCTAssertEqual(after.current, 6)
    }

    /// The start sits after the gap that broke the previous run, not at
    /// the beginning of all history.
    func testStartDateSitsAfterTheBreakNotAtTheStartOfHistory() {
        var days = Set<Date>()
        for i in 20...25 { days.insert(day(-i, from: today)) }   // old run
        for i in 0...2 { days.insert(day(-i, from: today)) }     // current run
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        XCTAssertEqual(r.current, 3)
        XCTAssertEqual(r.currentStart, day(-2, from: today))
    }

    /// Through compute(), with a walk mid-run — the start is the first
    /// active day, and a walk in the middle doesn't re-anchor it.
    @MainActor
    func testStartDateThroughComputeWithAWalkMidRun() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-2, from: today), context: context)
        let (walk, activity) = walkSession(on: day(-1, from: today), context: context)
        let t2 = trainingSession(on: today, context: context)

        let stats = streaks([t1, walk, t2], activities: [activity])
        XCTAssertEqual(stats.currentActiveStreak, 3)
        XCTAssertEqual(stats.currentActiveStreakStartDate, day(-2, from: today))
    }

    /// And nil through compute() when the run is broken.
    @MainActor
    func testNoStartDateThroughComputeWhenBroken() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-6, from: today), context: context)
        let t2 = trainingSession(on: day(-5, from: today), context: context)

        let stats = streaks([t1, t2])
        XCTAssertEqual(stats.currentActiveStreak, 0)
        XCTAssertNil(stats.currentActiveStreakStartDate)
    }

    // MARK: - The max streak's date range
    //
    // The "Present" path is NOT reachable from the real data this was
    // built against (current 11, max 21 — different streaks), so it's
    // driven here with synthetic day sets instead of assumed to work.

    /// No data: no range at all, so the row renders without a subtitle
    /// rather than with an empty or placeholder one.
    func testNoDataGivesNoRange() {
        XCTAssertNil(StatsEngine.activeDayStreaks(activeDays: [], today: today).maxRange)
    }

    /// A finished historical run reports its real span and a break date,
    /// so it renders as a closed range.
    func testAFinishedRunReportsItsSpanAndABreakDate() {
        var days = Set<Date>()
        for i in 10...14 { days.insert(day(-i, from: today)) }   // -14 ... -10
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 5)
        XCTAssertEqual(range.start, day(-14, from: today))
        XCTAssertEqual(range.end, day(-10, from: today))
        XCTAssertNotNil(range.followingBreakDate, "a finished streak must report the day that ended it")
        XCTAssertEqual(range.followingBreakDate, day(-9, from: today))
        XCTAssertNil(range.precedingBreakDate, "it opens the history, so nothing preceded it")
    }

    /// THE "PRESENT" CASE: when the record run is the one still going,
    /// followingBreakDate is nil — which is what the view renders as
    /// "– Present".
    func testAnOngoingRecordStreakHasNoFollowingBreakDate() {
        var days = Set<Date>()
        for i in 0...5 { days.insert(day(-i, from: today)) }     // the current run, 6 days
        days.formUnion([day(-20, from: today), day(-19, from: today)])
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 6)
        XCTAssertEqual(r.current, 6, "the record IS the current run")
        XCTAssertEqual(range.start, day(-5, from: today))
        XCTAssertEqual(range.end, today)
        XCTAssertNil(range.followingBreakDate, "still open — this is what renders as Present")
    }

    /// The ongoing run counts as ongoing even when today itself isn't
    /// logged yet — the run ends at yesterday, and it's still open.
    func testAnOngoingRunIsStillOngoingWithTodayUnlogged() {
        var days = Set<Date>()
        for i in 1...4 { days.insert(day(-i, from: today)) }     // through yesterday
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.current, 4)
        XCTAssertEqual(range.end, day(-1, from: today))
        XCTAssertNil(range.followingBreakDate, "today being unlogged doesn't close the streak")
    }

    /// TIES go to the later run, so a tie between old history and the
    /// run still going describes the ongoing one and reads "Present" —
    /// matching computeRestBank's own tie rule.
    func testATieBetweenHistoricalAndOngoingGoesToTheOngoingOne() {
        var days = Set<Date>()
        for i in 30...32 { days.insert(day(-i, from: today)) }   // historical 3-day run
        for i in 0...2 { days.insert(day(-i, from: today)) }     // ongoing 3-day run
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 3)
        XCTAssertEqual(r.current, 3, "both runs are 3 — a genuine tie")
        XCTAssertEqual(range.start, day(-2, from: today), "the range describes the ongoing run")
        XCTAssertNil(range.followingBreakDate, "so it renders as Present")
    }

    /// A tie between two FINISHED runs also goes to the later one, so the
    /// rule is about recency rather than being a special case for ongoing.
    func testATieBetweenTwoFinishedRunsGoesToTheLaterOne() {
        var days = Set<Date>()
        for i in 40...42 { days.insert(day(-i, from: today)) }
        for i in 20...22 { days.insert(day(-i, from: today)) }
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 3)
        XCTAssertEqual(range.start, day(-22, from: today))
        XCTAssertNotNil(range.followingBreakDate)
    }

    /// A single finished day is a range whose start equals its end — what
    /// the view collapses to one date rather than "Sep 8 – Sep 8".
    func testASingleFinishedDayHasStartEqualToEnd() {
        let days: Set<Date> = [day(-10, from: today)]
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 1)
        XCTAssertEqual(range.start, range.end)
        XCTAssertNotNil(range.followingBreakDate, "finished, so it collapses to a single date")
    }

    /// A single ongoing day keeps the range form, since "Present" is
    /// saying something the start date isn't.
    func testASingleOngoingDayStaysOpen() {
        let days: Set<Date> = [today]
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 1)
        XCTAssertEqual(r.current, 1)
        XCTAssertEqual(range.start, range.end)
        XCTAssertNil(range.followingBreakDate, "renders as \"<date> – Present\", not a bare date")
    }

    /// A record run that isn't the current one keeps its own break date
    /// even while a shorter run is in progress — the Present rendering
    /// must not leak onto a historical record.
    func testAHistoricalRecordStaysClosedWhileAShorterRunIsInProgress() {
        var days = Set<Date>()
        for i in 20...26 { days.insert(day(-i, from: today)) }   // 7-day record
        days.formUnion([day(-1, from: today), today])            // 2-day current
        let r = StatsEngine.activeDayStreaks(activeDays: days, today: today)
        let range = try! XCTUnwrap(r.maxRange)
        XCTAssertEqual(r.max, 7)
        XCTAssertEqual(r.current, 2)
        XCTAssertNotNil(range.followingBreakDate, "the record ended; only the current run is open")
        XCTAssertEqual(range.end, day(-20, from: today))
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
                            // **Required for anything lift-vs-walk.**
                            // `allLiftDays` is built from `allSessions`, so
                            // omitting it leaves every day classified as
                            // walk-only — which is silent, because the
                            // streak tests above only care that a day is
                            // active at all.
                            allSessions: sessions,
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

    // MARK: - The streak rows' composition (Lift + Walk = Active)

    /// **The invariant the table is there to show.** Lift and Walk on the
    /// two streak rows are the *composition* of the Active streak, so they
    /// sum to it — which four independent streaks never could.
    ///
    /// This shape is the proof: alternating lift and walk days give an
    /// active streak of 4 out of a lift streak of 1 and a walk streak of 1.
    @MainActor
    func testStreakCompositionSumsToTheActiveStreak() {
        let context = makeContext()
        let t1 = trainingSession(on: day(-3, from: today), context: context)
        let (w1, a1) = walkSession(on: day(-2, from: today), context: context)
        let t2 = trainingSession(on: day(-1, from: today), context: context)
        let (w2, a2) = walkSession(on: today, context: context)

        let stats = streaks([t1, w1, t2, w2], activities: [a1, a2])

        XCTAssertEqual(stats.currentActiveStreak, 4)
        XCTAssertEqual(stats.currentActiveStreakLiftDays, 2)
        XCTAssertEqual(stats.currentActiveStreakWalkDays, 2)
        XCTAssertEqual(
            stats.currentActiveStreakLiftDays + stats.currentActiveStreakWalkDays,
            stats.currentActiveStreak,
            "Lift + Walk must equal Active on the streak row"
        )
        XCTAssertEqual(
            stats.maxActiveStreakLiftDays + stats.maxActiveStreakWalkDays,
            stats.maxActiveStreak,
            "and on the max row"
        )
        // The point of the fixture: the per-discipline streaks do NOT sum,
        // which is why the cells had to stop being streaks.
        XCTAssertNotEqual(
            stats.consistencyLift.currentStreak + stats.consistencyWalk.currentStreak,
            stats.currentActiveStreak,
            "if this ever sums, the fixture stopped exercising the case"
        )
    }

    /// A day with both a lift and a walk counts once, as a lift — the same
    /// partition `liftDays`/`walkOnlyDays` uses for the Days-logged row, so
    /// the sum holds rather than double-counting.
    @MainActor
    func testADayWithBothCountsOnceAsLift() {
        let context = makeContext()
        let lift = trainingSession(on: today, context: context)
        let (walk, activity) = walkSession(on: today, context: context)

        let stats = streaks([lift, walk], activities: [activity])

        XCTAssertEqual(stats.currentActiveStreak, 1)
        XCTAssertEqual(stats.currentActiveStreakLiftDays, 1)
        XCTAssertEqual(stats.currentActiveStreakWalkDays, 0, "not counted twice")
    }

    /// With no streak at all there is nothing to compose.
    @MainActor
    func testNoActiveStreakMeansNoComposition() {
        let context = makeContext()
        let old = trainingSession(on: day(-10, from: today), context: context)

        let stats = streaks([old])

        XCTAssertEqual(stats.currentActiveStreak, 0)
        XCTAssertEqual(stats.currentActiveStreakLiftDays, 0)
        XCTAssertEqual(stats.currentActiveStreakWalkDays, 0)
        XCTAssertEqual(stats.maxActiveStreakLiftDays + stats.maxActiveStreakWalkDays,
                       stats.maxActiveStreak, "the closed max streak still composes")
    }

    // MARK: - The streak rows' cells

    /// Rest shows no value. Extracted out of the view for this: while the
    /// rule lived inside `consistencyRows`, sabotaging it to print `0` broke
    /// nothing.
    func testRestCellShowsNoValueOnTheStreakRows() {
        XCTAssertEqual(
            ConsistencyStreakCell.text(header: "Rest", active: 7, lift: 4, walk: 3), "—",
            "a rest day is never inside an active streak, so there is no number to show"
        )
    }

    func testStreakRowCellsReadTheirOwnColumn() {
        XCTAssertEqual(ConsistencyStreakCell.text(header: "Active", active: 7, lift: 4, walk: 3), "7")
        XCTAssertEqual(ConsistencyStreakCell.text(header: "Lift", active: 7, lift: 4, walk: 3), "4")
        XCTAssertEqual(ConsistencyStreakCell.text(header: "Walk", active: 7, lift: 4, walk: 3), "3")
    }
}
