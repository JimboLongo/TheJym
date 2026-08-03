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
    let reps: [Int]
    /// Per-set resolved weight label — paired with `reps` (same index) in a
    /// SetsGrid.
    let weightLabels: [String]
    var hasData: Bool { date != nil }
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
        let bestWeights = currentWeights.isEmpty ? nil : byName
            .filter({ $0.weightsKey == weightsKey })
            .max(by: { $0.totalWeightMoved < $1.totalWeightMoved })
        let bestPlan = byName
            .filter({ $0.planKey == planKey })
            .max(by: { $0.totalWeightMoved < $1.totalWeightMoved })

        return [
            target(.lastLogged, from: last),
            target(.bestAtTheseWeights, from: bestWeights),
            target(.bestForExercise, from: bestPlan),
        ]
    }

    private static func target(_ kind: ComparisonTarget.Kind, from log: ExerciseLog?) -> ComparisonTarget {
        guard let log else {
            return ComparisonTarget(kind: kind, date: nil, totalWeightMoved: 0, setWeightsMoved: [], reps: [], weightLabels: [])
        }
        let sortedSets = log.sortedSets
        return ComparisonTarget(kind: kind,
                                date: log.session?.date ?? .distantPast,
                                totalWeightMoved: log.totalWeightMoved,
                                setWeightsMoved: sortedSets.map { $0.weight * Double($0.reps) },
                                reps: sortedSets.map(\.reps),
                                weightLabels: weightLabels(for: log))
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
        var hasData: Bool { date != nil }
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
        let atWeights = currentWeightsKey.isEmpty ? [] : byName.filter { $0.weightsKey == currentWeightsKey }
        let bestAtWeights = bestRepTotalLog(among: atWeights)
        let bestOverall = bestRepTotalLog(among: byName.filter { $0.planKey == planKey })

        return [
            repTotalTarget(.lastLogged, from: last),
            repTotalTarget(.bestAtTheseWeights, from: bestAtWeights),
            repTotalTarget(.bestForExercise, from: bestOverall),
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

    private static func repTotalTarget(_ kind: ComparisonTarget.Kind, from log: ExerciseLog?) -> RepTotalComparisonTarget {
        guard let log else {
            return RepTotalComparisonTarget(kind: kind, date: nil, setsToComplete: nil,
                                            totalWeightMoved: 0, reps: [], weightLabels: [])
        }
        let sortedSets = log.sortedSets
        return RepTotalComparisonTarget(kind: kind,
                                        date: log.session?.date ?? .distantPast,
                                        setsToComplete: log.repTotalReached ? sortedSets.count : nil,
                                        totalWeightMoved: log.totalWeightMoved,
                                        reps: sortedSets.map(\.reps),
                                        weightLabels: weightLabels(for: log))
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

    /// One already-logged set's numbers, as needed to reconstruct what its
    /// own pace requirement was at the time — `rawWeight` is what was
    /// actually loaded (the countdown's own denominator, same convention as
    /// paceCellValue's columnWeight), `effectiveWeightMoved` is what that
    /// set contributed to the session's cumulative total (bodyweight-
    /// resolved for a bodyweight exercise, matching ExerciseDraft.loggedTotal).
    struct LoggedSetEntry {
        let rawWeight: Double
        let effectiveWeightMoved: Double
        let reps: Int
    }

    /// Reps needed for the upcoming set, ratcheted against the previous
    /// set's own requirement and whether it was met: hitting (or beating)
    /// what a set asked for can never make the next set demand *more*, and
    /// falling short of a set can never make the next set demand *less* —
    /// this must hold in both directions across two sets at the SAME
    /// weight (never miss a set and see the number go down; never hit a
    /// set and see the number go up), and also protects against a lighter
    /// or heavier weight entered for the next set otherwise making the raw
    /// pro-rata countdown jump around in a way that reads as broken (e.g.
    /// "need 4" -> hit 4 -> "need 5").
    ///
    /// Walks every already-logged set in order, recomputing what its own
    /// requirement would have been and clamping it against the ratchet
    /// carried from the set before it, then applies the same clamp to the
    /// upcoming set. An ahead-of-pace set (raw <= 0) has no positive
    /// "needed" number to carry forward, so the ratchet resets fresh right
    /// after it — otherwise a big enough early lead would permanently pin
    /// every later set's requirement to (near) zero even if you actually
    /// fall behind on a much heavier set down the line.
    ///
    /// Returns nil under the same condition paceCellValue does (no usable
    /// upcoming weight). A negative result still means "ahead of pace by
    /// this many reps," same as paceCellValue, and is returned unclamped —
    /// the ratchet only governs the positive ("reps still needed") side.
    ///
    /// `isFinalSet` — true when the upcoming set is the last one left in
    /// today's exercise, with nothing after it to make up ground on. This
    /// is the one case the ratchet must NOT govern, even though it's
    /// usually also a same-weight, just-hit-it set: the last set's raw
    /// requirement already *is* the exact number of reps needed to cross
    /// the target's total, so honoring the "just hit it, can't ask for
    /// more" rule here would understate — sometimes to the point of
    /// promising a win that a literal reading of the target's total says
    /// isn't actually there yet.
    static func ratchetedPaceCellValue(target: ComparisonTarget, loggedSets: [LoggedSetEntry],
                                       upcomingSetIndex: Int, upcomingRawWeight: Double,
                                       isFinalSet: Bool = false) -> Double? {
        guard upcomingRawWeight > 0 else { return nil }
        var cumulative = 0.0
        var lastRequirement: Int?
        // Whether the set that produced lastRequirement actually met ITS
        // OWN (already-clamped) requirement — this, not the requirement
        // number itself, is what decides which direction the next set's
        // clamp goes. Comparing a set's reps against a DIFFERENT set's
        // requirement (e.g. set 2's reps against set 1's number) was the
        // bug: two sets can need completely different rep counts at
        // completely different weights, so 9 reps "failing" a 13-rep bar
        // set by a heavier set doesn't mean anything.
        var lastMet = true
        for (i, entry) in loggedSets.enumerated() {
            defer { cumulative += entry.effectiveWeightMoved }
            guard entry.rawWeight > 0 else { lastRequirement = nil; lastMet = true; continue }
            let m = milestone(atSetIndex: i + 1, setWeightsMoved: target.setWeightsMoved,
                              total: target.totalWeightMoved)
            let raw = (m - cumulative) / entry.rawWeight
            guard raw > 0 else { lastRequirement = nil; lastMet = true; continue }
            var req = Int(ceil(raw))
            if let last = lastRequirement {
                req = lastMet ? min(req, last) : max(req, last)
            }
            lastRequirement = req
            lastMet = entry.reps >= req
        }
        let m = milestone(atSetIndex: upcomingSetIndex, setWeightsMoved: target.setWeightsMoved,
                          total: target.totalWeightMoved)
        let raw = (m - cumulative) / upcomingRawWeight
        guard raw > 0 else { return raw }
        var req = Int(ceil(raw))
        if !isFinalSet, let last = lastRequirement {
            req = lastMet ? min(req, last) : max(req, last)
        }
        return Double(req)
    }
}
