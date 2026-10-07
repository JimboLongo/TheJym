//
//  ConsistencyRateInvariantTests.swift
//  TheJymTests
//
//  Structural invariants on the Consistency table's rates, which hold for
//  ANY data rather than for a particular fixture:
//
//    1. No column's daysPerWeek can exceed 7.0. There are seven days in a
//       week; a column counts DAYS, so it cannot report more of them per
//       week than exist.
//    2. Every column divides by the SAME denominator, and that denominator
//       is daysSinceStart / 7 — not a rolling window, not the column's own
//       span. So daysLogged / daysPerWeek must come out identical across
//       all four columns.
//
//  These exist because the table is read as a grid of related numbers, and
//  a denominator drifting on one column produces figures that look
//  plausible cell-by-cell while being arithmetically impossible together
//  (7.7 lift days in a 7-day week; 77 distinct days inside a 49-day span).
//  Eyeballing catches that only if someone happens to do the division.
//

import XCTest
import SwiftData
@testable import TheJym

final class ConsistencyRateInvariantTests: XCTestCase {
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

    private func columns(_ s: TrainingStats) -> [(String, ConsistencyColumn)] {
        [("Active", s.consistencyActive), ("Lift", s.consistencyLift),
         ("Walk", s.consistencyWalk), ("Rest", s.consistencyRest)]
    }

    /// Both invariants, on one TrainingStats.
    private func assertRateInvariants(_ s: TrainingStats, _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let expectedWeeks = Double(s.daysSinceStart) / 7.0
        for (name, col) in columns(s) {
            XCTAssertLessThanOrEqual(col.daysPerWeek, 7.0 + 1e-9,
                                     "\(label): \(name) reports \(col.daysPerWeek) days per week — there are only 7",
                                     file: file, line: line)
            guard col.daysLogged > 0 else { continue }
            let impliedWeeks = Double(col.daysLogged) / col.daysPerWeek
            XCTAssertEqual(impliedWeeks, expectedWeeks, accuracy: 1e-6,
                           "\(label): \(name) divides by \(impliedWeeks) weeks, but daysSinceStart/7 is \(expectedWeeks)",
                           file: file, line: line)
        }
    }

    // MARK: - The invariants, across every shape

    @MainActor
    func testRateInvariantsOnARealisticSpan() {
        let context = makeContext()
        var sessions: [WorkoutSession] = []
        var activities: [RestDayActivity] = []
        // ~79 days, lifting most weekdays and walking on some others —
        // the shape of real use.
        for offset in stride(from: -78, through: -1, by: 1) {
            switch offset % 7 {
            case 0, -1, -2, -4:
                sessions.append(lift(on: day(offset), context: context))
            case -3, -5:
                let (s, a) = walk(on: day(offset), context: context)
                sessions.append(s); activities.append(a)
            default:
                break   // genuine rest day
            }
        }
        let result = stats(sessions, activities: activities, startOffset: -78)
        assertRateInvariants(result, "realistic 79-day span")

        // And the figure that started this: Active per week must be
        // plausible for the span, not wildly above it.
        XCTAssertGreaterThan(result.consistencyActive.daysPerWeek, 0)
        XCTAssertLessThan(result.consistencyActive.daysPerWeek, 7.0)
    }

    @MainActor
    func testRateInvariantsWhenEveryDayIsLogged() {
        let context = makeContext()
        // The only case that may legitimately touch the ceiling: every
        // single day active means exactly 7.0 per week, never more.
        let sessions = (1...28).map { lift(on: day(-$0), context: context) }
        let result = stats(sessions, startOffset: -28)
        assertRateInvariants(result, "every day logged")
        XCTAssertLessThanOrEqual(result.consistencyActive.daysPerWeek, 7.0 + 1e-9)
    }

    @MainActor
    func testRateInvariantsWithMultipleSessionsPerDay() {
        let context = makeContext()
        // Two sessions on one day is still ONE day — the shape that would
        // push a rate past 7.0 if a column ever counted sessions.
        var sessions: [WorkoutSession] = []
        var activities: [RestDayActivity] = []
        for offset in 1...20 {
            sessions.append(lift(on: day(-offset), context: context))
            sessions.append(lift(on: day(-offset), context: context))
            let (s, a) = walk(on: day(-offset), context: context)
            sessions.append(s); activities.append(a)
        }
        let result = stats(sessions, activities: activities, startOffset: -20)
        assertRateInvariants(result, "three sessions per day")
        XCTAssertLessThanOrEqual(result.consistencyActive.daysPerWeek, 7.0 + 1e-9,
                                 "sessions must not be counted as days")
    }

    @MainActor
    func testRateInvariantsWithNoData() {
        assertRateInvariants(stats([], startOffset: -30), "no data")
    }

    @MainActor
    func testRateInvariantsOnAOneDayWindow() {
        let context = makeContext()
        let s = lift(on: today, context: context)
        assertRateInvariants(stats([s], startOffset: 0), "single day")
    }

    /// Prints the four cells of both rate rows as the table actually
    /// renders them, so a claimed sample can be checked against engine
    /// output rather than taken on trust.
    @MainActor
    func testPrintRenderedRowsForInspection() {
        let context = makeContext()
        var sessions: [WorkoutSession] = []
        var activities: [RestDayActivity] = []
        for offset in stride(from: -78, through: -1, by: 1) {
            switch offset % 7 {
            case 0, -1, -2, -4:
                sessions.append(lift(on: day(offset), context: context))
            case -3, -5:
                let (s, a) = walk(on: day(offset), context: context)
                sessions.append(s); activities.append(a)
            default:
                break
            }
        }
        let r = stats(sessions, activities: activities, startOffset: -78)
        print("ENGINE OUTPUT  daysSinceStart=\(r.daysSinceStart)  weeks=\(Double(r.daysSinceStart)/7.0)")
        print("  Days per week  " + columns(r).map { String(format: "%6.2f", $0.1.daysPerWeek) }.joined())
        print("  Days logged    " + columns(r).map { String(format: "%6d", $0.1.daysLogged) }.joined())
        for (name, col) in columns(r) where col.daysLogged > 0 {
            print(String(format: "  %-7@ implies %.4f weeks", name as NSString,
                         Double(col.daysLogged) / col.daysPerWeek))
        }
    }
}
