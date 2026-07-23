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

    var aiAggressiveness: AIAggressiveness {
        get { AIAggressiveness(rawValue: aiAggressivenessRaw) ?? .moderate }
        set { aiAggressivenessRaw = newValue.rawValue }
    }

    init(trainingStartDate: Date = .now,
         aiAssistantEnabled: Bool = true,
         aiAggressiveness: AIAggressiveness = .moderate,
         deloadWeeksEnabled: Bool = false,
         useGeminiForPhasePlanning: Bool = false,
         geminiAPIKey: String = "") {
        self.trainingStartDate = trainingStartDate
        self.aiAssistantEnabled = aiAssistantEnabled
        self.aiAggressivenessRaw = aiAggressiveness.rawValue
        self.deloadWeeksEnabled = deloadWeeksEnabled
        self.useGeminiForPhasePlanning = useGeminiForPhasePlanning
        self.geminiAPIKey = geminiAPIKey
    }
}

// MARK: - Bars (for the plate calculator)

@Model
final class Bar {
    var name: String
    var weight: Double
    init(name: String, weight: Double) {
        self.name = name
        self.weight = weight
    }
}

// MARK: - Exercise library

@Model
final class ExerciseDef {
    @Attribute(.unique) var name: String
    var muscleGroup: String        // e.g. "Chest", "Back", "Quads"
    var dayLetter: String          // which split day it belongs to: "P", "L", etc.
    var isLowerBody: Bool          // used by progression engine for jump sizes
    var defaultTargetReps: [Int]   // suggested sets/reps, e.g. [5,5,5,3,3,3]

    init(name: String, muscleGroup: String, dayLetter: String,
         isLowerBody: Bool = false, defaultTargetReps: [Int] = [8, 8, 8]) {
        self.name = name
        self.muscleGroup = muscleGroup
        self.dayLetter = dayLetter
        self.isLowerBody = isLowerBody
        self.defaultTargetReps = defaultTargetReps
    }
}

// MARK: - Phase / Split

/// A Phase = a split pattern (e.g. "PPLRPPLR") run for N cycles with a fixed
/// set of exercises per day letter. After N cycles, a new Phase begins.
@Model
final class Phase {
    var number: Int                // Phase 1, Phase 2, ...
    var splitPattern: String       // "PPLRPPLR" — "R" is always Rest
    var totalCycles: Int           // e.g. 8
    var startDate: Date
    var isActive: Bool
    /// Cycle index (1-based) that is a deload cycle, or 0 for none.
    var deloadCycle: Int

    @Relationship(deleteRule: .cascade, inverse: \PlannedExercise.phase)
    var plannedExercises: [PlannedExercise] = []

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSession.phase)
    var sessions: [WorkoutSession] = []

    init(number: Int, splitPattern: String, totalCycles: Int,
         startDate: Date = .now, isActive: Bool = true, deloadCycle: Int = 0) {
        self.number = number
        self.splitPattern = splitPattern.uppercased()
        self.totalCycles = totalCycles
        self.startDate = startDate
        self.isActive = isActive
        self.deloadCycle = deloadCycle
    }

    /// Non-rest day letters in order of appearance, e.g. "PPLRPPLR" -> ["P","P","L","P","P","L"] positions.
    var patternLetters: [String] { splitPattern.map { String($0) } }

    /// Distinct training-day letters within one repeat of the split, in order,
    /// disambiguating a reused letter (e.g. "PPLR" is Pull, Push, Legs — a
    /// classic split reuses "P" for two different training days, not one day
    /// twice): "PPLR" -> ["Pull","Push","L"], "PPLRPPLR" -> the same, since it's
    /// just that pattern repeated.
    var distinctTrainingLetters: [String] { Phase.distinctTrainingLetters(for: splitPattern) }

    static func distinctTrainingLetters(for pattern: String) -> [String] {
        let base = pattern.prefix(basePatternLength(of: pattern))
        var counts: [Character: Int] = [:]
        var result: [String] = []
        for ch in base where ch.isLetter && ch != "R" {
            counts[ch, default: 0] += 1
            let n = counts[ch]!
            switch (ch, n) {
            case ("P", 1): result.append("Pull")
            case ("P", 2): result.append("Push")
            default: result.append(n == 1 ? String(ch) : "\(ch)\(n)")
            }
        }
        return result
    }

    /// Length of the smallest repeating unit of `pattern`, e.g. "PPLRPPLR" -> 4
    /// (it's just "PPLR" run twice).
    private static func basePatternLength(of pattern: String) -> Int {
        let chars = Array(pattern)
        let n = chars.count
        guard n > 0 else { return 0 }
        for p in 1...n where n % p == 0 {
            if (0..<n).allSatisfy({ chars[$0] == chars[$0 % p] }) { return p }
        }
        return n
    }

    /// Disambiguated training-day label for each position in the full split
    /// pattern, cycling through `distinctTrainingLetters` in order, e.g.
    /// "PPLRPPLR" -> ["Pull","Push","L","R","Pull","Push","L","R"].
    private var labeledPattern: [String] {
        let labels = distinctTrainingLetters
        guard !labels.isEmpty else { return patternLetters }
        var result: [String] = []
        var i = 0
        for ch in splitPattern {
            if ch == "R" {
                result.append("R")
            } else {
                result.append(labels[i % labels.count])
                i += 1
            }
        }
        return result
    }

    func plan(for letter: String) -> [PlannedExercise] {
        plannedExercises
            .filter { $0.dayLetter == letter }
            .sorted { $0.order < $1.order }
    }

    /// How many completed (non-rest) sessions logged; used to figure out where we are.
    var completedSessionCount: Int { sessions.count }

    /// The number of training days in one full pass of the pattern.
    var trainingDaysPerCycle: Int { patternLetters.filter { $0 != "R" }.count }

    /// Current cycle number (1-based) based on sessions logged.
    var currentCycle: Int {
        guard trainingDaysPerCycle > 0 else { return 1 }
        return min(totalCycles, completedSessionCount / trainingDaysPerCycle + 1)
    }

    /// Index into the pattern's *training* days for the next session (0-based).
    var nextTrainingDayIndex: Int {
        guard trainingDaysPerCycle > 0 else { return 0 }
        return completedSessionCount % trainingDaysPerCycle
    }

    /// The day letter you're "supposed" to do next according to the pattern.
    var nextDayLetter: String {
        let trainingLabels = labeledPattern.filter { $0 != "R" }
        guard !trainingLabels.isEmpty else { return "P" }
        return trainingLabels[nextTrainingDayIndex]
    }

    var isComplete: Bool {
        completedSessionCount >= trainingDaysPerCycle * totalCycles
    }
}

/// One exercise slot inside a Phase's plan for a given day letter.
@Model
final class PlannedExercise {
    var phase: Phase?
    var dayLetter: String
    var order: Int
    var exerciseName: String
    var targetReps: [Int]          // e.g. [5,5,5,3,3,3] — user can override
    var suggestedWeights: [Double] // per-set suggestion (AI or manual); empty = none yet
    var isLowerBody: Bool

    init(dayLetter: String, order: Int, exerciseName: String,
         targetReps: [Int], suggestedWeights: [Double] = [], isLowerBody: Bool = false) {
        self.dayLetter = dayLetter
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
    var dayLetter: String
    var cycleNumber: Int
    var isDeload: Bool

    @Relationship(deleteRule: .cascade, inverse: \ExerciseLog.session)
    var exerciseLogs: [ExerciseLog] = []

    init(date: Date = .now, dayLetter: String, cycleNumber: Int, isDeload: Bool = false) {
        self.date = date
        self.dayLetter = dayLetter
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
