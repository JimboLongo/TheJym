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

    var aiAggressiveness: AIAggressiveness {
        get { AIAggressiveness(rawValue: aiAggressivenessRaw) ?? .moderate }
        set { aiAggressivenessRaw = newValue.rawValue }
    }

    init(trainingStartDate: Date = .now,
         aiAssistantEnabled: Bool = true,
         aiAggressiveness: AIAggressiveness = .moderate,
         deloadWeeksEnabled: Bool = false,
         useGeminiForPhasePlanning: Bool = false,
         geminiAPIKey: String = "",
         availablePlateSizes: [Double] = [45, 35, 25, 10, 5, 2.5, 1.25]) {
        self.trainingStartDate = trainingStartDate
        self.aiAssistantEnabled = aiAssistantEnabled
        self.aiAggressivenessRaw = aiAggressiveness.rawValue
        self.deloadWeeksEnabled = deloadWeeksEnabled
        self.useGeminiForPhasePlanning = useGeminiForPhasePlanning
        self.geminiAPIKey = geminiAPIKey
        self.availablePlateSizes = availablePlateSizes
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

/// A persistent, user-managed exercise definition: name, default rep scheme,
/// tagged equipment, and notes. Lives independently of any Phase — Phase Setup
/// picks from these, and the exercise's history spans every phase it's used in.
///
/// The same name can have multiple rep-scheme *variants* — "Back Squat"
/// 8/8/8 and "Back Squat" 6/8/10 are two distinct ExerciseDef rows, each
/// independently tagged and each with its own history.
@Model
final class ExerciseDef {
    var name: String
    var targetReps: [Int]          // default rep scheme, e.g. [5,5,5,3,3,3]
    var isLowerBody: Bool          // used by progression engine for jump sizes
    var notes: String = ""
    var equipment: Bar?

    init(name: String, targetReps: [Int] = [8, 8, 8], isLowerBody: Bool = false,
         notes: String = "", equipment: Bar? = nil) {
        self.name = name
        self.targetReps = targetReps
        self.isLowerBody = isLowerBody
        self.notes = notes
        self.equipment = equipment
    }

    /// Identifies a specific name + rep-scheme variant, e.g. "Back Squat|8/8/8".
    var variantKey: String { "\(name)|\(targetReps.map(String.init).joined(separator: "/"))" }

    /// Groups a list of definitions by name, sorted alphabetically, with each
    /// name's variants sorted by rep scheme — shared by the Exercises tab and
    /// Phase Setup's exercise picker.
    static func grouped(_ defs: [ExerciseDef]) -> [(name: String, variants: [ExerciseDef])] {
        let byName = Dictionary(grouping: defs, by: \.name)
        return byName.keys.sorted().map { name in
            (name, byName[name]!.sorted { $0.targetReps.lexicographicallyPrecedes($1.targetReps) })
        }
    }

    /// Creates a new variant (name + rep scheme) if this exact combination
    /// doesn't exist yet. Used by Phase Setup, where the rep scheme is
    /// meaningful (a real target, not just a log of what happened).
    static func ensureVariantExists(name: String, targetReps: [Int], isLowerBody: Bool = false,
                                    knownVariantKeys: inout Set<String>, context: ModelContext) {
        let key = "\(name)|\(targetReps.map(String.init).joined(separator: "/"))"
        guard !knownVariantKeys.contains(key) else { return }
        context.insert(ExerciseDef(name: name, targetReps: targetReps, isLowerBody: isLowerBody))
        knownVariantKeys.insert(key)
    }

    /// Creates a bare entry for `name` only if no variant of it exists yet —
    /// used where there's no meaningful target rep scheme (a CSV import or a
    /// manually back-filled historical workout just logs what happened).
    static func ensureAnyVariantExists(name: String, knownNames: inout Set<String>, context: ModelContext) {
        guard !knownNames.contains(name) else { return }
        context.insert(ExerciseDef(name: name))
        knownNames.insert(name)
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

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSession.phase)
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

    /// Every planned exercise across every day — used by AI phase planning to
    /// look up an exercise's isLowerBody flag by name.
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
    var isLowerBody: Bool

    init(order: Int, exerciseName: String,
         targetReps: [Int], suggestedWeights: [Double] = [], isLowerBody: Bool = false) {
        self.order = order
        self.exerciseName = exerciseName
        self.targetReps = targetReps
        self.suggestedWeights = suggestedWeights
        self.isLowerBody = isLowerBody
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

    init(date: Date = .now, name: String) {
        self.date = date
        self.name = name
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
}
