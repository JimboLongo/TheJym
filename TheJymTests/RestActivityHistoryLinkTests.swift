//
//  RestActivityHistoryLinkTests.swift
//  TheJymTests
//
//  A rest-day activity's distance used to be folded, unreachably, into its
//  History mirror's exercise NAME (e.g. "Walk (3.1 mi)"). It now lives in
//  that mirror's one SetLog.weight instead, linked back to the originating
//  RestDayActivity via ExerciseLog.restDayActivity — editable in History
//  (SetEditRow), with edits meant to stay in sync with the RestDayActivity
//  record StatsEngine's miles-walked totals actually read from.
//

import XCTest
import SwiftData
@testable import TheJym

final class RestActivityHistoryLinkTests: XCTestCase {
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

    /// The import path (ImportEngine.importIntoStore) for a rest-activity
    /// row: the exercise name stays bare (no "(3.1 mi)" suffix), the
    /// resulting SetLog's weight holds the distance, and it's linked back
    /// to the RestDayActivity record.
    @MainActor
    func testImportedRestActivityLinksDistanceToSetLogWeight() async {
        let context = makeContext()
        let entry = ImportEngine.ImportedEntry(
            date: Date(), exerciseName: "Walk",
            kind: .restActivity(distance: 3.1, distanceUnit: "mi"),
            phaseNumber: nil, dayLabel: "Rest", equipmentName: nil)
        _ = await ImportEngine.importIntoStore([entry], context: context)

        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())
        guard let log = logs.first else { return XCTFail("Expected an ExerciseLog for the rest activity") }
        XCTAssertEqual(log.exerciseName, "Walk", "distance should no longer be folded into the name")
        guard let restActivity = log.restDayActivity else {
            return XCTFail("Expected the log to be linked to its RestDayActivity")
        }
        XCTAssertEqual(restActivity.distance, 3.1)
        guard let set = log.sortedSets.first else { return XCTFail("Expected one SetLog") }
        XCTAssertEqual(set.weight, 3.1, "the set's weight should mirror the activity's distance")

        // Editing the set's weight (as History's SetEditRow does) and
        // writing through to restActivity.distance keeps them in sync.
        set.weight = 4.2
        restActivity.distance = 4.2
        XCTAssertEqual(restActivity.distance, 4.2)
    }

    /// A rest activity logged with no distance at all still links up, with
    /// both sides at 0/nil as appropriate.
    @MainActor
    func testImportedRestActivityWithNoDistanceLinksWithZeroWeight() async {
        let context = makeContext()
        let entry = ImportEngine.ImportedEntry(
            date: Date(), exerciseName: "Stretching",
            kind: .restActivity(distance: nil, distanceUnit: "mi"),
            phaseNumber: nil, dayLabel: "Rest", equipmentName: nil)
        _ = await ImportEngine.importIntoStore([entry], context: context)

        let logs = try! context.fetch(FetchDescriptor<ExerciseLog>())
        guard let log = logs.first else { return XCTFail("Expected an ExerciseLog for the rest activity") }
        XCTAssertEqual(log.exerciseName, "Stretching")
        XCTAssertNotNil(log.restDayActivity)
        XCTAssertNil(log.restDayActivity?.distance)
        XCTAssertEqual(log.sortedSets.first?.weight, 0)
    }
}
