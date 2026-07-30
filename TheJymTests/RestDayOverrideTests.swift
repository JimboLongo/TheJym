//
//  RestDayOverrideTests.swift
//  TheJymTests
//
//  A day that was gap-filled with a no-activity "Rest Day" placeholder
//  (backfillRestDays / creditYesterdayAsRestIfNothingLogged) should have
//  that placeholder replaced, not duplicated alongside, once a real
//  workout gets logged or imported for that same date.
//

import XCTest
import SwiftData
@testable import TheJym

final class RestDayOverrideTests: XCTestCase {
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
    func testRemovesBackfilledPlaceholderOnThatDate() {
        let context = makeContext()
        let date = Date()
        context.insert(WorkoutSession(date: date, dayLabel: "Rest Day", cycleNumber: 0))
        try? context.save()

        WorkoutSession.removeBackfilledRestPlaceholder(on: date, context: context)
        try? context.save()

        let remaining = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testDoesNotRemoveARealScheduledRestDaySession() {
        let context = makeContext()
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let restDay = PhaseDay(order: 0, name: "Rest", isRest: true)
        restDay.phase = phase
        context.insert(restDay)

        let date = Date()
        // Live "Log Rest Day" logging sets `day`, unlike the gap-filled
        // placeholder — should survive untouched.
        context.insert(WorkoutSession(date: date, day: restDay, dayLabel: restDay.name, cycleNumber: 1))
        try? context.save()

        WorkoutSession.removeBackfilledRestPlaceholder(on: date, context: context)
        try? context.save()

        let remaining = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        XCTAssertEqual(remaining.count, 1, "A real scheduled Rest day session shouldn't be touched")
    }

    @MainActor
    func testDoesNotRemoveASessionWithExerciseLogs() {
        let context = makeContext()
        let date = Date()
        let session = WorkoutSession(date: date, dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log.session = session
        context.insert(log)
        try? context.save()

        WorkoutSession.removeBackfilledRestPlaceholder(on: date, context: context)
        try? context.save()

        let remaining = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        XCTAssertEqual(remaining.count, 1, "A session with real exercise logs isn't an empty placeholder")
    }

    @MainActor
    func testFinishingAWorkoutOverridesAPlaceholderOnTheSameDate() {
        let context = makeContext()
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let trainDay = PhaseDay(order: 0, name: "Push A", isRest: false)
        trainDay.phase = phase
        context.insert(trainDay)

        let date = Calendar.current.startOfDay(for: Date())
        context.insert(WorkoutSession(date: date, dayLabel: "Rest Day", cycleNumber: 0))
        try? context.save()
        XCTAssertEqual(phase.sessions.count, 0, "The placeholder isn't attributed to any phase")

        WorkoutSession.removeBackfilledRestPlaceholder(on: date, context: context)
        let real = WorkoutSession(date: date, day: trainDay, dayLabel: trainDay.name, cycleNumber: 1)
        real.phase = phase
        context.insert(real)
        try? context.save()

        let remaining = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.dayLabel, "Push A")
    }
}
