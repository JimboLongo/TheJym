//
//  RestTimeDefault.swift
//  TheJym
//
//  What rest time to offer when adding an exercise to a day.
//
//  The cascade's first step — "the last rest time used for this exercise" —
//  is NOT a guess. Measured across this store's 80 planned slots: 54 carry
//  a rest time, they use only four distinct values (90s ×30, 60s ×12,
//  75s ×8, 180s ×4), and **no exercise uses more than one of them**. Rest
//  time is stored per-slot but is in practice a property of the exercise,
//  so reading a sibling slot's value reproduces what would have been typed
//  rather than approximating it.
//
//  That is also why the field stays on PlannedExercise rather than moving
//  to ExerciseDef: the per-slot flexibility is worth keeping and a
//  migration isn't worth it. If this cascade ever starts fighting the data
//  model — an exercise legitimately wanting two different rest times — the
//  measurement above is the assumption that stopped holding.
//

import Foundation
import SwiftData

enum RestTimeDefault {
    /// Last resort. Already RestTimePickerSheet's own default, and the
    /// modal value in the real data (30 of 54 slots).
    static let fallbackSeconds = 90

    /// Offered when adding `exerciseName` to a day.
    ///
    /// 1. The most recent slot for this same exercise, anywhere — see the
    ///    file note on why that reproduces rather than guesses.
    /// 2. The last value entered during this run of adds, which carries a
    ///    deliberate choice across a string of brand-new exercises.
    /// 3. 90s.
    static func suggested(for exerciseName: String,
                          in planned: [PlannedExercise],
                          sessionLast: Int? = nil) -> Int {
        if let prior = mostRecentSlot(for: exerciseName, in: planned)?.restTimeSeconds {
            return prior
        }
        return sessionLast ?? fallbackSeconds
    }

    /// Most recent by the owning phase's start date, then by slot order.
    ///
    /// With no exercise currently using two values the ordering changes
    /// nothing, so it exists to make the answer DETERMINISTIC rather than
    /// whatever the fetch happened to return first — the day one exercise
    /// does carry two, this picks the newer on purpose instead of by luck.
    private static func mostRecentSlot(for exerciseName: String,
                                       in planned: [PlannedExercise]) -> PlannedExercise? {
        planned
            .filter { $0.exerciseName == exerciseName && $0.restTimeSeconds != nil }
            .max { a, b in
                let aDate = a.day?.phase?.startDate ?? .distantPast
                let bDate = b.day?.phase?.startDate ?? .distantPast
                if aDate != bDate { return aDate < bDate }
                return a.order < b.order
            }
    }
}
