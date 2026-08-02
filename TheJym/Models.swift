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
    /// A local notification reminding you to log a workout or rest day,
    /// scheduled for streakReminderHour each day — but only when nothing's
    /// been logged yet that day (StreakNotificationManager cancels it the
    /// moment something is), so it never fires once the streak's covered.
    var streakRemindersEnabled: Bool = false
    var streakReminderHour: Int = 20   // 24-hour clock, local time
    /// A local notification on Mondays (weight is only ever logged to the
    /// nearest Monday — see BodyWeightView/TodayView) reminding you to log
    /// it — cancelled if you already have that week's entry.
    var weightRemindersEnabled: Bool = false
    var weightReminderHour: Int = 9   // 24-hour clock, local time
    /// Custom auto weight-increase rule — when enabled, replaces the AI
    /// Assistant's aggressiveness-preset jump logic with a flat rule: bump
    /// every set's weight by customWeightIncreaseAmount once every target
    /// rep's been met or beaten customWeightIncreaseStreak sessions in a
    /// row at the same weight.
    var customWeightIncreaseEnabled: Bool = false
    var customWeightIncreaseStreak: Int = 2
    var customWeightIncreaseAmount: Double = 5

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
    @Relationship(deleteRule: .nullify) var equipment: Bar?
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
    /// Grandfather baseline for requiring Rest slots in cycle completion
    /// (see cycleWalk) — the number of cycles this phase already had
    /// training-complete (the old rule, Rest not required) as of the moment
    /// Rest-aware tracking shipped, MINUS one, so the cycle in progress
    /// right then still has to earn its completion under the new rule
    /// rather than being grandfathered in too. nil means not yet stamped;
    /// TheJymApp computes and freezes it once, on launch, for any phase
    /// that doesn't have it yet — including a phase created after this
    /// shipped, which simply freezes at 0 since it has no history to
    /// protect. Frozen for good once set: recomputing it later from
    /// then-current history would keep pulling in cycles the Rest-aware
    /// rule has since correctly completed on its own.
    var legacyCompletedCycles: Int?

    @Relationship(deleteRule: .cascade, inverse: \PhaseDay.phase)
    var days: [PhaseDay] = []

    /// Nullify, not cascade — deleting a Phase should never delete the
    /// workouts logged under it. They stay in History with a blank phase.
    @Relationship(deleteRule: .nullify, inverse: \WorkoutSession.phase)
    var sessions: [WorkoutSession] = []

    init(number: Int, totalCycles: Int,
         startDate: Date = .now, isActive: Bool = true, deloadCycle: Int = 0,
         legacyCompletedCycles: Int? = 0) {
        self.number = number
        self.totalCycles = totalCycles
        self.startDate = startDate
        self.isActive = isActive
        self.deloadCycle = deloadCycle
        self.legacyCompletedCycles = legacyCompletedCycles
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
    // Each cycle has one "slot" per PhaseDay in orderedDays — Rest slots
    // included, so a cycle only completes once every rest day in the
    // template has been explicitly logged too (the plain "Log Rest Day"
    // credit or a rest-day activity, both of which set WorkoutSession.day to
    // that exact Rest PhaseDay), not just its training days. The passive
    // gap-filling credit backfillRestDays/creditYesterdayAsRestIfNothingLogged
    // insert for a day nothing was logged at all deliberately leaves `day`
    // nil, so it never counts toward a rest slot here.
    //
    // `cycleNumber` on each WorkoutSession (see its own doc) is the source
    // of truth for which cycle a session belongs to — set automatically
    // wherever a session is created (live logging, import, gap-fill), an
    // explicit "Cycle" import column, or a manual edit in History — so this
    // walk just GROUPS sessions by that stamped number rather than
    // inferring cycle boundaries from date order. A session whose day's
    // slot is already represented in its cycle's group is a "bonus" simply
    // by virtue of the group being a Set (still real history, still counted
    // for pace comparisons and the rest-bank streak, just not additional
    // cycle progress). legacyCompletedCycles still plays its original role
    // here too: a floor below which this walk never re-verifies a cycle
    // number's completeness, trusting it done regardless of what's actually
    // in that group — those old cycle numbers themselves come from
    // legacyCycleNumbers(), a one-time migration of pre-existing history
    // onto this scheme (see its own doc).

    private struct CycleWalkResult {
        var currentCycle: Int
        var completedCycles: Int
        var filledSlotIDs: Set<PersistentIdentifier>
        var perfectFlags: [Bool]
    }

    /// - Parameter freezeDate: if set, a cycle only counts as *complete* —
    ///   for deciding whether to advance `currentCycle` past it — using
    ///   sessions dated before this instant; a cycle that only becomes
    ///   complete because of a session dated on/after it still shows that
    ///   slot filled (today's own logging shows checked immediately), it
    ///   just doesn't roll the display over to the next cycle yet. Used by
    ///   `displayCycleWalk` to freeze right at the start of today. nil (the
    ///   real `cycleWalk` below) means never freeze.
    private func cycleWalk(freezeDate: Date? = nil) -> CycleWalkResult {
        let slots = orderedDays
        guard !slots.isEmpty else {
            return CycleWalkResult(currentCycle: 1, completedCycles: 0, filledSlotIDs: [], perfectFlags: [])
        }
        let cal = Calendar.current
        let slotCount = slots.count
        let relevant = sessions.filter { $0.day != nil && $0.cycleNumber > 0 }

        var filledByCycle: [Int: Set<PersistentIdentifier>] = [:]
        var filledByCycleBeforeFreeze: [Int: Set<PersistentIdentifier>] = [:]
        // Earliest date each PhaseDay was hit within a given cycle — mirrors
        // the old walk's "bonus session dates don't stretch the perfect-
        // cycle span" rule by only ever looking at each slot's first fill.
        var earliestDateByCycleDay: [Int: [PersistentIdentifier: Date]] = [:]
        for session in relevant {
            guard let dayID = session.day?.persistentModelID else { continue }
            let n = session.cycleNumber
            filledByCycle[n, default: []].insert(dayID)
            if freezeDate == nil || session.date < freezeDate! {
                filledByCycleBeforeFreeze[n, default: []].insert(dayID)
            }
            if let existing = earliestDateByCycleDay[n]?[dayID] {
                if session.date < existing { earliestDateByCycleDay[n]![dayID] = session.date }
            } else {
                earliestDateByCycleDay[n, default: [:]][dayID] = session.date
            }
        }

        // legacyCompletedCycles is a floor below which the walk never
        // re-verifies completeness — those old cycle numbers (assigned by
        // the one-time migration, approximately, from history that
        // predates Rest-aware tracking) are permanently trusted as done
        // regardless of what's actually in their group, same role it
        // played skipping straight past that much history in the old
        // chronological walk.
        let floor = max(1, (legacyCompletedCycles ?? 0) + 1)
        var n = floor
        while n <= totalCycles, (filledByCycleBeforeFreeze[n]?.count ?? 0) >= slotCount { n += 1 }
        let completedCycles = n - 1
        let currentCycle = min(n, totalCycles)
        let filledSlotIDs = filledByCycle[currentCycle] ?? []

        var perfectFlags: [Bool] = []
        for cycle in floor..<n {
            // "Perfect" needs every slot filled (guaranteed here, since only
            // complete cycles are considered) inside a calendar span no
            // wider than the pattern's own length (rest days included) plus
            // one day of slack.
            guard let perDay = earliestDateByCycleDay[cycle],
                  let first = perDay.values.min(), let last = perDay.values.max()
            else { perfectFlags.append(false); continue }
            let span = (cal.dateComponents([.day], from: cal.startOfDay(for: first),
                                           to: cal.startOfDay(for: last)).day ?? 0) + 1
            perfectFlags.append(span <= orderedDays.count + 1)
        }

        return CycleWalkResult(currentCycle: currentCycle, completedCycles: completedCycles,
                               filledSlotIDs: filledSlotIDs, perfectFlags: perfectFlags)
    }

    /// FROZEN, migration-only: replays the OLD date-ordered, slot-filling
    /// algorithm `cycleWalk` used before `WorkoutSession.cycleNumber` became
    /// authoritative, to compute what cycle number each of this phase's
    /// existing sessions would have gotten under that system — used exactly
    /// once by TheJymApp's repairMissingCycleNumbers() migration, so
    /// upgrading to the new grouped walk above doesn't visibly shift
    /// anyone's already-displayed current cycle. Never call this for
    /// anything else, and don't "fix" or modernize it — it exists purely to
    /// reproduce a frozen moment in time.
    func legacyCycleNumbers() -> [PersistentIdentifier: Int] {
        let slots = orderedDays
        guard !slots.isEmpty else { return [:] }
        let relevant = sessions
            .filter { $0.day != nil }
            .sorted { $0.date < $1.date }

        var assignments: [PersistentIdentifier: Int] = [:]

        // Sessions covered by the legacyCompletedCycles floor itself never
        // had precise per-cycle boundaries tracked (that floor is just a
        // count) — approximate them by replaying the same training-days-
        // only pass stampLegacyCompletedCycles() uses to COUNT that floor,
        // assigning an incrementing cycle number as each pass of the
        // training days completes. Matches the app's existing level of
        // precision for that vintage of data (never more precise than "N
        // old-rule passes happened").
        var startIndex = 0
        let legacyTarget = legacyCompletedCycles ?? 0
        if legacyTarget > 0 {
            let trainingSlotIDs = Set(trainingDays.map(\.persistentModelID))
            var legacyFilled: Set<PersistentIdentifier> = []
            var legacyPasses = 0
            for (i, session) in relevant.enumerated() {
                guard let dayID = session.day?.persistentModelID else { continue }
                assignments[session.persistentModelID] = legacyPasses + 1
                guard trainingSlotIDs.contains(dayID), !legacyFilled.contains(dayID) else { continue }
                legacyFilled.insert(dayID)
                guard trainingSlotIDs.isSubset(of: legacyFilled) else { continue }
                legacyPasses += 1
                legacyFilled = []
                if legacyPasses == legacyTarget {
                    startIndex = i + 1
                    break
                }
            }
        }

        var filled: Set<PersistentIdentifier> = []
        var completedCycles = legacyTarget
        for session in relevant[startIndex...] {
            guard let dayID = session.day?.persistentModelID else { continue }
            assignments[session.persistentModelID] = completedCycles + 1
            if filled.contains(dayID) { continue }   // bonus — already filled this cycle
            filled.insert(dayID)
            if filled.count == slots.count {
                completedCycles += 1
                filled = []
            }
        }
        return assignments
    }

    private var cycleWalk: CycleWalkResult { cycleWalk(freezeDate: nil) }

    /// Same walk as `cycleWalk`, but a cycle-completion dated today doesn't
    /// apply yet — its slots still show filled, just without advancing the
    /// cycle number or (on a phase's last cycle) flipping to complete.
    /// Powers TodayView's Phase summary (cycle number, progress bar, slot
    /// checklist, complete-phase swap) so none of it visibly jumps mid-day
    /// the instant the cycle's last slot is filled; it mirrors
    /// TodayView.templateNextDay's same-day carve-out for the featured row
    /// underneath. Everything else — cycleNumber tagging and deload
    /// determination when actually logging a workout, progression math,
    /// pace/stats — keeps using the immediate `cycleWalk` above, since that
    /// data should be correct right away even though the Train tab's
    /// display waits for real midnight.
    private var displayCycleWalk: CycleWalkResult {
        cycleWalk(freezeDate: Calendar.current.startOfDay(for: Date()))
    }

    /// True if `day`'s slot for the cycle currently in progress is already
    /// filled — logging another session for it right now would be a bonus
    /// session rather than filling a slot.
    func isSlotFilled(for day: PhaseDay) -> Bool {
        cycleWalk.filledSlotIDs.contains(day.persistentModelID)
    }

    /// Display-frozen counterpart to `isSlotFilled` — see `displayCycleWalk`.
    func isSlotFilledForDisplay(_ day: PhaseDay) -> Bool {
        displayCycleWalk.filledSlotIDs.contains(day.persistentModelID)
    }

    /// Total slots filled across all history (bonus sessions don't count),
    /// training and Rest both — a monotonic progress counter, same role the
    /// old raw session count played, just slot-aware now.
    var filledSlotCount: Int {
        cycleWalk.completedCycles * orderedDays.count + cycleWalk.filledSlotIDs.count
    }

    /// Display-frozen counterpart to `filledSlotCount` — see `displayCycleWalk`.
    var displayFilledSlotCount: Int {
        displayCycleWalk.completedCycles * orderedDays.count + displayCycleWalk.filledSlotIDs.count
    }

    /// Current cycle number (1-based), based on how many full cycles' worth
    /// of slots have been filled.
    var currentCycle: Int { cycleWalk.currentCycle }

    /// Display-frozen counterpart to `currentCycle` — see `displayCycleWalk`.
    var displayCurrentCycle: Int { displayCycleWalk.currentCycle }

    /// The first not-yet-filled training day slot in the cycle currently in
    /// progress, in pattern order — the day you're "supposed" to do next.
    var nextDay: PhaseDay? {
        let filled = cycleWalk.filledSlotIDs
        return trainingDays.first { !filled.contains($0.persistentModelID) }
    }

    var isComplete: Bool {
        cycleWalk.completedCycles >= totalCycles
    }

    /// Display-frozen counterpart to `isComplete` — see `displayCycleWalk`.
    /// Without this, finishing a phase's very last slot would flip the Train
    /// tab straight to the "Phase Complete" screen mid-day, the same jump
    /// this whole display-frozen family exists to avoid.
    var displayIsComplete: Bool {
        displayCycleWalk.completedCycles >= totalCycles
    }

    /// Whether each completed cycle so far met the "perfect cycle" bar —
    /// see the span check above. Order matches completion order, oldest
    /// first; the cycle currently in progress (not yet complete) isn't
    /// included. Deload cycles aren't special-cased — they're just as
    /// eligible as any other.
    var perfectCycleFlags: [Bool] { cycleWalk.perfectFlags }

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
    /// Which pass of `phase`'s template this session belongs to — the
    /// source of truth for Phase.cycleWalk (grouped by this, not inferred
    /// from date order), History's "Phase X, Cycle Y" header, and
    /// PhasesView's per-cycle exercise history. 0 means "never tagged" —
    /// only legitimate for a session with `day == nil` (manually
    /// back-filled/imported, or a passive gap-fill placeholder), which
    /// never participates in cycle math anyway. Every path that sets `day`
    /// to a real PhaseDay must set this to a real (>= 1) value: live
    /// logging and RestDayLogView use `phase.currentCycle` at the moment of
    /// creation, import auto-computes it (or takes an explicit "Cycle"
    /// column), and it's user-editable afterward in History.
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

    /// Any calendar day (from the earliest logged session through yesterday)
    /// with no session at all gets a no-activity Rest Day entry, so History
    /// never has an unexplained gap. Safe to re-run any time — only fills
    /// days that are still missing. Runs on every app launch
    /// (TheJymApp.ContentView) and right after an import completes, since an
    /// import can introduce gaps (days between logged workouts) that weren't
    /// there before.
    @MainActor
    static func backfillRestDays(context: ModelContext) {
        let allSessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        guard let earliest = allSessions.map(\.date).min() else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var existingDays = Set(allSessions.map { calendar.startOfDay(for: $0.date) })

        var day = calendar.startOfDay(for: earliest)
        while day < today {
            if !existingDays.contains(day) {
                let session = WorkoutSession(date: day, dayLabel: "Rest Day", cycleNumber: 0)
                context.insert(session)
                existingDays.insert(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        try? context.save()
    }

    /// If yesterday — just yesterday, not the whole historical backlog
    /// backfillRestDays covers — has nothing logged at all (no session, no
    /// rest-day activity, no plain rest credit), credits it as a rest day:
    /// the same ActiveRecovery + no-activity session the "Log Rest Day"
    /// button creates live, just applied a day late since it already ended
    /// before the app could prompt for it. This is what makes the cycle
    /// actually rotate past a day you never opened the app for — without
    /// it, a day with nothing logged has no credited day for
    /// TodayView.templateNextDay to advance past. Deliberately scoped to
    /// just yesterday so it doesn't retroactively rewrite rest-bank credit
    /// for older gaps (e.g. from an import) that predate this behavior.
    @MainActor
    static func creditYesterdayAsRestIfNothingLogged(context: ModelContext) {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) else { return }

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        guard !sessions.contains(where: { cal.isDate($0.date, inSameDayAs: yesterday) }) else { return }
        let activeRecoveries = (try? context.fetch(FetchDescriptor<ActiveRecovery>())) ?? []
        guard !activeRecoveries.contains(where: { cal.isDate($0.date, inSameDayAs: yesterday) }) else { return }
        let restActivities = (try? context.fetch(FetchDescriptor<RestDayActivity>())) ?? []
        guard !restActivities.contains(where: { cal.isDate($0.date, inSameDayAs: yesterday) }) else { return }

        context.insert(ActiveRecovery(date: yesterday, type: .rest))
        context.insert(WorkoutSession(date: yesterday, dayLabel: "Rest Day", cycleNumber: 0))
        try? context.save()
    }

    /// A gap-filling placeholder inserted by backfillRestDays /
    /// creditYesterdayAsRestIfNothingLogged for a day nothing was logged
    /// for at all — distinct from an actual scheduled Rest day (which has
    /// `day` set to that PhaseDay) or a logged rest-day activity (which has
    /// its own exercise log). A real workout logged or imported for the
    /// same calendar day should override this placeholder, not coexist
    /// alongside it.
    var isBackfilledRestPlaceholder: Bool {
        day == nil && dayLabel == "Rest Day" && exerciseLogs.isEmpty
    }

    /// Deletes any backfilled rest-day placeholder session on `date` —
    /// called right before inserting a real session (a workout, or a
    /// logged rest-day activity) for that same calendar day, so logging or
    /// importing something for a day assumed missed overrides the
    /// placeholder instead of leaving both around.
    @MainActor
    static func removeBackfilledRestPlaceholder(on date: Date, context: ModelContext) {
        let cal = Calendar.current
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        for session in sessions where cal.isDate(session.date, inSameDayAs: date) && session.isBackfilledRestPlaceholder {
            context.delete(session)
        }
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
    /// Plain "I rested today" credit — no activity of any kind, just a
    /// one-tap way to mark the day as rested for streak purposes.
    case rest = 3

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .walk: return "Walk"
        case .cardio: return "Cardio"
        case .mobility: return "Mobility"
        case .rest: return "Rest"
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
    /// "8:00 PM" for a bare 24-hour-clock hour (0-23) — the streak-reminder
    /// time picker's own values, formatted using the user's locale/12-24hr
    /// preference rather than a hardcoded "20:00" string.
    static func hourLabel(_ hour: Int) -> String {
        let comps = DateComponents(hour: hour, minute: 0)
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
    /// Body weight is tracked weekly, not daily — every entry is dated to
    /// the most recent Monday on or before `date` (today's own Monday if
    /// today IS one, i.e. the start of a Monday-Sunday week), never an
    /// arbitrary day.
    static func nearestPastMonday(from date: Date = .now) -> Date {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)   // 1 = Sunday, 2 = Monday
        let today = cal.startOfDay(for: date)
        let offset = (weekday - 2 + 7) % 7
        return cal.date(byAdding: .day, value: -offset, to: today) ?? today
    }
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
