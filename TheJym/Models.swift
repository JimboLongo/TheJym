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
    /// Used to derive the rest-bank earn rate when there's no active Phase
    /// to derive it from a split pattern instead. Changes are logged to
    /// TrainingDaysPerWeekChange so past days keep the rate that was
    /// actually in effect then.
    var trainingDaysPerWeek: Int = 3
    /// Whether the built-in starter exercise library (Bench Press, Back
    /// Squat, etc.) gets seeded into the Exercises tab. Only matters when
    /// the tab is empty — turning this off after exercises already exist
    /// doesn't remove them, it just stops them from being reseeded if the
    /// tab is ever emptied out again (e.g. via Delete All Exercises).
    var includeDefaultExercises: Bool = true

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
         hasDumbbell25Attachment: Bool = false) {
        self.trainingStartDate = trainingStartDate
        self.aiAssistantEnabled = aiAssistantEnabled
        self.aiAggressivenessRaw = aiAggressiveness.rawValue
        self.deloadWeeksEnabled = deloadWeeksEnabled
        self.useGeminiForPhasePlanning = useGeminiForPhasePlanning
        self.geminiAPIKey = geminiAPIKey
        self.availablePlateSizes = availablePlateSizes
        self.hasDumbbell125Attachment = hasDumbbell125Attachment
        self.hasDumbbell25Attachment = hasDumbbell25Attachment
    }
}

// MARK: - Equipment (bars + dumbbell sets, for the plate calculator)

@Model
final class Bar {
    var name: String
    var weight: Double              // bar weight; unused (0) for a dumbbell set
    var isDumbbell: Bool = false
    var dumbbellWeights: [Double] = []   // the individual dumbbell weights you own, when isDumbbell
    var loadableSides: Int = 2      // 1 or 2 — sides of THIS bar you can load plates on

