//
//  StatsEngineYearlyTotalsTests.swift
//  TheJymTests
//
//  Covers TrainingStats.yearlyTotals — the Stats page's per-year table.
//  Two things worth pinning down: the year bucketing (which years appear,
//  in what order, with no padding), and the classification of what counts
//  as a "workout" for that column, which is the subtle part — walks count,
//  Rest Day placeholders don't.
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
        XCTAssertEqual(result.yearlyTotals.map(\.workoutCount), [1, 2])
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
        XCTAssertEqual(y2025?.workoutCount, 0)
        XCTAssertEqual(y2025?.milesWalked ?? 0, 3.5, accuracy: 0.001)
    }

    /// Dec 31 and Jan 1 must land in their own years, not bleed across the
    /// boundary — the year bounds are inclusive on both ends.
    func testYearBoundariesAreInclusiveOnBothEnds() {
        let result = stats(sessionDates: [date(2025, 1, 1), date(2025, 12, 31), date(2026, 1, 1)],
                           startDate: date(2025, 1, 1), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2025 }?.workoutCount, 2,
                       "Jan 1 and Dec 31 2025 both belong to 2025")
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.workoutCount, 1)
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
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.workoutCount, 1)
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
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.workoutCount, 1,
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

        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.workoutCount, 2,
                       "training + walk count; placeholder + plain rest credit do not")
        XCTAssertEqual(result.yearlyTotals.first { $0.year == 2026 }?.milesWalked ?? 0, 2.5, accuracy: 0.001)
    }

    /// The per-year counts must sum to allTimeWorkoutCount — they're
    /// derived from the same input, so any drift here means the bucketing
    /// dropped or double-counted something.
    @MainActor
    func testPerYearCountsSumToAllTimeWorkoutCount() {
        let result = stats(sessionDates: [date(2025, 4, 10), date(2025, 8, 1),
                                          date(2026, 2, 2), date(2026, 7, 7)],
                           startDate: date(2025, 4, 10), now: date(2026, 9, 16))
        XCTAssertEqual(result.yearlyTotals.map(\.workoutCount).reduce(0, +), result.allTimeWorkoutCount)
    }
}
