//
//  TimerEngine.swift
//  TheJym
//
//  Drives the currently-running timer sequence (if any) app-wide — a single
//  shared instance (not tied to any one view) so a run started from the
//  Timer section keeps going, and its alarms keep firing, no matter which
//  tab you switch to. Local notifications (not just live UI state) are what
//  actually guarantee an alarm is heard while backgrounded, on another
//  screen, or with the app fully quit — the in-app countdown is purely
//  derived from wall-clock end dates, so it re-syncs itself correctly the
//  moment the app's back in the foreground even after missing every tick
//  while away, rather than needing to have kept counting the whole time.
//

import Foundation
import Combine
import UserNotifications

/// One repeat of one timer, flattened into running order — a plain value
/// type (not a direct SwiftData model reference) so an active run survives
/// its source TimerPreset being edited or deleted mid-run.
struct TimerSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var presetName: String
    var seconds: Double
    var repIndex: Int      // 1-based
    var repCount: Int
    var presetIndex: Int   // 0-based, this timer's position among the template's timers
    var presetCount: Int
    /// A rest timer between work timers — plays a low continuous tone for
    /// its own duration, and its final 3-2-1 countdown beeps rise in pitch
    /// (1,2,3) instead of falling. See TimerAudioEngine.
    var isRest: Bool = false
}

private struct TimerRunState: Codable {
    var templateName: String
    var segments: [TimerSegment]
    var continuous: Bool
    var currentIndex: Int          // == segments.count once the whole run has finished
    var segmentEndDate: Date?      // nil = currentIndex hasn't started counting down yet
}

@MainActor
final class TimerEngine: NSObject, ObservableObject {
    static let shared = TimerEngine()

    @Published private(set) var templateName: String?
    @Published private(set) var segments: [TimerSegment] = []
    @Published private(set) var continuous = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var segmentEndDate: Date?
    /// Bumped every tick purely to force observers to re-read
    /// `remainingSeconds` — a computed property, so it isn't itself
    /// @Published and wouldn't otherwise trigger a per-second UI refresh.
    @Published private var tickToken = 0

