//
//  RestStopwatch.swift
//  TheJym
//
//  A plain count-up stopwatch for the workout log screen — deliberately NOT
//  TimerEngine, which is a countdown engine with alarms, an audio loop, and
//  UNUserNotificationCenter integration, none of which applies to a rest
//  stopwatch (and which must never beep). One instance per active workout,
//  hoisted to WorkoutLogView itself (see its own doc on completedSummaryCollapsed
//  for why state needs to live above the paging LazyVStack) so it survives a
//  swipe between exercise pages.
//
//  Same wall-clock-anchored approach as TimerEngine (segmentEndDate/
//  catchUpAndStartTicking): elapsed is always DERIVED from a stored Date via
//  now - start, never accumulated by incrementing a counter on each tick —
//  a counter would freeze while the screen is locked or the app is
//  backgrounded mid-set, exactly when this needs to stay accurate. The
//  1-second Timer here only exists to force the UI to keep re-reading the
//  computed `elapsed` property; it isn't the source of truth.
//
//  Deliberately not persisted (no UserDefaults, no Codable draft field) —
//  this is live state for the current on-screen session only, not part of
//  the logged workout.
//

import Foundation
import Combine

@MainActor
final class RestStopwatch: ObservableObject {
    @Published private(set) var isRunning = false
    /// Bumped every tick purely to force observers to re-read `elapsed` — a
    /// computed property, so it isn't itself @Published and wouldn't
    /// otherwise trigger a per-second UI refresh. Same trick as
    /// TimerEngine.tickToken.
    @Published private var tickToken = 0

    /// Elapsed time banked from any previous run(s) since the last reset —
    /// frozen (not advancing) whenever `startDate` is nil.
    private var accumulated: TimeInterval = 0
    /// When the current run started counting from `accumulated` — nil while
    /// paused.
    private var startDate: Date?
    private var ticker: Timer?

    var elapsed: TimeInterval {
        guard let startDate else { return accumulated }
        return accumulated + Date().timeIntervalSince(startDate)
    }

    deinit {
        ticker?.invalidate()
    }

    /// Fires whenever a set's reps are committed — always zeroes and starts
    /// counting from now, overriding a manual pause if one was in effect,
    /// since the whole point is "time since the last completed set."
    func resetAndStart() {
        accumulated = 0
        startDate = Date()
        isRunning = true
        startTicking()
    }

    /// Pause — freezes the displayed elapsed time in place rather than
    /// clearing it, so Resume can continue from here.
    func stop() {
        guard isRunning else { return }
        accumulated = elapsed
        startDate = nil
        isRunning = false
        stopTicking()
    }

    /// Continues from wherever Stop froze it — a no-op if already running.
    func resume() {
        guard !isRunning else { return }
        startDate = Date()
        isRunning = true
        startTicking()
    }

    /// Zeroes the elapsed time without changing whether it's running —
    /// still counting from 0 if it was running, still paused at 0 if not.
    /// The only control that clears the count; Stop/Resume never do.
    func reset() {
        accumulated = 0
        if isRunning { startDate = Date() }
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickToken += 1 }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}
