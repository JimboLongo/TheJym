//
//  WorkoutStopwatchTests.swift
//  TheJymTests
//
//  Covers start/pause/resume/reset/clear and the snapshot round-trip used to
//  persist across a backgrounded-and-killed app. Elapsed is wall-clock
//  derived (no injectable clock here either, same as TimerEngine), so
//  assertions use small tolerances rather than exact values.
//

import XCTest
@testable import TheJym

@MainActor
final class WorkoutStopwatchTests: XCTestCase {
    func testNeverStartedShowsZeroAndNotRunning() {
        let sw = WorkoutStopwatch()
        XCTAssertFalse(sw.hasStarted)
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.001)
    }

    func testStartBeginsCountingFromZero() {
        let sw = WorkoutStopwatch()
        sw.start()
        XCTAssertTrue(sw.hasStarted)
        XCTAssertTrue(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.elapsed, 0.2, accuracy: 0.1)
    }

    func testStartTwiceIsANoOpAndDoesNotRestart() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        sw.start()
        XCTAssertEqual(sw.elapsed, 0.2, accuracy: 0.1, "A second Start shouldn't reset an already-started workout")
    }

    func testPauseFreezesElapsedInPlace() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        sw.pause()
        let frozen = sw.elapsed
        XCTAssertFalse(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.elapsed, frozen, accuracy: 0.01, "Shouldn't advance while paused")
    }

    func testResumeContinuesFromWhereItPaused() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        sw.pause()
        let frozen = sw.elapsed
        sw.resume()
        XCTAssertTrue(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.elapsed, frozen + 0.2, accuracy: 0.1)
    }

    func testResumeBeforeStartIsANoOp() {
        let sw = WorkoutStopwatch()
        sw.resume()
        XCTAssertFalse(sw.hasStarted)
        XCTAssertFalse(sw.isRunning)
    }

    func testResetZeroesButKeepsRunningAndStarted() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        sw.reset()
        XCTAssertTrue(sw.hasStarted)
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.1)
    }

    func testClearRevertsToNeverStarted() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        sw.clear()
        XCTAssertFalse(sw.hasStarted)
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.001)
    }

    func testSnapshotRoundTripRestoresARunningWorkout() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        let snapshot = sw.snapshot

        let restored = WorkoutStopwatch()
        restored.restore(snapshot)
        XCTAssertTrue(restored.hasStarted)
        XCTAssertTrue(restored.isRunning)
        XCTAssertEqual(restored.elapsed, sw.elapsed, accuracy: 0.05)
        // And it keeps advancing after restore, as if the app never closed.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(restored.elapsed, snapshot.accumulated + 0.4, accuracy: 0.1)
    }

    func testSnapshotRoundTripRestoresAPausedWorkout() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.2)
        sw.pause()
        let snapshot = sw.snapshot

        let restored = WorkoutStopwatch()
        restored.restore(snapshot)
        XCTAssertTrue(restored.hasStarted)
        XCTAssertFalse(restored.isRunning)
        XCTAssertEqual(restored.elapsed, sw.elapsed, accuracy: 0.01)
    }
}
