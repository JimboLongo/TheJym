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
//  is known, continuing past 0 into negative numbers (how far overdue the
//  next set is) rather than freezing there. Falls back to counting UP from 0
//  with no target when the current exercise has no rest time set (nil), so
//  the display is always useful either way.
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
    /// remaining time counting down through 0 and on into negative numbers —
    /// how overdue the next set is, rather than freezing at 0.
    var displaySeconds: Double {
        guard let targetSeconds else { return elapsed }
        return Double(targetSeconds) - elapsed
    }

    /// True once a countdown has reached (and passed) 0 — always false in
    /// count-up mode, which has no zero to reach.
    var isAtZero: Bool {
        guard let targetSeconds else { return false }
        return Double(targetSeconds) - elapsed <= 0
    }

    /// True in the last 10 seconds of a countdown (including once past 0) —
    /// irrelevant in count-up mode. 10s is the threshold "approaching zero"
    /// turns red and blinks at.
    var isUrgent: Bool {
        guard let targetSeconds else { return false }
        return Double(targetSeconds) - elapsed <= 10
    }

    /// Which of the final-approach cues (5,4,3,2,1 beeps, 0 tone) have
    /// already fired for the CURRENT approach to zero — not "for the
    /// current anchor": a threshold is un-fired (removed) the moment
    /// `remaining` rises back above it, so it's eligible to fire again on a
    /// later approach even without a real re-anchor. See `evaluateAudioCues`.
    private var firedThresholds: Set<Int> = []
    /// How a cue is actually played — real playback goes through
    /// TimerAudioEngine.shared (this app's one audio path; see its own file
    /// for why nothing here talks to AVAudioSession/AVAudioEngine directly).
    /// Overridable so tests can substitute a no-op: driving a target of 5s
    /// or less through resetAndStart/retarget synchronously calls this on
    /// the calling thread, and the real engine's AVAudioSession activation
    /// has no business running inside a unit test — it isn't a real device
    /// audio route, and it has hung the test process rather than failing
    /// fast when tried.
    var playCue: (_ frequency: Double, _ duration: Double, _ amplitude: Float) -> Void = { frequency, duration, amplitude in
        TimerAudioEngine.shared.playBeep(frequency: frequency, duration: duration, amplitude: amplitude)
    }

    deinit {
        ticker?.invalidate()
    }

    /// Fires whenever a set's reps are committed — always retargets to
    /// `targetSeconds` (that exercise's own rest time, or nil to fall back
    /// to counting up) and restarts from the top, overriding a manual pause
    /// if one was in effect, since the whole point is "time since/until the
    /// last completed set." Re-anchors elapsed to 0 — for changing the
    /// target WITHOUT touching elapsed (e.g. swiping to a different
    /// exercise), use `retarget(to:)` instead.
    func resetAndStart(targetSeconds: Int?) {
        self.targetSeconds = targetSeconds
        accumulated = 0
        startDate = Date()
        isRunning = true
        firedThresholds.removeAll()
        startTicking()
        evaluateAudioCues()
    }

    /// Changes which duration is being counted down to/from WITHOUT
    /// touching the elapsed-time anchor — for when the exercise being
    /// VIEWED changes (a swipe) rather than one being logged against.
    /// Elapsed time since the last logged set is the invariant; the target
    /// is just whichever exercise is currently on screen. A no-op if the
    /// target isn't actually changing.
    func retarget(to targetSeconds: Int?) {
        guard targetSeconds != self.targetSeconds else { return }
        self.targetSeconds = targetSeconds
        evaluateAudioCues()
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
        // Explicit, not left to evaluateAudioCues' own live filter — for a
        // target of 5s or less, the filter alone can leave a stale
        // "already fired" entry behind that coincidentally still satisfies
        // `remaining <= threshold` at the fresh full duration, silently
        // skipping a cue that should legitimately fire again on this new
        // run from the top.
        firedThresholds.removeAll()
        evaluateAudioCues()
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tickToken += 1
                self.evaluateAudioCues()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Audio cues — final-5-seconds beeps + a 0-second tone
    //
    // A short beep once per second for the final 5 seconds (5,4,3,2,1), one
    // 3-second tone at 0, then silence — the display keeps blinking red at
    // 0:00 until the next set, but this sits on screen for a whole workout
    // and must not keep beeping indefinitely.
    //
    // Ticks are wall-clock derived, not a guaranteed once-per-second
    // callback — one can land twice in the same second, or a gap (the app
    // backgrounding, a slow frame) can skip several seconds at once. Testing
    // `Int(remaining) == 5` on every tick would either double-fire on a
    // double-tick or silently skip a cue entirely on a gap. Tracking which
    // thresholds have already fired for the current approach sidesteps the
    // double-tick case for free (the threshold's already consumed, so
    // nothing plays again). For a gap — or a discontinuous jump from
    // retargeting, or a target that starts at 5s or less in the first
    // place — only the single nearest still-live threshold plays; the ones
    // it skipped over are marked fired without sound, since they were never
    // actually the "current" number on the way down (e.g. a fresh 3-second
    // target was never at 5 or 4 seconds remaining; a swipe that drops
    // remaining from 40s to -10s didn't audibly pass through 5,4,3,2,1
    // either). `firedThresholds` un-fires a threshold the moment `remaining`
    // rises back above it (see its own doc), so retargeting to a longer
    // duration (this file's `retarget(to:)`) or hitting Reset both make the
    // whole final approach eligible to play out again from scratch.
    private func evaluateAudioCues() {
        guard let targetSeconds else {
            firedThresholds.removeAll()
            return
        }
        let remaining = Double(targetSeconds) - elapsed
        firedThresholds = firedThresholds.filter { remaining <= Double($0) }
        guard isRunning, remaining <= 5 else { return }
        let current = max(0, min(5, Int(remaining.rounded(.down))))
        guard !firedThresholds.contains(current) else { return }
        for threshold in stride(from: 5, through: current, by: -1) {
            firedThresholds.insert(threshold)
        }
        if current == 0 {
            playCue(440, 3.0, 0.3)
        } else {
            playCue(880, 0.18, 0.35)
        }
    }
}
