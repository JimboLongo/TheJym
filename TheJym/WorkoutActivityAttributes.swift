//
//  WorkoutActivityAttributes.swift
//  TheJym
//
//  Shared with the TheJymWidget extension target (see its own Sources build
//  phase, which references this exact file) so both sides agree on the Live
//  Activity's content shape without duplicating it. Deliberately depends on
//  nothing else in the app — the widget extension doesn't need to pull in
//  SwiftData, WorkoutStopwatch, or anything else just to render the Dynamic
//  Island.
//
//  Mirrors WorkoutStopwatch's own wall-clock-anchored model (accumulated +
//  a running startDate) rather than a plain elapsed-seconds snapshot, so the
//  Dynamic Island's timer text can tick natively via SwiftUI's
//  Text(timerInterval:) — no per-second updates need to be pushed from the
//  app while a workout is actually running, only on each Start/Pause/
//  Resume/Reset (see WorkoutActivityController).
//

import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the CURRENT run started counting from `accumulatedSeconds`
        /// — nil while paused, matching WorkoutStopwatch.startDate.
        var startDate: Date?
        /// Time banked from any previous run(s) since the last reset —
        /// matching WorkoutStopwatch.accumulated.
        var accumulatedSeconds: Double
        var isRunning: Bool
    }
}
