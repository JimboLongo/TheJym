//
//  PaceEngine.swift
//  TheJym
//
//  Finds the three comparison workouts for an exercise and computes
//  "reps needed in the next set to stay on pace to beat" each one.
//

import Foundation

struct ComparisonTarget: Identifiable {
    enum Kind: String {
        case lastLogged = "Last Time"
        case bestAtTheseWeights = "Best @ These Weights"
        case bestForExercise = "All-Time Best (This Plan)"
    }
    let id = UUID()
    let kind: Kind
    let date: Date
    let totalWeightMoved: Double
    let setsSummary: String        // "6/6/5/4/4/3 @ 135/135/135/145/145/145"
}

enum PaceEngine {

    // MARK: Finding the three comparison workouts

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

        var out: [ComparisonTarget] = []

        if let last = byName.first(where: { $0.planKey == planKey }) ?? byName.first {
            out.append(target(.lastLogged, from: last))
        }
        if !currentWeights.isEmpty,
           let bestWeights = byName
               .filter({ $0.weightsKey == weightsKey })
               .max(by: { $0.totalWeightMoved < $1.totalWeightMoved }) {
            out.append(target(.bestAtTheseWeights, from: bestWeights))
        }
        if let bestPlan = byName
            .filter({ $0.planKey == planKey })
            .max(by: { $0.totalWeightMoved < $1.totalWeightMoved }) {
            out.append(target(.bestForExercise, from: bestPlan))
        }
        return out
    }

    private static func target(_ kind: ComparisonTarget.Kind, from log: ExerciseLog) -> ComparisonTarget {
        let reps = log.sortedSets.map { String($0.reps) }.joined(separator: "/")
        let weights = log.sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
        return ComparisonTarget(kind: kind,
                                date: log.session?.date ?? .distantPast,
                                totalWeightMoved: log.totalWeightMoved,
                                setsSummary: "\(reps) @ \(weights)")
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
