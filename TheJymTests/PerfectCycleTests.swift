//
//  PerfectCycleTests.swift
//  TheJymTests
//
//  A cycle is "perfect" when every slot got filled within a calendar span no
//  wider than the pattern's own length (rest days included) plus one day of
//  slack. Covers the span check itself, that a bonus session (an
//  already-filled slot logged again) can't widen that span, the lifetime
//  count / current streak aggregated across a phase's completed cycles, and
//  the no-active-phase perfect-week fallback.
//

import XCTest
import SwiftData
@testable import TheJym

final class PerfectCycleTests: XCTestCase {
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

    /// Day A, Day B, Rest, Day C — 3 training slots per cycle, 4 days total
    /// in the pattern, so a perfect cycle needs all 3 slots filled within a
    /// 5-calendar-day span (4 + 1).
    @MainActor
    private func makeFourDayPhase(context: ModelContext, number: Int = 1) -> (phase: Phase, dayA: PhaseDay, dayB: PhaseDay, dayC: PhaseDay) {
        let phase = Phase(number: number, totalCycles: 100)
        context.insert(phase)
        let dayA = PhaseDay(order: 0, name: "Day A", isRest: false); dayA.phase = phase; context.insert(dayA)
        let dayB = PhaseDay(order: 1, name: "Day B", isRest: false); dayB.phase = phase; context.insert(dayB)
        let rest = PhaseDay(order: 2, name: "Rest", isRest: true); rest.phase = phase; context.insert(rest)
        let dayC = PhaseDay(order: 3, name: "Day C", isRest: false); dayC.phase = phase; context.insert(dayC)
        return (phase, dayA, dayB, dayC)
    }

