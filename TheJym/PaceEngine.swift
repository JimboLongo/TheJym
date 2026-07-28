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
    let setsSummary: String        // "6/6/5/4/4/3 reps @ 135/135/135/145/145/145 lbs"
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
            return ComparisonTarget(kind: kind, date: nil, totalWeightMoved: 0, setsSummary: "")
        }
        let sortedSets = log.sortedSets
        let reps = sortedSets.map { String($0.reps) }.joined(separator: "/")
        return ComparisonTarget(kind: kind,
                                date: log.session?.date ?? .distantPast,
                                totalWeightMoved: log.totalWeightMoved,
                                setsSummary: "\(reps) reps @ \(weightsSummaryString(for: log))")
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
        let firstSetReps: Int?
        let totalWeightMoved: Double
        let setsSummary: String
        var hasData: Bool { date != nil }
    }

    /// Same three kinds as `comparisons`, but for a repTotal exercise: shows
    /// sets-to-complete + first-set reps instead of total-weight reps-to-
    /// beat math. `currentWeightsKey` should already be BW-aware (built the
    /// same way ExerciseLog.weightsKey is) if this exercise is bodyweight.
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
                                            firstSetReps: nil, totalWeightMoved: 0, setsSummary: "")
        }
        let sortedSets = log.sortedSets
        let reps = sortedSets.map { String($0.reps) }.joined(separator: "/")
        return RepTotalComparisonTarget(kind: kind,
                                        date: log.session?.date ?? .distantPast,
                                        setsToComplete: log.repTotalReached ? sortedSets.count : nil,
                                        firstSetReps: sortedSets.first?.reps,
                                        totalWeightMoved: log.totalWeightMoved,
                                        setsSummary: "\(reps) reps @ \(weightsSummaryString(for: log))")
    }

    /// "Finish in N more sets for a PR" — how many sets of room are left
    /// before merely tying (not beating) the fewest-sets record. Nil once
    /// there's no room left, or there's no record yet to chase.
    static func repTotalPRRoom(setsLoggedSoFar: Int, bestSetsToComplete: Int?) -> Int? {
        guard let best = bestSetsToComplete else { return nil }
        let room = best - 1 - setsLoggedSoFar
        return room >= 1 ? room : nil
    }

    // MARK: Reps-to-beat math

    /// Reps needed in just the NEXT set (at its current, possibly just-
    /// adjusted weight) to beat the target outright — doesn't spread the
    /// deficit across every remaining set, so a weight bump on the next set
    /// is reflected immediately in the pace needed for that one set.
    static func repsToClinch(targetTotal: Double,
                             loggedSoFar: Double,
                             nextWeight: Double) -> Int? {
        guard nextWeight > 0 else { return nil }
        let deficit = targetTotal - loggedSoFar + 1
        if deficit <= 0 { return 0 }
        return Int(ceil(deficit / nextWeight))
    }
}
