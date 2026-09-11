//
//  WorkoutSessionFabricatedDurationTests.swift
//  TheJymTests
//
//  Covers WorkoutSession.fillMissingDurationsWithFabricatedValues — the
//  one-time, deliberately-fabricated cleanup that assigns a random 61-79
//  minute duration to every logged workout missing one, while excluding
//  shapes that never represent real training time: the backfilled rest
//  placeholder, a day-matched but empty-log rest credit (logPlainRestDay/
//  import gap-fill), and a rest-day-activity-only session.
//

import XCTest
import SwiftData
@testable import TheJym

final class WorkoutSessionFabricatedDurationTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func addRealWorkoutLog(to session: WorkoutSession, context: ModelContext) {
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)
    }

    @MainActor
    private func addRestActivityLog(to session: WorkoutSession, context: ModelContext) {
        let activity = RestDayActivity(date: session.date, name: "Walk", distance: 3.1, distanceUnit: "mi")
        context.insert(activity)
        let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log.session = session
        log.restDayActivity = activity
        context.insert(log)
        let set = SetLog(index: 0, weight: 3.1, reps: 1)
        set.exerciseLog = log
        context.insert(set)
    }

    // MARK: - Exclusions

    /// The backfilled placeholder itself (day == nil, dayLabel == "Rest
    /// Day", no logs) is left untouched.
    @MainActor
    func testExcludesTheBackfilledRestPlaceholder() {
        let context = makeContext()
        let session = WorkoutSession(dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(session)
        XCTAssertTrue(session.isBackfilledRestPlaceholder)

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 0)
        XCTAssertNil(session.durationSeconds)
    }

    /// A day-matched but log-empty rest credit (logPlainRestDay()'s own
    /// shape — day is set, but nothing was actually logged) is excluded
    /// too, even though it doesn't match isBackfilledRestPlaceholder's own
    /// day == nil check — functionally identical, no work was logged.
    @MainActor
    func testExcludesADayMatchedButLogEmptyRestCredit() {
        let context = makeContext()
        let phaseDay = PhaseDay(order: 0, name: "Rest", isRest: true)
        context.insert(phaseDay)
        let session = WorkoutSession(day: phaseDay, dayLabel: "Rest", cycleNumber: 1)
        context.insert(session)
        XCTAssertFalse(session.isBackfilledRestPlaceholder, "day is set, so this isn't the named placeholder shape")

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 0)
        XCTAssertNil(session.durationSeconds)
    }

    /// A session whose only exercise log is a rest-day activity (e.g. a
    /// logged walk) is excluded — that category never has a code path that
    /// sets durationSeconds at all, live or imported.
    @MainActor
    func testExcludesARestActivityOnlySession() {
        let context = makeContext()
        let session = WorkoutSession(dayLabel: "Rest", cycleNumber: 1)
        context.insert(session)
        addRestActivityLog(to: session, context: context)

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 0)
        XCTAssertNil(session.durationSeconds)
    }

    /// A session that already has a recorded duration is left alone.
    @MainActor
    func testLeavesAnAlreadyRecordedDurationUntouched() {
        let context = makeContext()
        let session = WorkoutSession(dayLabel: "Push", cycleNumber: 1)
        context.insert(session)
        addRealWorkoutLog(to: session, context: context)
        session.durationSeconds = 1800

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 0)
        XCTAssertEqual(session.durationSeconds, 1800)
    }

    // MARK: - The real fabrication

    /// A genuine logged workout (day == nil, "Manual"/imported shape, or a
    /// real scheduled day — any of them) with at least one real exercise
    /// log gets a fabricated duration in [3660, 4740].
    @MainActor
    func testFillsARealLoggedWorkoutWithAValueInRange() throws {
        let context = makeContext()
        let session = WorkoutSession(dayLabel: "Manual", cycleNumber: 0)
        context.insert(session)
        addRealWorkoutLog(to: session, context: context)

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 1)
        let duration = try XCTUnwrap(session.durationSeconds)
        XCTAssertTrue((3660...4740).contains(duration))
    }

    /// Each session gets its OWN independent random value — not one value
    /// stamped onto every session.
    @MainActor
    func testEachSessionGetsAnIndependentRandomValue() {
        let context = makeContext()
        var sessions: [WorkoutSession] = []
        for i in 0..<6 {
            let session = WorkoutSession(dayLabel: "Push \(i)", cycleNumber: 1)
            context.insert(session)
            addRealWorkoutLog(to: session, context: context)
            sessions.append(session)
        }

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 6)
        let durations = Set(sessions.compactMap(\.durationSeconds))
        XCTAssertGreaterThan(durations.count, 1, "6 independent random draws landing on the exact same value is not expected")
        for d in durations { XCTAssertTrue((3660...4740).contains(d)) }
    }

    /// Idempotent: running it a second time doesn't reassign an
    /// already-filled session to a new random value.
    @MainActor
    func testRunningTwiceDoesNotReassignAnAlreadyFilledSession() {
        let context = makeContext()
        let session = WorkoutSession(dayLabel: "Manual", cycleNumber: 0)
        context.insert(session)
        addRealWorkoutLog(to: session, context: context)

        XCTAssertEqual(WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context), 1)
        let firstValue = session.durationSeconds
        XCTAssertEqual(WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context), 0)
        XCTAssertEqual(session.durationSeconds, firstValue)
    }

    /// A mix of all shapes in the same fetch — only the genuine workout is
    /// touched.
    @MainActor
    func testOnlyFillsTheGenuineWorkoutAmongAMixOfShapes() {
        let context = makeContext()
        let placeholder = WorkoutSession(dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(placeholder)

        let phaseDay = PhaseDay(order: 0, name: "Rest", isRest: true)
        context.insert(phaseDay)
        let restCredit = WorkoutSession(day: phaseDay, dayLabel: "Rest", cycleNumber: 1)
        context.insert(restCredit)

        let restActivity = WorkoutSession(dayLabel: "Rest", cycleNumber: 1)
        context.insert(restActivity)
        addRestActivityLog(to: restActivity, context: context)

        let realWorkout = WorkoutSession(dayLabel: "Push", cycleNumber: 1)
        context.insert(realWorkout)
        addRealWorkoutLog(to: realWorkout, context: context)

        let filled = WorkoutSession.fillMissingDurationsWithFabricatedValues(context: context)
        XCTAssertEqual(filled, 1)
        XCTAssertNil(placeholder.durationSeconds)
        XCTAssertNil(restCredit.durationSeconds)
        XCTAssertNil(restActivity.durationSeconds)
        XCTAssertNotNil(realWorkout.durationSeconds)
    }
}
