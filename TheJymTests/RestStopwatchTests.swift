//
//  RestStopwatchTests.swift
//  TheJymTests
//
//  Covers the pause/resume/reset bookkeeping — elapsed is wall-clock
//  derived (no injectable clock here either, same as TimerEngine), so
//  assertions use small tolerances rather than exact values.
//

import XCTest
@testable import TheJym

@MainActor
final class RestStopwatchTests: XCTestCase {
    func testResetAndStartBeginsFromZero() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.1)
    }

    func testStopFreezesElapsedInPlace() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        let frozen = sw.elapsed
        XCTAssertFalse(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.elapsed, frozen, accuracy: 0.01, "Elapsed shouldn't advance while stopped")
    }

    func testResumeContinuesFromWhereItStopped() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        let frozen = sw.elapsed
        sw.resume()
        XCTAssertTrue(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.elapsed, frozen + 0.2, accuracy: 0.1, "Resume should add to the frozen total, not restart it")
    }

    func testResumeWhileAlreadyRunningIsANoOp() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        Thread.sleep(forTimeInterval: 0.2)
        sw.resume()
        XCTAssertEqual(sw.elapsed, 0.2, accuracy: 0.1, "Resuming an already-running stopwatch shouldn't restart its anchor")
    }

    func testResetZeroesButKeepsRunningIfItWasRunning() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        Thread.sleep(forTimeInterval: 0.2)
        sw.reset()
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.1)
    }

    func testResetZeroesButStaysPausedIfItWasPaused() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        sw.reset()
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.01)
    }

    func testResetAndStartOverridesAManualPause() {
        let sw = RestStopwatch()
        sw.resetAndStart()
        Thread.sleep(forTimeInterval: 0.1)
        sw.stop()
        sw.resetAndStart()
        XCTAssertTrue(sw.isRunning, "A fresh set completion should resume counting even if it was manually paused")
        XCTAssertEqual(sw.elapsed, 0, accuracy: 0.1)
    }
}