    init(name: String, weight: Double, isDumbbell: Bool = false, dumbbellWeights: [Double] = [], loadableSides: Int = 2) {
        self.name = name
        self.weight = weight
        self.isDumbbell = isDumbbell
        self.dumbbellWeights = dumbbellWeights
        self.loadableSides = loadableSides
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
    /// Saved rep-total targets, e.g. [30, 40] — the repTotal-goal counterpart
    /// to repSchemes, for exercises like Pull-Up where a saved "set" is a
    /// single running total instead of a fixed rep scheme.
    var repTotalTargets: [Int] = []
    /// Default for new plan slots created from this exercise (e.g. Pull-Up,
    /// Dip) — still overridable per PlannedExercise.
    var isBodyweight: Bool = false

    init(name: String, notes: String = "",
         equipment: Bar? = nil, repSchemes: [[Int]] = [], repTotalTargets: [Int] = [],
         isBodyweight: Bool = false) {
        self.name = name
        self.notes = notes
        self.equipment = equipment
        self.repSchemes = repSchemes
        self.repTotalTargets = repTotalTargets
        self.isBodyweight = isBodyweight
    }

    /// Adds `reps` as a saved set if it isn't already present.
    func addRepScheme(_ reps: [Int]) {
        guard !reps.isEmpty, !repSchemes.contains(reps) else { return }
        repSchemes.append(reps)
    }

    /// Adds `target` as a saved rep-total if it isn't already present.
    func addRepTotalTarget(_ target: Int) {
        guard target > 0, !repTotalTargets.contains(target) else { return }
        repTotalTargets.append(target)
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

    /// The number of training days in one full pass of the cycle.
    var trainingDaysPerCycle: Int { trainingDays.count }

    // MARK: - Slot-based cycle tracking
    //
    // Each cycle has one "slot" per PhaseDay in trainingDays (in order).
    // Logging a session for a training day fills its slot for whichever
    // cycle is currently in progress; logging another session for a day
    // whose slot this cycle is already filled doesn't fill anything or
    // advance the cycle — it's a "bonus" session (still real history, still
    // counted for pace comparisons and the rest-bank streak, just not for
    // cycle progression). Always recomputed fresh from `sessions` rather
    // than trusting any stored flag, so edits/backdating a session's date
    // can't leave the cycle state stale.

    private struct CycleWalkResult {
        var currentCycle: Int
        var completedCycles: Int
        var filledSlotIDs: Set<PersistentIdentifier>
    }

    private var cycleWalk: CycleWalkResult {
        let slots = trainingDays
        guard !slots.isEmpty else {
            return CycleWalkResult(currentCycle: 1, completedCycles: 0, filledSlotIDs: [])
        }
        let relevant = sessions
            .filter { $0.day != nil && $0.day!.isRest == false }
            .sorted { $0.date < $1.date }

        var filled: Set<PersistentIdentifier> = []
        var completedCycles = 0
        for session in relevant {
            guard let dayID = session.day?.persistentModelID else { continue }
            if filled.contains(dayID) { continue }   // bonus — already filled this cycle
            filled.insert(dayID)
            if filled.count == slots.count {
                completedCycles += 1
                filled = []
            }
        }
        return CycleWalkResult(currentCycle: min(totalCycles, completedCycles + 1),
                               completedCycles: completedCycles,
                               filledSlotIDs: filled)
    }

    /// True if `day`'s slot for the cycle currently in progress is already
    /// filled — logging another session for it right now would be a bonus
    /// session rather than filling a slot.
    func isSlotFilled(for day: PhaseDay) -> Bool {
        cycleWalk.filledSlotIDs.contains(day.persistentModelID)
    }

    /// Total slots filled across all history (bonus sessions don't count) —
    /// a monotonic progress counter, same role the old raw session count
    /// played, just slot-aware now.
    var filledSlotCount: Int {
        cycleWalk.completedCycles * trainingDaysPerCycle + cycleWalk.filledSlotIDs.count
    }

    /// Current cycle number (1-based), based on how many full cycles' worth
    /// of slots have been filled.
    var currentCycle: Int { cycleWalk.currentCycle }

    /// The first not-yet-filled training day slot in the cycle currently in
    /// progress, in pattern order — the day you're "supposed" to do next.
    var nextDay: PhaseDay? {
        let filled = cycleWalk.filledSlotIDs
        return trainingDays.first { !filled.contains($0.persistentModelID) }
    }

    var isComplete: Bool {
        cycleWalk.completedCycles >= totalCycles
    }

    /// This phase's own rest-bank earn rate, derived from its split pattern
    /// (e.g. Push/Pull/Legs/Rest -> 1 rest day / 3 training days -> ~0.33).
    var restBankEarnRate: Double {
        let rest = orderedDays.count - trainingDaysPerCycle
        return StatsEngine.earnRate(restDays: rest, trainingDays: trainingDaysPerCycle)
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

// MARK: - Goal types
//
// An exercise's goal is either a fixed set/rep scheme (the original, still-
// default behavior) or a single rep-total target reached over however many
// sets it takes. Shared by PlannedExercise and ExerciseLog; stored on each
// @Model as decomposed raw fields (goalKindRaw/repTotalTarget) — matching
// this codebase's existing convention for storing enums in SwiftData
// (see AIAggressiveness/AppSettings) — with `goalType` as the computed
// get/set wrapper callers actually use.

enum GoalType: Codable, Equatable {
    case fixedSets
    case repTotal(target: Int)
}

/// One exercise slot inside a specific PhaseDay's plan.
@Model
final class PlannedExercise {
    var day: PhaseDay?
    var order: Int
    var exerciseName: String
    var targetReps: [Int]          // e.g. [5,5,5,3,3,3] — user can override; unused (empty) for repTotal
    var suggestedWeights: [Double] // per-set suggestion (AI or manual); empty = none yet. For a
                                    // bodyweight exercise these represent ADDED weight, not total load.
    var isBodyweight: Bool = false
    var goalKindRaw: Int = 0       // 0 = fixedSets, 1 = repTotal
    var repTotalTarget: Int = 0    // meaningful only when goalKindRaw == 1
    /// repTotal only: which direction AI progression bumps when the target
    /// is reached quickly enough — added weight (default) or the rep total
    /// itself.
    var repTotalProgressesReps: Bool = false

    init(order: Int, exerciseName: String,
         targetReps: [Int], suggestedWeights: [Double] = [],
         isBodyweight: Bool = false, goalType: GoalType = .fixedSets,
         repTotalProgressesReps: Bool = false) {
        self.order = order
        self.exerciseName = exerciseName
        self.targetReps = targetReps
        self.suggestedWeights = suggestedWeights
        self.isBodyweight = isBodyweight
        self.repTotalProgressesReps = repTotalProgressesReps
        switch goalType {
        case .fixedSets:
            self.goalKindRaw = 0
        case .repTotal(let target):
            self.goalKindRaw = 1
            self.repTotalTarget = target
        }
    }

    var goalType: GoalType {
        get { goalKindRaw == 1 ? .repTotal(target: repTotalTarget) : .fixedSets }
        set {
            switch newValue {
            case .fixedSets:
                goalKindRaw = 0
            case .repTotal(let target):
                goalKindRaw = 1
                repTotalTarget = target
            }
        }
    }

    /// Stable key for "same plan" comparisons: name + target rep scheme (or,
    /// for repTotal, name + the total target — e.g. "Farmer's Carry|40 total").
    var planKey: String {
        switch goalType {
        case .fixedSets:
            return "\(exerciseName)|\(targetReps.map(String.init).joined(separator: "/"))"
        case .repTotal(let target):
            return "\(exerciseName)|\(target) total"
        }
    }

    /// How this exercise's target reads wherever a plain rep scheme would
    /// otherwise show (e.g. "8/8/8") — "N Total" for a repTotal exercise
    /// instead, since it has no fixed per-set scheme to join.
    var setsSummaryText: String {
        switch goalType {
        case .fixedSets:
            return targetReps.map(String.init).joined(separator: "/")
        case .repTotal(let target):
            return "\(target) Total"
        }
    }
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
    /// Set at creation time if this training day's slot for its cycle was
    /// already filled — still real history (shows in History, pace
    /// comparisons, and streak credit), just didn't advance the cycle.
    /// Cycle math itself never trusts this after the fact (Phase.cycleWalk
    /// always recomputes from scratch); this is a display-only snapshot.
    var isBonusSession: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ExerciseLog.session)
    var exerciseLogs: [ExerciseLog] = []

    init(date: Date = .now, day: PhaseDay? = nil, dayLabel: String, cycleNumber: Int,
         isDeload: Bool = false, isBonusSession: Bool = false) {
        self.date = date
        self.day = day
        self.dayLabel = dayLabel
        self.cycleNumber = cycleNumber
        self.isDeload = isDeload
        self.isBonusSession = isBonusSession
    }

    var totalWeightMoved: Double {
        exerciseLogs.reduce(0) { $0 + $1.totalWeightMoved }
    }
}

@Model
final class ExerciseLog {
    var session: WorkoutSession?
    var exerciseName: String
    var targetReps: [Int]          // the plan used that day; empty for repTotal
    var order: Int
    var isBodyweight: Bool = false
    var goalKindRaw: Int = 0       // 0 = fixedSets, 1 = repTotal
    var repTotalTarget: Int = 0    // meaningful only when goalKindRaw == 1

    @Relationship(deleteRule: .cascade, inverse: \SetLog.exerciseLog)
    var sets: [SetLog] = []

    init(exerciseName: String, targetReps: [Int], order: Int,
         isBodyweight: Bool = false, goalType: GoalType = .fixedSets) {
        self.exerciseName = exerciseName
        self.targetReps = targetReps
        self.order = order
        self.isBodyweight = isBodyweight
        switch goalType {
        case .fixedSets:
            self.goalKindRaw = 0
        case .repTotal(let target):
            self.goalKindRaw = 1
            self.repTotalTarget = target
        }
    }

    var goalType: GoalType {
        get { goalKindRaw == 1 ? .repTotal(target: repTotalTarget) : .fixedSets }
        set {
            switch newValue {
            case .fixedSets:
                goalKindRaw = 0
            case .repTotal(let target):
                goalKindRaw = 1
                repTotalTarget = target
            }
        }
    }

    var sortedSets: [SetLog] { sets.sorted { $0.index < $1.index } }

    /// e.g. (6+6+5)*135 + (4+4+3)*145 = 3,890. Uses `weight`, which for a
    /// bodyweight set already holds the resolved effective weight
    /// (bodyweight + added, frozen at log time) — never re-derived later.
    var totalWeightMoved: Double {
        sets.reduce(0) { $0 + Double($1.reps) * $1.weight }
    }

    /// "135/135/135/145/145/145" — used to find "best at these same
    /// weights". For a bodyweight exercise, uses the ADDED-weight sequence
    /// instead (e.g. "BW+0/BW+0/BW+0") so sessions match across bodyweight
    /// changes rather than across the (constantly shifting) resolved total.
    var weightsKey: String {
        if isBodyweight {
            return sortedSets.map { "BW+\(Formatters.trim($0.addedWeight ?? 0))" }.joined(separator: "/")
        }
        return sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
    }

    /// "Farmer's Carry|40 total" for repTotal, matching PlannedExercise.planKey.
    var planKey: String {
        switch goalType {
        case .fixedSets:
            return "\(exerciseName)|\(targetReps.map(String.init).joined(separator: "/"))"
        case .repTotal(let target):
            return "\(exerciseName)|\(target) total"
        }
    }

    /// How this exercise's target reads wherever a plain rep scheme would
    /// otherwise show (e.g. "8/8/8") — "N Total" for a repTotal exercise
    /// instead, since it has no fixed per-set scheme to join.
    var setsSummaryText: String {
        switch goalType {
        case .fixedSets:
            return targetReps.map(String.init).joined(separator: "/")
        case .repTotal(let target):
            return "\(target) Total"
        }
    }

    /// repTotal only: total reps logged so far across all sets.
    var repTotalSoFar: Int { sets.reduce(0) { $0 + $1.reps } }

    /// repTotal only: did this session actually reach its target? Past logs
    /// that didn't (an interrupted/incomplete session) fall back to a
    /// total-weight-moved comparison instead of sets-to-complete, since
    /// "sets to complete" isn't meaningful for a session that never finished.
    var repTotalReached: Bool {
        guard case .repTotal(let target) = goalType else { return false }
        return repTotalSoFar >= target
    }
}

@Model
final class SetLog {
    var exerciseLog: ExerciseLog?
    var index: Int
    /// The effective weight moved: for a normal set, the literal weight
    /// lifted (unchanged); for a bodyweight set, the resolved total
    /// (bodyweightAtLog + addedWeight), frozen at log time — used everywhere
    /// (totalWeightMoved, pace math) exactly like a normal weight, so none
    /// of that code needs to know or care a set was bodyweight-based.
    var weight: Double
    var reps: Int
    /// Bodyweight sets only — the added load beyond bodyweight (e.g. a
    /// weighted-vest/dip-belt add-on, or negative for an assisted variant).
    var addedWeight: Double?
    /// Bodyweight sets only — the resolved BodyWeightEntry as of the
    /// session's date. Frozen forever once logged; never re-resolved even if
    /// later BodyWeightEntry edits would change what "as of that date" means.
    var bodyweightAtLog: Double?

    init(index: Int, weight: Double, reps: Int, addedWeight: Double? = nil, bodyweightAtLog: Double? = nil) {
        self.index = index
        self.weight = weight
        self.reps = reps
        self.addedWeight = addedWeight
        self.bodyweightAtLog = bodyweightAtLog
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

// MARK: - Active recovery (rest-bank streak credit only)

enum ActiveRecoveryType: Int, Codable, CaseIterable, Identifiable {
    case walk = 0
    case cardio = 1
    case mobility = 2

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .walk: return "Walk"
        case .cardio: return "Cardio"
        case .mobility: return "Mobility"
        }
    }
}

/// A logged "did something active today" entry that credits the rest-bank
/// streak (see StatsEngine.computeRestBank) without touching workout history
/// or pace comparisons — deliberately separate from RestDayActivity, which
/// is a richer, named/timed log tied to a Phase's Rest day.
@Model
final class ActiveRecovery {
    var date: Date
    var typeRaw: Int

    var type: ActiveRecoveryType {
        get { ActiveRecoveryType(rawValue: typeRaw) ?? .walk }
        set { typeRaw = newValue.rawValue }
    }

    init(date: Date = .now, type: ActiveRecoveryType) {
        self.date = date
        self.typeRaw = type.rawValue
    }
}

/// Logs when the "Training days per week" setting changes, so the rest-bank
/// engine can apply the rate that was actually in effect on each historical
/// day instead of recomputing the past with today's value.
@Model
final class TrainingDaysPerWeekChange {
    var date: Date
    var trainingDaysPerWeek: Int

    init(date: Date = .now, trainingDaysPerWeek: Int) {
        self.date = date
        self.trainingDaysPerWeek = trainingDaysPerWeek
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
    /// Full weekday name alone, e.g. "Sunday" — first line of the workout
    /// log's two-line date button.
    static let weekdayFull: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
    /// Abbreviated month + day + year, e.g. "Jul 26, 2026" — second line of
    /// the workout log's two-line date button.
    static let shortMonthDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
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
