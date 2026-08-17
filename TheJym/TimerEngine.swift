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
    func start(templateName: String, presets: [(name: String, seconds: Double, repeatCount: Int)], continuous: Bool) {
        cancelPendingNotifications(count: segments.count)
        let flat = Self.flatten(presets)
        guard !flat.isEmpty else { return }
        self.templateName = templateName
        self.segments = flat
        self.continuous = continuous
        self.currentIndex = 0
        self.segmentEndDate = Date().addingTimeInterval(flat[0].seconds)
        saveState()
        startTicking()

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
        saveState()
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
    /// then waits for startNext().
    private func tick() {
        tickToken += 1
        guard let end = segmentEndDate, Date() >= end else { return }

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
        saveState()
    }

    // MARK: Flattening

    private static func flatten(_ presets: [(name: String, seconds: Double, repeatCount: Int)]) -> [TimerSegment] {
        var out: [TimerSegment] = []
        for (i, preset) in presets.enumerated() {
            let reps = max(1, preset.repeatCount)
            for rep in 1...reps {
                out.append(TimerSegment(presetName: preset.name, seconds: preset.seconds,
                                        repIndex: rep, repCount: reps,
                                        presetIndex: i, presetCount: presets.count))
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

    private func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
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

    private func scheduleSingle(_ segment: TimerSegment, index: Int, fireDate: Date) {
        let interval = max(0.1, fireDate.timeIntervalSinceNow)
        let content = UNMutableNotificationContent()
        let isLast = index == segments.count - 1
        let repSuffix = segment.repCount > 1 ? " — rep \(segment.repIndex)/\(segment.repCount)" : ""
        content.title = isLast ? "Timers Complete!" : "\(segment.presetName) Done"
        content.body = isLast
            ? "\(segment.presetName)\(repSuffix) — all timers finished."
            : "\(segment.presetName)\(repSuffix) done."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "timerSegment-\(index)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

extension TimerEngine: UNUserNotificationCenterDelegate {
    /// Without this, a notification's sound/banner is silently suppressed
    /// whenever the app itself is in the foreground — which is exactly when
    /// a timer alarm is most likely to fire (the user's mid-workout, app
    /// open on some other tab). Opts every notification into showing/
    /// sounding regardless of foreground/background state.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
