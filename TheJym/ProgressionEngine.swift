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
    /// `history` = this exercise's logs, same plan key, oldest -> newest
    /// (any phase — progression looks at your whole training history, not
    /// just the current block). The most recent entry is "today's" workout.
    /// `roundingIncrement` is the finest weight jump achievable with the
    /// equipment on hand (e.g. 1.25/2.5 lb with a dumbbell attachment).
    /// `isBodyweight`: when true, progression is computed on ADDED weight
    /// (SetLog.addedWeight) instead of the resolved effective weight, since
    /// bodyweight itself can drift independently of training progress —
    /// suggestions should only ever move the added load, never bodyweight.
    /// Every other caller (the vast majority — non-bodyweight exercises)
    /// leaves this at its default and sees byte-identical behavior.
    /// `customIncreaseStreak`/`customIncreaseAmount`: when both are
    /// provided (Settings' custom auto weight-increase rule, enabled),
    /// they completely replace the aggressiveness preset's own jump logic
    /// below — a flat "streak >= N -> +X lb" rule instead of the
    /// surplus-scaled small/big/huge jumps. Leave both nil (the default)
    /// to keep using the aggressiveness preset.
    static func suggestNextWeights(targetReps: [Int],
                                   history: [ExerciseLog],
                                   aggressiveness: AIAggressiveness,
                                   roundingIncrement: Double = 2.5,
                                   isBodyweight: Bool = false,
                                   customIncreaseStreak: Int? = nil,
                                   customIncreaseAmount: Double? = nil) -> [Double]? {
        guard let latest = history.last, !latest.sets.isEmpty else { return nil }
        let latestWeights = isBodyweight
            ? latest.sortedSets.map { $0.addedWeight ?? 0 }
            : latest.sortedSets.map(\.weight)
        let streak = currentStreak(targetReps: targetReps, history: history)

        let smallJump: Double = 2.5
        let bigJump: Double = 5
        let hugeJump: Double = 10

        var increment: Double = 0
        if let customStreak = customIncreaseStreak, let customAmount = customIncreaseAmount {
            if streak >= customStreak { increment = customAmount }
        } else {
            switch aggressiveness {
            case .conservative:
                if streak >= 3 { increment = avgSurplus(latest, targetReps: targetReps) >= 2 ? bigJump : smallJump }
            case .moderate:
                if streak >= 2 { increment = avgSurplus(latest, targetReps: targetReps) >= 2 ? bigJump : smallJump }
                else if streak >= 1 && avgSurplus(latest, targetReps: targetReps) >= 3 { increment = smallJump }
            case .aggressive:
                if metAll(latest, targetReps: targetReps) {
                    increment = avgSurplus(latest, targetReps: targetReps) >= 2 ? hugeJump : bigJump
                }
            }
        }

        // If they badly missed targets (avg 2+ reps short), suggest backing off ~5%.
        if avgSurplus(latest, targetReps: targetReps) <= -2 {
            return latestWeights.map { roundToPlate($0 * 0.95, smallest: roundingIncrement) }
        }

        guard increment > 0 else { return latestWeights }   // hold the weight
        return latestWeights.map { roundToPlate($0 + increment, smallest: roundingIncrement) }
    }

    // MARK: - Shared performance checks (used by suggestNextWeights + recap)

    /// Did a given session EXCEED every target rep? (strictly more on at
    /// least one set, and >= target on all sets)
    private static func exceeded(_ log: ExerciseLog, targetReps: [Int]) -> Bool {
        let sets = log.sortedSets
        guard sets.count == targetReps.count else { return metAll(log, targetReps: targetReps) }
        var strict = false
        for (i, s) in sets.enumerated() {
            if s.reps < targetReps[i] { return false }
            if s.reps > targetReps[i] { strict = true }
        }
        return strict
    }

    private static func metAll(_ log: ExerciseLog, targetReps: [Int]) -> Bool {
        let sets = log.sortedSets
        guard !sets.isEmpty else { return false }
        for (i, s) in sets.enumerated() {
            let t = i < targetReps.count ? targetReps[i] : targetReps.last ?? 0
            if s.reps < t { return false }
        }
        return true
    }

    /// Average surplus reps per set in a session (negative = fell short).
    private static func avgSurplus(_ log: ExerciseLog, targetReps: [Int]) -> Double {
        let sets = log.sortedSets
        guard !sets.isEmpty else { return 0 }
        var total = 0
        for (i, s) in sets.enumerated() {
            let t = i < targetReps.count ? targetReps[i] : targetReps.last ?? 0
            total += (s.reps - t)
        }
        return Double(total) / Double(sets.count)
    }

    /// Consecutive most-recent sessions (at the same weights as the latest)
    /// that exceeded every target rep — exposed for progress display (e.g.
    /// the end-of-workout recap's "2/3 sessions to a weight jump"), separate
    /// from the jump decision itself which still comes from suggestNextWeights.
    static func currentStreak(targetReps: [Int], history: [ExerciseLog]) -> Int {
        guard let latest = history.last, !latest.sets.isEmpty else { return 0 }
        let latestWeights = latest.sortedSets.map(\.weight)
        var streak = 0
        for log in history.reversed() {
            guard log.sortedSets.map(\.weight) == latestWeights else { break }
            if exceeded(log, targetReps: targetReps) { streak += 1 } else { break }
        }
        return streak
    }

    /// How many consecutive exceeded sessions are needed to trigger a weight
    /// jump at this aggressiveness — mirrors the thresholds in
    /// suggestNextWeights, for progress display purposes.
    static func requiredStreak(for aggressiveness: AIAggressiveness) -> Int {
        switch aggressiveness {
        case .conservative: return 3
        case .moderate: return 2
        case .aggressive: return 1
        }
    }

    // MARK: - repTotal progression

    struct RepTotalSuggestion {
        /// Set only when progressing the rep total itself (repTotalProgressesReps).
        var newTarget: Int?
        /// Set only when progressing added weight (the default).
        var newAddedWeight: Double?
    }

    /// For a repTotal exercise: if the latest session actually reached its
    /// target in <= "suggestedSets" sets, it's efficient enough to progress.
    /// Reuses requiredStreak's conservative/moderate/aggressive thresholds
    /// (3/2/1) here as "sets it took" rather than "consecutive cycles" —
    /// aggressive demands finishing in a single set to earn a bump,
    /// conservative allows up to 3. Bumps either added weight (+2.5-5 lb,
    /// bigger jump if finished in just 1 set) or the rep total (+5),
    /// depending on the exercise's own toggle (default: weight).
    static func suggestRepTotalProgression(history: [ExerciseLog],
                                           aggressiveness: AIAggressiveness,
                                           progressesReps: Bool,
                                           roundingIncrement: Double = 2.5) -> RepTotalSuggestion? {
        guard let latest = history.last, latest.repTotalReached else { return nil }
        let setsTaken = latest.sortedSets.count
        guard setsTaken <= requiredStreak(for: aggressiveness) else { return nil }

        if progressesReps {
            guard case .repTotal(let target) = latest.goalType else { return nil }
            return RepTotalSuggestion(newTarget: target + 5, newAddedWeight: nil)
        }
        let latestWeight = latest.isBodyweight
            ? (latest.sortedSets.last?.addedWeight ?? 0)
            : (latest.sortedSets.last?.weight ?? 0)
        let bump: Double = setsTaken <= 1 ? 5 : 2.5
        let newWeight = roundToPlate(latestWeight + bump, smallest: roundingIncrement)
        return RepTotalSuggestion(newTarget: nil, newAddedWeight: newWeight)
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

    // MARK: - Starting weights (single source of truth for "what would this
    // exercise actually start at right now" — shared by WorkoutLogView's
    // draft setup and the Train tab's preview, so the preview never shows a
    // different weight than opening the workout does)

    /// The weights a fixedSets exercise would start at if logged right now:
    /// the AI's next-cycle suggestion when the AI Assistant is on (falling
    /// back to the plan's own `suggestedWeights` if it has no opinion yet —
    /// e.g. no history), or last time's actual weights when it's off (same
    /// fallback) — then halved for a deload cycle.
    static func startingWeights(for pe: PlannedExercise,
                                history: [ExerciseLog],
                                aiOn: Bool,
                                aggressiveness: AIAggressiveness,
                                roundingIncrement: Double,
                                customIncreaseStreak: Int? = nil,
                                customIncreaseAmount: Double? = nil,
                                isDeloadCycle: Bool = false) -> [Double] {
        var weights = aiOn
            ? (suggestNextWeights(targetReps: pe.targetReps, history: history,
                                  aggressiveness: aggressiveness, roundingIncrement: roundingIncrement,
                                  isBodyweight: pe.isBodyweight,
                                  customIncreaseStreak: customIncreaseStreak,
                                  customIncreaseAmount: customIncreaseAmount)
               ?? pe.suggestedWeights)
            : (history.last?.sortedSets.map { pe.isBodyweight ? ($0.addedWeight ?? 0) : $0.weight }
               ?? pe.suggestedWeights)
        if isDeloadCycle, !weights.isEmpty {
            weights = deloadWeights(from: weights)
        }
        return weights
    }

    /// Same idea as `startingWeights`, for a repTotal exercise — a single
    /// starting weight plus whatever rep total it'd actually start at (the
    /// AI may bump the target itself instead of the weight).
    static func startingRepTotal(for pe: PlannedExercise,
                                 history: [ExerciseLog],
                                 aiOn: Bool,
                                 aggressiveness: AIAggressiveness,
                                 roundingIncrement: Double,
                                 isDeloadCycle: Bool = false) -> (weight: Double, target: Int) {
        var effectiveTarget = pe.repTotalTarget
        var startWeight = pe.suggestedWeights.first ?? 0
        if aiOn, let suggestion = suggestRepTotalProgression(history: history, aggressiveness: aggressiveness,
                                                              progressesReps: pe.repTotalProgressesReps,
                                                              roundingIncrement: roundingIncrement) {
            if let newTarget = suggestion.newTarget { effectiveTarget = newTarget }
            if let newWeight = suggestion.newAddedWeight { startWeight = newWeight }
        } else if !aiOn, let lastSet = history.last?.sortedSets.last {
            startWeight = pe.isBodyweight ? (lastSet.addedWeight ?? 0) : lastSet.weight
        }
        if isDeloadCycle, startWeight > 0 {
            startWeight = deloadWeights(from: [startWeight]).first ?? startWeight
        }
        return (startWeight, effectiveTarget)
    }

    // MARK: - Rules-based phase planning (Gemini fallback)

    struct PlannedSlot {
        var exerciseName: String
        var targetReps: [Int]      // fixedSets only — empty for repTotal
        var startingWeights: [Double]
        var rationale: String
        var goalType: GoalType = .fixedSets

        /// How this slot's target reads wherever a plain rep scheme would
        /// otherwise show (e.g. "8/8/8") — "N Total" for repTotal instead.
        var setsSummaryText: String {
            switch goalType {
            case .fixedSets:
                return targetReps.map(String.init).joined(separator: "/")
            case .repTotal(let target):
                return "\(target) Total"
            }
        }
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
                                             rationale: "Carried over (no logs last phase).",
                                             goalType: planned.goalType))
                    continue
                }

                let firstAvg = avgWeight(first), lastAvg = avgWeight(last)
                let progressed = lastAvg > firstAvg + 0.01
                let lastWeights = last.sortedSets.map(\.weight)

                if progressed {
                    slots.append(PlannedSlot(exerciseName: planned.exerciseName,
                                             targetReps: planned.targetReps,
                                             startingWeights: lastWeights,
                                             rationale: "Progressing well (+\(Formatters.trim(lastAvg - firstAvg)) lb avg) — keep riding it.",
                                             goalType: planned.goalType))
                } else {
                    switch planned.goalType {
                    case .fixedSets:
                        let newReps = flippedScheme(planned.targetReps)
                        let factor = schemeIsLighter(newReps, than: planned.targetReps) ? 0.85 : 1.05
                        let newWeights = lastWeights.map { roundToPlate($0 * factor) }
                        slots.append(PlannedSlot(exerciseName: planned.exerciseName,
                                                 targetReps: newReps,
                                                 startingWeights: newWeights,
                                                 rationale: "Stalled last phase — changing rep scheme to vary the stimulus.",
                                                 goalType: .fixedSets))
                    case .repTotal(let target):
                        // No rep scheme to flip — back off the weight
                        // slightly instead to vary the stimulus while
                        // keeping the same rep-total target.
                        let newWeights = lastWeights.map { roundToPlate($0 * 0.925) }
                        slots.append(PlannedSlot(exerciseName: planned.exerciseName,
                                                 targetReps: [],
                                                 startingWeights: newWeights,
                                                 rationale: "Stalled last phase — backing off slightly to build back up.",
                                                 goalType: .repTotal(target: target)))
                    }
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
