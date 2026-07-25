//
//  Models.swift
//  TheJym
//
//  SwiftData models. iOS 17+.
//

import Foundation
import SwiftData

// MARK: - App Settings (singleton-style, fetch first or create)

enum AIAggressiveness: Int, Codable, CaseIterable, Identifiable {
    case conservative = 0   // must EXCEED targets 3 cycles in a row -> +2.5/5 lb
    case moderate = 1       // exceed targets 2 cycles in a row -> +5 lb (upper) / +10 (lower)
    case aggressive = 2     // hit targets once -> +5/+10; blow past by 2+ reps/set -> +10/+15

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .conservative: return "Not Very Aggressive"
        case .moderate:     return "Moderate"
        case .aggressive:   return "Aggressive"
        }
    }
    var detail: String {
        switch self {
        case .conservative: return "Only increases weight after exceeding target reps 3 cycles in a row, by 2.5–5 lb."
        case .moderate:     return "Increases after exceeding targets 2 cycles in a row, by 5–10 lb."
        case .aggressive:   return "Increases as soon as you hit targets, by 5–15 lb depending on how far you exceeded them."
        }
    }
}

@Model
final class AppSettings {
    var trainingStartDate: Date
    var aiAssistantEnabled: Bool
    var aiAggressivenessRaw: Int
    var deloadWeeksEnabled: Bool
    var useGeminiForPhasePlanning: Bool
    var geminiAPIKey: String
    var availablePlateSizes: [Double] = [45, 35, 25, 10, 5, 2.5, 1.25]   // plates you own, for the plate calculator
    var hasDumbbell125Attachment: Bool = false   // finer dumbbell-weight increments, used in AI weight suggestions
    var hasDumbbell25Attachment: Bool = false
    var plateLoadableSides: Int = 2              // 1 or 2 — sides of the bar you can load plates on

    var aiAggressiveness: AIAggressiveness {
        get { AIAggressiveness(rawValue: aiAggressivenessRaw) ?? .moderate }
        set { aiAggressivenessRaw = newValue.rawValue }
    }

    /// Finest achievable weight increment for a dumbbell exercise, given
    /// whichever attachments (if any) are on hand.
    var dumbbellRoundingIncrement: Double {
        if hasDumbbell125Attachment { return 1.25 }
        if hasDumbbell25Attachment { return 2.5 }
        return 5
    }

    init(trainingStartDate: Date = .now,
         aiAssistantEnabled: Bool = true,
         aiAggressiveness: AIAggressiveness = .moderate,
         deloadWeeksEnabled: Bool = false,
         useGeminiForPhasePlanning: Bool = false,
         geminiAPIKey: String = "",
         availablePlateSizes: [Double] = [45, 35, 25, 10, 5, 2.5, 1.25],
         hasDumbbell125Attachment: Bool = false,
         hasDumbbell25Attachment: Bool = false,
         plateLoadableSides: Int = 2) {
        self.trainingStartDate = trainingStartDate
        self.aiAssistantEnabled = aiAssistantEnabled
        self.aiAggressivenessRaw = aiAggressiveness.rawValue
        self.deloadWeeksEnabled = deloadWeeksEnabled
        self.useGeminiForPhasePlanning = useGeminiForPhasePlanning
        self.geminiAPIKey = geminiAPIKey
        self.availablePlateSizes = availablePlateSizes
        self.hasDumbbell125Attachment = hasDumbbell125Attachment
        self.hasDumbbell25Attachment = hasDumbbell25Attachment
        self.plateLoadableSides = plateLoadableSides
    }
}

// MARK: - Equipment (bars + dumbbell sets, for the plate calculator)

@Model
final class Bar {
    var name: String
    var weight: Double              // bar weight; unused (0) for a dumbbell set
    var isDumbbell: Bool = false
    var dumbbellWeights: [Double] = []   // the individual dumbbell weights you own, when isDumbbell

    init(name: String, weight: Double, isDumbbell: Bool = false, dumbbellWeights: [Double] = []) {
        self.name = name
        self.weight = weight
        self.isDumbbell = isDumbbell
        self.dumbbellWeights = dumbbellWeights
    }
}

// MARK: - Exercise library

/// A persistent, user-managed exercise definition. Equipment and notes
/// belong to the exercise itself, regardless of rep scheme. `repSchemes` is
/// the list of saved "sets" under it (e.g. "Back Squat" might have both
/// 8/8/8 and 6/8/10 saved) — each has its own logged history, but they all
/// share the same equipment/notes. Lives independently of any Phase — Phase
/// Setup picks from these, and history spans every phase used in.
@Model
final class ExerciseDef {
    @Attribute(.unique) var name: String
    var notes: String = ""
    var equipment: Bar?
    var repSchemes: [[Int]] = []   // saved sets, e.g. [[5,5,5,3,3,3], [8,8,8]]

