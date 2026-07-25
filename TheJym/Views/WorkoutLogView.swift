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

struct WorkoutLogView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [AppSettings]
    @Query private var allExerciseLogs: [ExerciseLog]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

    let phase: Phase
    let day: PhaseDay

    @State private var drafts: [ExerciseDraft] = []
    @State private var showFinishSheet = false
    @State private var aiSuggestions: [AISuggestionRow] = []
    @State private var scrollToDraftID: UUID?
    @State private var selectedExerciseName: String?

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
        /// True if this exercise had no AI suggestion and no previous-workout
        /// weight to prefill from — drives the smart-fill-across-sets behavior.
        var hadNoBaseline: Bool = false
        /// False once every set is logged and it's auto-collapsed to a summary.
        var isExpanded: Bool = true
        /// False after the user manually reopens a collapsed exercise, so it
        /// won't auto-collapse again until they close it themselves.
        var autoCollapseEnabled: Bool = true
        var loggedTotal: Double {
            sets.reduce(0) { $0 + (Double($1.reps ?? 0) * ($1.weight ?? 0)) }
        }
    }

    struct AISuggestionRow: Identifiable {
        let id = UUID()
        var name: String
        var current: String
        var suggested: [Double]
        var overrideText: String
    }

    var body: some View {
        let plateSizes = settings?.availablePlateSizes ?? PlateCalculator.defaultPlates
        let dumbbellIncrement = settings?.dumbbellRoundingIncrement ?? 5
        ScrollViewReader { proxy in
            List {
                if isDeloadCycle {
                    Section {
                        Label("Deload cycle — weights below are cut to ~60% to dissipate fatigue before the next block. Go light, move well, recover.",
                              systemImage: "arrow.down.heart")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                ForEach(Array(drafts.indices), id: \.self) { i in
                    Section {
                        ExerciseDraftSection(draft: $drafts[i], allLogs: allExerciseLogs,
                                            exerciseDef: exerciseDefs.first { $0.name == drafts[i].name },
                                            plateSizes: plateSizes, dumbbellIncrement: dumbbellIncrement)
                    } header: {
                        Text(drafts[i].name)
                            .font(.headline)
                    }
                    .id(drafts[i].id)
                }
                Section {
                    Button {
                        finishWorkout()
                    } label: {
                        Label("Finish & Save Workout", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(drafts.allSatisfy { $0.sets.allSatisfy { !$0.isLogged } })
                }
            }
            .listStyle(.plain)
            .onChange(of: scrollToDraftID) { _, newID in
                if let newID {
                    withAnimation { proxy.scrollTo(newID, anchor: .top) }
                }
            }
        }
        .navigationTitle("\(day.name) · Cycle \(phase.currentCycle)")
        .toolbar {
            if drafts.count > 1 {
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(drafts) { draft in
                            Button(draft.name) {
                                scrollToDraftID = draft.id
                                selectedExerciseName = draft.name
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedExerciseName ?? "\(day.name) · Cycle \(phase.currentCycle)")
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .onAppear(perform: buildDrafts)
        .onChange(of: drafts) { _, _ in saveDraftToDisk() }
        .sheet(isPresented: $showFinishSheet, onDismiss: { dismiss() }) {
            AISuggestionSheet(rows: $aiSuggestions) { applySuggestions() }
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
            let hadNoBaseline = weights.isEmpty
            let sets = pe.targetReps.enumerated().map { i, _ in
                SetDraft(weightText: i < weights.count ? Formatters.trim(weights[i]) : "",
                         repsText: "")
            }
            drafts.append(ExerciseDraft(name: pe.exerciseName,
                                        targetReps: pe.targetReps,
                                        sets: sets,
                                        hadNoBaseline: hadNoBaseline))
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

        for (order, d) in drafts.enumerated() {
            let logged = d.sets.filter(\.isLogged)
            guard !logged.isEmpty else { continue }
            let log = ExerciseLog(exerciseName: d.name, targetReps: d.targetReps, order: order)
            log.session = session
            context.insert(log)
            for (i, s) in logged.enumerated() {
                let set = SetLog(index: i, weight: s.weight ?? 0, reps: s.reps ?? 0)
                set.exerciseLog = log
                context.insert(set)
            }
        }
        try? context.save()
        clearSavedDraft()

        // AI Assistant: suggest next-cycle weights if enabled and phase continues.
        if settings?.aiAssistantEnabled == true, !phase.isComplete, !isDeloadCycle {
            buildAISuggestions()
            if !aiSuggestions.isEmpty {
                showFinishSheet = true
                return
            }
        }
        dismiss()
    }

    private func buildAISuggestions() {
        let agg = settings?.aiAggressiveness ?? .moderate
        aiSuggestions = []
        for pe in phase.plan(for: day) {
            let logs = history(for: pe)
            let increment = roundingIncrement(for: pe.exerciseName)
            guard let suggestion = ProgressionEngine.suggestNextWeights(
                targetReps: pe.targetReps, history: logs,
                aggressiveness: agg, roundingIncrement: increment),
                let latest = logs.last else { continue }

            let currentStr = latest.sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
            let suggestedStr = suggestion.map { Formatters.trim($0) }.joined(separator: "/")
            guard suggestedStr != currentStr else { continue }   // no change, skip

            aiSuggestions.append(AISuggestionRow(name: pe.exerciseName,
                                                 current: currentStr,
                                                 suggested: suggestion,
                                                 overrideText: suggestedStr))
        }
    }

    private func applySuggestions() {
        for row in aiSuggestions {
            guard let pe = phase.plan(for: day).first(where: { $0.exerciseName == row.name }) else { continue }
            let weights = row.overrideText.split(separator: "/")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if !weights.isEmpty { pe.suggestedWeights = weights }
        }
        try? context.save()
    }
}

// MARK: - One exercise's logging card + pace panel

struct ExerciseDraftSection: View {
    @Binding var draft: WorkoutLogView.ExerciseDraft
    let allLogs: [ExerciseLog]
    let exerciseDef: ExerciseDef?
    let plateSizes: [Double]
    let dumbbellIncrement: Double

    @State private var showingDetails = false
    @State private var plateTargetText = ""

    private enum FocusTarget: Hashable {
        case weight(Int)
        case reps(Int)
    }
    @FocusState private var focusedField: FocusTarget?
    /// Snapshot taken when a weight field gains focus, so on blur we can
    /// tell what actually changed (and avoid reacting to every keystroke —
    /// e.g. typing "175" one digit at a time shouldn't cascade three times).
    @State private var weightOnFocus: [Int: String] = [:]
    /// Sets a later set's weight was just shifted by via cascade, so the
    /// field can flash a "+10"/"-5" badge before fading out.
    @State private var cascadeIndicator: [Int: Double] = [:]
    @State private var wheelTarget: WheelTarget?

    private struct WheelTarget: Identifiable, Equatable {
        let index: Int
        let isWeight: Bool
        var id: String { "\(index)-\(isWeight)" }
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if draft.isExpanded {
                if showingDetails {
                    notesAndPlateCalc(exerciseDef)
                }
                setRows
            } else {
                currentWorkoutRow
            }

            // Pace panel
            if comparisons.isEmpty {
                Text("First time logging this — set the baseline. 💪")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
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
        }
        .padding(.vertical, 4)
        .onChange(of: focusedField) { oldField, newField in
            if let oldField, oldField != newField {
                switch oldField {
                case .weight(let idx) where idx < draft.sets.count:
                    commitWeightEdit(at: idx)
                case .reps:
                    checkAutoCollapse()
                default:
                    break
                }
            }
            if case .weight(let idx) = newField {
                weightOnFocus[idx] = draft.sets[idx].weightText
            }
        }
        .popover(item: $wheelTarget) { target in
            wheelPickerContent(for: target)
        }
    }

    private var header: some View {
        HStack {
            Text("Goal \(draft.targetReps.map(String.init).joined(separator: "/"))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if draft.isExpanded {
                Button {
                    withAnimation { showingDetails.toggle() }
                } label: {
                    Image(systemName: showingDetails ? "chevron.up.circle.fill" : "info.circle")
                }
                .buttonStyle(.plain)
                .imageScale(.large)
                Button {
                    withAnimation { draft.isExpanded = false }
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
    }

    private var setRows: some View {
        ForEach(Array(draft.sets.enumerated()), id: \.element.id) { i, _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("Set \(i + 1)")
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        ZStack(alignment: .top) {
                            TextField("lbs", text: $draft.sets[i].weightText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .frame(width: 74)
                                .focused($focusedField, equals: .weight(i))
                            if let delta = cascadeIndicator[i] {
                                Text(delta > 0 ? "+\(Formatters.trim(delta))" : Formatters.trim(delta))
                                    .font(.caption2.bold())
                                    .foregroundStyle(delta > 0 ? .green : .red)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.thinMaterial, in: Capsule())
                                    .offset(y: -14)
                                    .transition(.opacity)
                            }
                        }
                        wheelButton { wheelTarget = WheelTarget(index: i, isWeight: true) }
                    }

                    Text("×").foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        TextField("reps", text: $draft.sets[i].repsText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .frame(width: 70)
                            .focused($focusedField, equals: .reps(i))
                        wheelButton { wheelTarget = WheelTarget(index: i, isWeight: false) }
                    }
                }
            }
            .animation(.easeInOut, value: cascadeIndicator[i])
        }
    }

    /// Runs once editing a weight field actually finishes (it loses focus),
    /// not on every keystroke — so typing "175" doesn't cascade on "1", "17",
    /// then "175" in turn.
    private func commitWeightEdit(at index: Int) {
        let before = weightOnFocus.removeValue(forKey: index) ?? ""
        let after = draft.sets[index].weightText
        guard before != after else { return }

        if before.isEmpty {
            // First-ever entry with nothing to prefill from: smart-fill the
            // other still-empty sets (same reps -> same weight, different
            // reps -> Epley-estimated).
            smartFillIfNeeded(from: index)
        } else if let oldWeight = Double(before), let newWeight = Double(after) {
            // Editing an existing weight: shift every LATER set that already
            // has a weight by the same delta, preserving the gap between
            // rep-groups (e.g. 165/165/185/185 -> edit set 1 to 175 ->
            // 175/175/195/195). Earlier sets are never touched.
            cascadeDelta(newWeight - oldWeight, from: index)
        }
    }

    private func cascadeDelta(_ delta: Double, from index: Int) {
        guard delta != 0 else { return }
        var affected: [Int] = []
        for k in (index + 1)..<draft.sets.count {
            guard let existing = draft.sets[k].weight else { continue }
            draft.sets[k].weightText = Formatters.trim(existing + delta)
            cascadeIndicator[k] = delta
            affected.append(k)
        }
        guard !affected.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for k in affected { cascadeIndicator.removeValue(forKey: k) }
        }
    }

    /// Only auto-collapses if the exercise hasn't been manually reopened
    /// since the last time it collapsed.
    private func checkAutoCollapse() {
        guard draft.autoCollapseEnabled else { return }
        if draft.sets.allSatisfy(\.isLogged) {
            withAnimation { draft.isExpanded = false }
        }
    }

    private func wheelButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.and.down.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// The scrollable wheel for either a set's weight or its reps — values
    /// step by the same increments the old +/- buttons used (smallest plate/
    /// dumbbell increment for weight, 1 for reps). Weight changes cascade to
    /// later sets immediately, same as before.
    @ViewBuilder
    private func wheelPickerContent(for target: WheelTarget) -> some View {
        if target.isWeight {
            let step = weightStep
            let values = Array(stride(from: 0.0, through: 600.0, by: step))
            VStack(spacing: 4) {
                Text("Set \(target.index + 1) Weight").font(.headline)
                Picker("Weight", selection: Binding(
                    get: { nearestValue(draft.sets[target.index].weight ?? 0, in: values) },
                    set: { newValue in
                        let old = draft.sets[target.index].weight ?? 0
                        draft.sets[target.index].weightText = Formatters.trim(newValue)
                        let delta = newValue - old
                        if delta != 0 { cascadeDelta(delta, from: target.index) }
                    })) {
                    ForEach(values, id: \.self) { v in
                        Text(Formatters.trim(v)).tag(v)
                    }
                }
                .pickerStyle(.wheel)
            }
            .padding()
            .presentationDetents([.height(260)])
            .presentationCompactAdaptation(.popover)
        } else {
            let values = Array(0...50)
            VStack(spacing: 4) {
                Text("Set \(target.index + 1) Reps").font(.headline)
                Picker("Reps", selection: Binding(
                    get: { draft.sets[target.index].reps ?? 0 },
                    set: { newValue in
                        draft.sets[target.index].repsText = String(newValue)
                        checkAutoCollapse()
                    })) {
                    ForEach(values, id: \.self) { v in
                        Text("\(v)").tag(v)
                    }
                }
                .pickerStyle(.wheel)
            }
            .padding()
            .presentationDetents([.height(260)])
            .presentationCompactAdaptation(.popover)
        }
    }

    private func nearestValue(_ target: Double, in values: [Double]) -> Double {
        values.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
    }

    /// If there's no history/AI weight to prefill from, entering a weight for
    /// one set fills the other still-empty sets: same target reps get the
    /// same weight, different rep targets get an Epley-estimated weight.
    private func smartFillIfNeeded(from sourceIndex: Int) {
        guard draft.hadNoBaseline, let sourceWeight = draft.sets[sourceIndex].weight else { return }
        let sourceReps = draft.targetReps[safe: sourceIndex] ?? 0
        for j in draft.sets.indices where j != sourceIndex && draft.sets[j].weightText.isEmpty {
            let targetRepsJ = draft.targetReps[safe: j] ?? sourceReps
            let estimated = targetRepsJ == sourceReps
                ? sourceWeight
                : ProgressionEngine.estimatedWeight(from: sourceWeight, atReps: sourceReps, forReps: targetRepsJ)
            draft.sets[j].weightText = Formatters.trim(estimated)
        }
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
            } else {
                Text("Tag equipment for this exercise in the Exercises tab to use the plate calculator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
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

    var body: some View {
        let beaten = loggedSoFar > target.totalWeightMoved
        let paceReps = PaceEngine.repsNeededNextSet(targetTotal: target.totalWeightMoved,
                                                    loggedSoFar: loggedSoFar,
                                                    remainingWeights: remainingWeights)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(target.kind.rawValue).font(.caption.bold())
                Spacer()
                Text(Formatters.date.string(from: target.date))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(target.setsSummary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if beaten {
                Label("Beaten by \(repsEquivalent(loggedSoFar - target.totalWeightMoved)) 🔥",
                      systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if remainingWeights.isEmpty {
                Label("Fell short by \(repsEquivalent(target.totalWeightMoved - loggedSoFar))",
                      systemImage: "arrow.down.right")
                    .font(.caption).foregroundStyle(.red)
            } else if let reps = paceReps {
                Label("Need \(reps) reps/set pace to beat it (\(remainingWeights.count) sets left)",
                      systemImage: "target")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - AI suggestion sheet (override before accepting)

struct AISuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var rows: [WorkoutLogView.AISuggestionRow]
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("AI suggestions for your next cycle. Edit any of these before applying, or skip to keep current weights.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    Section(row.name) {
                        LabeledContent("This cycle", value: row.current)
                        LabeledContent("Suggested") {
                            Text(row.suggested.map { Formatters.trim($0) }.joined(separator: "/"))
                                .foregroundStyle(.green)
                        }
                        TextField("Next cycle (override)", text: $row.overrideText)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
            }
            .navigationTitle("Next Cycle Weights")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(); dismiss() }
                }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
