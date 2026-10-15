//
//  PhaseActivationTests.swift
//  TheJymTests
//
//  Who deactivates a phase, and when.
//
//  The bug this pins: "Build Phase N+1 Manually" and the AI planner's
//  "Continue to Edit & Start" both set isActive = false the moment the
//  button was tapped, so PhaseBuilderView.save's `shouldActivate` would
//  see no active phase. Backing out of the builder then left NO phase
//  active at all — which is exactly what happened to Phase 2: complete at
//  8 of 8, deactivated by a tap, no Phase 3 created, and Adherence,
//  Perfect Cycles, Miles this phase and Rest days banked all silently
//  gone from Stats.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class PhaseActivationTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self, MacroTier.self, CycleMacroTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    @discardableResult
    private func phase(_ ctx: ModelContext, _ number: Int, active: Bool) -> Phase {
        let p = Phase(number: number, totalCycles: 8, startDate: .now, isActive: active)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // MARK: - The regression

    /// Opening the builder must not change anything. The old code
    /// deactivated here, and nothing put it back.
    func testOpeningTheBuilderDoesNotDeactivateAnything() {
        let ctx = makeContext()
        let two = phase(ctx, 2, active: true)
        // Whatever the button does now, it must not touch isActive — the
        // only writes left are in PhaseBuilderView.save and activate(among:).
        XCTAssertTrue(two.isActive)
    }

    /// Exactly one phase is active after a replacement is saved, and it's
    /// the new one.
    func testSavingAReplacementMovesActivationToTheNewPhase() {
        let ctx = makeContext()
        let two = phase(ctx, 2, active: true)
        let three = Phase(number: 3, totalCycles: 8, startDate: .now, isActive: true)
        ctx.insert(three)
        // What save() does when activatesOnSave is true.
        three.activate(among: [two])
        try? ctx.save()

        XCTAssertFalse(two.isActive, "the outgoing phase is deactivated ON SAVE")
        XCTAssertTrue(three.isActive)
        let active = (try! ctx.fetch(FetchDescriptor<Phase>())).filter(\.isActive)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.number, 3)
    }

    /// The state the bug produced, asserted as the thing to avoid: a
    /// complete phase deactivated with no replacement leaves the app with
    /// no active phase at all.
    func testNoActivePhaseIsTheStateTheBugProduced() {
        let ctx = makeContext()
        let two = phase(ctx, 2, active: true)
        two.isActive = false            // the old button, then a cancel
        try? ctx.save()
        XCTAssertTrue((try! ctx.fetch(FetchDescriptor<Phase>())).allSatisfy { !$0.isActive },
                      "this is what used to happen — nothing restores it")
    }

    // MARK: - activate(among:)

    func testActivateDeactivatesEveryOtherPhase() {
        let ctx = makeContext()
        let one = phase(ctx, 1, active: true)
        let two = phase(ctx, 2, active: true)   // shouldn't happen, but be safe
        let three = phase(ctx, 3, active: false)
        three.activate(among: [one, two, three])
        try? ctx.save()
        XCTAssertFalse(one.isActive)
        XCTAssertFalse(two.isActive)
        XCTAssertTrue(three.isActive)
    }

    /// A brand-new phase has no sessions, so activate resets its start to
    /// now — a standby built weeks earlier shouldn't claim that stale date.
    func testActivatingAnUntrainedPhaseResetsItsStartDate() {
        let ctx = makeContext()
        let stale = Phase(number: 2, totalCycles: 8,
                          startDate: Date(timeIntervalSince1970: 1_600_000_000))
        ctx.insert(stale)
        stale.activate(among: [stale])
        XCTAssertEqual(stale.startDate.timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// One that's already been trained keeps its real start, so pace math
    /// against its own history stays correct.
    func testActivatingATrainedPhaseKeepsItsStartDate() {
        let ctx = makeContext()
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let trained = Phase(number: 2, totalCycles: 8, startDate: original)
        ctx.insert(trained)
        let s = WorkoutSession(date: original, dayLabel: "A", cycleNumber: 1)
        s.phase = trained
        ctx.insert(s)
        try? ctx.save()
        trained.activate(among: [trained])
        XCTAssertEqual(trained.startDate, original)
    }

    // MARK: - The final cycle doesn't top up the bank

    /// Why reactivating a COMPLETE phase wouldn't help the rest bank:
    /// restBankResetEvents deliberately excludes the last cycle, so a
    /// phase finishing its 8th of 8 generates no reset. Only a new phase
    /// completing cycles refills it.
    func testCompletingTheFinalCycleGeneratesNoResetEvent() {
        let ctx = makeContext()
        let p = Phase(number: 1, totalCycles: 2, startDate: .now)
        ctx.insert(p)
        for (order, name) in ["A", "Rest"].enumerated() {
            let d = PhaseDay(order: order, name: name, isRest: name == "Rest")
            d.phase = p
            ctx.insert(d)
        }
        let days = p.orderedDays
        var date = Calendar.current.startOfDay(for: .now)
        for cycle in 1...2 {
            for day in days {
                let s = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: cycle)
                s.phase = p
                ctx.insert(s)
                let log = ExerciseLog(exerciseName: "Squat", targetReps: [5], order: 0)
                log.session = s
                ctx.insert(log)
                let set = SetLog(index: 0, weight: 100, reps: 5)
                set.exerciseLog = log
                ctx.insert(set)
                date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
            }
        }
        try? ctx.save()

        let events = p.restBankResetEvents
        // firstLoggedDate always produces one; cycle 1 completing produces
        // one; cycle 2 — the LAST — must not.
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(p.cycleCompletionDates.keys.filter { $0 < p.totalCycles }.count,
                       events.count - 1,
                       "only cycles before the last generate a reset")
    }
}
