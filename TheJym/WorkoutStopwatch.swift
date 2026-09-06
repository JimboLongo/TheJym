//
//  WorkoutStopwatch.swift
//  TheJym
//
//  Tracks total session duration for the workout currently being logged —
//  deliberately a SEPARATE object from RestStopwatch (per-set rest
//  countdown). Different lifetimes (this one spans the whole workout; a rest
//  countdown resets on every set) and different purposes; both can be on
//  screen at once, so they're never merged into one engine.
//
//  Same wall-clock-anchored approach as TimerEngine (segmentEndDate/
//  catchUpAndStartTicking) and RestStopwatch: elapsed is always DERIVED from
//  a stored Date via now - start, never accumulated by incrementing a
//  counter on each tick — a counter would freeze while the screen is locked
//  or the app is backgrounded, exactly when a workout is likely to sit idle
//  for a while. The 1-second Timer here only exists to force the UI to keep
//  re-reading the computed `elapsed` property; it isn't the source of truth.
//
//  Unlike RestStopwatch, this one IS meant to be persisted (see WorkoutLogView's
//  own doc on why: a workout can be backgrounded, and even fully killed by
//  the OS, and resumed later from its saved disk draft — "how long this
//  workout took" should reflect real elapsed wall-clock time across that,
//  the same way the draft's own logged sets survive it). This type stays
//  storage-agnostic itself (no UserDefaults inside it) — WorkoutLogView owns
//  reading/writing `snapshot` via its own draft-storage key, the same
//  separation `ExerciseDraft` already has from `saveDraftToDisk`/
//  `loadDraftFromDisk`.
//

import Foundation
import Combine

@MainActor
final class WorkoutStopwatch: ObservableObject {
    /// False until Start is tapped for the first time this workout — the
    /// page shows just a Start button until then, Pause/Resume/Reset after.
    @Published private(set) var hasStarted = false
    @Published private(set) var isRunning = false
    /// Bumped every tick purely to force observers to re-read `elapsed` — a
    /// computed property, so it isn't itself @Published and wouldn't
    /// otherwise trigger a per-second UI refresh. Same trick as
    /// TimerEngine.tickToken / RestStopwatch.tickToken.
    @Published private var tickToken = 0

    /// Time banked from any previous run(s) since the last reset — frozen
    /// (not advancing) whenever `startDate` is nil.
    private var accumulated: TimeInterval = 0
    /// When the current run started counting from `accumulated` — nil while
    /// paused.
    private var startDate: Date?
    private var ticker: Timer?

    var elapsed: TimeInterval {
        guard let startDate else { return accumulated }
        return accumulated + Date().timeIntervalSince(startDate)
    }

    /// Everything needed to restore this stopwatch exactly as it was —
    /// WorkoutLogView encodes/decodes this to/from UserDefaults itself.
    struct Snapshot: Codable {
        var hasStarted: Bool
        var isRunning: Bool
        var accumulated: TimeInterval
        var startDate: Date?
    }

    var snapshot: Snapshot {
        Snapshot(hasStarted: hasStarted, isRunning: isRunning, accumulated: accumulated, startDate: startDate)
    }

    /// Restores a previously-saved snapshot — e.g. on relaunch, after the
    /// app was fully killed while backgrounded mid-workout. If it was
    /// running when saved, ticking resumes immediately so `elapsed` keeps
    /// reflecting real time right away rather than looking frozen until the
    /// next manual interaction.
    func restore(_ snapshot: Snapshot) {
        hasStarted = snapshot.hasStarted
        isRunning = snapshot.isRunning
        accumulated = snapshot.accumulated
        startDate = snapshot.startDate
        if isRunning { startTicking() }
    }

    deinit {
        ticker?.invalidate()
    }

    /// Begins counting from 0 — a no-op if already started (this workout
    /// has no re-start; Reset is how you zero it again).
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        accumulated = 0
        startDate = Date()
        isRunning = true
        startTicking()
    }

    /// Pause — freezes the displayed elapsed time in place rather than
    /// clearing it, so Resume can continue from here. Also what
    /// finishWorkout() calls: the workout is done, so this stops counting.
    func pause() {
        guard isRunning else { return }
        accumulated = elapsed
        startDate = nil
        isRunning = false
        stopTicking()
    }

    /// Continues from wherever Pause froze it — a no-op if not yet started
    /// or already running.
    func resume() {
        guard hasStarted, !isRunning else { return }
        startDate = Date()
        isRunning = true
        startTicking()
    }

    /// Zeroes the elapsed time without changing whether it's running or
    /// started — still counting from 0 if it was running, still paused at 0
    /// if not. The only control that clears the count; Pause/Resume never
    /// do.
    func reset() {
        accumulated = 0
        if isRunning { startDate = Date() }
    }

    /// Reverts all the way to "never started" — the page goes back to
    /// showing just the Start button. Distinct from `reset()`, which only
    /// zeroes the count while staying started/running. Used when discarding
    /// the whole workout draft (Start Fresh), not for a normal in-workout
    /// reset.
    func clear() {
        hasStarted = false
        isRunning = false
        accumulated = 0
        startDate = nil
        stopTicking()
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
