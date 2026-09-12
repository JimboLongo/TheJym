//
//  ClaudeStatsEngineTests.swift
//  TheJymTests
//
//  Covers the two genuinely new pieces of logic behind the Claude Stats
//  page: MomentumEngine's normalization/weighting, and
//  StatsEngine.consistencyDayKind's day classification.
//

import XCTest
import SwiftData
@testable import TheJym

final class MomentumEngineTests: XCTestCase {

    // MARK: - normalizedPace

    func testNormalizedPaceIsHalfExactlyOnPace() {
        XCTAssertEqual(MomentumEngine.normalizedPace(0), 0.5, accuracy: 0.0001)
    }

    func testNormalizedPaceClampsAtCeilingAhead() {
        XCTAssertEqual(MomentumEngine.normalizedPace(5, ceilingDays: 5), 1.0, accuracy: 0.0001)
        // Far beyond the ceiling should clamp to the same 1.0, not keep climbing.
        XCTAssertEqual(MomentumEngine.normalizedPace(50, ceilingDays: 5), 1.0, accuracy: 0.0001)
    }

    func testNormalizedPaceClampsAtCeilingBehind() {
        XCTAssertEqual(MomentumEngine.normalizedPace(-5, ceilingDays: 5), 0.0, accuracy: 0.0001)
        XCTAssertEqual(MomentumEngine.normalizedPace(-50, ceilingDays: 5), 0.0, accuracy: 0.0001)
    }

    func testNormalizedPaceIsLinearBetweenCeilings() {
        // Halfway behind the ceiling (-2.5 of 5) should sit halfway between 0 and 0.5.
        XCTAssertEqual(MomentumEngine.normalizedPace(-2, ceilingDays: 4), 0.25, accuracy: 0.0001)
        XCTAssertEqual(MomentumEngine.normalizedPace(2, ceilingDays: 4), 0.75, accuracy: 0.0001)
    }

    // MARK: - normalizedStreak

    func testNormalizedStreakZeroIsZero() {
        XCTAssertEqual(MomentumEngine.normalizedStreak(0), 0, accuracy: 0.0001)
    }

    func testNormalizedStreakScalesLinearlyToCeiling() {
        XCTAssertEqual(MomentumEngine.normalizedStreak(7, ceiling: 14), 0.5, accuracy: 0.0001)
    }

    func testNormalizedStreakClampsAtOneBeyondCeiling() {
        XCTAssertEqual(MomentumEngine.normalizedStreak(14, ceiling: 14), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MomentumEngine.normalizedStreak(100, ceiling: 14), 1.0, accuracy: 0.0001)
    }

    // MARK: - score (active phase: adherence 50 / pace 30 / streak 20)

    func testScorePerfectEverythingIsOneHundred() {
        // adherence 100 -> 1.0, cyclePaceDelta way ahead -> 1.0, streak way past ceiling -> 1.0
        let score = MomentumEngine.score(adherencePercent: 100, cyclePaceDelta: 20, currentStreak: 100, percentLogged: 1)
        XCTAssertEqual(score, 100)
    }

    func testScoreZeroEverythingIsZero() {
        let score = MomentumEngine.score(adherencePercent: 0, cyclePaceDelta: -20, currentStreak: 0, percentLogged: 0)
        XCTAssertEqual(score, 0)
    }

    func testScoreOnPaceHalfAdherenceNoStreakWeightsCorrectly() {
        // adherence01 = 0.5 * 0.5 = 0.25; pace01 = 0.5 (on pace) * 0.3 = 0.15; streak01 = 0 * 0.2 = 0
        // composite = 0.40 -> 40
        let score = MomentumEngine.score(adherencePercent: 50, cyclePaceDelta: 0, currentStreak: 0, percentLogged: 0.5)
        XCTAssertEqual(score, 40)
    }

    // MARK: - score (no active phase: fold pace's 30% into adherence -> 80/20)

