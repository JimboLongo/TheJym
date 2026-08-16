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
import Charts

/// The medal emoji for a given rank (1 = gold, 2 = silver, 3 = bronze),
/// nil if unranked. See `PaceEngine.medalRank`.
func medalEmoji(_ rank: Int?) -> String? {
    switch rank {
    case 1: return "🥇"
    case 2: return "🥈"
    case 3: return "🥉"
    default: return nil
    }
}

/// Combines a target's base label with a trailing medal emoji, if ranked.
private func labelText(_ base: String, medalRank: Int?, baseFont: Font, baseColor: Color? = nil) -> Text {
    var text = Text(base).font(baseFont)
    if let baseColor {
        text = text.foregroundStyle(baseColor)
    }
    if let emoji = medalEmoji(medalRank) {
        text = text + Text(" \(emoji)")
    }
    return text
}

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
    /// Flipped to .stats once the workout is actually finished and saved —
    /// see MainTab's own doc for why this is threaded down as a binding
    /// rather than reached some other way.
    @Binding var selectedTab: MainTab

    @State private var drafts: [ExerciseDraft] = []
    @State private var showRecapSheet = false
    @State private var recapEntries: [RecapEntry] = []
    @State private var recapChoices: [String: Bool] = [:]
    /// Hand-adjustable per-set weights for each recap entry's suggested
    /// jump/drop — seeded from `RecapEntry.suggestion`, then edited via the
    /// recap's own +/- steppers. What `applyRecapChoices` actually writes
    /// out, not necessarily the original AI suggestion verbatim.
    @State private var recapWeights: [String: [Double]] = [:]
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
    /// Shown on appear instead of silently resuming when a saved draft has
    /// at least one actually-logged set — asks whether to pick up where it
    /// left off or discard it and rebuild fresh (AI-suggested/last-time
    /// weights). A draft that's only ever had its suggested starting
    /// weights auto-filled (nothing logged yet) resumes silently as before.
    @State private var showResumePrompt = false
    /// A second confirmation before Start Fresh actually discards the
    /// already-logged sets — that's a destructive, unrecoverable action, so
    /// it shouldn't fire off one tap on the resume prompt alone.
    @State private var showStartFreshConfirm = false
    /// Last time the user touched anything in this workout — used to keep
    /// the screen from auto-locking for up to 3 minutes of idle time.
    @State private var lastInteraction = Date()
    /// Snapshots of `drafts` from right before each change, oldest first —
    /// lets the toolbar's Undo button step back one input at a time. Capped
    /// so a very long workout doesn't grow this unbounded.
    @State private var undoStack: [[ExerciseDraft]] = []
    /// Set right before restoring a popped snapshot so the resulting
    /// onChange doesn't push that restore back onto the stack as if it
    /// were a new input.
    @State private var isUndoing = false

    private var settings: AppSettings? { settingsList.first }
    private var isDeloadCycle: Bool {
        guard let phase else { return false }
        return settings?.deloadWeeksEnabled == true && phase.deloadCycle == phase.currentCycle
    }
    /// The custom auto weight-increase rule's threshold/amount, only when
    /// the Settings toggle for it is on — nil otherwise, which tells
    /// suggestNextWeights to fall back to the aggressiveness preset.
    private var customIncreaseStreak: Int? {
        settings?.customWeightIncreaseEnabled == true ? settings?.customWeightIncreaseStreak : nil
    }
    private var customIncreaseAmount: Double? {
        settings?.customWeightIncreaseEnabled == true ? settings?.customWeightIncreaseAmount : nil
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
        /// This exercise's own weight step (2.5 for barbell/plate work, or
        /// the dumbbell increment) — the +/- granularity for hand-adjusting
        /// the suggested jump per set in the recap.
        var increment: Double
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
                                                currentPageID: $currentPageID, allDrafts: drafts)
                                    .id("ex-\(drafts[i].id)")
                            case .completedSummary:
                                CompletedSummaryPageView(drafts: $drafts, allLogs: allExerciseLogs,
                                                        currentBodyweight: currentBodyweight,
                                                        pageHeight: geo.size.height,
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
        .overlay {
            if showResumePrompt {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("Resume this workout?")
                            .font(.headline)
                        Text("You have sets already logged from earlier in this workout.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack {
                            Button(role: .destructive) {
                                showStartFreshConfirm = true
                            } label: {
                                Text("Start Fresh")
                            }
                            Spacer()
                            Button {
                                showResumePrompt = false
                                buildDrafts()
                            } label: {
                                Text("Continue").font(.headline)
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
        .animation(.easeInOut(duration: 0.2), value: showDatePicker)
        .animation(.easeInOut(duration: 0.2), value: showBodyWeightPrompt)
        .animation(.easeInOut(duration: 0.2), value: showResumePrompt)
        .confirmationDialog("Are you sure you want to start fresh?", isPresented: $showStartFreshConfirm, titleVisibility: .visible) {
            Button("Start Fresh", role: .destructive) {
                clearSavedDraft()
                showResumePrompt = false
                buildDrafts()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This discards every set already logged in this workout. This can't be undone.")
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .disabled(undoStack.isEmpty)
            }
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
            if drafts.isEmpty {
                if let saved = loadDraftFromDisk(), saved.contains(where: { $0.sets.contains(where: \.isLogged) }) {
                    showResumePrompt = true
                } else {
                    buildDrafts()
                }
            }
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
        .onChange(of: drafts) { oldValue, _ in
            if isUndoing {
                isUndoing = false
            } else {
                undoStack.append(oldValue)
                if undoStack.count > 20 { undoStack.removeFirst() }
            }
            lastInteraction = Date()
            saveDraftToDisk()
        }
        .sheet(isPresented: $showRecapSheet, onDismiss: { selectedTab = .stats; dismiss() }) {
            WorkoutRecapView(entries: recapEntries, choices: $recapChoices, weights: $recapWeights) { applyRecapChoices() }
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
        if var saved = loadDraftFromDisk(), !saved.isEmpty {
            // A draft cached to disk from an in-progress workout can predate
            // a change to the exercise's definition (e.g. just flagged
            // bodyweight) — resync those structural flags from the current
            // PlannedExercise so it doesn't stay stuck showing the old UI,
            // without touching anything already entered.
            for i in saved.indices {
                guard let pe = plannedExercises(for: day).first(where: { $0.exerciseName == saved[i].name }) else { continue }
                saved[i].isBodyweight = pe.isBodyweight
            }
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
                let weights = ProgressionEngine.startingWeights(for: pe, history: logs, aiOn: aiOn,
                                                                 aggressiveness: agg, roundingIncrement: increment,
                                                                 customIncreaseStreak: customIncreaseStreak,
                                                                 customIncreaseAmount: customIncreaseAmount,
                                                                 isDeloadCycle: isDeloadCycle)
                let sets = pe.targetReps.enumerated().map { i, _ in
                    SetDraft(weightText: i < weights.count ? Formatters.trim(weights[i]) : "",
                             repsText: "")
                }
                drafts.append(ExerciseDraft(name: pe.exerciseName,
                                            targetReps: pe.targetReps,
                                            sets: sets,
                                            goalType: .fixedSets,
                                            isBodyweight: pe.isBodyweight))

            case .repTotal:
                let resolved = ProgressionEngine.startingRepTotal(for: pe, history: logs, aiOn: aiOn,
                                                                   aggressiveness: agg, roundingIncrement: increment,
                                                                   customIncreaseAmount: customIncreaseAmount,
                                                                   isDeloadCycle: isDeloadCycle)
                let sets = [SetDraft(weightText: Formatters.trim(resolved.weight), repsText: "")]
                drafts.append(ExerciseDraft(name: pe.exerciseName,
                                            targetReps: [],
                                            sets: sets,
                                            goalType: .repTotal(target: resolved.target),
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
            drafts[idx].isBodyweight = pe.isBodyweight
            let logs = history(for: pe)
            let increment = roundingIncrement(for: pe.exerciseName)

            switch drafts[idx].goalType {
            case .fixedSets:
                let weights = ProgressionEngine.startingWeights(for: pe, history: logs, aiOn: aiOn,
                                                                 aggressiveness: agg, roundingIncrement: increment,
                                                                 customIncreaseStreak: customIncreaseStreak,
                                                                 customIncreaseAmount: customIncreaseAmount,
                                                                 isDeloadCycle: isDeloadCycle)
                for i in drafts[idx].sets.indices where i < weights.count {
                    drafts[idx].sets[i].weightText = Formatters.trim(weights[i])
                }

            case .repTotal:
                let resolved = ProgressionEngine.startingRepTotal(for: pe, history: logs, aiOn: aiOn,
                                                                   aggressiveness: agg, roundingIncrement: increment,
                                                                   customIncreaseAmount: customIncreaseAmount,
                                                                   isDeloadCycle: isDeloadCycle)
                if !drafts[idx].sets.isEmpty {
                    drafts[idx].sets[0].weightText = Formatters.trim(resolved.weight)
                }
                drafts[idx].goalType = .repTotal(target: resolved.target)
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

    /// Steps `drafts` back to the snapshot from right before the most
    /// recent change — undoes the last input (a logged set, a collapse,
    /// whatever changed last), one step at a time.
    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        isUndoing = true
        drafts = previous
    }

    // MARK: Saving + AI

    private func finishWorkout() {
        // Must be read BEFORE the new session is linked to the phase, since
        // it reflects slot-fill state as of right now.
        let isBonus = !day.isRest && (phase?.isSlotFilled(for: day) ?? false)
        // A logged workout overrides a gap-filled "nothing happened" Rest
        // Day placeholder for this same date — they shouldn't coexist.
        WorkoutSession.removeBackfilledRestPlaceholder(on: loggedDate, context: context)
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
                    aggressiveness: agg, roundingIncrement: increment, isBodyweight: d.isBodyweight,
                    customIncreaseStreak: customIncreaseStreak, customIncreaseAmount: customIncreaseAmount)
                let currentWeights = log.sortedSets.map { d.isBodyweight ? ($0.addedWeight ?? 0) : $0.weight }
                entries.append(RecapEntry(exerciseName: d.name,
                                          previousTotal: priorLogs.last?.totalWeightMoved,
                                          todayTotal: log.totalWeightMoved,
                                          streak: streak,
                                          requiredStreak: ProgressionEngine.requiredStreak(for: agg),
                                          suggestion: (suggestion != currentWeights) ? suggestion : nil,
                                          currentWeights: currentWeights,
                                          increment: increment))

            case .repTotal:
                // repTotal progression is applied automatically (no interactive
                // recap step for this goal type) — mirrors suggestion straight
                // onto the plan for next cycle.
                if let pe, let suggestion = ProgressionEngine.suggestRepTotalProgression(
                    history: combinedHistory, aggressiveness: agg,
                    progressesReps: pe.repTotalProgressesReps, roundingIncrement: increment,
                    customIncreaseAmount: customIncreaseAmount) {
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
            recapWeights = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                entry.suggestion.map { (entry.exerciseName, $0) }
            })
            showRecapSheet = true
        } else {
            selectedTab = .stats
            dismiss()
        }
    }

    private func applyRecapChoices() {
        for entry in recapEntries {
            guard entry.suggestion != nil, recapChoices[entry.exerciseName] == true,
                  let weights = recapWeights[entry.exerciseName],
                  let pe = plannedExercises(for: day).first(where: { $0.exerciseName == entry.exerciseName }) else { continue }
            pe.suggestedWeights = weights
        }
        try? context.save()
    }
}

// MARK: - One exercise's logging card + pace panel

struct ExercisePageView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bar.name) private var allBars: [Bar]
    @Query private var settingsList: [AppSettings]
    private var settings: AppSettings? { settingsList.first }

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
    /// Redirected to the next still-open exercise (or the shared completed
    /// page if none remain) when this one collapses — manually or via the
    /// delayed auto-collapse — since its own page disappears from the
    /// paging list at that point.
    @Binding var currentPageID: String?
    /// A read-only snapshot of every exercise in this workout, in plan
    /// order — used only to find the next still-open one to jump to right
    /// after this one collapses (see nextOpenPageID()).
    let allDrafts: [WorkoutLogView.ExerciseDraft]

    @State private var showAddEquipmentSheet = false
    /// Shown from the Warm-Up Sets page's Edit/Add button.
    @State private var showEditNotesSheet = false
    /// Which internal tag of the pace panel's TabView is showing — 1 is the
    /// live pace comparisons (the "real" first page), 2 is previous
    /// workouts, 3 is the plate calculator, 4 is warm-up sets; 0 and 5 are
    /// invisible wraparound decoys (see the TabView's own comment). Starts
    /// at 1, not 0, since 0 is a decoy now.
    @State private var paceTabSelection = 1
    /// Shown when a set number is tapped — every past log of this exercise,
    /// History-tab styled.
    @State private var showFullHistory = false
    /// Non-nil briefly, 2 seconds after every set is logged, if today's
    /// total beat one of the three comparisons — drives the celebration
    /// burst, sized to whichever one it was. Shown together with (and
    /// centered on) `medalPopupRank`, on the same timing — see
    /// `checkCelebrationEffects`.
    @State private var celebrationTier: CelebrationBurst.Tier?
    /// Non-nil briefly, 2 seconds after every set is logged, if today's live
    /// total ranks top-3 for this exercise's plan — drives the big medal
    /// popup. Independent of the 4-second auto-collapse timer itself: this
    /// can pop while the exercise is still open, as soon as it's complete.
    @State private var medalPopupRank: Int?
    /// Guards `checkCelebrationEffects`'s delayed check the same way
    /// `collapseGeneration` guards auto-collapse — bumped on every call so a
    /// stale delayed task from an earlier state doesn't fire after
    /// something's changed.
    @State private var celebrationGeneration = 0

    /// Up to the 3 most recently logged workouts of this exercise (already
    /// saved — the one in progress right now isn't in allLogs yet), most
    /// recent first — all shown together on the pace panel's last page.
    private var previousLogs: [ExerciseLog] {
        Array(allLogs
            .filter { $0.exerciseName == draft.name && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) > ($1.session?.date ?? .distantPast) }
            .prefix(3))
    }

    /// Page 0's content — the live pace comparisons — pulled out into its
    /// own property so it can also back page 4, the invisible wraparound
    /// clone the TabView briefly lands on when swiping right past the last
    /// real page.
    @ViewBuilder
    private var comparisonsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch draft.goalType {
            case .fixedSets:
                ForEach(comparisons) { c in
                    PaceRow(target: c, draft: draft, currentBodyweight: currentBodyweight)
                }
            case .repTotal(let target):
                ForEach(repTotalComparisons(target: target)) { c in
                    RepTotalPaceRow(target: c,
                                   setsLoggedSoFar: draft.sets.filter(\.isLogged).count,
                                   loggedTotal: draft.loggedTotal(bodyweight: currentBodyweight))
                }
            }
        }
        // Without this, a page shorter than the panel's fixed height
        // centers vertically instead of hugging the top like the other
        // pages do.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var previousLogsPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Previous Workouts").font(.caption.bold()).foregroundStyle(.secondary)
            if previousLogs.isEmpty {
                Text("No previous workouts yet.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(previousLogs, id: \.persistentModelID) { log in
                VStack(alignment: .leading, spacing: 2) {
                    if let date = log.session?.date {
                        HStack(spacing: 4) {
                            Text(Formatters.date.string(from: date)).font(.caption2.bold())
                            if let emoji = medalEmoji(PaceEngine.medalRank(for: log, allLogs: allLogs)) {
                                Text(emoji).font(.caption2)
                            }
                        }
                    }
                    SetsGrid(weightLabels: PaceEngine.weightLabels(for: log),
                            repLabels: log.sortedSets.map { String($0.reps) })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// This exercise's full logged history, oldest first — same "any plan
    /// key, just this exercise name" scope `previousLogs` already uses, so
    /// the longitudinal charts below see every session regardless of how
    /// the rep scheme or weights have changed over time.
    private var exerciseHistory: [ExerciseLog] {
        allLogs
            .filter { $0.exerciseName == draft.name && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) < ($1.session?.date ?? .distantPast) }
    }

    /// Every session's value, oldest first, each flagged with whether it
    /// was a new all-time high as of that point (walks history in order,
    /// tracking a running max). `sessionValue` returns nil for a session
    /// with nothing qualifying that day (e.g. no single-rep set logged),
    /// which is simply skipped — it doesn't reset the running max.
    private func valuesWithRecordFlags(sessionValue: (ExerciseLog) -> Double?) -> [(date: Date, value: Double, isRecord: Bool)] {
        var runningMax = -Double.infinity
        var points: [(date: Date, value: Double, isRecord: Bool)] = []
        for log in exerciseHistory {
            guard let date = log.session?.date, let value = sessionValue(log) else { continue }
            let isRecord = value > runningMax
            if isRecord { runningMax = value }
            points.append((date, value, isRecord))
        }
        return points
    }

    /// Every session's total weight moved (Σ reps × weight across every
    /// set that day), flagged for whether it was a new record at the time.
    private var totalWeightMovedOverTime: [(date: Date, value: Double, isRecord: Bool)] {
        valuesWithRecordFlags { $0.totalWeightMoved }
    }

    /// Every session's single best set's total weight moved that day (reps
    /// × weight for just that one set — e.g. 1125 for a 225x5 — not the
    /// heaviest load alone and not summed across every set the way
    /// `totalWeightMovedOverTime` is), flagged for whether it was a new
    /// record at the time.
    private var maxWeightMovedOverTime: [(date: Date, value: Double, isRecord: Bool)] {
        valuesWithRecordFlags { log in
            log.sortedSets.map { $0.weight * Double($0.reps) }.max()
        }
    }

    /// Every session's best calculated 1-rep max that day (Epley: weight ×
    /// (1 + reps/30)), taken across all of that day's sets — the single set
    /// implying the highest 1RM, not necessarily the heaviest set outright
    /// (a lighter set done for more reps can imply a bigger 1RM) — flagged
    /// for whether it was a new record at the time.
    private var oneRepMaxOverTime: [(date: Date, value: Double, isRecord: Bool)] {
        valuesWithRecordFlags { log in
            let best = log.sortedSets.map { $0.weight * (1 + Double($0.reps) / 30.0) }.max() ?? 0
            return best > 0 ? best : nil
        }
    }

    /// Shared layout for the "over time" chart pages — a caption header
    /// plus a chart, or a placeholder until there's enough history (a
    /// single point has nothing to draw a line between). The line runs
    /// through every session (so it still reads as the metric's actual
    /// day-to-day history), but only the sessions that set a new record at
    /// the time get a visible marker AND its value labeled — deliberately
    /// sparse rather than labeling every point on the line, which at any
    /// real amount of history would just turn into an unreadable smear of
    /// overlapping numbers.
    ///
    /// Plotted by SESSION ORDER, not actual calendar date — a real date
    /// axis would waste most of its width on any long dormant stretch
    /// (an injury, an off-season) and could squash a burst of recent
    /// sessions into a sliver at the edge. Every session gets equal
    /// spacing regardless of the calendar gap before it, which both
    /// collapses those dead stretches and guarantees the most recent
    /// session always lands at the right edge — it's simply the last
    /// point, whatever the timeline actually looked like. The axis itself
    /// is hidden since raw session-order numbers aren't meaningful on
    /// their own; the record markers' own value labels are the payoff.
    @ViewBuilder
    private func recordMarkedMetricPage(title: String, valueLabel: String, emptyMessage: String,
                                        points: [(date: Date, value: Double, isRecord: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            if points.count < 2 {
                Text(emptyMessage)
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        LineMark(x: .value("Session", index), y: .value(valueLabel, point.value))
                    }
                    ForEach(Array(points.enumerated()).filter(\.element.isRecord), id: \.offset) { index, point in
                        PointMark(x: .value("Session", index), y: .value(valueLabel, point.value))
                            .annotation(position: .top) {
                                // Rounded for readability — the point's
                                // actual (unrounded) value is still what's
                                // plotted, this is just the label text.
                                Text(Formatters.trim((point.value / 5).rounded() * 5))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var totalWeightMovedPage: some View {
        recordMarkedMetricPage(title: "Total Weight Moved", valueLabel: "Total Weight",
                               emptyMessage: "Log this exercise a few more times to see its total-weight-moved trend over time.",
                               points: totalWeightMovedOverTime)
    }
    private var maxWeightMovedPage: some View {
        recordMarkedMetricPage(title: "Max Weight Moved", valueLabel: "Max Weight",
                               emptyMessage: "Log this exercise a few more times to see its max-weight trend over time.",
                               points: maxWeightMovedOverTime)
    }
    private var oneRepMaxPage: some View {
        recordMarkedMetricPage(title: "1-Rep Max", valueLabel: "1RM",
                               emptyMessage: "Log this exercise a few more times to see its 1-rep max trend over time.",
                               points: oneRepMaxOverTime)
    }

    /// The lightest weight actually usable for this exercise's equipment —
    /// the empty bar for barbell/plate work, or the smallest dumbbell
    /// actually owned — so a suggested warm-up set never asks for less than
    /// what's physically on hand. 0 (no floor) when there's no equipment set.
    private var equipmentMinWeight: Double {
        guard let bar = exerciseDef?.equipment else { return 0 }
        return bar.isDumbbell ? (bar.dumbbellWeights.min() ?? 0) : bar.weight
    }

    /// Suggested warm-up ramp (40/60/80% of today's heaviest entered
    /// working weight, tapering reps down as the weight climbs) — based on
    /// what's actually been typed in for today, not history. Never suggests
    /// less than `equipmentMinWeight` — you can't warm up below the empty
    /// bar (or your lightest dumbbell) regardless of what the percentage
    /// math works out to.
    private var warmupSets: [(weight: Double, reps: Int)] {
        guard let top = uniqueSetWeights.max(), top > 0 else { return [] }
        let scheme: [(pct: Double, reps: Int)] = [(0.4, 8), (0.6, 5), (0.8, 3)]
        let floor = equipmentMinWeight
        return scheme.map { pct, reps in
            let raw = top * pct
            let rounded = (raw / 5).rounded() * 5
            return (max(floor, rounded), reps)
        }
    }

    @ViewBuilder
    private var warmupPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Warm-Up Sets").font(.caption.bold()).foregroundStyle(.secondary)
            if warmupSets.isEmpty {
                Text("Enter today's working weight to see suggested warm-up sets.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(Array(warmupSets.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 12) {
                        Text("Set \(i + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text("\(Formatters.trim(s.weight)) lbs")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("\(s.reps) reps")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            if let def = exerciseDef {
                Divider()
                HStack {
                    Text("Notes").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showEditNotesSheet = true
                    } label: {
                        Label(def.notes.isEmpty ? "Add" : "Edit", systemImage: "pencil")
                            .font(.caption2)
                    }
                }
                if !def.notes.isEmpty {
                    Text(def.notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showEditNotesSheet) {
            NotesEditSheet(initialText: exerciseDef?.notes ?? "") { newText in
                exerciseDef?.notes = newText
                try? context.save()
            }
        }
    }

    /// Distinct, nonzero weights entered across today's sets for this
    /// exercise, ascending — each gets its own plate/dumbbell-match
    /// breakdown on the plate-calculator page, no manual target entry
    /// needed.
    private var uniqueSetWeights: [Double] {
        Array(Set(draft.sets.compactMap(\.weight).filter { $0 > 0 })).sorted()
    }

    /// Current equipment (or "None"), with a menu to switch to any other
    /// owned bar/dumbbell set or add a new one — shown regardless of
    /// whether something's already tagged, so switching equipment doesn't
    /// require leaving the workout for the Exercises tab.
    @ViewBuilder
    private func equipmentSelectorRow(def: ExerciseDef) -> some View {
        HStack(spacing: 6) {
            Text("Equipment").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(allBars) { bar in
                    Button {
                        def.equipment = bar
                        try? context.save()
                    } label: {
                        if def.equipment?.persistentModelID == bar.persistentModelID {
                            Label(bar.name, systemImage: "checkmark")
                        } else {
                            Text(bar.name)
                        }
                    }
                }
                if !allBars.isEmpty { Divider() }
                Button {
                    showAddEquipmentSheet = true
                } label: {
                    Label("New Equipment…", systemImage: "plus")
                }
            } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(def.equipment?.name ?? "None")
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.subheadline.bold())
                    if let weight = def.equipment?.weight, weight > 0 {
                        Text("\(Formatters.trim(weight)) lbs")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var plateCalculatorPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let def = exerciseDef {
                equipmentSelectorRow(def: def)
                if let bar = def.equipment {
                    Text(bar.isDumbbell ? "Dumbbell Match" : "Plate Calculator")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    if uniqueSetWeights.isEmpty {
                        Text("No weights entered yet.").font(.caption2).foregroundStyle(.secondary)
                    } else if bar.isDumbbell {
                        ForEach(uniqueSetWeights, id: \.self) { target in
                            dumbbellMatchRow(bar: bar, target: target)
                        }
                    } else {
                        ForEach(uniqueSetWeights, id: \.self) { target in
                            plateBreakdownRow(bar: bar, target: target)
                        }
                    }
                } else {
                    Text("No equipment tagged yet — pick one above.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Add this exercise in the Exercises tab to tag equipment for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAddEquipmentSheet) {
            NewEquipmentSheet { bar in
                exerciseDef?.equipment = bar
                try? context.save()
            }
        }
    }

    @ViewBuilder
    private func plateBreakdownRow(bar: Bar, target: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(Formatters.trim(target)) lbs").font(.caption.bold())
            if let (plates, leftover) = PlateCalculator.plates(target: target, barWeight: bar.weight,
                                                               available: plateSizes, sides: bar.loadableSides) {
                if plates.isEmpty && leftover == 0 {
                    Text("Empty \(Formatters.trim(bar.weight)) lb bar — no plates needed")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // A separate, right-aligned "per side" column so that word
                // lines up across every plate size regardless of how wide
                // "× N" happens to be — sized to its own content (no
                // Spacer), so it sits right after the count instead of
                // being pushed to the far edge of the box.
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(plates) { p in
                        GridRow {
                            Text("\(Formatters.trim(p.plate)) lb plate")
                                .font(.system(.caption2, design: .monospaced))
                            Text("× \(p.countPerSide)")
                                .font(.system(.caption2, design: .monospaced)).bold()
                            if bar.loadableSides != 1 {
                                Text("per side")
                                    .font(.system(.caption2, design: .monospaced)).bold()
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }
                if leftover > 0 {
                    Text("Can't hit exactly — \(Formatters.trim(leftover)) lbs short.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text("Lighter than the \(Formatters.trim(bar.weight)) lb bar.")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    /// Owned clip-on attachment sizes (1.25 / 2.5 lb), from Settings — lets
    /// the dumbbell match below hit a target between two owned dumbbell
    /// weights instead of only ever reporting the closest bare one.
    private var dumbbellAttachmentSizes: [Double] {
        var sizes: [Double] = []
        if settings?.hasDumbbell125Attachment == true { sizes.append(1.25) }
        if settings?.hasDumbbell25Attachment == true { sizes.append(2.5) }
        return sizes
    }

    private func attachmentSummary(_ attachments: [Double]) -> String {
        var counts: [Double: Int] = [:]
        for a in attachments { counts[a, default: 0] += 1 }
        return counts.sorted { $0.key > $1.key }.map { size, count in
            count == 1 ? "one \(Formatters.trim(size)) lb attachment" : "\(Formatters.trim(size)) lb attachment ×\(count)"
        }.joined(separator: " + ")
    }

    @ViewBuilder
    private func dumbbellMatchRow(bar: Bar, target: Double) -> some View {
        HStack {
            Text("\(Formatters.trim(target)) lbs").font(.caption.bold())
            Spacer()
            if let match = PlateCalculator.dumbbellMatch(target: target, ownedWeights: bar.dumbbellWeights,
                                                         attachmentSizes: dumbbellAttachmentSizes) {
                if match.attachments.isEmpty {
                    Text("Exact match: \(Formatters.trim(match.baseWeight)) lb")
                        .font(.caption2).foregroundStyle(.green)
                } else {
                    Text("\(Formatters.trim(match.baseWeight)) lb + \(attachmentSummary(match.attachments))")
                        .font(.caption2).foregroundStyle(.green)
                }
            } else if let closest = bar.dumbbellWeights.min(by: { abs($0 - target) < abs($1 - target) }) {
                Text("Closest: \(Formatters.trim(closest)) lb")
                    .font(.caption2).foregroundStyle(.orange)
            } else {
                Text("No dumbbell weights set for \(bar.name)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
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
    /// Same format `ExerciseLog.planKey`/`PlannedExercise.planKey` use —
    /// this exercise's plan key, computed from the in-progress draft (which
    /// isn't a saved ExerciseLog yet).
    private var draftPlanKey: String {
        switch draft.goalType {
        case .fixedSets:
            return "\(draft.name)|\(draft.targetReps.map(String.init).joined(separator: "/"))"
        case .repTotal(let target):
            return "\(draft.name)|\(target) total"
        }
    }
    /// Where today's live total would rank (1/2/3, nil below that) among
    /// this exercise's plan history if logged right now — drives the big
    /// medal popup once the exercise is complete. See
    /// `PaceEngine.medalRank(forNewTotal:...)`.
    private var liveMedalRank: Int? {
        let total = draft.loggedTotal(bodyweight: currentBodyweight)
        guard total > 0 else { return nil }
        return PaceEngine.medalRank(forNewTotal: total, exerciseName: draft.name,
                                    planKey: draftPlanKey, allLogs: allLogs)
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
    /// The resolved bodyweight prefix shown once, on its own line right
    /// under the "Weight" header, for a bodyweight exercise (e.g.
    /// "181 (BW) +") — not repeated on every set row.
    private var bodyweightPrefixLabel: String {
        currentBodyweight.map { "\(Formatters.trim($0)) (BW) +" } ?? "BW +"
    }
    private let weightColumnWidth: CGFloat = 100
    /// The pace panel's fixed height — tall enough for the previous-
    /// workouts, plate-calculator, and warm-up pages' typical content to
    /// fit without any of them needing to scroll internally, plus room for
    /// the Pace Calculator page's 3rd (per-set delta) grid row.
    private let pacePanelHeight: CGFloat = 290
    /// The bottom up/down navigation bar's fixed height, including its own
    /// top padding — counted into chromeHeight below so the weight/reps
    /// wheels shrink to leave room for it instead of pushing it off-page.
    private let navBarHeight: CGFloat = 46
    /// Shrinks the weight/reps wheels as needed so all of this exercise's
    /// sets, plus the header and pace panel, fit within one page height.
    private var wheelHeight: CGFloat {
        // header + paddings, estimated, plus the pace panel's own fixed
        // height and some room for its page dots.
        let chromeHeight: CGFloat = 150 + pacePanelHeight + navBarHeight
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
        VStack(alignment: .leading, spacing: 0) {
            header

            // Tight against the header — the wheel pickers below already
            // center their selected value within their own tall frame, so
            // any extra spacing here on top of that just reads as a dead
            // gap between the header and the first row.
            Group {
                if draft.isExpanded {
                    switch draft.goalType {
                    case .fixedSets:
                        setRows
                    case .repTotal:
                        ScrollViewReader { proxy in
                            ScrollView {
                                repTotalSetRows(scrollProxy: proxy)
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                } else {
                    currentWorkoutRow
                }
            }
            // Matches setRows' own internal -8 overlap between rows, so the
            // header-to-first-row transition looks the same as the
            // transition between any two rows below it.
            .padding(.top, -8)

            // Pace panel — 7 real pages (Pace Calculator, Plate Calculator,
            // Previous Workouts, Warm-Up Sets, Total Weight Moved, Max
            // Weight Moved, Estimated 1-Rep Max — the last 3 charting that
            // metric over this exercise's full history), each wrapped with
            // an invisible clone of its opposite neighbor on either side
            // (tags 0 and 8) so swiping past either end lands on a decoy
            // that onChange below silently snaps to the real page right
            // after — reads as wrapping around in both directions instead
            // of dead-ending. Native page dots are off (they'd count all 9
            // internal tags); paceDots below draws exactly 7, mapped from
            // whichever tag is actually showing.
            TabView(selection: $paceTabSelection) {
                oneRepMaxPage.tag(0)        // decoy: swiping back past page 1 lands here
                comparisonsPage.tag(1)      // Pace Calculator (real "page 0")
                plateCalculatorPage.tag(2)
                previousLogsPage.tag(3)
                warmupPage.tag(4)
                totalWeightMovedPage.tag(5)
                maxWeightMovedPage.tag(6)
                oneRepMaxPage.tag(7)
                comparisonsPage.tag(8)      // decoy: swiping forward past page 7 lands here
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: pacePanelHeight)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)
            .overlay(alignment: .bottom) {
                paceDots
            }
            .onChange(of: paceTabSelection) { _, newValue in
                guard newValue == 0 || newValue == 8 else { return }
                let real = newValue == 0 ? 7 : 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { paceTabSelection = real }
                }
            }

            navBar
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(height: pageHeight, alignment: .top)
        .sheet(isPresented: $showFullHistory) {
            ExerciseFullHistoryView(exerciseName: draft.name, allLogs: allLogs)
        }
        .overlay {
            if let tier = celebrationTier {
                CelebrationBurst(tier: tier)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let rank = medalPopupRank, let emoji = medalEmoji(rank) {
                MedalPopup(emoji: emoji)
                    .allowsHitTesting(false)
            }
        }
        // Swiping to (or back to) this exercise from another one resets its
        // pace panel to the Pace Calculator page — a LazyVStack can keep
        // this view's @State alive across a round trip, so without this a
        // revisited exercise could reopen on whatever sub-page it was left
        // on instead of always starting fresh.
        .onChange(of: currentPageID) { _, newValue in
            if newValue == "ex-\(draft.id)" {
                paceTabSelection = 1
            }
        }
    }

    /// 7 dots standing in for the native page indicator (off, since it'd
    /// count all 9 internal tags including the 2 wraparound decoys) — maps
    /// whichever internal tag is showing back to one of the 7 real pages.
    private var paceDots: some View {
        let realPage = ((paceTabSelection - 1) % 7 + 7) % 7
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                Circle()
                    .fill(i == realPage ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.bottom, 4)
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
                        checkCelebrationEffects()
                        withAnimation { collapse() }
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
                VStack(alignment: .leading, spacing: 2) {
                    switch draft.goalType {
                    case .fixedSets:
                        HStack(spacing: 12) {
                            Text("Set").font(.subheadline).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            Text("Weight").font(.subheadline).foregroundStyle(.secondary)
                                .frame(width: weightColumnWidth, alignment: .center)
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
                                .frame(width: weightColumnWidth, alignment: .center)
                            Text("Reps").font(.subheadline).foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .center)
                            Spacer()
                        }
                        .lineLimit(1)
                    }
                    // The resolved bodyweight, shown once right under the
                    // "Weight" header (not repeated on every set row below),
                    // formatted the same as the column labels above it.
                    if draft.isBodyweight {
                        HStack(spacing: 12) {
                            // A plain Text (not Color.clear) so this spacer
                            // hugs the row's natural text height instead of
                            // expanding to fill whatever vertical space is
                            // available, which was stretching the whole row.
                            Text("").font(.subheadline)
                                .frame(width: 44, alignment: .leading)
                            Text(bodyweightPrefixLabel).font(.subheadline).foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: weightColumnWidth, alignment: .center)
                            Spacer()
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    }
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
                        .contentShape(Rectangle())
                        .onTapGesture { showFullHistory = true }

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
    /// since the last time it collapsed. Waits 4 seconds before collapsing so
    /// the last entry doesn't vanish out from under you — and bails if
    /// anything's changed (re-opened, un-logged, or superseded) by the time
    /// it fires. Called from every weight/reps picker on every value change,
    /// so the 4 seconds are measured from the LAST edit, not from whenever
    /// the exercise first became complete — editing a weight or rep again
    /// (even after it was already "done") restarts the countdown.
    private func checkAutoCollapse() {
        checkCelebrationEffects()
        guard draft.autoCollapseEnabled, isReadyToAutoCollapse else { return }
        collapseGeneration += 1
        let generation = collapseGeneration
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard generation == collapseGeneration,
                  draft.autoCollapseEnabled, isReadyToAutoCollapse else { return }
            withAnimation { collapse() }
        }
    }

    /// 2 seconds after every set is logged, if the exercise is complete,
    /// briefly shows the medal popup (today's live total ranks top-3 for
    /// this plan) and the celebration burst (today's total beat one of the
    /// three comparisons — All-Time Best is the biggest, Best at Weights is
    /// medium, just beating Previous Workout is the smallest) together, on
    /// the same timing, centered on each other — independent of
    /// `autoCollapseEnabled` (fires even if the exercise was manually kept
    /// open) and of the 4-second auto-collapse itself.
    private func checkCelebrationEffects() {
        guard isReadyToAutoCollapse else { return }
        celebrationGeneration += 1
        let generation = celebrationGeneration
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard generation == celebrationGeneration, isReadyToAutoCollapse else { return }
            let rank = liveMedalRank
            let tier = bestBeatenTier()
            guard rank != nil || tier != nil else { return }
            withAnimation {
                medalPopupRank = rank
                celebrationTier = tier
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.95) {
                withAnimation {
                    medalPopupRank = nil
                    celebrationTier = nil
                }
            }
        }
    }

    /// Collapses the exercise to its summary and jumps to the next still-open
    /// one. The medal/celebration popups (see `checkCelebrationEffects`) have
    /// already fired 2 seconds earlier and finished well before this runs.
    private func collapse() {
        let target = nextOpenPageID()
        draft.isExpanded = false
        currentPageID = target
    }

    /// The next still-open (not yet completed) exercise to jump to once
    /// this one collapses — the next one after this in plan order, or
    /// wrapping around to the first still-open one before it if this was
    /// the last, or the shared completed page if nothing else is open.
    private func nextOpenPageID() -> String {
        guard let myIndex = allDrafts.firstIndex(where: { $0.id == draft.id }) else { return "summary" }
        let openIndices = allDrafts.indices.filter { $0 != myIndex && allDrafts[$0].isExpanded }
        if let next = openIndices.first(where: { $0 > myIndex }) {
            return "ex-\(allDrafts[next].id)"
        }
        if let wrapped = openIndices.first {
            return "ex-\(allDrafts[wrapped].id)"
        }
        return "summary"
    }

    /// The previous still-open exercise before this one in plan order, for
    /// the navigation bar's up arrow — nil (arrow hidden/disabled) when
    /// this is the first open exercise, since there's nowhere to go back to.
    private func previousOpenPageID() -> String? {
        guard let myIndex = allDrafts.firstIndex(where: { $0.id == draft.id }) else { return nil }
        let openIndices = allDrafts.indices.filter { $0 != myIndex && allDrafts[$0].isExpanded }
        guard let prev = openIndices.last(where: { $0 < myIndex }) else { return nil }
        return "ex-\(allDrafts[prev].id)"
    }

    /// The next still-open exercise after this one in plan order, for the
    /// navigation bar's down arrow — unlike nextOpenPageID() (which wraps
    /// around, meant for auto-advancing on collapse), this always moves
    /// strictly forward, landing on the shared completed page once nothing
    /// else follows.
    private func nextOpenPageIDForNav() -> String {
        guard let myIndex = allDrafts.firstIndex(where: { $0.id == draft.id }) else { return "summary" }
        if let next = allDrafts.indices.first(where: { $0 > myIndex && allDrafts[$0].isExpanded }) {
            return "ex-\(allDrafts[next].id)"
        }
        return "summary"
    }

    /// Bottom bar for jumping directly between exercises — left half moves
    /// up to the previous open exercise, right half moves down to the next
    /// one (or the completed summary page, past the last exercise).
    private var navBar: some View {
        let previous = previousOpenPageID()
        return HStack(spacing: 0) {
            Button {
                if let previous { withAnimation { currentPageID = previous } }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(maxWidth: .infinity)
            }
            .disabled(previous == nil)

            Divider().frame(height: 20)

            Button {
                withAnimation { currentPageID = nextOpenPageIDForNav() }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .font(.body.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 10)
    }

    /// The most prestigious comparison today's total actually beat, if any
    /// — same "beaten" definition PaceRow/RepTotalPaceRow use (today's
    /// resolved total vs. that comparison's), just picking the best one
    /// among however many got beaten instead of showing each individually.
    private func bestBeatenTier() -> CelebrationBurst.Tier? {
        let loggedTotal = draft.loggedTotal(bodyweight: currentBodyweight)
        let beatenKinds: Set<ComparisonTarget.Kind>
        switch draft.goalType {
        case .fixedSets:
            beatenKinds = Set(comparisons
                .filter { $0.hasData && loggedTotal > $0.totalWeightMoved }
                .map(\.kind))
        case .repTotal(let target):
            beatenKinds = Set(repTotalComparisons(target: target)
                .filter { $0.hasData && loggedTotal > $0.totalWeightMoved }
                .map(\.kind))
        }
        if beatenKinds.contains(.bestForExercise) { return .allTimeBest }
        if beatenKinds.contains(.bestAtTheseWeights) { return .bestAtWeights }
        if beatenKinds.contains(.lastLogged) { return .previousWorkout }
        return nil
    }

    /// Shared weight-entry cell for one set — a plate/dumbbell wheel picker
    /// normally, or a "BW + n" added-weight stepper for a bodyweight exercise
    /// (suggested/AI weights already represent added load in that case).
    @ViewBuilder
    private func weightCell(for index: Int, height: CGFloat) -> some View {
        if draft.isBodyweight {
            // The "181 (BW) +" label lives once in the column header, not
            // repeated per row — this is just the wheel, aligned under it.
            ZStack(alignment: .top) {
                Picker("Added Weight", selection: Binding(
                    get: { nearestValue(draft.sets[index].weight ?? 0, in: addedWeightValues) },
                    set: { newValue in
                        let old = draft.sets[index].weight ?? 0
                        draft.sets[index].weightText = Formatters.trim(newValue)
                        let delta = newValue - old
                        if delta != 0 { cascadeDelta(delta, from: index) }
                        checkAutoCollapse()
                    })) {
                    ForEach(addedWeightValues, id: \.self) { v in
                        Text(Formatters.trim(v)).font(.subheadline.weight(.medium)).tag(v)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: weightColumnWidth, height: height)
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
        } else {
            ZStack(alignment: .top) {
                Picker("Weight", selection: Binding(
                    get: { nearestValue(draft.sets[index].weight ?? 0, in: weightValues) },
                    set: { newValue in
                        let old = draft.sets[index].weight ?? 0
                        draft.sets[index].weightText = Formatters.trim(newValue)
                        let delta = newValue - old
                        if delta != 0 { cascadeDelta(delta, from: index) }
                        checkAutoCollapse()
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
    private func repTotalSetRows(scrollProxy: ScrollViewProxy) -> some View {
        // -8, matching setRows' own overlap: each wheel row already centers
        // its selected value within its own tall frame, so any positive
        // gap here just reads as extra dead space between sets — more
        // noticeable here than in setRows since a repTotal exercise's set
        // count is open-ended (via Add Set) rather than fixed up front.
        VStack(alignment: .leading, spacing: -8) {
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

                    // Add Set's slot — right after the wheel rather than
                    // floating out in the trailing gap. Rendered on every
                    // row, not just the last one — invisible and untappable
                    // where it doesn't apply — so its 24pt column is always
                    // really there instead of relying on an empty
                    // conditional view to still reserve the same width,
                    // which is what left delete misaligned between the last
                    // row and every other one.
                    let isLastRow = i == draft.sets.count - 1
                    Button {
                        let carryWeight = draft.sets.last?.weightText ?? ""
                        draft.sets.append(WorkoutLogView.SetDraft(weightText: carryWeight, repsText: ""))
                        // Scroll to the marker below every row, not this
                        // button itself — the button's small icon sits
                        // vertically centered in its (much taller) row, so
                        // anchoring on it left the bottom of the new row
                        // still clipped. Deferred a run-loop turn since the
                        // marker hasn't moved down to sit below the new row
                        // until it's actually laid out.
                        DispatchQueue.main.async {
                            withAnimation {
                                scrollProxy.scrollTo("repTotalBottomAnchor", anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                    .opacity(isLastRow ? 1 : 0)
                    .disabled(!isLastRow)
                    .allowsHitTesting(isLastRow)
                    .frame(width: 24)

                    // Delete, right after Add Set's slot (with the row's
                    // normal 12pt gap, not pushed out toward the trailing
                    // edge) — always shown once there's more than one set,
                    // so no per-row conditional here to misalign.
                    Group {
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
                    .frame(width: 24)
                }
            }

            // Scroll target for the Add Set button above — sits below every
            // row, so scrolling to it always reaches the true bottom of the
            // list instead of stopping wherever the last row's own Add Set
            // icon happens to be.
            Color.clear.frame(height: 1).id("repTotalBottomAnchor")
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
    /// exercise auto-collapses (or is manually collapsed) — grid-aligned by
    /// set like the historical pace-calc rows, and includes each of those
    /// same three comparisons' results so how today stacks up is visible at
    /// a glance without swiping the pace panel back open.
    private var currentWorkoutRow: some View {
        let weightLabels = draft.sets
            .map { $0.weightText.isEmpty ? "—" : (draft.isBodyweight ? "BW+\($0.weightText)" : $0.weightText) }
        let repLabels = draft.sets.map { $0.repsText.isEmpty ? "—" : $0.repsText }
        let totalLine: String? = {
            guard case .repTotal(let target) = draft.goalType else { return nil }
            return "\(draft.repTotalSoFar)/\(target) reps"
        }()

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Workout").font(.caption.bold())
                if let totalLine {
                    Text(totalLine).font(.caption2.bold()).foregroundStyle(.blue)
                }
                SetsGrid(weightLabels: weightLabels, repLabels: repLabels)
            }

            switch draft.goalType {
            case .fixedSets:
                ForEach(comparisons) { c in
                    PaceRow(target: c, draft: draft, currentBodyweight: currentBodyweight)
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
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

}

// MARK: - Quick notes editor, reachable from the Warm-Up Sets page

struct NotesEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(text); dismiss() }
                    }
                }
        }
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

// MARK: - Scaled celebration for beating a pace-calculator comparison on
// exercise completion — bigger the more prestigious the comparison beaten.

struct CelebrationBurst: View {
    enum Tier {
        case previousWorkout
        case bestAtWeights
        case allTimeBest

        var particleCount: Int {
            switch self {
            case .previousWorkout: return 10
            case .bestAtWeights: return 20
            case .allTimeBest: return 36
            }
        }
        // Radii are large enough to clear a 135pt medal emoji (see
        // MedalPopup) so the burst visibly surrounds it rather than
        // overlapping its glyph.
        var radius: Double {
            switch self {
            case .previousWorkout: return 85
            case .bestAtWeights: return 105
            case .allTimeBest: return 130
            }
        }
        var duration: Double {
            switch self {
            case .previousWorkout: return 0.675
            case .bestAtWeights: return 0.975
            case .allTimeBest: return 1.35
            }
        }
        var label: String? {
            switch self {
            case .previousWorkout: return nil
            case .bestAtWeights: return "PR! 🔥"
            case .allTimeBest: return "ALL-TIME BEST! 🏆"
            }
        }
        var colors: [Color] {
            switch self {
            case .previousWorkout: return [.green]
            case .bestAtWeights: return [.green, .yellow]
            case .allTimeBest: return [.yellow, .orange, .red]
            }
        }
    }

    let tier: Tier
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<tier.particleCount, id: \.self) { i in
                Circle()
                    .fill(tier.colors[i % tier.colors.count])
                    .frame(width: 6, height: 6)
                    .offset(expanded ? offset(for: i) : .zero)
                    .opacity(expanded ? 0 : 1)
                    .scaleEffect(expanded ? 0.3 : 1)
            }
            if let label = tier.label {
                Text(label)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.75), in: Capsule())
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.5)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: tier.duration)) {
                expanded = true
            }
        }
    }

    private func offset(for index: Int) -> CGSize {
        let angle = (Double(index) / Double(tier.particleCount)) * 2 * .pi
        return CGSize(width: cos(angle) * tier.radius, height: sin(angle) * tier.radius)
    }
}

/// A single medal emoji that pops in big, settles, then fades — shown 2
/// seconds after an exercise becomes complete if today's live total ranks
/// top-3 for its plan. See `ExercisePageView.checkCelebrationEffects`.
struct MedalPopup: View {
    let emoji: String
    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0

    var body: some View {
        Text(emoji)
            .font(.system(size: 135))
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) {
                    scale = 1.15
                    opacity = 1
                }
                withAnimation(.easeOut(duration: 0.3).delay(0.525)) {
                    scale = 1.0
                }
                withAnimation(.easeIn(duration: 0.525).delay(1.425)) {
                    opacity = 0
                }
            }
    }
}

/// Weights over reps, Grid-aligned by set so every "/" lands in the same
/// horizontal spot on both lines — same layout convention History uses for
/// a logged exercise's sets, just without History's optional target-reps
/// row. Reps are strings (not Int) so a still-in-progress set can show a
/// "—" placeholder alongside a completed log's real numbers.
struct SetsGrid: View {
    let weightLabels: [String]
    let repLabels: [String]
    /// Optional per-column color override for the reps row only — an index
    /// left nil (or past the array's end) keeps the default secondary
    /// color.
    var repColors: [Color?] = []
    /// Optional 3rd row beneath reps — e.g. PaceRow's per-set cumulative
    /// pace delta, shown only once today's matching set has been logged (an
    /// empty string at that index leaves the cell blank). Row is omitted
    /// entirely when this is empty.
    var deltaLabels: [String] = []
    var deltaColors: [Color?] = []

    var body: some View {
        let columnCount = max(weightLabels.count, repLabels.count, deltaLabels.count)
        Grid(alignment: .center, horizontalSpacing: 3, verticalSpacing: 2) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { idx in
                    Text(idx < weightLabels.count ? weightLabels[idx] : "")
                        .foregroundStyle(.secondary)
                    if idx < columnCount - 1 {
                        Text("/").foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }
            GridRow {
                ForEach(0..<columnCount, id: \.self) { idx in
                    Text(idx < repLabels.count ? repLabels[idx] : "")
                        .foregroundStyle((idx < repColors.count ? repColors[idx] : nil) ?? .secondary)
                    if idx < columnCount - 1 {
                        Text("/").foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }
            if !deltaLabels.isEmpty {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { idx in
                        Text(idx < deltaLabels.count ? deltaLabels[idx] : "")
                            .foregroundStyle((idx < deltaColors.count ? deltaColors[idx] : nil) ?? .secondary)
                            .bold()
                        if idx < columnCount - 1 {
                            Text("")
                        }
                    }
                }
            }
        }
        .font(.system(.caption2, design: .monospaced))
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
                labelText(target.label, medalRank: target.medalRank, baseFont: .caption.bold())
                Spacer()
                if let date = target.date {
                    Text(Formatters.date.string(from: date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if target.hasData {
                SetsGrid(weightLabels: target.weightLabels, repLabels: target.reps.map(String.init))
                comparisonLine
            } else {
                Text(noDataMessage)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Actual reps achieved that log — sum of every logged set, not just
    /// the nominal target it reached (could run a little over).
    private var totalReps: Int { target.reps.reduce(0, +) }

    @ViewBuilder
    private var comparisonLine: some View {
        if let setsToComplete = target.setsToComplete {
            if target.kind == .lastLogged {
                Text("Finished \(totalReps) reps in \(setsToComplete) set\(setsToComplete == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let room = PaceEngine.repTotalPRRoom(setsLoggedSoFar: setsLoggedSoFar, bestSetsToComplete: setsToComplete) {
                Label("Finish in \(room) more set\(room == 1 ? "" : "s") for a PR", systemImage: "target")
                    .font(.caption).foregroundStyle(.orange)
            } else if setsLoggedSoFar >= setsToComplete {
                Label("Matched or beat the \(setsToComplete)-set record 🔥", systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("Best: finished \(totalReps) reps in \(setsToComplete) set\(setsToComplete == 1 ? "" : "s")")
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
    let draft: WorkoutLogView.ExerciseDraft
    let currentBodyweight: Double?

    private var loggedSoFar: Double { draft.loggedTotal(bodyweight: currentBodyweight) }
    private var remainingWeights: [Double] {
        draft.sets.filter { $0.reps == nil }.map { $0.weight ?? 0 }
    }
    /// Average weight moved per rep so far — converts a beaten-by/fell-
    /// short-by weight delta into an equivalent whole-rep count.
    private var avgWeightPerRep: Double {
        let totalReps = draft.sets.compactMap(\.reps).reduce(0, +)
        guard totalReps > 0 else { return 0 }
        return loggedSoFar / Double(totalReps)
    }
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

    /// Cumulative reps ahead (green, sign kept) or behind (red) this
    /// target's own pace as of today's set `n` (1-based) — a permanent
    /// snapshot, not a live-recomputed running total: set n's own weight/
    /// reps (already logged, so fixed) and the target's milestone at n are
    /// both fixed the moment set n is logged, so this never changes
    /// retroactively just because a later set gets logged too. Nil until
    /// set n itself has been logged.
    private func cumulativeDelta(throughSet n: Int) -> (reps: Int, ahead: Bool)? {
        let loggedSets = draft.sets.filter(\.isLogged)
        guard target.hasData, avgWeightPerRep > 0, n >= 1, n <= loggedSets.count else { return nil }
        let cumulative = loggedSets.prefix(n).reduce(0.0) { total, s in
            let raw = s.weight ?? 0
            let effective = draft.isBodyweight ? raw + (currentBodyweight ?? 0) : raw
            return total + effective * Double(s.reps ?? 0)
        }
        let milestone = PaceEngine.milestone(atSetIndex: n, setWeightsMoved: target.setWeightsMoved,
                                             total: target.totalWeightMoved)
        let deltaLbs = cumulative - milestone
        // Always rounds up — a hair ahead is still a whole rep ahead, and a
        // hair behind still costs a whole rep — so 0 only ever comes out
        // when deltaLbs is exactly 0, i.e. genuinely, exactly on pace.
        let reps = Int(ceil(abs(deltaLbs) / avgWeightPerRep))
        return (reps, deltaLbs >= 0)
    }

    /// A 3rd grid row beneath the target's own weights/reps — blank until
    /// today's matching set is logged, then shows that set's cumulative
    /// pace delta ("+N" ahead / "(N)" behind).
    private var paceDeltaLabels: [String] {
        target.reps.indices.map { i in
            guard let delta = cumulativeDelta(throughSet: i + 1) else { return "" }
            return delta.ahead ? "+\(delta.reps)" : "(\(delta.reps))"
        }
    }
    private var paceDeltaColors: [Color?] {
        target.reps.indices.map { i in
            guard let delta = cumulativeDelta(throughSet: i + 1) else { return nil }
            return delta.ahead ? .green : .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                labelText(target.label, medalRank: target.medalRank, baseFont: .caption.bold())
                Spacer()
                if let date = target.date {
                    Text(Formatters.date.string(from: date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if target.hasData {
                SetsGrid(weightLabels: target.weightLabels, repLabels: target.reps.map(String.init),
                        deltaLabels: paceDeltaLabels, deltaColors: paceDeltaColors)
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
        if beaten {
            Text("Beaten by \(repsEquivalent(loggedSoFar - target.totalWeightMoved)) 🔥")
                .font(.caption).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                paceCellLabel
                // Only meaningful once there's no next set left to give a
                // pace reading for instead — while sets remain, you haven't
                // actually fallen short yet, just not finished.
                if remainingWeights.isEmpty {
                    Text("Fell short by \(repsEquivalent(target.totalWeightMoved - loggedSoFar)) overall 😔")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// The even-pace cell for the upcoming set (PaceEngine.evenPaceCellValue)
    /// — nil (and so nothing rendered here) once there's no next set left to
    /// give a pace reading for.
    @ViewBuilder
    private var paceCellLabel: some View {
        let setsLoggedSoFar = draft.sets.filter(\.isLogged).count
        if let cell = PaceEngine.evenPaceCellValue(target: target, loggedSoFar: loggedSoFar,
                                                    setsLoggedSoFar: setsLoggedSoFar,
                                                    totalSetsToday: draft.sets.count) {
            // Whole reps only — you can't do a fractional one. Round toward
            // whichever direction doesn't overstate the claim: floor "ahead"
            // (don't claim more cushion than's actually banked), ceil "need"
            // (11.7 needed really means 12 whole reps, not 11).
            if cell < 0 {
                let repsAhead = Int(floor(abs(cell)))
                Label("\(repsAhead) rep\(repsAhead == 1 ? "" : "s") ahead of pace", systemImage: "arrow.up.right")
                    .font(.caption).foregroundStyle(.green)
            } else {
                let repsNeeded = Int(ceil(cell))
                Label("Need \(repsNeeded) rep\(repsNeeded == 1 ? "" : "s") in your next set to stay on pace",
                      systemImage: "target")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - End-of-workout recap (what you beat, progress to a weight jump,
// and an explicit jump/stay or drop/stay choice per exercise)

struct WorkoutRecapView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [WorkoutLogView.RecapEntry]
    @Binding var choices: [String: Bool]
    /// Hand-adjustable per-set weights, keyed by exercise name — seeded
    /// from each entry's `suggestion` before this sheet appears, edited
    /// here via the +/- stepper on each set.
    @Binding var weights: [String: [Double]]
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
                            let accepted = choices[entry.exerciseName] ?? true
                            Toggle(isJump ? "Apply the suggested jump" : "Apply the suggested drop", isOn: Binding(
                                get: { accepted },
                                set: { choices[entry.exerciseName] = $0 }))

                            if accepted {
                                let setWeights = weights[entry.exerciseName] ?? suggestion
                                ForEach(setWeights.indices, id: \.self) { i in
                                    HStack {
                                        Text("Set \(i + 1)")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(Formatters.trim(entry.currentWeights[safe: i] ?? 0)) → \(Formatters.trim(setWeights[i]))")
                                        Stepper("", value: Binding(
                                            get: { weights[entry.exerciseName]?[safe: i] ?? suggestion[i] },
                                            set: { newValue in
                                                var arr = weights[entry.exerciseName] ?? suggestion
                                                arr[i] = newValue
                                                weights[entry.exerciseName] = arr
                                            }), step: entry.increment)
                                        .labelsHidden()
                                        .fixedSize()
                                    }
                                }
                            } else {
                                Text("Stay at \(entry.currentWeights.map { Formatters.trim($0) }.joined(separator: "/"))")
                                    .foregroundStyle(.secondary)
                            }
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
    let allLogs: [ExerciseLog]
    let currentBodyweight: Double?
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
        // Indicators left on (unlike the outer paging ScrollView) so a
        // visible scrollbar signals there's more below when the completed
        // list is too long for one screen — otherwise it'd look identical
        // to a page that simply ended.
        ScrollView(showsIndicators: true) {
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
            .frame(minHeight: pageHeight, alignment: .topLeading)
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

    private func comparisons(for draft: WorkoutLogView.ExerciseDraft) -> [ComparisonTarget] {
        PaceEngine.comparisons(for: draft.name,
                               targetReps: draft.targetReps,
                               currentWeights: draft.sets.map { $0.weight ?? 0 },
                               isBodyweight: draft.isBodyweight,
                               allLogs: allLogs)
    }
    private func repTotalComparisons(for draft: WorkoutLogView.ExerciseDraft, target: Int) -> [PaceEngine.RepTotalComparisonTarget] {
        let weightsKey = draft.isBodyweight
            ? draft.sets.map { "BW+\(Formatters.trim($0.weight ?? 0))" }.joined(separator: "/")
            : draft.sets.map { Formatters.trim($0.weight ?? 0) }.joined(separator: "/")
        return PaceEngine.repTotalComparisons(for: draft.name, target: target,
                                              currentWeightsKey: weightsKey, allLogs: allLogs)
    }
    private func avgWeightPerRep(for draft: WorkoutLogView.ExerciseDraft) -> Double {
        let totalReps = draft.sets.compactMap(\.reps).reduce(0, +)
        guard totalReps > 0 else { return 0 }
        return draft.loggedTotal(bodyweight: currentBodyweight) / Double(totalReps)
    }

    /// Condensed "Beaten by N reps"/"Fell short by N reps" verdict, without
    /// the target's own weight/rep grid — the summary page just needs the
    /// result, not the historical detail behind it.
    private func fixedSetsResult(_ target: ComparisonTarget, draft: WorkoutLogView.ExerciseDraft) -> (text: String, color: Color) {
        guard target.hasData else { return ("First time — set the baseline 💪", .secondary) }
        let loggedSoFar = draft.loggedTotal(bodyweight: currentBodyweight)
        let avg = avgWeightPerRep(for: draft)
        func repsEquivalent(_ lbsDelta: Double) -> String {
            guard avg > 0 else { return "0 reps" }
            let reps = max(1, Int(ceil(abs(lbsDelta) / avg)))
            return "\(reps) rep\(reps == 1 ? "" : "s")"
        }
        if loggedSoFar > target.totalWeightMoved {
            return ("Beaten by \(repsEquivalent(loggedSoFar - target.totalWeightMoved)) 🔥", .green)
        } else {
            return ("Fell short by \(repsEquivalent(target.totalWeightMoved - loggedSoFar)) 😔", .red)
        }
    }

    /// Same condensing treatment as `fixedSetsResult`, for a repTotal exercise.
    private func repTotalResult(_ target: PaceEngine.RepTotalComparisonTarget,
                                setsLoggedSoFar: Int, loggedTotal: Double) -> (text: String, color: Color) {
        guard target.hasData else { return ("First time — set the baseline 💪", .secondary) }
        if let setsToComplete = target.setsToComplete {
            if target.kind == .lastLogged {
                return ("Finished in \(setsToComplete) set\(setsToComplete == 1 ? "" : "s")", .secondary)
            } else if let room = PaceEngine.repTotalPRRoom(setsLoggedSoFar: setsLoggedSoFar, bestSetsToComplete: setsToComplete) {
                return ("Finish in \(room) more set\(room == 1 ? "" : "s") for a PR", .orange)
            } else if setsLoggedSoFar >= setsToComplete {
                return ("Matched or beat the \(setsToComplete)-set record 🔥", .green)
            } else {
                return ("Best: \(setsToComplete) set\(setsToComplete == 1 ? "" : "s") to finish", .secondary)
            }
        } else if loggedTotal > target.totalWeightMoved {
            return ("Beaten on total weight moved 🔥", .green)
        } else {
            return ("Unfinished last time — \(Formatters.trim(target.totalWeightMoved)) lbs moved", .secondary)
        }
    }

    private func row(for i: Int) -> some View {
        let draft = drafts[i]
        let weightLabels = draft.sets
            .map { $0.weightText.isEmpty ? "—" : (draft.isBodyweight ? "BW+\($0.weightText)" : $0.weightText) }
        let repLabels = draft.sets.map { $0.repsText.isEmpty ? "—" : $0.repsText }
        return VStack(alignment: .leading, spacing: 6) {
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
            SetsGrid(weightLabels: weightLabels, repLabels: repLabels)

            switch draft.goalType {
            case .fixedSets:
                ForEach(comparisons(for: draft)) { c in
                    let result = fixedSetsResult(c, draft: draft)
                    (labelText(c.label, medalRank: c.medalRank, baseFont: .caption2, baseColor: .secondary)
                     + Text(": ").foregroundStyle(.secondary)
                     + Text(result.text).foregroundStyle(result.color))
                        .font(.caption2)
                }
            case .repTotal(let target):
                ForEach(repTotalComparisons(for: draft, target: target)) { c in
                    let result = repTotalResult(c, setsLoggedSoFar: draft.sets.filter(\.isLogged).count,
                                                loggedTotal: draft.loggedTotal(bodyweight: currentBodyweight))
                    (labelText(c.label, medalRank: c.medalRank, baseFont: .caption2, baseColor: .secondary)
                     + Text(": ").foregroundStyle(.secondary)
                     + Text(result.text).foregroundStyle(result.color))
                        .font(.caption2)
                }
            }
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