    init(name: String, notes: String = "",
         equipment: Bar? = nil, repSchemes: [[Int]] = []) {
        self.name = name
        self.notes = notes
        self.equipment = equipment
        self.repSchemes = repSchemes
    }

    /// Adds `reps` as a saved set if it isn't already present.
    func addRepScheme(_ reps: [Int]) {
        guard !reps.isEmpty, !repSchemes.contains(reps) else { return }
        repSchemes.append(reps)
    }

    /// Ensures `name` exists in the library, and that `targetReps` is one of
    /// its saved sets — creating the exercise and/or adding the set as
    /// needed. Used by Phase Setup, where the rep scheme is meaningful (a
    /// real target, not just a log of what happened).
    static func ensureVariantExists(name: String, targetReps: [Int],
                                    knownDefs: inout [String: ExerciseDef], context: ModelContext) {
        if let def = knownDefs[name] {
            def.addRepScheme(targetReps)
        } else {
            let def = ExerciseDef(name: name, repSchemes: targetReps.isEmpty ? [] : [targetReps])
            context.insert(def)
            knownDefs[name] = def
        }
    }

    /// Ensures `name` exists in the library at all — used where there's no
    /// meaningful target rep scheme (a CSV import or a manually back-filled
    /// historical workout just logs what happened).
    static func ensureAnyVariantExists(name: String, knownDefs: inout [String: ExerciseDef], context: ModelContext) {
        guard knownDefs[name] == nil else { return }
        let def = ExerciseDef(name: name)
        context.insert(def)
        knownDefs[name] = def
    }
}

// MARK: - Phase / Split

/// A Phase = a custom one-cycle day template (e.g. "Pull A, Push A, Legs A,
/// Rest, Pull B, Push B, Legs B, Rest") run for N cycles. Each day is either
/// the fixed "Rest" or a freely-named training day with its own independent
/// exercise list — two days can share a similar name (Pull A vs Pull B)
/// without sharing exercises, since each is its own PhaseDay.
@Model
final class Phase {
    var number: Int                // Phase 1, Phase 2, ...
    var totalCycles: Int           // e.g. 8
    var startDate: Date
    var isActive: Bool
    /// Cycle index (1-based) that is a deload cycle, or 0 for none.
    var deloadCycle: Int

    @Relationship(deleteRule: .cascade, inverse: \PhaseDay.phase)
    var days: [PhaseDay] = []

    /// Nullify, not cascade — deleting a Phase should never delete the
    /// workouts logged under it. They stay in History with a blank phase.
    @Relationship(deleteRule: .nullify, inverse: \WorkoutSession.phase)
    var sessions: [WorkoutSession] = []

    init(number: Int, totalCycles: Int,
         startDate: Date = .now, isActive: Bool = true, deloadCycle: Int = 0) {
        self.number = number
        self.totalCycles = totalCycles
        self.startDate = startDate
        self.isActive = isActive
        self.deloadCycle = deloadCycle
    }

    /// The one-cycle day template, in order.
    var orderedDays: [PhaseDay] { days.sorted { $0.order < $1.order } }

    /// Non-rest days, in order — each independent, even if two share a name.
    var trainingDays: [PhaseDay] { orderedDays.filter { !$0.isRest } }

    /// A short label for badges/headers, e.g. "Pull A · Push A · Legs A · Rest".
    var summary: String { orderedDays.map(\.name).joined(separator: " · ") }

    /// Every planned exercise across every day — used by AI phase planning.
    var plannedExercises: [PlannedExercise] { days.flatMap(\.plannedExercises) }

    func plan(for day: PhaseDay) -> [PlannedExercise] {
        day.plannedExercises.sorted { $0.order < $1.order }
    }

    /// How many completed (non-rest) sessions logged; used to figure out where we are.
    var completedSessionCount: Int { sessions.count }

    /// The number of training days in one full pass of the cycle.
    var trainingDaysPerCycle: Int { trainingDays.count }

    /// Current cycle number (1-based) based on sessions logged.
    var currentCycle: Int {
        guard trainingDaysPerCycle > 0 else { return 1 }
        return min(totalCycles, completedSessionCount / trainingDaysPerCycle + 1)
    }

    /// Index into the cycle's *training* days for the next session (0-based).
    var nextTrainingDayIndex: Int {
        guard trainingDaysPerCycle > 0 else { return 0 }
        return completedSessionCount % trainingDaysPerCycle
    }

    /// The day you're "supposed" to do next according to the cycle.
    var nextDay: PhaseDay? {
        let t = trainingDays
        guard !t.isEmpty else { return nil }
        return t[nextTrainingDayIndex]
    }

    var isComplete: Bool {
        completedSessionCount >= trainingDaysPerCycle * totalCycles
    }
}

