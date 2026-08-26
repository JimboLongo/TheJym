//
//  PhaseFilledSlotCountTests.swift
//  TheJymTests
//
//  Regression coverage for a double-count bug: once a phase completes,
//  cycleWalk's currentCycle clamps back down to totalCycles (the same
//  cycle completedCycles already counted), so filledSlotCount's
//  completedCycles*orderedDays.count term and its +filledSlotIDs.count
//  term both counted the final cycle — e.g. 8*6 + 6 = 54 instead of 48
//  for an 8-cycle, 6-day phase. Also covers the two Stats consumers that
//  read straight off filledSlotCount (cyclePaceDelta, adherencePercent),
//  which were reporting the same inflation without their own separate bug.
//

import XCTest
import SwiftData
@testable import TheJym

final class PhaseFilledSlotCountTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// 6 days per cycle, matching the reported scenario: Lower A, Upper A,
    /// Rest, Lower B, Upper B, Rest.
    @MainActor
    private func makeSixDayPhase(totalCycles: Int, context: ModelContext) -> (phase: Phase, days: [PhaseDay]) {
        let phase = Phase(number: 1, totalCycles: totalCycles, isActive: true)
        context.insert(phase)
        let names: [(String, Bool)] = [("Lower A", false), ("Upper A", false), ("Rest", true),
                                       ("Lower B", false), ("Upper B", false), ("Rest", true)]
        var days: [PhaseDay] = []
        for (i, entry) in names.enumerated() {
            let day = PhaseDay(order: i, name: entry.0, isRest: entry.1)
            day.phase = phase
            context.insert(day)
            days.append(day)
        }
        return (phase, days)
    }

    /// Saves after every insert (unlike PerfectCycleTests' own `log`
    /// helper, which doesn't need to since it never spans more than one
    /// cycle) — matches WorkoutLogView.finishWorkout's real behavior of
    /// saving once per logged day.
    @MainActor
    @discardableResult
    private func log(_ day: PhaseDay, on date: Date, phase: Phase, context: ModelContext) -> WorkoutSession {
        let session = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: phase.currentCycle)
        session.phase = phase
        context.insert(session)
        try? context.save()
        return session
    }

    /// Logs `totalCycles` full cycles of `days`, one slot per calendar day,
    /// ending exactly `endingDaysAgo` days before now — displayCycleWalk's
    /// freeze (anything on/after the start of today) needs every session
    /// dated strictly in the past to behave like a real logging history,
    /// not the future-dated sessions a naive "start at Date() and count
    /// forward" helper would produce.
    @MainActor
    private func logFullPhase(_ phase: Phase, days: [PhaseDay], totalCycles: Int, endingDaysAgo: Int, context: ModelContext) {
        let totalSlots = totalCycles * days.count
        var date = Calendar.current.date(byAdding: .day, value: -(endingDaysAgo + totalSlots - 1), to: Date())!
        for _ in 1...totalCycles {
            for day in days {
                log(day, on: date, phase: phase, context: context)
                date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
            }
        }
    }

    @MainActor
    func testFilledSlotCountDoesNotDoubleCountTheFinalCycle() {
        let context = makeContext()
        let (phase, days) = makeSixDayPhase(totalCycles: 8, context: context)
        logFullPhase(phase, days: days, totalCycles: 8, endingDaysAgo: 1, context: context)
        try? context.save()

        XCTAssertTrue(phase.isComplete)
        XCTAssertEqual(phase.filledSlotCount, 48, "8 cycles * 6 days = 48, not 54 from double-counting the last cycle")
        XCTAssertEqual(phase.displayFilledSlotCount, 48)
    }

    @MainActor
    func testFilledSlotCountStillCountsAnInFlightPartialCycle() {
        let context = makeContext()
        let (phase, days) = makeSixDayPhase(totalCycles: 8, context: context)
        var date = Calendar.current.date(byAdding: .day, value: -45, to: Date())!
        for _ in 1...7 {
            for day in days {
                log(day, on: date, phase: phase, context: context)
                date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
            }
        }
        // Cycle 8, only 2 of its 6 slots done.
        log(days[0], on: date, phase: phase, context: context)
        date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        log(days[1], on: date, phase: phase, context: context)
        try? context.save()

        XCTAssertFalse(phase.isComplete)
        XCTAssertEqual(phase.filledSlotCount, 7 * 6 + 2, "7 complete cycles plus 2 slots into the in-flight 8th")
    }

    @MainActor
    func testPaceAndAdherenceReadCorrectlyOnceThePhaseIsComplete() {
        let context = makeContext()
        let (phase, days) = makeSixDayPhase(totalCycles: 8, context: context)
        phase.startDate = Calendar.current.date(byAdding: .day, value: -51, to: Date())!
        logFullPhase(phase, days: days, totalCycles: 8, endingDaysAgo: 4, context: context)
        try? context.save()

        // 52 days elapsed (51 days ago through today, inclusive), 48 slots
        // filled — 4 behind, not the "2 ahead" the double-count produced.
        XCTAssertEqual(StatsEngine.cyclePaceDelta(for: phase), -4)
        XCTAssertLessThanOrEqual(StatsEngine.adherencePercent(for: phase), 100,
                                 "a finished phase should never read over 100% adherence")
    }
}
