//
//  BodyWeightImportTests.swift
//  TheJymTests
//
//  Verifies the "Exercise == Weight, value in Reps" body weight import path:
//  parses correctly, creates a BodyWeightEntry, and skips a date that
//  already has one rather than duplicating it.
//

import XCTest
import SwiftData
@testable import TheJym

final class BodyWeightImportTests: XCTestCase {
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
    func testWeightRowCreatesBodyWeightEntry() async {
        let csv = """
        Date,Exercise,Sets,Weights,Reps
        2026-01-05,Weight,,,172.5
        2026-01-06,Back Squat,5/5/5,135/135/135,5/5/5
        """
        let (rows, skipped) = ImportEngine.parseRows(csv: csv)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(rows.count, 2)

        let context = makeContext()
        let outcome = await ImportEngine.importIntoStore(rows, context: context)
        XCTAssertEqual(outcome.bodyWeightEntriesCreated, 1)
        XCTAssertEqual(outcome.sessionsCreated, 1, "Only the real exercise row makes a session")

        let entries = (try? context.fetch(FetchDescriptor<BodyWeightEntry>())) ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.weight, 172.5)
    }

    @MainActor
    func testWeightRowSkipsDateThatAlreadyHasAnEntry() async {
        let context = makeContext()
        context.insert(BodyWeightEntry(date: DateComponents(calendar: .current, year: 2026, month: 1, day: 5).date!, weight: 170))
        try? context.save()

        let csv = """
        Date,Exercise,Sets,Weights,Reps
        2026-01-05,Weight,,,172.5
        """
        let (rows, _) = ImportEngine.parseRows(csv: csv)
        let outcome = await ImportEngine.importIntoStore(rows, context: context)
        XCTAssertEqual(outcome.bodyWeightEntriesCreated, 0, "Already has an entry for that date")

        let entries = (try? context.fetch(FetchDescriptor<BodyWeightEntry>())) ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.weight, 170, "Existing entry left untouched, not overwritten")
    }
}
