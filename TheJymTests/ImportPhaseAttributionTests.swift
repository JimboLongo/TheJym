//
//  ImportPhaseAttributionTests.swift
//  TheJymTests
//
//  Reproduces the exact sequence HistoryView's "import -> review -> Start
//  Phase" flow runs: create a Phase + its PhaseDays (mirroring
//  PhaseBuilderView.save()), then immediately call
//  ImportEngine.importIntoStore(attributeTo:) with that just-created,
//  not-yet-saved Phase — exactly like onPhaseCreated fires before
//  dismiss(). Isolates whether the "no history imported" report is an
//  ImportEngine bug or a UI-wiring bug.
//

import XCTest
import SwiftData
@testable import TheJym

final class ImportPhaseAttributionTests: XCTestCase {
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

    @MainActor
    func testForcedPhaseAttributionRightAfterCreation() async {
        let context = makeContext()

        // Mirror PhaseBuilderView.save() exactly: insert the Phase, then
        // insert each PhaseDay with day.phase set, with NO context.save()
        // in between (matches save() calling context.save() once at the
        // very end, then onPhaseCreated(phase) firing right after).
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)

        let day1 = PhaseDay(order: 0, name: "Upper A", isRest: false)
        day1.phase = phase
        context.insert(day1)

        let day2 = PhaseDay(order: 1, name: "Rest", isRest: true)
        day2.phase = phase
        context.insert(day2)

        try? context.save()

        XCTAssertEqual(phase.orderedDays.count, 2, "Phase should see its just-inserted days without a fresh fetch")

        // A row whose Day label matches "Upper A" case-insensitively.
        let row = ImportEngine.ImportedEntry(
            date: Date(),
            exerciseName: "Back Squat",
            kind: .exercise(goalType: .fixedSets, targetReps: [5, 5, 5], weights: [135, 135, 135], reps: [5, 5, 5]),
            phaseNumber: nil,
            dayLabel: "Upper A",
            equipmentName: nil
        )

        let result = await ImportEngine.importIntoStore([row], context: context, attributeTo: phase)

        XCTAssertEqual(result.sessionsCreated, 1, "Expected exactly one session to be created")
        XCTAssertEqual(result.setsImported, 3, "Expected all 3 sets to import")

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.phase?.number, 1, "Session should be attributed to the forced Phase")
        XCTAssertEqual(sessions.first?.day?.name, "Upper A")

        let logs = (try? context.fetch(FetchDescriptor<ExerciseLog>())) ?? []
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.exerciseName, "Back Squat")

        let sets = (try? context.fetch(FetchDescriptor<SetLog>())) ?? []
        XCTAssertEqual(sets.count, 3)
    }

    /// A rest-activity row should only be retroactively attributed to the
    /// forced Phase from whichever date this same import's own exercise
    /// rows first got attributed onward — a "Rest" row that predates that
    /// (even though its label matches the Phase's Rest day too) should
    /// stay unattributed, same as if no Phase had ever matched it.
    @MainActor
    func testRestRowOnlyAttributedFromEarliestAttributedExerciseDateOnward() async {
        let context = makeContext()

        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let trainDay = PhaseDay(order: 0, name: "Upper A", isRest: false)
        trainDay.phase = phase
        context.insert(trainDay)
        let restDay = PhaseDay(order: 1, name: "Rest", isRest: true)
        restDay.phase = phase
        context.insert(restDay)
        try? context.save()

        let cal = Calendar.current
        let exerciseDate = cal.startOfDay(for: Date())
        let earlyRestDate = cal.date(byAdding: .day, value: -5, to: exerciseDate)!
        let lateRestDate = cal.date(byAdding: .day, value: 5, to: exerciseDate)!

        let exerciseRow = ImportEngine.ImportedEntry(
            date: exerciseDate, exerciseName: "Back Squat",
            kind: .exercise(goalType: .fixedSets, targetReps: [5], weights: [135], reps: [5]),
            phaseNumber: nil, dayLabel: "Upper A", equipmentName: nil)
        let earlyRestRow = ImportEngine.ImportedEntry(
            date: earlyRestDate, exerciseName: "Walk",
            kind: .restActivity(distance: nil, distanceUnit: "mi"),
            phaseNumber: nil, dayLabel: "Rest", equipmentName: nil)
        let lateRestRow = ImportEngine.ImportedEntry(
            date: lateRestDate, exerciseName: "Yoga",
            kind: .restActivity(distance: nil, distanceUnit: "mi"),
            phaseNumber: nil, dayLabel: "Rest", equipmentName: nil)

        _ = await ImportEngine.importIntoStore([exerciseRow, earlyRestRow, lateRestRow],
                                               context: context, attributeTo: phase)

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let earlySession = sessions.first { cal.isDate($0.date, inSameDayAs: earlyRestDate) }
        let lateSession = sessions.first { cal.isDate($0.date, inSameDayAs: lateRestDate) }

        XCTAssertNil(earlySession?.phase, "A rest row before the earliest attributed exercise date shouldn't be attributed")
        XCTAssertEqual(lateSession?.phase?.number, 1, "A rest row on/after the earliest attributed exercise date should be attributed")
    }
}
