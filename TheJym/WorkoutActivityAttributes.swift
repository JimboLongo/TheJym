//
//  WorkoutActivityAttributes.swift
//  TheJym
//
//  Shared with the TheJymWidget extension target (see its own Sources build
//  phase, which references this exact file) so both sides agree on the Live
//  Activity's content shape without duplicating it. Deliberately depends on
//  nothing else in the app — the widget extension doesn't need to pull in
//  SwiftData, RestStopwatch, or anything else just to render the Dynamic
//  Island.
//
//  Mirrors RestStopwatch's own wall-clock-anchored model (accumulated + a
//  running startDate, plus its target) rather than a plain remaining-seconds
//  snapshot, so the Dynamic Island's timer text can tick natively via
//  SwiftUI's Text(timerInterval:) — no per-second updates need to be pushed
//  from the app while a rest period is actually counting down, only on each
//  resetAndStart/retarget (see RestActivityController).
//

import ActivityKit
import Foundation

struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// nil = counting up from 0 with no target (the current exercise
        /// has no rest time set); non-nil = counting down from this many
        /// seconds — matching RestStopwatch.targetSeconds.
        var targetSeconds: Int?
        /// When the CURRENT run started counting from `accumulatedSeconds`
        /// — nil while paused, matching RestStopwatch's own startDate.
        var startDate: Date?
        /// Time banked from any previous run(s) since the last reset/
        /// retarget — matching RestStopwatch's own accumulated.
        var accumulatedSeconds: Double
        var isRunning: Bool
    }
}
