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

    let phase: Phase
    let day: PhaseDay

    @State private var drafts: [ExerciseDraft] = []
    @State private var showRecapSheet = false
    @State private var recapEntries: [RecapEntry] = []
    @State private var recapChoices: [String: Bool] = [:]
    @State private var currentPageID: String?
    @State private var showExerciseJumpList = false
    /// Last time the user touched anything in this workout — used to keep
    /// the screen from auto-locking for up to 3 minutes of idle time.
    @State private var lastInteraction = Date()

    private var settings: AppSettings? { settingsList.first }
    private var isDeloadCycle: Bool {
        settings?.deloadWeeksEnabled == true && phase.deloadCycle == phase.currentCycle
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
        var targetReps: [Int]
        var sets: [SetDraft]
        /// False once every set is logged and it's auto-collapsed to a summary.
        var isExpanded: Bool = true
        /// False after the user manually reopens a collapsed exercise, so it
        /// won't auto-collapse again until they close it themselves.
        var autoCollapseEnabled: Bool = true
        /// Notes / plate-calculator panel toggle, lifted up here (instead of
        /// local view state) so the sticky section header can drive it too.
        var showingDetails: Bool = false
        var loggedTotal: Double {
            sets.reduce(0) { $0 + (Double($1.reps ?? 0) * ($1.weight ?? 0)) }
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
    /// order; any collapsed/completed ones are gathered onto one trailing
    /// summary page instead of each taking a full screen.
    private var pages: [WorkoutPage] {
        var result: [WorkoutPage] = drafts.indices.filter { drafts[$0].isExpanded }.map { .exercise($0) }
        if drafts.contains(where: { !$0.isExpanded }) {
            result.append(.completedSummary)
        }
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
                                                pageHeight: geo.size.height, currentPageID: $currentPageID)
                                    .id("ex-\(drafts[i].id)")
                            case .completedSummary:
                                CompletedSummaryPageView(drafts: $drafts, pageHeight: geo.size.height,
                                                        currentPageID: $currentPageID)
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
        .safeAreaInset(edge: .bottom) {
            Button {
                finishWorkout()
            } label: {
                Label("Finish & Save Workout", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(drafts.allSatisfy { $0.sets.allSatisfy { !$0.isLogged } })
            .padding()
            .background(.bar)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("\(day.name) · Cycle \(phase.currentCycle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            List(drafts) { draft in
                                Button {
                                    withAnimation { currentPageID = pageID(for: draft) }
                                    showExerciseJumpList = false
                                } label: {
                                    Text(draft.name)
                                        .strikethrough(!draft.isExpanded)
                                        .foregroundStyle(draft.isExpanded ? .primary : .secondary)
                                }
                            }
                            .presentationCompactAdaptation(.popover)
                            .frame(minWidth: 250, minHeight: 200)
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
    /// your whole training history, not just the current block).
    private func history(for pe: PlannedExercise) -> [ExerciseLog] {
        allExerciseLogs
            .filter { $0.planKey == pe.planKey && !$0.sets.isEmpty && $0.session?.isDeload != true }
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

        for pe in phase.plan(for: day) {
            let logs = history(for: pe)
            let increment = roundingIncrement(for: pe.exerciseName)
            // AI on: what the AI Assistant thinks is the right goal from history.
            // AI off: exactly what was lifted last time.
            var weights = aiOn
                ? (ProgressionEngine.suggestNextWeights(targetReps: pe.targetReps, history: logs,
                                                        aggressiveness: agg, roundingIncrement: increment)
                   ?? pe.suggestedWeights)
                : (logs.last?.sortedSets.map(\.weight) ?? pe.suggestedWeights)
            if isDeloadCycle, !weights.isEmpty {
                weights = ProgressionEngine.deloadWeights(from: weights)
            }
            let sets = pe.targetReps.enumerated().map { i, _ in
                SetDraft(weightText: i < weights.count ? Formatters.trim(weights[i]) : "",
                         repsText: "")
            }
            drafts.append(ExerciseDraft(name: pe.exerciseName,
                                        targetReps: pe.targetReps,
                                        sets: sets))
        }
    }

    // MARK: Draft persistence (survives tab switches / app close)

    private var draftStorageKey: String {
        "workoutDraft_\(phase.number)_\(day.name)_\(phase.currentCycle)"
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
        let session = WorkoutSession(day: day, dayLabel: day.name,
                                     cycleNumber: phase.currentCycle,
                                     isDeload: isDeloadCycle)
        session.phase = phase
        context.insert(session)

        let agg = settings?.aiAggressiveness ?? .moderate
        var entries: [RecapEntry] = []

        for (order, d) in drafts.enumerated() {
            let logged = d.sets.filter(\.isLogged)
            guard !logged.isEmpty else { continue }

            let pe = phase.plan(for: day).first { $0.exerciseName == d.name }
            let priorLogs = pe.map(history) ?? []

            let log = ExerciseLog(exerciseName: d.name, targetReps: d.targetReps, order: order)
            log.session = session
            context.insert(log)
            for (i, s) in logged.enumerated() {
                let set = SetLog(index: i, weight: s.weight ?? 0, reps: s.reps ?? 0)
                set.exerciseLog = log
                context.insert(set)
            }

            // Recap + next-cycle progression — skip during a deload (weights
            // are intentionally cut, so progression math doesn't apply) or
            // once the phase is over (no next cycle to jump into).
            if !isDeloadCycle, !phase.isComplete {
                let increment = roundingIncrement(for: d.name)
                let combinedHistory = priorLogs + [log]
                let streak = ProgressionEngine.currentStreak(targetReps: d.targetReps, history: combinedHistory)
                let suggestion = ProgressionEngine.suggestNextWeights(
                    targetReps: d.targetReps, history: combinedHistory,
                    aggressiveness: agg, roundingIncrement: increment)
                let currentWeights = log.sortedSets.map(\.weight)
                entries.append(RecapEntry(exerciseName: d.name,
                                          previousTotal: priorLogs.last?.totalWeightMoved,
                                          todayTotal: log.totalWeightMoved,
                                          streak: streak,
                                          requiredStreak: ProgressionEngine.requiredStreak(for: agg),
                                          suggestion: (suggestion != currentWeights) ? suggestion : nil,
                                          currentWeights: currentWeights))
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
                  let pe = phase.plan(for: day).first(where: { $0.exerciseName == entry.exerciseName }) else { continue }
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

    private var comparisons: [ComparisonTarget] {
        PaceEngine.comparisons(for: draft.name,
                               targetReps: draft.targetReps,
                               currentWeights: draft.sets.map { $0.weight ?? 0 },
                               allLogs: allLogs)
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
        return draft.loggedTotal / Double(totalReps)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if draft.isExpanded {
                if draft.showingDetails {
                    notesAndPlateCalc(exerciseDef)
                }
                setRows
            } else {
                currentWorkoutRow
            }

            // Pace panel — always shows all three comparisons; any with no
            // prior data yet just says so instead of being omitted.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comparisons) { c in
                    PaceRow(target: c,
                            loggedSoFar: draft.loggedTotal,
                            remainingWeights: remainingWeights,
                            avgWeightPerRep: avgWeightPerRep)
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

                    ZStack(alignment: .top) {
                        Picker("Weight", selection: Binding(
                            get: { nearestValue(draft.sets[i].weight ?? 0, in: weightValues) },
                            set: { newValue in
                                let old = draft.sets[i].weight ?? 0
                                draft.sets[i].weightText = Formatters.trim(newValue)
                                let delta = newValue - old
                                if delta != 0 { cascadeDelta(delta, from: i) }
                            })) {
                            ForEach(weightValues, id: \.self) { v in
                                Text(Formatters.trim(v)).font(.subheadline.weight(.medium)).tag(v)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100, height: wheelHeight)
                        .clipped()
                        if let delta = cascadeIndicator[i] {
                            Text(delta > 0 ? "+\(Formatters.trim(delta))" : Formatters.trim(delta))
                                .font(.caption2.bold())
                                .foregroundStyle(delta > 0 ? .green : .red)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.thinMaterial, in: Capsule())
                                .transition(.opacity)
                        }
                    }

                    if let goal = draft.targetReps[safe: i] {
                        HStack(spacing: 2) {
                            Text("\(goal)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 44, alignment: .center)
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
                                        draft.sets[i].repsText = String(goal)
                                        checkAutoCollapse()
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

                    Picker("Reps", selection: Binding(
                        get: { draft.sets[i].reps ?? 0 },
                        set: { newValue in
                            draft.sets[i].repsText = String(newValue)
                            checkAutoCollapse()
                        })) {
                        ForEach(0...50, id: \.self) { v in
                            Text("\(v)").font(.subheadline.weight(.medium)).tag(v)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 100, height: wheelHeight)
                    .clipped()

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

    /// Only auto-collapses if the exercise hasn't been manually reopened
    /// since the last time it collapsed. Waits 3 seconds before collapsing so
    /// the last entry doesn't vanish out from under you — and bails if
    /// anything's changed (re-opened, un-logged, or superseded) by the time
    /// it fires.
    private func checkAutoCollapse() {
        guard draft.autoCollapseEnabled, draft.sets.allSatisfy(\.isLogged) else { return }
        collapseGeneration += 1
        let generation = collapseGeneration
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard generation == collapseGeneration,
                  draft.autoCollapseEnabled, draft.sets.allSatisfy(\.isLogged) else { return }
            withAnimation { draft.isExpanded = false; currentPageID = "summary" }
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
        let weights = draft.sets.map { $0.weightText.isEmpty ? "—" : $0.weightText }.joined(separator: "/")
        let reps = draft.sets.map { $0.repsText.isEmpty ? "—" : $0.repsText }.joined(separator: "/")

        return VStack(alignment: .leading, spacing: 2) {
            Text("Current Workout").font(.caption.bold())
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

    private var completedIndices: [Int] {
        drafts.indices.filter { !drafts[$0].isExpanded }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Completed")
                    .font(.title2.bold())
                ForEach(completedIndices, id: \.self) { i in
                    row(for: i)
                }
            }
            .padding()
            .frame(minHeight: pageHeight, alignment: .top)
        }
    }

    private func row(for i: Int) -> some View {
        let draft = drafts[i]
        let weights = draft.sets.map { $0.weightText.isEmpty ? "—" : $0.weightText }.joined(separator: "/")
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
