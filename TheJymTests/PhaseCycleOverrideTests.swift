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
                             context: context)
        day.setCycleOverride(for: base, cycle: 3, exerciseName: "Overhead Press",
                             targetReps: [5, 5, 5], goalType: .fixedSets, isBodyweight: false,
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
                             context: context)

        let overridden = phase.plan(for: day, cycle: 5).first
        guard case .repTotal(let target) = overridden?.goalType else {
            return XCTFail("expected a repTotal goal on the override")
        }
        XCTAssertEqual(target, 40)
        XCTAssertEqual(overridden?.isBodyweight, true)
    }
}
