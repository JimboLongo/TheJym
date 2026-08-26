//
//  PhaseAutoContinueTests.swift
//  TheJymTests
//
//  Covers Array<Phase>.queuedNextPhase(after:) and Phase.activate(among:) —
//  auto-continuing straight into an already-built Phase n+1 the day after
//  Phase n's last slot was filled, without needing the "Phase Complete"
//  screen's manual picker.
//

import XCTest
import SwiftData
@testable import TheJym

final class PhaseAutoContinueTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A one-training-day, one-cycle phase, completed by a single session
    /// logged `daysAgo` days back — displayIsComplete only reads true once
    /// that completing session is dated before today (the "day after"
    /// framing everything else here relies on).
    @MainActor
    private func makeCompletedPhase(number: Int, daysAgo: Int, context: ModelContext) -> Phase {
        let phase = Phase(number: number, totalCycles: 1, isActive: true)
        context.insert(phase)
        let day = PhaseDay(order: 0, name: "Full Body")
        day.phase = phase
        context.insert(day)
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let session = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: 1)
        session.phase = phase
        context.insert(session)
        return phase
    }

    @MainActor
    func testQueuedNextPhaseFindsExactlyOneHigherNumberedStandby() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 1, context: context)
        let phase2 = Phase(number: 2, totalCycles: 8, isActive: false)
        context.insert(phase2)
        try? context.save()

        XCTAssertTrue(phase1.displayIsComplete)
        let phases = [phase1, phase2]
        XCTAssertEqual(phases.queuedNextPhase(after: phase1)?.number, 2)
    }

    /// The exact scenario reported: every cycle finished TODAY (not
    /// yesterday) — displayIsComplete stays frozen off until tomorrow, but
    /// the LIVE isComplete (what WorkoutLogView.finishWorkout and
    /// ContentView's own repair now both check) should already be true, so
    /// auto-continuing into Phase 2 doesn't wait a full day once there's
    /// truly no cycle left to train under Phase 1.
    @MainActor
    func testCompletingTheLastSlotTodayIsLiveCompleteEvenThoughDisplayIsFrozen() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 0, context: context)
        let phase2 = Phase(number: 2, totalCycles: 8, isActive: false)
        context.insert(phase2)
        try? context.save()

        XCTAssertTrue(phase1.isComplete)
        XCTAssertFalse(phase1.displayIsComplete, "display freeze should still hold off until tomorrow")
        let phases = [phase1, phase2]
        XCTAssertEqual(phases.queuedNextPhase(after: phase1)?.number, 2)
    }

    /// Regression test: currentCycle is clamped to totalCycles (Models.swift
    /// cycleWalk's `min(n, totalCycles)`), even once every cycle is done —
    /// it never runs past totalCycles the way a naive "which cycle am I
    /// on" counter might. Anything gating on `currentCycle > totalCycles`
    /// to detect "this phase has no real cycles left" is dead code; use
    /// `isComplete` instead (see TodayView.effectiveDaySource, which hit
    /// exactly this bug).
    @MainActor
    func testCurrentCycleStaysClampedToTotalCyclesEvenOnceComplete() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 0, context: context)
        try? context.save()

        XCTAssertTrue(phase1.isComplete)
        XCTAssertEqual(phase1.currentCycle, phase1.totalCycles,
                       "currentCycle must never exceed totalCycles, even on a fully completed phase")
    }

    @MainActor
    func testNoQueuedNextPhaseWhenNumberingSkips() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 1, context: context)
        let phase3 = Phase(number: 3, totalCycles: 8, isActive: false)
        context.insert(phase3)
        try? context.save()

        let phases = [phase1, phase3]
        XCTAssertNil(phases.queuedNextPhase(after: phase1),
                     "Phase 3 shouldn't auto-continue from Phase 1 — only an exact n+1 match should")
    }

    @MainActor
    func testNoQueuedNextPhaseWhenNoStandbyExists() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 1, context: context)
        try? context.save()

        XCTAssertNil([phase1].queuedNextPhase(after: phase1))
    }

    @MainActor
    func testActivateDeactivatesEveryOtherPhaseAndResetsAFreshStartDate() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 1, context: context)
        let phase2 = Phase(number: 2, totalCycles: 8, startDate: Calendar.current.date(byAdding: .day, value: -30, to: Date())!, isActive: false)
        context.insert(phase2)
        try? context.save()

        phase2.activate(among: [phase1, phase2])

        XCTAssertFalse(phase1.isActive)
        XCTAssertTrue(phase2.isActive)
        XCTAssertTrue(Calendar.current.isDateInToday(phase2.startDate),
                      "a never-trained standby phase's stale creation-time startDate should reset to now once activated")
    }

    @MainActor
    func testActivatingAnAlreadyTrainedPhasePreservesItsRealStartDate() {
        let context = makeContext()
        let phase1 = makeCompletedPhase(number: 1, daysAgo: 1, context: context)
        let originalStart = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let phase2 = Phase(number: 2, totalCycles: 8, startDate: originalStart, isActive: false)
        context.insert(phase2)
        let day2 = PhaseDay(order: 0, name: "Day")
        day2.phase = phase2
        context.insert(day2)
        let session2 = WorkoutSession(date: originalStart, day: day2, dayLabel: day2.name, cycleNumber: 1)
        session2.phase = phase2
        context.insert(session2)
        try? context.save()

        phase2.activate(among: [phase1, phase2])

        XCTAssertEqual(phase2.startDate, originalStart,
                       "a phase that's already been trained (switched away from and back) should keep its real start date")
    }
}
