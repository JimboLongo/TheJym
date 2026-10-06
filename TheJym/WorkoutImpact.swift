//
//  WorkoutImpact.swift
//  TheJym
//
//  Carries "what did the workout I just saved actually change" from
//  finishWorkout() to the Stats tab it lands on, so the day counts that
//  moved can be badged.
//

import Foundation
import SwiftUI

/// The day-count deltas of the workout just finished, held only long
/// enough for the Stats tab to show them once.
///
/// IN-MEMORY ONLY, and that's load-bearing. Nothing here touches
/// UserDefaults, @AppStorage or SwiftData, so a cold launch always starts
/// with `pending == nil` — Tuesday can never badge Monday's workout.
/// That's structural rather than a rule someone has to remember to
/// enforce.
///
/// KNOWN PROPERTY, not a bug: a suspend is not a launch. Background the
/// app mid-transition and resume it an hour later and the badge still
/// appears on that delayed arrival. Accepted — it still describes the
/// right workout and the right numbers; the process never died, so
/// nothing about it went stale.
///
/// Deliberately NOT a general "stats changed" channel. It carries two
/// day counts, both of which finishWorkout can determine from two cheap
/// filters over sessions it already holds. Streaks and rolling windows
/// are excluded on purpose: whether the Daily Streak advanced depends on
/// yesterday and the Program Streak on the rest bank, neither derivable
/// without real computation, and a wrong badge is worse than no badge.
@MainActor
@Observable
final class WorkoutImpact {
    static let shared = WorkoutImpact()
    private init() {}

    /// Set once by finishWorkout, read and cleared by StatsView. nil
    /// whenever there's nothing to show — including when a workout
    /// genuinely moved neither count.
    private(set) var pending: Deltas?

    struct Deltas: Equatable {
        let active: Int
        let lift: Int
        /// Only ever 0 or 1 each, so "did anything move" is just this.
        var isEmpty: Bool { active == 0 && lift == 0 }
    }

    func record(_ deltas: Deltas) {
        pending = deltas.isEmpty ? nil : deltas
    }

    func clear() { pending = nil }

    /// What finishing a workout on `day` adds to the Active and Lift day
    /// counts, given the sessions that existed BEFORE it was saved.
    ///
    /// Both are day counts, so the answer is 0 or 1 — a second lift on a
    /// day that already had one adds no new DAY. The two predicates are
    /// the engine's own, not new ones:
    ///
    ///   lift   — WorkoutSession.hasLiftingLog, what the Consistency
    ///            table's Lift column runs on
    ///   active — `!exerciseLogs.isEmpty`, which is exactly
    ///            StatsView.realSessionDates and therefore activeDays
    ///
    /// `day` is the workout's logged date, which can be backdated. The
    /// counts are windowed to [trainingStartDate, today], so a backdate
    /// still moves them — the one case where the badge describes a change
    /// you can't see on screen is a workout dated BEFORE the training
    /// start date. Accepted rather than guarded; it's a rare enough hand
    /// edit that a window check would cost more than it's worth.
    static func deltas(forFinishingOn day: Date,
                       existingSessions: [WorkoutSession],
                       newSessionIsLift: Bool,
                       cal: Calendar = .current) -> Deltas {
        // Nothing was logged, so no session-with-logs is being created and
        // neither count can move.
        guard newSessionIsLift else { return Deltas(active: 0, lift: 0) }

        let onDay = existingSessions.filter { cal.isDate($0.date, inSameDayAs: day) }
        let hadLiftAlready = onDay.contains { $0.hasLiftingLog }
        let wasActiveAlready = onDay.contains { !$0.exerciseLogs.isEmpty }

        return Deltas(active: wasActiveAlready ? 0 : 1,
                      lift: hadLiftAlready ? 0 : 1)
    }
}