    private var ticker: Timer?
    private let storageKey = "TimerEngine.runState"
    /// Which of {1,2,3} have already been beeped for the CURRENT segment —
    /// cleared every time the segment changes, so each only beeps once.
    private var beepedRemaining: Set<Int> = []
    /// Tracks whether the rest tone is actually playing, independent of
    /// AVAudioPlayerNode's own state, so `updateLoopTone` only calls
    /// start/stop on real transitions instead of restarting (and audibly
    /// stuttering) it every tick.
    private var loopIsPlaying = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        loadState()
        if isActive { catchUpAndStartTicking() }
    }

    var isActive: Bool { templateName != nil }
    var isFinished: Bool { isActive && currentIndex >= segments.count }
    var currentSegment: TimerSegment? {
        segments.indices.contains(currentIndex) ? segments[currentIndex] : nil
    }
    /// True once a non-continuous segment has finished and is waiting on
    /// `startNext()` — irrelevant in continuous mode, which never stops on
    /// its own until the whole run is finished.
    var isAwaitingManualStart: Bool {
        isActive && !isFinished && segmentEndDate == nil
    }
    var remainingSeconds: Double {
        guard let end = segmentEndDate else { return currentSegment?.seconds ?? 0 }
        return max(0, end.timeIntervalSinceNow)
    }
    /// Sum of every timer's own seconds × repeatCount, matching the header
    /// summary the Timer list shows for a template before it's even started.
    var totalSeconds: Double {
        segments.reduce(0) { $0 + $1.seconds }
    }

    /// Starts a fresh run from a template's own timers — replaces whatever
    /// run (if any) was already active. `presets` must already be in the
    /// order they should run.
    func start(templateName: String, presets: [(name: String, seconds: Double, repeatCount: Int, isRest: Bool)], continuous: Bool) {
        cancelPendingNotifications(count: segments.count)
        let flat = Self.flatten(presets)
        guard !flat.isEmpty else { return }
        self.templateName = templateName
        self.segments = flat
        self.continuous = continuous
        self.currentIndex = 0
        self.segmentEndDate = Date().addingTimeInterval(flat[0].seconds)
        beepedRemaining = []
        saveState()
        startTicking()
        updateLoopTone()

        if continuous {
            // No manual gates ahead, so every fire date is already knowable
            // — schedule the whole chain up front rather than one at a time,
            // so it all still fires correctly even if the app gets killed.
            scheduleChain(from: 0, startingAt: Date())
        } else {
            scheduleSingle(flat[0], index: 0, fireDate: segmentEndDate!)
        }
        Task { await requestAuthorizationIfNeeded() }
    }

    /// Non-continuous mode only — begins the next segment's countdown after
    /// the previous one finished and is awaiting a manual start.
    func startNext() {
        guard isAwaitingManualStart, let seg = currentSegment else { return }
        let end = Date().addingTimeInterval(seg.seconds)
        segmentEndDate = end
        beepedRemaining = []
        saveState()
        updateLoopTone()
        scheduleSingle(seg, index: currentIndex, fireDate: end)
    }

    /// Cancels the run outright, clearing all state and any pending alarms.
    func stop() {
        cancelPendingNotifications(count: segments.count)
        templateName = nil
        segments = []
        currentIndex = 0
        segmentEndDate = nil
        stopTicking()
        updateLoopTone()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: Ticking / self-healing catch-up

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func catchUpAndStartTicking() {
        tick()
        if isActive, !isFinished { startTicking() }
    }

    /// Advances currentIndex/segmentEndDate to match wall-clock time —
    /// correct whether called every second (normal ticking) or once after a
    /// long gap (relaunch, time spent backgrounded). Continuous mode can
    /// walk through several already-completed segments at once; non-
    /// continuous only ever advances past the ONE currently-active segment,
    /// then waits for startNext(). Always ends by checking the countdown
    /// beeps and the rest-tone loop against wherever it landed.
    private func tick() {
        tickToken += 1
        handleCountdownBeeps()

        if let end = segmentEndDate, Date() >= end {
            if continuous {
                var cursor = end
                var idx = currentIndex
                while Date() >= cursor {
                    idx += 1
                    guard segments.indices.contains(idx) else {
                        currentIndex = segments.count
                        segmentEndDate = nil
                        saveState()
                        stopTicking()
                        updateLoopTone()
                        return
                    }
                    cursor = cursor.addingTimeInterval(segments[idx].seconds)
                }
                currentIndex = idx
                segmentEndDate = cursor
            } else {
                currentIndex += 1
                segmentEndDate = nil
                if currentIndex >= segments.count { stopTicking() }
            }
            beepedRemaining = []
            saveState()
        }
        updateLoopTone()
    }

    // MARK: Tones — rest-timer loop and the 3-2-1 / 1-2-3 countdown beeps

    /// Fires once each for the 3rd, 2nd, and 1st second remaining in the
    /// current segment — descending pitch (3,2,1) for a work timer, rising
    /// pitch (1,2,3) for a rest timer, so the two feel distinctly different
    /// even without looking at the screen.
    private func handleCountdownBeeps() {
        guard let seg = currentSegment, let end = segmentEndDate else { return }
        let remaining = Int(end.timeIntervalSinceNow.rounded())
        guard (1...3).contains(remaining), !beepedRemaining.contains(remaining) else { return }
        beepedRemaining.insert(remaining)
        let frequency: Double
        if seg.isRest {
            frequency = remaining == 3 ? 440 : remaining == 2 ? 660 : 880
        } else {
            frequency = remaining == 3 ? 880 : remaining == 2 ? 660 : 440
        }
        TimerAudioEngine.shared.playBeep(frequency: frequency)
    }

    /// Starts/stops the continuous low tone to match whether the segment
    /// actually counting down right now is a rest timer — a no-op if it's
    /// already in the right state, so this can be called on every tick
    /// without restarting (and stuttering) an already-playing loop.
    private func updateLoopTone() {
        let shouldPlay = isActive && !isFinished && currentSegment?.isRest == true && segmentEndDate != nil
        guard shouldPlay != loopIsPlaying else { return }
        loopIsPlaying = shouldPlay
        if shouldPlay {
            TimerAudioEngine.shared.startLoop()
        } else {
            TimerAudioEngine.shared.stopLoop()
        }
    }

    // MARK: Flattening

    private static func flatten(_ presets: [(name: String, seconds: Double, repeatCount: Int, isRest: Bool)]) -> [TimerSegment] {
        var out: [TimerSegment] = []
        for (i, preset) in presets.enumerated() {
            let reps = max(1, preset.repeatCount)
            for rep in 1...reps {
                out.append(TimerSegment(presetName: preset.name, seconds: preset.seconds,
                                        repIndex: rep, repCount: reps,
                                        presetIndex: i, presetCount: presets.count,
                                        isRest: preset.isRest))
            }
        }
        return out
    }

    // MARK: Persistence (survives app relaunch, not just backgrounding)

    private func saveState() {
        guard isActive else { return }
        let state = TimerRunState(templateName: templateName ?? "", segments: segments,
                                  continuous: continuous, currentIndex: currentIndex,
                                  segmentEndDate: segmentEndDate)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func loadState() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(TimerRunState.self, from: data) else { return }
        templateName = state.templateName
        segments = state.segments
        continuous = state.continuous
        currentIndex = state.currentIndex
        segmentEndDate = state.segmentEndDate
    }

    // MARK: Notifications — the actual "heard even off-screen" alarm

    /// Sound-only — no `.alert`, so a timer's completion is heard (a chime)
    /// without ever popping up a visible banner, on the lock screen or
    /// anywhere else.
    private func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.sound])
    }

    private func cancelPendingNotifications(count: Int) {
        guard count > 0 else { return }
        let ids = (0..<count).map { "timerSegment-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func scheduleChain(from startIndex: Int, startingAt startDate: Date) {
        var cursor = startDate
        for i in startIndex..<segments.count {
            cursor = cursor.addingTimeInterval(segments[i].seconds)
            scheduleSingle(segments[i], index: i, fireDate: cursor)
        }
    }

    /// No title/body shown anywhere (see requestAuthorizationIfNeeded's
    /// sound-only scope and the delegate below) — just a chime, standing in
    /// for the popup banner this used to show.
    private func scheduleSingle(_ segment: TimerSegment, index: Int, fireDate: Date) {
        let interval = max(0.1, fireDate.timeIntervalSinceNow)
        let content = UNMutableNotificationContent()
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "chime.caf"))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "timerSegment-\(index)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

extension TimerEngine: UNUserNotificationCenterDelegate {
    /// Sound only, no banner — a timer's alarm is a chime, not a popup, even
    /// while the app itself is in the foreground (where a notification's
    /// presentation would otherwise be silently suppressed entirely without
    /// this delegate opting back in).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.sound]
    }
}
