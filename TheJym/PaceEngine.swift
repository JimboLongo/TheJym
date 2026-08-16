//
//  PaceEngine.swift
//  TheJym
//
//  Finds the three comparison workouts for an exercise and computes
//  "reps needed in the next set to stay on pace to beat" each one.
//

import Foundation

struct ComparisonTarget: Identifiable {
    enum Kind: String, CaseIterable {
        case lastLogged = "Previous Workout"
        case bestAtTheseWeights = "Best at Weights"
        case bestForExercise = "All-Time Best"
    }
    let id = UUID()
    let kind: Kind
    /// Nil when there's no prior log to compare against for this kind yet
    /// (e.g. the first time at this exact weight).
    let date: Date?
    let totalWeightMoved: Double
    /// Weight moved per set, in order (reps × weight for each) — powers the
    /// pro-rata pace milestone, which needs to know how the target's own
    /// total was distributed across its sets, not just the final number.
    let setWeightsMoved: [Double]
    /// The target's own per-set weight (not weight × reps) — the rate the
    /// even-pace calculation spreads the remaining deficit across.
    let weights: [Double]
    let reps: [Int]
    /// Per-set resolved weight label — paired with `reps` (same index) in a
    /// SetsGrid.
    let weightLabels: [String]
    /// How many times this kind's own criterion has occurred in history —
    /// for `.lastLogged`, sessions in a row (ending at this one, going
    /// backward through history) at THAT SESSION's own weights that also
    /// hit or beat their own target reps on every set (0 if this session
    /// itself doesn't qualify) — this describes history, so it does NOT
    /// move when today's weight field changes; for `.bestAtTheseWeights`,
    /// total sessions ever logged at today's live weights — this ONE does
    /// move live as today's weight field changes; for `.bestForExercise`,
    /// total sessions ever logged with this rep/set structure, independent
    /// of weight entirely. `.bestAtTheseWeights` and `.lastLogged` are each
    /// bounded by `.bestForExercise` (both only ever count sessions that
    /// also share this rep/set structure), but NOT by each other — moving
    /// today's weight to one never done before drops `.bestAtTheseWeights`
    /// to 0 while `.lastLogged` keeps reflecting whatever streak the actual
    /// previous session was on at ITS weight. Powers the "(2x)", "(3x)",
    /// etc. suffix on the label.
    let occurrenceCount: Int
    /// Whether this log's totalWeightMoved ties or beats the highest total
    /// ever moved for this exercise's plan (same name + target rep scheme)
    /// — see `comparisons`'s `planBestTotal`. `.bestForExercise` is always
    /// true here by construction (it IS that plan's best log), but
    /// `.lastLogged`/`.bestAtTheseWeights` only when they happen to be it too.
    let isPR: Bool
    var hasData: Bool { date != nil }

    /// The kind's display name, with a "(Nx)" occurrence-count suffix (and
    /// a "(PR)" tag, if this is the plan's all-time-best total) appended
    /// once there's actually a log to count.
    var label: String {
        guard hasData else { return kind.rawValue }
        return "\(kind.rawValue) (\(occurrenceCount)x)" + (isPR ? " (PR)" : "")
    }
}

enum PaceEngine {

    // MARK: Finding the three comparison workouts

    /// Always returns all three kinds, in order — one per Kind.allCases —
    /// even when there's no prior log to compare against yet, so the pace
    /// panel's layout stays consistent (that kind just shows "no data yet").
    /// - lastLogged: most recent log of this exercise (same plan key preferred, else same name)
    /// - bestAtTheseWeights: max total moved among logs with an identical weights sequence
    /// - bestForExercise: max total moved among logs with the same plan (name + target scheme)
    static func comparisons(for exerciseName: String,
                            targetReps: [Int],
                            currentWeights: [Double],
                            isBodyweight: Bool = false,
                            allLogs: [ExerciseLog]) -> [ComparisonTarget] {
        let planKey = "\(exerciseName)|\(targetReps.map(String.init).joined(separator: "/"))"
        // For a bodyweight exercise, currentWeights holds ADDED weight, so
        // the key must match ExerciseLog.weightsKey's "BW+n" format.
        let weightsKey = isBodyweight
            ? currentWeights.map { "BW+\(Formatters.trim($0))" }.joined(separator: "/")
            : currentWeights.map { Formatters.trim($0) }.joined(separator: "/")

        let byName = allLogs
            .filter { $0.exerciseName == exerciseName && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) > ($1.session?.date ?? .distantPast) }

