//
//  RestStopwatchTests.swift
//  TheJymTests
//
//  Covers the pause/resume/reset bookkeeping, the countdown-vs-count-up
//  modes, the target staying pinned to the set that was actually logged,
//  and the final-approach audio cues — displaySeconds is wall-clock
//  derived (no injectable clock here either, same as TimerEngine), so
//  assertions use small tolerances rather than exact values.
//
//  Every stopwatch here gets a no-op `playCue` — the real one goes through
//  TimerAudioEngine's actual AVAudioSession/AVAudioEngine, which has no
//  business running inside a unit test (it isn't a real device audio route)
//  and has been observed to hang the test process rather than fail fast
//  when it's exercised here.
//

import XCTest
@testable import TheJym

@MainActor
final class RestStopwatchTests: XCTestCase {
    private func makeStopwatch() -> RestStopwatch {
        let sw = RestStopwatch()
        sw.playCue = { _, _, _ in }
        return sw
    }

    // MARK: Count-up mode (nil target — no rest time set)

    func testResetAndStartWithNoTargetCountsUpFromZero() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, 0.2, accuracy: 0.1)
    }

    func testStopFreezesDisplaySecondsInPlace() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        let frozen = sw.displaySeconds
        XCTAssertFalse(sw.isRunning)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, frozen, accuracy: 0.01, "Shouldn't advance while stopped")
    }

    /// Stopping has to silence the final-approach cues, not just freeze
    /// the number. This is what WorkoutLogView relies on when every
    /// exercise is complete: the workout is over, and a rest timer that
    /// kept beeping its way down to 0:00 afterwards is the actual nuisance
    /// being fixed — freezing the display alone wouldn't do it.
    func testStopSilencesTheRemainingAudioCues() {
        var cues = 0
        let sw = RestStopwatch()
        sw.playCue = { _, _, _ in cues += 1 }

        // A 1s target is already inside the 5-4-3-2-1 window, so
        // resetAndStart fires its due cues synchronously. Everything after
        // this point is what the ticker would go on to play.
        sw.resetAndStart(targetSeconds: 1)
        let firedAtStart = cues

        sw.stop()
        // Well past when the 0:00 tone would have landed.
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(cues, firedAtStart,
                       "a stopped rest timer must not play its way down to zero")
    }

    func testResumeContinuesFromWhereItStopped() {
        let sw = makeStopwatch()
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
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.resume()
        XCTAssertEqual(sw.displaySeconds, 0.2, accuracy: 0.1, "Resuming an already-running stopwatch shouldn't restart its anchor")
    }

    func testResetZeroesButKeepsRunningIfItWasRunning() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.reset()
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1)
    }

    func testResetZeroesButStaysPausedIfItWasPaused() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        sw.reset()
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.01)
    }

    func testResetAndStartOverridesAManualPause() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.1)
        sw.stop()
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertTrue(sw.isRunning, "A fresh set completion should resume counting even if it was manually paused")
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1)
    }

    // MARK: Countdown mode (a real rest time)

    func testResetAndStartWithTargetCountsDown() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertEqual(sw.displaySeconds, 90, accuracy: 0.1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sw.displaySeconds, 89.8, accuracy: 0.1)
    }

    func testCountdownContinuesNegativePastZeroRatherThanFlooring() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 0)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sw.displaySeconds, -0.3, accuracy: 0.1, "Should keep counting down past 0, not hold at it")
        XCTAssertTrue(sw.isAtZero)
        XCTAssertTrue(sw.isRunning, "Still running, not stopped, until the next set is logged")
    }

    func testResetOnACountdownReturnsToTheFullTargetNotZero() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        Thread.sleep(forTimeInterval: 0.2)
        sw.reset()
        XCTAssertEqual(sw.displaySeconds, 60, accuracy: 0.1)
        XCTAssertTrue(sw.isRunning)
    }

    func testResetWhilePausedOnACountdownAlsoReturnsToTheFullTarget() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        Thread.sleep(forTimeInterval: 0.2)
        sw.stop()
        sw.reset()
        XCTAssertEqual(sw.displaySeconds, 60, accuracy: 0.01)
        XCTAssertFalse(sw.isRunning)
    }

    func testIsUrgentOnceWithinTenSecondsOfZero() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 9)
        XCTAssertTrue(sw.isUrgent)
    }

    func testIsNotUrgentWithMoreThanTenSecondsLeft() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertFalse(sw.isUrgent)
    }

    func testCountUpModeIsNeverUrgentOrAtZero() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertFalse(sw.isUrgent)
        XCTAssertFalse(sw.isAtZero)
    }

    func testANewLoggedSetSwitchesModesCleanly() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        sw.resetAndStart(targetSeconds: 45)
        XCTAssertEqual(sw.displaySeconds, 45, accuracy: 0.1, "A fresh set on a different exercise should retarget, not keep the old mode")
    }

    // MARK: The target is pinned to the logged set — swiping never moves it
    //
    // These replace an earlier `retarget(to:)` suite that asserted the
    // opposite (the countdown following whichever exercise was on screen).
    // That method is gone: `resetAndStart(targetSeconds:)` is now the only
    // way `targetSeconds` ever changes, so there is deliberately no API a
    // page swipe could call to move the target. What's left to pin down is
    // that the target genuinely holds still on its own.

    func testTargetHoldsItsOriginalValueAsTimeElapses() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        XCTAssertEqual(sw.targetSeconds, 60)
        Thread.sleep(forTimeInterval: 0.3)
        // Still counting down from the SAME 60, just further along — a
        // swipe to an exercise with a different rest time can't change
        // either half of this.
        XCTAssertEqual(sw.targetSeconds, 60)
        XCTAssertEqual(sw.displaySeconds, 59.7, accuracy: 0.1)
    }

    func testOnlyANewLoggedSetChangesTheTarget() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        Thread.sleep(forTimeInterval: 0.2)
        // Every other public control leaves the target exactly where it is.
        sw.stop()
        XCTAssertEqual(sw.targetSeconds, 60)
        sw.resume()
        XCTAssertEqual(sw.targetSeconds, 60)
        sw.reset()
        XCTAssertEqual(sw.targetSeconds, 60, "Reset returns to the top of the SAME target, it doesn't clear it")
        // Only logging a set against a different exercise moves it.
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertEqual(sw.targetSeconds, 90)
    }

    func testExpiredStateIsClearedOnlyByANewLoggedSetNotBySwiping() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 0)
        XCTAssertTrue(sw.isAtZero)
        // The countdown holds at 0:00 (blinking red) until the NEXT set is
        // logged — it no longer leaves that state just because a longer
        // exercise came on screen.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(sw.isAtZero, "Must hold at zero, not recover on its own")
        sw.resetAndStart(targetSeconds: 30)
        XCTAssertFalse(sw.isAtZero, "isAtZero must be derived live, not latched from the previous target")
        XCTAssertEqual(sw.displaySeconds, 30, accuracy: 0.1)
    }

    func testANewLoggedSetWithNoRestTimeFallsBackToCountUp() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 60)
        Thread.sleep(forTimeInterval: 0.2)
        sw.resetAndStart(targetSeconds: nil)
        XCTAssertNil(sw.targetSeconds)
        XCTAssertEqual(sw.displaySeconds, 0, accuracy: 0.1, "Count-up re-anchors from 0 — this is a logged set, not a swipe")
        XCTAssertFalse(sw.isUrgent)
        XCTAssertFalse(sw.isAtZero)
    }

    // MARK: Fixed-duration restarts (the bar's Warm / Ready buttons)
    //
    // Both buttons call resetAndStart(targetSeconds:) with a constant, so
    // they behave exactly like logging a set: a fresh anchor, not a target
    // change on a running countdown.

    func testAFixedDurationRestartOverridesARunningCountdownWithNoStaleState() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 300)
        Thread.sleep(forTimeInterval: 0.3)
        sw.resetAndStart(targetSeconds: 60)   // "Warm"
        XCTAssertEqual(sw.targetSeconds, 60)
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 60, accuracy: 0.1,
                       "elapsed must re-anchor to 0, not carry the 0.3s over from the previous run")
    }

    /// Overrides a manual pause too — isRunning comes back true without
    /// needing a separate resume.
    func testAFixedDurationRestartOverridesAManualPause() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 300)
        sw.stop()
        XCTAssertFalse(sw.isRunning)
        sw.resetAndStart(targetSeconds: 90)   // "Ready"
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.displaySeconds, 90, accuracy: 0.1)
    }

    /// The cue bookkeeping has to clear on the new anchor, or a countdown
    /// that already played its final approach would suppress the beeps for
    /// the next one. Driven here with short targets so the cues fire
    /// synchronously.
    func testFixedDurationRestartsMakeTheFinalApproachCuesEligibleAgain() {
        let sw = makeStopwatch()
        var fireCount = 0
        sw.playCue = { _, _, _ in fireCount += 1 }
        sw.resetAndStart(targetSeconds: 2)
        XCTAssertEqual(fireCount, 1, "entering at remaining == 2 fires that cue")
        sw.resetAndStart(targetSeconds: 2)
        XCTAssertEqual(fireCount, 2, "a fresh restart must let it fire again, not treat it as consumed")
    }

    /// A 60s or 90s restart is well outside the final-5-second window, so
    /// it must not fire anything on the spot — the beeps belong at the end
    /// of the countdown, not the start.
    func testAFixedDurationRestartFiresNoCueImmediately() {
        let sw = makeStopwatch()
        var fireCount = 0
        sw.playCue = { _, _, _ in fireCount += 1 }
        sw.resetAndStart(targetSeconds: 60)
        XCTAssertEqual(fireCount, 0)
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertEqual(fireCount, 0)
    }

    /// The red blinking hold is derived live from the target, so a
    /// fixed-duration restart clears an expired state rather than latching.
    func testAFixedDurationRestartClearsTheZeroHold() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 0)
        XCTAssertTrue(sw.isAtZero)
        XCTAssertTrue(sw.isUrgent)
        sw.resetAndStart(targetSeconds: 60)
        XCTAssertFalse(sw.isAtZero)
        XCTAssertFalse(sw.isUrgent, "60s in is nowhere near the 10s urgent window")
    }

    // MARK: Audio cues

    func testNoCuesFireAboveTheFiveSecondWindow() {
        let sw = makeStopwatch()
        var fired: [Double] = []
        sw.playCue = { frequency, _, _ in fired.append(frequency) }
        sw.resetAndStart(targetSeconds: 90)
        XCTAssertTrue(fired.isEmpty)
    }

    func testCueFiresOnceWhenEnteringEachThreshold() {
        let sw = makeStopwatch()
        var fireCount = 0
        sw.playCue = { _, _, _ in fireCount += 1 }
        sw.resetAndStart(targetSeconds: 3)
        // Entering at remaining == 3 should fire exactly the "3" cue, not
        // also "5" and "4" (never crossed).
        XCTAssertEqual(fireCount, 1)
    }

    func testZeroToneFiresOnceAndOnlyOnceAtExpiry() {
        let sw = makeStopwatch()
        var durations: [Double] = []
        sw.playCue = { _, duration, _ in durations.append(duration) }
        sw.resetAndStart(targetSeconds: 0)
        XCTAssertEqual(durations.filter { $0 == 3.0 }.count, 1, "Exactly one 3-second tone at 0")
    }

    /// Re-entering the final window on a NEW logged set lets the same cue
    /// fire again — previously exercised by swiping a target back up and
    /// down via retarget(to:), which no longer exists.
    func testTheSameCueFiresAgainOnTheNextLoggedSet() {
        let sw = makeStopwatch()
        var fireCount = 0
        sw.playCue = { _, _, _ in fireCount += 1 }
        sw.resetAndStart(targetSeconds: 2) // fires the "2" cue immediately
        XCTAssertEqual(fireCount, 1)
        sw.resetAndStart(targetSeconds: 2) // next set, same short rest time
        XCTAssertEqual(fireCount, 2, "A fresh set at the same target should let the cue fire again")
    }

    func test0ToneIsEligibleAgainOnTheNextLoggedSet() {
        let sw = makeStopwatch()
        var zeroToneCount = 0
        sw.playCue = { _, duration, _ in if duration == 3.0 { zeroToneCount += 1 } }
        sw.resetAndStart(targetSeconds: 0) // expires immediately
        XCTAssertEqual(zeroToneCount, 1)
        sw.resetAndStart(targetSeconds: 0) // next set, expires immediately again
        XCTAssertEqual(zeroToneCount, 2, "The 0-second tone must be eligible again on a fresh set")
    }

    func testNoCuesFireWhilePaused() {
        let sw = makeStopwatch()
        sw.resetAndStart(targetSeconds: 3)
        sw.stop()
        var fireCount = 0
        sw.playCue = { _, _, _ in fireCount += 1 }
        // reset() re-evaluates cues (and clears firedThresholds), so this
        // would fire the "3" cue if the paused guard weren't holding.
        sw.reset()
        XCTAssertEqual(fireCount, 0, "Paused shouldn't play cues even if bookkeeping updates")
    }

    func testResetMakesAllCuesEligibleAgainEvenForAShortTarget() {
        let sw = makeStopwatch()
        var fireCount = 0
        sw.resetAndStart(targetSeconds: 3) // fires "3" once, with a no-op playCue set after
        sw.playCue = { _, _, _ in fireCount += 1 }
        sw.reset() // back to remaining == 3 on the same short target
        XCTAssertEqual(fireCount, 1, "Reset should make the '3' cue eligible again even though remaining lands back on the same number")
    }

    func testCountUpModeNeverFiresCues() {
        let sw = makeStopwatch()
        var fireCount = 0
        sw.playCue = { _, _, _ in fireCount += 1 }
        sw.resetAndStart(targetSeconds: nil)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fireCount, 0)
    }
}
