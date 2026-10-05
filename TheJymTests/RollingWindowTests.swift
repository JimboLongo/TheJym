//
//  RollingWindowTests.swift
//  TheJymTests
//
//  The Stats page's "last N days" table. Two identities have to hold on
//  every row, and the denominator rule is the thing most likely to be
//  "fixed" into agreeing with the Consistency table by someone who hasn't
//  read RollingWindow's doc — so it's pinned here too.
//

import XCTest
import SwiftData
@testable import TheJym

final class RollingWindowTests: XCTestCase {
    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: .now) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

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

    private func stats(_ sessions: [WorkoutSession], activities: [RestDayActivity] = [],
                       startOffset: Int) -> TrainingStats {
        StatsEngine.compute(startDate: day(startOffset),
                            sessionDates: sessions.filter { !$0.exerciseLogs.isEmpty }.map(\.date),
                            restActivityDates: activities.map(\.date),
                            restActivities: activities,
                            allSessions: sessions,
                            now: .now)
    }

    // MARK: - The two identities

    @MainActor
    func testBothIdentitiesHoldOnEveryWindow() {
        let context = makeContext()
        var sessions: [WorkoutSession] = []
        var activities: [RestDayActivity] = []
        // A spread reaching past 365 days so every window is exercised,
        // including days that fall outside the longest one.
        for offset in [-400, -300, -200, -150, -100, -95, -70, -40, -20, -10, -5, -2, -1] {
            sessions.append(lift(on: day(offset), context: context))
        }
        for offset in [-370, -250, -111, -88, -55, -33, -11, -3] {
            let (s, a) = walk(on: day(offset), context: context)
            sessions.append(s); activities.append(a)
        }
        // A day with BOTH, which must land in Lift and not be counted twice.
        let bothLift = lift(on: day(-60), context: context)
        let (bothWalk, bothActivity) = walk(on: day(-60), context: context)
        sessions += [bothLift, bothWalk]; activities.append(bothActivity)

        let result = stats(sessions, activities: activities, startOffset: -120)
        XCTAssertEqual(result.rollingWindows.map(\.days), [30, 60, 90, 120, 180, 365])

        for w in result.rollingWindows {
            XCTAssertEqual(w.lift + w.walk, w.active,
                           "Lift + Walk must equal Active on the \(w.days)-day window")
            XCTAssertEqual(w.active + w.rest, w.days,
                           "Active + Rest must equal the window length on \(w.days)")
            XCTAssertGreaterThanOrEqual(w.rest, 0, "\(w.days)-day window went negative")
        }
    }

    @MainActor
    func testWindowsAreNestedAndMonotonic() {
        let context = makeContext()
        let sessions = (1...200).map { lift(on: day(-$0), context: context) }
        let result = stats(sessions, startOffset: -200)
        // Each window contains the one before it, so no count can shrink.
        for (smaller, larger) in zip(result.rollingWindows, result.rollingWindows.dropFirst()) {
            XCTAssertLessThanOrEqual(smaller.active, larger.active)
            XCTAssertLessThanOrEqual(smaller.lift, larger.lift)
            XCTAssertLessThanOrEqual(smaller.walk, larger.walk)
        }
    }

    // MARK: - The denominator

    /// The rule most at risk of being "reconciled" with the Consistency
    /// table: the divisor is the WINDOW, never daysSinceStart. With 10
    /// days of history the 365-day row must read 355 Rest, not 0.
    @MainActor
    func testDenominatorIsTheWindowNotDaysSinceStart() {
        let context = makeContext()
        let sessions = (1...10).map { lift(on: day(-$0), context: context) }
        let result = stats(sessions, startOffset: -10)

        let year = result.rollingWindows.first { $0.days == 365 }!
        XCTAssertEqual(year.active, 10)
        XCTAssertEqual(year.rest, 355, "days before any data exist count as Rest")
        XCTAssertEqual(year.percent(for: "Active"), 10.0 / 365 * 100, accuracy: 0.0001)

        // ...and the shorter window over the same data reads differently,
        // which is the whole point of having more than one row.
        let thirty = result.rollingWindows.first { $0.days == 30 }!
        XCTAssertEqual(thirty.active, 10)
        XCTAssertNotEqual(thirty.percent(for: "Active"), year.percent(for: "Active"))
    }

    // MARK: - The window anchor
    //
    // Windows end at effectiveToday, not today: an unlogged today
    // shouldn't drag every percentage down just because it's 9am. Both
    // branches seed a solid run of 30 lift days and expect a perfect
    // 30/30 — which only comes out right if the window sits where it
    // should. Under the other anchor each case loses a day off one end
    // and reads 29.

    /// Nothing logged today, so the window is the 30 days ending
    /// YESTERDAY: day(-30) ... day(-1).
    @MainActor
    func testWindowEndsYesterdayWhenNothingIsLoggedToday() {
        let context = makeContext()
        let sessions = (1...30).map { lift(on: day(-$0), context: context) }
        let result = stats(sessions, startOffset: -60)

        let thirty = result.rollingWindows.first { $0.days == 30 }!
        XCTAssertEqual(thirty.active, 30,
                       "the window should cover day(-30)...day(-1) exactly; anchoring at today would drop day(-30) and leave 29")
        XCTAssertEqual(thirty.rest, 0,
                       "an unlogged today must be excluded from the window, not counted as a Rest day inside it")
        XCTAssertEqual(thirty.percent(for: "Active"), 100, accuracy: 0.0001)
    }

    /// Something logged today, so the window ends TODAY:
    /// day(-29) ... day(0).
    @MainActor
    func testWindowEndsTodayWhenSomethingIsLoggedToday() {
        let context = makeContext()
        let sessions = (0...29).map { lift(on: day(-$0), context: context) }
        let result = stats(sessions, startOffset: -60)

        let thirty = result.rollingWindows.first { $0.days == 30 }!
        XCTAssertEqual(thirty.active, 30,
                       "the window should cover day(-29)...today exactly")
        XCTAssertEqual(thirty.rest, 0)
    }

    /// The boundary day itself, isolated: day(-30) is inside the window
    /// when today is unlogged and outside it when today is logged.
    @MainActor
    func testTheOldestIncludedDayShiftsWithTheAnchor() {
        let unloggedToday = makeContext()
        let onlyOld = lift(on: day(-30), context: unloggedToday)
        let shifted = stats([onlyOld], startOffset: -60)
        XCTAssertEqual(shifted.rollingWindows.first { $0.days == 30 }!.active, 1,
                       "with today unlogged the window reaches back to day(-30)")

        let loggedToday = makeContext()
        let old = lift(on: day(-30), context: loggedToday)
        let now = lift(on: day(0), context: loggedToday)
        let anchored = stats([old, now], startOffset: -60)
        XCTAssertEqual(anchored.rollingWindows.first { $0.days == 30 }!.active, 1,
                       "logging today pushes day(-30) out — only today remains inside")
    }

    @MainActor
    func testADayWithBothALiftAndAWalkCountsOnceAsLift() {
        let context = makeContext()
        let lifted = lift(on: day(-5), context: context)
        let (walked, activity) = walk(on: day(-5), context: context)
        let result = stats([lifted, walked], activities: [activity], startOffset: -30)

        let thirty = result.rollingWindows.first { $0.days == 30 }!
        XCTAssertEqual(thirty.active, 1, "one calendar day, not two")
        XCTAssertEqual(thirty.lift, 1)
        XCTAssertEqual(thirty.walk, 0, "the walk must not also count")
    }

    @MainActor
    func testNoDataGivesAllRest() {
        let result = stats([], startOffset: -30)
        for w in result.rollingWindows {
            XCTAssertEqual(w.active, 0)
            XCTAssertEqual(w.rest, w.days)
            XCTAssertEqual(w.percent(for: "Rest"), 100, accuracy: 0.0001)
        }
    }

    /// Days older than the longest window are dropped entirely rather
    /// than quietly inflating it.
    @MainActor
    func testDaysBeyondThreeSixtyFiveAreExcluded() {
        let context = makeContext()
        let old = lift(on: day(-400), context: context)
        let recent = lift(on: day(-3), context: context)
        let result = stats([old, recent], startOffset: -400)

        let year = result.rollingWindows.first { $0.days == 365 }!
        XCTAssertEqual(year.active, 1, "the 400-day-old session is outside every window")
    }
}
