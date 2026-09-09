//
//  WorkoutActivityController.swift
//  TheJym
//
//  Drives the Dynamic Island / Lock Screen Live Activity that mirrors
//  WorkoutStopwatch — a single shared instance since there's only ever one
//  active workout at a time, matching WorkoutStopwatch's own one-instance-
//  per-active-workout scope (hoisted to WorkoutLogView). Deliberately kept
//  separate from WorkoutStopwatch itself (which knows nothing about
//  ActivityKit) — WorkoutLogView calls `sync` after every Start/Pause/
//  Resume/Reset/restore, and `end` when the workout finishes or is
//  discarded, the same explicit call-site wiring RestStopwatch's audio cues
//  and onSetLogged already use elsewhere in this app.
//

import ActivityKit
import Foundation

@MainActor
final class WorkoutActivityController {
    static let shared = WorkoutActivityController()
    private init() {}

    private var activity: Activity<WorkoutActivityAttributes>?

    /// Starts a new Activity if the workout just started and none exists
    /// yet, updates the existing one to match `snapshot`, or ends one
    /// that's still running if the workout hasn't (or no longer has)
    /// started. Safe to call after every Start/Pause/Resume/Reset/restore —
    /// a no-op beyond the one Activity update each of those needs.
    func sync(hasStarted: Bool, snapshot: WorkoutStopwatch.Snapshot) {
        guard hasStarted else {
            end()
            return
        }
        let state = WorkoutActivityAttributes.ContentState(
            startDate: snapshot.startDate,
            accumulatedSeconds: snapshot.accumulated,
            isRunning: snapshot.isRunning)
        let content = ActivityContent(state: state, staleDate: nil)

        if let activity {
            Task { await activity.update(content) }
            return
        }

        // A Live Activity survives the app being killed, so a relaunch
        // (WorkoutLogView restoring its saved draft) can find one already
        // running rather than starting a duplicate — adopt it instead.
        if let existing = Activity<WorkoutActivityAttributes>.activities.first {
            activity = existing
            Task { await existing.update(content) }
            return
        }

        do {
            activity = try Activity.request(attributes: WorkoutActivityAttributes(), content: content, pushType: nil)
        } catch {
            // Live Activities can be disabled in Settings, or unavailable
            // for other reasons — the workout itself doesn't depend on
            // this succeeding, so just don't show one.
            activity = nil
        }
    }

    /// Ends the Live Activity immediately — the workout is finished or
    /// discarded, so there's nothing left worth showing.
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
