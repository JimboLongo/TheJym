//
//  RestStopwatch.swift
//  TheJym
//
//  A plain rest timer for the workout log screen — deliberately NOT
//  TimerEngine, which is a countdown engine with alarms, an audio loop, and
//  UNUserNotificationCenter integration, none of which applies here (and
//  which must never beep). One instance per active workout, hoisted to
//  WorkoutLogView itself (see its own doc on completedSummaryCollapsed for
//  why state needs to live above the paging LazyVStack) so it survives a
//  swipe between exercise pages.
//
//  Counts DOWN from a target duration (an exercise's own rest time) when one
//  is known, floored at 0 rather than going negative or flipping to
//  counting up. Falls back to counting UP from 0 with no target when the
//  current exercise has no rest time set (nil), so the display is always
//  useful either way.
//
//  Same wall-clock-anchored approach as TimerEngine (segmentEndDate/
//  catchUpAndStartTicking): displaySeconds is always DERIVED from a stored
//  Date via now - start, never accumulated by incrementing a counter on each
//  tick — a counter would freeze while the screen is locked or the app is
//  backgrounded mid-set, exactly when this needs to stay accurate. The
//  1-second Timer here only exists to force the UI to keep re-reading the
//  computed `displaySeconds` property; it isn't the source of truth.
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
    /// Bumped every tick purely to force observers to re-read
    /// `displaySeconds` — a computed property, so it isn't itself @Published
    /// and wouldn't otherwise trigger a per-second UI refresh. Same trick as
    /// TimerEngine.tickToken.
    @Published private var tickToken = 0

    /// nil = counting up from 0 with no target (the current exercise has no
    /// rest time set); non-nil = counting down from this many seconds,
    /// floored at 0.
    private(set) var targetSeconds: Int?
    /// Time banked from any previous run(s) since the last reset/retarget —
    /// frozen (not advancing) whenever `startDate` is nil.
    private var accumulated: TimeInterval = 0
    /// When the current run started counting from `accumulated` — nil while
    /// paused.
    private var startDate: Date?
    private var ticker: Timer?

    /// Seconds elapsed since the current run's own anchor, ignoring the
    /// countdown floor — internal; the UI reads `displaySeconds` instead.
    private var elapsed: TimeInterval {
        guard let startDate else { return accumulated }
        return accumulated + Date().timeIntervalSince(startDate)
    }

    /// What the UI shows: elapsed time counting up with no target, or
    /// remaining time counting down to 0 and holding there — never negative.
    var displaySeconds: Double {
        guard let targetSeconds else { return elapsed }
        return max(0, Double(targetSeconds) - elapsed)
    }

    /// True once a countdown has reached (and is holding at) 0 — always
    /// false in count-up mode, which has no floor to hit.
    var isAtZero: Bool {
        guard let targetSeconds else { return false }
        return Double(targetSeconds) - elapsed <= 0
    }

    /// True in the last 10 seconds of a countdown (including while holding
    /// at 0) — irrelevant in count-up mode. 10s is the threshold "approaching
    /// zero" turns red and blinks at.
    var isUrgent: Bool {
        guard let targetSeconds else { return false }
        return Double(targetSeconds) - elapsed <= 10
    }

    deinit {
        ticker?.invalidate()
    }

    /// Fires whenever a set's reps are committed — always retargets to
    /// `targetSeconds` (that exercise's own rest time, or nil to fall back
    /// to counting up) and restarts from the top, overriding a manual pause
    /// if one was in effect, since the whole point is "time since/until the
    /// last completed set."
    func resetAndStart(targetSeconds: Int?) {
        self.targetSeconds = targetSeconds
        accumulated = 0
        startDate = Date()
        isRunning = true
        startTicking()
    }

    /// Pause — freezes the displayed time in place rather than clearing it,
    /// so Resume can continue from here.
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

    /// Returns to the full target duration (0 in count-up mode) without
    /// changing whether it's running or what the target is — still counting
    /// down from the top if it was running, still paused at the top if not.
    /// The only control that clears the elapsed time; Stop/Resume never do.
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
