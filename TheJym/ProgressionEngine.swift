//
//  ProgressionEngine.swift
//  TheJym
//
//  The "AI Assistant" brain. Deterministic, on-device, free.
//  - Suggests next-cycle weights per exercise based on logged performance
//    and the aggressiveness setting.
//  - Computes deload placement and deload weights.
//  - Rules-based Phase planner (used as-is, or as fallback when Gemini is off).
//

import Foundation

enum ProgressionEngine {

    // MARK: - Next-cycle weight suggestion

    /// Suggest per-set weights for the NEXT cycle of an exercise.
    ///
    /// `history` = this exercise's logs *within the current phase, same plan key*,
    /// oldest -> newest. The most recent entry is "today's" workout.
    static func suggestNextWeights(targetReps: [Int],
                                   history: [ExerciseLog],
                                   isLowerBody: Bool,
                                   aggressiveness: AIAggressiveness) -> [Double]? {
        guard let latest = history.last, !latest.sets.isEmpty else { return nil }
        let latestWeights = latest.sortedSets.map(\.weight)

        // Did a given session EXCEED every target rep? (strictly more on at least
        // one set, and >= target on all sets)
        func exceeded(_ log: ExerciseLog) -> Bool {
            let sets = log.sortedSets
            guard sets.count == targetReps.count else { return metAll(log) }
            var strict = false
            for (i, s) in sets.enumerated() {
                if s.reps < targetReps[i] { return false }
                if s.reps > targetReps[i] { strict = true }
            }
            return strict
        }
        func metAll(_ log: ExerciseLog) -> Bool {
            let sets = log.sortedSets
            guard !sets.isEmpty else { return false }
            for (i, s) in sets.enumerated() {
                let t = i < targetReps.count ? targetReps[i] : targetReps.last ?? 0
                if s.reps < t { return false }
            }
            return true
        }
        /// Average surplus reps per set in the latest session.
        func avgSurplus(_ log: ExerciseLog) -> Double {
            let sets = log.sortedSets
            guard !sets.isEmpty else { return 0 }
            var total = 0
            for (i, s) in sets.enumerated() {
                let t = i < targetReps.count ? targetReps[i] : targetReps.last ?? 0
                total += (s.reps - t)
            }
            return Double(total) / Double(sets.count)
        }

        // Consecutive-exceed streak counting back from the latest session,
        // only counting sessions at the SAME weights as the latest (so a bump
        // resets the clock).
        var streak = 0
        for log in history.reversed() {
            guard log.sortedSets.map(\.weight) == latestWeights else { break }
            if exceeded(log) { streak += 1 } else { break }
        }

        let smallJump: Double = isLowerBody ? 5 : 2.5
        let bigJump: Double = isLowerBody ? 10 : 5
        let hugeJump: Double = isLowerBody ? 15 : 10

        var increment: Double = 0
        switch aggressiveness {
        case .conservative:
            if streak >= 3 { increment = avgSurplus(latest) >= 2 ? bigJump : smallJump }
        case .moderate:
            if streak >= 2 { increment = avgSurplus(latest) >= 2 ? bigJump : smallJump }
            else if streak >= 1 && avgSurplus(latest) >= 3 { increment = smallJump }
        case .aggressive:
            if metAll(latest) {
                increment = avgSurplus(latest) >= 2 ? hugeJump : bigJump
            }
        }

        // If they badly missed targets (avg 2+ reps short), suggest backing off ~5%.
        if avgSurplus(latest) <= -2 {
            return latestWeights.map { roundToPlate($0 * 0.95) }
        }

        guard increment > 0 else { return latestWeights }   // hold the weight
        return latestWeights.map { roundToPlate($0 + increment) }
    }

    static func roundToPlate(_ w: Double, smallest: Double = 2.5) -> Double {
        (w / smallest).rounded() * smallest
    }

    // MARK: - Deload

    /// Where to put the deload cycle for a phase of `totalCycles`.
    /// Rationale: accumulated fatigue peaks late in a training block; a planned
    /// deload in the final cycle dissipates fatigue so you enter the next phase
    /// recovered and can express the fitness you built (fitness–fatigue model).
    /// For long phases (10+), a mid-block deload also helps.
    static func deloadCycle(totalCycles: Int) -> Int {
        guard totalCycles >= 4 else { return 0 }   // too short to need one
        return totalCycles                          // last cycle of the phase
    }

