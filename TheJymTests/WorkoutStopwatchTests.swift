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

    // MARK: Duration captured when the lifting stops, not when Finish is tapped
    //
    // WorkoutLogView pauses the stopwatch the moment every exercise has
    // collapsed (allExercisesComplete), rather than waiting for
    // finishWorkout(). These cover the stopwatch semantics that has to
    // rely on — finishWorkout itself is a private View method and can't
    // be called from here.

    /// The point of the change: time spent between finishing the last set
    /// and tapping Finish must not land in the saved duration.
    func testTimeAfterTheEarlyPauseIsNotCounted() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.3)
        sw.pause()                       // last exercise collapsed
        let atCompletion = sw.elapsed
        Thread.sleep(forTimeInterval: 0.4)   // user dawdles before tapping Finish
        XCTAssertEqual(sw.elapsed, atCompletion, accuracy: 0.01,
                       "the clock must stay frozen from completion to Finish")
        XCTAssertEqual(sw.elapsed, 0.3, accuracy: 0.15)
    }

    /// finishWorkout() still calls pause() after the early one. It must be
    /// a no-op rather than re-freezing or zeroing the accumulated total.
    func testPausingAgainAtFinishDoesNotDisturbTheAccumulatedTotal() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.3)
        sw.pause()                       // allExercisesComplete
        let atCompletion = sw.elapsed
        sw.pause()                       // finishWorkout()
        XCTAssertEqual(sw.elapsed, atCompletion, accuracy: 0.001,
                       "a second pause must not re-anchor or clear anything")
        XCTAssertFalse(sw.isRunning)
        XCTAssertTrue(sw.hasStarted)
    }

    /// Reopening an exercise resumes rather than locking the duration, and
    /// the time already banked before the reopen is kept — the total is
    /// both stretches, not just the second.
    func testReopeningResumesAndKeepsTheTimeAlreadyBanked() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.3)
        sw.pause()                       // completed
        let banked = sw.elapsed
        Thread.sleep(forTimeInterval: 0.2)   // paused gap — must not count
        sw.resume()                      // exercise reopened
        XCTAssertTrue(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.3)
        sw.pause()                       // completed again
        XCTAssertEqual(sw.elapsed, banked + 0.3, accuracy: 0.15,
                       "both working stretches count; the paused gap between them doesn't")
    }

    /// A workout finished with an exercise still open never hit the early
    /// pause, so finishWorkout()'s own pause is what stops it — and it
    /// still captures the full elapsed time.
    func testAWorkoutFinishedWithAnExerciseStillOpenIsStoppedByFinishInstead() {
        let sw = WorkoutStopwatch()
        sw.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(sw.isRunning, "never completed, so never early-paused")
        sw.pause()                       // finishWorkout()
        XCTAssertEqual(sw.elapsed, 0.3, accuracy: 0.15)
        XCTAssertFalse(sw.isRunning)
    }

    /// The early pause is guarded on isRunning, so a stopwatch that was
    /// never started stays never-started — durationSeconds stays nil
    /// rather than becoming 0.
    func testCompletingWithoutEverStartingLeavesItNeverStarted() {
        let sw = WorkoutStopwatch()
        XCTAssertFalse(sw.isRunning)
        sw.pause()                       // the guard makes this a no-op
        XCTAssertFalse(sw.hasStarted, "must stay nil-duration, not become a real 0")
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.001)
    }

    /// resume() is guarded on hasStarted, so a reopen before any set was
    /// ever logged can't start the clock behind the user's back.
    func testReopeningBeforeAnythingWasLoggedCannotStartTheClock() {
        let sw = WorkoutStopwatch()
        sw.resume()
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