    func testScoreWithNoActivePhaseUsesPercentLoggedFallback() {
        // No active phase -> adherencePercent/cyclePaceDelta both nil.
        // percentLogged 1.0 * 0.8 = 0.8; streak past ceiling * 0.2 = 0.2 -> 100
        let score = MomentumEngine.score(adherencePercent: nil, cyclePaceDelta: nil, currentStreak: 100, percentLogged: 1.0)
        XCTAssertEqual(score, 100)
    }

    func testScoreWithNoActivePhaseAndNoStreakIsJustAdherenceShare() {
        // percentLogged 0.5 * 0.8 = 0.4; streak 0 -> 40
        let score = MomentumEngine.score(adherencePercent: nil, cyclePaceDelta: nil, currentStreak: 0, percentLogged: 0.5)
        XCTAssertEqual(score, 40)
    }

    func testScoreClampsPercentLoggedAboveOne() {
        // percentLogged can exceed 1.0 in principle (bonus sessions) — must not push score past 100.
        let score = MomentumEngine.score(adherencePercent: nil, cyclePaceDelta: nil, currentStreak: 100, percentLogged: 2.0)
        XCTAssertEqual(score, 100)
    }
}

final class ConsistencyDayKindTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let today = Calendar.current.startOfDay(for: .now)

    // MARK: - empty

    func testEmptyWhenNoSessionAtAllThatDay() {
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: []), .empty)
    }

    // MARK: - rest

    @MainActor
    func testRestForBackfilledPlaceholder() {
        let context = makeContext()
        let session = WorkoutSession(date: today, dayLabel: "Rest Day", cycleNumber: 0)
        context.insert(session)
        XCTAssertTrue(session.isBackfilledRestPlaceholder)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: [session]), .rest)
    }

    @MainActor
    func testRestForPlainRestDayCreditWithNoExerciseLogs() {
        let context = makeContext()
        // Mirrors TodayView.logPlainRestDay(): day set, dayLabel from the
        // scheduled day, but zero exercise logs.
        let session = WorkoutSession(date: today, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(session)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: [session]), .rest)
    }

    @MainActor
    func testRestForLoggedRestDayActivity() {
        let context = makeContext()
        let session = WorkoutSession(date: today, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(session)
        let activity = RestDayActivity(date: today, name: "Walk", distance: 2.5)
        context.insert(activity)
        let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log.session = session
        log.restDayActivity = activity
        context.insert(log)
        let set = SetLog(index: 0, weight: 2.5, reps: 1)
        set.exerciseLog = log
        context.insert(set)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: [session]), .rest)
    }

    // MARK: - trained / deload

    @MainActor
    func testTrainedForARealExerciseLog() {
        let context = makeContext()
        let session = WorkoutSession(date: today, dayLabel: "Push Day", cycleNumber: 1, isDeload: false)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: [session]), .trained)
    }

    @MainActor
    func testDeloadForADeloadSessionWithARealExerciseLog() {
        let context = makeContext()
        let session = WorkoutSession(date: today, dayLabel: "Push Day", cycleNumber: 1, isDeload: true)
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 100, reps: 8)
        set.exerciseLog = log
        context.insert(set)
        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: [session]), .deload)
    }

    /// A real training log wins even if another session logged the same day
    /// is rest-activity-only (e.g. a bonus walk logged after the workout).
    @MainActor
    func testTrainedWinsOverACoincidentRestActivitySessionSameDay() {
        let context = makeContext()
        let trainedSession = WorkoutSession(date: today, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(trainedSession)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8, 8, 8], order: 0)
        log.session = trainedSession
        context.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        context.insert(set)

        let restSession = WorkoutSession(date: today, dayLabel: "Push Day", cycleNumber: 1)
        context.insert(restSession)
        let activity = RestDayActivity(date: today, name: "Walk")
        context.insert(activity)
        let restLog = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        restLog.session = restSession
        restLog.restDayActivity = activity
        context.insert(restLog)
        let restSet = SetLog(index: 0, weight: 0, reps: 1)
        restSet.exerciseLog = restLog
        context.insert(restSet)

        XCTAssertEqual(StatsEngine.consistencyDayKind(on: today, sessions: [trainedSession, restSession]), .trained)
    }
}