        let last = byName.first(where: { $0.planKey == planKey }) ?? byName.first
        // Previous Workout's own weights, not today's — this streak
        // describes history, so it doesn't move just because today's
        // weight field changes (unlike .bestAtTheseWeights below, which
        // deliberately does).
        let lastStreak = last.map { consecutiveHitStreak(endingAt: $0, in: byName, atWeightsKey: $0.weightsKey) } ?? 0
        let atWeights = currentWeights.isEmpty ? [] : byName.filter({ $0.weightsKey == weightsKey })
        let bestWeights = atWeights.max(by: { $0.totalWeightMoved < $1.totalWeightMoved })
        let atPlan = byName.filter({ $0.planKey == planKey })
        let bestPlan = atPlan.max(by: { $0.totalWeightMoved < $1.totalWeightMoved })
        // The single yardstick all 3 "(PR)" checks below compare against —
        // this plan's own highest total ever moved. .bestForExercise IS
        // that log, so it always ties it; the other two only when they
        // happen to be it too.
        let planBestTotal = bestPlan?.totalWeightMoved

        return [
            target(.lastLogged, from: last, occurrenceCount: lastStreak, planBestTotal: planBestTotal),
            target(.bestAtTheseWeights, from: bestWeights, occurrenceCount: atWeights.count, planBestTotal: planBestTotal),
            target(.bestForExercise, from: bestPlan, occurrenceCount: atPlan.count, planBestTotal: planBestTotal),
        ]
    }

    /// Whether every set in this log hit or beat its own target rep count —
    /// for a repTotal exercise, whether the total target was reached at all
    /// (there's no per-set target to check).
    private static func hitTargetReps(_ log: ExerciseLog) -> Bool {
        switch log.goalType {
        case .fixedSets:
            let sets = log.sortedSets
            guard !sets.isEmpty, sets.count == log.targetReps.count else { return false }
            return zip(sets, log.targetReps).allSatisfy { $0.reps >= $1 }
        case .repTotal:
            return log.repTotalReached
        }
    }

    /// How many sessions in a row, counting backward in time starting at
    /// `log` itself, were BOTH at `atWeightsKey` AND hit or beat their own
    /// target reps on every set — 0 if `log` itself doesn't qualify (a
    /// different weight or a miss resets the streak, it doesn't just stop
    /// counting it). Callers decide what `atWeightsKey` means: `comparisons`
    /// passes `log`'s own weightsKey (so the result describes history, not
    /// today's weight field). `logs` must already be sorted most-recent-first
    /// and contain `log`.
    private static func consecutiveHitStreak(endingAt log: ExerciseLog, in logs: [ExerciseLog], atWeightsKey: String) -> Int {
        guard let startIndex = logs.firstIndex(where: { $0 === log }) else {
            return (log.weightsKey == atWeightsKey && hitTargetReps(log)) ? 1 : 0
        }
        var count = 0
        for entry in logs[startIndex...] {
            guard entry.weightsKey == atWeightsKey, hitTargetReps(entry) else { break }
            count += 1
        }
        return count
    }

    private static func target(_ kind: ComparisonTarget.Kind, from log: ExerciseLog?, occurrenceCount: Int = 1,
                               planBestTotal: Double? = nil) -> ComparisonTarget {
        guard let log else {
            return ComparisonTarget(kind: kind, date: nil, totalWeightMoved: 0, setWeightsMoved: [], weights: [], reps: [], weightLabels: [], occurrenceCount: 1, isPR: false)
        }
        let sortedSets = log.sortedSets
        let isPR = planBestTotal.map { log.totalWeightMoved >= $0 } ?? false
        return ComparisonTarget(kind: kind,
                                date: log.session?.date ?? .distantPast,
                                totalWeightMoved: log.totalWeightMoved,
                                setWeightsMoved: sortedSets.map { $0.weight * Double($0.reps) },
                                weights: sortedSets.map(\.weight),
                                reps: sortedSets.map(\.reps),
                                weightLabels: weightLabels(for: log),
                                occurrenceCount: occurrenceCount,
                                isPR: isPR)
    }

    /// "135/135/135 lbs" for a normal log, or "BW+25/BW+25/BW+25 (172 BW)
    /// lbs" for a bodyweight one — shows both the added load and the
    /// bodyweight it was resolved against, since the resolved total alone
    /// wouldn't reveal whether a change was from added weight or bodyweight.
    static func weightsSummaryString(for log: ExerciseLog) -> String {
        let sortedSets = log.sortedSets
        guard log.isBodyweight else {
            return sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/") + " lbs"
        }
        let addedSeq = sortedSets.map { "BW+\(Formatters.trim($0.addedWeight ?? 0))" }.joined(separator: "/")
        let bw = sortedSets.first?.bodyweightAtLog.map { Formatters.trim($0) } ?? "?"
        return "\(addedSeq) (\(bw) BW) lbs"
    }

    /// Per-set weight label — the resolved effective total (bodyweightAtLog
    /// + addedWeight for a bodyweight set, same as any other set's `weight`)
    /// so History, the Pace Calculator, and Previous Workouts all read the
    /// same number a non-bodyweight exercise would show.
    static func weightLabels(for log: ExerciseLog) -> [String] {
        log.sortedSets.map { Formatters.trim($0.weight) }
    }

    // MARK: - repTotal comparisons (sets-to-complete, not reps-to-beat)

    struct RepTotalComparisonTarget: Identifiable {
        let id = UUID()
        let kind: ComparisonTarget.Kind
        let date: Date?
        /// Nil if that log never actually reached its rep total (an
        /// interrupted/incomplete session) — falls back to comparing total
        /// weight moved instead, since "sets to complete" isn't meaningful
        /// for a session that never finished.
        let setsToComplete: Int?
        let totalWeightMoved: Double
        let reps: [Int]
        let weightLabels: [String]
        /// See `ComparisonTarget.occurrenceCount`.
        let occurrenceCount: Int
        /// See `ComparisonTarget.isPR` — note that for repTotal,
        /// `.bestForExercise` picks its log by fewest sets to reach the
        /// target (efficiency), NOT highest total weight moved, so unlike
        /// the fixedSets version this ISN'T guaranteed to always be true
        /// there — only when the most efficient session also happened to
        /// move the most total weight.
        let isPR: Bool
        var hasData: Bool { date != nil }

        /// See `ComparisonTarget.label`.
        var label: String {
            guard hasData else { return kind.rawValue }
            return "\(kind.rawValue) (\(occurrenceCount)x)" + (isPR ? " (PR)" : "")
        }
    }

    /// Same three kinds as `comparisons`, but for a repTotal exercise: shows
    /// sets-to-complete + reps finished instead of total-weight reps-to-beat
    /// math. `currentWeightsKey` should already be BW-aware (built the same
    /// way ExerciseLog.weightsKey is) if this exercise is bodyweight.
    static func repTotalComparisons(for exerciseName: String,
                                    target: Int,
                                    currentWeightsKey: String,
                                    allLogs: [ExerciseLog]) -> [RepTotalComparisonTarget] {
        let planKey = "\(exerciseName)|\(target) total"
        let byName = allLogs
            .filter { $0.exerciseName == exerciseName && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) > ($1.session?.date ?? .distantPast) }

        let last = byName.first(where: { $0.planKey == planKey }) ?? byName.first
        // Previous Workout's own weights, not today's — see comparisons(for:...).
        let lastStreak = last.map { consecutiveHitStreak(endingAt: $0, in: byName, atWeightsKey: $0.weightsKey) } ?? 0
        let atWeights = currentWeightsKey.isEmpty ? [] : byName.filter { $0.weightsKey == currentWeightsKey }
        let bestAtWeights = bestRepTotalLog(among: atWeights)
        let atPlan = byName.filter { $0.planKey == planKey }
        let bestOverall = bestRepTotalLog(among: atPlan)
        let planBestTotal = atPlan.map(\.totalWeightMoved).max()

        return [
            repTotalTarget(.lastLogged, from: last, occurrenceCount: lastStreak, planBestTotal: planBestTotal),
            repTotalTarget(.bestAtTheseWeights, from: bestAtWeights, occurrenceCount: atWeights.count, planBestTotal: planBestTotal),
            repTotalTarget(.bestForExercise, from: bestOverall, occurrenceCount: atPlan.count, planBestTotal: planBestTotal),
        ]
    }

    /// Prefers whichever log reached the target in the fewest sets; if none
    /// reached it yet, falls back to the best attempt by total weight moved.
    static func bestRepTotalLog(among logs: [ExerciseLog]) -> ExerciseLog? {
        let reached = logs.filter(\.repTotalReached)
        if let best = reached.min(by: { $0.sortedSets.count < $1.sortedSets.count }) {
            return best
        }
        return logs.max(by: { $0.totalWeightMoved < $1.totalWeightMoved })
    }

    private static func repTotalTarget(_ kind: ComparisonTarget.Kind, from log: ExerciseLog?, occurrenceCount: Int = 1,
                                       planBestTotal: Double? = nil) -> RepTotalComparisonTarget {
        guard let log else {
            return RepTotalComparisonTarget(kind: kind, date: nil, setsToComplete: nil,
                                            totalWeightMoved: 0, reps: [], weightLabels: [], occurrenceCount: 1, isPR: false)
        }
        let sortedSets = log.sortedSets
        let isPR = planBestTotal.map { log.totalWeightMoved >= $0 } ?? false
        return RepTotalComparisonTarget(kind: kind,
                                        date: log.session?.date ?? .distantPast,
                                        setsToComplete: log.repTotalReached ? sortedSets.count : nil,
                                        totalWeightMoved: log.totalWeightMoved,
                                        reps: sortedSets.map(\.reps),
                                        weightLabels: weightLabels(for: log),
                                        occurrenceCount: occurrenceCount,
                                        isPR: isPR)
    }

    /// "Finish in N more sets for a PR" — how many sets of room are left
    /// before merely tying (not beating) the fewest-sets record. Nil once
    /// there's no room left, or there's no record yet to chase.
    static func repTotalPRRoom(setsLoggedSoFar: Int, bestSetsToComplete: Int?) -> Int? {
        guard let best = bestSetsToComplete else { return nil }
        let room = best - 1 - setsLoggedSoFar
        return room >= 1 ? room : nil
    }

    // MARK: - Pro-rata pace math

    /// How far into its own total the target was by its own set `n` (1-based)
    /// — e.g. 0.6 means the target had moved 60% of its eventual total by
    /// then. `n` beyond the target's own set count has no defined share.
    private static func share(atSetIndex n: Int, setWeightsMoved: [Double], total: Double) -> Double? {
        guard n >= 1, n <= setWeightsMoved.count, total > 0 else { return nil }
        return setWeightsMoved.prefix(n).reduce(0, +) / total
    }

    /// "By set n, you should have moved this much to be on the target's own
    /// pace toward actually beating it" — the target's share through its own
    /// set n, scaled to (total + 1) rather than just its total, so matching
    /// the target's pace exactly still isn't quite enough to win (it takes at
    /// least one more unit than the target moved). Once n runs past however
    /// many sets the target itself took, there's no further pacing signal to
    /// follow — the milestone just becomes the full win threshold.
    static func milestone(atSetIndex n: Int, setWeightsMoved: [Double], total: Double) -> Double {
        guard let share = share(atSetIndex: n, setWeightsMoved: setWeightsMoved, total: total) else {
            return total + 1
        }
        return share * (total + 1)
    }

    /// Pro-rata pace cell: how many reps (fractional) `columnWeight` — the
    /// weight for set `setIndex` (1-based, the set about to be attempted) —
    /// needs to reach that set's milestone, given `loggedSoFar` (this
    /// session's cumulative through set `setIndex - 1`). Replaces a flat
    /// "beat the whole total by the last set" countdown with one that tracks
    /// whether THIS set is keeping pace with how the target distributed its
    /// own total across its own sets. Negative means already past the
    /// milestone — ahead of pace, not behind.
    static func paceCellValue(target: ComparisonTarget, setIndex: Int,
                              loggedSoFar: Double, columnWeight: Double) -> Double? {
        guard columnWeight > 0 else { return nil }
        let m = milestone(atSetIndex: setIndex, setWeightsMoved: target.setWeightsMoved,
                          total: target.totalWeightMoved)
        return (m - loggedSoFar) / columnWeight
    }

    /// Reps needed in the immediate next set to stay on pace to beat the
    /// target's total — ports a reference spreadsheet formula: spreads the
    /// remaining weight deficit evenly across every set still remaining
    /// today, using the target's own weight at each remaining set position
    /// (averaged) as the rate. Deliberately ignores today's own upcoming
    /// weight and any ratchet/history from earlier sets — it's a fresh,
    /// stateless recompute every time, driven entirely by the target's
    /// weights and however much of the deficit is left right now:
    ///
    ///   reps needed = ROUNDUP( (target total − today's total so far)
    ///                          ÷ average(target's weight at each
    ///                            still-remaining set position)
    ///                          ÷ sets still remaining )
    ///
    /// On the last remaining set this reduces to exactly "deficit ÷ that
    /// set's own target weight" — the literal number of reps needed to
    /// cross the total, with nothing left to average or spread across.
    static func evenPaceCellValue(target: ComparisonTarget, loggedSoFar: Double,
                                  setsLoggedSoFar: Int, totalSetsToday: Int) -> Double? {
        let setsRemain = totalSetsToday - setsLoggedSoFar
        guard setsRemain > 0, !target.weights.isEmpty else { return nil }
        let wtRemain = target.totalWeightMoved - loggedSoFar
        let endIndex = min(totalSetsToday, target.weights.count)
        let startIndex = min(setsLoggedSoFar, endIndex)
        let validWeights = Array(target.weights[startIndex..<endIndex])
        guard !validWeights.isEmpty else { return nil }
        let avg = validWeights.reduce(0, +) / Double(validWeights.count)
        guard avg > 0 else { return nil }
        return (wtRemain / avg / Double(setsRemain)).rounded(.up)
    }
}
