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
                            allLogs: [ExerciseLog]) -> [ComparisonTarget] {
        let planKey = "\(exerciseName)|\(targetReps.map(String.init).joined(separator: "/"))"
        let weightsKey = currentWeights.map { Formatters.trim($0) }.joined(separator: "/")

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
        let weights = sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
        return ComparisonTarget(kind: kind,
                                date: log.session?.date ?? .distantPast,
                                totalWeightMoved: log.totalWeightMoved,
                                setsSummary: "\(reps) reps @ \(weights) lbs")
    }

    // MARK: Reps-to-beat math

    /// Given a target total, the sets already logged, and the weights planned for the
    /// remaining sets, return the reps you need in the NEXT set to stay "on pace" to
    /// beat the target (deficit spread proportionally across remaining sets by weight).
    ///
    /// Example: target 3,890, nothing logged yet, plan 135/135/135/145/145/145
    /// -> remaining capacity per rep = 135+135+135+145+145+145 = 840
    /// -> even pace requires ~4.63 "reps worth" per weighted set; next set at 135
    ///    needs ceil((3891 * 135/840) / 135) ... simplified below to an even-reps solve.
    static func repsNeededNextSet(targetTotal: Double,
                                  loggedSoFar: Double,
                                  remainingWeights: [Double]) -> Int? {
        guard let next = remainingWeights.first, next > 0 else { return nil }
        let deficit = targetTotal - loggedSoFar + 1   // +1 lb·rep to BEAT, not tie
        if deficit <= 0 { return 0 }                   // already beaten
        let capacityPerRep = remainingWeights.reduce(0, +)
        guard capacityPerRep > 0 else { return nil }
        // Solve for equal reps r across remaining sets: r * capacityPerRep >= deficit
        let evenReps = deficit / capacityPerRep
        return Int(ceil(evenReps))
    }

    /// Reps needed in the FINAL remaining set to beat outright (if it all came down to this set).
    static func repsToClinch(targetTotal: Double,
                             loggedSoFar: Double,
                             nextWeight: Double) -> Int? {
        guard nextWeight > 0 else { return nil }
        let deficit = targetTotal - loggedSoFar + 1
        if deficit <= 0 { return 0 }
        return Int(ceil(deficit / nextWeight))
    }
}
