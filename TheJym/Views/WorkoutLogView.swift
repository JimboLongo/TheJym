//
//  WorkoutLogView.swift
//  TheJym
//
//  Log a session. For each exercise, shows the three comparison workouts
//  (Previous Workout / Best at Weights / All-Time Best) with dates, totals,
//  and the reps you need next set to stay on pace to beat each. Once every
//  set in an exercise is logged, it auto-collapses to a compact summary
//  (tap to reopen and edit). On finish, the AI Assistant suggests
//  next-cycle weights (overridable). In-progress data survives leaving the
//  view or closing the app — it's persisted to disk on every change and
//  restored next time this exact phase/day/cycle is opened.
//

import SwiftUI
import SwiftData
import UIKit
import Combine

struct WorkoutLogView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [AppSettings]
    @Query private var allExerciseLogs: [ExerciseLog]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \BodyWeightEntry.date) private var allBodyWeights: [BodyWeightEntry]

    /// Nil for a standalone "quick workout" not tied to any Phase — cycle/
    /// deload math and next-cycle weight suggestions just don't apply then.
    let phase: Phase?
    let day: PhaseDay

    @State private var drafts: [ExerciseDraft] = []
    @State private var showRecapSheet = false
    @State private var recapEntries: [RecapEntry] = []
    @State private var recapChoices: [String: Bool] = [:]
    @State private var currentPageID: String?
    @State private var showExerciseJumpList = false
    /// The calendar day this workout will be saved under — defaults to
    /// today, confirmed/changed via a date picker shown when finishing.
    @State private var loggedDate = Date()
    @State private var showDatePicker = false
    /// Shown after date confirmation, before saving, only if a bodyweight
    /// exercise was logged with sets and no BodyWeightEntry exists yet for
    /// that date to resolve its effective weight against.
    @State private var showBodyWeightPrompt = false
    @State private var bodyWeightPromptText = ""
    /// Last time the user touched anything in this workout — used to keep
    /// the screen from auto-locking for up to 3 minutes of idle time.
    @State private var lastInteraction = Date()

    private var settings: AppSettings? { settingsList.first }
    private var isDeloadCycle: Bool {
        guard let phase else { return false }
        return settings?.deloadWeeksEnabled == true && phase.deloadCycle == phase.currentCycle
    }

    /// This day's planned exercises, in order — works whether or not the day
    /// belongs to a Phase (a standalone "quick workout" day has phase nil).
    private func plannedExercises(for day: PhaseDay) -> [PlannedExercise] {
        day.plannedExercises.sorted { $0.order < $1.order }
    }

    /// Most recent BodyWeightEntry on or before `date` — used to resolve a
    /// bodyweight exercise's effective weight. Nil if none exists yet.
    private func resolvedBodyweight(asOf date: Date) -> Double? {
        allBodyWeights.last { $0.date <= date }?.weight
    }

    /// Live approximation (today's date) for the "BW + n -> lb" hint shown
    /// while logging — the actual save resolves against `loggedDate` instead.
    private var currentBodyweight: Double? { resolvedBodyweight(asOf: Date()) }

    /// True if a bodyweight exercise has logged sets but there's no
    /// BodyWeightEntry on or before `loggedDate` to resolve them against —
    /// the save flow needs to prompt for one before finishing.
    private var needsBodyWeightPrompt: Bool {
        guard resolvedBodyweight(asOf: loggedDate) == nil else { return false }
        return drafts.contains { $0.isBodyweight && $0.sets.contains(where: \.isLogged) }
    }

    // MARK: Draft state — Codable so in-progress work can be persisted to disk.

    struct SetDraft: Identifiable, Codable, Equatable {
        var id = UUID()
        var weightText: String
        var repsText: String
        var weight: Double? { Double(weightText) }
        var reps: Int? { Int(repsText) }
        var isLogged: Bool { weight != nil && reps != nil }
    }

    struct ExerciseDraft: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        var targetReps: [Int]      // empty for repTotal
        var sets: [SetDraft]
        /// False once every set is logged and it's auto-collapsed to a summary.
        var isExpanded: Bool = true
        /// False after the user manually reopens a collapsed exercise, so it
        /// won't auto-collapse again until they close it themselves.
        var autoCollapseEnabled: Bool = true
        /// Notes / plate-calculator panel toggle, lifted up here (instead of
        /// local view state) so the sticky section header can drive it too.
        var showingDetails: Bool = false
        var goalType: GoalType = .fixedSets
        /// When true, each set's weightText holds ADDED weight (not total
        /// load) — the resolved effective weight is only computed at save
        /// time against a BodyWeightEntry.
        var isBodyweight: Bool = false
        /// Effective total weight moved so far. For a bodyweight exercise,
        /// each set's weight is ADDED weight — resolve it against `bodyweight`
        /// (nil if not yet known) to get the real per-rep load.
        func loggedTotal(bodyweight: Double? = nil) -> Double {
            sets.reduce(0) { total, s in
                guard let reps = s.reps, let w = s.weight else { return total }
                let effective = isBodyweight ? w + (bodyweight ?? 0) : w
                return total + Double(reps) * effective
            }
        }
        /// repTotal only: running total reps logged across all sets so far.
        var repTotalSoFar: Int {
            sets.reduce(0) { $0 + ($1.reps ?? 0) }
        }
    }

    struct RecapEntry: Identifiable {
        let id = UUID()
        var exerciseName: String
        /// Prior best total to compare against — nil if never logged before.
        var previousTotal: Double?
        var todayTotal: Double
        var streak: Int
        var requiredStreak: Int
        /// Non-nil only when suggestNextWeights proposes a change from what
        /// was actually lifted today (a jump if higher, a drop if lower).
        var suggestion: [Double]?
        var currentWeights: [Double]
    }

    /// One page in the paging ScrollView: either a single active exercise,
    /// or the shared summary page that all completed exercises collapse
    /// into once they're done (see item 8 — "move completed onto one screen").
    private enum WorkoutPage: Identifiable {
        case exercise(Int)
        case completedSummary
        var id: String {
            switch self {
            case .exercise(let i): return "exercise-\(i)"
            case .completedSummary: return "summary"
            }
        }
    }

    /// Active (still-expanded) exercises each get their own page, in plan
    /// order; the completed-exercises summary is always the trailing page
    /// (even with nothing completed yet), so the workout's finish/save
    /// action always has a permanent home to swipe to.
    private var pages: [WorkoutPage] {
        var result: [WorkoutPage] = drafts.indices.filter { drafts[$0].isExpanded }.map { .exercise($0) }
        result.append(.completedSummary)
        return result
    }

    private func pageID(for draft: ExerciseDraft) -> String {
        draft.isExpanded ? "ex-\(draft.id)" : "summary"
    }

    var body: some View {
        let plateSizes = settings?.availablePlateSizes ?? PlateCalculator.defaultPlates
        let dumbbellIncrement = settings?.dumbbellRoundingIncrement ?? 5
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { page in
                        Group {
                            switch page {
                            case .exercise(let i):
                                ExercisePageView(draft: $drafts[i], allLogs: allExerciseLogs,
                                                exerciseDef: exerciseDefs.first { $0.name == drafts[i].name },
                                                plateSizes: plateSizes, dumbbellIncrement: dumbbellIncrement,
                                                pageHeight: geo.size.height, currentBodyweight: currentBodyweight,
                                                currentPageID: $currentPageID)
                                    .id("ex-\(drafts[i].id)")
                            case .completedSummary:
                                CompletedSummaryPageView(drafts: $drafts, pageHeight: geo.size.height,
                                                        currentPageID: $currentPageID,
                                                        onFinish: { showDatePicker = true })
                                    .id("summary")
                            }
                        }
                        .frame(height: geo.size.height)
                        .clipped()
                    }
                }
                .scrollTargetLayout()
            }
            // .always caps each swipe to moving one page, regardless of
            // flick velocity — plain .paging can otherwise skip a page on a
            // strong swipe.
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $currentPageID, anchor: .top)
            .refreshable {
                refreshDrafts()
            }
        }
        .safeAreaInset(edge: .top) {
            if isDeloadCycle {
                Label("Deload cycle — weights below are cut to ~60% to dissipate fatigue before the next block. Go light, move well, recover.",
                      systemImage: "arrow.down.heart")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
            }
        }
        .overlay {
            // A centered popup card (not a bottom sheet) so it reads as a
            // deliberate confirmation step in the middle of the screen.
            if showDatePicker {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { showDatePicker = false }
                    VStack(spacing: 16) {
                        Text("Log this workout to:")
                            .font(.headline)
                        DatePicker("Log workout to", selection: $loggedDate,
                                  in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        HStack {
                            Button("Cancel") { showDatePicker = false }
                            Spacer()
                            Button {
                                showDatePicker = false
                                if needsBodyWeightPrompt {
                                    bodyWeightPromptText = currentBodyweight.map(Formatters.trim) ?? ""
                                    showBodyWeightPrompt = true
                                } else {
                                    finishWorkout()
                                }
                            } label: {
                                Text("Save Workout").font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(32)
                    .shadow(radius: 20)
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if showBodyWeightPrompt {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("What's your body weight today?")
                            .font(.headline)
                        Text("Needed to resolve the load for a bodyweight exercise you logged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        TextField("Body weight (lb)", text: $bodyWeightPromptText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                        HStack {
                            Button("Cancel") { showBodyWeightPrompt = false }
                            Spacer()
                            Button {
                                if let w = Double(bodyWeightPromptText), w > 0 {
                                    context.insert(BodyWeightEntry(date: loggedDate, weight: w))
                                }
                                showBodyWeightPrompt = false
                                finishWorkout()
                            } label: {
                                Text("Continue").font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(Double(bodyWeightPromptText) == nil)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(32)
                    .shadow(radius: 20)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDatePicker)
        .animation(.easeInOut(duration: 0.2), value: showBodyWeightPrompt)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 6) {
                    Text(phase.map { "\(day.name) · Cycle \($0.currentCycle)" } ?? day.name)
                        .font(.headline)
                    if drafts.count > 1 {
                        Button {
                            showExerciseJumpList = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Jump to Exercise…")
                                    .font(.headline)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                        }
                        // A native Menu's UIMenu backing drops strikethrough
                        // and custom colors on its items, so completed
                        // exercises couldn't actually look struck-through —
                        // a real List in a popover renders Text styling
                        // normally, since it's not translated through UIKit's
                        // menu system.
                        .popover(isPresented: $showExerciseJumpList) {
                            // A plain VStack (not List) so there are no row
                            // separators and everything's sized to fit — no
                            // internal scrolling — matching the compact look
                            // the native Menu had, minus its style stripping.
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(drafts) { draft in
                                    Button {
                                        withAnimation { currentPageID = pageID(for: draft) }
                                        showExerciseJumpList = false
                                    } label: {
                                        Text(draft.name)
                                            .font(.subheadline)
                                            .strikethrough(!draft.isExpanded)
                                            .foregroundStyle(draft.isExpanded ? .primary : .secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .presentationCompactAdaptation(.popover)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 220)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            buildDrafts()
            UIApplication.shared.isIdleTimerDisabled = true
            lastInteraction = Date()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            // Keep the screen awake for up to 3 minutes of idle time (e.g.
            // resting between sets); let it lock normally after that.
            UIApplication.shared.isIdleTimerDisabled = Date().timeIntervalSince(lastInteraction) < 180
        }
        .onChange(of: drafts) { _, _ in
            lastInteraction = Date()
            saveDraftToDisk()
        }
        .sheet(isPresented: $showRecapSheet, onDismiss: { dismiss() }) {
            WorkoutRecapView(entries: recapEntries, choices: $recapChoices) { applyRecapChoices() }
        }
    }

    // MARK: Setup

    /// This exercise's logs, same plan key, any phase (progression looks at
    /// your whole training history, not just the current block). Excludes
    /// bonus sessions (an extra session logged after that cycle's slot for
    /// the day was already filled) so the AI progression math still sees
    /// exactly one log per cycle per exercise, same as before slots existed.
    private func history(for pe: PlannedExercise) -> [ExerciseLog] {
        allExerciseLogs
            .filter { $0.planKey == pe.planKey && !$0.sets.isEmpty
                     && $0.session?.isDeload != true && $0.session?.isBonusSession != true }
            .sorted { ($0.session?.date ?? .distantPast) < ($1.session?.date ?? .distantPast) }
    }

    /// Finest weight jump achievable for this exercise's equipment — the
    /// standard 2.5 lb for barbell/plate work, or a finer dumbbell increment
    /// if the matching attachment is on hand.
    private func roundingIncrement(for exerciseName: String) -> Double {
        guard let def = exerciseDefs.first(where: { $0.name == exerciseName }),
              def.equipment?.isDumbbell == true
        else { return 2.5 }
        return settings?.dumbbellRoundingIncrement ?? 5
    }

    private func buildDrafts() {
        guard drafts.isEmpty else { return }
        if let saved = loadDraftFromDisk(), !saved.isEmpty {
            drafts = saved
            return
        }

        let aiOn = settings?.aiAssistantEnabled == true
        let agg = settings?.aiAggressiveness ?? .moderate

        for pe in plannedExercises(for: day) {
            let logs = history(for: pe)
            let increment = roundingIncrement(for: pe.exerciseName)

            switch pe.goalType {
            case .fixedSets:
                // AI on: what the AI Assistant thinks is the right goal from history.
                // AI off: exactly what was lifted last time. For a bodyweight
                // exercise, every weight here is ADDED weight, not total load.
                var weights = aiOn
                    ? (ProgressionEngine.suggestNextWeights(targetReps: pe.targetReps, history: logs,
                                                            aggressiveness: agg, roundingIncrement: increment,
                                                            isBodyweight: pe.isBodyweight)
                       ?? pe.suggestedWeights)
                    : (logs.last?.sortedSets.map { pe.isBodyweight ? ($0.addedWeight ?? 0) : $0.weight }
                       ?? pe.suggestedWeights)
                if isDeloadCycle, !weights.isEmpty {
                    weights = ProgressionEngine.deloadWeights(from: weights)
                }
                let sets = pe.targetReps.enumerated().map { i, _ in
                    SetDraft(weightText: i < weights.count ? Formatters.trim(weights[i]) : "",
                             repsText: "")
                }
                drafts.append(ExerciseDraft(name: pe.exerciseName,
                                            targetReps: pe.targetReps,
                                            sets: sets,
                                            goalType: .fixedSets,
                                            isBodyweight: pe.isBodyweight))

            case .repTotal(let target):
                var effectiveTarget = target
                var startWeight = pe.suggestedWeights.first ?? 0
                if aiOn, let suggestion = ProgressionEngine.suggestRepTotalProgression(
                    history: logs, aggressiveness: agg, progressesReps: pe.repTotalProgressesReps,
                    roundingIncrement: increment) {
                    if let newTarget = suggestion.newTarget { effectiveTarget = newTarget }
                    if let newWeight = suggestion.newAddedWeight { startWeight = newWeight }
                } else if !aiOn, let lastSet = logs.last?.sortedSets.last {
                    startWeight = pe.isBodyweight ? (lastSet.addedWeight ?? 0) : lastSet.weight
                }
                if isDeloadCycle, startWeight > 0 {
                    startWeight = ProgressionEngine.deloadWeights(from: [startWeight]).first ?? startWeight
                }
                let sets = [SetDraft(weightText: Formatters.trim(startWeight), repsText: "")]
                drafts.append(ExerciseDraft(name: pe.exerciseName,
                                            targetReps: [],
                                            sets: sets,
                                            goalType: .repTotal(target: effectiveTarget),
                                            isBodyweight: pe.isBodyweight))
            }
        }
    }

    /// Pull-to-refresh: re-pulls suggested/last-time weights from history for
    /// any exercise that hasn't been started yet (no set with a logged rep),
    /// so a change made in the History tab while this workout was open
    /// (edited a past log, corrected a weight, etc.) is picked up without
    /// losing anything already entered. An exercise with any rep already
    /// logged is left completely alone — its weights aren't second-guessed
    /// mid-set.
    private func refreshDrafts() {
        let aiOn = settings?.aiAssistantEnabled == true
        let agg = settings?.aiAggressiveness ?? .moderate

        for idx in drafts.indices {
            guard !drafts[idx].sets.contains(where: { $0.reps != nil }) else { continue }
            guard let pe = plannedExercises(for: day).first(where: { $0.exerciseName == drafts[idx].name }) else { continue }
            let logs = history(for: pe)
            let increment = roundingIncrement(for: pe.exerciseName)

            switch drafts[idx].goalType {
            case .fixedSets:
                var weights = aiOn
                    ? (ProgressionEngine.suggestNextWeights(targetReps: pe.targetReps, history: logs,
                                                            aggressiveness: agg, roundingIncrement: increment,
                                                            isBodyweight: pe.isBodyweight)
                       ?? pe.suggestedWeights)
                    : (logs.last?.sortedSets.map { pe.isBodyweight ? ($0.addedWeight ?? 0) : $0.weight }
                       ?? pe.suggestedWeights)
                if isDeloadCycle, !weights.isEmpty {
                    weights = ProgressionEngine.deloadWeights(from: weights)
                }
                for i in drafts[idx].sets.indices where i < weights.count {
                    drafts[idx].sets[i].weightText = Formatters.trim(weights[i])
                }

            case .repTotal:
                var startWeight = pe.suggestedWeights.first ?? 0
                var effectiveTarget: Int? = nil
                if aiOn, let suggestion = ProgressionEngine.suggestRepTotalProgression(
                    history: logs, aggressiveness: agg, progressesReps: pe.repTotalProgressesReps,
                    roundingIncrement: increment) {
                    if let newTarget = suggestion.newTarget { effectiveTarget = newTarget }
                    if let newWeight = suggestion.newAddedWeight { startWeight = newWeight }
                } else if !aiOn, let lastSet = logs.last?.sortedSets.last {
                    startWeight = pe.isBodyweight ? (lastSet.addedWeight ?? 0) : lastSet.weight
                }
                if isDeloadCycle, startWeight > 0 {
                    startWeight = ProgressionEngine.deloadWeights(from: [startWeight]).first ?? startWeight
                }
                if !drafts[idx].sets.isEmpty {
                    drafts[idx].sets[0].weightText = Formatters.trim(startWeight)
                }
                if let effectiveTarget {
                    drafts[idx].goalType = .repTotal(target: effectiveTarget)
                }
            }
        }
    }

    // MARK: Draft persistence (survives tab switches / app close)

    private var draftStorageKey: String {
        guard let phase else { return "workoutDraft_quick_\(day.name)" }
        return "workoutDraft_\(phase.number)_\(day.name)_\(phase.currentCycle)"
    }

    private func saveDraftToDisk() {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: draftStorageKey)
    }

    private func loadDraftFromDisk() -> [ExerciseDraft]? {
        guard let data = UserDefaults.standard.data(forKey: draftStorageKey) else { return nil }
        return try? JSONDecoder().decode([ExerciseDraft].self, from: data)
    }

    private func clearSavedDraft() {
        UserDefaults.standard.removeObject(forKey: draftStorageKey)
    }

    // MARK: Saving + AI

    private func finishWorkout() {
        // Must be read BEFORE the new session is linked to the phase, since
        // it reflects slot-fill state as of right now.
        let isBonus = !day.isRest && (phase?.isSlotFilled(for: day) ?? false)
        let session = WorkoutSession(date: loggedDate, day: day, dayLabel: day.name,
                                     cycleNumber: phase?.currentCycle ?? 0,
                                     isDeload: isDeloadCycle, isBonusSession: isBonus)
        session.phase = phase
        context.insert(session)

        let agg = settings?.aiAggressiveness ?? .moderate
        var entries: [RecapEntry] = []
        // Resolved once per save, against the confirmed log date — a BW set
        // logged just now (or the prompt above) may have just created the
        // entry this depends on.
        let bodyweight = resolvedBodyweight(asOf: loggedDate)

        for (order, d) in drafts.enumerated() {
            let logged = d.sets.filter(\.isLogged)
            guard !logged.isEmpty else { continue }

            let pe = plannedExercises(for: day).first { $0.exerciseName == d.name }
            let priorLogs = pe.map(history) ?? []

            let log = ExerciseLog(exerciseName: d.name, targetReps: d.targetReps, order: order,
                                  isBodyweight: d.isBodyweight, goalType: d.goalType)
            log.session = session
            context.insert(log)
            for (i, s) in logged.enumerated() {
                let addedWeight = s.weight ?? 0
                let set: SetLog
                if d.isBodyweight {
                    set = SetLog(index: i, weight: addedWeight + (bodyweight ?? 0), reps: s.reps ?? 0,
                                 addedWeight: addedWeight, bodyweightAtLog: bodyweight)
                } else {
                    set = SetLog(index: i, weight: addedWeight, reps: s.reps ?? 0)
                }
                set.exerciseLog = log
                context.insert(set)
            }

            // Recap + next-cycle progression — skip during a deload (weights
            // are intentionally cut, so progression math doesn't apply) or
            // once the phase is over (no next cycle to jump into). A
            // standalone quick workout has no phase, so it's never "over".
            guard !isDeloadCycle, !(phase?.isComplete ?? false) else { continue }
            let increment = roundingIncrement(for: d.name)
            let combinedHistory = priorLogs + [log]

            switch d.goalType {
            case .fixedSets:
                let streak = ProgressionEngine.currentStreak(targetReps: d.targetReps, history: combinedHistory)
                let suggestion = ProgressionEngine.suggestNextWeights(
                    targetReps: d.targetReps, history: combinedHistory,
                    aggressiveness: agg, roundingIncrement: increment, isBodyweight: d.isBodyweight)
                let currentWeights = log.sortedSets.map { d.isBodyweight ? ($0.addedWeight ?? 0) : $0.weight }
                entries.append(RecapEntry(exerciseName: d.name,
                                          previousTotal: priorLogs.last?.totalWeightMoved,
                                          todayTotal: log.totalWeightMoved,
                                          streak: streak,
                                          requiredStreak: ProgressionEngine.requiredStreak(for: agg),
                                          suggestion: (suggestion != currentWeights) ? suggestion : nil,
                                          currentWeights: currentWeights))

            case .repTotal:
                // repTotal progression is applied automatically (no interactive
                // recap step for this goal type) — mirrors suggestion straight
                // onto the plan for next cycle.
                if let pe, let suggestion = ProgressionEngine.suggestRepTotalProgression(
                    history: combinedHistory, aggressiveness: agg,
                    progressesReps: pe.repTotalProgressesReps, roundingIncrement: increment) {
                    if let newTarget = suggestion.newTarget {
                        pe.goalType = .repTotal(target: newTarget)
                    }
                    if let newWeight = suggestion.newAddedWeight {
                        pe.suggestedWeights = [newWeight]
                    }
                }
            }
        }
        try? context.save()
        clearSavedDraft()

        if !entries.isEmpty {
            recapEntries = entries
            // Default to accepting the suggested jump/drop — matches the
            // app's existing "AI suggestion applied unless overridden" pattern.
            recapChoices = Dictionary(uniqueKeysWithValues: entries.map { ($0.exerciseName, true) })
            showRecapSheet = true
        } else {
            dismiss()
        }
    }

    private func applyRecapChoices() {
        for entry in recapEntries {
            guard let suggestion = entry.suggestion, recapChoices[entry.exerciseName] == true,
                  let pe = plannedExercises(for: day).first(where: { $0.exerciseName == entry.exerciseName }) else { continue }
            pe.suggestedWeights = suggestion
        }
        try? context.save()
    }
}

// MARK: - One exercise's logging card + pace panel

struct ExercisePageView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bar.name) private var allBars: [Bar]

    @Binding var draft: WorkoutLogView.ExerciseDraft
    let allLogs: [ExerciseLog]
    let exerciseDef: ExerciseDef?
    let plateSizes: [Double]
    let dumbbellIncrement: Double
    /// Full available height for this one exercise's "page" — everything
    /// from the name down through the pace panel must fit inside it so a
    /// vertical swipe moves cleanly to the next exercise instead of scrolling.
    let pageHeight: CGFloat
    /// Most recent BodyWeightEntry resolved as of today — used for the live
    /// "BW + n -> lb" hint shown next to the stepper while logging a
    /// bodyweight exercise. The actual save resolves against the confirmed
    /// log date instead, which may differ from this approximation.
    let currentBodyweight: Double?
    /// Redirected to the shared completed-exercises page when this one
    /// collapses (manually or via the delayed auto-collapse), since its own
    /// page disappears from the paging list at that point.
    @Binding var currentPageID: String?

    @State private var plateTargetText = ""
    @State private var showAddEquipmentSheet = false
    /// Sets a later set's weight was just shifted by via cascade, so the
    /// field can flash a "+10"/"-5" badge before fading out.
    @State private var cascadeIndicator: [Int: Double] = [:]
    /// Bumped on every checkAutoCollapse call so a stale, already-scheduled
    /// 5-second auto-collapse (from a set that's since been un-logged, or
    /// superseded by a newer completion) doesn't fire.
    @State private var collapseGeneration = 0
    /// Live horizontal drag offset for "swipe the target into reps", per set.
    @State private var targetDragOffset: [Int: CGFloat] = [:]
    /// True briefly over the reps wheel right after a successful swipe-copy,
    /// to show a little burst drawing attention to the update.
    @State private var repsExplosion: [Int: Bool] = [:]
    /// +/- flash badge for a swipe-copy into reps, mirroring the weight
    /// cascade indicator's look.
    @State private var repsDeltaIndicator: [Int: Int] = [:]

    private var comparisons: [ComparisonTarget] {
        PaceEngine.comparisons(for: draft.name,
                               targetReps: draft.targetReps,
                               currentWeights: draft.sets.map { $0.weight ?? 0 },
                               isBodyweight: draft.isBodyweight,
                               allLogs: allLogs)
    }
    private func repTotalComparisons(target: Int) -> [PaceEngine.RepTotalComparisonTarget] {
        let weightsKey = draft.isBodyweight
            ? draft.sets.map { "BW+\(Formatters.trim($0.weight ?? 0))" }.joined(separator: "/")
            : draft.sets.map { Formatters.trim($0.weight ?? 0) }.joined(separator: "/")
        return PaceEngine.repTotalComparisons(for: draft.name, target: target,
                                              currentWeightsKey: weightsKey, allLogs: allLogs)
    }
    /// Weights for sets not yet logged (reps missing), using entered weight or 0.
    private var remainingWeights: [Double] {
        draft.sets.filter { $0.reps == nil }.map { $0.weight ?? 0 }
    }
    /// Average weight moved per rep so far this workout — used to translate
    /// a beaten-by/fell-short-by weight delta into an equivalent rep count.
    private var avgWeightPerRep: Double {
        let totalReps = draft.sets.compactMap(\.reps).reduce(0, +)
        guard totalReps > 0 else { return 0 }
        return draft.loggedTotal(bodyweight: currentBodyweight) / Double(totalReps)
    }
    /// The +/- step for this exercise's weight fields: the smallest plate
    /// you own for barbell/plate work, or the finest dumbbell increment
    /// (attachments considered) for a dumbbell exercise.
    private var weightStep: Double {
        guard let bar = exerciseDef?.equipment else { return 2.5 }
        return bar.isDumbbell ? dumbbellIncrement : (plateSizes.min() ?? 2.5)
    }
    /// Selectable values for the inline weight wheel, spaced by weightStep.
    private var weightValues: [Double] {
        Array(stride(from: 0.0, through: 600.0, by: weightStep))
    }
    /// Selectable added-weight values for a bodyweight exercise's wheel —
    /// always 2.5 lb increments regardless of the exercise's equipment.
    private var addedWeightValues: [Double] {
        Array(stride(from: 0.0, through: 200.0, by: 2.5))
    }
    /// Shrinks the weight/reps wheels as needed so all of this exercise's
    /// sets, plus the header and pace panel, fit within one page height.
    private var wheelHeight: CGFloat {
        let chromeHeight: CGFloat = 300   // header + pace panel + paddings, estimated
        let available = pageHeight - chromeHeight
        let setCount = max(draft.sets.count, 1)
        let perSet = available / CGFloat(setCount)
        // Taller floor/ceiling than before so more of the previous/next row
        // peeks through above and below the selected value.
        return min(100, max(60, perSet))
    }
    /// Fixed (not page-height-derived) row height for repTotal sets, since
    /// the set count there is open-ended (grows via "Add Set") rather than
    /// fixed up front — the rows scroll internally instead of being sized to
    /// guarantee everything fits on one screen.
    private let repTotalRowHeight: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if draft.isExpanded {
                if draft.showingDetails {
                    notesAndPlateCalc(exerciseDef)
                }
                switch draft.goalType {
                case .fixedSets:
                    setRows
                case .repTotal:
                    ScrollView {
                        repTotalSetRows
                    }
                    .frame(maxHeight: 260)
                }
            } else {
                currentWorkoutRow
            }

            // Pace panel — always shows all three comparisons; any with no
            // prior data yet just says so instead of being omitted.
            VStack(alignment: .leading, spacing: 6) {
                switch draft.goalType {
                case .fixedSets:
                    ForEach(comparisons) { c in
                        PaceRow(target: c,
                                loggedSoFar: draft.loggedTotal(bodyweight: currentBodyweight),
                                remainingWeights: remainingWeights,
                                avgWeightPerRep: avgWeightPerRep)
                    }
                case .repTotal(let target):
                    ForEach(repTotalComparisons(target: target)) { c in
                        RepTotalPaceRow(target: c,
                                       setsLoggedSoFar: draft.sets.filter(\.isLogged).count,
                                       loggedTotal: draft.loggedTotal(bodyweight: currentBodyweight))
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(height: pageHeight, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.name)
                    .font(.title2.bold())
                if case .repTotal(let target) = draft.goalType {
                    Text("\(draft.repTotalSoFar)/\(target)")
                        .font(.title3.bold())
                        .foregroundStyle(draft.repTotalSoFar >= target ? .green : .secondary)
                }
                Spacer()
                if draft.isExpanded {
                    Button {
                        withAnimation { draft.showingDetails.toggle() }
                    } label: {
                        Image(systemName: draft.showingDetails ? "chevron.up.circle.fill" : "info.circle")
                    }
                    .buttonStyle(.plain)
                    .imageScale(.large)
                    Button {
                        withAnimation { draft.isExpanded = false; currentPageID = "summary" }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .imageScale(.large)
                } else {
                    Button {
                        // Reopened manually — leave it open until the user closes
                        // it again themselves, don't auto-collapse a second time.
                        withAnimation { draft.isExpanded = true; draft.autoCollapseEnabled = false }
                    } label: {
                        Label("Edit", systemImage: "pencil.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }
            if draft.isExpanded {
                switch draft.goalType {
                case .fixedSets:
                    HStack(spacing: 12) {
                        Text("Set").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text("Weight").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .center)
                        Text("Target").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .center)
                        Text("Reps").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .center)
                        Text("+/-").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .center)
                    }
                    .lineLimit(1)
                case .repTotal:
                    HStack(spacing: 12) {
                        Text("Set").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text("Weight").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .center)
                        Text("Reps").font(.subheadline).foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .center)
                        Spacer()
                    }
                    .lineLimit(1)
                }
            }
        }
    }

    private var setRows: some View {
        VStack(alignment: .leading, spacing: -8) {
            ForEach(Array(draft.sets.enumerated()), id: \.element.id) { i, _ in
                HStack(spacing: 12) {
                    Text("Set \(i + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)

                    weightCell(for: i, height: wheelHeight)

                    if let goal = draft.targetReps[safe: i] {
                        HStack(spacing: 8) {
                            Text("\(goal)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize()
                            Image(systemName: "arrow.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.10, green: 0.24, blue: 0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                        .fixedSize()
                        .frame(minWidth: 54, alignment: .center)
                        .offset(x: targetDragOffset[i] ?? 0)
                        .animation(.interactiveSpring(), value: targetDragOffset[i])
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    // Only follow rightward drags, toward the reps wheel.
                                    targetDragOffset[i] = max(0, value.translation.width)
                                }
                                .onEnded { value in
                                    if value.translation.width > 40 {
                                        let oldReps = draft.sets[i].reps ?? 0
                                        draft.sets[i].repsText = String(goal)
                                        checkAutoCollapse()
                                        let delta = goal - oldReps
                                        if delta != 0 { repsDeltaIndicator[i] = delta }
                                        repsExplosion[i] = true
                                        Task {
                                            try? await Task.sleep(nanoseconds: 500_000_000)
                                            repsExplosion[i] = false
                                        }
                                        Task {
                                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                                            repsDeltaIndicator[i] = nil
                                        }
                                    }
                                    targetDragOffset[i] = 0
                                }
                        )
                    } else {
                        Text("–")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .center)
                    }

                    ZStack(alignment: .top) {
                        Picker("Reps", selection: Binding(
                            get: { draft.sets[i].reps ?? 0 },
                            set: { newValue in
                                draft.sets[i].repsText = String(newValue)
                                checkAutoCollapse()
                            })) {
                            ForEach(0...50, id: \.self) { v in
                                Text("\(v)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(repsExplosion[i] == true ? Color.green : Color.primary)
                                    .tag(v)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100, height: wheelHeight)
                        .clipped()

                        if repsExplosion[i] == true {
                            ExplosionBurst()
                                .frame(width: 100, height: wheelHeight)
                                .allowsHitTesting(false)
                        }
                        if let delta = repsDeltaIndicator[i] {
                            Text(delta > 0 ? "+\(delta)" : "\(delta)")
                                .font(.caption2.bold())
                                .foregroundStyle(delta > 0 ? .green : .red)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.thinMaterial, in: Capsule())
                                .offset(y: -8)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut, value: repsDeltaIndicator[i])

                    if let delta = repsDelta(for: i) {
                        Text(delta > 0 ? "+\(delta)" : "\(delta)")
                            .font(.subheadline.bold())
                            .foregroundStyle(delta >= 0 ? .green : .red)
                            .frame(width: 44, alignment: .center)
                    } else {
                        Text("–")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .center)
                    }
                }
                .animation(.easeInOut, value: cascadeIndicator[i])
            }
        }
    }

    private func cascadeDelta(_ delta: Double, from index: Int) {
        guard delta != 0 else { return }
        var affected: [Int] = [index]
        cascadeIndicator[index] = delta
        for k in (index + 1)..<draft.sets.count {
            guard let existing = draft.sets[k].weight else { continue }
            draft.sets[k].weightText = Formatters.trim(existing + delta)
            cascadeIndicator[k] = delta
            affected.append(k)
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for k in affected { cascadeIndicator.removeValue(forKey: k) }
        }
    }

    /// fixedSets: every set logged. repTotal: the total's been reached and
    /// the last set (the one that pushed it there) is logged.
    private var isReadyToAutoCollapse: Bool {
        switch draft.goalType {
        case .fixedSets:
            return draft.sets.allSatisfy(\.isLogged)
        case .repTotal(let target):
            return (draft.sets.last?.isLogged ?? false) && draft.repTotalSoFar >= target
        }
    }

    /// Only auto-collapses if the exercise hasn't been manually reopened
    /// since the last time it collapsed. Waits 3 seconds before collapsing so
    /// the last entry doesn't vanish out from under you — and bails if
    /// anything's changed (re-opened, un-logged, or superseded) by the time
    /// it fires.
    private func checkAutoCollapse() {
        guard draft.autoCollapseEnabled, isReadyToAutoCollapse else { return }
        collapseGeneration += 1
        let generation = collapseGeneration
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard generation == collapseGeneration,
                  draft.autoCollapseEnabled, isReadyToAutoCollapse else { return }
            withAnimation { draft.isExpanded = false; currentPageID = "summary" }
        }
    }

    /// Shared weight-entry cell for one set — a plate/dumbbell wheel picker
    /// normally, or a "BW + n" added-weight stepper for a bodyweight exercise
    /// (suggested/AI weights already represent added load in that case).
    @ViewBuilder
    private func weightCell(for index: Int, height: CGFloat) -> some View {
        if draft.isBodyweight {
            HStack(spacing: 4) {
                Text(currentBodyweight.map { "\(Formatters.trim($0)) (BW) +" } ?? "BW +")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                ZStack(alignment: .top) {
                    Picker("Added Weight", selection: Binding(
                        get: { nearestValue(draft.sets[index].weight ?? 0, in: addedWeightValues) },
                        set: { newValue in
                            let old = draft.sets[index].weight ?? 0
                            draft.sets[index].weightText = Formatters.trim(newValue)
                            let delta = newValue - old
                            if delta != 0 { cascadeDelta(delta, from: index) }
                        })) {
                        ForEach(addedWeightValues, id: \.self) { v in
                            Text(Formatters.trim(v)).font(.subheadline.weight(.medium)).tag(v)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 60, height: height)
                    .clipped()
                    if let delta = cascadeIndicator[index] {
                        Text(delta > 0 ? "+\(Formatters.trim(delta))" : Formatters.trim(delta))
                            .font(.caption2.bold())
                            .foregroundStyle(delta > 0 ? .green : .red)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.thinMaterial, in: Capsule())
                            .transition(.opacity)
                    }
                }
            }
        } else {
            ZStack(alignment: .top) {
                Picker("Weight", selection: Binding(
                    get: { nearestValue(draft.sets[index].weight ?? 0, in: weightValues) },
                    set: { newValue in
                        let old = draft.sets[index].weight ?? 0
                        draft.sets[index].weightText = Formatters.trim(newValue)
                        let delta = newValue - old
                        if delta != 0 { cascadeDelta(delta, from: index) }
                    })) {
                    ForEach(weightValues, id: \.self) { v in
                        Text(Formatters.trim(v)).font(.subheadline.weight(.medium)).tag(v)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 100, height: height)
                .clipped()
                if let delta = cascadeIndicator[index] {
                    Text(delta > 0 ? "+\(Formatters.trim(delta))" : Formatters.trim(delta))
                        .font(.caption2.bold())
                        .foregroundStyle(delta > 0 ? .green : .red)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.thinMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
        }
    }

    /// repTotal logging: open-ended set list (no fixed target per set) with
    /// an "Add Set" button, and a delete affordance once there's more than
    /// one set (so an accidental extra Add Set isn't a dead end).
    private var repTotalSetRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(draft.sets.enumerated()), id: \.element.id) { i, _ in
                HStack(spacing: 12) {
                    Text("Set \(i + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)

                    weightCell(for: i, height: repTotalRowHeight)

                    ZStack(alignment: .top) {
                        Picker("Reps", selection: Binding(
                            get: { draft.sets[i].reps ?? 0 },
                            set: { newValue in
                                draft.sets[i].repsText = String(newValue)
                                checkAutoCollapse()
                            })) {
                            ForEach(0...50, id: \.self) { v in
                                Text("\(v)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(repsExplosion[i] == true ? Color.green : Color.primary)
                                    .tag(v)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100, height: repTotalRowHeight)
                        .clipped()
                        if repsExplosion[i] == true {
                            ExplosionBurst()
                                .frame(width: 100, height: repTotalRowHeight)
                                .allowsHitTesting(false)
                        }
                    }

                    Spacer()

                    if draft.sets.count > 1 {
                        Button {
                            draft.sets.remove(at: i)
                            checkAutoCollapse()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
            }

            Button {
                let carryWeight = draft.sets.last?.weightText ?? ""
                draft.sets.append(WorkoutLogView.SetDraft(weightText: carryWeight, repsText: ""))
            } label: {
                Label("Add Set", systemImage: "plus.circle.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
    }

    private func nearestValue(_ target: Double, in values: [Double]) -> Double {
        values.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
    }

    /// Actual reps minus goal reps for a set, once reps have been entered —
    /// nil (shown as a dash) until then, so it doesn't default to "-N" for a
    /// set that hasn't been logged yet.
    private func repsDelta(for index: Int) -> Int? {
        guard let reps = draft.sets[index].reps,
              let goal = draft.targetReps[safe: index] else { return nil }
        return reps - goal
    }

    /// Compact summary of today's entered weights/reps, shown once the
    /// exercise auto-collapses (mirrors the historical pace-calc rows).
    private var currentWorkoutRow: some View {
        let weights = draft.sets
            .map { $0.weightText.isEmpty ? "—" : (draft.isBodyweight ? "BW+\($0.weightText)" : $0.weightText) }
            .joined(separator: "/")
        let reps = draft.sets.map { $0.repsText.isEmpty ? "—" : $0.repsText }.joined(separator: "/")
        let totalLine: String? = {
            guard case .repTotal(let target) = draft.goalType else { return nil }
            return "\(draft.repTotalSoFar)/\(target) reps"
        }()

        return VStack(alignment: .leading, spacing: 2) {
            Text("Current Workout").font(.caption.bold())
            if let totalLine {
                Text(totalLine).font(.caption2.bold()).foregroundStyle(.blue)
            }
            Text("\(reps) reps @ \(weights) lbs")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func notesAndPlateCalc(_ def: ExerciseDef?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let def, !def.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(def.notes).font(.subheadline)
                }
            }

            if let bar = def?.equipment {
                if bar.isDumbbell {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dumbbell Match").font(.caption.bold()).foregroundStyle(.secondary)
                        HStack {
                            Text("Target")
                            TextField("lbs", text: $plateTargetText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        .font(.subheadline)

                        if let target = Double(plateTargetText) {
                            if let closest = bar.dumbbellWeights.min(by: { abs($0 - target) < abs($1 - target) }) {
                                Text(closest == target
                                     ? "You have that exact dumbbell: \(Formatters.trim(closest)) lb"
                                     : "Closest you have: \(Formatters.trim(closest)) lb")
                                    .font(.caption)
                                    .foregroundStyle(closest == target ? .green : .orange)
                            } else {
                                Text("No dumbbell weights set for \(bar.name) — add some in Equipment.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plate Calculator").font(.caption.bold()).foregroundStyle(.secondary)
                        HStack {
                            Text("Target")
                            TextField("lbs", text: $plateTargetText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        .font(.subheadline)

                        if let target = Double(plateTargetText) {
                            if let (plates, leftover) = PlateCalculator.plates(target: target, barWeight: bar.weight,
                                                                               available: plateSizes, sides: bar.loadableSides) {
                                if plates.isEmpty && leftover == 0 {
                                    Text("Empty \(Formatters.trim(bar.weight)) lb bar — no plates needed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(plates) { p in
                                    HStack {
                                        Text("\(Formatters.trim(p.plate)) lb plate")
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text(bar.loadableSides == 1 ? "× \(p.countPerSide)" : "× \(p.countPerSide) per side")
                                            .font(.system(.caption, design: .monospaced)).bold()
                                    }
                                }
                                if leftover > 0 {
                                    Text("Can't hit exactly — \(Formatters.trim(leftover)) lbs short.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            } else {
                                Text("Target is lighter than the \(Formatters.trim(bar.weight)) lb bar.")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            } else if let def {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No equipment tagged for this exercise yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(allBars) { bar in
                            Button(bar.name) {
                                def.equipment = bar
                                try? context.save()
                            }
                        }
                        if !allBars.isEmpty { Divider() }
                        Button {
                            showAddEquipmentSheet = true
                        } label: {
                            Label("New Equipment…", systemImage: "plus")
                        }
                    } label: {
                        Label("Quick Add Equipment", systemImage: "plus.circle")
                            .font(.caption.bold())
                    }
                }
                .sheet(isPresented: $showAddEquipmentSheet) {
                    NewEquipmentSheet { bar in
                        def.equipment = bar
                        try? context.save()
                    }
                }
            } else {
                Text("Add this exercise in the Exercises tab to tag equipment for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Quick "add new equipment" sheet, reachable from a workout

struct NewEquipmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var weightText = ""
    @State private var isDumbbell = false
    @State private var loadableSides = 2

    var onSave: (Bar) -> Void

    private var canSave: Bool {
        !name.isEmpty && (isDumbbell || Double(weightText) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name e.g. Trap Bar", text: $name)
                    Toggle("This is a dumbbell set", isOn: $isDumbbell)
                    if !isDumbbell {
                        TextField("Bar weight (lbs)", text: $weightText)
                            .keyboardType(.decimalPad)
                        Picker("Sides", selection: $loadableSides) {
                            Text("1 side").tag(1)
                            Text("2 sides").tag(2)
                        }
                    }
                } footer: {
                    if isDumbbell {
                        Text("Add the individual dumbbell weights you own in the Equipment tab afterward.")
                    }
                }
            }
            .navigationTitle("New Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let bar = Bar(name: name,
                                     weight: isDumbbell ? 0 : (Double(weightText) ?? 0),
                                     isDumbbell: isDumbbell,
                                     loadableSides: loadableSides)
                        context.insert(bar)
                        try? context.save()
                        onSave(bar)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

// MARK: - Little attention-grabbing burst for the swipe-to-copy reps update

struct ExplosionBurst: View {
    @State private var expanded = false

    private let particleCount = 10

    var body: some View {
        ZStack {
            ForEach(0..<particleCount, id: \.self) { i in
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .offset(expanded ? offset(for: i) : .zero)
                    .opacity(expanded ? 0 : 1)
                    .scaleEffect(expanded ? 0.3 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                expanded = true
            }
        }
    }

    private func offset(for index: Int) -> CGSize {
        let angle = (Double(index) / Double(particleCount)) * 2 * .pi
        let radius: Double = 34
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}

// MARK: - repTotal pace row (sets-to-complete, not reps-to-beat)

struct RepTotalPaceRow: View {
    let target: PaceEngine.RepTotalComparisonTarget
    let setsLoggedSoFar: Int
    let loggedTotal: Double

    private var noDataMessage: String {
        switch target.kind {
        case .lastLogged: return "First time logging this exercise — set the baseline. 💪"
        case .bestAtTheseWeights: return "First time at this exact weight — set the baseline. 💪"
        case .bestForExercise: return "No logs yet for this rep total — set the baseline. 💪"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(target.kind.rawValue).font(.caption.bold())
                Spacer()
                if let date = target.date {
                    Text(Formatters.date.string(from: date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if target.hasData {
                Text(target.setsSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                comparisonLine
            } else {
                Text(noDataMessage)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var comparisonLine: some View {
        if let setsToComplete = target.setsToComplete {
            if target.kind == .lastLogged {
                Text("Finished in \(setsToComplete) set\(setsToComplete == 1 ? "" : "s"), first set \(target.firstSetReps ?? 0) reps")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let room = PaceEngine.repTotalPRRoom(setsLoggedSoFar: setsLoggedSoFar, bestSetsToComplete: setsToComplete) {
                Label("Finish in \(room) more set\(room == 1 ? "" : "s") for a PR", systemImage: "target")
                    .font(.caption).foregroundStyle(.orange)
            } else if setsLoggedSoFar >= setsToComplete {
                Label("Matched or beat the \(setsToComplete)-set record 🔥", systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("Best: \(setsToComplete) set\(setsToComplete == 1 ? "" : "s") to finish, first set \(target.firstSetReps ?? 0) reps")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if loggedTotal > target.totalWeightMoved {
            // That log never actually reached its total — the only
            // meaningful comparison left is total weight moved.
            Label("Beaten on total weight moved 🔥", systemImage: "flame.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Text("Unfinished last time — \(Formatters.trim(target.totalWeightMoved)) lbs moved")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PaceRow: View {
    let target: ComparisonTarget
    let loggedSoFar: Double
    let remainingWeights: [Double]
    /// Average weight moved per rep so far — converts a beaten-by/fell-
    /// short-by weight delta into an equivalent whole-rep count.
    let avgWeightPerRep: Double

    /// Whole reps (rounded up — a partial rep still costs you a full one).
    private func repsEquivalent(_ lbsDelta: Double) -> String {
        guard avgWeightPerRep > 0 else { return "0 reps" }
        let reps = max(1, Int(ceil(abs(lbsDelta) / avgWeightPerRep)))
        return "\(reps) rep\(reps == 1 ? "" : "s")"
    }

    /// A human label for what "no data yet" means for this particular kind.
    private var noDataMessage: String {
        switch target.kind {
        case .lastLogged: return "First time logging this exercise — set the baseline. 💪"
        case .bestAtTheseWeights: return "First time at this exact weight — set the baseline. 💪"
        case .bestForExercise: return "No logs yet for this rep scheme — set the baseline. 💪"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(target.kind.rawValue).font(.caption.bold())
                Spacer()
                if let date = target.date {
                    Text(Formatters.date.string(from: date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if target.hasData {
                Text(target.setsSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                loggedComparison
            } else {
                Text(noDataMessage)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var loggedComparison: some View {
        let beaten = loggedSoFar > target.totalWeightMoved
        let paceReps = PaceEngine.repsToClinch(targetTotal: target.totalWeightMoved,
                                               loggedSoFar: loggedSoFar,
                                               nextWeight: remainingWeights.first ?? 0)
        if beaten {
            Label("Beaten by \(repsEquivalent(loggedSoFar - target.totalWeightMoved)) 🔥",
                  systemImage: "flame.fill")
                .font(.caption).foregroundStyle(.green)
        } else if remainingWeights.isEmpty {
            Label("Fell short by \(repsEquivalent(target.totalWeightMoved - loggedSoFar))",
                  systemImage: "arrow.down.right")
                .font(.caption).foregroundStyle(.red)
        } else if let reps = paceReps {
            Label("Need \(reps) reps in your next set to stay on pace",
                  systemImage: "target")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - End-of-workout recap (what you beat, progress to a weight jump,
// and an explicit jump/stay or drop/stay choice per exercise)

struct WorkoutRecapView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [WorkoutLogView.RecapEntry]
    @Binding var choices: [String: Bool]
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    Section(entry.exerciseName) {
                        comparisonLabel(for: entry)

                        if entry.requiredStreak > 0 {
                            LabeledContent("Progress to next weight jump") {
                                Text("\(min(entry.streak, entry.requiredStreak))/\(entry.requiredStreak)")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let suggestion = entry.suggestion {
                            let isJump = (suggestion.first ?? 0) > (entry.currentWeights.first ?? 0)
                            Picker("", selection: Binding(
                                get: { choices[entry.exerciseName] ?? true },
                                set: { choices[entry.exerciseName] = $0 })) {
                                Text(isJump
                                     ? "Jump to \(suggestion.map { Formatters.trim($0) }.joined(separator: "/"))"
                                     : "Drop to \(suggestion.map { Formatters.trim($0) }.joined(separator: "/"))")
                                    .tag(true)
                                Text("Stay at \(entry.currentWeights.map { Formatters.trim($0) }.joined(separator: "/"))")
                                    .tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }
            .navigationTitle("Workout Recap")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(); dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func comparisonLabel(for entry: WorkoutLogView.RecapEntry) -> some View {
        if let previous = entry.previousTotal {
            if entry.todayTotal > previous {
                Label("Beat previous workout (\(Formatters.trim(entry.todayTotal - previous)) lbs more)",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if entry.todayTotal < previous {
                Label("Missed previous workout by \(Formatters.trim(previous - entry.todayTotal)) lbs",
                      systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            } else {
                Label("Tied previous workout", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("First time logging this exercise", systemImage: "star.fill")
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - Completed exercises, gathered onto one shared page

struct CompletedSummaryPageView: View {
    @Binding var drafts: [WorkoutLogView.ExerciseDraft]
    let pageHeight: CGFloat
    @Binding var currentPageID: String?
    /// Called when the finish button here is tapped — starts the date
    /// confirmation step in the parent.
    var onFinish: () -> Void

    private var completedIndices: [Int] {
        drafts.indices.filter { !drafts[$0].isExpanded }
    }
    private var allDone: Bool {
        !drafts.isEmpty && drafts.allSatisfy { !$0.isExpanded }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Completed")
                    .font(.title2.bold())
                if completedIndices.isEmpty {
                    Text("Nothing checked off yet — swipe back to an exercise and finish it, or save now to end the workout early.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(completedIndices, id: \.self) { i in
                        row(for: i)
                    }
                }
            }
            .padding()
            .frame(minHeight: pageHeight, alignment: .top)
        }
        .safeAreaInset(edge: .bottom) {
            if !drafts.isEmpty {
                Button(action: onFinish) {
                    Label(allDone ? "Finish & Save Workout" : "Complete & Save Unfinished Workout",
                          systemImage: allDone ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(allDone ? .accentColor : .orange)
                .padding()
                .background(.bar)
            }
        }
    }

    private func row(for i: Int) -> some View {
        let draft = drafts[i]
        let weights = draft.sets
            .map { $0.weightText.isEmpty ? "—" : (draft.isBodyweight ? "BW+\($0.weightText)" : $0.weightText) }
            .joined(separator: "/")
        let reps = draft.sets.map { $0.repsText.isEmpty ? "—" : $0.repsText }.joined(separator: "/")
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(draft.name).font(.headline)
                Spacer()
                Button {
                    // Reopening moves it back to its own page and out of
                    // this summary — jump there so the transition is clear.
                    withAnimation {
                        drafts[i].isExpanded = true
                        drafts[i].autoCollapseEnabled = false
                        currentPageID = "ex-\(drafts[i].id)"
                    }
                } label: {
                    Label("Edit", systemImage: "pencil.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            if case .repTotal(let target) = draft.goalType {
                Text("\(draft.repTotalSoFar)/\(target) reps")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }
            Text("\(reps) reps @ \(weights) lbs")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
