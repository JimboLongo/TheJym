//
//  RepSchemeImpactTests.swift
//  TheJymTests
//
//  What ManageSetsView confirms, and — just as important — what it doesn't.
//
//  Two rules under test. First, every confirmation must state SCOPE: the
//  action is global (repSchemes lives on ExerciseDef) while the screen it
//  was reached from implies something narrow, a single-cycle override in
//  PhasesView most of all. Second, a confirmation appears ONLY when the
//  impact is real — a prompt that always appears is one you learn to
//  dismiss, which would make the one that matters worthless.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class RepSchemeImpactTests: XCTestCase {

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

    /// An exercise with one saved set, plus whatever references the caller asks for.
    private func fixture(_ ctx: ModelContext, planned: Int = 0, logged: Int = 0,
                         ceiling: Bool = false,
                         cycleOverride: Int = 0) -> ExerciseDef {
        let def = ExerciseDef(name: "Safety Squats", repSchemes: [[6, 6, 6]])
        ctx.insert(def)
        if ceiling {
            def.setCeiling(for: [6, 6, 6], upperTargetReps: [8, 8, 8], weightIncreaseAmount: 5)
        }
        if planned > 0 {
            let phase = Phase(number: 2, totalCycles: 8, startDate: .now)
            ctx.insert(phase)
            let day = PhaseDay(order: 0, name: "Lower Day 1", isRest: false)
            day.phase = phase
            ctx.insert(day)
            for i in 0..<planned {
                let pe = PlannedExercise(order: i, exerciseName: "Safety Squats",
                                         targetReps: [6, 6, 6], isBodyweight: false,
                                         goalType: .fixedSets, cycleOverride: cycleOverride)
                pe.day = day
                ctx.insert(pe)
            }
        }
        for i in 0..<logged {
            let session = WorkoutSession(date: .now, dayLabel: "Lower Day 1", cycleNumber: 1)
            ctx.insert(session)
            let log = ExerciseLog(exerciseName: "Safety Squats", targetReps: [6, 6, 6], order: i)
            log.session = session
            ctx.insert(log)
        }
        try? ctx.save()
        return def
    }

    private func impact(_ ctx: ModelContext, _ def: ExerciseDef) -> RepSchemeImpact {
        RepSchemeImpact.compute(
            def: def, reps: [6, 6, 6],
            plannedExercises: try! ctx.fetch(FetchDescriptor<PlannedExercise>()),
            logs: try! ctx.fetch(FetchDescriptor<ExerciseLog>()))
    }

    // MARK: - Silence when nothing is referenced

    func testUnreferencedSetNeedsNoConfirmationForEitherAction() {
        let ctx = makeContext()
        let i = impact(ctx, fixture(ctx))
        XCTAssertTrue(i.isUnreferenced)
        XCTAssertNil(i.deleteConfirmation)
        XCTAssertNil(i.editConfirmation(newReps: [7, 7, 7]))
        XCTAssertNil(i.editConfirmation(newReps: [6, 6, 6, 6]),
                     "even a set-count change is silent with no ceiling and nothing pointing at it")
    }

    // MARK: - Scope, on every confirmation that appears

    func testEveryConfirmationStatesTheGlobalScope() {
        let ctx = makeContext()
        let i = impact(ctx, fixture(ctx, planned: 1, logged: 2, ceiling: true))
        let scope = "This set is saved on Safety Squats in Exercises. "
            + "Changing it affects every phase that uses it."
        for message in [i.deleteConfirmation, i.editConfirmation(newReps: [7, 7, 7])] {
            let text = try! XCTUnwrap(message)
            XCTAssertTrue(text.hasPrefix(scope),
                          "scope must LEAD, not be buried: \(text)")
        }
    }

    // MARK: - Each trigger on its own

    func testLogsAloneTriggerAConfirmationThatSaysTheyStayPut() {
        let ctx = makeContext()
        let text = try! XCTUnwrap(impact(ctx, fixture(ctx, logged: 3))
            .editConfirmation(newReps: [7, 7, 7]))
        XCTAssertTrue(text.contains("3 logged workouts"))
        XCTAssertTrue(text.contains("won't show under the new set"))
    }

    func testPlannedUsagesAreNamedByPhaseAndDay() {
        let ctx = makeContext()
        let text = try! XCTUnwrap(impact(ctx, fixture(ctx, planned: 1))
            .editConfirmation(newReps: [7, 7, 7]))
        XCTAssertTrue(text.contains("Phase 2 · Lower Day 1"), text)
        XCTAssertTrue(text.contains("keep training 6/6/6"),
                      "the plan still trains the old reps — that's the reassuring half")
    }

    /// A per-cycle override reads as its own slot, so it says which cycle.
    func testCycleOverrideUsageNamesItsCycle() {
        let ctx = makeContext()
        let text = try! XCTUnwrap(impact(ctx, fixture(ctx, planned: 1, cycleOverride: 4))
            .editConfirmation(newReps: [7, 7, 7]))
        XCTAssertTrue(text.contains("(cycle 4)"), text)
    }

    // MARK: - The ceiling rule

    func testSameSetCountCarriesTheCeilingAndSaysNothingAboutIt() {
        let ctx = makeContext()
        let i = impact(ctx, fixture(ctx, ceiling: true))
        guard case .movesVerbatim(let c) = i.ceilingOutcome(forNewReps: [7, 7, 7]) else {
            return XCTFail("same set count should carry the ceiling")
        }
        XCTAssertEqual(c.upperTargetReps, [8, 8, 8])
        XCTAssertNil(i.editConfirmation(newReps: [7, 7, 7]),
                     "a ceiling that carries cleanly is not worth interrupting for")
    }

    func testDifferentSetCountCannotCarryTheCeilingAndSaysSo() {
        let ctx = makeContext()
        let i = impact(ctx, fixture(ctx, ceiling: true))
        guard case .mustBeReentered(let oldCount, let newCount) =
                i.ceilingOutcome(forNewReps: [6, 6, 6, 6]) else {
            return XCTFail("a set-count change cannot carry a per-set ceiling")
        }
        XCTAssertEqual(oldCount, 3)
        XCTAssertEqual(newCount, 4)
        let text = try! XCTUnwrap(i.editConfirmation(newReps: [6, 6, 6, 6]))
        XCTAssertTrue(text.contains("set for 3 sets"), text)
        XCTAssertTrue(text.contains("now has 4"), text)
        XCTAssertTrue(text.contains("cleared"), text)
    }

    func testNoCeilingMeansNoCeilingOutcome() {
        let ctx = makeContext()
        guard case .none = impact(ctx, fixture(ctx)).ceilingOutcome(forNewReps: [6, 6, 6, 6]) else {
            return XCTFail("nothing to carry")
        }
    }

    func testDeletingMentionsTheCeilingGoesWithIt() {
        let ctx = makeContext()
        let text = try! XCTUnwrap(impact(ctx, fixture(ctx, ceiling: true)).deleteConfirmation)
        XCTAssertTrue(text.contains("rep ceiling is deleted with it"), text)
    }

    // MARK: - Scoping of the counts themselves

    /// Only this exact array on this exact exercise counts — a sibling
    /// scheme or another exercise must not inflate the warning.
    func testCountsDoNotLeakAcrossSchemesOrExercises() {
        let ctx = makeContext()
        let def = fixture(ctx, planned: 1, logged: 1)
        def.addRepScheme([10, 10])

        let other = WorkoutSession(date: .now, dayLabel: "X", cycleNumber: 1)
        ctx.insert(other)
        for (name, reps) in [("Safety Squats", [10, 10]), ("Bench Press", [6, 6, 6])] {
            let log = ExerciseLog(exerciseName: name, targetReps: reps, order: 0)
            log.session = other
            ctx.insert(log)
        }
        try? ctx.save()

        let i = impact(ctx, def)
        XCTAssertEqual(i.loggedCount, 1, "only Safety Squats 6/6/6 counts")
        XCTAssertEqual(i.plannedUsages.count, 1)
    }

    /// A rep-total plan is a different kind of thing and must never be
    /// counted as a usage of a fixed-set scheme.
    func testRepTotalPlansAreNotCountedAsUsages() {
        let ctx = makeContext()
        let def = fixture(ctx)
        let phase = Phase(number: 1, totalCycles: 4, startDate: .now)
        ctx.insert(phase)
        let day = PhaseDay(order: 0, name: "Day", isRest: false)
        day.phase = phase
        ctx.insert(day)
        let pe = PlannedExercise(order: 0, exerciseName: "Safety Squats", targetReps: [],
                                 isBodyweight: false, goalType: .repTotal(target: 40))
        pe.day = day
        ctx.insert(pe)
        try? ctx.save()
        XCTAssertTrue(impact(ctx, def).plannedUsages.isEmpty)
    }
}
