//
//  RepSchemeImpact.swift
//  TheJym
//
//  What editing or deleting one saved set would actually touch, and the
//  confirmation text that says so.
//
//  repSchemes lives on ExerciseDef, so it is GLOBAL. Editing 6/6/6 from a
//  single-cycle override in PhasesView changes the library entry every
//  phase shares. The screen you long-pressed from implies a narrow scope
//  and the action has a wide one, so every confirmation here leads with
//  that fact rather than describing only the local effect.
//
//  Confirmations appear only when the impact is non-zero. A set nothing
//  references is edited or deleted silently — a prompt that always appears
//  is a prompt you learn to dismiss, which would make the one that matters
//  worthless.
//

import Foundation
import SwiftData

struct RepSchemeImpact {
    let defName: String
    let reps: [Int]
    /// "Phase 2 · Lower Day 1", one per PlannedExercise still planning this
    /// exact array. These keep working after an edit — PlannedExercise holds
    /// its OWN copy of targetReps — but they stop matching the library and
    /// start showing PhaseEditView/PhasesView's "isn't saved … anymore"
    /// warning, which is what makes them worth naming.
    let plannedUsages: [String]
    /// Logged workouts whose targetReps snapshot is this exact array. They
    /// are never modified: ExerciseLog has no relationship to ExerciseDef,
    /// only an exerciseName string, so nothing cascades. What changes is
    /// that they stop appearing under this set in the Exercises tab.
    let loggedCount: Int
    let ceiling: RepSchemeCeiling?

    /// Nothing points at this set, so changing it can't surprise anyone.
    var isUnreferenced: Bool {
        plannedUsages.isEmpty && loggedCount == 0 && ceiling == nil
    }

    static func compute(def: ExerciseDef, reps: [Int],
                        plannedExercises: [PlannedExercise],
                        logs: [ExerciseLog]) -> RepSchemeImpact {
        let usages = plannedExercises
            .filter { $0.exerciseName == def.name && $0.targetReps == reps }
            .filter { if case .fixedSets = $0.goalType { return true } else { return false } }
            .map { pe -> String in
                let day = pe.day
                let phase = day?.phase.map { "Phase \($0.number)" } ?? "No phase"
                let dayName = day?.name ?? "Unassigned day"
                // A per-cycle override is a different slot from its base and
                // reads as one, so it says which cycle it belongs to.
                return pe.cycleOverride > 0
                    ? "\(phase) · \(dayName) (cycle \(pe.cycleOverride))"
                    : "\(phase) · \(dayName)"
            }
            .sorted()
        let logged = logs.filter { $0.exerciseName == def.name && $0.targetReps == reps }.count
        return RepSchemeImpact(defName: def.name, reps: reps,
                               plannedUsages: usages, loggedCount: logged,
                               ceiling: def.ceiling(for: reps))
    }

    // MARK: - Text

    private var setText: String { reps.map(String.init).joined(separator: "/") }

    /// Leads every confirmation. The action is wider than any one screen
    /// implies, and scope should never be a surprise because of where you
    /// happened to long-press.
    private var scopeLine: String {
        "This set is saved on \(defName) in Exercises. "
            + "Changing it affects every phase that uses it."
    }

    private var usageLines: [String] {
        var out: [String] = []
        if !plannedUsages.isEmpty {
            out.append("Planned in \(plannedUsages.count) place\(plannedUsages.count == 1 ? "" : "s"): "
                       + plannedUsages.joined(separator: ", ")
                       + ". Those keep training \(setText) — they'll just be flagged as no longer saved here.")
        }
        if loggedCount > 0 {
            out.append("\(loggedCount) logged workout\(loggedCount == 1 ? "" : "s") stay on \(setText) "
                       + "and won't show under the new set.")
        }
        return out
    }

    /// What a ceiling does when the reps change, which depends entirely on
    /// whether the number of sets changes with them.
    enum CeilingOutcome: Equatable {
        /// No ceiling configured — nothing to carry.
        case none
        /// Same set count, so the upper target still has one entry per set
        /// and rides across untouched.
        case movesVerbatim(RepSchemeCeiling)
        /// Set count changed, so the existing upper target no longer has one
        /// entry per set — the invariant UpperTargetPickerSheet.canSet
        /// enforces. It cannot ride along and must be re-entered or dropped.
        case mustBeReentered(oldSetCount: Int, newSetCount: Int)
    }

    func ceilingOutcome(forNewReps new: [Int]) -> CeilingOutcome {
        guard let ceiling else { return .none }
        return new.count == reps.count
            ? .movesVerbatim(ceiling)
            : .mustBeReentered(oldSetCount: reps.count, newSetCount: new.count)
    }

    /// nil when no confirmation is warranted.
    func editConfirmation(newReps new: [Int]) -> String? {
        var lines = usageLines
        if case .mustBeReentered(let oldCount, let newCount) = ceilingOutcome(forNewReps: new) {
            lines.append("The rep ceiling was set for \(oldCount) set\(oldCount == 1 ? "" : "s") "
                         + "and this set now has \(newCount). It can't carry over — "
                         + "re-enter it in the next step or it will be cleared.")
        }
        guard !lines.isEmpty else { return nil }
        return ([scopeLine] + lines).joined(separator: "\n\n")
    }

    /// nil when no confirmation is warranted.
    var deleteConfirmation: String? {
        var lines = usageLines
        if ceiling != nil {
            lines.append("Its rep ceiling is deleted with it.")
        }
        guard !lines.isEmpty else { return nil }
        return ([scopeLine] + lines).joined(separator: "\n\n")
    }
}
