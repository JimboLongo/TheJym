//
//  RestStopwatchTests.swift
//  TheJymTests
//
//  Covers the pause/resume/reset bookkeeping and the countdown-vs-count-up
//  modes — displaySeconds is wall-clock derived (no injectable clock here
//  either, same as TimerEngine), so assertions use small tolerances rather
//  than exact values.
//

import XCTest
@testable import TheJym

@MainActor
final class RestStopwatchTests: XCTestCase {
    // MARK: Count-up mode (nil target — no rest time set)

    func testResetAndStartWithNoTargetCountsUpFromZero() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, 0.2, accuracy: 0.1)
    }

    func testStopFreezesDisplaySecondsInPlace() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        let frozen = sw.displaySeconds
        XCTAssertFalse(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, frozen, accuracy: 0.01, "Shouldn't advance while stopped")
    }

    func testResumeContinuesFromWhereItStopped() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        let frozen = sw.displaySeconds
        sw.resume()
        XCTAssertTrue(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, frozen + 0.2, accuracy: 0.1, "Resume should add to the frozen total, not restart it")
    }

    func testResumeWhileAlreadyRunningIsANoOp() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.resume()
        XCTAssertEqual(sw.displaySeconds, 0.2, accuracy: 0.1, "Resuming an already-running stopwatch shouldn't restart its anchor")
    }

    func testResetZeroesButKeepsRunningIfItWasRunning() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.reset()
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1)
    }

    func testResetZeroesButStaysPausedIfItWasPaused() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        sw.reset()
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.01)
    }

    func testResetAndStartOverridesAManualPause() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.1)
        sw.stop()
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertTrue(sw.isRunning, "A fresh set completion should resume counting even if it was manually paused")
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1)
    }

    // MARK: Countdown mode (a real rest time)

    func testResetAndStartWithTargetCountsDown() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertEqual(sw.displaySeconds, 90, accuracy: 0.1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, 89.8, accuracy: 0.1)
    }

    func testCountdownFloorsAtZeroRatherThanGoingNegative() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: 0)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.001)
        XCTAssertTrue(sw.isAtZero)
        XCTAssertTrue(sw.isRunning, "Holding at zero, not stopped, until the next set is logged")
    }

    func testResetOnACountdownReturnsToTheFullTargetNotZero() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        Thread.sleep(forTimeInterval: 0.2)
        sw.reset()
        XCTAssertEqual(sw.displaySeconds, 60, accuracy: 0.1)
        XCTAssertTrue(sw.isRunning)
    }

    func testResetWhilePausedOnACountdownAlsoReturnsToTheFullTarget() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        sw.reset()
        XCTAssertEqual(sw.displaySeconds, 60, accuracy: 0.01)
        XCTAssertFalse(sw.isRunning)
    }

    func testIsUrgentOnceWithinTenSecondsOfZero() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: 9)
        XCTAssertTrue(sw.isUrgent)
    }

    func testIsNotUrgentWithMoreThanTenSecondsLeft() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertFalse(sw.isUrgent)
    }

    func testCountUpModeIsNeverUrgentOrAtZero() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertFalse(sw.isUrgent)
        XCTAssertFalse(sw.isAtZero)
    }

    func testRetargetingOnANewSetSwitchesModesCleanly() {
        let sw = RestStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.resetAndStart(targetSeconds: 45)
        XCTAssertEqual(sw.displaySeconds, 45, accuracy: 0.1, "A fresh set on a different exercise should retarget, not keep the old mode")
    }
}
