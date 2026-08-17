//
//  MilesWalkedTests.swift
//  TheJymTests
//
//  StatsEngine.compute's miles-walked totals: since Training Start Date,
//  within the active phase, YTD/MTD (current + prior year), and all-time —
//  all summed from RestDayActivity.distance entries whose distanceUnit is
//  literally "mi" (a "km" entry is excluded, not converted).
//

import XCTest
import SwiftData
@testable import TheJym

final class MilesWalkedTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self,
                 Phase.self, PhaseDay.self, PlannedExercise.self,
                 WorkoutSession.self, ExerciseLog.self, SetLog.self,
                 BodyWeightEntry.self, RestDayActivity.self,
                 ActiveRecovery.self, TrainingDaysPerWeekChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @MainActor
    @discardableResult
    private func activity(_ name: String, on date: Date, miles: Double?, unit: String = "mi",
                          context: ModelContext) -> RestDayActivity {
        let a = RestDayActivity(date: date, name: name, distance: miles, distanceUnit: unit)
        context.insert(a)
        return a
    }

    /// "Since start" only counts entries within [Training Start Date, today],
    /// and only entries tagged "mi" — a "km" entry (or one before the start
    /// date, or after "today") is excluded.
    @MainActor
    func testMilesSinceStartSumsOnlyMileEntriesWithinWindow() {
        let context = makeContext()
        let start = date(2026, 1, 1)
        let today = date(2026, 1, 31)
        activity("Walk", on: date(2025, 12, 31), miles: 5, context: context)       // before start
        activity("Walk", on: date(2026, 1, 10), miles: 3.1, context: context)      // in window, mi
        activity("Bike", on: date(2026, 1, 15), miles: 8, unit: "km", context: context) // in window, not mi
        activity("Walk", on: date(2026, 1, 20), miles: 2.4, context: context)      // in window, mi
        activity("Walk", on: date(2026, 2, 1), miles: 100, context: context)       // after today
        let allActivities = try! context.fetch(FetchDescriptor<RestDayActivity>())

        let stats = StatsEngine.compute(startDate: start,
                                        sessionDates: [today],
                                        restActivityDates: allActivities.map(\.date),
                                        restActivities: allActivities,
                                        now: today)
        XCTAssertEqual(stats.milesSinceStart, 5.5, accuracy: 1e-9)
    }

    /// "This phase" is nil with no active phase, and otherwise only counts
    /// entries from the active phase's own start date onward.
    @MainActor
    func testMilesThisPhaseNilWithoutActivePhaseAndScopedToPhaseStart() {
        let context = makeContext()
        let phaseStart = date(2026, 1, 15)
        let today = date(2026, 1, 31)
        let phase = Phase(number: 1, totalCycles: 100, startDate: phaseStart)
        context.insert(phase)
        activity("Walk", on: date(2026, 1, 10), miles: 9, context: context)   // before phase start
        activity("Walk", on: date(2026, 1, 20), miles: 4, context: context)   // during phase
        let allActivities = try! context.fetch(FetchDescriptor<RestDayActivity>())

        let withPhase = StatsEngine.compute(startDate: date(2026, 1, 1), sessionDates: [today],
                                            restActivityDates: allActivities.map(\.date),
                                            allPhases: [phase], activePhase: phase,
                                            restActivities: allActivities, now: today)
        XCTAssertEqual(withPhase.milesThisPhase ?? -1, 4, accuracy: 1e-9)

        let withoutPhase = StatsEngine.compute(startDate: date(2026, 1, 1), sessionDates: [today],
                                               restActivityDates: allActivities.map(\.date),
                                               restActivities: allActivities, now: today)
        XCTAssertNil(withoutPhase.milesThisPhase)
    }

    /// YTD/MTD (and their prior-year counterparts) and the unbounded
    /// all-time total, each isolated to its own calendar window.
    @MainActor
    func testYtdMtdAndAllTimeMiles() {
        let context = makeContext()
        let today = date(2026, 3, 15)
        activity("Walk", on: date(2025, 3, 10), miles: 1, context: context)   // prior-year YTD + MTD
        activity("Walk", on: date(2025, 6, 1), miles: 2, context: context)    // prior year, outside PY-YTD window (after PY "today")
        activity("Walk", on: date(2026, 2, 1), miles: 4, context: context)    // this year, before this month
        activity("Walk", on: date(2026, 3, 5), miles: 8, context: context)    // this month
        let allActivities = try! context.fetch(FetchDescriptor<RestDayActivity>())

        let stats = StatsEngine.compute(startDate: date(2020, 1, 1), sessionDates: [today],
                                        restActivityDates: allActivities.map(\.date),
                                        restActivities: allActivities, now: today)

        XCTAssertEqual(stats.ytdMiles, 12, accuracy: 1e-9)          // Feb 1 (4) + Mar 5 (8)
        XCTAssertEqual(stats.mtdMiles, 8, accuracy: 1e-9)           // Mar 5 only
        XCTAssertEqual(stats.priorYearYtdMiles, 1, accuracy: 1e-9)  // Mar 10 2025 only (June 2025 is after PY "today")
        XCTAssertEqual(stats.priorYearMtdMiles, 1, accuracy: 1e-9)  // Mar 10 2025 only
        XCTAssertEqual(stats.allTimeMiles, 15, accuracy: 1e-9)      // every entry, unbounded
    }
}
