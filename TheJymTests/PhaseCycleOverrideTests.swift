//
//  PhaseCycleOverrideTests.swift
//  TheJymTests
//
//  Covers PlannedExercise.cycleOverride / PhaseDay.setCycleOverride /
//  Phase.plan(for:cycle:) — swapping an exercise or set for one specific
//  cycle only, without touching every other cycle's plan.
//

import XCTest
import SwiftData
@testable import TheJym

final class PhaseCycleOverrideTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self,
                 Phase.self, PhaseDay.self, PlannedExercise.self,
                 WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func makeDay(context: ModelContext) -> (Phase, PhaseDay, PlannedExercise) {
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let day = PhaseDay(order: 0, name: "Push A")
        day.phase = phase
        context.insert(day)
        let benchPress = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [5, 5, 5])
        benchPress.day = day
        context.insert(benchPress)
        return (phase, day, benchPress)
    }

    @MainActor
    func testNoOverrideReturnsBasePlanForAnyCycle() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)

        for cycle in 1...3 {
            let plan = phase.plan(for: day, cycle: cycle)
            XCTAssertEqual(plan.map(\.exerciseName), [base.exerciseName])
            XCTAssertEqual(plan.first?.persistentModelID, base.persistentModelID)
        }
    }

    @MainActor
    func testOverrideOnlyAppliesToItsOwnCycle() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)

        day.setCycleOverride(for: base, cycle: 3, exerciseName: "Incline Press",
                             targetReps: [8, 8, 8], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)

        XCTAssertEqual(phase.plan(for: day, cycle: 2).map(\.exerciseName), ["Bench Press"])
        XCTAssertEqual(phase.plan(for: day, cycle: 3).map(\.exerciseName), ["Incline Press"])
        XCTAssertEqual(phase.plan(for: day, cycle: 3).first?.targetReps, [8, 8, 8])
        XCTAssertEqual(phase.plan(for: day, cycle: 4).map(\.exerciseName), ["Bench Press"])
    }

    @MainActor
    func testBasePlanNeverIncludesOverrideRows() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)

        day.setCycleOverride(for: base, cycle: 3, exerciseName: "Incline Press",
                             targetReps: [8, 8, 8], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)

        XCTAssertEqual(phase.plan(for: day).map(\.exerciseName), ["Bench Press"])
        XCTAssertEqual(day.basePlannedExercises.map(\.exerciseName), ["Bench Press"])
        XCTAssertEqual(phase.plannedExercises.map(\.exerciseName), ["Bench Press"])
    }

    @MainActor
    func testSettingAnOverrideTwiceReplacesRatherThanStacks() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)

        day.setCycleOverride(for: base, cycle: 3, exerciseName: "Incline Press",
                             targetReps: [8, 8, 8], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)
        day.setCycleOverride(for: base, cycle: 3, exerciseName: "Overhead Press",
                             targetReps: [5, 5, 5], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)

        let overridesInStore = day.plannedExercises.filter { $0.cycleOverride == 3 }
        XCTAssertEqual(overridesInStore.count, 1, "the first override should be replaced, not left behind")
        XCTAssertEqual(phase.plan(for: day, cycle: 3).map(\.exerciseName), ["Overhead Press"])
    }

    @MainActor
    func testRemovingAnOverrideRevertsThatCycleToTheBasePlan() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)

        day.setCycleOverride(for: base, cycle: 3, exerciseName: "Incline Press",
                             targetReps: [8, 8, 8], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)
        XCTAssertEqual(phase.plan(for: day, cycle: 3).map(\.exerciseName), ["Incline Press"])

        day.removeCycleOverride(for: base, cycle: 3, context: context)

        XCTAssertEqual(phase.plan(for: day, cycle: 3).map(\.exerciseName), ["Bench Press"])
    }

    @MainActor
    func testRepTotalOverrideCarriesItsOwnGoalType() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)

        day.setCycleOverride(for: base, cycle: 5, exerciseName: "Pull-Up",
                             targetReps: [], goalType: .repTotal(target: 40), isBodyweight: true,
                             restTimeSeconds: nil,
                             context: context)

        let overridden = phase.plan(for: day, cycle: 5).first
        guard case .repTotal(let target) = overridden?.goalType else {
            return XCTFail("expected a repTotal goal on the override")
        }
        XCTAssertEqual(target, 40)
        XCTAssertEqual(overridden?.isBodyweight, true)
    }

    /// Regression test: every PlannedExercise used to end up with the SAME
    /// `slotID` (a hand-written init didn't explicitly set it, and
    /// SwiftData's @Model macro doesn't reliably re-run a stored
    /// property's `= UUID()` default on its own) — so overriding ONE
    /// exercise in a multi-exercise day silently applied that same
    /// override to every other exercise in the day too, since
    /// Phase.plan(for:cycle:) matches an override to its base slot by
    /// slotID. `makeDay` alone (a single-exercise day) could never have
    /// caught this; every other test above unknowingly relied on a day
    /// with exactly one slot.
    @MainActor
    func testOverridingOneExerciseDoesNotAffectAnotherExerciseInTheSameDay() {
        let context = makeContext()
        let (phase, day, benchPress) = makeDay(context: context)
        let barbellRow = PlannedExercise(order: 1, exerciseName: "Barbell Row", targetReps: [8, 8, 8])
        barbellRow.day = day
        context.insert(barbellRow)

        XCTAssertNotEqual(benchPress.slotID, barbellRow.slotID,
                          "two distinct PlannedExercise slots must never share a slotID")

        day.setCycleOverride(for: benchPress, cycle: 3, exerciseName: "Incline Press",
                             targetReps: [8, 8, 8], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)

        let plan = phase.plan(for: day, cycle: 3)
        XCTAssertEqual(plan.map(\.exerciseName), ["Incline Press", "Barbell Row"],
                       "only Bench Press's own slot should be overridden — Barbell Row must stay untouched")
    }

    /// Regression test for TodayView's "Your Cycle" preview calling
    /// `plan(for: day)` (no cycle) instead of `plan(for: day, cycle:)` —
    /// silently showing base-template sets/reps for a cycle with overrides
    /// configured (e.g. a deload cycle's cut sets), even though the day's
    /// own "(Deload)" name label was already correct. Both TodayView's
    /// preview and WorkoutLogView.plannedExercises(for:) must resolve a
    /// day's plan against `phase.currentCycle` — the actual cycle number
    /// anything tapped right now would be logged under — never a
    /// hypothetical "which cycle does this preview position represent"
    /// number, or the two can disagree about what a phase with real, live
    /// cycle-4 progress and a cycle-4 override should show.
    @MainActor
    func testCurrentCycleWithAnOverrideAppliesWhenResolvedByPhaseCurrentCycle() {
        let context = makeContext()
        let (phase, day, base) = makeDay(context: context)
        day.setCycleOverride(for: base, cycle: 4, exerciseName: "Deload Bench Press",
                             targetReps: [5, 5, 5], goalType: .fixedSets, isBodyweight: false,
                             restTimeSeconds: nil,
                             context: context)

        // Actually advance phase.currentCycle to 4 by fully logging cycles
        // 1-3's one slot each — not just asserting against a hardcoded
        // cycle number, so this exercises the SAME live currentCycle both
        // TodayView and WorkoutLogView read.
        for cycle in 1...3 {
            let date = Calendar.current.date(byAdding: .day, value: -(4 - cycle), to: .now)!
            let session = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: cycle)
            session.phase = phase
            context.insert(session)
        }
        XCTAssertEqual(phase.currentCycle, 4, "sanity check: 3 fully-logged cycles should advance to cycle 4")

        // What TodayView's preview (after the fix) and
        // WorkoutLogView.plannedExercises(for:) both actually call.
        let resolvedForCurrentCycle = phase.plan(for: day, cycle: phase.currentCycle)
        XCTAssertEqual(resolvedForCurrentCycle.map(\.exerciseName), ["Deload Bench Press"],
                       "the preview must reflect cycle 4's own override, not the base plan")

        // Contrast with the actual bug: calling the no-cycle overload
        // silently ignores any override, regardless of currentCycle.
        XCTAssertEqual(phase.plan(for: day).map(\.exerciseName), ["Bench Press"],
                       "plan(for:) with no cycle always returns the base template — this was the bug")
    }
}