/// One day within a Phase's one-cycle template — either the fixed "Rest" or
/// a freely-named training day ("Pull A", "Upper 1", ...) with its own
/// independent exercise list.
@Model
final class PhaseDay {
    var phase: Phase?
    var order: Int              // position within the cycle, 0-based
    var name: String            // "Pull A", "Upper 1", or "Rest"
    var isRest: Bool

    @Relationship(deleteRule: .cascade, inverse: \PlannedExercise.day)
    var plannedExercises: [PlannedExercise] = []

    /// Nullify — deleting a day (whether by editing a Phase or deleting the
    /// whole Phase) should never delete the workouts logged for it.
    @Relationship(deleteRule: .nullify, inverse: \WorkoutSession.day)
    var loggedSessions: [WorkoutSession] = []

    init(order: Int, name: String, isRest: Bool = false) {
        self.order = order
        self.name = name
        self.isRest = isRest
    }
}

/// One exercise slot inside a specific PhaseDay's plan.
@Model
final class PlannedExercise {
    var day: PhaseDay?
    var order: Int
    var exerciseName: String
    var targetReps: [Int]          // e.g. [5,5,5,3,3,3] — user can override
    var suggestedWeights: [Double] // per-set suggestion (AI or manual); empty = none yet

    init(order: Int, exerciseName: String,
         targetReps: [Int], suggestedWeights: [Double] = []) {
        self.order = order
        self.exerciseName = exerciseName
        self.targetReps = targetReps
        self.suggestedWeights = suggestedWeights
    }

    /// Stable key for "same plan" comparisons: name + target rep scheme.
    var planKey: String { "\(exerciseName)|\(targetReps.map(String.init).joined(separator: "/"))" }
}

// MARK: - Logged workouts

@Model
final class WorkoutSession {
    var phase: Phase?
    var date: Date
    var day: PhaseDay?        // nil for manually back-filled/imported entries
    var dayLabel: String      // display name at log time — survives the day being renamed/deleted
    var cycleNumber: Int
    var isDeload: Bool

    @Relationship(deleteRule: .cascade, inverse: \ExerciseLog.session)
    var exerciseLogs: [ExerciseLog] = []

    init(date: Date = .now, day: PhaseDay? = nil, dayLabel: String, cycleNumber: Int, isDeload: Bool = false) {
        self.date = date
        self.day = day
        self.dayLabel = dayLabel
        self.cycleNumber = cycleNumber
        self.isDeload = isDeload
    }

    var totalWeightMoved: Double {
        exerciseLogs.reduce(0) { $0 + $1.totalWeightMoved }
    }
}

@Model
final class ExerciseLog {
    var session: WorkoutSession?
    var exerciseName: String
    var targetReps: [Int]          // the plan used that day
    var order: Int

    @Relationship(deleteRule: .cascade, inverse: \SetLog.exerciseLog)
    var sets: [SetLog] = []

    init(exerciseName: String, targetReps: [Int], order: Int) {
        self.exerciseName = exerciseName
        self.targetReps = targetReps
        self.order = order
    }

    var sortedSets: [SetLog] { sets.sorted { $0.index < $1.index } }

    /// e.g. (6+6+5)*135 + (4+4+3)*145 = 3,890
    var totalWeightMoved: Double {
        sets.reduce(0) { $0 + Double($1.reps) * $1.weight }
    }

    /// "135/135/135/145/145/145" — used to find "best at these same weights".
    var weightsKey: String {
        sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
    }

    var planKey: String { "\(exerciseName)|\(targetReps.map(String.init).joined(separator: "/"))" }
}

@Model
final class SetLog {
    var exerciseLog: ExerciseLog?
    var index: Int
    var weight: Double
    var reps: Int

    init(index: Int, weight: Double, reps: Int) {
        self.index = index
        self.weight = weight
        self.reps = reps
    }
}

// MARK: - Rest-day activity

/// A lightweight, non-lift activity logged on a day off (a walk, a hike,
/// stretching, whatever). Never touches Phase/WorkoutSession — it doesn't
/// advance the split — but counts as a "logged day" for stats/streaks.
@Model
final class RestDayActivity {
    var date: Date
    var name: String
    var distance: Double?          // optional — e.g. miles walked/biked
    var distanceUnit: String = "mi"

    init(date: Date = .now, name: String, distance: Double? = nil, distanceUnit: String = "mi") {
        self.date = date
        self.name = name
        self.distance = distance
        self.distanceUnit = distanceUnit
    }
}

// MARK: - Body weight tracking

@Model
final class BodyWeightEntry {
    var date: Date
    var weight: Double
    init(date: Date = .now, weight: Double) {
        self.date = date
        self.weight = weight
    }
}

// MARK: - Small shared helpers

enum Formatters {
    static func trim(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2f", d).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
    /// Compact numeric date for tight table columns, e.g. "1/5/26".
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()
    /// Unambiguous ISO date for CSV export — the first format ImportEngine
    /// tries, so an exported file round-trips cleanly back through import.
    static let exportDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