    /// Deload weights: ~60% of the most recent working weights, half the sets' reps kept easy.
    static func deloadWeights(from lastWeights: [Double]) -> [Double] {
        lastWeights.map { roundToPlate($0 * 0.6) }
    }

    // MARK: - Rules-based phase planning (Gemini fallback)

    struct PlannedSlot {
        var exerciseName: String
        var targetReps: [Int]
        var startingWeights: [Double]
        var isLowerBody: Bool
        var rationale: String
    }

    /// Build a Phase-N+1 plan from Phase-N results:
    /// - Exercises that progressed well (weights went up across the phase) are kept.
    /// - Stalled exercises get a rep-scheme change (e.g. 5/5/5/3/3/3 -> 8/8/8/6/6/6 at ~85% load,
    ///   or vice versa) to vary the stimulus.
    /// - Starting weights = last working weights (or 92.5% of them for stalled lifts).
    static func planNextPhase(previousPhase: Phase) -> [String: [PlannedSlot]] {
        var result: [String: [PlannedSlot]] = [:]

        for day in previousPhase.trainingDays {
            var slots: [PlannedSlot] = []
            for planned in previousPhase.plan(for: day) {
                let logs = previousPhase.sessions
                    .flatMap { $0.exerciseLogs }
                    .filter { $0.planKey == planned.planKey && !$0.sets.isEmpty }
                    .sorted { ($0.session?.date ?? .distantPast) < ($1.session?.date ?? .distantPast) }

                guard let first = logs.first, let last = logs.last else {
                    // Never logged; carry it forward unchanged.
                    slots.append(PlannedSlot(exerciseName: planned.exerciseName,
                                             targetReps: planned.targetReps,
                                             startingWeights: planned.suggestedWeights,
                                             isLowerBody: planned.isLowerBody,
                                             rationale: "Carried over (no logs last phase)."))
                    continue
                }

                let firstAvg = avgWeight(first), lastAvg = avgWeight(last)
                let progressed = lastAvg > firstAvg + 0.01
                let lastWeights = last.sortedSets.map(\.weight)

                if progressed {
                    slots.append(PlannedSlot(exerciseName: planned.exerciseName,
                                             targetReps: planned.targetReps,
                                             startingWeights: lastWeights,
                                             isLowerBody: planned.isLowerBody,
                                             rationale: "Progressing well (+\(Formatters.trim(lastAvg - firstAvg)) lb avg) — keep riding it."))
                } else {
                    let newReps = flippedScheme(planned.targetReps)
                    let factor = schemeIsLighter(newReps, than: planned.targetReps) ? 0.85 : 1.05
                    let newWeights = lastWeights.map { roundToPlate($0 * factor) }
                    slots.append(PlannedSlot(exerciseName: planned.exerciseName,
                                             targetReps: newReps,
                                             startingWeights: newWeights,
                                             isLowerBody: planned.isLowerBody,
                                             rationale: "Stalled last phase — changing rep scheme to vary the stimulus."))
                }
            }
            result[day.name] = slots
        }
        return result
    }

    private static func avgWeight(_ log: ExerciseLog) -> Double {
        let sets = log.sortedSets
        guard !sets.isEmpty else { return 0 }
        return sets.map(\.weight).reduce(0, +) / Double(sets.count)
    }

    /// Heavy scheme -> moderate hypertrophy scheme, and vice versa.
    private static func flippedScheme(_ reps: [Int]) -> [Int] {
        let avg = reps.isEmpty ? 8 : reps.reduce(0, +) / reps.count
        if avg <= 6 { return reps.map { min($0 + 3, 12) } }   // 5/5/5/3/3/3 -> 8/8/8/6/6/6
        return reps.map { max($0 - 3, 3) }                    // 10s -> heavier 7s
    }

    private static func schemeIsLighter(_ a: [Int], than b: [Int]) -> Bool {
        (a.reduce(0, +)) > (b.reduce(0, +))   // more reps => lighter load
    }
}
