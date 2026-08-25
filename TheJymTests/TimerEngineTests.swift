//
//  TimerEngineTests.swift
//  TheJymTests
//
//  Covers the pure sequencing logic — flattening a list of (name, seconds,
//  repeatCount, isRest) timers into the running order, and the resulting
//  segment/total bookkeeping. The actual wall-clock countdown, tone
//  playback, and notification scheduling aren't exercised here (TimerEngine
//  has no injectable clock), so this focuses on what's deterministic.
//

import XCTest
@testable import TheJym

@MainActor
final class TimerEngineTests: XCTestCase {
    override func tearDown() {
        TimerEngine.shared.stop()
        super.tearDown()
    }

    func testFlattensEachPresetRepeatedItsOwnRepeatCountInOrder() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Test",
                     presets: [(name: "Sprint", seconds: 30, repeatCount: 3, isRest: false),
                              (name: "Cooldown", seconds: 60, repeatCount: 1, isRest: false)],
                     continuous: true)

        XCTAssertEqual(engine.segments.count, 4)
        XCTAssertEqual(engine.segments.map(\.presetName), ["Sprint", "Sprint", "Sprint", "Cooldown"])
        XCTAssertEqual(engine.segments.map(\.repIndex), [1, 2, 3, 1])
        XCTAssertEqual(engine.segments.map(\.repCount), [3, 3, 3, 1])
        XCTAssertEqual(engine.segments.map(\.presetIndex), [0, 0, 0, 1])
        XCTAssertEqual(engine.segments.map(\.presetCount), [2, 2, 2, 2])
    }

    func testTotalSecondsSumsAcrossAllRepeats() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Test",
                     presets: [(name: "Work", seconds: 20, repeatCount: 2, isRest: false),
                              (name: "Rest", seconds: 10, repeatCount: 3, isRest: true)],
                     continuous: false)
        // (20 * 2) + (10 * 3) = 70
        XCTAssertEqual(engine.totalSeconds, 70, accuracy: 1e-9)
    }

    func testStartBeginsTheFirstSegmentImmediately() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Test",
                     presets: [(name: "Only", seconds: 45, repeatCount: 1, isRest: false)],
                     continuous: false)

        XCTAssertTrue(engine.isActive)
        XCTAssertFalse(engine.isFinished)
        XCTAssertFalse(engine.isAwaitingManualStart, "Start() should begin counting down right away, not wait for a manual tap")
        XCTAssertEqual(engine.currentSegment?.presetName, "Only")
        XCTAssertEqual(engine.remainingSeconds, 45, accuracy: 0.5)
    }

    func testStartWithNoPresetsDoesNothing() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Empty", presets: [], continuous: false)
        XCTAssertFalse(engine.isActive)
    }

    func testStopClearsAllState() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Test",
                     presets: [(name: "Only", seconds: 10, repeatCount: 1, isRest: false)],
                     continuous: true)
        XCTAssertTrue(engine.isActive)

        engine.stop()

        XCTAssertFalse(engine.isActive)
        XCTAssertNil(engine.currentSegment)
        XCTAssertTrue(engine.segments.isEmpty)
    }

    func testRepeatCountBelowOneIsTreatedAsOne() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Test",
                     presets: [(name: "Zero", seconds: 15, repeatCount: 0, isRest: false)],
                     continuous: true)
        XCTAssertEqual(engine.segments.count, 1)
        XCTAssertEqual(engine.segments.first?.repCount, 1)
    }

    func testIsRestPropagatesToEverySegmentFromItsOwnPreset() {
        let engine = TimerEngine.shared
        engine.start(templateName: "Test",
                     presets: [(name: "Sprint", seconds: 30, repeatCount: 2, isRest: false),
                              (name: "Rest", seconds: 15, repeatCount: 2, isRest: true)],
                     continuous: true)
        XCTAssertEqual(engine.segments.map(\.isRest), [false, false, true, true])
    }
}
