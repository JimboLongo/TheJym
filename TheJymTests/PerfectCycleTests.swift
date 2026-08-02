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

    /// Assigns cycleNumber live via phase.currentCycle at insert time — same
    /// as WorkoutLogView.finishWorkout()/RestDayLogView do for the real app
    /// — so a test spanning multiple cycles gets correctly incrementing
    /// numbers automatically instead of every session colliding into one
    /// cycle. Relies on phase.sessions reflecting just-inserted-but-unsaved
    /// sessions within the same context (established elsewhere, e.g.
    /// ImportPhaseAttributionTests), so no context.save() is needed between
    /// calls for this to stay accurate.
    @MainActor
    @discardableResult
    private func log(_ day: PhaseDay, on date: Date, phase: Phase, context: ModelContext) -> WorkoutSession {
        let session = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: phase.currentCycle)
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

    /// The Train tab's display-frozen cycle number (Phase.displayCurrentCycle)
    /// shouldn't advance until the real midnight rollover, even though the
    /// authoritative currentCycle already reflects it the instant the last
    /// slot is logged — mirrors TodayView.templateNextDay's same-day
    /// carve-out for the featured row underneath it.
    @MainActor
    func testDisplayCycleDoesNotAdvanceUntilMidnight() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        let rest = phase.orderedDays[2]
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(0), phase: phase, context: context)
        log(rest, on: d(0), phase: phase, context: context)
        log(dayC, on: d(0), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.currentCycle, 2, "Data-wise the cycle completed the instant the last slot was logged")
        XCTAssertEqual(phase.displayCurrentCycle, 1, "But the Train tab shouldn't show that until midnight")
        XCTAssertFalse(phase.isSlotFilled(for: dayA), "Data-wise a fresh (already-rotated) cycle 2 is in progress, nothing filled yet")
        XCTAssertTrue(phase.isSlotFilledForDisplay(dayA), "But the display checklist should still show the just-finished cycle 1, fully checked")
    }

    /// Same carve-out applies to finishing a phase's very last cycle — the
    /// Train tab shouldn't swap to the "Phase Complete" screen mid-day
    /// either, even though Phase.isComplete already flips immediately.
    @MainActor
    func testDisplayIsCompleteWaitsForMidnightOnAPhasesFinalCycle() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        phase.totalCycles = 1
        let rest = phase.orderedDays[2]
        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(0), phase: phase, context: context)
        log(rest, on: d(0), phase: phase, context: context)
        log(dayC, on: d(0), phase: phase, context: context)
        try? context.save()

        XCTAssertTrue(phase.isComplete)
        XCTAssertFalse(phase.displayIsComplete, "Train tab shouldn't flip to the Phase Complete screen mid-day")
    }

    /// legacyCompletedCycles grandfathers a phase's pre-Rest-tracking
    /// progress in as a frozen floor — but the cycle that was still in
    /// progress at that moment (deliberately one short of the old-rule
    /// count — see the stamping doc in TheJymApp) has to earn its
    /// completion under the new Rest-aware rule like any other from then on.
    @MainActor
    func testLegacyBaselineIsHonoredButTheNextCycleStillNeedsRest() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        // Pass 1: old-style history — training only, Rest never logged for
        // it, same as a phase that progressed under the pre-Rest-tracking rule.
        log(dayA, on: d(-10), phase: phase, context: context)
        log(dayB, on: d(-9), phase: phase, context: context)
        log(dayC, on: d(-7), phase: phase, context: context)
        phase.legacyCompletedCycles = 1   // simulates the migration freezing this baseline
        try? context.save()

        XCTAssertEqual(phase.currentCycle, 2, "Baseline of 1 means cycle 2 is already in progress")

        log(dayA, on: d(0), phase: phase, context: context)
        log(dayB, on: d(1), phase: phase, context: context)
        log(dayC, on: d(3), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.currentCycle, 2, "Training alone doesn't complete this cycle — Rest still required")

        let rest = phase.orderedDays[2]
        log(rest, on: d(4), phase: phase, context: context)
        try? context.save()

        XCTAssertEqual(phase.currentCycle, 3, "Now cycle 2 is genuinely complete, on top of the baseline of 1")
    }

    /// Simulates the one-time repairMissingCycleNumbers migration
    /// (TheJymApp): sessions from before cycleNumber became authoritative
    /// sit at the `0` marker; Phase.legacyCycleNumbers() must assign every
    /// one of them a sensible, monotonically increasing cycle number, and
    /// once stamped, phase.currentCycle should show exactly what the OLD
    /// chronological algorithm already had visible — nothing jumps for
    /// existing history on upgrade.
    @MainActor
    func testLegacyCycleNumbersMigrationStampsSensibleValues() {
        let context = makeContext()
        let (phase, dayA, dayB, dayC) = makeFourDayPhase(context: context)
        let rest = phase.orderedDays[2]

        // Same shape any session created before this feature shipped would
        // have — cycleNumber left at its old, meaningless default.
        func logUntagged(_ day: PhaseDay, on date: Date) {
            let session = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: 0)
            session.phase = phase
            context.insert(session)
        }
        // Cycle 1: complete, Rest-aware.
        logUntagged(dayA, on: d(0))
        logUntagged(dayB, on: d(1))
        logUntagged(rest, on: d(2))
        logUntagged(dayC, on: d(3))
        // Cycle 2: in progress — two training days done, no Rest yet.
        logUntagged(dayA, on: d(4))
        logUntagged(dayB, on: d(5))
        try? context.save()

        XCTAssertTrue(phase.sessions.allSatisfy { $0.cycleNumber == 0 },
            "Nothing's been migrated yet — every session should still be at the 0 marker")

        let assignments = phase.legacyCycleNumbers()
        for session in phase.sessions where session.cycleNumber == 0 {
            session.cycleNumber = assignments[session.persistentModelID] ?? 0
        }
        try? context.save()

        XCTAssertTrue(phase.sessions.allSatisfy { $0.cycleNumber > 0 }, "Every day!=nil session should get a real cycle number")
        XCTAssertEqual(phase.currentCycle, 2,
            "Cycle 1 fully complete (including Rest), cycle 2 in progress — same as the old chronological walk would already show")
        XCTAssertTrue(phase.isSlotFilled(for: dayA))
        XCTAssertTrue(phase.isSlotFilled(for: dayB))
        XCTAssertFalse(phase.isSlotFilled(for: rest))
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
