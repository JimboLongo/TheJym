//
//  LiftDaysPerWeekTests.swift
//  TheJymTests
//
//  Covers the Days per week row's Total / Lift / Walk partition.
//
//  The load-bearing property is the identity Lift + Walk == Total: a day
//  with both a lift and a walk can only be counted once, so it belongs to
//  Lift and Walk is the remainder. That's the whole point of the row and
//  the easiest thing to silently break later, so it's asserted directly
//  and again across a mixed real-shaped fixture.
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

private extension TrainingStats {
    /// Just for readability in the identity assertions below.
    var liftPlusWalk: Double { consistencyLift.daysPerWeek + consistencyWalk.daysPerWeek }
}

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
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(1, result), accuracy: 0.001)
    }

    @MainActor
    func testAWalkOnlyDayDoesNotCount() {
        let context = makeContext()
        let (session, activity) = walk(on: day(-3), context: context)
        let result = stats([session], activities: [activity], startOffset: -6)
        XCTAssertEqual(result.consistencyLift.daysPerWeek, 0, accuracy: 0.001)
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
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(1, result), accuracy: 0.001,
                       "the walk must not cancel out the lift on the same date")
    }

    /// Two sessions on one lift day are still ONE day.
    @MainActor
    func testTwoLiftsOnOneDayCountOnce() {
        let context = makeContext()
        let a = lift(on: day(-3), context: context)
        let b = lift(on: day(-3), context: context)
        let result = stats([a, b], startOffset: -6)
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(1, result), accuracy: 0.001)
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
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(3, result), accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek, perWeek(5, result), accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek - result.consistencyLift.daysPerWeek, perWeek(2, result), accuracy: 0.001,
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
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(1, result), accuracy: 0.001)
    }

    @MainActor
    func testNoDataGivesZero() {
        let result = stats([], startOffset: -6)
        XCTAssertEqual(result.consistencyLift.daysPerWeek, 0, accuracy: 0.001)
        XCTAssertEqual(result.consistencyWalk.daysPerWeek, 0, accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek, 0, accuracy: 0.001)
    }

    // MARK: - Lift + Walk == Total

    /// The identity the whole row rests on, on a fixture carrying every
    /// shape at once: lift-only, walk-only, BOTH on one day, two lifts on
    /// one day, a placeholder and a plain rest credit.
    @MainActor
    func testLiftPlusWalkEqualsTotalAcrossEveryShape() {
        let context = makeContext()
        var sessions: [WorkoutSession] = []
        var activities: [RestDayActivity] = []

        sessions.append(lift(on: day(-12), context: context))            // lift only
        let (w1, a1) = walk(on: day(-11), context: context)              // walk only
        sessions.append(w1); activities.append(a1)
        sessions.append(lift(on: day(-10), context: context))            // BOTH
        let (w2, a2) = walk(on: day(-10), context: context)
        sessions.append(w2); activities.append(a2)
        sessions.append(lift(on: day(-9), context: context))             // two lifts, one day
        sessions.append(lift(on: day(-9), context: context))
        let placeholder = WorkoutSession(date: day(-8), dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(placeholder); sessions.append(placeholder)
        let plainRest = WorkoutSession(date: day(-7), dayLabel: "Push Day", cycleNumber: 1)
        context.insert(plainRest); sessions.append(plainRest)
        let (w3, a3) = walk(on: day(-6), context: context)               // walk only
        sessions.append(w3); activities.append(a3)

        let result = stats(sessions, activities: activities, startOffset: -14)

        XCTAssertEqual(result.consistencyLift.daysPerWeek + result.consistencyWalk.daysPerWeek,
                       result.daysPerWeek, accuracy: 0.0001,
                       "Lift + Walk must equal Total exactly")
        // Lift days: -12, -10, -9  (the BOTH day counts as a lift day).
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(3, result), accuracy: 0.001)
        // Walk-only days: -11, -6. The -10 walk is absorbed by its lift.
        XCTAssertEqual(result.consistencyWalk.daysPerWeek, perWeek(2, result), accuracy: 0.001)
        XCTAssertEqual(result.daysPerWeek, perWeek(5, result), accuracy: 0.001)
    }

    /// The BOTH day in isolation: it must land in Lift and contribute
    /// nothing to Walk, or the identity would over-count it.
    @MainActor
    func testADayWithBothIsCountedOnceInLiftAndNotInWalk() {
        let context = makeContext()
        let lifted = lift(on: day(-3), context: context)
        let (walked, activity) = walk(on: day(-3), context: context)

        let result = stats([lifted, walked], activities: [activity], startOffset: -6)
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(1, result), accuracy: 0.001)
        XCTAssertEqual(result.consistencyWalk.daysPerWeek, 0, accuracy: 0.001,
                       "the walk is absorbed by the lift on that date")
        XCTAssertEqual(result.liftPlusWalk, result.daysPerWeek, accuracy: 0.0001)
    }

    /// The identity holds when there is nothing but walks, too.
    @MainActor
    func testIdentityHoldsWithWalksOnly() {
        let context = makeContext()
        let (w1, a1) = walk(on: day(-4), context: context)
        let (w2, a2) = walk(on: day(-3), context: context)
        let result = stats([w1, w2], activities: [a1, a2], startOffset: -6)
        XCTAssertEqual(result.consistencyLift.daysPerWeek, 0, accuracy: 0.001)
        XCTAssertEqual(result.consistencyWalk.daysPerWeek, perWeek(2, result), accuracy: 0.001)
        XCTAssertEqual(result.liftPlusWalk, result.daysPerWeek, accuracy: 0.0001)
    }

    /// And with nothing but lifts.
    @MainActor
    func testIdentityHoldsWithLiftsOnly() {
        let context = makeContext()
        let a = lift(on: day(-4), context: context)
        let b = lift(on: day(-3), context: context)
        let result = stats([a, b], startOffset: -6)
        XCTAssertEqual(result.consistencyWalk.daysPerWeek, 0, accuracy: 0.001)
        XCTAssertEqual(result.consistencyLift.daysPerWeek, perWeek(2, result), accuracy: 0.001)
        XCTAssertEqual(result.liftPlusWalk, result.daysPerWeek, accuracy: 0.0001)
    }

    /// Total must not move: adding the partition changed nothing about how
    /// daysPerWeek itself is derived, so it still equals loggedDays/weeks.
    @MainActor
    func testTotalIsUnchangedByThePartition() {
        let context = makeContext()
        let lifted = lift(on: day(-5), context: context)
        let (walked, activity) = walk(on: day(-4), context: context)
        let both = lift(on: day(-3), context: context)
        let (bothWalk, bothActivity) = walk(on: day(-3), context: context)

        let result = stats([lifted, walked, both, bothWalk],
                           activities: [activity, bothActivity], startOffset: -6)
        // 4 sessions across 3 distinct dates -> Total is a DAY count.
        XCTAssertEqual(result.daysPerWeek, perWeek(3, result), accuracy: 0.001)
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

    // MARK: - The second identity: Active + Rest == Days since start
    //
    // Rest is the arithmetic complement of Active, so this is the other
    // half of what makes the table a partition: together with
    // Lift + Walk == Active, every day since the start date lands in
    // exactly one of Lift, Walk, Rest.

    @MainActor
    func testActivePlusRestEqualsDaysSinceStart() {
        let context = makeContext()
        let a = lift(on: day(-6), context: context)
        let b = lift(on: day(-4), context: context)
        let (w, activity) = walk(on: day(-2), context: context)
        let result = stats([a, b, w], activities: [activity], startOffset: -6)

        XCTAssertEqual(result.consistencyActive.daysLogged + result.consistencyRest.daysLogged,
                       result.daysSinceStart,
                       "Active + Rest must account for every day since the start date")
        XCTAssertEqual(result.consistencyLift.daysLogged + result.consistencyWalk.daysLogged,
                       result.consistencyActive.daysLogged,
                       "Lift + Walk must still partition Active")
        XCTAssertEqual(result.consistencyLift.daysLogged, 2)
        XCTAssertEqual(result.consistencyWalk.daysLogged, 1)
        XCTAssertEqual(result.consistencyActive.daysLogged, 3)
        XCTAssertEqual(result.consistencyRest.daysLogged, result.daysSinceStart - 3)
    }

    @MainActor
    func testRestIsZeroWhenEveryDayIsLogged() {
        let context = makeContext()
        // Every day of a 4-day window logged. The window ends yesterday,
        // not today, while today is still unlogged — so seeding -3...-1
        // fills it exactly.
        let sessions = (-3...(-1)).map { lift(on: day($0), context: context) }
        let result = stats(sessions, startOffset: -3)

        XCTAssertEqual(result.consistencyActive.daysLogged, result.daysSinceStart)
        XCTAssertEqual(result.consistencyRest.daysLogged, 0,
                       "no gaps means no rest days")
        XCTAssertEqual(result.consistencyRest.daysPerWeek, 0, accuracy: 0.0001)
    }

    @MainActor
    func testEveryColumnsDaysPerWeekMatchesItsDayCount() {
        let context = makeContext()
        let a = lift(on: day(-8), context: context)
        let (w, activity) = walk(on: day(-5), context: context)
        let result = stats([a, w], activities: [activity], startOffset: -9)

        // The four columns must share one denominator, or the rows can't
        // be read across.
        for col in [result.consistencyActive, result.consistencyLift,
                    result.consistencyWalk, result.consistencyRest] {
            XCTAssertEqual(col.daysPerWeek, perWeek(Double(col.daysLogged), result), accuracy: 0.0001)
        }
    }

    // MARK: - % of days
    //
    // Asserted on percentOfDays itself, never on the "%.1f%%" strings the
    // table renders — at one decimal the four cells don't always foot
    // (91.25 + 8.75 displays as 91.3 + 8.8), so a string-level assertion
    // would either fail on a correct value or, worse, be loosened until it
    // stopped catching a real break.

    @MainActor
    func testPercentIdentitiesHold() {
        let context = makeContext()
        let a = lift(on: day(-6), context: context)
        let b = lift(on: day(-4), context: context)
        let (w, activity) = walk(on: day(-2), context: context)
        let result = stats([a, b, w], activities: [activity], startOffset: -6)

        XCTAssertEqual(result.consistencyLift.percentOfDays + result.consistencyWalk.percentOfDays,
                       result.consistencyActive.percentOfDays, accuracy: 1e-12,
                       "Lift% + Walk% must equal Active%")
        XCTAssertEqual(result.consistencyActive.percentOfDays + result.consistencyRest.percentOfDays,
                       1.0, accuracy: 1e-12,
                       "Active% + Rest% must equal 100%")
    }

    @MainActor
    func testActivePercentIsExactlyPercentLogged() {
        let context = makeContext()
        let a = lift(on: day(-5), context: context)
        let (w, activity) = walk(on: day(-3), context: context)
        let result = stats([a, w], activities: [activity], startOffset: -9)

        // Bit-identical, not merely close: both are the same daysLogged
        // over the same daysSinceStart, which is the whole reason the
        // standalone "% of days logged" row could be removed. `accuracy`
        // would let a genuine divergence through.
        XCTAssertEqual(result.consistencyActive.percentOfDays, result.percentLogged,
                       "the Active cell must BE percentLogged, not approximate it")
    }

    @MainActor
    func testEachColumnsPercentMatchesItsOwnDayCount() {
        let context = makeContext()
        let a = lift(on: day(-8), context: context)
        let b = lift(on: day(-7), context: context)
        let (w, activity) = walk(on: day(-5), context: context)
        let result = stats([a, b, w], activities: [activity], startOffset: -9)

        for col in [result.consistencyActive, result.consistencyLift,
                    result.consistencyWalk, result.consistencyRest] {
            XCTAssertEqual(col.percentOfDays,
                           Double(col.daysLogged) / Double(result.daysSinceStart),
                           accuracy: 1e-12,
                           "every column must share daysSinceStart as its denominator")
        }
    }

    @MainActor
    func testPercentIdentitiesHoldWithNoRestDays() {
        let context = makeContext()
        let sessions = (-3...(-1)).map { lift(on: day($0), context: context) }
        let result = stats(sessions, startOffset: -3)

        XCTAssertEqual(result.consistencyRest.percentOfDays, 0, accuracy: 1e-12)
        XCTAssertEqual(result.consistencyActive.percentOfDays, 1.0, accuracy: 1e-12,
                       "every day logged means Active is the whole window")
        XCTAssertEqual(result.consistencyActive.percentOfDays + result.consistencyRest.percentOfDays,
                       1.0, accuracy: 1e-12)
    }

    // MARK: - % of days, as RENDERED
    //
    // The tests above assert the identities on the underlying Doubles.
    // These assert them on the formatted strings, because that's the layer
    // that was actually breaking: rounding four independent cells to one
    // decimal broke the visible sum ~23.5% of the time. See
    // ConsistencyPercentCell.

    /// The four cells as the table renders them, stripped of the "%".
    private func renderedPercents(_ s: TrainingStats) -> (active: Double, lift: Double,
                                                          walk: Double, rest: Double) {
        func cell(_ header: String) -> Double {
            let text = ConsistencyPercentCell.text(header: header,
                                                   active: s.consistencyActive.percentOfDays,
                                                   lift: s.consistencyLift.percentOfDays)
            return Double(text.replacingOccurrences(of: "%", with: "")) ?? .nan
        }
        return (cell("Active"), cell("Lift"), cell("Walk"), cell("Rest"))
    }

    @MainActor
    func testRenderedPercentsFootOnRealShapedData() {
        let context = makeContext()
        let a = lift(on: day(-6), context: context)
        let b = lift(on: day(-4), context: context)
        let (w, activity) = walk(on: day(-2), context: context)
        let result = stats([a, b, w], activities: [activity], startOffset: -6)
        let p = renderedPercents(result)

        XCTAssertEqual(p.lift + p.walk, p.active, accuracy: 1e-9,
                       "Lift% + Walk% must foot as DISPLAYED, not only underneath")
        XCTAssertEqual(p.active + p.rest, 100, accuracy: 1e-9,
                       "Active% + Rest% must foot as DISPLAYED")
    }

    /// The exact case that motivated the plug: 73/51/22/7 of 80 days.
    /// Active's 91.25 is an exact tie that "%.1f" takes DOWN to 91.2,
    /// while Lift's (51/80)*100 is 63.74999999999999 — just under its own
    /// tie — and also rounds down. Rounding the cells independently only
    /// happens to foot here because of that pairing; computing Lift as the
    /// algebraically equal 100*51/80 gives exactly 63.75, which ties UP to
    /// 63.8 and breaks the row. The plug removes that dependence.
    func testTheEightyDayShapeRendersUnchangedAndFoots() {
        let active = 73.0 / 80, lift = 51.0 / 80
        func cell(_ h: String) -> String {
            ConsistencyPercentCell.text(header: h, active: active, lift: lift)
        }
        XCTAssertEqual(cell("Active"), "91.2%")
        XCTAssertEqual(cell("Lift"), "63.7%")
        XCTAssertEqual(cell("Walk"), "27.5%")
        XCTAssertEqual(cell("Rest"), "8.8%")

        // The fragility being removed, shown directly: the same Lift share
        // reached by the other order of operations is a tie that goes up.
        XCTAssertEqual(String(format: "%.1f", (51.0 / 80) * 100), "63.7")
        XCTAssertEqual(String(format: "%.1f", 100 * 51.0 / 80), "63.8")
    }

    /// Walks every column shape in a realistic window and checks both the
    /// footing and the size of the plug's error, then asserts ONCE on what
    /// it found. Deliberately not an XCTAssert per shape: at ~14k shapes
    /// that's ~55k assertions, and XCTest's per-assertion bookkeeping took
    /// the whole suite from 13s to nearly four minutes. Failures are
    /// reported with the exact shape that broke, so collapsing them costs
    /// no diagnostic value.
    func testRenderedPercentsFootAndPlugErrorStaysBounded() {
        var breaks: [String] = []
        var worstWalk = 0.0, worstRest = 0.0
        var worstShape = ""

        for days in stride(from: 30, through: 120, by: 7) {
            for activeDays in 0...days {
                for liftDays in stride(from: 0, through: activeDays, by: max(1, activeDays / 12)) {
                    let active = Double(activeDays) / Double(days)
                    let lift = Double(liftDays) / Double(days)
                    func value(_ h: String) -> Double {
                        Double(ConsistencyPercentCell.text(header: h, active: active, lift: lift)
                            .replacingOccurrences(of: "%", with: "")) ?? .nan
                    }
                    let a = value("Active"), l = value("Lift")
                    let w = value("Walk"), r = value("Rest")
                    let shape = "\(liftDays)L/\(activeDays)A of \(days)d"
                    if abs(l + w - a) > 1e-9 { breaks.append("Lift+Walk at \(shape)") }
                    if abs(a + r - 100) > 1e-9 { breaks.append("Active+Rest at \(shape)") }

                    // How far each plugged cell sits from what it would
                    // have rendered on its own.
                    let walkErr = abs(w - Double(activeDays - liftDays) / Double(days) * 100)
                    let restErr = abs(r - Double(days - activeDays) / Double(days) * 100)
                    if max(walkErr, restErr) > max(worstWalk, worstRest) { worstShape = shape }
                    worstWalk = max(worstWalk, walkErr)
                    worstRest = max(worstRest, restErr)
                }
            }
        }

        XCTAssertEqual(breaks.count, 0,
                       "the rendered row must always foot; first breaks: \(breaks.prefix(5))")
        // The plug's price, and the bound being accepted. A derived cell
        // is at most one rounding step (0.1pp) from its own true value —
        // if this ever exceeds that, the plug is doing something other
        // than absorbing rounding.
        XCTAssertLessThanOrEqual(worstWalk, 0.1 + 1e-9, "worst Walk divergence at \(worstShape)")
        XCTAssertLessThanOrEqual(worstRest, 0.1 + 1e-9, "worst Rest divergence at \(worstShape)")
    }

    // MARK: - The streak halves

    @MainActor
    func testStreakColumnsPartitionTheSameWayTheCountsDo() {
        let context = makeContext()
        // Three consecutive days: lift, lift+walk, walk. The middle day
        // belongs to Lift, so Lift runs 2 and Walk runs 1.
        let a = lift(on: day(-4), context: context)
        let b = lift(on: day(-3), context: context)
        let (bothWalk, bothActivity) = walk(on: day(-3), context: context)
        let (w, activity) = walk(on: day(-2), context: context)
        let result = stats([a, b, bothWalk, w],
                           activities: [bothActivity, activity], startOffset: -6)

        XCTAssertEqual(result.consistencyActive.maxStreak, 3,
                       "all three days are active days in a row")
        XCTAssertEqual(result.consistencyLift.maxStreak, 2,
                       "the both-day extends the lift streak, not the walk one")
        XCTAssertEqual(result.consistencyWalk.maxStreak, 1)
    }

    @MainActor
    func testRestStreakCountsTheGapAndLeavesTodayPending() {
        let context = makeContext()
        // Active on -7 and -2, so the gap is -6...-3 — four rest days —
        // and the open run since -2 is just yesterday, since today isn't a
        // rest day until it ends unlogged.
        let a = lift(on: day(-7), context: context)
        let b = lift(on: day(-2), context: context)
        let result = stats([a, b], startOffset: -7)

        XCTAssertEqual(result.consistencyRest.maxStreak, 4,
                       "the -6...-3 gap is four rest days")
        XCTAssertEqual(result.consistencyRest.currentStreak, 1,
                       "yesterday only — today stays pending until it ends unlogged")
    }

    @MainActor
    func testRestStreakIsZeroOnADayYouTrained() {
        let context = makeContext()
        let a = lift(on: day(-4), context: context)
        let b = lift(on: today, context: context)
        let result = stats([a, b], startOffset: -6)

        XCTAssertEqual(result.consistencyRest.currentStreak, 0,
                       "training today ends the rest run outright")
        XCTAssertEqual(result.consistencyRest.maxStreak, 3, "the -3...-1 gap")
    }
}
