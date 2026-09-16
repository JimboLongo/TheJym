//
//  StatsEngineYearlyTotalsTests.swift
//  TheJymTests
//
//  Covers TrainingStats.yearlyTotals — the Stats page's per-year table.
//  Three things worth pinning down: the year bucketing (which years appear,
//  in what order, with no padding), the classification of which sessions
//  qualify (walks count, Rest Day placeholders don't), and the collapse of
//  multiple qualifying sessions on one date into a single ACTIVE DAY,
//  which is the same basis allTimeActiveDayCount uses — so the per-year
//  figures sum to that lifetime number.
//
//  Note on the classification: yearlyTotals buckets `sessionDates`, which
//  StatsView derives as `sessions.filter { !$0.exerciseLogs.isEmpty }`.
//  So these tests feed compute() the same already-filtered shape the real
//  caller does, and separately assert (via realSessionDates-equivalent
//  filtering below) that the filter itself sorts the session shapes into
//  the right buckets.
//

import XCTest
import SwiftData
@testable import TheJym

final class StatsEngineYearlyTotalsTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Mirrors StatsView.realSessionDates exactly — the filter that decides
    /// which session shapes ever reach yearlyTotals' workout count.
    private func realSessionDates(_ sessions: [WorkoutSession]) -> [Date] {
        sessions.filter { !$0.exerciseLogs.isEmpty }.map(\.date)
    }

    private func stats(sessionDates: [Date] = [],
                       restActivities: [RestDayActivity] = [],
                       startDate: Date,
                       now: Date) -> TrainingStats {
        StatsEngine.compute(startDate: startDate,
                            sessionDates: sessionDates,
                            restActivityDates: restActivities.map(\.date),
                            restActivities: restActivities,
                            now: now)
    }

    // MARK: - Year bucketing

    func testOneRowPerYearNewestFirst() {
        let result = stats(sessionDates: [date(2025, 4, 10), date(2025, 8, 1), date(2026, 2, 2)],
                           startDate: date(2025, 4, 10), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.map(\.year), [2026, 2025], "descending, newest first")
        XCTAssertEqual(result.yearlyTotals.map(\.activeDayCount), [1, 2])
    }

    /// A year with nothing at all never gets a row, and sparse years are
    /// not padded with the empty years between them.
    func testEmptyYearsAreOmittedAndGapsAreNotPadded() {
        let result = stats(sessionDates: [date(2023, 5, 1), date(2026, 5, 1)],
                           startDate: date(2023, 5, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.map(\.year), [2026, 2023],
                       "2024 and 2025 have nothing in them and must not appear")
    }

    func testNoRowsAtAllWhenNothingIsLogged() {
        let result = stats(startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertTrue(result.yearlyTotals.isEmpty)
    }

    /// A year with no sessions but some miles still qualifies.
    @MainActor
    func testAYearWithOnlyMilesStillGetsARow() {
        let context = makeContext()
        let walk = RestDayActivity(date: date(2025, 6, 1), name: "Walk", distance: 3.5)
        context.insert(walk)

        let result = stats(sessionDates: [date(2026, 1, 5)], restActivities: [walk],
                           startDate: date(2025, 6, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.map(\.year), [2026, 2025])
        let y2025 = result.yearlyTotals.first { $0.year == 2025 }
        XCTAssertEqual(y2025?.activeDayCount, 0)
        XCTAssertEqual(y2025?.milesWalked ?? 0, 3.5, accuracy: 0.001)
    }

    /// Dec 31 and Jan 1 must land in their own years, not bleed across the
    /// boundary — the year bounds are inclusive on both ends.
    func testYearBoundariesAreInclusiveOnBothEnds() {
        let result = stats(sessionDates: [date(2025, 1, 1), date(2025, 12, 31), date(2026, 1, 1)],
                           startDate: date(2025, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2025 }?.activeDayCount, 2,
                       "Jan 1 and Dec 31 2025 both belong to 2025")
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.activeDayCount, 1)
    }

    // MARK: - Miles column agrees with the page's other miles figures

    @MainActor
    func testMilesAreBucketedByYearAndSumToAllTimeMiles() {
        let context = makeContext()
        let a = RestDayActivity(date: date(2025, 3, 1), name: "Walk", distance: 2.0)
        let b = RestDayActivity(date: date(2025, 11, 1), name: "Walk", distance: 1.5)
        let c = RestDayActivity(date: date(2026, 4, 1), name: "Walk", distance: 4.0)
        [a, b, c].forEach(context.insert)

        let result = stats(sessionDates: [date(2025, 3, 1), date(2025, 11, 1), date(2026, 4, 1)],
                           restActivities: [a, b, c],
                           startDate: date(2025, 3, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2025 }?.milesWalked ?? 0, 3.5, accuracy: 0.001)
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.milesWalked ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(result.yearlyTotals.map(\.milesWalked).reduce(0, +), result.allTimeMiles, accuracy: 0.001,
                       "the per-year column must sum to the same all-time figure shown elsewhere on the page")
    }

    /// A non-mile unit is excluded here exactly as it is everywhere else —
    /// milesSum is the single shared helper, so this can't diverge.
    @MainActor
    func testNonMileUnitsAreExcludedSameAsEverywhereElse() {
        let context = makeContext()
        let km = RestDayActivity(date: date(2026, 5, 1), name: "Walk", distance: 5.0, distanceUnit: "km")
        context.insert(km)

        let result = stats(sessionDates: [date(2026, 5, 1)], restActivities: [km],
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.milesWalked ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(result.allTimeMiles, 0, accuracy: 0.001)
    }

    // MARK: - Workout-count classification (walks in, placeholders out)
    //
    // The part most likely to be subtly wrong. Each test builds the real
    // session shape and runs it through realSessionDates (StatsView's own
    // filter) before compute() ever sees it.

    /// A training session — the obvious case, counts.
    @MainActor
    func testATrainingSessionCounts() {
        let context = makeContext()
        let session = WorkoutSession(date: date(2026, 3, 1), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)

        let result = stats(sessionDates: realSessionDates([session]),
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.activeDayCount, 1)
    }

    /// A walk — mirrors TodayView.logActivity's shape (a real session whose
    /// one ExerciseLog carries a restDayActivity). "Including walks" means
    /// this counts.
    @MainActor
    func testAWalkCountsAsAWorkout() {
        let context = makeContext()
        let activity = RestDayActivity(date: date(2026, 3, 2), name: "Walk", distance: 2.5)
        context.insert(activity)
        let session = WorkoutSession(date: date(2026, 3, 2), dayLabel: "Rest", cycleNumber: 1)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log.session = session
        log.restDayActivity = activity
        context.insert(log)
        let set = SetLog(index: 0, weight: 2.5, reps: 1)
        set.exerciseLog = log
        context.insert(set)

        let result = stats(sessionDates: realSessionDates([session]), restActivities: [activity],
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.activeDayCount, 1,
                       "a logged walk is something the user actually did — it counts")
    }

    /// A backfilled Rest Day placeholder (day == nil, dayLabel == "Rest
    /// Day", no exercise logs) represents nothing happening — excluded.
    @MainActor
    func testABackfilledRestDayPlaceholderDoesNotCount() {
        let context = makeContext()
        let placeholder = WorkoutSession(date: date(2026, 3, 3), dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(placeholder)
        XCTAssertTrue(placeholder.isBackfilledRestPlaceholder,
                      "sanity check: this is the exact shape Models.swift documents")

        let result = stats(sessionDates: realSessionDates([placeholder]),
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertTrue(result.yearlyTotals.isEmpty,
                      "a placeholder alone gives the year nothing to report")
    }

    /// A plain "Log Rest Day" credit — has a real `day` but still no
    /// exercise logs, so it's excluded for the same reason.
    @MainActor
    func testAPlainRestDayCreditDoesNotCount() {
        let context = makeContext()
        let restCredit = WorkoutSession(date: date(2026, 3, 4), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(restCredit)

        let result = stats(sessionDates: realSessionDates([restCredit]),
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertTrue(result.yearlyTotals.isEmpty)
    }

    /// All four shapes together in one year: training + walk count,
    /// placeholder + plain rest credit don't.
    @MainActor
    func testMixedYearCountsOnlyTrainingAndWalks() {
        let context = makeContext()

        let training = WorkoutSession(date: date(2026, 3, 1), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(training)
        let trainingLog = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
        trainingLog.session = training
        context.insert(trainingLog)
        let trainingSet = SetLog(index: 0, weight: 135, reps: 8)
        trainingSet.exerciseLog = trainingLog
        context.insert(trainingSet)

        let activity = RestDayActivity(date: date(2026, 3, 2), name: "Walk", distance: 2.5)
        context.insert(activity)
        let walk = WorkoutSession(date: date(2026, 3, 2), dayLabel: "Rest", cycleNumber: 1)
        context.insert(walk)
        let walkLog = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        walkLog.session = walk
        walkLog.restDayActivity = activity
        context.insert(walkLog)
        let walkSet = SetLog(index: 0, weight: 2.5, reps: 1)
        walkSet.exerciseLog = walkLog
        context.insert(walkSet)

        let placeholder = WorkoutSession(date: date(2026, 3, 3), dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(placeholder)
        let restCredit = WorkoutSession(date: date(2026, 3, 4), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(restCredit)

        let all = [training, walk, placeholder, restCredit]
        let result = stats(sessionDates: realSessionDates(all), restActivities: [activity],
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))

        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.activeDayCount, 2,
                       "training + walk count; placeholder + plain rest credit do not")
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.milesWalked ?? 0, 2.5, accuracy: 0.001)
    }

    // MARK: - Active DAYS, not sessions
    //
    // The distinction this column turns on. Real data had 224 qualifying
    // 2025 sessions across 167 distinct days — 57 dates carrying a
    // training session AND a walk, from a CSV import that wrote the walk
    // as its own session.

    /// Two qualifying sessions on the same date are ONE active day.
    func testTwoSessionsOnTheSameDateCountAsOneActiveDay() {
        let result = stats(sessionDates: [date(2026, 3, 1), date(2026, 3, 1)],
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.activeDayCount, 1)
    }

    /// Same-day collapse ignores the time of day — two sessions hours
    /// apart are still one date.
    func testSessionsAtDifferentTimesOnOneDateStillCountOnce() {
        let morning = Calendar.current.date(byAdding: .hour, value: 7, to: date(2026, 3, 1))!
        let evening = Calendar.current.date(byAdding: .hour, value: 19, to: date(2026, 3, 1))!
        let result = stats(sessionDates: [morning, evening],
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.activeDayCount, 1)
    }

    /// The real-data shape, reproduced: a training session and a walk on
    /// the same date are two sessions but one active day — and the miles
    /// from that walk still count in full.
    @MainActor
    func testATrainingSessionAndAWalkOnOneDateAreOneActiveDay() {
        let context = makeContext()

        let training = WorkoutSession(date: date(2026, 3, 1), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(training)
        let trainingLog = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
        trainingLog.session = training
        context.insert(trainingLog)
        let trainingSet = SetLog(index: 0, weight: 135, reps: 8)
        trainingSet.exerciseLog = trainingLog
        context.insert(trainingSet)

        let activity = RestDayActivity(date: date(2026, 3, 1), name: "Walk", distance: 2.5)
        context.insert(activity)
        let walk = WorkoutSession(date: date(2026, 3, 1), dayLabel: "Rest", cycleNumber: 1)
        context.insert(walk)
        let walkLog = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        walkLog.session = walk
        walkLog.restDayActivity = activity
        context.insert(walkLog)
        let walkSet = SetLog(index: 0, weight: 2.5, reps: 1)
        walkSet.exerciseLog = walkLog
        context.insert(walkSet)

        let result = stats(sessionDates: realSessionDates([training, walk]), restActivities: [activity],
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        let y = result.yearlyTotals.first { $0.year == 2026 }
        XCTAssertEqual(y?.activeDayCount, 1, "two sessions, one date, one active day")
        XCTAssertEqual(y?.milesWalked ?? 0, 2.5, accuracy: 0.001, "the walk's miles still count in full")
    }

    /// allTimeActiveDayCount is built from the same day-collapsed set, so
    /// it's a DAY count too — three sessions across two dates is two.
    func testAllTimeActiveDayCountCollapsesSameDaySessions() {
        let result = stats(sessionDates: [date(2025, 4, 10), date(2025, 4, 10), date(2026, 2, 2)],
                           startDate: date(2025, 4, 10), now: date(2026, 9, 16))
        XCTAssertEqual(result.allTimeActiveDayCount, 2, "three sessions, two distinct dates")
    }

    /// The per-year column and the lifetime figure must agree — same
    /// basis, so this holds whether or not any date repeats.
    func testPerYearActiveDaysSumToAllTimeActiveDayCount() {
        let withRepeats = stats(sessionDates: [date(2025, 4, 10), date(2025, 4, 10),
                                               date(2025, 8, 1), date(2026, 2, 2)],
                                startDate: date(2025, 4, 10), now: date(2026, 9, 16))
        XCTAssertEqual(withRepeats.yearlyTotals.map(\.activeDayCount).reduce(0, +),
                       withRepeats.allTimeActiveDayCount)

        let noRepeats = stats(sessionDates: [date(2025, 4, 10), date(2025, 8, 1),
                                             date(2026, 2, 2), date(2026, 7, 7)],
                              startDate: date(2025, 4, 10), now: date(2026, 9, 16))
        XCTAssertEqual(noRepeats.yearlyTotals.map(\.activeDayCount).reduce(0, +),
                       noRepeats.allTimeActiveDayCount)
    }

    // MARK: - Current-year projection (rolling 3-month pace)
    //
    // The projection is whatever is already banked plus the trailing
    // 3-month per-day rate applied to the days still left in the year.
    // The window clamps to Jan 1, so early in a year it degenerates to
    // "the year so far".

    /// Consecutive dates so each is its own active day.
    private func consecutiveDates(count: Int, from start: Date) -> [Date] {
        (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    /// Active every day so far, with the window clamped to Jan 1 (only 14
    /// days into the year): rate is 1.0/day, so the projection fills every
    /// remaining day and lands on the full 365.
    func testAFullPaceEarlyInTheYearProjectsToTheWholeYear() {
        let result = stats(sessionDates: consecutiveDates(count: 14, from: date(2026, 1, 1)),
                           startDate: date(2026, 1, 1), now: date(2026, 1, 14))
        XCTAssertEqual(result.yearlyTotals.first?.activeDayCount, 14)
        XCTAssertEqual(result.currentYearProjection?.activeDayCount, 365,
                       "14 banked + 351 remaining days at a 1.0/day pace")
    }

    /// The whole point of the rolling window: a strong start that has since
    /// gone quiet projects off the RECENT pace, not the year's average. Here
    /// the trailing 3 months are empty, so nothing is added to what's banked.
    func testAQuietRecentStretchProjectsNoFurtherGrowth() {
        // Active every day of Jan-Mar, nothing since.
        let result = stats(sessionDates: consecutiveDates(count: 90, from: date(2026, 1, 1)),
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        let actual = result.yearlyTotals.first { $0.year == 2026 }
        XCTAssertEqual(actual?.activeDayCount, 90)
        XCTAssertEqual(result.currentYearProjection?.activeDayCount, 90,
                       "the trailing 3 months are empty, so the projection is just what's banked — "
                       + "a year-to-date rate would instead have inflated this to ~127")
    }

    /// The mirror case: a quiet start that has recently picked up projects
    /// off the recent pace, so it grows well past the year-to-date rate.
    func testARecentSurgeProjectsOffTheRecentPaceNotTheYearAverage() {
        // Nothing until mid-June, then active every day through Sep 16.
        let dates = consecutiveDates(count: 93, from: date(2026, 6, 16))
        let result = stats(sessionDates: dates, startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        let actual = result.yearlyTotals.first { $0.year == 2026 }
        let projected = result.currentYearProjection?.activeDayCount ?? 0
        XCTAssertEqual(actual?.activeDayCount, 93)
        // Trailing window is ~fully active, so ~every remaining day is added.
        XCTAssertGreaterThan(projected, 180,
                             "a full recent pace should project far past the 93 banked")
    }

    /// Miles use the same window and the same per-day rate as the day count.
    @MainActor
    func testProjectionUsesTheSameWindowForMiles() {
        let context = makeContext()
        // 2 miles a day for the first 14 days of the year.
        let walkDates = consecutiveDates(count: 14, from: date(2026, 1, 1))
        let walks = walkDates.map { RestDayActivity(date: $0, name: "Walk", distance: 2.0) }
        walks.forEach(context.insert)

        let result = stats(sessionDates: walkDates, restActivities: walks,
                           startDate: date(2026, 1, 1), now: date(2026, 1, 14))
        XCTAssertEqual(result.yearlyTotals.first?.milesWalked ?? 0, 28, accuracy: 0.001)
        // 28 banked + 351 remaining days at 2.0/day.
        XCTAssertEqual(result.currentYearProjection?.milesWalked ?? 0, 28 + 702, accuracy: 0.001)
    }

    /// Only the CURRENT year is projected — a prior year is already
    /// complete and has nothing to extrapolate.
    func testOnlyTheCurrentYearIsProjected() {
        let result = stats(sessionDates: [date(2025, 6, 1), date(2026, 3, 1)],
                           startDate: date(2025, 6, 1), now: date(2026, 7, 2))
        XCTAssertEqual(result.currentYearProjection?.year, 2026)
    }

    /// Too early in the year to extrapolate from — a rate off a handful of
    /// days would project to nonsense, so there's no column.
    func testNoProjectionInTheFirstTwoWeeksOfTheYear() {
        let result = stats(sessionDates: [date(2026, 1, 2), date(2026, 1, 3)],
                           startDate: date(2026, 1, 1), now: date(2026, 1, 8))
        XCTAssertNil(result.currentYearProjection,
                     "8 days in is not enough of a year to extrapolate a full-year total from")
    }

    /// The elapsed-days count uses effectiveToday: today only counts once
    /// something's been logged for it, which is exactly what tips this over
    /// the 14-day threshold.
    func testTodayCountsAsElapsedOnlyOnceSomethingIsLoggedForIt() {
        let logged = stats(sessionDates: [date(2026, 1, 2), date(2026, 1, 14)],
                           startDate: date(2026, 1, 1), now: date(2026, 1, 14))
        let unlogged = stats(sessionDates: [date(2026, 1, 2), date(2026, 1, 13)],
                             startDate: date(2026, 1, 1), now: date(2026, 1, 14))
        XCTAssertNotNil(logged.currentYearProjection, "14 elapsed days")
        XCTAssertNil(unlogged.currentYearProjection,
                     "13 elapsed days — today isn't counted until something's logged for it")
    }

    /// Once the year is genuinely complete there are no remaining days to
    /// project into, so the column is omitted rather than restating the
    /// actual.
    func testNoProjectionOnceTheYearIsComplete() {
        let result = stats(sessionDates: [date(2026, 3, 1), date(2026, 12, 31)],
                           startDate: date(2026, 1, 1), now: date(2026, 12, 31))
        XCTAssertNil(result.currentYearProjection)
    }

    /// A current year with no sessions and no miles has no row, so there's
    /// nothing to project from either.
    func testNoProjectionWhenTheCurrentYearHasNoRowAtAll() {
        let result = stats(sessionDates: [date(2025, 6, 1)],
                           startDate: date(2025, 6, 1), now: date(2026, 7, 2))
        XCTAssertEqual(result.yearlyTotals.map(\.year), [2025])
        XCTAssertNil(result.currentYearProjection)
    }

    /// Banked actuals are never re-estimated — only the remaining days are
    /// projected — so a projection can never read below what already
    /// happened, however quiet the recent window is.
    func testProjectionIsNeverBelowTheActualSoFar() {
        let result = stats(sessionDates: consecutiveDates(count: 40, from: date(2026, 2, 1)),
                           startDate: date(2026, 1, 1), now: date(2026, 9, 16))
        let actual = result.yearlyTotals.first { $0.year == 2026 }
        XCTAssertEqual(actual?.activeDayCount, 40)
        XCTAssertGreaterThanOrEqual(result.currentYearProjection?.activeDayCount ?? 0,
                                    actual?.activeDayCount ?? 0)
    }
}
