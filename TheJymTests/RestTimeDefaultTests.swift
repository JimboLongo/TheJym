//
//  RestTimeDefaultTests.swift
//  TheJymTests
//
//  The rest-time cascade offered when adding an exercise to a day.
//
//  Step 1 — "the last rest time used for this exercise" — reproduces rather
//  than guesses, and the measurement behind that claim is in
//  RestTimeDefault's own doc: across the real store's 80 slots, 54 carry a
//  rest time, four distinct values are in use, and NO exercise uses more
//  than one. These tests pin the behaviour that relies on it, including
//  what happens the day an exercise does carry two.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class RestTimeDefaultTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self, MacroTier.self, CycleMacroTag.self, MacroLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    @discardableResult
    private func slot(_ ctx: ModelContext, _ name: String, rest: Int?,
                      phaseNumber: Int = 1, phaseStart: Date = .distantPast,
                      order: Int = 0) -> PlannedExercise {
        let phase = Phase(number: phaseNumber, totalCycles: 8, startDate: phaseStart)
        ctx.insert(phase)
        let day = PhaseDay(order: 0, name: "Day \(phaseNumber)", isRest: false)
        day.phase = phase
        ctx.insert(day)
        let pe = PlannedExercise(order: order, exerciseName: name, targetReps: [6, 6, 6],
                                 isBodyweight: false, goalType: .fixedSets,
                                 restTimeSeconds: rest)
        pe.day = day
        ctx.insert(pe)
        try? ctx.save()
        return pe
    }

    private func all(_ ctx: ModelContext) -> [PlannedExercise] {
        try! ctx.fetch(FetchDescriptor<PlannedExercise>())
    }

    // MARK: - The cascade, in order

    func testPriorValueForTheSameExerciseWins() {
        let ctx = makeContext()
        slot(ctx, "Safety Squats", rest: 180)
        XCTAssertEqual(
            RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx), sessionLast: 60),
            180, "a sibling slot's value beats the session value")
    }

    func testSessionValueUsedWhenTheExerciseHasNoPrior() {
        let ctx = makeContext()
        slot(ctx, "Bench Press", rest: 90)
        XCTAssertEqual(
            RestTimeDefault.suggested(for: "Brand New Lift", in: all(ctx), sessionLast: 75),
            75, "another exercise's rest time must not leak across")
    }

    func testFallsBackTo90WithNothingToGoOn() {
        let ctx = makeContext()
        XCTAssertEqual(RestTimeDefault.suggested(for: "Anything", in: all(ctx)), 90)
        XCTAssertEqual(RestTimeDefault.fallbackSeconds, 90,
                       "matches RestTimePickerSheet's own default and the store's modal value")
    }

    /// A slot with no rest time is not a prior value — it's the absence of
    /// one, and must not suppress the rest of the cascade.
    func testSlotsWithoutARestTimeAreNotTreatedAsPriors() {
        let ctx = makeContext()
        slot(ctx, "Safety Squats", rest: nil)
        XCTAssertEqual(
            RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx), sessionLast: 60), 60)
    }

    // MARK: - Determinism

    /// With no exercise currently using two values this changes nothing,
    /// which is exactly why it's worth pinning: the day one does, the newer
    /// phase must win on purpose rather than by fetch order.
    func testMostRecentPhaseWinsWhenAnExerciseCarriesTwoValues() {
        let ctx = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        slot(ctx, "Safety Squats", rest: 60, phaseNumber: 1, phaseStart: old)
        slot(ctx, "Safety Squats", rest: 180, phaseNumber: 2, phaseStart: new)
        XCTAssertEqual(RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx)), 180)

        // Order of the input must not change the answer.
        XCTAssertEqual(RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx).reversed()), 180)
    }

    func testSlotOrderBreaksTiesWithinOnePhase() {
        let ctx = makeContext()
        let phase = Phase(number: 1, totalCycles: 8, startDate: .now)
        ctx.insert(phase)
        let day = PhaseDay(order: 0, name: "Day", isRest: false)
        day.phase = phase
        ctx.insert(day)
        for (order, rest) in [(0, 60), (1, 120)] {
            let pe = PlannedExercise(order: order, exerciseName: "Safety Squats",
                                     targetReps: [6], isBodyweight: false,
                                     goalType: .fixedSets, restTimeSeconds: rest)
            pe.day = day
            ctx.insert(pe)
        }
        try? ctx.save()
        XCTAssertEqual(RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx)), 120)
    }

    // MARK: - Scope

    /// The cascade READS sibling slots and must never write to them —
    /// setting a rest time in the add flow is per-slot, this slot only.
    func testSuggestingNeverMutatesAnySlot() {
        let ctx = makeContext()
        let existing = slot(ctx, "Safety Squats", rest: 180)
        _ = RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx), sessionLast: 60)
        _ = RestTimeDefault.suggested(for: "Something Else", in: all(ctx), sessionLast: 60)
        XCTAssertEqual(existing.restTimeSeconds, 180)
        XCTAssertEqual(all(ctx).count, 1, "no slot created, none changed")
    }

    /// A per-cycle override is still a slot of the same exercise, so its
    /// value is inheritable like any other.
    func testOverrideSlotsCountAsPriors() {
        let ctx = makeContext()
        let pe = slot(ctx, "Safety Squats", rest: 150)
        pe.cycleOverride = 4
        try? ctx.save()
        XCTAssertEqual(RestTimeDefault.suggested(for: "Safety Squats", in: all(ctx)), 150)
    }
}