    @MainActor
    @discardableResult
    private func log(_ day: PhaseDay, on date: Date, phase: Phase, context: ModelContext) -> WorkoutSession {
        let session = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: 1)
        session.phase = phase
        context.insert(session)
        return session
    }

    private func d(_ daysFromNow: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date())!
    }

    @MainActor
    func testPerfectCycleWithinSpan() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        let rest = phase.orderedDays[2]
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(1), phase: phase, context: context)
        log(rest, on: d(2), phase: phase, context: context)
        log(dayC, on: d(3), phase: phase, context: context)   // span 0->3 = 4 days <= 5
        try? context.save()

        XCTAssertEqual(phase.perfectCycleFlags, [true])
    }

    @MainActor
    func testNotPerfectWhenSpanTooWide() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        let rest = phase.orderedDays[2]
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(1), phase: phase, context: context)
        log(rest, on: d(2), phase: phase, context: context)
        log(dayC, on: d(10), phase: phase, context: context)  // span 0->10 = 11 days > 5
        try? context.save()

        XCTAssertEqual(phase.perfectCycleFlags, [false])
    }

    @MainActor
    func testBonusSessionDoesNotDisqualify() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        let rest = phase.orderedDays[2]
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayA, on: d(20), phase: phase, context: context)  // bonus — Day A slot already filled
        log(dayB, on: d(1), phase: phase, context: context)
        log(rest, on: d(2), phase: phase, context: context)
        log(dayC, on: d(3), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.perfectCycleFlags, [true], "A bonus session's date shouldn't widen the span")
    }

    /// A cycle only completes once its Rest slot is explicitly logged too —
    /// finishing every training day isn't enough on its own.
    @MainActor
    func testCycleDoesNotCompleteUntilRestSlotIsExplicitlyLogged() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(1), phase: phase, context: context)
        log(dayC, on: d(3), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.currentCycle, 1, "All 3 training slots are filled, but Rest isn't — still cycle 1")
        XCTAssertFalse(phase.isComplete)

        let rest = phase.orderedDays[2]
        log(rest, on: d(4), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.currentCycle, 2, "Logging Rest is what actually completes the cycle")
    }

    /// The passive "nothing was logged" backfill credit (WorkoutSession with
    /// no `day` set) must never fill a Rest slot on its own — only an
    /// explicit Log Rest Day / rest-day activity, which sets `day`, can.
    @MainActor
    func testPassiveRestBackfillDoesNotFillTheRestSlot() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(1), phase: phase, context: context)
        log(dayC, on: d(3), phase: phase, context: context)
        // Passive backfill credit for a day nothing was logged — day: nil.
        let passive = WorkoutSession(date: d(4), dayLabel: "Rest Day", cycleNumber: 0)
        passive.phase = phase
        context.insert(passive)
        try? context.save()

        let rest = phase.orderedDays[2]
        XCTAssertFalse(phase.isSlotFilled(for: rest), "A day-less placeholder shouldn't fill the Rest slot")
        XCTAssertEqual(phase.currentCycle, 1)
    }

    @MainActor
    func testLifetimeCountAndStreakBreakOnImperfectCycle() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        let rest = phase.orderedDays[2]
        // Cycle 1: perfect.
        log(dayA, on: d(-30), phase: phase, context: context)
        log(dayB, on: d(-29), phase: phase, context: context)
        log(rest, on: d(-28), phase: phase, context: context)
        log(dayC, on: d(-27), phase: phase, context: context)
        // Cycle 2: not perfect — too spread out.
        log(dayA, on: d(-24), phase: phase, context: context)
        log(dayB, on: d(-20), phase: phase, context: context)
        log(rest, on: d(-10), phase: phase, context: context)
        log(dayC, on: d(-5), phase: phase, context: context)
        // Cycle 3: perfect.
        log(dayA, on: d(-4), phase: phase, context: context)
        log(dayB, on: d(-3), phase: phase, context: context)
        log(rest, on: d(-2), phase: phase, context: context)
        log(dayC, on: d(-1), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.perfectCycleFlags, [true, false, true])

        let stats = StatsEngine.compute(startDate: d(-30), sessionDates: [], allPhases: [phase], activePhase: phase)
        XCTAssertEqual(stats.perfectCycleLifetimeCount, 2)
        XCTAssertEqual(stats.perfectCycleCurrentStreak, 1, "Only the trailing perfect run counts — cycle 2 broke it")
        XCTAssertEqual(stats.activePhaseCycleProgress?.number, phase.number)
        XCTAssertEqual(stats.activePhaseCycleProgress?.perfectCount, 2)
        XCTAssertEqual(stats.activePhaseCycleProgress?.completedCount, 3)
        XCTAssertNil(stats.perfectWeekFallback, "Fallback is only for when there's no active phase")
    }

    @MainActor
    func testPerfectWeekFallbackWithNoActivePhase() {
        var mondayCal = Calendar.current
        mondayCal.firstWeekday = 2
        let today = mondayCal.startOfDay(for: Date())
        let currentWeekStart = mondayCal.date(from: mondayCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        func weekStart(_ weeksAgo: Int) -> Date {
            mondayCal.date(byAdding: .day, value: -7 * weeksAgo, to: currentWeekStart)!
        }
        func offset(_ date: Date, _ days: Int) -> Date {
            mondayCal.date(byAdding: .day, value: days, to: date)!
        }

        // Week -3: 3 sessions (meets the setting) -> perfect.
        // Week -2: 1 session (misses it) -> not perfect.
        // Week -1: 3 sessions -> perfect (the trailing run).
        let sessionDates = [
            weekStart(3), offset(weekStart(3), 2), offset(weekStart(3), 4),
            weekStart(2),
            weekStart(1), offset(weekStart(1), 2), offset(weekStart(1), 4),
        ]

        let stats = StatsEngine.compute(startDate: weekStart(3), sessionDates: sessionDates,
                                        activePhase: nil, defaultTrainingDaysPerWeek: 3)

        XCTAssertNil(stats.perfectCycleLifetimeCount)
        XCTAssertNil(stats.activePhaseCycleProgress)
        XCTAssertEqual(stats.perfectWeekFallback?.lifetimeCount, 2)
        XCTAssertEqual(stats.perfectWeekFallback?.currentStreak, 1)
    }
}
