//
//  ExerciseLogWeightAdjustmentMigrationTests.swift
//  TheJymTests
//
//  Covers ExerciseLog.migrateWeightAdjustmentFields — the phase-1 idempotent
//  migration from the old selectedWeightIncreaseAmount/
//  selectedWeightDecreaseAmount fields onto the single new
//  selectedWeightAdjustment field. No persisted marker Bool — guarded
//  purely on selectedWeightAdjustment == nil, same pattern as
//  WorkoutSession.backfillRestDays.
//

import XCTest
import SwiftData
@testable import TheJym

final class ExerciseLogWeightAdjustmentMigrationTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    @discardableResult
    private func log(context: ModelContext) -> ExerciseLog {
        let session = WorkoutSession(dayLabel: "Day", cycleNumber: 1)
        context.insert(session)
        let exerciseLog = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        exerciseLog.session = session
        context.insert(exerciseLog)
        return exerciseLog
    }

    /// Increase stays positive across the migration.
    @MainActor
    func testMigratesOldIncreaseValuePositive() {
        let context = makeContext()
        let entry = log(context: context)
        entry.selectedWeightIncreaseAmount = 5

        let migrated = ExerciseLog.migrateWeightAdjustmentFields(context: context)
        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(entry.selectedWeightAdjustment, 5)
    }

    /// Decrease is already negative and maps straight across with no sign
    /// flip.
    @MainActor
    func testMigratesOldDecreaseValueNegative() {
        let context = makeContext()
        let entry = log(context: context)
        entry.selectedWeightDecreaseAmount = -5

        let migrated = ExerciseLog.migrateWeightAdjustmentFields(context: context)
        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(entry.selectedWeightAdjustment, -5)
    }

    /// A row with neither old field set is left alone — not counted, not
    /// given a spurious 0.
    @MainActor
    func testRowWithNeitherOldFieldIsUntouched() {
        let context = makeContext()
        let entry = log(context: context)

        let migrated = ExerciseLog.migrateWeightAdjustmentFields(context: context)
        XCTAssertEqual(migrated, 0)
        XCTAssertNil(entry.selectedWeightAdjustment)
    }

    /// Idempotent: running it again after a successful migration is a
    /// no-op, since the guard is `selectedWeightAdjustment == nil` — no
    /// separate marker Bool needed.
    @MainActor
    func testRunningTwiceIsANoOpTheSecondTime() {
        let context = makeContext()
        let entry = log(context: context)
        entry.selectedWeightIncreaseAmount = 7.5

        XCTAssertEqual(ExerciseLog.migrateWeightAdjustmentFields(context: context), 1)
        XCTAssertEqual(entry.selectedWeightAdjustment, 7.5)

        // Simulate stale/leftover old-field data still sitting around —
        // the migration must not re-read it once the new field is set.
        entry.selectedWeightIncreaseAmount = 99
        XCTAssertEqual(ExerciseLog.migrateWeightAdjustmentFields(context: context), 0)
        XCTAssertEqual(entry.selectedWeightAdjustment, 7.5, "already migrated — must not be clobbered by a second pass")
    }

    /// Only rows that actually need it are migrated — a mix of migrated,
    /// untouched, and already-set rows in the same fetch.
    @MainActor
    func testOnlyMigratesRowsThatActuallyNeedIt() {
        let context = makeContext()
        let needsIncrease = log(context: context)
        needsIncrease.selectedWeightIncreaseAmount = 2.5
        let needsDecrease = log(context: context)
        needsDecrease.selectedWeightDecreaseAmount = -10
        let alreadyMigrated = log(context: context)
        alreadyMigrated.selectedWeightAdjustment = 5
        let neverTouched = log(context: context)

        let migrated = ExerciseLog.migrateWeightAdjustmentFields(context: context)
        XCTAssertEqual(migrated, 2)
        XCTAssertEqual(needsIncrease.selectedWeightAdjustment, 2.5)
        XCTAssertEqual(needsDecrease.selectedWeightAdjustment, -10)
        XCTAssertEqual(alreadyMigrated.selectedWeightAdjustment, 5)
        XCTAssertNil(neverTouched.selectedWeightAdjustment)
    }
}
