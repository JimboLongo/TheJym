//
//  ImportStressTests.swift
//  TheJymTests
//
//  Reproduces a realistic large historical import (~1000 rows, matching the
//  scale of a real user file) through the exact "review -> Start Phase ->
//  attribute to forced Phase" path, to check whether importIntoStore is
//  simply too slow to run synchronously on the main thread (a plausible
//  cause for the app appearing to "close" — an iOS watchdog kill — right
//  after Start Phase on a big import) or whether it throws/crashes outright.
//

import XCTest
import SwiftData
@testable import TheJym

final class ImportStressTests: XCTestCase {
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
    func testLargeHistoricalImportAttributedToForcedPhase() async {
        let context = makeContext()

        let dayNames = ["Upper A", "Lower A", "Rest", "Upper B", "Lower B", "Rest"]
        let phase = Phase(number: 1, totalCycles: 40)
        context.insert(phase)
        for (i, name) in dayNames.enumerated() {
            let day = PhaseDay(order: i, name: name, isRest: name == "Rest")
            day.phase = phase
            context.insert(day)
        }
        try? context.save()

        let exercises = ["Back Squat", "Bench Press", "Deadlift", "Overhead Press",
                          "Barbell Row", "Pull-Up", "Dips", "Leg Press",
                          "Lat Pulldown", "Bicep Curl", "Tricep Pushdown", "Leg Curl"]

        var rows: [ImportEngine.ImportedEntry] = []
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var cycleDay = 0
        // ~1100 rows: ~183 training days * 6 exercises/day, matching the
        // scale of WorkoutImport7.xlsx (1097 data rows).
        while rows.count < 1100 {
            let label = dayNames[cycleDay % dayNames.count]
            if label != "Rest" {
                for e in exercises.prefix(6) {
                    rows.append(ImportEngine.ImportedEntry(
                        date: date, exerciseName: e,
                        kind: .exercise(goalType: .fixedSets, targetReps: [5, 5, 5],
                                       weights: [135, 135, 135], reps: [5, 5, 5]),
                        phaseNumber: nil, dayLabel: label, equipmentName: "Barbell"))
                }
            }
            cycleDay += 1
            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        }

        let start = Date()
        let result = await ImportEngine.importIntoStore(rows, context: context, attributeTo: phase)
        let elapsed = Date().timeIntervalSince(start)

        print("Imported \(result.sessionsCreated) sessions, \(result.setsImported) sets from \(rows.count) rows in \(elapsed)s")
        XCTAssertGreaterThan(result.sessionsCreated, 0)
        XCTAssertGreaterThan(result.setsImported, 0)
        // Generous ceiling — this is meant to catch a pathological slowdown
        // (the kind that would trip iOS's main-thread watchdog), not to be a
        // tight perf benchmark.
        XCTAssertLessThan(elapsed, 10.0, "Import took suspiciously long for ~1100 rows — likely too slow to run synchronously on the main thread without risking a watchdog kill")

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let attributed = sessions.filter { $0.phase?.number == 1 }
        XCTAssertEqual(attributed.count, sessions.count, "Every session should be attributed to the forced Phase")
        XCTAssertFalse(sessions.isEmpty)
    }
}
