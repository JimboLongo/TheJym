//
//  WorkoutActivityController.swift
//  TheJym
//
//  Drives the Dynamic Island / Lock Screen Live Activity that mirrors
//  RestStopwatch — a single shared instance since there's only ever one
//  active rest countdown at a time, matching RestStopwatch's own
//  one-instance-per-active-workout scope (hoisted to WorkoutLogView).
//  Deliberately kept separate from RestStopwatch itself (which knows
//  nothing about ActivityKit) — WorkoutLogView calls `sync` after every
//  resetAndStart (a logged set) and retarget (a swipe to a different
//  exercise), and `end` whenever there's nothing left to track: the workout
//  finishes, is discarded, or the workout screen goes away entirely (see
//  RestStopwatch's own doc on why it's never persisted, unlike
//  WorkoutStopwatch — there's no saved state to adopt an existing Activity
//  against on relaunch, so WorkoutLogView ends any leftover one on appear
//  instead).
//

import ActivityKit
import Foundation

@MainActor
final class RestActivityController {
    static let shared = RestActivityController()
    private init() {}

    private var activity: Activity<RestActivityAttributes>?

    /// Starts a new Activity if none exists yet, or updates the existing
    /// one to match `state` — safe to call after every resetAndStart/
    /// retarget, a no-op beyond the one Activity update each needs.
    func sync(_ state: (targetSeconds: Int?, accumulatedSeconds: TimeInterval, startDate: Date?, isRunning: Bool)) {
        let contentState = RestActivityAttributes.ContentState(
            targetSeconds: state.targetSeconds,
            startDate: state.startDate,
            accumulatedSeconds: state.accumulatedSeconds,
            isRunning: state.isRunning)
        let content = ActivityContent(state: contentState, staleDate: nil)

        if let activity {
            Task { await activity.update(content) }
            return
        }

        do {
            activity = try Activity.request(attributes: RestActivityAttributes(), content: content, pushType: nil)
        } catch {
            // Live Activities can be disabled in Settings, or unavailable
            // for other reasons — the rest timer itself doesn't depend on
            // this succeeding, so just don't show one.
            activity = nil
        }
    }

    /// Ends the Live Activity immediately — the workout finished, was
    /// discarded, or the workout screen went away, so there's nothing left
    /// worth showing (and, unlike WorkoutStopwatch, nothing saved to
    /// resume it against later).
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
