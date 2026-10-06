//
//  WorkoutImpactTests.swift
//  TheJymTests
//
//  The two day-count deltas finishWorkout hands to the Stats tab. Both are
//  DAY counts, so each is 0 or 1 — the interesting cases are the ones
//  where they disagree with each other, or where nothing should be shown
//  at all.
//

import XCTest
import SwiftData
@testable import TheJym

final class WorkoutImpactTests: XCTestCase {
    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: .now) }

    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    @discardableResult
    private func lift(on date: Date, context: ModelContext) -> WorkoutSession {
        let s = WorkoutSession(date: date, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(s)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
        log.session = s
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)
        return s
    }

    @MainActor
    private func walk(on date: Date, context: ModelContext) -> WorkoutSession {
        let activity = RestDayActivity(date: date, name: "Walk", distance: 2.5)
        context.insert(activity)
        let s = WorkoutSession(date: date, dayLabel: "Rest", cycleNumber: 1)
        context.insert(s)
        let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log.session = s
        log.restDayActivity = activity
        context.insert(log)
        let set = SetLog(index: 0, weight: 2.5, reps: 1)
        set.exerciseLog = log
        context.insert(set)
        return s
    }

    @MainActor
    private func deltas(_ existing: [WorkoutSession], on day: Date,
                        isLift: Bool = true) -> WorkoutImpact.Deltas {
        WorkoutImpact.deltas(forFinishingOn: day, existingSessions: existing,
                             newSessionIsLift: isLift)
    }

    // MARK: - The two cases that aren't obvious

    /// A lift on a day that already had a walk: the day was ALREADY
    /// active, so only the Lift count gains a new day. One badge, not two,
    /// and specifically not "+0" over Active.
    @MainActor
    func testLiftOnADayThatAlreadyHadAWalk() {
        let context = makeContext()
        let existingWalk = walk(on: today, context: context)

        let d = deltas([existingWalk], on: today)
        XCTAssertEqual(d.lift, 1, "the day becomes a lift day for the first time")
        XCTAssertEqual(d.active, 0, "the walk already made it an active day")
        XCTAssertFalse(d.isEmpty, "so there IS something to badge")
    }

    /// A finish that logged nothing: no session-with-logs is created, so
    /// neither count moves and the singleton must stay unset rather than
    /// holding a pair of zeroes.
    @MainActor
    func testFinishWithNothingLoggedRecordsNoImpact() {
        let d = deltas([], on: today, isLift: false)
        XCTAssertEqual(d.active, 0)
        XCTAssertEqual(d.lift, 0)
        XCTAssertTrue(d.isEmpty)

        let impact = WorkoutImpact.shared
        impact.clear()
        impact.record(d)
        XCTAssertNil(impact.pending, "an all-zero delta must leave nothing pending")
        impact.clear()
    }

    // MARK: - The straightforward ones, for completeness

    @MainActor
    func testFirstActivityOfTheDayMovesBoth() {
        let d = deltas([], on: today)
        XCTAssertEqual(d.active, 1)
        XCTAssertEqual(d.lift, 1)
    }

    @MainActor
    func testSecondLiftOfTheDayMovesNeither() {
        let context = makeContext()
        let earlier = lift(on: today, context: context)
        let d = deltas([earlier], on: today)
        XCTAssertEqual(d.lift, 0, "a second lift adds no new DAY")
        XCTAssertEqual(d.active, 0)
        XCTAssertTrue(d.isEmpty, "nothing to badge")
    }

    /// Yesterday's sessions are irrelevant — these are per-day counts.
    @MainActor
    func testActivityOnAnotherDayDoesNotSuppressTheDelta() {
        let context = makeContext()
        let yesterday = lift(on: cal.date(byAdding: .day, value: -1, to: today)!, context: context)
        let d = deltas([yesterday], on: today)
        XCTAssertEqual(d.active, 1)
        XCTAssertEqual(d.lift, 1)
    }

    /// Backdating is supported: the comparison is against the LOGGED date,
    /// not today.
    @MainActor
    func testDeltasAreMeasuredAgainstTheLoggedDateNotToday() {
        let context = makeContext()
        let target = cal.date(byAdding: .day, value: -3, to: today)!
        let walkThen = walk(on: target, context: context)
        let liftToday = lift(on: today, context: context)

        let d = deltas([walkThen, liftToday], on: target)
        XCTAssertEqual(d.lift, 1, "that day had no lift")
        XCTAssertEqual(d.active, 0, "but it was already active, from the walk")
    }

    // MARK: - The singleton's one-shot behaviour

    @MainActor
    func testRecordThenClearLeavesNothingPending() {
        let impact = WorkoutImpact.shared
        impact.clear()
        impact.record(WorkoutImpact.Deltas(active: 1, lift: 1))
        XCTAssertEqual(impact.pending, WorkoutImpact.Deltas(active: 1, lift: 1))
        impact.clear()
        XCTAssertNil(impact.pending, "leaving the Stats tab clears it")
    }
}
